import AppKit
import AVFoundation
import Combine
import os
import UniformTypeIdentifiers

private let tagEditorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ru.aleksandr.macAmp",
    category: "metadata-editor"
)

private func logTagEditorFailure(_ operation: String, url: URL?, error: Error) {
    let nsError = error as NSError
    let path = url?.path ?? "<none>"
    tagEditorLogger.error(
        "\(operation, privacy: .public) failed; path=\(path, privacy: .public); domain=\(nsError.domain, privacy: .public); code=\(nsError.code); error=\(String(describing: error), privacy: .public)"
    )
}

struct TagEditorFields: Equatable {
    var trackNumber = ""
    var discNumber = ""
    var bpm = ""
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var year = ""
    var genre = ""
    var comment = ""
    var composer = ""
    var publisher = ""
    var originalArtist = ""
    var copyright = ""
    var url = ""
    var encodedBy = ""

    var hasAnyValue: Bool {
        [
            trackNumber, discNumber, bpm, title, artist, album, albumArtist,
            year, genre, comment, composer, publisher, originalArtist,
            copyright, url, encodedBy
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasID3v1CopyableValue: Bool {
        [trackNumber, title, artist, album, year, comment]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private extension TagEditorFields {
    func reinterpretingLegacyBytes(as encoding: String.Encoding) -> TagEditorFields {
        func convert(_ value: String) -> String {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return value }
            let sourceData = value.data(using: .isoLatin1) ?? value.data(using: .windowsCP1252)
            guard let sourceData, let converted = String(data: sourceData, encoding: encoding) else { return value }
            return converted
        }

        var result = self
        result.trackNumber = convert(trackNumber)
        result.discNumber = convert(discNumber)
        result.bpm = convert(bpm)
        result.title = convert(title)
        result.artist = convert(artist)
        result.album = convert(album)
        result.albumArtist = convert(albumArtist)
        result.year = convert(year)
        result.genre = convert(genre)
        result.comment = convert(comment)
        result.composer = convert(composer)
        result.publisher = convert(publisher)
        result.originalArtist = convert(originalArtist)
        result.copyright = convert(copyright)
        result.url = convert(url)
        result.encodedBy = convert(encodedBy)
        return result
    }
}

struct TagEditorValues {
    var fields = TagEditorFields()
    var formatInfo = ""
    var artworkData: Data?
    var metadataTypeName = "Metadata"
    var canWrite = false
    var supportsID3Fields = false
    var supportsID3v1 = false
    var supportsEncodingReload = false
    var id3v1Fields = TagEditorFields()
    var canCopyID3v1 = false
    var supportsArtworkEditing = false
    var canToggleTag = false
    var tagEnabled = true
    var supportMessage = ""
}

private enum TagEditorArtworkChange {
    case unchanged
    case remove
    case replace(Data)
}

private extension TagEditorArtworkChange {
    var logName: String {
        switch self {
        case .unchanged: return "unchanged"
        case .remove: return "remove"
        case .replace: return "replace"
        }
    }
}

enum TagEditorError: LocalizedError {
    case invalidFile
    case unsupportedFormat(String)
    case metadataReadFailed
    case exportTimedOut
    case exportFailed(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The selected item is not a regular local audio file."
        case .unsupportedFormat(let extensionName):
            return "Tag writing for \(extensionName.uppercased()) is not supported yet."
        case .metadataReadFailed:
            return "macOS could not read the metadata container."
        case .exportTimedOut:
            return "Writing the metadata took too long and was cancelled."
        case .exportFailed(let reason):
            return reason
        case .fileWriteFailed(let reason):
            return "The audio file was not saved: \(reason)"
        }
    }
}

/// The editor keeps reading cheap and asynchronous. Writing is deliberately
/// limited to containers for which this implementation can preserve the
/// audio stream and existing non-edited metadata.
final class TagEditorModel: ObservableObject {
    @Published private(set) var values = TagEditorValues()
    @Published private(set) var fileName = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    private let queue = DispatchQueue(label: "ru.aleksandr.macAmp.tag-editor", qos: .utility)
    private var generation = UUID()
    private var currentURL: URL?
    private var artworkChange: TagEditorArtworkChange = .unchanged
    private var originalFields = TagEditorFields()
    private var originalTagEnabled = true
    private var originalArtworkData: Data?

    func load(_ url: URL, bookmarkData: Data? = nil) {
        let accessibleURL = Self.resolve(url, bookmarkData: bookmarkData)
        tagEditorLogger.debug("Loading metadata from \(accessibleURL.path, privacy: .public); bookmark=\(bookmarkData != nil)")
        let token = UUID()
        generation = token
        currentURL = accessibleURL
        fileName = accessibleURL.path
        isLoading = true
        isSaving = false
        errorMessage = nil
        artworkChange = .unchanged
        values = Self.initialValues(for: accessibleURL)
        originalFields = values.fields
        originalTagEnabled = values.tagEnabled
        originalArtworkData = values.artworkData

        queue.async { [weak self] in
            let beganScope = accessibleURL.startAccessingSecurityScopedResource()
            let loaded = Self.read(accessibleURL)
            tagEditorLogger.debug("Loaded metadata from \(accessibleURL.path, privacy: .public); securityScope=\(beganScope); writable=\(loaded.canWrite)")
            if beganScope { accessibleURL.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isLoading = false
                self.values = loaded
                self.originalFields = loaded.fields
                self.originalTagEnabled = loaded.tagEnabled
                self.originalArtworkData = loaded.artworkData
            }
        }
    }

    private static func resolve(_ url: URL, bookmarkData: Data?) -> URL {
        guard let bookmarkData else { return url }
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? url
    }

    func save(_ fields: TagEditorFields, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = currentURL else {
            tagEditorLogger.error("Metadata save rejected: there is no current file")
            completion(.failure(TagEditorError.invalidFile))
            return
        }
        guard values.canWrite else {
            tagEditorLogger.error("Metadata save rejected for \(url.path, privacy: .public): unsupported format")
            completion(.failure(TagEditorError.unsupportedFormat(url.pathExtension)))
            return
        }

        let artworkChange = artworkChange
        let tagEnabled = values.tagEnabled
        isSaving = true
        errorMessage = nil
        queue.async { [weak self] in
            let beganScope = url.startAccessingSecurityScopedResource()
            tagEditorLogger.debug("Saving metadata to \(url.path, privacy: .public); securityScope=\(beganScope); tagEnabled=\(tagEnabled); artwork=\(artworkChange.logName)")
            let result: Result<Void, Error>
            do {
                try AudioTagWriter.write(fields, artwork: artworkChange, tagEnabled: tagEnabled, to: url)
                result = .success(())
                tagEditorLogger.debug("Metadata saved to \(url.path, privacy: .public)")
            } catch {
                result = .failure(error)
                logTagEditorFailure("Metadata save", url: url, error: error)
                tagEditorLogger.error("Metadata save securityScope=\(beganScope)")
            }
            if beganScope { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                if case .failure(let error) = result {
                    self.errorMessage = error.localizedDescription
                } else {
                    self.values.fields = fields
                    self.artworkChange = .unchanged
                }
                completion(result)
            }
        }
    }

    func setArtwork(_ data: Data) {
        guard values.supportsArtworkEditing, NSImage(data: data) != nil else { return }
        values.artworkData = data
        values.tagEnabled = true
        artworkChange = .replace(data)
    }

    func removeArtwork() {
        guard values.supportsArtworkEditing else { return }
        values.artworkData = nil
        artworkChange = .remove
    }

    func setTagEnabled(_ enabled: Bool) {
        guard values.canToggleTag else { return }
        values.tagEnabled = enabled
    }

    var canGetFromFilename: Bool {
        guard let currentURL else { return false }
        return TrackNotificationController.artistAndTitle(
            fromFilename: currentURL.deletingPathExtension().lastPathComponent
        ) != nil
    }

    func getFromFilename() {
        guard let currentURL,
              let inferred = TrackNotificationController.artistAndTitle(
                fromFilename: currentURL.deletingPathExtension().lastPathComponent
              ) else { return }
        values.fields.artist = inferred.artist
        values.fields.title = inferred.title
        values.tagEnabled = true
    }

    func copyFromID3v1() {
        guard values.canCopyID3v1 else { return }
        let source = values.id3v1Fields
        var fields = values.fields
        func copyIfFilled(_ source: String, into destination: inout String) {
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { destination = value }
        }
        copyIfFilled(source.trackNumber, into: &fields.trackNumber)
        copyIfFilled(source.title, into: &fields.title)
        copyIfFilled(source.artist, into: &fields.artist)
        copyIfFilled(source.album, into: &fields.album)
        copyIfFilled(source.year, into: &fields.year)
        copyIfFilled(source.genre, into: &fields.genre)
        copyIfFilled(source.comment, into: &fields.comment)
        values.fields = fields
        values.tagEnabled = true
    }

    func reload(with encoding: String.Encoding) {
        guard values.tagEnabled, values.supportsEncodingReload else { return }
        values.fields = values.fields.reinterpretingLegacyBytes(as: encoding)
    }

    func undoChanges() {
        values.fields = originalFields
        values.tagEnabled = originalTagEnabled
        values.artworkData = originalArtworkData
        artworkChange = .unchanged
        errorMessage = nil
    }

    func hasUnsavedChanges(fields: TagEditorFields) -> Bool {
        fields != originalFields
            || values.tagEnabled != originalTagEnabled
            || artworkHasChanged
    }

    private var artworkHasChanged: Bool {
        switch artworkChange {
        case .unchanged:
            return false
        case .remove:
            return originalArtworkData != nil
        case .replace(let data):
            return data != originalArtworkData
        }
    }

    private static func initialValues(for url: URL) -> TagEditorValues {
        let extensionName = url.pathExtension.lowercased()
        let metadataTypeName = Self.metadataTypeName(for: url)
        switch extensionName {
        case "mp3":
            return TagEditorValues(
                metadataTypeName: metadataTypeName,
                canWrite: true,
                supportsID3Fields: true,
                supportsID3v1: true,
                supportsEncodingReload: true,
                supportsArtworkEditing: true,
                canToggleTag: true,
                    supportMessage: "Editable ID3v2 fields; other frames preserved."
            )
        case "aac":
            return TagEditorValues(
                metadataTypeName: metadataTypeName,
                canWrite: true,
                supportsEncodingReload: true,
                canToggleTag: true,
                    supportMessage: "Editable ID3v2 fields; other frames preserved."
            )
        case "m4a", "mp4":
            return TagEditorValues(
                metadataTypeName: metadataTypeName,
                canWrite: true,
                canToggleTag: true,
                supportMessage: "Editable: iTunes metadata. Existing artwork and other fields are preserved."
            )
        default:
            let readableExtension = extensionName.isEmpty ? "this format" : extensionName.uppercased()
            return TagEditorValues(
                metadataTypeName: metadataTypeName,
                canWrite: false,
                supportMessage: "Read-only for now: \(readableExtension)."
            )
        }
    }

    private static func metadataTypeName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3", "aac": return "ID3v2 Tag"
        case "m4a", "mp4": return "iTunes Metadata"
        case "flac", "ogg": return "Vorbis Comment"
        case "opus": return "OpusTags"
        case "wav": return "RIFF INFO"
        case "aif", "aiff": return "IFF Metadata"
        default: return "Metadata"
        }
    }

    private static func read(_ url: URL) -> TagEditorValues {
        let initial = initialValues(for: url)
        guard url.isFileURL else { return initial }

        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata", "duration"]) {
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return Self.unreadableValues(from: initial)
        }
        var metadataError: NSError?
        guard asset.statusOfValue(forKey: "metadata", error: &metadataError) == .loaded else {
            return Self.unreadableValues(from: initial)
        }

        let metadata = asset.commonMetadata + asset.metadata
        func text(_ item: AVMetadataItem?) -> String? {
            guard let value = item?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        func matches(_ item: AVMetadataItem, frame: String, keys: [String]) -> Bool {
            let key = (item.key as? String)?.uppercased()
            let identifier = item.identifier?.rawValue.uppercased()
            let candidates = [frame] + keys
            return candidates.contains { candidate in
                let normalized = candidate.uppercased()
                return key == normalized
                    || identifier == normalized
                    || identifier?.hasSuffix("/\(normalized)") == true
            }
        }
        func firstText(frames: [String] = [], keys: [String] = [], commonKey: AVMetadataKey? = nil) -> String {
            for frame in frames {
                if let item = metadata.first(where: { matches($0, frame: frame, keys: []) }), let value = text(item) {
                    return value
                }
            }
            if let item = metadata.first(where: { matches($0, frame: "", keys: keys) }), let value = text(item) {
                return value
            }
            if let commonKey,
               let item = metadata.first(where: { $0.commonKey == commonKey }),
               let value = text(item) {
                return value
            }
            return ""
        }
        func numberText(frames: [String], keys: [String]) -> String {
            guard let item = metadata.first(where: { matches($0, frame: "", keys: frames + keys) }) else { return "" }
            if let value = text(item) { return value }
            if let number = item.numberValue { return number.stringValue }
            if let data = item.dataValue, data.count >= 8 {
                let first = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                let total = Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5])
                if first > 0 && total > 0 { return "\(first)/\(total)" }
                if first > 0 { return String(first) }
            }
            return ""
        }
        func urlText(frames: [String]) -> String {
            guard let item = metadata.first(where: { item in
                frames.contains { matches(item, frame: $0, keys: []) }
            }) else { return "" }
            if let value = text(item), value.contains("://") { return value }
            guard let data = item.dataValue else { return text(item) ?? "" }
            for prefix in ["https://", "http://"] {
                guard let start = data.range(of: Data(prefix.utf8))?.lowerBound else { continue }
                let bytes = data[start...].prefix(while: { $0 != 0 && $0 != 10 && $0 != 13 })
                let value = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return text(item) ?? ""
        }

        var fields = TagEditorFields()
        fields.trackNumber = numberText(frames: ["TRCK"], keys: ["TRACKNUMBER", "TRKN"])
        fields.discNumber = numberText(frames: ["TPOS"], keys: ["DISCNUMBER", "DISK"])
        fields.bpm = numberText(frames: ["TBPM"], keys: ["BPM", "TMPo"])
        fields.title = firstText(frames: ["TIT2"], keys: ["TITLE", "©NAM"], commonKey: .commonKeyTitle)
        fields.artist = firstText(frames: ["TPE1"], keys: ["ARTIST", "©ART"], commonKey: .commonKeyArtist)
        fields.album = firstText(frames: ["TALB"], keys: ["ALBUM", "©ALB"], commonKey: .commonKeyAlbumName)
        fields.albumArtist = firstText(frames: ["TPE2"], keys: ["ALBUMARTIST", "ALBUM ARTIST", "AART"])
        fields.year = firstText(frames: ["TYER", "TDRC"], keys: ["DATE", "©DAY"], commonKey: .commonKeyCreationDate)
        fields.genre = firstText(frames: ["TCON"], keys: ["GENRE", "©GEN"], commonKey: .commonKeyType)
        fields.comment = firstText(frames: ["COMM"], keys: ["COMMENT", "©CMT"], commonKey: .commonKeyDescription)
        fields.composer = firstText(frames: ["TCOM"], keys: ["COMPOSER", "©WRT"])
        fields.publisher = firstText(frames: ["TPUB"], keys: ["PUBLISHER", "©PUB"], commonKey: .commonKeyPublisher)
        fields.originalArtist = firstText(frames: ["TOPE"], keys: ["ORIGARTIST", "ORIGINAL ARTIST"])
        fields.copyright = firstText(frames: ["TCOP"], keys: ["COPYRIGHT"], commonKey: .commonKeyCopyrights)
        fields.url = urlText(frames: ["WXXX", "WOAR", "WOAF", "WOAS"])
        fields.encodedBy = firstText(frames: ["TENC"], keys: ["ENCODEDBY", "ENCODED BY"])

        let artworkData = metadata.first { item in
            let key = (item.key as? String)?.uppercased()
            let identifier = item.identifier?.rawValue.uppercased()
            return key == "APIC"
                || identifier?.hasSuffix("/APIC") == true
                || item.commonKey == .commonKeyArtwork
        }?.dataValue

        var result = initial
        result.fields = fields
        result.artworkData = artworkData
        if initial.supportsID3v1 {
            result.id3v1Fields = readID3v1Fields(from: url)
            result.canCopyID3v1 = result.id3v1Fields.hasID3v1CopyableValue
        }
        result.tagEnabled = hasMetadataTag(for: url, metadata: metadata)
        result.formatInfo = formatInfoLines(for: url, asset: asset, metadata: metadata).joined(separator: "\n")
        Self.applyWriteAccess(to: &result, for: url)
        return result
    }

    private static func applyWriteAccess(to values: inout TagEditorValues, for url: URL) {
        guard values.canWrite else { return }

        do {
            let handle = try FileHandle(forUpdating: url)
            try handle.close()
            tagEditorLogger.debug("Write preflight passed; path=\(url.path, privacy: .public)")
        } catch {
            logTagEditorFailure("Write preflight", url: url, error: error)
            values.canWrite = false
            values.supportMessage = "Read-only: you don't have permission to save this file."
        }
    }

    private static func readID3v1Fields(from url: URL) -> TagEditorFields {
        guard url.pathExtension.lowercased() == "mp3",
              let input = try? FileHandle(forReadingFrom: url) else { return TagEditorFields() }
        defer { try? input.close() }
        guard let fileLength = try? input.seekToEnd(), fileLength >= 128 else { return TagEditorFields() }
        input.seek(toFileOffset: fileLength - 128)
        guard let data = try? input.read(upToCount: 128), data.count == 128,
              data[0] == 0x54, data[1] == 0x41, data[2] == 0x47 else {
            return TagEditorFields()
        }

        func text(in range: Range<Int>) -> String {
            let bytes = data.subdata(in: range).prefix(while: { $0 != 0 })
            guard !bytes.isEmpty else { return "" }
            let value = String(data: Data(bytes), encoding: .utf8)
                ?? String(data: Data(bytes), encoding: .windowsCP1252)
                ?? String(data: Data(bytes), encoding: .isoLatin1)
                ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var fields = TagEditorFields()
        fields.title = text(in: 3..<33)
        fields.artist = text(in: 33..<63)
        fields.album = text(in: 63..<93)
        fields.year = text(in: 93..<97)
        if data[125] == 0 {
            fields.comment = text(in: 97..<125)
            if data[126] > 0 { fields.trackNumber = String(data[126]) }
        } else {
            fields.comment = text(in: 97..<127)
        }
        // An empty ID3v1 record is zero-filled, which technically maps its
        // genre byte to "Blues". Do not expose that placeholder as data;
        // retain genre 0 only when another ID3v1 field is actually filled.
        if Int(data[127]) < id3v1Genres.count,
           fields.hasAnyValue || data[127] != 0 {
            fields.genre = id3v1Genres[Int(data[127])]
        }
        return fields
    }

    private static let id3v1Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock",
        "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
        "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical",
        "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock",
        "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
        "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk",
        "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer",
        "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic",
        "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock",
        "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore",
        "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal",
        "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal",
        "Anime", "JPop", "Synthpop"
    ]

    private static func unreadableValues(from initial: TagEditorValues) -> TagEditorValues {
        var result = initial
        result.canWrite = false
        result.supportMessage = "Metadata could not be read; editing is disabled."
        return result
    }

    private static func hasMetadataTag(for url: URL, metadata: [AVMetadataItem]) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp3", "aac": return hasEditableID3Metadata(in: metadata)
        case "m4a", "mp4": return metadata.contains(where: isM4AUserMetadata)
        default: return true
        }
    }

    private static func hasEditableID3Metadata(in metadata: [AVMetadataItem]) -> Bool {
        // An ID3 header can contain only private technical frames, for
        // example PeakValue/AverageLevel left by a ReplayGain scanner. Those
        // frames are not the editable metadata tag shown by this window.
        let editableFrames = [
            "TIT2", "TPE1", "TALB", "TPE2", "TYER", "TDRC", "TCON", "COMM",
            "TCOM", "TPUB", "TOPE", "TCOP", "TRCK", "TPOS", "TBPM", "WXXX",
            "WOAR", "WOAF", "WOAS", "TENC", "APIC"
        ]
        let commonKeys: Set<AVMetadataKey> = [
            .commonKeyTitle, .commonKeyArtist, .commonKeyAlbumName,
            .commonKeyCreationDate, .commonKeyType, .commonKeyDescription,
            .commonKeyPublisher, .commonKeyCopyrights, .commonKeyArtwork
        ]
        return metadata.contains { item in
            if let commonKey = item.commonKey, commonKeys.contains(commonKey) {
                return true
            }
            let key = (item.key as? String)?.uppercased()
            let identifier = item.identifier?.rawValue.uppercased()
            return editableFrames.contains { frame in
                key == frame || identifier == frame || identifier?.hasSuffix("/\(frame)") == true
            }
        }
    }

    private static func isM4AUserMetadata(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyTitle || item.commonKey == .commonKeyArtist
            || item.commonKey == .commonKeyAlbumName || item.commonKey == .commonKeyCreationDate
            || item.commonKey == .commonKeyDescription || item.commonKey == .commonKeyPublisher
            || item.commonKey == .commonKeyArtwork || item.commonKey == .commonKeyCopyrights {
            return true
        }
        let key = (item.key as? String)?.lowercased()
        let identifier = item.identifier?.rawValue.lowercased()
        let userKeys = ["©nam", "©art", "©alb", "aart", "©day", "©gen", "©cmt", "©wrt", "©pub", "trkn", "disk", "tmpo", "covr"]
        return userKeys.contains { candidate in
            key == candidate || identifier?.hasSuffix("/\(candidate)") == true
        }
    }

    private struct MPEGFrameHeader {
        let version: String
        let layer: Int
        let bitrateKbps: Int
        let sampleRate: Int
        let channelMode: String
        let frameLength: Int
    }

    private struct MPEGInfo {
        let headerOffset: Int
        let firstFrame: MPEGFrameHeader
        let frameCount: Int
        let isVariableBitrate: Bool
    }

    private struct PopularimeterInfo {
        let name: String
        let value: Int
        let counter: UInt64

        var starCount: Int {
            guard value > 0 else { return 0 }
            return min(5, (value - 1) / 51 + 1)
        }

        var starDisplay: String {
            String(repeating: "★", count: starCount)
                + String(repeating: "☆", count: 5 - starCount)
        }
    }

    private static func formatInfoLines(for url: URL, asset: AVAsset, metadata: [AVMetadataItem]) -> [String] {
        var lines: [String] = []

        let mpegInfo: MPEGInfo?
        if url.pathExtension.lowercased() == "mp3" {
            mpegInfo = readMPEGInfo(from: url)
            if let mpegInfo {
                lines.append("\(mpegInfo.firstFrame.version) Layer \(mpegInfo.firstFrame.layer)")
            }
        } else {
            mpegInfo = nil
        }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            lines.append("Size: \(fileSize) bytes")
        }

        let duration = asset.duration.seconds
        if duration.isFinite, duration > 0 {
            lines.append("Length: \(max(0, Int(duration.rounded()))) seconds")
        }

        if let mpegInfo {
            lines.append("Header found at: \(mpegInfo.headerOffset) bytes")

            let bitrate = mpegInfo.isVariableBitrate
                ? "VBR"
                : "\(mpegInfo.firstFrame.bitrateKbps)kbit"
            lines.append("\(bitrate), \(mpegInfo.frameCount) frames")
            lines.append("\(mpegInfo.firstFrame.sampleRate)Hz \(mpegInfo.firstFrame.channelMode)")
        } else if let bitrate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate, bitrate > 0 {
            lines.append("\(Int((bitrate / 1_000).rounded()))kbit")
        }

        let ratings = popularimeterRecords(from: url, metadata: metadata)
        if !ratings.isEmpty {
            if !lines.isEmpty { lines.append("") }
            for rating in ratings {
                let name = rating.name.isEmpty ? "(unnamed)" : rating.name
                lines.append("Rating: \(name)")
                lines.append("- Value: \(rating.value)/255")
                lines.append("- Stars: \(rating.starCount)/5 \(rating.starDisplay)")
                lines.append("- Play count: \(rating.counter)")
            }
        }

        return lines
    }

    private static func popularimeterRecords(from url: URL, metadata: [AVMetadataItem]) -> [PopularimeterInfo] {
        let records = readPopularimeterRecords(from: url)
        if !records.isEmpty { return records }

        return metadata.compactMap { item in
            guard isPopularimeterItem(item), let data = item.dataValue else { return nil }
            return parsePopularimeterRecord(data)
        }
    }

    private static func readPopularimeterRecords(from url: URL) -> [PopularimeterInfo] {
        guard url.isFileURL, let input = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? input.close() }

        guard let header = try? input.read(upToCount: 10), header.count == 10,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else {
            return []
        }
        let version = Int(header[3])
        guard version == 3 || version == 4 else { return [] }

        let tagSize = synchsafeValue(header[6], header[7], header[8], header[9])
        guard tagSize <= 64 * 1024 * 1024,
              let tagData = try? input.read(upToCount: tagSize), tagData.count == tagSize else {
            return []
        }

        var offset = 0
        if header[5] & 0x40 != 0 {
            let extendedSize: Int
            if version == 4 {
                guard tagData.count >= 4 else { return [] }
                extendedSize = synchsafeValue(tagData[0], tagData[1], tagData[2], tagData[3])
            } else {
                guard tagData.count >= 4 else { return [] }
                extendedSize = Int(tagData[0]) << 24
                    | Int(tagData[1]) << 16
                    | Int(tagData[2]) << 8
                    | Int(tagData[3])
            }
            offset = min(tagData.count, 4 + extendedSize)
        }

        var records: [PopularimeterInfo] = []
        while offset + 10 <= tagData.count {
            let idBytes = tagData.subdata(in: offset..<(offset + 4))
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            guard idBytes.allSatisfy({
                ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39)
            }), let id = String(data: idBytes, encoding: .ascii) else {
                break
            }

            let frameSize: Int
            if version == 4 {
                frameSize = synchsafeValue(
                    tagData[offset + 4], tagData[offset + 5],
                    tagData[offset + 6], tagData[offset + 7]
                )
            } else {
                frameSize = Int(tagData[offset + 4]) << 24
                    | Int(tagData[offset + 5]) << 16
                    | Int(tagData[offset + 6]) << 8
                    | Int(tagData[offset + 7])
            }
            guard frameSize >= 0, frameSize <= tagData.count - offset - 10 else { break }

            let bodyStart = offset + 10
            let bodyEnd = bodyStart + frameSize
            if id == "POPM",
               let record = parsePopularimeterRecord(tagData.subdata(in: bodyStart..<bodyEnd)) {
                records.append(record)
            }
            offset = bodyEnd
        }
        return records
    }

    private static func isPopularimeterItem(_ item: AVMetadataItem) -> Bool {
        let key = (item.key as? String)?.uppercased()
        let identifier = item.identifier?.rawValue.uppercased()
        return key == "POPM"
            || identifier == "POPM"
            || identifier?.hasSuffix("/POPM") == true
    }

    private static func parsePopularimeterRecord(_ data: Data) -> PopularimeterInfo? {
        guard let separator = data.firstIndex(of: 0) else { return nil }
        let ratingIndex = data.index(after: separator)
        guard ratingIndex < data.endIndex else { return nil }

        let nameData = data.subdata(in: data.startIndex..<separator)
        let name = (String(data: nameData, encoding: .isoLatin1)
            ?? String(decoding: nameData, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Int(data[ratingIndex])
        let counterStart = data.index(after: ratingIndex)
        var counter: UInt64 = 0
        for byte in data[counterStart...] {
            if counter > (UInt64.max - UInt64(byte)) / 256 {
                counter = UInt64.max
                break
            }
            counter = counter * 256 + UInt64(byte)
        }
        return PopularimeterInfo(name: name, value: value, counter: counter)
    }

    private static func synchsafeValue(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    private static func readMPEGInfo(from url: URL) -> MPEGInfo? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 4 else {
            return nil
        }

        let audioStart = id3v2AudioStart(in: data)
        let audioEnd = hasID3v1Tag(in: data) ? data.count - 128 : data.count
        guard audioStart < audioEnd else { return nil }

        // A valid MP3 frame is normally immediately after the ID3v2 tag. The
        // bounded scan also handles files with a small amount of leading junk.
        let scanEnd = min(audioEnd, audioStart + 16 * 1024 * 1024)
        var headerOffset: Int?
        var firstFrame: MPEGFrameHeader?
        var offset = audioStart
        while offset + 4 <= scanEnd {
            if let header = parseMPEGFrameHeader(in: data, at: offset) {
                headerOffset = offset
                firstFrame = header
                break
            }
            offset += 1
        }

        guard let headerOffset, let firstFrame else { return nil }

        var frameCount = 0
        var bitrates = Set<Int>()
        var frameOffset = headerOffset
        while frameOffset + 4 <= audioEnd,
              let frame = parseMPEGFrameHeader(in: data, at: frameOffset),
              frame.frameLength > 0,
              frame.frameLength <= audioEnd - frameOffset {
            frameCount += 1
            bitrates.insert(frame.bitrateKbps)
            frameOffset += frame.frameLength
        }

        guard frameCount > 0 else { return nil }
        return MPEGInfo(
            headerOffset: headerOffset,
            firstFrame: firstFrame,
            frameCount: frameCount,
            isVariableBitrate: bitrates.count > 1
        )
    }

    private static func parseMPEGFrameHeader(in data: Data, at offset: Int) -> MPEGFrameHeader? {
        guard offset >= 0, offset + 4 <= data.count,
              data[offset] == 0xFF,
              data[offset + 1] & 0xE0 == 0xE0 else {
            return nil
        }

        let versionBits = (data[offset + 1] >> 3) & 0x03
        let layerBits = (data[offset + 1] >> 1) & 0x03
        guard versionBits != 1, layerBits != 0 else { return nil }

        let bitrateIndex = Int(data[offset + 2] >> 4)
        let sampleRateIndex = Int((data[offset + 2] >> 2) & 0x03)
        guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3 else { return nil }

        let layer = layerBits == 3 ? 1 : layerBits == 2 ? 2 : 3
        let bitrateTable: [Int]
        if versionBits == 3 {
            switch layer {
            case 1: bitrateTable = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
            case 2: bitrateTable = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
            default: bitrateTable = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            }
        } else {
            switch layer {
            case 1: bitrateTable = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
            default: bitrateTable = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            }
        }

        let baseSampleRates = [44_100, 48_000, 32_000]
        let sampleRateMultiplier: Int
        let version: String
        switch versionBits {
        case 3:
            sampleRateMultiplier = 1
            version = "MPEG 1.0"
        case 2:
            sampleRateMultiplier = 2
            version = "MPEG 2.0"
        default:
            sampleRateMultiplier = 4
            version = "MPEG 2.5"
        }

        let bitrateKbps = bitrateTable[bitrateIndex]
        let sampleRate = baseSampleRates[sampleRateIndex] / sampleRateMultiplier
        let padding = Int((data[offset + 2] >> 1) & 0x01)
        let coefficient = layer == 1 ? 12 : (versionBits == 3 ? 144 : 72)
        let slotSize = layer == 1 ? 4 : 1
        let frameLength = coefficient * bitrateKbps * 1_000 / sampleRate + padding * slotSize
        guard frameLength > 4 else { return nil }

        let channelModes = ["Stereo", "Joint Stereo", "Dual Channel", "Single Channel"]
        let channelMode = channelModes[Int(data[offset + 3] >> 6)]
        return MPEGFrameHeader(
            version: version,
            layer: layer,
            bitrateKbps: bitrateKbps,
            sampleRate: sampleRate,
            channelMode: channelMode,
            frameLength: frameLength
        )
    }

    private static func id3v2AudioStart(in data: Data) -> Int {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return 0
        }
        let tagSize = (Int(data[6] & 0x7F) << 21)
            | (Int(data[7] & 0x7F) << 14)
            | (Int(data[8] & 0x7F) << 7)
            | Int(data[9] & 0x7F)
        let footerSize = data[3] == 4 && data[5] & 0x10 != 0 ? 10 : 0
        return min(data.count, 10 + tagSize + footerSize)
    }

    private static func hasID3v1Tag(in data: Data) -> Bool {
        guard data.count >= 128 else { return false }
        let offset = data.count - 128
        return data[offset] == 0x54 && data[offset + 1] == 0x41 && data[offset + 2] == 0x47
    }
}

/// Writes ID3v2 without decoding or re-encoding the audio stream. The old
/// tag is parsed only for frame boundaries; every non-edited frame (including
/// APIC artwork) is copied byte-for-byte into the new tag.
private enum AudioTagWriter {
    static func write(_ fields: TagEditorFields, artwork: TagEditorArtworkChange, tagEnabled: Bool, to url: URL) throws {
        guard isSafeRegularFile(url) else { throw TagEditorError.invalidFile }
        tagEditorLogger.debug("Writing \(url.pathExtension.lowercased(), privacy: .public) metadata; path=\(url.path, privacy: .public); tagEnabled=\(tagEnabled)")
        switch url.pathExtension.lowercased() {
        case "mp3", "aac":
            if tagEnabled {
                try writeID3(fields, artwork: artwork, to: url)
            } else {
                try removeID3Tag(from: url)
            }
        case "m4a", "mp4":
            try writeM4A(fields, tagEnabled: tagEnabled, to: url)
        default:
            throw TagEditorError.unsupportedFormat(url.pathExtension)
        }
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL, !url.path.isEmpty,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isDirectory != true && values.isSymbolicLink != true
    }

    private struct ID3Header {
        let version: Int
        let audioStart: UInt64
        let tagData: Data
    }

    private static func writeID3(_ fields: TagEditorFields, artwork: TagEditorArtworkChange, to url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileLength = try input.seekToEnd()
        input.seek(toFileOffset: 0)

        let header = try readID3Header(from: input, fileLength: fileLength)
        let version = header.version
        var preservedFrames: [Data] = []
        if !header.tagData.isEmpty {
            preservedFrames = try preservedID3Frames(from: header.tagData, version: version)
        }
        let replacementIDs = Set(["TPE1", "TIT2", "TALB", "TPE2", "TYER", "TDRC", "TCON", "COMM", "TCOM", "TPUB", "TPOS", "TRCK", "TBPM", "TOPE", "TCOP", "WXXX", "TENC"])
        preservedFrames.removeAll { frame in
            guard frame.count >= 4, let id = String(bytes: frame.prefix(4), encoding: .ascii) else { return false }
            return replacementIDs.contains(id) || (id == "APIC" && !isUnchanged(artwork))
        }

        var newFrames = preservedFrames
        newFrames.append(contentsOf: makeID3Frames(fields, version: version))
        if case .replace(let data) = artwork {
            newFrames.append(makeID3ArtworkFrame(data, version: version))
        }
        let payload = newFrames.reduce(into: Data()) { $0.append($1) }
        guard payload.count <= 0x0FFFFFFF else { throw TagEditorError.exportFailed("The metadata tag is too large.") }

        let audioEnd = oldAudioEnd(fileLength: fileLength, audioStart: header.audioStart, input: input)
        guard audioEnd >= header.audioStart else { throw TagEditorError.invalidFile }
        let tag = makeID3TagData(payload, version: version, paddedTo: header.audioStart)
        try input.close()
        try rewriteID3InPlace(
            to: url,
            oldTagSize: header.audioStart,
            contentEnd: audioEnd,
            fileLength: fileLength,
            newTag: tag,
            preserveTrailingID3v1: true
        )
    }

    private static func removeID3Tag(from url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileLength = try input.seekToEnd()
        input.seek(toFileOffset: 0)

        let header = try readID3Header(from: input, fileLength: fileLength)
        let audioEnd = oldAudioEnd(fileLength: fileLength, audioStart: header.audioStart, input: input)
        guard audioEnd >= header.audioStart else { throw TagEditorError.invalidFile }
        try input.close()
        try rewriteID3InPlace(
            to: url,
            oldTagSize: header.audioStart,
            contentEnd: audioEnd,
            fileLength: fileLength,
            newTag: Data(),
            preserveTrailingID3v1: false
        )
    }

    private static func readID3Header(from input: FileHandle, fileLength: UInt64) throws -> ID3Header {
        guard let prefix = try input.read(upToCount: 10), prefix.count == 10 else {
            throw TagEditorError.invalidFile
        }
        guard prefix[0] == 0x49, prefix[1] == 0x44, prefix[2] == 0x33 else {
            input.seek(toFileOffset: 0)
            return ID3Header(version: 3, audioStart: 0, tagData: Data())
        }
        let version = Int(prefix[3])
        guard version == 3 || version == 4 else {
            throw TagEditorError.unsupportedFormat("ID3v2.\(version)")
        }
        // Unsynchronisation and extended headers need format-specific
        // decoding. Refuse those tags rather than silently corrupting frames.
        guard prefix[5] & 0xC0 == 0 else {
            throw TagEditorError.exportFailed("This ID3 tag uses an unsupported header encoding.")
        }
        let tagSize = synchsafeValue(prefix[6], prefix[7], prefix[8], prefix[9])
        let footerSize = version == 4 && prefix[5] & 0x10 != 0 ? 10 : 0
        let totalSize = UInt64(10 + tagSize + footerSize)
        guard totalSize <= fileLength, tagSize <= 64 * 1024 * 1024 else {
            throw TagEditorError.invalidFile
        }
        guard let tagData = try input.read(upToCount: tagSize), tagData.count == tagSize else {
            throw TagEditorError.invalidFile
        }
        if footerSize > 0 {
            _ = try input.read(upToCount: footerSize)
        }
        return ID3Header(version: version, audioStart: totalSize, tagData: tagData)
    }

    private static func preservedID3Frames(from data: Data, version: Int) throws -> [Data] {
        var frames: [Data] = []
        var offset = 0
        while offset + 10 <= data.count {
            let idData = data.subdata(in: offset..<(offset + 4))
            if idData.allSatisfy({ $0 == 0 }) { break }
            guard let id = String(data: idData, encoding: .ascii), id.utf8.count == 4 else { break }
            let size: Int
            if version == 4 {
                size = synchsafeValue(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
            } else {
                size = Int(data[offset + 4]) << 24
                    | Int(data[offset + 5]) << 16
                    | Int(data[offset + 6]) << 8
                    | Int(data[offset + 7])
            }
            guard size >= 0, size <= data.count - offset - 10 else { break }
            let end = offset + 10 + size
            frames.append(data.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }

    private static func makeID3Frames(_ fields: TagEditorFields, version: Int) -> [Data] {
        var frames: [Data] = []
        func add(_ id: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            frames.append(makeID3Frame(id: id, value: trimmed, version: version))
        }
        add("TPE1", fields.artist)
        add("TIT2", fields.title)
        add("TALB", fields.album)
        add("TPE2", fields.albumArtist)
        add(version == 4 ? "TDRC" : "TYER", fields.year)
        add("TCON", fields.genre)
        add("TCOM", fields.composer)
        add("TPUB", fields.publisher)
        add("TOPE", fields.originalArtist)
        add("TCOP", fields.copyright)
        add("TPOS", fields.discNumber)
        add("TRCK", fields.trackNumber)
        add("TBPM", fields.bpm)
        addURL(fields.url)
        let comment = fields.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { frames.append(makeID3Comment(comment, version: version)) }
        add("TENC", fields.encodedBy)
        return frames

        func addURL(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var body = Data([version == 4 ? 3 : 0, 0])
            body.append(contentsOf: Array(trimmed.utf8))
            frames.append(frameData(id: "WXXX", body: body, version: version))
        }
    }

    private static func makeID3Frame(id: String, value: String, version: Int) -> Data {
        var body = Data()
        if version == 4 {
            body.append(3)
            body.append(contentsOf: Array(value.utf8))
            body.append(0)
        } else {
            body.append(1)
            body.append(contentsOf: utf16BigEndian(value))
            body.append(contentsOf: [0, 0])
        }
        return frameData(id: id, body: body, version: version)
    }

    private static func makeID3Comment(_ value: String, version: Int) -> Data {
        var body = Data()
        if version == 4 {
            body.append(3)
            body.append(contentsOf: [0x65, 0x6E, 0x67, 0]) // eng + empty description
            body.append(contentsOf: Array(value.utf8))
            body.append(0)
        } else {
            body.append(1)
            body.append(contentsOf: [0x65, 0x6E, 0x67])
            body.append(contentsOf: [0xFE, 0xFF, 0, 0]) // empty UTF-16 description
            body.append(contentsOf: utf16BigEndian(value))
            body.append(contentsOf: [0, 0])
        }
        return frameData(id: "COMM", body: body, version: version)
    }

    private static func makeID3ArtworkFrame(_ data: Data, version: Int) -> Data {
        var body = Data([0]) // ISO-8859-1 encoding for the empty description.
        body.append(contentsOf: Array(artworkMIMEType(for: data).utf8))
        body.append(0)
        body.append(0) // Other picture type.
        body.append(0) // Empty description.
        body.append(contentsOf: data)
        return frameData(id: "APIC", body: body, version: version)
    }

    private static func artworkMIMEType(for data: Data) -> String {
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "image/jpeg" }
        if data.count >= 8, data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.count >= 6, data.prefix(6).elementsEqual([0x47, 0x49, 0x46, 0x38, 0x37, 0x61])
            || data.prefix(6).elementsEqual([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) { return "image/gif" }
        return "application/octet-stream"
    }

    private static func isUnchanged(_ artwork: TagEditorArtworkChange) -> Bool {
        if case .unchanged = artwork { return true }
        return false
    }

    private static func frameData(id: String, body: Data, version: Int) -> Data {
        var frame = Data(id.utf8)
        frame.append(contentsOf: version == 4 ? synchsafe(body.count) : uint32BE(body.count))
        frame.append(contentsOf: [0, 0])
        frame.append(contentsOf: body)
        return frame
    }

    private static func utf16BigEndian(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = [0xFE, 0xFF]
        bytes.reserveCapacity(value.utf16.count * 2 + 2)
        for unit in value.utf16 {
            bytes.append(UInt8((unit >> 8) & 0xFF))
            bytes.append(UInt8(unit & 0xFF))
        }
        return bytes
    }

    private static func writeM4A(_ fields: TagEditorFields, tagEnabled: Bool, to url: URL) throws {
        tagEditorLogger.debug("Preparing M4A export; path=\(url.path, privacy: .public)")
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["metadata"]) { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            tagEditorLogger.error("M4A metadata load timed out; path=\(url.path, privacy: .public)")
            throw TagEditorError.metadataReadFailed
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.m4a) else {
            tagEditorLogger.error("M4A exporter unavailable; path=\(url.path, privacy: .public)")
            throw TagEditorError.unsupportedFormat(url.pathExtension)
        }

        let temporaryURL = try makeTemporaryFile(for: url, suffix: "m4a")
        removeTemporary(temporaryURL, for: url)
        tagEditorLogger.debug("M4A export output: \(temporaryURL.path, privacy: .public)")
        exporter.outputURL = temporaryURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        if tagEnabled {
            let existing = asset.metadata.filter { !isEditedM4AItem($0) }
            exporter.metadata = existing + makeM4AItems(fields)
        } else {
            exporter.metadata = []
        }
        let exportSemaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { exportSemaphore.signal() }

        guard exportSemaphore.wait(timeout: .now() + 120) == .success else {
            exporter.cancelExport()
            _ = exportSemaphore.wait(timeout: .now() + 5)
            removeTemporary(temporaryURL, for: url)
            tagEditorLogger.error("M4A metadata export timed out; path=\(url.path, privacy: .public)")
            throw TagEditorError.exportTimedOut
        }
        guard exporter.status == .completed else {
            removeTemporary(temporaryURL, for: url)
            let error = exporter.error ?? TagEditorError.exportFailed("The metadata export failed.")
            logTagEditorFailure("M4A metadata export", url: url, error: error)
            throw TagEditorError.exportFailed(error.localizedDescription)
        }
        do {
            // A security-scoped file selection grants access to the file's
            // contents, but it does not necessarily grant permission to
            // replace the directory entry itself. Updating the existing file
            // avoids that extra parent-directory permission requirement and
            // also preserves the file's identity and permissions.
            try overwrite(original: url, with: temporaryURL)
        } catch {
            removeTemporary(temporaryURL, for: url)
            logTagEditorFailure("M4A file write", url: url, error: error)
            throw error
        }
    }

    private static let editedM4AKeys = [
        "©nam", "©ART", "©alb", "aART", "©day", "©gen", "©cmt", "©wrt", "©pub", "trkn", "disk", "tmpo"
    ]

    private static func isEditedM4AItem(_ item: AVMetadataItem) -> Bool {
        let key = (item.key as? String)?.lowercased()
        let identifier = item.identifier?.rawValue.lowercased()
        if item.commonKey == .commonKeyTitle || item.commonKey == .commonKeyArtist
            || item.commonKey == .commonKeyAlbumName || item.commonKey == .commonKeyCreationDate
            || item.commonKey == .commonKeyDescription || item.commonKey == .commonKeyPublisher { return true }
        return editedM4AKeys.contains { candidate in
            let normalized = candidate.lowercased()
            return key == normalized || identifier?.hasSuffix("/\(normalized)") == true
        }
    }

    private static func makeM4AItems(_ fields: TagEditorFields) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ key: AVMetadataKey, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.iTunes
            item.key = key.rawValue as NSString
            item.value = value as NSString
            items.append(item)
        }
        add(.iTunesMetadataKeySongName, fields.title)
        add(.iTunesMetadataKeyArtist, fields.artist)
        add(.iTunesMetadataKeyAlbum, fields.album)
        add(.iTunesMetadataKeyAlbumArtist, fields.albumArtist)
        add(.iTunesMetadataKeyReleaseDate, fields.year)
        add(.iTunesMetadataKeyUserGenre, fields.genre)
        add(.iTunesMetadataKeyUserComment, fields.comment)
        add(.iTunesMetadataKeyComposer, fields.composer)
        add(.iTunesMetadataKeyPublisher, fields.publisher)
        add(.iTunesMetadataKeyTrackNumber, fields.trackNumber)
        add(.iTunesMetadataKeyDiscNumber, fields.discNumber)
        add(.iTunesMetadataKeyBeatsPerMin, fields.bpm)
        return items
    }

    private static func oldAudioEnd(fileLength: UInt64, audioStart: UInt64, input: FileHandle) -> UInt64 {
        guard fileLength >= audioStart + 128 else { return fileLength }
        do {
            input.seek(toFileOffset: fileLength - 128)
            guard let suffix = try input.read(upToCount: 3), suffix.count == 3,
                  suffix[0] == 0x54, suffix[1] == 0x41, suffix[2] == 0x47 else { return fileLength }
            return fileLength - 128
        } catch {
            return fileLength
        }
    }

    private static func makeID3TagData(_ payload: Data, version: Int, paddedTo oldTagSize: UInt64) -> Data {
        var tag = Data([0x49, 0x44, 0x33, UInt8(version), 0, 0])
        tag.append(contentsOf: synchsafe(payload.count))
        tag.append(contentsOf: payload)

        // Keep the existing tag area when the new data fits. This avoids
        // moving the audio stream for ordinary edits and leaves room for the
        // next small change, as ID3-aware taggers commonly do.
        if oldTagSize >= UInt64(tag.count), oldTagSize <= UInt64(Int.max) {
            tag.append(Data(repeating: 0, count: Int(oldTagSize) - tag.count))
        }
        return tag
    }

    /// Rewrites the leading ID3 block without replacing the directory entry.
    /// The audio and optional trailing ID3v1 bytes are shifted in overlapping-
    /// safe order, then the file is truncated to its exact new length.
    private static func rewriteID3InPlace(
        to url: URL,
        oldTagSize: UInt64,
        contentEnd: UInt64,
        fileLength: UInt64,
        newTag: Data,
        preserveTrailingID3v1: Bool
    ) throws {
        guard oldTagSize <= contentEnd, contentEnd <= fileLength else {
            throw TagEditorError.invalidFile
        }

        let trailingLength = preserveTrailingID3v1 ? fileLength - contentEnd : 0
        let preservedLength = (contentEnd - oldTagSize) + trailingLength
        let newTagSize = UInt64(newTag.count)
        guard newTagSize <= UInt64.max - preservedLength else {
            throw TagEditorError.exportFailed("The metadata tag is too large.")
        }
        let newFileLength = newTagSize + preservedLength
        tagEditorLogger.debug("MP3 update preflight; path=\(url.path, privacy: .public); writable=\(FileManager.default.isWritableFile(atPath: url.path)); oldSize=\(fileLength); newSize=\(newFileLength)")
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            logTagEditorFailure("Opening MP3 for update", url: url, error: error)
            throw TagEditorError.fileWriteFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        let oldContentStart = oldTagSize
        let newContentStart = newTagSize
        if newContentStart > oldContentStart {
            // Grow before moving right so the destination cannot run past
            // the current EOF. The source range ends at contentEnd when the
            // old ID3v1 tag is being removed.
            try handle.truncate(atOffset: newFileLength)
            var remaining = preservedLength
            while remaining > 0 {
                let readLength = Int(min(UInt64(1024 * 1024), remaining))
                let sourceOffset = oldContentStart + remaining - UInt64(readLength)
                let destinationOffset = newContentStart + remaining - UInt64(readLength)
                handle.seek(toFileOffset: sourceOffset)
                guard let chunk = try handle.read(upToCount: readLength), chunk.count == readLength else {
                    throw TagEditorError.fileWriteFailed("The audio stream ended unexpectedly.")
                }
                handle.seek(toFileOffset: destinationOffset)
                try handle.write(contentsOf: chunk)
                remaining -= UInt64(readLength)
            }
        } else if newContentStart < oldContentStart {
            // Move left from the beginning. Reading a complete chunk before
            // writing it makes the overlap safe, while the next source chunk
            // remains untouched.
            var moved: UInt64 = 0
            while moved < preservedLength {
                let readLength = Int(min(UInt64(1024 * 1024), preservedLength - moved))
                handle.seek(toFileOffset: oldContentStart + moved)
                guard let chunk = try handle.read(upToCount: readLength), chunk.count == readLength else {
                    throw TagEditorError.fileWriteFailed("The audio stream ended unexpectedly.")
                }
                handle.seek(toFileOffset: newContentStart + moved)
                try handle.write(contentsOf: chunk)
                moved += UInt64(readLength)
            }
        }

        handle.seek(toFileOffset: 0)
        if !newTag.isEmpty {
            try handle.write(contentsOf: newTag)
        }
        try handle.truncate(atOffset: newFileLength)
        try handle.synchronize()
    }

    private static func makeTemporaryFile(for original: URL, suffix: String) throws -> URL {
        let parent = original.deletingLastPathComponent().standardizedFileURL
        guard parent.path != "/",
              (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw TagEditorError.fileWriteFailed("The parent folder is unavailable.")
        }
        let name = ".macamp-tag-\(UUID().uuidString).\(suffix)"
        let candidate = parent.appendingPathComponent(name, isDirectory: false)
        guard candidate.deletingLastPathComponent().standardizedFileURL == parent else {
            throw TagEditorError.fileWriteFailed("The temporary path is invalid.")
        }
        if FileManager.default.createFile(atPath: candidate.path, contents: nil) {
            return candidate
        }

        // A security-scoped bookmark may authorize the audio file itself but
        // not creation of a sibling in its directory. Use the process
        // temporary directory as a safe fallback while keeping the same
        // atomic replacement path for the original file.
        let fallbackParent = FileManager.default.temporaryDirectory.standardizedFileURL
        let fallback = fallbackParent.appendingPathComponent(name, isDirectory: false)
        guard fallback.deletingLastPathComponent().standardizedFileURL == fallbackParent else {
            throw TagEditorError.fileWriteFailed("The fallback temporary path is invalid.")
        }
        guard FileManager.default.createFile(atPath: fallback.path, contents: nil) else {
            throw TagEditorError.fileWriteFailed("Could not create a temporary file next to the audio file or in the system temporary folder.")
        }
        return fallback
    }

    private static func overwrite(original: URL, with temporary: URL) throws {
        guard isSafeRegularFile(original), isSafeRegularFile(temporary),
              original.standardizedFileURL != temporary.standardizedFileURL else {
            tagEditorLogger.error("M4A overwrite rejected; original=\(original.path, privacy: .public); temporary=\(temporary.path, privacy: .public)")
            throw TagEditorError.fileWriteFailed("The source or destination file is unavailable.")
        }

        tagEditorLogger.debug("Overwriting existing file contents; original=\(original.path, privacy: .public); temporary=\(temporary.path, privacy: .public)")

        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: temporary)
        } catch {
            logTagEditorFailure("Opening M4A export", url: temporary, error: error)
            throw TagEditorError.fileWriteFailed(error.localizedDescription)
        }
        defer { try? source.close() }

        let sourceLength: UInt64
        do {
            sourceLength = try source.seekToEnd()
            try source.seek(toOffset: 0)
        } catch {
            logTagEditorFailure("Inspecting M4A export", url: temporary, error: error)
            throw TagEditorError.fileWriteFailed(error.localizedDescription)
        }
        tagEditorLogger.debug("M4A export size=\(sourceLength) bytes")

        let destination: FileHandle
        do {
            destination = try FileHandle(forUpdating: original)
        } catch {
            logTagEditorFailure("Opening original file for update", url: original, error: error)
            throw TagEditorError.fileWriteFailed(error.localizedDescription)
        }
        defer { try? destination.close() }

        do {
            try destination.seek(toOffset: 0)
            while true {
                guard let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                try destination.write(contentsOf: chunk)
            }
            try destination.truncate(atOffset: sourceLength)
            try destination.synchronize()
        } catch {
            logTagEditorFailure("Writing M4A contents", url: original, error: error)
            throw TagEditorError.fileWriteFailed(error.localizedDescription)
        }
        tagEditorLogger.debug("M4A contents written successfully; path=\(original.path, privacy: .public); size=\(sourceLength) bytes")
    }

    private static func removeTemporary(_ temporary: URL, for original: URL) {
        let parent = original.deletingLastPathComponent().standardizedFileURL
        let processTemporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard temporary.deletingLastPathComponent().standardizedFileURL == parent
                || temporary.deletingLastPathComponent().standardizedFileURL == processTemporaryDirectory,
              temporary.lastPathComponent.hasPrefix(".macamp-tag-") else { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    private static func synchsafe(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)
        ]
    }

    private static func synchsafeValue(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    private static func uint32BE(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

final class TagEditorPanelView: NSView {
    private let model: TagEditorModel
    private let onSave: (TagEditorFields) -> Void
    private let onCancel: () -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private var observations = Set<AnyCancellable>()

    private let fileLabel = NSTextField(labelWithString: "")
    private let trackField = NSTextField()
    private let titleField = NSTextField()
    private let artistField = NSTextField()
    private let albumField = NSTextField()
    private let albumArtistField = NSTextField()
    private let yearField = NSTextField()
    private let genreField = NSComboBox()
    private let commentView = NSTextView()
    private let composerField = NSTextField()
    private let publisherField = NSTextField()
    private let originalArtistField = NSTextField()
    private let copyrightField = NSTextField()
    private let urlField = NSTextField()
    private let encodedByField = NSTextField()
    private let formatView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let commentScroll = NSScrollView()
    private let formatScroll = NSScrollView()
    private let artworkContent = TagEditorArtworkContentView()
    private let metadataTypeSwitch = NSButton(checkboxWithTitle: "Metadata", target: nil, action: nil)
    private let metadataBox = NSBox()
    private let artworkBox = NSBox()
    private let formatBox = NSBox()
    private let metadataContent: TagEditorFormContentView
    private let previousButton = NSButton(title: "←", target: nil, action: nil)
    private let nextButton = NSButton(title: "→", target: nil, action: nil)
    private lazy var saveButton = NSButton(title: "OK", target: self, action: #selector(save(_:)))
    private lazy var cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
    private var hasPreviousFile = false
    private var hasNextFile = false

    var initialFirstResponder: NSView { titleField }

    init(
        model: TagEditorModel,
        onSave: @escaping (TagEditorFields) -> Void,
        onCancel: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) {
        self.model = model
        self.onSave = onSave
        self.onCancel = onCancel
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.metadataContent = TagEditorFormContentView(
            trackField: trackField,
            titleField: titleField,
            artistField: artistField,
            albumField: albumField,
            albumArtistField: albumArtistField,
            yearField: yearField,
            genreField: genreField,
            commentScroll: commentScroll,
            composerField: composerField,
            publisherField: publisherField,
            originalArtistField: originalArtistField,
            copyrightField: copyrightField,
            urlField: urlField,
            encodedByField: encodedByField,
            metadataTypeSwitch: metadataTypeSwitch
        )
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        artworkContent.onChoose = { [weak self] in self?.chooseArtwork() }
        artworkContent.onRemove = { [weak self] in self?.removeArtwork() }
        metadataContent.onMetadataTypeToggle = { [weak self] enabled in self?.model.setTagEnabled(enabled) }
        metadataContent.onGetFromFilename = { [weak self] in self?.model.getFromFilename() }
        metadataContent.onCopyFromID3v1 = { [weak self] in self?.model.copyFromID3v1() }
        metadataContent.onReloadWithEncoding = { [weak self] in
            self?.model.reload(with: .windowsCP1251)
        }
        metadataContent.onUndoChanges = { [weak self] in self?.model.undoChanges() }
        metadataContent.onFieldsChanged = { [weak self] in self?.updateActionButtons() }
        setup()
        model.$values.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyModel() }.store(in: &observations)
        model.$fileName.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyModel() }.store(in: &observations)
        model.$isLoading.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyModel() }.store(in: &observations)
        model.$isSaving.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyModel() }.store(in: &observations)
        model.$errorMessage.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyModel() }.store(in: &observations)
        applyModel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        fileLabel.font = NSFont.systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.alignment = .left

        configureField(trackField)
        configureField(titleField)
        configureField(artistField)
        configureField(albumField)
        configureField(albumArtistField)
        configureField(yearField)
        configureField(composerField)
        configureField(publisherField)
        configureField(originalArtistField)
        configureField(copyrightField)
        configureField(urlField)
        configureField(encodedByField)

        configureField(genreField)
        genreField.isEditable = true
        genreField.usesDataSource = false
        genreField.controlSize = .small
        genreField.font = NSFont.systemFont(ofSize: 12)
        genreField.addItems(withObjectValues: Self.genres)

        configureCommentView()
        configureReadOnlyText(formatView)
        configureTextScroll(commentScroll, document: commentView, border: .bezelBorder)
        configureTextScroll(formatScroll, document: formatView, border: .bezelBorder)
        configureNavigationButton(previousButton, toolTip: "Previous file in playlist", action: #selector(previous(_:)))
        configureNavigationButton(nextButton, toolTip: "Next file in playlist", action: #selector(next(_:)))

        configureBox(metadataBox, title: "Metadata", content: metadataContent)
        configureBox(artworkBox, title: "Album art", content: artworkContent)
        configureBox(formatBox, title: "Format Info", content: formatScroll)
        addSubview(fileLabel)
        addSubview(metadataBox)
        addSubview(artworkBox)
        addSubview(formatBox)
        addSubview(statusLabel)
        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(cancelButton)
        addSubview(saveButton)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .left
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
    }

    private func configureBox(_ box: NSBox, title: String, content: NSView) {
        box.title = title
        box.titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 10, height: 10)
        box.contentView = content
        content.autoresizingMask = [.width, .height]
    }

    private func configureTextScroll(_ scroll: NSScrollView, document: NSTextView, border: NSBorderType) {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = border
        scroll.documentView = document
        scroll.autoresizingMask = [.width, .height]
    }

    private func configureField(_ field: NSTextField) {
        field.font = NSFont.systemFont(ofSize: 12)
        field.controlSize = .small
        field.placeholderString = ""
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byTruncatingTail
        field.autoresizingMask = [.width]
    }

    private func configureCommentView() {
        commentView.font = NSFont.systemFont(ofSize: 12)
        commentView.isEditable = true
        commentView.isSelectable = true
        commentView.isRichText = false
        commentView.allowsUndo = true
        commentView.textContainerInset = NSSize(width: 4, height: 4)
        commentView.autoresizingMask = [.width, .height]
    }

    private func configureReadOnlyText(_ view: NSTextView) {
        view.font = NSFont.systemFont(ofSize: 12)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.autoresizingMask = [.width, .height]
    }

    private func configureNavigationButton(_ button: NSButton, toolTip: String, action: Selector) {
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.controlSize = .small
        button.bezelStyle = .smallSquare
        button.font = NSFont.systemFont(ofSize: 14)
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let margin: CGFloat = 16
        let buttonY: CGFloat = 14
        let buttonHeight: CGFloat = 26
        let mainBottom = buttonY + buttonHeight + 12
        let fileHeight: CGFloat = 18
        let fileY = max(mainBottom + 10, bounds.height - margin - fileHeight)
        let navigationGap: CGFloat = 0
        let navigationWidth: CGFloat = 40
        let nextButtonX = bounds.width - margin - navigationWidth
        let previousButtonX = nextButtonX - navigationGap - navigationWidth
        let navigationY = fileY - 2
        fileLabel.frame = NSRect(
            x: margin,
            y: fileY,
            width: max(0, previousButtonX - navigationGap - margin),
            height: fileHeight
        )
        previousButton.frame = NSRect(x: previousButtonX, y: navigationY, width: navigationWidth, height: 22)
        nextButton.frame = NSRect(x: nextButtonX, y: navigationY, width: navigationWidth, height: 22)

        let mainTop = fileY - 9
        let mainHeight = max(420, mainTop - mainBottom)
        let leftWidth: CGFloat = 270
        let gap: CGFloat = 14
        let availableWidth = max(0, bounds.width - margin * 2)
        let metadataWidth = max(420, availableWidth - leftWidth - gap)
        let leftX = margin
        let metadataX = min(bounds.width - margin - metadataWidth, leftX + leftWidth + gap)
        let formatHeight = max(155, mainHeight * 0.40)
        let artworkHeight = max(180, mainHeight - formatHeight - gap)
        metadataBox.frame = NSRect(x: metadataX, y: mainBottom, width: metadataWidth, height: mainHeight)
        formatBox.frame = NSRect(x: leftX, y: mainBottom, width: leftWidth, height: formatHeight)
        artworkBox.frame = NSRect(x: leftX, y: formatBox.frame.maxY + gap, width: leftWidth, height: artworkHeight)

        setContentFrame(metadataBox, metadataContent)
        setContentFrame(artworkBox, artworkContent)
        setContentFrame(formatBox, formatScroll)

        statusLabel.frame = NSRect(x: margin, y: buttonY + 4, width: max(0, bounds.width - margin * 2 - 190), height: 18)
        cancelButton.frame = NSRect(x: bounds.width - margin - 176, y: buttonY, width: 82, height: buttonHeight)
        saveButton.frame = NSRect(x: bounds.width - margin - 86, y: buttonY, width: 86, height: buttonHeight)
    }

    private func setContentFrame(_ box: NSBox, _ content: NSView) {
        let width = max(0, box.bounds.width - 20)
        let height = max(0, box.bounds.height - 34)
        content.frame = NSRect(x: 10, y: 10, width: width, height: height)
    }

    private func applyModel() {
        let fields = model.values.fields
        let canEdit = model.values.canWrite && !model.isLoading && !model.isSaving
        trackField.stringValue = fields.trackNumber
        titleField.stringValue = fields.title
        artistField.stringValue = fields.artist
        albumField.stringValue = fields.album
        albumArtistField.stringValue = fields.albumArtist
        yearField.stringValue = fields.year
        genreField.stringValue = fields.genre
        commentView.string = fields.comment
        composerField.stringValue = fields.composer
        publisherField.stringValue = fields.publisher
        originalArtistField.stringValue = fields.originalArtist
        copyrightField.stringValue = fields.copyright
        urlField.stringValue = fields.url
        encodedByField.stringValue = fields.encodedBy
        formatView.string = model.values.formatInfo
        fileLabel.stringValue = model.fileName
        artworkContent.image = model.values.artworkData.flatMap { NSImage(data: $0) }
        artworkContent.isEditingEnabled = model.values.supportsArtworkEditing && canEdit
        metadataContent.setMetadataTypeName(
            model.values.metadataTypeName,
            isOn: model.values.tagEnabled,
            isEnabled: model.values.canToggleTag && canEdit
        )
        metadataContent.setMetadataFieldsEnabled(model.values.tagEnabled && canEdit)
        metadataContent.setID3FieldsEnabled(model.values.supportsID3Fields && model.values.tagEnabled && canEdit)
        updateNavigationButtonState()

        if let error = model.errorMessage {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else if model.isLoading {
            statusLabel.stringValue = "Reading metadata…"
            statusLabel.textColor = .secondaryLabelColor
        } else if model.isSaving {
            statusLabel.stringValue = "Writing metadata…"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = model.values.supportMessage
            statusLabel.textColor = .secondaryLabelColor
        }
        saveButton.isEnabled = model.values.canWrite && !model.isLoading && !model.isSaving
        cancelButton.isEnabled = !model.isSaving
        updateActionButtons()
    }

    @objc private func save(_ sender: Any?) {
        onSave(currentFields())
    }

    func setNavigationAvailability(previous: Bool, next: Bool) {
        hasPreviousFile = previous
        hasNextFile = next
        updateNavigationButtonState()
    }

    private func updateNavigationButtonState() {
        let enabled = !model.isLoading && !model.isSaving
        previousButton.isEnabled = hasPreviousFile && enabled
        nextButton.isEnabled = hasNextFile && enabled
    }

    @objc private func previous(_ sender: Any?) {
        navigateToAnotherFile(onPrevious)
    }

    @objc private func next(_ sender: Any?) {
        navigateToAnotherFile(onNext)
    }

    private func navigateToAnotherFile(_ action: () -> Void) {
        guard !model.isLoading, !model.isSaving else { return }
        guard model.hasUnsavedChanges(fields: currentFields()) else {
            action()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Discard changes?"
        alert.informativeText = "Your changes will be lost when you open another file."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func currentFields() -> TagEditorFields {
        var fields = TagEditorFields()
        // Disc number and BPM are intentionally hidden from this layout, but
        // their existing values must survive when the other metadata changes.
        fields.discNumber = model.values.fields.discNumber
        fields.bpm = model.values.fields.bpm
        fields.trackNumber = trackField.stringValue
        fields.title = titleField.stringValue
        fields.artist = artistField.stringValue
        fields.album = albumField.stringValue
        fields.albumArtist = albumArtistField.stringValue
        fields.year = yearField.stringValue
        fields.genre = genreField.stringValue
        fields.comment = commentView.string
        fields.composer = composerField.stringValue
        fields.publisher = publisherField.stringValue
        fields.originalArtist = originalArtistField.stringValue
        fields.copyright = copyrightField.stringValue
        fields.url = urlField.stringValue
        fields.encodedBy = encodedByField.stringValue
        return fields
    }

    private func updateActionButtons() {
        let isBusy = model.isLoading || model.isSaving
        let canEdit = model.values.canWrite && !isBusy
        metadataContent.setActionAvailability(
            getFromFilename: canEdit && model.canGetFromFilename,
            copyFromID3v1: canEdit && model.values.canCopyID3v1,
            reloadWithEncoding: canEdit && model.values.tagEnabled && model.values.supportsEncodingReload,
            undoChanges: canEdit && model.hasUnsavedChanges(fields: currentFields())
        )
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .gif, .tiff, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let beganScope = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if beganScope { url.stopAccessingSecurityScopedResource() }
        guard let data, data.count <= 64 * 1024 * 1024, NSImage(data: data) != nil else { return }
        model.setArtwork(data)
    }

    private func removeArtwork() {
        model.removeArtwork()
    }

    @objc private func cancel(_ sender: Any?) { onCancel() }

    private static let genres = [
        "Blues", "Classical", "Country", "Dance", "Disco", "Electronic", "Folk",
        "Funk", "Hip-Hop", "Jazz", "Metal", "New Age", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Soundtrack", "Alternative", "Ambient", "House", "Techno",
        "Trance", "Vocal"
    ]
}

private final class TagEditorArtworkContentView: NSView {
    private let imageView = NSImageView()
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Image", target: nil, action: nil)

    var onChoose: (() -> Void)?
    var onRemove: (() -> Void)?
    var image: NSImage? {
        didSet {
            imageView.image = image
            updateButtonState()
        }
    }
    var isEditingEnabled = false {
        didSet { updateButtonState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .grayBezel
        imageView.image = nil
        imageView.autoresizingMask = [.width, .height]

        chooseButton.target = self
        chooseButton.action = #selector(choose(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        chooseButton.controlSize = .small
        removeButton.controlSize = .small
        chooseButton.bezelStyle = .rounded
        removeButton.bezelStyle = .rounded

        addSubview(imageView)
        addSubview(chooseButton)
        addSubview(removeButton)
        updateButtonState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let buttonHeight: CGFloat = 24
        let buttonWidth = max(0, (bounds.width - gap) * 0.5)
        chooseButton.frame = NSRect(x: 0, y: bounds.height - buttonHeight, width: buttonWidth, height: buttonHeight)
        removeButton.frame = NSRect(x: buttonWidth + gap, y: bounds.height - buttonHeight, width: buttonWidth, height: buttonHeight)
        imageView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - buttonHeight - gap))
    }

    private func updateButtonState() {
        chooseButton.isEnabled = isEditingEnabled
        removeButton.isEnabled = isEditingEnabled && image != nil
    }

    @objc private func choose(_ sender: Any?) { onChoose?() }
    @objc private func remove(_ sender: Any?) { onRemove?() }
}

final class TagEditorFormContentView: NSView, NSTextFieldDelegate, NSComboBoxDelegate, NSTextViewDelegate {
    private let trackField: NSTextField
    private let titleField: NSTextField
    private let artistField: NSTextField
    private let albumField: NSTextField
    private let albumArtistField: NSTextField
    private let yearField: NSTextField
    private let genreField: NSComboBox
    private let commentScroll: NSScrollView
    private let composerField: NSTextField
    private let publisherField: NSTextField
    private let originalArtistField: NSTextField
    private let copyrightField: NSTextField
    private let urlField: NSTextField
    private let encodedByField: NSTextField
    private let metadataTypeSwitch: NSButton
    var onMetadataTypeToggle: ((Bool) -> Void)?
    var onGetFromFilename: (() -> Void)?
    var onCopyFromID3v1: (() -> Void)?
    var onReloadWithEncoding: (() -> Void)?
    var onUndoChanges: (() -> Void)?
    var onFieldsChanged: (() -> Void)?

    private let trackLabel = NSTextField(labelWithString: "Track #:")
    private let titleLabel = NSTextField(labelWithString: "Title:")
    private let artistLabel = NSTextField(labelWithString: "Artist:")
    private let albumLabel = NSTextField(labelWithString: "Album:")
    private let albumArtistLabel = NSTextField(labelWithString: "Album Artist:")
    private let yearLabel = NSTextField(labelWithString: "Year:")
    private let genreLabel = NSTextField(labelWithString: "Genre:")
    private let commentLabel = NSTextField(labelWithString: "Comment:")
    private let composerLabel = NSTextField(labelWithString: "Composer:")
    private let publisherLabel = NSTextField(labelWithString: "Publisher:")
    private let originalArtistLabel = NSTextField(labelWithString: "Orig. Artist:")
    private let copyrightLabel = NSTextField(labelWithString: "Copyright:")
    private let urlLabel = NSTextField(labelWithString: "URL:")
    private let encodedByLabel = NSTextField(labelWithString: "Encoded by:")
    private let getFromFilenameButton = NSButton(title: "Get from filename", target: nil, action: nil)
    private let copyFromID3v1Button = NSButton(title: "Copy from ID3v1", target: nil, action: nil)
    private let reloadWithEncodingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let undoChangesButton = NSButton(title: "Undo changes", target: nil, action: nil)

    init(
        trackField: NSTextField,
        titleField: NSTextField,
        artistField: NSTextField,
        albumField: NSTextField,
        albumArtistField: NSTextField,
        yearField: NSTextField,
        genreField: NSComboBox,
        commentScroll: NSScrollView,
        composerField: NSTextField,
        publisherField: NSTextField,
        originalArtistField: NSTextField,
        copyrightField: NSTextField,
        urlField: NSTextField,
        encodedByField: NSTextField,
        metadataTypeSwitch: NSButton
    ) {
        self.trackField = trackField
        self.titleField = titleField
        self.artistField = artistField
        self.albumField = albumField
        self.albumArtistField = albumArtistField
        self.yearField = yearField
        self.genreField = genreField
        self.commentScroll = commentScroll
        self.composerField = composerField
        self.publisherField = publisherField
        self.originalArtistField = originalArtistField
        self.copyrightField = copyrightField
        self.urlField = urlField
        self.encodedByField = encodedByField
        self.metadataTypeSwitch = metadataTypeSwitch
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        metadataTypeSwitch.controlSize = .small
        metadataTypeSwitch.font = NSFont.systemFont(ofSize: 12)
        metadataTypeSwitch.target = self
        metadataTypeSwitch.action = #selector(metadataTypeChanged(_:))
        [
            metadataTypeSwitch, trackLabel, titleLabel, artistLabel, albumLabel,
            albumArtistLabel, yearLabel, genreLabel, commentLabel, composerLabel,
            publisherLabel, originalArtistLabel, copyrightLabel, urlLabel, encodedByLabel,
            trackField, titleField, artistField,
            albumField, albumArtistField, yearField, genreField, commentScroll,
            composerField, publisherField, originalArtistField, copyrightField,
            urlField, encodedByField
        ].forEach(addSubview)
        [trackLabel, titleLabel, artistLabel, albumLabel,
         albumArtistLabel, yearLabel, genreLabel, commentLabel, composerLabel,
         publisherLabel, originalArtistLabel, copyrightLabel, urlLabel, encodedByLabel].forEach {
            $0.alignment = .right
            $0.font = NSFont.systemFont(ofSize: 12)
        }
        configureActionButton(getFromFilenameButton, action: #selector(getFromFilename(_:)))
        configureActionButton(copyFromID3v1Button, action: #selector(copyFromID3v1(_:)))
        configureActionButton(undoChangesButton, action: #selector(undoChanges(_:)))
        reloadWithEncodingButton.controlSize = .small
        reloadWithEncodingButton.font = NSFont.systemFont(ofSize: 11)
        reloadWithEncodingButton.bezelStyle = .rounded
        reloadWithEncodingButton.addItem(withTitle: "Reload with encoding")
        reloadWithEncodingButton.addItem(withTitle: "Windows-1251")
        reloadWithEncodingButton.target = self
        reloadWithEncodingButton.action = #selector(reloadWithEncoding(_:))
        reloadWithEncodingButton.autoenablesItems = false
        addSubview(getFromFilenameButton)
        addSubview(copyFromID3v1Button)
        addSubview(reloadWithEncodingButton)
        addSubview(undoChangesButton)
        [
            trackField, titleField, artistField, albumField, albumArtistField,
            yearField, genreField, composerField, publisherField,
            originalArtistField, copyrightField, urlField, encodedByField
        ].forEach { $0.delegate = self }
        if let commentView = commentScroll.documentView as? NSTextView {
            commentView.delegate = self
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setID3FieldsEnabled(_ enabled: Bool) {
        [originalArtistField, copyrightField, urlField, encodedByField].forEach { $0.isEnabled = enabled }
        [originalArtistLabel, copyrightLabel, urlLabel, encodedByLabel].forEach {
            $0.textColor = enabled ? .labelColor : .disabledControlTextColor
        }
    }

    func setMetadataTypeName(_ name: String, isOn: Bool, isEnabled: Bool) {
        metadataTypeSwitch.title = name
        metadataTypeSwitch.state = isOn ? .on : .off
        metadataTypeSwitch.isEnabled = isEnabled
    }

    func setMetadataFieldsEnabled(_ enabled: Bool) {
        [
            trackField, titleField, artistField, albumField, albumArtistField,
            yearField, genreField, composerField, publisherField,
            originalArtistField, copyrightField, urlField, encodedByField
        ].forEach { $0.isEnabled = enabled }
        if let commentView = commentScroll.documentView as? NSTextView {
            commentView.isEditable = enabled
            commentView.isSelectable = enabled
        }
        commentScroll.alphaValue = enabled ? 1 : 0.65
        [
            trackLabel, titleLabel, artistLabel, albumLabel, albumArtistLabel,
            yearLabel, genreLabel, commentLabel, composerLabel, publisherLabel,
            originalArtistLabel, copyrightLabel, urlLabel, encodedByLabel
        ].forEach { $0.textColor = enabled ? .labelColor : .disabledControlTextColor }
    }

    func setActionAvailability(
        getFromFilename: Bool,
        copyFromID3v1: Bool,
        reloadWithEncoding: Bool,
        undoChanges: Bool
    ) {
        getFromFilenameButton.isEnabled = getFromFilename
        copyFromID3v1Button.isEnabled = copyFromID3v1
        reloadWithEncodingButton.isEnabled = reloadWithEncoding
        undoChangesButton.isEnabled = undoChanges
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let labelWidth: CGFloat = 110
        let fieldX = labelWidth + 8
        let fieldWidth = max(70, bounds.width - fieldX - 2)
        let rowHeight: CGFloat = 22
        let gap: CGFloat = 4
        var y: CGFloat = 0

        let trackFieldWidth: CGFloat = 60
        let trackFieldX = max(0, bounds.width - trackFieldWidth)
        let trackLabelWidth: CGFloat = 54
        let trackLabelX = max(0, trackFieldX - trackLabelWidth - 8)
        metadataTypeSwitch.frame = NSRect(x: fieldX, y: y, width: max(100, trackLabelX - fieldX - 8), height: rowHeight)
        trackLabel.frame = NSRect(x: trackLabelX, y: y, width: trackLabelWidth, height: rowHeight)
        trackField.frame = NSRect(x: trackFieldX, y: y, width: trackFieldWidth, height: rowHeight)
        y += rowHeight + gap

        func setRow(_ label: NSTextField, _ field: NSTextField) {
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
            field.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: rowHeight)
            y += rowHeight + gap
        }
        setRow(titleLabel, titleField)
        setRow(artistLabel, artistField)
        setRow(albumLabel, albumField)
        setRow(albumArtistLabel, albumArtistField)

        yearLabel.frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
        yearField.frame = NSRect(x: fieldX, y: y, width: 68, height: rowHeight)
        genreLabel.frame = NSRect(x: fieldX + 76, y: y, width: 48, height: rowHeight)
        genreField.frame = NSRect(x: fieldX + 130, y: y, width: max(70, bounds.width - fieldX - 132), height: rowHeight)
        y += rowHeight + gap

        commentLabel.frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
        commentScroll.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 58)
        y += 58 + gap
        setRow(composerLabel, composerField)
        setRow(originalArtistLabel, originalArtistField)
        setRow(copyrightLabel, copyrightField)
        setRow(urlLabel, urlField)
        setRow(encodedByLabel, encodedByField)
        setRow(publisherLabel, publisherField)

        let actionGap: CGFloat = 6
        let actionHeight: CGFloat = 24
        let actionRowGap: CGFloat = 4
        let actionRowWidth = (bounds.width - actionGap) * 0.5
        let actionY = max(y + actionGap, bounds.height - actionHeight * 2 - actionRowGap)
        getFromFilenameButton.frame = NSRect(x: 0, y: actionY, width: actionRowWidth, height: actionHeight)
        copyFromID3v1Button.frame = NSRect(x: actionRowWidth + actionGap, y: actionY, width: actionRowWidth, height: actionHeight)
        let secondActionY = actionY + actionHeight + actionRowGap
        reloadWithEncodingButton.frame = NSRect(x: 0, y: secondActionY, width: actionRowWidth, height: actionHeight)
        undoChangesButton.frame = NSRect(x: actionRowWidth + actionGap, y: secondActionY, width: actionRowWidth, height: actionHeight)
    }

    @objc private func metadataTypeChanged(_ sender: NSButton) {
        onMetadataTypeToggle?(sender.state == .on)
        onFieldsChanged?()
    }

    @objc private func getFromFilename(_ sender: NSButton) { onGetFromFilename?() }
    @objc private func copyFromID3v1(_ sender: NSButton) { onCopyFromID3v1?() }

    @objc private func reloadWithEncoding(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem == 1 else { return }
        onReloadWithEncoding?()
        sender.selectItem(at: 0)
    }

    @objc private func undoChanges(_ sender: NSButton) { onUndoChanges?() }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    func controlTextDidChange(_ obj: Notification) { onFieldsChanged?() }
    func textDidChange(_ notification: Notification) { onFieldsChanged?() }
}
