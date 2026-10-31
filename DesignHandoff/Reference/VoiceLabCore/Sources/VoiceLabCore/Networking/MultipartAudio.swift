import Foundation

/// File-backed multipart keeps memory usage bounded even for 500 MiB imports.
struct MultipartAudio {
    static let maximumFileBytes = 500 * 1024 * 1024
    let url: URL
    let contentType: String
    init(file: URL, language: DictationLanguage) throws {
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0 else {
            throw VoiceLabError.emptyAudio
        }
        guard size <= Self.maximumFileBytes else { throw VoiceLabError.audioTooLarge }
        let types = [
            "wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac",
            "ogg": "audio/ogg", "webm": "audio/webm", "flac": "audio/flac", "aiff": "audio/aiff",
            "caf": "audio/caf",
        ]
        let ext = file.pathExtension.lowercased()
        guard let mime = types[ext] else {
            throw VoiceLabError.server(
                status: 422, message: "Audio formati qo‘llab-quvvatlanmaydi.", requestID: nil)
        }
        let boundary = "VoiceLab-\(UUID().uuidString)"
        contentType = "multipart/form-data; boundary=\(boundary)"
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw VoiceLabError.storage("Vaqtinchalik audio fayli yaratilmadi.")
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            let input = try FileHandle(forReadingFrom: file)
            defer {
                try? input.close()
                try? output.close()
            }
            try output.write(
                contentsOf: Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language.rawValue)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n"
                        .utf8))
            var copied = 0
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                copied += data.count
                guard copied <= Self.maximumFileBytes else { throw VoiceLabError.audioTooLarge }
                try output.write(contentsOf: data)
            }
            guard copied > 0 else { throw VoiceLabError.emptyAudio }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
