import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// PDF through PDFKit: pages to images at any DPI, text out, images in.
enum PDFEngine {
    static var available: Bool { true }

    static func render(_ input: URL, to format: String, dpi: Int,
                       firstPageOnly: Bool, suffix: String?,
                       nameSource: URL? = nil,
                       progress: ((Double) -> Void)? = nil) throws -> [URL] {
        guard let document = PDFDocument(url: input) else {
            throw EngineError(message: "Cannot open \(input.lastPathComponent)")
        }
        guard document.pageCount > 0 else {
            throw EngineError(message: "\(input.lastPathComponent) has no pages")
        }
        let indexes = firstPageOnly ? [0] : Array(0..<document.pageCount)
        let naming = nameSource ?? input
        var written: [URL] = []
        for (position, index) in indexes.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let destination: URL
            if position == 0 {
                destination = Paths.destination(for: naming, format: format, suffix: suffix)
            } else {
                let base = naming.deletingPathExtension().lastPathComponent
                let directory = naming.deletingLastPathComponent()
                destination = Paths.unique(directory.appendingPathComponent(
                    "\(base)\(suffix ?? "")-\(index + 1).\(Formats.fileExtension(for: format))"))
            }
            try draw(page, to: destination, format: format, dpi: dpi)
            written.append(destination)
            progress?(Double(position + 1) / Double(indexes.count))
        }
        guard !written.isEmpty else {
            throw EngineError(message: "Nothing was rendered")
        }
        return written
    }

    static func text(_ input: URL, destination: URL) throws -> URL {
        guard let document = PDFDocument(url: input) else {
            throw EngineError(message: "Cannot open \(input.lastPathComponent)")
        }
        let text = document.string ?? ""
        guard !text.isEmpty else {
            throw EngineError(message: "That PDF has no selectable text")
        }
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw EngineError(message: error.localizedDescription)
        }
        return destination
    }

    static func imagesToPDF(_ inputs: [URL], destination: URL) throws -> URL {
        let document = PDFDocument()
        for input in inputs {
            guard let image = ImageEngine.orientedImage(from: input) else {
                throw EngineError(message: "Cannot read \(input.lastPathComponent)")
            }
            guard let page = PDFPage(image: NSImage(cgImage: image,
                                                   size: NSSize(width: image.width, height: image.height))) else {
                throw EngineError(message: "Cannot make a page from \(input.lastPathComponent)")
            }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, document.write(to: destination) else {
            throw EngineError(message: "Cannot write \(destination.lastPathComponent)")
        }
        return destination
    }

    // MARK: - Rendering

    private static func draw(_ page: PDFPage, to destination: URL,
                             format: String, dpi: Int) throws {
        let bounds = page.bounds(for: .mediaBox)
        let scale = CGFloat(max(36, dpi)) / 72.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else {
            throw EngineError(message: "Empty page")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw EngineError(message: "Cannot allocate a page context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw EngineError(message: "Cannot render the page")
        }

        let type = format == "jpeg" ? UTType.jpeg : UTType.png
        guard let target = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw EngineError(message: "Cannot write \(destination.lastPathComponent)")
        }
        let options: [CFString: Any] = format == "jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(target, image, options as CFDictionary)
        guard CGImageDestinationFinalize(target) else {
            throw EngineError(message: "Cannot write \(destination.lastPathComponent)")
        }
    }
}
