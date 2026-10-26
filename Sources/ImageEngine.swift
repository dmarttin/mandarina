import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Images through ImageIO and `sips`, which ship with macOS. This is the part
/// that works with nothing installed at all.
enum ImageEngine {
    static let writable: Set<String> = ["jpeg", "png", "tiff", "gif", "bmp", "heic", "avif", "tga", "exr"]

    static func canWrite(_ format: String) -> Bool { writable.contains(format) }

    static func convert(_ input: URL, to format: String, destination: URL,
                        quality: Int?, maxEdge: Int?, flatten: Bool) throws -> URL {
        guard canWrite(format) else {
            throw EngineError(message: "The image engine cannot write \(format)")
        }
        var source = input
        var temporary: URL?
        if flatten {
            source = try flattened(input)
            temporary = source
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        var arguments = ["-s", "format", sipsName(format)]
        if let quality {
            arguments += ["-s", "formatOptions", String(min(100, max(1, quality)))]
        }
        if let maxEdge {
            arguments += ["--resampleHeightWidthMax", String(maxEdge)]
        }
        arguments += [source.path, "--out", destination.path]

        let result = Toolchain.run(Toolchain.sipsPath, arguments)
        guard result?.ok == true, FileManager.default.fileExists(atPath: destination.path) else {
            let detail = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw EngineError(message: detail.isEmpty ? "sips could not write \(format)" : detail)
        }
        return destination
    }

    private static func sipsName(_ format: String) -> String {
        format == "jpeg" ? "jpeg" : format
    }

    /// Loads the first frame with the EXIF orientation already applied. A
    /// photo taken sideways must not come out sideways after flattening.
    static func orientedImage(from input: URL) -> CGImage? {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if let ciImage = CIImage(contentsOf: input, options: options) {
            let context = CIContext(options: [.useSoftwareRenderer: false])
            if let image = context.createCGImage(ciImage, from: ciImage.extent) {
                return image
            }
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Flattens transparency onto white, for tools that need an opaque image.
    static func flattened(_ input: URL) throws -> URL {
        guard let image = orientedImage(from: input) else {
            throw EngineError(message: "Cannot read \(input.lastPathComponent)")
        }
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EngineError(message: "Cannot allocate an image context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else {
            throw EngineError(message: "Cannot flatten \(input.lastPathComponent)")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-\(UUID().uuidString).png")
        guard let target = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw EngineError(message: "Cannot write a temporary image")
        }
        CGImageDestinationAddImage(target, flat, nil)
        guard CGImageDestinationFinalize(target) else {
            throw EngineError(message: "Cannot write a temporary image")
        }
        return destination
    }
}
