import Foundation

/// Offsets are relative to the audio file; a nil end means end of file.
struct CueSegment: Codable {
    let sheetURL: URL
    let trackNumber: Int
    let start: TimeInterval
    let end: TimeInterval?
}

struct CueTrack {
    let segment: CueSegment
    let artist: String?
    let title: String
}

/// Reads sidecars only, never follows FILE paths to open other audio files.
/// INDEX 01 uses mm:ss:ff with 75 frames per second:
/// https://www.gnu.org/software/ccd2cue/manual/html_node/INDEX-_0028CUE-Command_0029.html
enum CueSheet {
    private struct Track {
        let number: Int
        let file: String
        let audio: Bool
        var artist: String?
        var title: String?
        var start: TimeInterval?
    }

    static func tracks(for audioURL: URL) -> [CueTrack]? {
        guard audioURL.isFileURL else { return nil }
        let scoped = audioURL.startAccessingSecurityScopedResource()
        defer { if scoped { audioURL.stopAccessingSecurityScopedResource() } }
        let candidates = [audioURL.deletingPathExtension().appendingPathExtension("cue"),
                          audioURL.appendingPathExtension("cue")]
        for candidate in candidates {
            guard let handle = try? FileHandle(forReadingFrom: candidate) else { continue }
            let data = try? handle.read(upToCount: 1024 * 1024 + 1)
            try? handle.close()
            guard let data, data.count <= 1024 * 1024 else { continue }
            let text: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                text = String(data: data, encoding: .utf16)
            } else {
                text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .windowsCP1251)
                    ?? String(data: data, encoding: .windowsCP1252)
            }
            if let text, let tracks = parse(text, sheetURL: candidate, audioURL: audioURL) {
                return tracks
            }
        }
        return nil
    }

    private static func parse(_ text: String, sheetURL: URL, audioURL: URL) -> [CueTrack]? {
        var file: String?
        var files = Set<String>()
        var albumArtist: String?
        var tracks: [Track] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let command = parts.first else { continue }
            let arguments = parts.count == 2 ? String(parts[1]) : ""
            switch command.uppercased() {
            case "FILE":
                guard let name = value(arguments, firstWordOnly: true), !name.isEmpty else { return nil }
                file = name.replacingOccurrences(of: "\\", with: "/")
                files.insert(file!)
            case "TRACK":
                let fields = arguments.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, let number = Int(fields[0]), (1...99).contains(number),
                      let file, tracks.count < 1000 else { return nil }
                tracks.append(Track(number: number, file: file, audio: fields[1].uppercased() == "AUDIO"))
            case "TITLE", "PERFORMER":
                guard let value = value(arguments), !value.isEmpty else { continue }
                if let index = tracks.indices.last, tracks[index].file == file {
                    if command.uppercased() == "TITLE" { tracks[index].title = value }
                    else { tracks[index].artist = value }
                } else if command.uppercased() == "PERFORMER" {
                    albumArtist = value
                }
            case "INDEX":
                let fields = arguments.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, let index = tracks.indices.last, tracks[index].file == file else { return nil }
                if fields[0] == "01" {
                    guard tracks[index].start == nil, let offset = timestamp(String(fields[1])) else { return nil }
                    tracks[index].start = offset
                }
            default: break // REM, gaps, flags and CD-TEXT do not change INDEX 01 offsets.
            }
        }
        // A single-file sidecar may still name the original WAV after MP3 conversion.
        // For multi-file sheets use only the exact FILE context of the added audio.
        let audioPath = audioURL.standardizedFileURL.path
        let matching = tracks.filter { track in
            let referenced = URL(fileURLWithPath: track.file, relativeTo: sheetURL.deletingLastPathComponent()).standardizedFileURL
            return files.count == 1 || referenced.path == audioPath
        }
        guard !matching.isEmpty, matching.allSatisfy({ $0.audio && $0.start != nil }),
              Set(matching.map(\.number)).count == matching.count else { return nil }
        for index in matching.indices.dropFirst() {
            guard matching[index].start! > matching[index - 1].start! else { return nil }
        }
        return matching.enumerated().map { index, track in
            let title = track.title ?? "Track \(track.number)"
            return CueTrack(segment: CueSegment(sheetURL: sheetURL, trackNumber: track.number,
                                               start: track.start!, end: index + 1 < matching.count ? matching[index + 1].start : nil),
                            artist: track.artist ?? albumArtist, title: title)
        }
    }

    private static func value(_ text: String, firstWordOnly: Bool = false) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") {
            let remainder = text.dropFirst()
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            return String(remainder[..<end])
        }
        return firstWordOnly ? text.split(whereSeparator: \.isWhitespace).first.map(String.init) : text
    }

    private static func timestamp(_ value: String) -> TimeInterval? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let minutes = Double(fields[0]), let seconds = Double(fields[1]), let frames = Double(fields[2]),
              seconds < 60, frames < 75 else { return nil }
        let result = minutes * 60 + seconds + frames / 75
        return result.isFinite ? result : nil
    }
}
