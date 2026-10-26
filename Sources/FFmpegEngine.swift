import Foundation

/// Video, audio and the image formats ImageIO cannot write. Everything here
/// goes through ffmpeg, which Mandarina treats as a requirement.
enum FFmpegEngine {
    static var available: Bool { Toolchain.ffmpeg != nil }

    // MARK: - Capabilities

    static func canWriteImage(_ format: String) -> Bool {
        guard available else { return false }
        switch format {
        case "webp": return Toolchain.has(encoder: "libwebp") || Toolchain.cwebp != nil
        case "ppm": return Toolchain.has(encoder: "ppm")
        case "qoi": return Toolchain.has(encoder: "qoi")
        case "ico": return Toolchain.has(encoder: "ico")
        default: return false
        }
    }

    static func canProduce(_ format: String) -> Bool {
        guard available else { return false }
        switch format {
        case "mp4", "mov", "mkv": return Toolchain.has(encoder: "libx264")
        case "webm": return Toolchain.has(encoder: "libvpx-vp9")
        case "avi": return true
        case "wmv": return Toolchain.has(encoder: "wmv2")
        case "gif": return true
        case "mp3": return Toolchain.has(encoder: "libmp3lame")
        case "m4a", "aac": return Toolchain.has(encoder: "aac")
        case "wav": return Toolchain.has(encoder: "pcm_s16le")
        case "flac": return Toolchain.has(encoder: "flac")
        case "ogg": return Toolchain.has(encoder: "libvorbis") || Toolchain.has(encoder: "libopus")
        case "opus": return Toolchain.has(encoder: "libopus")
        case "aiff": return Toolchain.has(encoder: "pcm_s16be")
        default: return false
        }
    }

    // MARK: - Conversions

    static func video(_ input: URL, to format: String, destination: URL) throws -> URL {
        var arguments = ["-i", input.path]
        arguments += videoArguments(format)
        arguments += ["-pix_fmt", "yuv420p", destination.path]
        try run(arguments, expecting: destination)
        return destination
    }

    static func audio(_ input: URL, to format: String, destination: URL) throws -> URL {
        if hasAudio(input) == false {
            throw EngineError(message: "That file has no audio track")
        }
        var arguments = ["-i", input.path, "-vn", "-map", "0:a:0"]
        arguments += audioArguments(format)
        if ["m4a", "aac"].contains(format) {
            arguments += ["-b:a", "192k"]
        }
        if format == "m4a" {
            arguments += ["-movflags", "+faststart"]
        }
        arguments += [destination.path]
        try run(arguments, expecting: destination)
        return destination
    }

    static func image(_ input: URL, to format: String, destination: URL, quality: Int?) throws -> URL {
        if format == "webp", let cwebp = Toolchain.cwebp, !Toolchain.has(encoder: "libwebp") {
            let result = Toolchain.run(cwebp, ["-quiet", "-q", String(quality ?? 80),
                                               input.path, "-o", destination.path])
            guard result?.ok == true, FileManager.default.fileExists(atPath: destination.path) else {
                throw EngineError(message: result?.stderr ?? "cwebp failed")
            }
            return destination
        }
        var arguments = ["-i", input.path]
        switch format {
        case "webp": arguments += ["-c:v", "libwebp", "-q:v", String(quality ?? 80)]
        case "ppm": arguments += ["-c:v", "ppm"]
        case "qoi": arguments += ["-c:v", "qoi"]
        case "ico": arguments += ["-c:v", "ico"]
        default: throw EngineError(message: "ffmpeg cannot write \(format)")
        }
        arguments += [destination.path]
        try run(arguments, expecting: destination)
        return destination
    }

    static func toGIF(_ input: URL, destination: URL) throws -> URL {
        let filter = "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
        let arguments = ["-i", input.path, "-t", "10", "-vf", filter, "-loop", "0", destination.path]
        try run(arguments, expecting: destination)
        return destination
    }

    static func compressVideo(_ input: URL, height: Int, destination: URL) throws -> URL {
        let arguments = [
            "-i", input.path,
            "-vf", "scale=-2:\(height)",
            "-c:v", "libx264", "-crf", "26", "-preset", "veryfast",
            "-c:a", "aac", "-b:a", "160k",
            "-pix_fmt", "yuv420p",
            destination.path
        ]
        try run(arguments, expecting: destination)
        return destination
    }

    static func mute(_ input: URL, to format: String, destination: URL) throws -> URL {
        // Copying the video stream is instant; it fails when the container
        // cannot hold it, and then a transcode is the honest fallback.
        let copyAttempt = ["-i", input.path, "-an", "-c:v", "copy", destination.path]
        if let result = Toolchain.run(ffmpeg, base + copyAttempt), result.ok,
           FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        var arguments = ["-i", input.path, "-an"]
        arguments += videoArguments(format.isEmpty ? "mp4" : format)
        arguments += ["-pix_fmt", "yuv420p", destination.path]
        try run(arguments, expecting: destination)
        return destination
    }

    /// Nil when ffprobe is not installed: unknown, so try anyway.
    static func hasAudio(_ input: URL) -> Bool? {
        guard let ffprobe = Toolchain.ffprobe else { return nil }
        let result = Toolchain.run(ffprobe, [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            input.path
        ])
        guard let result, result.ok else { return nil }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Argument tables

    private static func videoArguments(_ format: String) -> [String] {
        switch format {
        case "mp4":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov", "mkv":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                    "-c:a", "aac", "-b:a", "192k"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0",
                    "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "192k"]
        case "wmv":
            return ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2"]
        default:
            return ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast"]
        }
    }

    private static func audioArguments(_ format: String) -> [String] {
        switch format {
        case "mp3": return ["-c:a", "libmp3lame"]
        case "m4a", "aac": return ["-c:a", "aac"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac"]
        case "ogg":
            return Toolchain.has(encoder: "libvorbis")
                ? ["-c:a", "libvorbis", "-b:a", "192k"]
                : ["-c:a", "libopus", "-b:a", "160k"]
        case "opus": return ["-c:a", "libopus", "-b:a", "160k"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        default: return ["-c:a", "aac"]
        }
    }

    private static var ffmpeg: URL {
        Toolchain.ffmpeg ?? URL(fileURLWithPath: "/usr/bin/false")
    }

    private static let base = ["-y", "-hide_banner", "-loglevel", "error"]

    private static func run(_ arguments: [String], expecting destination: URL) throws {
        guard Toolchain.ffmpeg != nil else {
            throw EngineError(message: "ffmpeg is not installed")
        }
        let result = Toolchain.run(ffmpeg, base + arguments)
        guard result?.ok == true, FileManager.default.fileExists(atPath: destination.path) else {
            let detail = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw EngineError(message: detail.isEmpty ? "ffmpeg failed" : String(detail.suffix(240)))
        }
    }
}
