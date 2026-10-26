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
    // MARK: - Targets

    /// What this Mac can actually do with the file, decided by the engines that
    /// are installed right now.
    static func targets(for url: URL) -> [Target] {
        let kind = FileKind(ext: url.pathExtension)
        return candidateIDs(for: kind)
            .filter { canConvert(from: kind, to: $0) }
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
            return ["pdf", "xlsx", "xls", "ods", "csv"]
        }
        if kind.isPresentation {
            return ["pdf", "pptx", "ppt", "odp"]
        }
        if kind.isDocument {
            return ["pdf", "docx", "doc", "odt", "rtf", "txt", "html", "epub"]
        }
        return []
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
                    completion: @escaping (Bool, [URL], String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var written: [URL] = []
            var failure: String?
            for file in files {
                do {
                    written += try perform(action, on: file, suffix: suffix)
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

    private static func perform(_ action: EngineAction, on input: URL, suffix: String?) throws -> [URL] {
        let kind = FileKind(ext: input.pathExtension)
        switch action {
        case .convert(let format):
            return try convert(input, kind: kind, to: format, suffix: suffix)

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
            return [try FFmpegEngine.compressVideo(input, height: height, destination: destination)]

        case .muteVideo:
            let format = kind.isVideo ? (kind.format ?? "mp4") : "mp4"
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try FFmpegEngine.mute(input, to: format, destination: destination)]

        case .videoToGIF:
            let destination = Paths.destination(for: input, format: "gif")
            return [try FFmpegEngine.toGIF(input, destination: destination)]

        case .extractAudio(let format):
            let destination = Paths.destination(for: input, format: format)
            return [try FFmpegEngine.audio(input, to: format, destination: destination)]

        case .pdfToImages(let format, let dpi, let firstOnly):
            return try PDFEngine.render(input, to: format, dpi: dpi,
                                        firstPageOnly: firstOnly, suffix: suffix)

        case .pdfToText:
            return [try PDFEngine.text(input, destination: Paths.destination(for: input, format: "txt"))]
        }
    }

    private static func convert(_ input: URL, kind: FileKind, to format: String, suffix: String?) throws -> [URL] {
        if format == "pdf", kind.isImage {
            return [try PDFEngine.imagesToPDF([input],
                                              destination: Paths.destination(for: input, format: "pdf", suffix: suffix))]
        }
        if kind.isPDF {
            if format == "txt" {
                return [try PDFEngine.text(input, destination: Paths.destination(for: input, format: "txt", suffix: suffix))]
            }
            return try PDFEngine.render(input, to: format, dpi: 150, firstPageOnly: false, suffix: suffix)
        }
        if kind.isOffice {
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            return [try OfficeEngine.convert(input, to: format, destination: destination)]
        }
        if kind.isVideo || kind.isAudio {
            let destination = Paths.destination(for: input, format: format, suffix: suffix)
            if ["gif"].contains(format) {
                return [try FFmpegEngine.toGIF(input, destination: destination)]
            }
            if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"].contains(format) {
                return [try FFmpegEngine.audio(input, to: format, destination: destination)]
            }
            return [try FFmpegEngine.video(input, to: format, destination: destination)]
        }
        // Images to anything else.
        let destination = Paths.destination(for: input, format: format, suffix: suffix)
        if ImageEngine.canWrite(format) {
            return [try ImageEngine.convert(input, to: format, destination: destination,
                                            quality: nil, maxEdge: nil, flatten: false)]
        }
        return [try FFmpegEngine.image(input, to: format, destination: destination, quality: nil)]
    }
}
