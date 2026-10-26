import Foundation

struct ConvtOption: Hashable {
    let id: String
    let name: String
    let category: String
}

enum Convt {
    /// convt ships its CLI inside the app bundle; keep the same lookup order the
    /// Finder extension uses: the app, then Homebrew, then PATH.
    static let binary: URL? = {
        var candidates = [
            "/Applications/convt.app/Contents/MacOS/convt",
            "/opt/homebrew/bin/convt",
            "/usr/local/bin/convt"
        ]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/convt")
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    // MARK: - Formats

    private static var formats: [String: ConvtOption] = [:]
    private static var extensionMap: [String: String] = [:]
    private static var formatsLoaded = false

    static func loadFormatsIfNeeded() {
        guard !formatsLoaded else { return }
        formatsLoaded = true
        guard let (status, output) = capture(["formats", "--json"]), status == 0,
              let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Log.write("formats: could not read convt formats --json")
            return
        }
        for entry in raw {
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { continue }
            let category = entry["category"] as? String ?? "other"
            formats[id] = ConvtOption(id: id, name: name, category: category)
            for ext in entry["extensions"] as? [String] ?? [] {
                extensionMap[ext.lowercased()] = id
            }
        }
        Log.write("formats: loaded \(formats.count)")
    }

    /// Format id for a file extension, so a tool can ask for the same format
    /// the file already has ("jpg" is "jpeg" to convt).
    static func formatId(forExtension ext: String) -> String? {
        loadFormatsIfNeeded()
        return extensionMap[ext.lowercased()]
    }

    static func option(for id: String) -> ConvtOption {
        if let known = formats[id] { return known }
        return ConvtOption(id: id, name: id.uppercased(), category: categoryGuess(id))
    }

    private static func categoryGuess(_ id: String) -> String {
        switch id {
        case "mp4", "mov", "mkv", "webm", "avi", "gif": return "video"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff": return "audio"
        case "pdf": return "pdf"
        case "docx", "docx2", "doc", "odt", "rtf", "txt", "html", "md", "epub": return "document"
        case "xlsx", "xls", "ods", "csv": return "spreadsheet"
        case "pptx", "ppt", "odp": return "presentation"
        default: return "image"
        }
    }

    // MARK: - Targets

    private static var targetCache: [String: [ConvtOption]] = [:]
    private static let cacheLock = NSLock()

    /// The formats the wheel offers for a file, most useful first.
    static func targets(for url: URL, menuOnly: Bool = false) -> [ConvtOption] {
        let key = "\(url.pathExtension.lowercased())|\(menuOnly)"
        cacheLock.lock()
        if let cached = targetCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var args = ["targets", url.path, "--menu"]
        if !menuOnly { args = ["targets", url.path] }
        guard let (status, output) = capture(args), status == 0 else {
            Log.write("targets: \(args.joined(separator: " ")) failed")
            return []
        }
        let ids = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        let options = ids.map { option(for: $0) }.sorted(by: preference)
        cacheLock.lock()
        targetCache[key] = options
        cacheLock.unlock()
        return options
    }

    private static let preferred = [
        "pdf", "png", "jpeg", "webp", "heic", "avif", "gif", "tiff", "svg",
        "mp4", "mov", "webm", "mkv", "mp3", "m4a", "wav", "flac",
        "docx", "txt", "md", "html", "epub", "csv", "xlsx", "pptx"
    ]

    private static func preference(_ a: ConvtOption, _ b: ConvtOption) -> Bool {
        let ia = preferred.firstIndex(of: a.id) ?? preferred.count
        let ib = preferred.firstIndex(of: b.id) ?? preferred.count
        if ia != ib { return ia < ib }
        return a.name < b.name
    }

    // MARK: - Converting

    struct Job {
        let files: [URL]
        let arguments: [String]
        let label: String
        /// Appended to the output name, for tools that keep the format.
        var suffix: String?
    }

    struct Output {
        let input: URL
        let files: [URL]
    }

    /// Runs a conversion off the main thread and reports the files written.
    static func run(_ job: Job, completion: @escaping (Bool, [Output], String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var arguments = job.files.map(\.path) + job.arguments
            var staging: URL?
            if job.suffix != nil {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mandarina-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                staging = directory
                arguments += ["-o", directory.path]
            }
            arguments.append("--json")
            Log.write("run: convt \(arguments.joined(separator: " "))")
            guard let (status, output) = capture(arguments) else {
                DispatchQueue.main.async { completion(false, [], "convt not found") }
                return
            }

            var results: [Output] = []
            var failure: String?
            for line in output.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = event["event"] as? String
                else { continue }
                if kind == "done",
                   let input = event["input"] as? String,
                   let outputs = event["outputs"] as? [String] {
                    results.append(Output(input: URL(fileURLWithPath: input),
                                          files: outputs.map { URL(fileURLWithPath: $0) }))
                }
                if kind == "failed" || kind == "error" {
                    failure = (event["error"] as? String) ?? "Conversion failed"
                }
            }

            if let suffix = job.suffix, let staging {
                for index in results.indices {
                    let result = results[index]
                    let moved = result.files.map { file -> URL in
                        let stem = result.input.deletingPathExtension().lastPathComponent
                        let destination = uniqueURL(
                            result.input.deletingLastPathComponent()
                                .appendingPathComponent("\(stem)\(suffix).\(file.pathExtension)")
                        )
                        do {
                            try FileManager.default.moveItem(at: file, to: destination)
                            return destination
                        } catch {
                            Log.write("move: \(error.localizedDescription)")
                            return file
                        }
                    }
                    results[index] = Output(input: result.input, files: moved)
                }
                try? FileManager.default.removeItem(at: staging)
            }

            let written = results.flatMap(\.files)
            Log.write("run: status \(status), outputs \(written.count)")
            DispatchQueue.main.async {
                if let failure {
                    completion(false, results, failure)
                } else {
                    completion(status == 0 && !written.isEmpty, results, output)
                }
            }
        }
    }

    /// Keeps an existing file, the way convt does, instead of overwriting it.
    static func uniqueURL(_ url: URL) -> URL {
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

    // MARK: - Process plumbing

    static func capture(_ args: [String]) -> (Int32, String)? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            Log.write("capture: \(error.localizedDescription)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
