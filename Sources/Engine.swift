import Foundation

/// What the wheel can ask an engine to do.
enum EngineAction {
    case convert(String)
    case compressImage(quality: Int)
    case resizeImage(maxEdge: Int)
    case flattenImage
    case compressVideo(height: Int)
    case muteVideo
    case videoToGIF
    case extractAudio(String)
    case pdfToImages(format: String, dpi: Int, firstPageOnly: Bool)
    case pdfToText
}

struct Target {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: EngineAction
    /// Appended to the output name for jobs that keep the source format.
    var suffix: String?
}

struct EngineError: Error {
    let message: String
}

enum Paths {
    static func destination(for input: URL, format: String, suffix: String? = nil) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let name = "\(stem)\(suffix ?? "").\(Formats.fileExtension(for: format))"
        return unique(directory.appendingPathComponent(name))
    }

    /// Never overwrite: `photo.png` becomes `photo 2.png`.
    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while counter < 1000 {
            let candidate = directory.appendingPathComponent("\(stem) \(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
        return url
    }
}

enum Engine {
    // MARK: - What the wheel offers

    static func targets(for url: URL) -> [Target] {
        let kind = FileKind(ext: url.pathExtension)
        guard let start = kind.format else { return [] }
        return candidateIDs(for: kind)
            .filter { $0 != start && reachable(from: start, to: $0) }
            .map { id in
                let info = Formats.info(id)
                return Target(id: id, title: info.name, detail: kind.label,
                              symbol: info.symbol, action: .convert(id))
            }
    }

    static func tools(for url: URL) -> [Target] {
        let kind = FileKind(ext: url.pathExtension)
        var items: [Target] = []

        if kind.isImage, Formats.id(forExtension: url.pathExtension) != nil {
            items.append(Target(id: "compress", title: "Compress", detail: "Quality 60",
                                symbol: "arrow.down.right.and.arrow.up.left",
                                action: .compressImage(quality: 60), suffix: "-compressed"))
            items.append(Target(id: "resize", title: "Resize", detail: "1920 px",
                                symbol: "arrow.up.left.and.arrow.down.right",
                                action: .resizeImage(maxEdge: 1920), suffix: "-1920"))
            items.append(Target(id: "thumbnail", title: "Thumbnail", detail: "512 px",
                                symbol: "square.resize",
                                action: .resizeImage(maxEdge: 512), suffix: "-512"))
            items.append(Target(id: "flatten", title: "Flatten", detail: "White background",
                                symbol: "square.on.square",
                                action: .flattenImage, suffix: "-flat"))
        }
        if kind.isVideo, FFmpegEngine.available {
            items.append(Target(id: "compress", title: "Compress", detail: "1080p",
                                symbol: "arrow.down.right.and.arrow.up.left",
                                action: .compressVideo(height: 1080), suffix: "-1080"))
            items.append(Target(id: "mute", title: "Mute", detail: "Drop audio",
                                symbol: "speaker.slash",
                                action: .muteVideo, suffix: "-muted"))
            if FFmpegEngine.canProduce("mp3") {
                items.append(Target(id: "audio-only", title: "Audio only", detail: "MP3",
                                    symbol: "music.note", action: .extractAudio("mp3")))
            }
            items.append(Target(id: "gif", title: "GIF", detail: "Short loop",
                                symbol: "photo.stack", action: .videoToGIF))
        }
        if kind.isPDF {
            items.append(Target(id: "pages", title: "First page", detail: "PNG",
                                symbol: "1.square",
                                action: .pdfToImages(format: "png", dpi: 150, firstPageOnly: true)))
            items.append(Target(id: "pages300", title: "Print quality", detail: "PNG 300 DPI",
                                symbol: "printer",
                                action: .pdfToImages(format: "png", dpi: 300, firstPageOnly: false),
                                suffix: "-300dpi"))
            items.append(Target(id: "text", title: "Plain text", detail: "TXT",
                                symbol: "text.alignleft", action: .pdfToText))
        }
        if kind.isOffice, OfficeEngine.available {
            items.append(Target(id: "to-pdf", title: "PDF", detail: "Document",
                                symbol: "doc.richtext", action: .convert("pdf")))
            items.append(Target(id: "to-txt", title: "Plain text", detail: "TXT",
                                symbol: "text.alignleft", action: .convert("txt")))
        }
        return items
    }

    private static func candidateIDs(for kind: FileKind) -> [String] {
        if kind.isImage {
            return ["png", "jpeg", "webp", "pdf", "heic", "avif", "tiff", "gif", "bmp", "ppm", "tga", "qoi"]
        }
        if kind.isVideo {
            return ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav", "flac", "opus"]
        }
        if kind.isAudio {
            return ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"]
        }
        if kind.isPDF {
            return ["png", "jpeg", "txt"]
        }
        if kind.isSpreadsheet {
            return ["pdf", "xlsx", "xls", "ods", "csv", "png", "jpeg"]
        }
        if kind.isPresentation {
            return ["pdf", "pptx", "ppt", "odp", "png", "jpeg"]
        }
        if kind.isDocument {
            return ["pdf", "docx", "doc", "odt", "rtf", "txt", "html", "epub", "png", "jpeg"]
        }
        return []
    }

    // MARK: - Routes

    /// Direct when an engine can do it, otherwise one intermediate format.
    /// `document.pdf` is what lets a deck become a PNG.
    static func reachable(from start: String, to goal: String) -> Bool {
        if canConvert(from: FileKind(ext: Formats.fileExtension(for: start)), to: goal) {
            return true
        }
        return path(from: start, to: goal) != nil
    }

    static func path(from start: String, to goal: String, maxHops: Int = 2) -> [String]? {
        guard start != goal else { return [start] }
        var queue: [[String]] = [[start]]
        var seen: Set<String> = [start]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let tail = current.last, current.count <= maxHops else { continue }
            for next in neighbours(of: tail) where !seen.contains(next) {
                if next == goal { return current + [next] }
                seen.insert(next)
                queue.append(current + [next])
            }
        }
        return nil
    }

    private static func neighbours(of format: String) -> [String] {
        let kind = FileKind(ext: Formats.fileExtension(for: format))
        return Formats.all.map(\.id).filter { canConvert(from: kind, to: $0) }
    }

    static func canConvert(from kind: FileKind, to format: String) -> Bool {
        if format == kind.format { return false }
        if format == "pdf" {
            if kind.isImage { return true }
            if kind.isOffice { return OfficeEngine.available }
            return false
        }
        if kind.isPDF, ["png", "jpeg", "txt"].contains(format) { return PDFEngine.available }
        if ["png", "jpeg", "heic", "avif", "tiff", "gif", "bmp", "tga", "exr"].contains(format) {
            return ImageEngine.canWrite(format) || FFmpegEngine.canWriteImage(format)
        }
        if ["webp", "ppm", "qoi", "ico"].contains(format) {
            return FFmpegEngine.canWriteImage(format)
        }
        if ["mp4", "mov", "mkv", "webm", "avi", "wmv"].contains(format) {
            return FFmpegEngine.canProduce(format)
        }
        if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"].contains(format) {
            return FFmpegEngine.canProduce(format)
        }
        if ["docx", "doc", "odt", "rtf", "txt", "html", "epub", "xlsx", "xls", "ods", "csv", "pptx", "ppt", "odp"].contains(format) {
            return kind.isOffice && OfficeEngine.available
        }
        return false
    }

    // MARK: - Running

    static func run(_ action: EngineAction, suffix: String?, files: [URL],
                    progress: ((Double) -> Void)? = nil,
                    completion: @escaping (Bool, [URL], String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var written: [URL] = []
            var failure: String?
            for (index, file) in files.enumerated() {
                let share: (Double) -> Void = { fraction in
                    guard let progress, !files.isEmpty else { return }
                    let base = Double(index) / Double(files.count)
                    progress(base + fraction / Double(files.count))
                }
                do {
                    written += try perform(action, on: file, suffix: suffix, progress: share)
                } catch let error as EngineError {
                    failure = error.message
                    break
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            DispatchQueue.main.async {
                if let failure {
                    completion(false, written, failure)
                } else if written.isEmpty {
                    completion(false, [], "Nothing was written")
                } else {
                    completion(true, written, "")
                }
            }
        }
    }

    private static func perform(_ action: EngineAction, on input: URL, suffix: String?,
                                progress: @escaping (Double) -> Void) throws -> [URL] {
        let kind = FileKind(ext: input.pathExtension)
        switch action {
        case .convert(let format):
            return try convert(input, kind: kind, to: format, suffix: suffix, progress: progress)

        case .compressImage(let quality):
            let format = kind.format ?? "jpeg"
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try ImageEngine.convert(input, to: format, destination: destination,
                                            quality: quality, maxEdge: nil, flatten: false)]

        case .resizeImage(let maxEdge):
            let format = kind.format ?? "jpeg"
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try ImageEngine.convert(input, to: format, destination: destination,
                                            quality: nil, maxEdge: maxEdge, flatten: false)]

        case .flattenImage:
            let format = kind.format ?? "png"
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try ImageEngine.convert(input, to: format, destination: destination,
                                            quality: nil, maxEdge: nil, flatten: true)]

        case .compressVideo(let height):
            let destination = Paths.destination(for: input, format: "mp4", suffix: suffix)
            return [try FFmpegEngine.compressVideo(input, height: height, destination: destination,
                                                   progress: progress)]

        case .muteVideo:
            let format = kind.isVideo ? (kind.format ?? "mp4") : "mp4"
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try FFmpegEngine.mute(input, to: format, destination: destination)]

        case .videoToGIF:
            let destination = Paths.destination(for: input, format: "gif")
            return [try FFmpegEngine.toGIF(input, destination: destination)]

        case .extractAudio(let format):
            let destination = Paths.destination(for: input, format: format)
            progress(0)
            return [try FFmpegEngine.audio(input, to: format, destination: destination,
                                           progress: progress)]

        case .pdfToImages(let format, let dpi, let firstOnly):
            return try PDFEngine.render(input, to: format, dpi: dpi,
                                        firstPageOnly: firstOnly, suffix: suffix,
                                        progress: progress)

        case .pdfToText:
            return [try PDFEngine.text(input, destination: Paths.destination(for: input, format: "txt"))]
        }
    }

    private static func convert(_ input: URL, kind: FileKind, to format: String,
                                suffix: String?, progress: @escaping (Double) -> Void) throws -> [URL] {
        if canConvert(from: kind, to: format) {
            return try direct(input, kind: kind, to: format,
                              destination: Paths.destination(for: input, format: format, suffix: suffix),
                              nameSource: input, progress: progress)
        }
        guard let start = kind.format, let steps = path(from: start, to: format) else {
            throw EngineError(message: "No route from \(kind.label) to \(format)")
        }
        return try chain(input, kind: kind, steps: steps, suffix: suffix, progress: progress)
    }

    /// Runs one format conversion with the destination already decided.
    private static func direct(_ input: URL, kind: FileKind, to format: String,
                               destination: URL, nameSource: URL,
                               progress: @escaping (Double) -> Void) throws -> [URL] {
        if format == "pdf", kind.isImage {
            return [try PDFEngine.imagesToPDF([input], destination: destination)]
        }
        if kind.isPDF {
            if format == "txt" {
                return [try PDFEngine.text(input, destination: destination)]
            }
            return try PDFEngine.render(input, to: format, dpi: 150, firstPageOnly: false,
                                        suffix: nil, nameSource: nameSource, progress: progress)
        }
        if kind.isOffice {
            return [try OfficeEngine.convert(input, to: format, destination: destination)]
        }
        if kind.isVideo || kind.isAudio {
            if format == "gif" {
                return [try FFmpegEngine.toGIF(input, destination: destination)]
            }
            if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"].contains(format) {
                return [try FFmpegEngine.audio(input, to: format, destination: destination,
                                               progress: progress)]
            }
            return [try FFmpegEngine.video(input, to: format, destination: destination,
                                           progress: progress)]
        }
        if ImageEngine.canWrite(format) {
            return [try ImageEngine.convert(input, to: format, destination: destination,
                                            quality: nil, maxEdge: nil, flatten: false)]
        }
        return [try FFmpegEngine.image(input, to: format, destination: destination, quality: nil)]
    }

    /// Two hops through a temporary directory, for example a deck to PDF to PNG.
    private static func chain(_ input: URL, kind: FileKind, steps: [String],
                              suffix: String?, progress: @escaping (Double) -> Void) throws -> [URL] {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-chain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var current = input
        var currentKind = kind
        for (index, step) in steps.enumerated() {
            let isLast = index == steps.count - 1
            let destination = isLast
                ? Paths.destination(for: input, format: step, suffix: suffix)
                : workspace.appendingPathComponent("\(index).\(Formats.fileExtension(for: step))")
            let share: (Double) -> Void = { fraction in
                progress((Double(index) + fraction) / Double(steps.count))
            }
            let outputs = try direct(current, kind: currentKind, to: step,
                                     destination: destination, nameSource: input, progress: share)
            guard isLast == false else { return outputs }
            guard let next = outputs.first else {
                throw EngineError(message: "The \(step) step wrote nothing")
            }
            current = next
            currentKind = FileKind(ext: Formats.fileExtension(for: step))
        }
        return []
    }
}
