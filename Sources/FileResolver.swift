import AppKit

/// Where the files under the cursor come from. Finder publishes the items being
/// dragged on the global drag pasteboard, so a monitor can read them without
/// asking Finder, which is busy inside its own drag loop.
enum FileResolver {
    /// Files on the drag pasteboard. The pasteboard keeps its last contents
    /// after a drag ends, so pass the change count seen while idle: anything
    /// that has not moved since then is not part of the drag in progress.
    static func draggedFiles(idleChangeCount: Int? = nil) -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        if let idleChangeCount, pasteboard.changeCount == idleChangeCount {
            return []
        }
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) else {
            return []
        }
        return items
            .compactMap { $0 as? URL }
            .filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The Finder selection, for when the wheel is opened from the keyboard.
    /// Finder does not answer while a drag is running, so the lookup is capped
    /// instead of blocking the caller.
    static func finderSelection(timeout: TimeInterval = 1.2) -> [URL] {
        let script = """
        tell application "Finder" to get POSIX path of (selection as alias list)
        """
        guard let output = runProcess(
            "/usr/bin/osascript",
            ["-e", script],
            timeout: timeout
        ) else { return [] }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func runProcess(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Log.write("resolver: osascript timed out")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
