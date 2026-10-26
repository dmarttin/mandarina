import Foundation

enum WheelMode: Int, CaseIterable {
    case convert
    case tools
    case actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    /// The key that opens this wheel, read live so Settings applies at once.
    var modifier: ModifierKey { Settings.shared.modifier(for: self) }

    var modifierHint: String { modifier.hint }

    var emptyMessage: String {
        switch self {
        case .convert: return "No conversion"
        case .tools: return "No tool"
        case .actions: return "No action"
        }
    }
}

struct WheelItem {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    /// Arguments handed to convt when the item is applied.
    let arguments: [String]
    let kind: Kind
    /// Added to the output name, for tools that keep the file's own format.
    var suffix: String? = nil

    enum Kind {
        case conversion
        case tool
        case action
    }

    static func conversion(_ option: ConvtOption) -> WheelItem {
        WheelItem(
            id: option.id,
            title: option.name,
            detail: option.category.capitalized,
            symbol: symbol(for: option.category, id: option.id),
            arguments: ["--to", option.id],
            kind: .conversion
        )
    }

    static func symbol(for category: String, id: String = "") -> String {
        switch id {
        case "pdf": return "doc.richtext"
        case "txt", "md": return "text.alignleft"
        case "html": return "globe"
        case "epub": return "book"
        case "csv", "xlsx", "xls", "ods": return "tablecells"
        case "pptx", "ppt", "odp": return "rectangle.on.rectangle"
        case "gif": return "photo.stack"
        case "mp4", "mov", "webm", "mkv", "avi": return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus": return "waveform"
        default: break
        }
        switch category.lowercased() {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        case "pdf": return "doc.richtext"
        case "document": return "doc.text"
        case "spreadsheet": return "tablecells"
        case "presentation": return "rectangle.on.rectangle"
        default: return "arrow.right.doc.on.clipboard"
        }
    }
}

enum WheelCatalog {
    static let maxConversions = 8

    static func conversions(for files: [URL]) -> [WheelItem] {
        guard let first = files.first else { return [] }
        let kind = FileKind(ext: first.pathExtension.lowercased())
        let options = Convt.targets(for: first).sorted { left, right in
            let a = rank(left, kind), b = rank(right, kind)
            return a == b ? left.name < right.name : a < b
        }
        return options.prefix(maxConversions).map(WheelItem.conversion)
    }

    /// Winsorised rank: what this kind of file usually becomes, first.
    private static func rank(_ option: ConvtOption, _ kind: FileKind) -> Int {
        let order: [String]
        if kind.isDocument {
            order = ["pdf", "docx", "txt", "md", "html", "epub", "rtf", "odt",
                     "png", "jpeg", "webp", "tiff", "heic", "avif", "gif"]
        } else if kind.isImage {
            order = ["png", "jpeg", "webp", "pdf", "heic", "avif", "tiff", "gif",
                     "bmp", "svg", "ico", "tga", "qoi", "exr", "ppm"]
        } else if kind.isVideo {
            order = ["mp4", "mov", "webm", "mkv", "gif", "avi", "mp3", "wav", "m4a"]
        } else if kind.isAudio {
            order = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff"]
        } else if kind.isPDF {
            order = ["png", "jpeg", "docx", "pptx", "xlsx", "txt", "md", "html", "epub"]
        } else {
            order = ["pdf", "png", "jpeg", "webp", "mp4", "mp3", "txt"]
        }
        return order.firstIndex(of: option.id) ?? order.count
    }

    static func tools(for files: [URL]) -> [WheelItem] {
        guard let first = files.first else { return [] }
        let ext = first.pathExtension.lowercased()
        let kind = FileKind(ext: ext)
        // Same-format tools must name the format explicitly.
        let same = Convt.formatId(forExtension: ext) ?? ext
        var items: [WheelItem] = []

        if kind.isImage || kind.isVideo {
            items.append(WheelItem(
                id: "compress",
                title: "Compress",
                detail: kind.isImage ? "Quality 60" : "1080p",
                symbol: "arrow.down.right.and.arrow.up.left",
                arguments: kind.isImage
                    ? ["--to", same, "--quality", "60"]
                    : ["--to", same, "--video-height", "1080"],
                kind: .tool,
                suffix: kind.isImage ? "-compressed" : "-1080"
            ))
        }
        if kind.isImage {
            items.append(WheelItem(
                id: "resize", title: "Resize", detail: "1920 px",
                symbol: "arrow.up.left.and.arrow.down.right",
                arguments: ["--to", same, "--max-size", "1920"],
                kind: .tool, suffix: "-1920"
            ))
            items.append(WheelItem(
                id: "thumbnail", title: "Thumbnail", detail: "512 px",
                symbol: "square.resize",
                arguments: ["--to", same, "--max-size", "512"],
                kind: .tool, suffix: "-512"
            ))
            items.append(WheelItem(
                id: "flatten", title: "Flatten", detail: "White background",
                symbol: "square.on.square",
                arguments: ["--to", same, "--background", "white"],
                kind: .tool, suffix: "-flat"
            ))
        }
        if kind.isVideo {
            items.append(WheelItem(
                id: "mute", title: "Mute", detail: "Drop audio",
                symbol: "speaker.slash",
                arguments: ["--to", same, "--no-audio"],
                kind: .tool, suffix: "-muted"
            ))
            items.append(WheelItem(
                id: "audio-only", title: "Audio only", detail: "MP3",
                symbol: "music.note",
                arguments: ["--to", "mp3"], kind: .tool
            ))
            items.append(WheelItem(
                id: "gif", title: "GIF", detail: "Short loop",
                symbol: "photo.stack",
                arguments: ["--to", "gif"], kind: .tool
            ))
        }
        if kind.isPDF {
            items.append(WheelItem(
                id: "pages", title: "First page", detail: "PNG",
                symbol: "1.square",
                arguments: ["--to", "png", "--pages", "1"], kind: .tool
            ))
            items.append(WheelItem(
                id: "pages300", title: "Print quality", detail: "PNG 300 DPI",
                symbol: "printer",
                arguments: ["--to", "png", "--dpi", "300"],
                kind: .tool, suffix: "-300dpi"
            ))
            items.append(WheelItem(
                id: "text", title: "Plain text", detail: "TXT",
                symbol: "text.alignleft",
                arguments: ["--to", "txt"], kind: .tool
            ))
        }
        if kind.isDocument {
            items.append(WheelItem(
                id: "to-pdf", title: "PDF", detail: "Document",
                symbol: "doc.richtext",
                arguments: ["--to", "pdf"], kind: .tool
            ))
            items.append(WheelItem(
                id: "to-txt", title: "Plain text", detail: "TXT",
                symbol: "text.alignleft",
                arguments: ["--to", "txt"], kind: .tool
            ))
        }
        return items
    }

    static func actions(for files: [URL]) -> [WheelItem] {
        [
            WheelItem(id: "copy-path", title: "Copy path", detail: "To clipboard",
                      symbol: "link", arguments: [], kind: .action),
            WheelItem(id: "copy-file", title: "Copy file", detail: "To clipboard",
                      symbol: "doc.on.doc", arguments: [], kind: .action),
            WheelItem(id: "reveal", title: "Reveal", detail: "In Finder",
                      symbol: "folder", arguments: [], kind: .action),
            WheelItem(id: "terminal", title: "Terminal", detail: "Open here",
                      symbol: "terminal", arguments: [], kind: .action),
            WheelItem(id: "airdrop", title: "AirDrop", detail: "Share",
                      symbol: "airplayaudio", arguments: [], kind: .action),
            WheelItem(id: "zip", title: "ZIP", detail: "Archive",
                      symbol: "archivebox", arguments: [], kind: .action)
        ]
    }

    static func items(mode: WheelMode, files: [URL]) -> [WheelItem] {
        switch mode {
        case .convert: return conversions(for: files)
        case .tools: return tools(for: files)
        case .actions: return actions(for: files)
        }
    }
}

struct FileKind {
    let ext: String

    var isImage: Bool {
        ["png", "jpg", "jpeg", "jfif", "webp", "heic", "heif", "avif", "tiff", "bmp", "gif", "svg", "ico", "tga", "qoi", "exr"]
            .contains(ext)
    }
    var isVideo: Bool { ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v"].contains(ext) }
    var isAudio: Bool { ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "wma"].contains(ext) }
    var isPDF: Bool { ext == "pdf" }
    var isDocument: Bool {
        ["docx", "doc", "odt", "rtf", "rtfd", "txt", "md", "markdown", "html", "htm", "epub", "pages"]
            .contains(ext)
    }
}
