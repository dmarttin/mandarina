import Foundation

/// Documents, spreadsheets and slides through LibreOffice's headless mode.
/// This is the one job no system framework does with any fidelity.
enum OfficeEngine {
    static var available: Bool { Toolchain.soffice != nil }

    static func convert(_ input: URL, to format: String, destination: URL) throws -> URL {
        guard let soffice = Toolchain.soffice else {
            throw EngineError(message: "LibreOffice is not installed")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-office-\(UUID().uuidString)", isDirectory: true)
        let profile = workspace.appendingPathComponent("profile", isDirectory: true)
        let output = workspace.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            throw EngineError(message: error.localizedDescription)
        }

        let filter = format == "txt" ? "txt:Text (encoded):UTF8" : format
        let arguments = [
            "-env:UserInstallation=file://\(profile.path)",
            "--headless", "--norestore", "--nolockcheck", "--nodefault",
            "--convert-to", filter,
            "--outdir", output.path,
            input.path
        ]
        let result = Toolchain.run(soffice, arguments)
        guard let result, result.ok else {
            let detail = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw EngineError(message: detail.isEmpty ? "LibreOffice failed" : String(detail.suffix(240)))
        }

        // LibreOffice names the result after the source, in the out directory.
        let expected = output.appendingPathComponent(
            "\(input.deletingPathExtension().lastPathComponent).\(Formats.fileExtension(for: format))")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            let produced = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
            guard let name = produced.first(where: { !$0.hasPrefix(".") }) else {
                throw EngineError(message: "LibreOffice wrote nothing")
            }
            return try move(output.appendingPathComponent(name), to: destination)
        }
        return try move(expected, to: destination)
    }

    private static func move(_ source: URL, to destination: URL) throws -> URL {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw EngineError(message: "Cannot write \(destination.lastPathComponent)")
        }
        return destination
    }
}
