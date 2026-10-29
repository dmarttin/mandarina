import AppKit
import CryptoKit

extension SHA256 {
    /// Digest of a file without loading it into memory.
    static func hash(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ReleaseNote {
    let version: String
    let body: String
    let dmg: URL
    let checksum: URL?
    let signature: URL?
}

/// Checks GitHub for a newer release, verifies it, and swaps the app in place.
///
/// The trust chain is TLS to GitHub, then the published checksum, then an
/// Ed25519 signature over that checksum when the release carries one. Nothing
/// is installed without asking first.
enum Updater {
    /// Releases, not the API root: one request, no paging.
    static let feed = URL(string: "https://api.github.com/repos/dmarttin/mandarina/releases/latest")!

    /// Base64 raw Ed25519 public key, set at build time by whoever owns the
    /// release signing key. Empty means releases are checksum-only.
    static let signingKey = "DO9OaH9cs6tWUeuIWQC53AEtsXTGsHw0b8kJfsbiGU8="

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updates.skipped") }
        set { UserDefaults.standard.set(newValue, forKey: "updates.skipped") }
    }

    private static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updates.lastCheck") }
    }

    // MARK: - Checking

    static func check(interactive: Bool, then completion: ((String) -> Void)? = nil) {
        if !interactive {
            guard Settings.shared.checksForUpdates else { return }
            if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        }
        lastCheck = Date()

        DispatchQueue.global(qos: .utility).async {
            do {
                let release = try latestRelease()
                DispatchQueue.main.async {
                    guard isNewer(release.version, than: currentVersion) else {
                        completion?("Mandarina \(currentVersion) is up to date")
                        if interactive { info("You are up to date", "Mandarina \(currentVersion) is the latest version.") }
                        return
                    }
                    if !interactive, release.version == skippedVersion { return }
                    completion?("Mandarina \(release.version) is available")
                    prompt(release)
                }
            } catch {
                let message = (error as? EngineError)?.message ?? error.localizedDescription
                Log.write("update: check failed \(message)")
                DispatchQueue.main.async {
                    completion?("Update check failed")
                    if interactive { info("Could not check for updates", message) }
                }
            }
        }
    }

    /// Test hook: one request, no UI, everything printed.
    static func probe(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let release = try latestRelease()
                let newer = isNewer(release.version, than: currentVersion)
                let assets = [
                    release.checksum?.lastPathComponent ?? "no-checksum",
                    release.signature?.lastPathComponent ?? "no-signature"
                ].joined(separator: ", ")
                completion("latest \(release.version) | local \(currentVersion) | newer \(newer) | \(assets)")
            } catch {
                completion("failed: \((error as? EngineError)?.message ?? error.localizedDescription)")
            }
        }
    }

    private static func latestRelease() throws -> ReleaseNote {
        let data = try fetch(feed)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let body = json["body"] as? String ?? json["name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw EngineError(message: "Unreadable release information")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ suffix: String) -> URL? {
            guard let match = assets.first(where: { ($0["name"] as? String)?.hasSuffix(suffix) == true }),
                  let path = match["browser_download_url"] as? String else { return nil }
            return URL(string: path)
        }
        guard let dmg = asset(".dmg") else {
            throw EngineError(message: "That release has no disk image")
        }
        return ReleaseNote(version: version, body: body, dmg: dmg,
                           checksum: asset(".dmg.sha256"), signature: asset(".dmg.sig"))
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(remote)
        let b = parts(local)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Prompt

    private static func prompt(_ release: ReleaseNote) {
        let alert = NSAlert()
        alert.messageText = "Mandarina \(release.version) is available"
        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? "You have \(currentVersion)."
            : String(notes.prefix(700))
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        // An accessory app can be refused focus; the prompt still has to be seen.
        alert.window.level = .floating
        alert.window.orderFrontRegardless()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            skippedVersion = release.version
            Log.write("update: skipped \(release.version)")
        default:
            break
        }
    }

    private static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        alert.runModal()
    }

    // MARK: - Install

    private static func install(_ release: ReleaseNote) {
        Log.write("update: installing \(release.version)")
        Toast.shared.show("Downloading \(release.version)…")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dmg = try download(release.dmg)
                defer { try? FileManager.default.removeItem(at: dmg) }

                let digest = try SHA256.hash(file: dmg)
                try verifyChecksum(digest, from: release.checksum)
                try verifySignature(digest, from: release.signature)

                DispatchQueue.main.async { Toast.shared.show("Verifying \(release.version)…") }
                let staged = try stage(dmg: dmg, expected: release.version)

                DispatchQueue.main.async {
                    Toast.shared.show("Installing \(release.version)…")
                    swapAndRelaunch(staged: staged)
                }
            } catch {
                let message = (error as? EngineError)?.message ?? error.localizedDescription
                Log.write("update: failed \(message)")
                DispatchQueue.main.async {
                    Toast.shared.show("Update failed")
                    info("Could not install the update", message)
                }
            }
        }
    }

    static func verifyChecksum(_ digest: String, from url: URL?) throws {
        guard let url else {
            throw EngineError(message: "That release publishes no checksum, so it cannot be verified")
        }
        let text = String(decoding: try fetch(url), as: UTF8.self)
        guard let published = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "*" }).first,
              published.count == 64 else {
            throw EngineError(message: "The published checksum is malformed")
        }
        guard published.lowercased() == digest.lowercased() else {
            throw EngineError(message: "The download does not match its published checksum")
        }
    }

    static func verifySignature(_ digest: String, from url: URL?) throws {
        guard !signingKey.hasPrefix("PUBLIC_KEY") else {
            // No key baked in: checksum only, and the user has already been asked.
            return
        }
        guard let url else {
            throw EngineError(message: "This release is unsigned and cannot be installed automatically")
        }
        let encoded = String(decoding: try fetch(url), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: encoded),
              let rawKey = Data(base64Encoded: signingKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            throw EngineError(message: "The signature on this release is unreadable")
        }
        guard key.isValidSignature(signature, for: Data(digest.utf8)) else {
            throw EngineError(message: "The signature on this release is not valid")
        }
    }

    /// Mounts the image, checks the app inside, and copies it somewhere the
    /// swap can use after this process is gone.
    static func stage(dmg: URL, expected: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        let attach = Toolchain.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                   ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                    "-mountpoint", mount.path, dmg.path], timeout: 120)
        guard attach?.ok == true else {
            throw EngineError(message: "Could not open the downloaded disk image")
        }
        defer {
            _ = Toolchain.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                              ["detach", mount.path, "-force"], timeout: 60)
        }

        let app = mount.appendingPathComponent("Mandarina.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw EngineError(message: "The disk image does not contain Mandarina")
        }
        let info = app.appendingPathComponent("Contents/Info.plist")
        let version = NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String
        guard version == expected else {
            throw EngineError(message: "The download says \(version ?? "nothing") but the release says \(expected)")
        }
        let verify = Toolchain.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                   ["--verify", "--strict", app.path], timeout: 120)
        guard verify?.ok == true else {
            throw EngineError(message: "The downloaded app is not correctly signed")
        }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let copy = Toolchain.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                 [app.path, staged.appendingPathComponent("Mandarina.app").path], timeout: 180)
        guard copy?.ok == true else {
            throw EngineError(message: "Could not copy the new version")
        }
        return staged.appendingPathComponent("Mandarina.app")
    }

    // MARK: - Swap

    /// Replaces the running bundle once this process exits, restoring the old
    /// one if the copy fails. The script is a file, not a command string.
    static func swapAndRelaunch(staged: URL) {
        let destination = ProcessInfo.processInfo.environment["MANDARINA_UPDATE_DEST"]
            ?? Bundle.main.bundleURL.path
        guard FileManager.default.isWritableFile(atPath: destination) else {
            info("Move Mandarina to Applications",
                 "Mandarina can only update itself from a folder you can write to, such as Applications.")
            return
        }
        let script = """
        #!/bin/sh
        set -eu
        target="\(destination)"
        staged="\(staged.path)"
        backup="$staged.backup"
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 \\
                31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
          pgrep -x Mandarina >/dev/null 2>&1 || break
          sleep 0.2
        done
        /usr/bin/ditto "$target" "$backup" || true
        if /usr/bin/ditto "$staged" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
          /usr/bin/open "$target"
        else
          /usr/bin/ditto "$backup" "$target" || true
        fi
        rm -rf "$staged" "$backup"
        rm -f "$0"
        """

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        } catch {
            info("Could not install the update", error.localizedDescription)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        do {
            try process.run()
        } catch {
            info("Could not install the update", error.localizedDescription)
            return
        }
        Log.write("update: handing over to the swap script, quitting")
        NSApp.terminate(nil)
    }

    // MARK: - Plumbing

    private static func fetch(_ url: URL) throws -> Data {
        guard url.scheme == "https", let host = url.host,
              host == "api.github.com" || host.hasSuffix("github.com")
                || host.hasSuffix("githubusercontent.com") else {
            throw EngineError(message: "Refusing to contact \(url.host ?? "an unknown host")")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(EngineError(message: "GitHub answered \(http.statusCode)"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        session.invalidateAndCancel()
        guard let result else {
            throw EngineError(message: "No answer from GitHub")
        }
        return try result.get()
    }

    private static func download(_ url: URL) throws -> URL {
        let data = try fetch(url)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mandarina-\(UUID().uuidString).dmg")
        try data.write(to: file)
        return file
    }
}
