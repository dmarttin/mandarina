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
    enum Kind {
        case conversion
        case tool
        case action
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let kind: Kind
    /// Nil for the file actions, which Mandarina performs itself.
    var action: EngineAction?
    /// Appended to the output name, for jobs that keep the source format.
    var suffix: String?

    init(id: String, title: String, detail: String, symbol: String, kind: Kind,
         action: EngineAction? = nil, suffix: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.kind = kind
        self.action = action
        self.suffix = suffix
    }
}

enum WheelCatalog {
    static let maxConversions = 8

    static func conversions(for files: [URL]) -> [WheelItem] {
        guard let first = files.first else { return [] }
        return Engine.targets(for: first).prefix(maxConversions).map { target in
            WheelItem(id: target.id, title: target.title, detail: target.detail,
                      symbol: target.symbol, kind: .conversion,
                      action: target.action, suffix: target.suffix)
        }
    }

    static func tools(for files: [URL]) -> [WheelItem] {
        guard let first = files.first else { return [] }
        return Engine.tools(for: first).map { target in
            WheelItem(id: target.id, title: target.title, detail: target.detail,
                      symbol: target.symbol, kind: .tool,
                      action: target.action, suffix: target.suffix)
        }
    }

    static func actions(for files: [URL]) -> [WheelItem] {
        [
            WheelItem(id: "copy-path", title: "Copy path", detail: "To clipboard",
                      symbol: "link", kind: .action),
            WheelItem(id: "copy-file", title: "Copy file", detail: "To clipboard",
                      symbol: "doc.on.doc", kind: .action),
            WheelItem(id: "reveal", title: "Reveal", detail: "In Finder",
                      symbol: "folder", kind: .action),
            WheelItem(id: "terminal", title: "Terminal", detail: "Open here",
                      symbol: "terminal", kind: .action),
            WheelItem(id: "airdrop", title: "AirDrop", detail: "Share",
                      symbol: "airplayaudio", kind: .action),
            WheelItem(id: "zip", title: "ZIP", detail: "Archive",
                      symbol: "archivebox", kind: .action)
        ]
    }

    static func items(mode: WheelMode, files: [URL]) -> [WheelItem] {
        switch mode {
        case .convert: return conversions(for: files)
        case .tools: return tools(for: files)
        case .actions: return actions(for: files)
        }
    }

    /// What to say in the hub when a wheel has nothing to offer.
    static func emptyReason(mode: WheelMode, files: [URL]) -> String {
        guard mode == .convert, let first = files.first else { return mode.emptyMessage }
        let kind = FileKind(ext: first.pathExtension)
        if kind.isOffice, !OfficeEngine.available { return "LibreOffice missing" }
        if kind.isVideo || kind.isAudio, !FFmpegEngine.available { return "ffmpeg missing" }
        return mode.emptyMessage
    }
}
