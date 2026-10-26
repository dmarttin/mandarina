import Foundation

/// One format Mandarina knows about. `id` is what the wheel and the engines
/// use; `extensions` map a file name back to an id.
struct FormatInfo {
    let id: String
    let name: String
    let category: String
    let extensions: [String]

    var symbol: String {
        switch id {
        case "pdf": return "doc.richtext"
        case "txt", "md": return "text.alignleft"
        case "html": return "globe"
        case "epub": return "book"
        case "docx", "doc", "odt", "rtf": return "doc.text"
        case "csv", "xlsx", "xls", "ods": return "tablecells"
        case "pptx", "ppt", "odp": return "rectangle.on.rectangle"
        case "gif": return "photo.stack"
        case "mp4", "mov", "webm", "mkv", "avi", "wmv": return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "wma": return "waveform"
        default:
            // Fall back on the category, so a new format still gets a sane glyph.
            switch category {
            case "document": return "doc.text"
            case "spreadsheet": return "tablecells"
            case "presentation": return "rectangle.on.rectangle"
            case "video": return "film"
            case "audio": return "waveform"
            case "pdf": return "doc.richtext"
            default: return "photo"
            }
        }
    }
}

enum Formats {
    static let all: [FormatInfo] = [
        FormatInfo(id: "jpeg", name: "JPEG", category: "image", extensions: ["jpg", "jpeg", "jfif"]),
        FormatInfo(id: "png", name: "PNG", category: "image", extensions: ["png"]),
        FormatInfo(id: "webp", name: "WebP", category: "image", extensions: ["webp"]),
        FormatInfo(id: "heic", name: "HEIC", category: "image", extensions: ["heic", "heif"]),
        FormatInfo(id: "avif", name: "AVIF", category: "image", extensions: ["avif"]),
        FormatInfo(id: "tiff", name: "TIFF", category: "image", extensions: ["tiff", "tif"]),
        FormatInfo(id: "gif", name: "GIF", category: "image", extensions: ["gif"]),
        FormatInfo(id: "bmp", name: "BMP", category: "image", extensions: ["bmp"]),
        FormatInfo(id: "ico", name: "ICO", category: "image", extensions: ["ico"]),
        FormatInfo(id: "tga", name: "TGA", category: "image", extensions: ["tga"]),
        FormatInfo(id: "ppm", name: "PPM", category: "image", extensions: ["ppm", "pnm", "pbm", "pgm"]),
        FormatInfo(id: "qoi", name: "QOI", category: "image", extensions: ["qoi"]),
        FormatInfo(id: "svg", name: "SVG", category: "image", extensions: ["svg"]),
        FormatInfo(id: "mp4", name: "MP4", category: "video", extensions: ["mp4", "m4v"]),
        FormatInfo(id: "mov", name: "MOV", category: "video", extensions: ["mov"]),
        FormatInfo(id: "mkv", name: "MKV", category: "video", extensions: ["mkv"]),
        FormatInfo(id: "webm", name: "WebM", category: "video", extensions: ["webm"]),
        FormatInfo(id: "avi", name: "AVI", category: "video", extensions: ["avi"]),
        FormatInfo(id: "wmv", name: "WMV", category: "video", extensions: ["wmv"]),
        FormatInfo(id: "mp3", name: "MP3", category: "audio", extensions: ["mp3"]),
        FormatInfo(id: "m4a", name: "M4A", category: "audio", extensions: ["m4a", "m4r"]),
        FormatInfo(id: "wav", name: "WAV", category: "audio", extensions: ["wav"]),
        FormatInfo(id: "flac", name: "FLAC", category: "audio", extensions: ["flac"]),
        FormatInfo(id: "aac", name: "AAC", category: "audio", extensions: ["aac"]),
        FormatInfo(id: "ogg", name: "OGG", category: "audio", extensions: ["ogg", "oga"]),
        FormatInfo(id: "opus", name: "Opus", category: "audio", extensions: ["opus"]),
        FormatInfo(id: "aiff", name: "AIFF", category: "audio", extensions: ["aiff", "aif", "caf"]),
        FormatInfo(id: "wma", name: "WMA", category: "audio", extensions: ["wma"]),
        FormatInfo(id: "pdf", name: "PDF", category: "pdf", extensions: ["pdf"]),
        FormatInfo(id: "docx", name: "DOCX", category: "document", extensions: ["docx"]),
        FormatInfo(id: "doc", name: "DOC", category: "document", extensions: ["doc"]),
        FormatInfo(id: "odt", name: "ODT", category: "document", extensions: ["odt"]),
        FormatInfo(id: "rtf", name: "RTF", category: "document", extensions: ["rtf"]),
        FormatInfo(id: "txt", name: "Plain text", category: "document", extensions: ["txt", "text"]),
        FormatInfo(id: "md", name: "Markdown", category: "document", extensions: ["md", "markdown"]),
        FormatInfo(id: "html", name: "HTML", category: "document", extensions: ["html", "htm"]),
        FormatInfo(id: "epub", name: "EPUB", category: "document", extensions: ["epub"]),
        FormatInfo(id: "xlsx", name: "XLSX", category: "spreadsheet", extensions: ["xlsx"]),
        FormatInfo(id: "xls", name: "XLS", category: "spreadsheet", extensions: ["xls"]),
        FormatInfo(id: "ods", name: "ODS", category: "spreadsheet", extensions: ["ods"]),
        FormatInfo(id: "csv", name: "CSV", category: "spreadsheet", extensions: ["csv", "tsv"]),
        FormatInfo(id: "pptx", name: "PPTX", category: "presentation", extensions: ["pptx"]),
        FormatInfo(id: "ppt", name: "PPT", category: "presentation", extensions: ["ppt"]),
        FormatInfo(id: "odp", name: "ODP", category: "presentation", extensions: ["odp"])
    ]

    private static let byID: [String: FormatInfo] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    private static let byExtension: [String: String] = {
        var map: [String: String] = [:]
        for format in all {
            for ext in format.extensions {
                map[ext.lowercased()] = format.id
            }
        }
        return map
    }()

    static func info(_ id: String) -> FormatInfo {
        byID[id] ?? FormatInfo(id: id, name: id.uppercased(), category: "image", extensions: [id])
    }

    /// The format a file is already in, so same-format tools can name it.
    static func id(forExtension ext: String) -> String? {
        byExtension[ext.lowercased()]
    }

    static func fileExtension(for id: String) -> String {
        info(id).extensions.first ?? id
    }
}

struct FileKind {
    let ext: String

    init(ext: String) {
        self.ext = ext.lowercased()
    }

    /// The normalised format id, so `jpg`, `jpeg` and `jfif` agree.
    var format: String? { Formats.id(forExtension: ext) }

    private var category: String? {
        format.map { Formats.info($0).category }
    }

    var isImage: Bool {
        category == "image" || ["exr", "psd"].contains(ext)
    }
    var isVideo: Bool { category == "video" }
    var isAudio: Bool { category == "audio" }
    var isPDF: Bool { category == "pdf" || ext == "pdf" }
    var isDocument: Bool {
        category == "document" || ["pages"].contains(ext)
    }
    var isSpreadsheet: Bool {
        category == "spreadsheet" || ["numbers"].contains(ext)
    }
    var isPresentation: Bool {
        category == "presentation" || ["key"].contains(ext)
    }

    var isOffice: Bool { isDocument || isSpreadsheet || isPresentation }

    var label: String {
        if isImage { return "Image" }
        if isVideo { return "Video" }
        if isAudio { return "Audio" }
        if isPDF { return "PDF" }
        if isSpreadsheet { return "Spreadsheet" }
        if isPresentation { return "Presentation" }
        if isDocument { return "Document" }
        return "File"
    }
}
