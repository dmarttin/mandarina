import Foundation

struct ToolResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

struct DependencyStatus {
    let name: String
    let ready: Bool
    let detail: String
    let install: String
}

/// Finds the external tools Mandarina drives. ffmpeg and LibreOffice are the
/// two hard requirements; cwebp is optional and only adds WebP output when the
/// ffmpeg build in use has no libwebp.
enum Toolchain {
    static let ffmpeg: URL? = locate([
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ])

    static let soffice: URL? = locate([
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/opt/homebrew/bin/soffice",
        "/usr/local/bin/soffice"
    ])

    static let ffprobe: URL? = locate([
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe"
    ])

    static let cwebp: URL? = locate([
        "/opt/homebrew/bin/cwebp",
        "/usr/local/bin/cwebp"
    ])

    private static let sips = URL(fileURLWithPath: "/usr/bin/sips")
    static var sipsPath: URL { sips }

    private static var encodedFormats: Set<String>?
    private static let probeLock = NSLock()

    /// Encoders the local ffmpeg was built with. Probed once, on first use.
    static func has(encoder name: String) -> Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let encodedFormats { return encodedFormats.contains(name) }
        guard let ffmpeg else {
            encodedFormats = []
            return false
        }
        var found: Set<String> = []
        if let output = run(ffmpeg, ["-hide_banner", "-encoders"])?.stdout {
            for line in output.split(separator: "\n") {
                // " V....D libx264   H.264 ..." — six flag characters, then the name.
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2, fields[0].count == 6, fields[1] != "=" else { continue }
                found.insert(String(fields[1]))
            }
        }
        encodedFormats = found
        Log.write("toolchain: ffmpeg encoders \(found.count)")
        return found.contains(name)
    }

    static var ffmpegVersion: String {
        guard let ffmpeg, let output = run(ffmpeg, ["-hide_banner", "-version"])?.stdout else { return "missing" }
        return output.split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    static var sofficeVersion: String {
        guard let soffice, let output = run(soffice, ["--version"])?.stdout else { return "missing" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var status: [DependencyStatus] {
        [
            DependencyStatus(
                name: "ffmpeg",
                ready: ffmpeg != nil,
                detail: ffmpeg == nil ? "Not found" : (ffmpeg?.path ?? ""),
                install: "brew install ffmpeg"
            ),
            DependencyStatus(
                name: "LibreOffice",
                ready: soffice != nil,
                detail: soffice == nil ? "Not found, documents are hidden" : (soffice?.path ?? ""),
                install: "brew install --cask libreoffice"
            ),
            DependencyStatus(
                name: "WebP",
                ready: has(encoder: "libwebp") || cwebp != nil,
                detail: has(encoder: "libwebp") ? "libwebp in ffmpeg"
                    : (cwebp == nil ? "Needs an ffmpeg with libwebp" : "cwebp"),
                install: "brew install webp"
            )
        ]
    }

    // MARK: - Plumbling

    private static func locate(_ candidates: [String]) -> URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathVariable.split(separator: ":") {
            let name = candidates.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Runs a tool and hands back its standard output line by line, for jobs
    /// that report progress while they work.
    @discardableResult
    static func stream(_ tool: URL, _ arguments: [String],
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) -> Process? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let handle = out.fileHandleForReading
        let lock = NSLock()
        var buffer = Data()
        handle.readabilityHandler = { readable in
            let chunk = readable.availableData
            guard !chunk.isEmpty else {
                readable.readabilityHandler = nil
                return
            }
            lock.lock()
            buffer.append(chunk)
            var lines: [String] = []
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                lines.append(String(decoding: line, as: UTF8.self))
            }
            lock.unlock()
            for line in lines { onLine(line) }
        }
        process.terminationHandler = { finished in
            handle.readabilityHandler = nil
            let remaining = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if !remaining.isEmpty {
                Log.write("stream \(tool.lastPathComponent): \(remaining.suffix(200))")
            }
            onExit(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            Log.write("stream \(tool.lastPathComponent): \(error.localizedDescription)")
            handle.readabilityHandler = nil
            onExit(-1)
            return nil
        }
        return process
    }

    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval? = nil) -> ToolResult? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            Log.write("run \(tool.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            stdout = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
        }

        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                Log.write("run \(tool.lastPathComponent): timed out")
                return nil
            }
        } else {
            group.wait()
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("run \(tool.lastPathComponent): exit \(process.terminationStatus) \(message.suffix(300))")
        }
        return ToolResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}
