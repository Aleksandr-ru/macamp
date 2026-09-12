import AVFoundation
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// The persistent, window-independent playlist domain model.  Windows only
/// render this state; hiding a window never destroys a playlist or its work.
final class PlaylistEntry: ObservableObject, Identifiable {
    let id: UUID
    var url: URL
    /// A path from NSOpenPanel is only authorised for this process. Store its
    /// sandbox bookmark alongside the playlist entry for later launches.
    var bookmarkData: Data?
    @Published var title: String
    /// Kept separately from the playlist label (which remains “Artist - Title”)
    /// so system integrations do not have to parse user-visible text.
    @Published var artist: String?
    @Published var trackTitle: String?
    @Published var duration: TimeInterval?
    @Published var metadataIsAvailable = false
    /// Numeric POPM value, not the five-star presentation value. Zero means no
    /// usable macAmp POPM record is available for this file.
    @Published var rating: UInt8 = 0
    /// Runtime-only result of an unsuccessful read/playback attempt.  This is
    /// deliberately absent from StoredEntry: a fresh launch retries files.
    @Published var hasPlaybackError = false

    init(id: UUID = UUID(), url: URL, bookmarkData: Data? = nil, title: String? = nil,
         artist: String? = nil, trackTitle: String? = nil, duration: TimeInterval? = nil, metadataIsAvailable: Bool = false,
         rating: UInt8 = 0) {
        self.id = id; self.url = url; self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist
        self.trackTitle = trackTitle
        self.bookmarkData = bookmarkData
        self.duration = duration; self.metadataIsAvailable = metadataIsAvailable; self.rating = rating
    }
}

final class PlaylistModel: ObservableObject, Identifiable {
    enum ScannerState: Equatable { case idle, adding(Int), scanningFolder(Int), readingMetadata(processed: Int, total: Int), paused }
    struct SortingProgress: Equatable {
        let processed: Int
        let total: Int
        let phase: String
    }
    let id: UUID
    @Published var name: String
    @Published var entries: [PlaylistEntry]
    @Published var selectedIDs = Set<UUID>()
    /// The fixed end of a Shift-click range. This is deliberately transient:
    /// selection itself is restored, while Finder-style range gestures begin
    /// from the first currently selected row after an app relaunch.
    var selectionAnchorID: UUID?
    /// Remembers this editor's playback cursor independently from the global
    /// active source, so it can be resumed after another playlist was active.
    @Published var lastPlayedEntryID: UUID?
    /// Scheduler-only state. Publishing it would invalidate the entire lazy
    /// playlist view on every scroll-frame, which is especially expensive for
    /// a playlist with tens of thousands of rows.
    var scrollPosition = 0
    /// Actual number of list rows visible in this editor.  It changes when a
    /// floating Playlist window is resized and must not be a fixed constant.
    var visibleEntryCount = 18
    @Published var isVisible = true
    @Published var isWindowShaded = false
    @Published var windowFrame: CGRect?
    /// Changes only when rows are inserted or removed. The playlist editor
    /// uses it to discard LazyVStack's cached row hosts after an index shift;
    /// selection and metadata updates do not touch it.
    @Published var structureRevision = 0
    /// Logical (unshaded) editor dimensions.  A shaded frame is only 14 px
    /// high and therefore cannot be used to restore the expanded height.
    @Published var unshadedWindowWidth: CGFloat?
    @Published var unshadedWindowHeight: CGFloat?
    @Published var scannerState: ScannerState = .idle
    @Published var sortingProgress: SortingProgress?
    @Published var isDirty = false
    @Published var automaticRatingEnabled: Bool
    var fileURL: URL?
    private var cachedTotalDuration: TimeInterval

    init(id: UUID = UUID(), name: String = "New Playlist", entries: [PlaylistEntry] = [], fileURL: URL? = nil,
         automaticRatingEnabled: Bool = RatingPreferences.shared.enableForAllPlaylists) {
        self.id = id; self.name = name; self.entries = entries; self.fileURL = fileURL
        self.automaticRatingEnabled = automaticRatingEnabled
        cachedTotalDuration = entries.compactMap(\.duration).reduce(0, +)
    }
    var totalDuration: TimeInterval { cachedTotalDuration }
    var hasUnknownDurations: Bool { entries.contains { $0.duration == nil } }
    func recalculateTotalDuration() { cachedTotalDuration = entries.compactMap(\.duration).reduce(0, +) }
    func appendToTotalDuration(_ newEntries: [PlaylistEntry]) {
        cachedTotalDuration += newEntries.compactMap(\.duration).reduce(0, +)
    }
    func replaceTotalDuration(_ previous: TimeInterval?, with updated: TimeInterval?) {
        cachedTotalDuration += (updated ?? 0) - (previous ?? 0)
    }
    func clearTotalDuration() { cachedTotalDuration = 0 }
}

struct PlaylistDragPayload: Codable {
    let sourcePlaylistID: UUID
    let entryIDs: [UUID]
}

enum PlaylistDragTransfer {
    static let typeIdentifier = "ru.aleksandr.macAmp.playlist-entry"
}

private enum PlaylistURLImportError: LocalizedError {
    case emptyURL
    case invalidURL
    case unsupportedScheme
    case requestFailed(String)
    case responseTooLarge
    case invalidPlaylist

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Enter a URL."
        case .invalidURL:
            return "The URL is not valid."
        case .unsupportedScheme:
            return "Only HTTP and HTTPS URLs are supported."
        case .requestFailed(let message):
            return message
        case .responseTooLarge:
            return "The remote playlist is too large."
        case .invalidPlaylist:
            return "The URL does not contain a readable playlist."
        }
    }
}

private struct ImportedPlaylistItem {
    let url: URL
    let title: String?
    let duration: TimeInterval?
}

private enum RemoteURLProbeResult {
    case stream(URL)
    case playlist(data: Data, baseURL: URL)
}

/// Performs just enough of a request to distinguish a radio/audio source from
/// a remote M3U/PLS. Audio sources are cancelled as soon as their response or
/// first binary payload is identified; playlist bodies are retained only up to
/// a bounded size and are parsed off the main queue.
private final class RemoteURLProbe: NSObject, URLSessionDataDelegate {
    private enum Mode { case undecided, stream, playlist }

    private static let maximumPlaylistBytes = 8 * 1024 * 1024
    private static let maximumProbeBytes = 8 * 1024

    private let url: URL
    private let completion: (Result<RemoteURLProbeResult, Error>) -> Void
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionDataTask?
    private var mode: Mode = .undecided
    private var responseURL: URL
    private var contentType = ""
    private var body = Data()
    private var isFinished = false

    init(url: URL, completion: @escaping (Result<RemoteURLProbeResult, Error>) -> Void) {
        self.url = url
        self.responseURL = url
        self.completion = completion
        super.init()
    }

    func start() {
        var request = URLRequest(url: url)
        request.setValue("MacAmp/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("audio/mpegurl, audio/x-scpls, text/plain, */*", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        task?.cancel()
        session.invalidateAndCancel()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(.failure(PlaylistURLImportError.requestFailed("The URL did not return an HTTP response.")))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            finish(.failure(PlaylistURLImportError.requestFailed("The server returned HTTP \(httpResponse.statusCode).")))
            completionHandler(.cancel)
            return
        }

        responseURL = response.url ?? url
        contentType = (httpResponse.mimeType ?? "").lowercased()
        let playlistExtension = ["m3u", "m3u8", "pls"].contains(responseURL.pathExtension.lowercased())
            || ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased())
        let playlistMIME = contentType.contains("mpegurl")
            || contentType.contains("scpls")
            || contentType.contains("playlist")
            || contentType == "audio/x-scpls"

        if playlistExtension || playlistMIME {
            mode = .playlist
        } else if contentType.hasPrefix("audio/") {
            finish(.success(.stream(responseURL)))
            completionHandler(.cancel)
            return
        } else if contentType == "application/octet-stream" {
            finish(.success(.stream(responseURL)))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        body.append(data)
        guard body.count <= Self.maximumPlaylistBytes else {
            if mode == .undecided {
                finish(.success(.stream(responseURL)))
            } else {
                finish(.failure(PlaylistURLImportError.responseTooLarge))
            }
            dataTask.cancel()
            return
        }

        guard mode == .undecided else { return }
        let probe = body.prefix(Self.maximumProbeBytes)
        if Self.looksLikePlaylist(Data(probe)) {
            mode = .playlist
        } else if !Self.isText(Data(probe)) && probe.count >= 1_024 {
            // MP3/AAC/Ogg payloads normally fail UTF-8 decoding immediately.
            // Do not wait for a radio stream to end before putting it in the
            // playlist.
            finish(.success(.stream(responseURL)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            finish(.failure(PlaylistURLImportError.requestFailed(error.localizedDescription)))
            return
        }

        // Some playlist generators answer with a plain-text redirect to the
        // actual station URL instead of returning an M3U body. Treat a single
        // HTTP(S) line as the stream it points to; otherwise the line would be
        // parsed as a playlist entry and a trailing slash would become its
        // visible title.
        if let streamURL = Self.singleRemoteURL(in: body, relativeTo: responseURL) {
            finish(.success(.stream(streamURL)))
        } else if mode == .playlist || Self.looksLikePlaylist(body) || contentType.hasPrefix("text/") {
            finish(.success(.playlist(data: body, baseURL: responseURL)))
        } else {
            finish(.success(.stream(responseURL)))
        }
    }

    private func finish(_ result: Result<RemoteURLProbeResult, Error>) {
        guard !isFinished else { return }
        isFinished = true
        session.invalidateAndCancel()
        completion(result)
    }

    private static func isText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return String(data: data, encoding: .utf8) != nil
            || String(data: data, encoding: .windowsCP1252) != nil
    }

    private static func looksLikePlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else { return false }
        var upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasPrefix("\u{FEFF}") { upper = String(upper.dropFirst()) }
        return upper.hasPrefix("#EXTM3U")
            || upper.hasPrefix("#EXTINF:")
            || upper.hasPrefix("[PLAYLIST]")
            || upper.contains("\nFILE1=")
            || upper.hasPrefix("FILE1=")
    }

    private static func singleRemoteURL(in data: Data, relativeTo baseURL: URL) -> URL? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else { return nil }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, !lines[0].hasPrefix("#"),
              let candidate = URL(string: lines[0], relativeTo: baseURL)?.absoluteURL,
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              candidate.host != nil else { return nil }
        return candidate
    }
}

/// Single authority for opening, saving and scanning playlists.  Its queues are
/// serial by design: network folders cannot create an unbounded number of jobs.
final class PlaylistManager: ObservableObject {
    enum SortOption: CaseIterable, Identifiable {
        case title
        case artistAlbumTrack
        case fileName
        case pathAndFileName
        case reverse

        var id: Self { self }

        var menuTitle: String {
            switch self {
            case .title: return "Sort by title"
        case .artistAlbumTrack: return "Sort by artist/album/track number"
            case .fileName: return "Sort by file name"
            case .pathAndFileName: return "Sort by path + file name"
            case .reverse: return "Reverse"
            }
        }

        init?(menuTitle: String) {
            guard let option = Self.allCases.first(where: { $0.menuTitle == menuTitle }) else { return nil }
            self = option
        }
    }

    struct KeyboardSelectionReveal: Equatable {
        let playlistID: UUID
        let entryID: UUID
        let alignToBottom: Bool
        let revision: UInt
    }
    private struct ShuffleTrack: Hashable {
        let playlistID: UUID
        let entryID: UUID
    }
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"]
    /// Bump when a stored display-title format needs one background refresh.
    /// Existing snapshots did not retain separate artist/title fields, so they
    /// must be revisited once for system notification presentation.
    private static let displayMetadataFormatVersionKey = "macAmp.playlist.displayMetadataFormatVersion"
    private static let displayMetadataFormatVersion = 2
    @Published private(set) var playlists: [PlaylistModel] = []
    @Published private(set) var activePlaylistID: UUID?
    @Published private(set) var focusedPlaylistID: UUID?
    @Published private(set) var playingEntryID: UUID?
    /// A playback command may target the same restored entry ID, in which case
    /// observing `playingEntryID` alone emits no SwiftUI change.  This token
    /// represents the command itself and lets the editor reveal an off-screen
    /// current row on every transport start.
    @Published private(set) var playbackRevealRevision = 0
    /// A keyboard-only reveal request. Keeping it separate from playback
    /// avoids changing the user's scroll position for ordinary selection.
    @Published private(set) var keyboardSelectionReveal: KeyboardSelectionReveal?
    private var keyboardSelectionRevealRevision: UInt = 0
    @Published private(set) var recentPlaylistURLs: [URL] = []

    private let folderQueue = DispatchQueue(label: "ru.aleksandr.macAmp.playlist.folder", qos: .utility)
    private let sortingQueue = DispatchQueue(label: "ru.aleksandr.macAmp.playlist.sorting", qos: .utility)
    private let metadataQueue = DispatchQueue(label: "ru.aleksandr.macAmp.playlist.metadata", qos: .background, attributes: .concurrent)
    private let persistenceURL: URL
    private let playlistEntriesDirectoryURL: URL
    /// Only playlists whose elements changed are re-encoded. Window state,
    /// selection and playback cursors remain in the small main snapshot.
    private var dirtyPlaylistEntryIDs = Set<UUID>()
    private var mainSnapshotNeedsRewrite = false
    private var pausedPlaylistIDs = Set<UUID>()
    private var cancelledFolderPlaylistIDs = Set<UUID>()
    private let scannerLock = NSLock()
    // AVFoundation's duration scan can decode/index aggressively (and more
    // than one such scan easily consumes a full CPU core). One background
    // worker keeps playback responsive; priority still puts the current and
    // visible rows ahead of the rest of the playlist.
    private let maximumMetadataOperations = 1
    private var metadataWorkersRunning = 0
    private var metadataProgress: [UUID: (processed: Int, total: Int)] = [:]
    /// Accessed only on the main queue. The request token makes a completion
    /// single-use: only the currently registered request may mutate its row.
    private var metadataInFlightRequests: [UUID: UInt64] = [:]
    private var nextMetadataRequestID: UInt64 = 1
    /// AVFoundation loads can otherwise occupy both workers long after the
    /// user scrolls to another part of a large playlist.  This lock protects
    /// the assets while they are owned by metadata worker threads.
    private let metadataAssetLock = NSLock()
    private var loadingMetadataAssets: [UUID: AVURLAsset] = [:]
    private var cancelledMetadataEntryIDs = Set<UUID>()
    private var pendingMetadataReprioritization: DispatchWorkItem?
    /// Playback can reveal an off-screen current row by scrolling the editor.
    /// That programmatic viewport change must not be treated like a user
    /// scroll: a user scroll may cancel obsolete metadata work, whereas a
    /// track change must let the current read finish and retain its counter.
    private var metadataReprioritizationSuppressedForPlaylistIDs = Set<UUID>()
    /// Main-thread generation of the visible metadata work set. A worker that
    /// finishes after scrolling skips its normal pacing delay and immediately
    /// chooses again from the new viewport.
    private var metadataPriorityRevision = 0
    /// Keeps parsing off-main while pacing visual insertion.  Enqueuing all
    /// parsed chunks at once starves a run-loop frame and makes the Loading
    /// counter appear to jump from zero to a large number.
    private struct PendingPlaylistLoad {
        var entries: [PlaylistEntry] = []
        var nextIndex = 0
        var parserFinished = false
        var isDraining = false
    }
    private struct SortRecord {
        let entry: PlaylistEntry
        let key: String
        let artist: String?
        let album: String?
        let trackNumber: Int?

        init(entry: PlaylistEntry, key: String, artist: String? = nil, album: String? = nil, trackNumber: Int? = nil) {
            self.entry = entry
            self.key = key
            self.artist = artist
            self.album = album
            self.trackNumber = trackNumber
        }
    }

    private final class SortingCancellationToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private final class SortingTask {
        let cancellation = SortingCancellationToken()
    }

    private var pendingPlaylistLoads: [UUID: PendingPlaylistLoad] = [:]
    /// URL probes are kept alive until their response is classified. The key
    /// is transient and is removed on the main queue with the playlist update.
    private var urlImportProbes: [UUID: RemoteURLProbe] = [:]
    // The Loading counter is an exact row counter: advance it one entry at a
    // time, rather than reporting parser blocks such as 128 records.
    private let visibleLoadingBatchSize = 1
    private let visibleLoadingBatchInterval: TimeInterval = 1.0 / 60.0
    private var waitingCursorPlaylistIDs = Set<UUID>()
    private var pendingSaveWorkItem: DispatchWorkItem?
    /// Sorting never mutates the model from its worker queue. The work item is
    /// removed before a playlist closes, so a late completion cannot reinsert
    /// rows into a closed editor.
    private var sortingTasks: [UUID: SortingTask] = [:]
    private var sortingWorkItems: [UUID: DispatchWorkItem] = [:]
    /// Metadata discovery is intentionally gentle: it must never compete with
    /// audio rendering just to fill columns that are not currently visible.
    private let metadataWorkInterval: TimeInterval = 0.25
    // Shuffle advances through a permutation so an enabled pass does not
    // repeat a track before all eligible tracks have been visited.
    private var shuffleOrderMode: ShuffleMode = .off
    /// The permutation's source is part of its identity.  A current-playlist
    /// shuffle must be rebuilt as soon as playback moves to another editor;
    /// comparing only the mode and track IDs leaves a stale cursor in a few
    /// restore/edit edge cases.
    private var shuffleOrderPlaylistID: UUID?
    private var shuffleOrder: [ShuffleTrack] = []
    private var shuffleCursor = -1

    init() {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("macAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistenceURL = directory.appendingPathComponent("playlists.json")
        playlistEntriesDirectoryURL = directory.appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: playlistEntriesDirectoryURL, withIntermediateDirectories: true)
        let needsDisplayMetadataRefresh = UserDefaults.standard.integer(forKey: Self.displayMetadataFormatVersionKey) < Self.displayMetadataFormatVersion
        restore(invalidateMetadata: needsDisplayMetadataRefresh)
        if playlists.isEmpty {
            let playlist = PlaylistModel(name: "Playlist")
            playlists = [playlist]
            activePlaylistID = playlist.id
            focusedPlaylistID = playlist.id
            dirtyPlaylistEntryIDs.insert(playlist.id)
        }
        if needsDisplayMetadataRefresh || mainSnapshotNeedsRewrite || !dirtyPlaylistEntryIDs.isEmpty {
            // Persist repaired references and metadata invalidation before
            // normal coalesced saves begin.
            writeSnapshot()
        }
        if needsDisplayMetadataRefresh {
            UserDefaults.standard.set(Self.displayMetadataFormatVersion, forKey: Self.displayMetadataFormatVersionKey)
        }
        DispatchQueue.main.async { [weak self] in self?.playlists.filter(\.isVisible).forEach { self?.scheduleMetadata(for: $0) } }
    }

    var activePlaylist: PlaylistModel? { playlists.first { $0.id == activePlaylistID } ?? playlists.first }
    func setAutomaticRating(_ enabled: Bool, for playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        playlist.automaticRatingEnabled = enabled
        mainSnapshotNeedsRewrite = true
        save()
    }
    var editingPlaylist: PlaylistModel? { playlists.first { $0.id == focusedPlaylistID } ?? activePlaylist }
    func playlist(id: UUID) -> PlaylistModel? { playlists.first { $0.id == id } }
    func isOpenPlaylist(at url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return playlists.contains { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }
    }

    func resetShuffleOrder() {
        shuffleOrderMode = .off
        shuffleOrderPlaylistID = nil
        shuffleOrder.removeAll(keepingCapacity: true)
        shuffleCursor = -1
    }

    private var currentShuffleTrack: ShuffleTrack? {
        guard let currentID = playingEntryID,
              let playlist = activePlaylist,
              playlist.entries.contains(where: { $0.id == currentID }) else { return nil }
        return ShuffleTrack(playlistID: playlist.id, entryID: currentID)
    }

    /// Removes tracks from a closed playlist without rebuilding the rest of
    /// the current all-playlists permutation. The cursor is then anchored to
    /// the track that remains current, if any, so the next/previous commands
    /// cannot resolve a deleted playlist or skip the first retained track.
    func removeShuffleHistory(for playlistID: UUID) {
        guard shuffleOrder.contains(where: { $0.playlistID == playlistID }) else { return }
        shuffleOrder.removeAll { $0.playlistID == playlistID }
        guard !shuffleOrder.isEmpty else {
            resetShuffleOrder()
            return
        }

        if let currentTrack = currentShuffleTrack,
           let currentIndex = shuffleOrder.firstIndex(of: currentTrack) {
            shuffleCursor = currentIndex
        } else {
            shuffleCursor = -1
        }
    }

    func shuffledEntry(for mode: ShuffleMode, step: Int) -> (playlist: PlaylistModel, entry: PlaylistEntry)? {
        guard mode != .off, step != 0 else { return nil }
        let sourcePlaylists: [PlaylistModel]
        switch mode {
        case .off:
            return nil
        case .currentPlaylist:
            sourcePlaylists = activePlaylist.map { [$0] } ?? []
        case .allPlaylists:
            sourcePlaylists = playlists
        }

        let candidates = sourcePlaylists.flatMap { playlist in
            playlist.entries
                .filter { !$0.hasPlaybackError }
                .map { ShuffleTrack(playlistID: playlist.id, entryID: $0.id) }
        }
        guard !candidates.isEmpty else { return nil }
        let candidateSet = Set(candidates)
        let sourcePlaylistID = mode == .currentPlaylist ? sourcePlaylists.first?.id : nil

        if shuffleOrderMode != mode
            || shuffleOrderPlaylistID != sourcePlaylistID
            || Set(shuffleOrder) != candidateSet {
            shuffleOrderMode = mode
            shuffleOrderPlaylistID = sourcePlaylistID
            shuffleOrder = candidates.shuffled()
            if let currentTrack = currentShuffleTrack,
               let currentIndex = shuffleOrder.firstIndex(of: currentTrack) {
                shuffleOrder.swapAt(0, currentIndex)
                shuffleCursor = 0
            } else {
                shuffleCursor = -1
            }
        } else if let currentTrack = currentShuffleTrack,
                  let currentIndex = shuffleOrder.firstIndex(of: currentTrack) {
            shuffleCursor = currentIndex
        } else {
            // The current source can change independently of this method (for
            // example after a direct row activation or entry cleanup). Never
            // continue from the old playlist's cursor when the current track
            // is absent from the retained permutation.
            shuffleCursor = -1
        }

        let nextCursor = shuffleCursor + step
        guard shuffleOrder.indices.contains(nextCursor) else { return nil }
        shuffleCursor = nextCursor
        let track = shuffleOrder[nextCursor]
        guard let playlist = playlist(id: track.playlistID),
              let entry = playlist.entries.first(where: { $0.id == track.entryID }) else {
            resetShuffleOrder()
            return nil
        }
        return (playlist, entry)
    }

    @discardableResult func createPlaylist(name: String = "New Playlist") -> PlaylistModel {
        let playlist = PlaylistModel(name: name)
        playlists.append(playlist); focusedPlaylistID = playlist.id
        markEntriesDirty(in: playlist); save(); return playlist
    }

    /// Resolves symlinks before comparing paths, so every open route observes
    /// the one-window-per-saved-playlist rule.
    @discardableResult func openPlaylist(at url: URL) -> PlaylistModel {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = playlists.first(where: { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }) {
            existing.isVisible = true; focusedPlaylistID = existing.id; return existing
        }
        let playlist = PlaylistModel(name: canonical.deletingPathExtension().lastPathComponent, fileURL: canonical)
        playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }
        markEntriesDirty(in: playlist); save(); return playlist
    }

    /// Creates the editor model immediately. Reading and parsing a large M3U
    /// happens off-main; entries then arrive in small main-queue batches so
    /// the new window remains responsive while its contents populate.
    @discardableResult func loadPlaylistAsynchronously(from url: URL) -> PlaylistModel? {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard ["m3u", "m3u8"].contains(canonical.pathExtension.lowercased()) else { return nil }
        if let existing = playlists.first(where: { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }) {
            existing.isVisible = true; focusedPlaylistID = existing.id; return existing
        }
        let playlist = PlaylistModel(name: canonical.deletingPathExtension().lastPathComponent, fileURL: canonical)
        playlist.scannerState = .scanningFolder(0)
        playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }
        markEntriesDirty(in: playlist); save()
        beginWaitingCursor(for: playlist)
        folderQueue.async { [weak self, weak playlist] in
            guard let self, let playlist else { return }
            guard let content = try? String(contentsOf: canonical, encoding: .utf8) else {
                DispatchQueue.main.async { self.finishLoadingPlaylist(playlist) }
                return
            }
            var title: String?; var duration: TimeInterval?; var batch: [PlaylistEntry] = []
            batch.reserveCapacity(128)
            for line in content.split(whereSeparator: \.isNewline) {
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.uppercased().hasPrefix("#EXTINF:") {
                    let parts = value.dropFirst(8).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    duration = parts.first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
                    title = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
                    continue
                }
                guard !value.isEmpty, !value.hasPrefix("#") else { continue }
                let item = (URL(string: value)?.scheme != nil) ? URL(string: value)! : URL(fileURLWithPath: value, relativeTo: canonical.deletingLastPathComponent()).standardizedFileURL
                batch.append(PlaylistEntry(url: item, title: title, duration: duration, metadataIsAvailable: title != nil || duration != nil))
                title = nil; duration = nil
                if batch.count == 128 {
                    let ready = batch; batch.removeAll(keepingCapacity: true)
                    DispatchQueue.main.async { self.enqueueLoadedEntries(ready, to: playlist) }
                }
            }
            if !batch.isEmpty { DispatchQueue.main.async { self.enqueueLoadedEntries(batch, to: playlist) } }
            DispatchQueue.main.async { self.finishEnqueuingLoadedPlaylist(playlist) }
        }
        return playlist
    }

    private func appendLoadedBatch(_ entries: [PlaylistEntry], to playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        if playlist.entries.isEmpty { endWaitingCursor(for: playlist) }
        playlist.entries.append(contentsOf: entries)
        playlist.structureRevision &+= 1
        playlist.appendToTotalDuration(entries)
        markEntriesDirty(in: playlist)
        playlist.scannerState = .scanningFolder(playlist.entries.count)
        // Start as soon as rows can actually be shown.  The state above stays
        // "Loading" until parsing finishes, even while metadata work runs.
        scheduleMetadata(for: playlist)
    }

    private func enqueueLoadedEntries(_ entries: [PlaylistEntry], to playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        var pending = pendingPlaylistLoads[playlist.id] ?? PendingPlaylistLoad()
        pending.entries.append(contentsOf: entries)
        let shouldStart = !pending.isDraining
        pending.isDraining = true
        pendingPlaylistLoads[playlist.id] = pending
        if shouldStart { drainLoadedEntries(for: playlist) }
    }

    private func finishEnqueuingLoadedPlaylist(_ playlist: PlaylistModel) {
        guard var pending = pendingPlaylistLoads[playlist.id] else {
            finishLoadingPlaylist(playlist)
            return
        }
        pending.parserFinished = true
        let shouldStart = !pending.isDraining
        pending.isDraining = true
        pendingPlaylistLoads[playlist.id] = pending
        if shouldStart { drainLoadedEntries(for: playlist) }
    }

    private func drainLoadedEntries(for playlist: PlaylistModel) {
        guard var pending = pendingPlaylistLoads[playlist.id] else { return }
        guard playlists.contains(where: { $0.id == playlist.id }) else {
            pendingPlaylistLoads.removeValue(forKey: playlist.id)
            return
        }
        if pending.nextIndex < pending.entries.count {
            let end = min(pending.entries.count, pending.nextIndex + visibleLoadingBatchSize)
            let batch = Array(pending.entries[pending.nextIndex..<end])
            pending.nextIndex = end
            pendingPlaylistLoads[playlist.id] = pending
            appendLoadedBatch(batch, to: playlist)
            DispatchQueue.main.asyncAfter(deadline: .now() + visibleLoadingBatchInterval) { [weak self, weak playlist] in
                guard let self, let playlist else { return }
                self.drainLoadedEntries(for: playlist)
            }
        } else if pending.parserFinished {
            pendingPlaylistLoads.removeValue(forKey: playlist.id)
            finishLoadingPlaylist(playlist)
        } else {
            pending.isDraining = false
            pendingPlaylistLoads[playlist.id] = pending
        }
    }

    private func finishLoadingPlaylist(_ playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        endWaitingCursor(for: playlist)
        finishEntryLoading(playlist)
        save()
    }

    private func beginWaitingCursor(for playlist: PlaylistModel) {
        guard waitingCursorPlaylistIDs.insert(playlist.id).inserted else { return }
        SkinCursors.beginBusyCursor()
    }

    private func endWaitingCursor(for playlist: PlaylistModel) {
        guard waitingCursorPlaylistIDs.remove(playlist.id) != nil else { return }
        SkinCursors.endBusyCursor()
    }

    func close(_ playlist: PlaylistModel) {
        cancelSorting(for: playlist)
        guard playlists.count > 1 else { playlist.isVisible = false; save(); return }
        if let url = playlist.fileURL { addRecent(url) }
        let wasActive = activePlaylistID == playlist.id
        playlists.removeAll { $0.id == playlist.id }
        removeShuffleHistory(for: playlist.id)
        dirtyPlaylistEntryIDs.remove(playlist.id)
        if wasActive {
            // Prefer an actually open window; fall back to a remaining hidden
            // model only when all editors are hidden.
            let replacement = playlists.first(where: \.isVisible) ?? playlists.first
            activePlaylistID = replacement?.id
            playingEntryID = replacement?.lastPlayedEntryID
        }
        if focusedPlaylistID == playlist.id { focusedPlaylistID = activePlaylistID ?? playlists.first?.id }
        save()
    }

    func setVisible(_ visible: Bool, for playlist: PlaylistModel) {
        playlist.isVisible = visible
        if visible {
            pausedPlaylistIDs.remove(playlist.id)
            scheduleMetadata(for: playlist)
        }
        else { pausedPlaylistIDs.insert(playlist.id); playlist.scannerState = .paused }
        save()
    }

    func canSort(_ option: SortOption, in playlist: PlaylistModel) -> Bool {
        guard playlists.contains(where: { $0.id == playlist.id }),
              playlist.entries.count > 1,
              sortingTasks[playlist.id] == nil,
              !isLoadingEntries(playlist) else { return false }
        if option == .title {
            return playlist.entries.allSatisfy(\.metadataIsAvailable)
        }
        return true
    }

    func sort(_ playlist: PlaylistModel, by option: SortOption) {
        guard canSort(option, in: playlist) else { return }

        let task = SortingTask()
        sortingTasks[playlist.id] = task
        let entries = playlist.entries
        let total = entries.count
        playlist.sortingProgress = PlaylistModel.SortingProgress(
            processed: 0,
            total: total,
            phase: option == .artistAlbumTrack ? "Reading" : "Sorting"
        )

        if option == .artistAlbumTrack {
            startArtistAlbumTrackSort(entries, playlist: playlist, task: task)
            return
        }

        let records = entries.map { entry in
            SortRecord(entry: entry, key: sortKey(for: entry, option: option))
        }
        startSort(records, option: option, playlist: playlist, task: task)
    }

    func canRebuildTitles(in playlist: PlaylistModel) -> Bool {
        guard playlists.contains(where: { $0.id == playlist.id }),
              !playlist.selectedIDs.isEmpty,
              playlist.sortingProgress == nil,
              !isLoadingEntries(playlist) else { return false }
        return playlist.entries.contains { playlist.selectedIDs.contains($0.id) }
    }

    /// Invalidates the selected rows and sends them through the same serial
    /// metadata reader used for newly added files.  Keeping the regular queue
    /// here preserves its playback/visibility priority and its status counter.
    func rebuildTitlesForSelection(in playlist: PlaylistModel) {
        guard canRebuildTitles(in: playlist) else { return }
        let selectedEntries = playlist.entries.filter { playlist.selectedIDs.contains($0.id) }
        guard !selectedEntries.isEmpty else { return }

        for entry in selectedEntries {
            entry.metadataIsAvailable = false
            entry.artist = nil
            entry.trackTitle = nil
            entry.title = entry.url.deletingPathExtension().lastPathComponent
            entry.duration = nil
        }
        playlist.recalculateTotalDuration()

        let pendingCount = playlist.entries.reduce(into: 0) { count, entry in
            if !entry.metadataIsAvailable { count += 1 }
        }
        metadataProgress[playlist.id] = (0, pendingCount)
        playlist.scannerState = .readingMetadata(processed: 0, total: pendingCount)
        playlist.isDirty = true
        markEntriesDirty(in: playlist)
        metadataPriorityRevision &+= 1
        scheduleMetadata(for: playlist)
        requestMetadataReprioritization()
        save()
    }

    /// Applies the values just written by the File Info editor to the live
    /// playlist row. The file remains the source of truth; this in-memory
    /// update only prevents the row and the player display from waiting for a
    /// later metadata scan.
    func applyEditedMetadata(_ fields: TagEditorFields, to entry: PlaylistEntry, in playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }),
              let liveEntry = playlist.entries.first(where: { $0.id == entry.id }) else { return }
        let artist = fields.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (artist.isEmpty ? nil : artist, title.isEmpty ? nil : title) {
        case let (.some(artist), .some(title)):
            liveEntry.artist = artist
            liveEntry.trackTitle = title
            liveEntry.title = "\(artist) - \(title)"
        case let (.some(artist), nil):
            liveEntry.artist = artist
            liveEntry.trackTitle = nil
            liveEntry.title = artist
        case let (nil, .some(title)):
            liveEntry.artist = nil
            liveEntry.trackTitle = title
            liveEntry.title = title
        case (nil, nil):
            liveEntry.artist = nil
            liveEntry.trackTitle = nil
            liveEntry.title = liveEntry.url.deletingPathExtension().lastPathComponent
        }
        liveEntry.metadataIsAvailable = true
        playlist.isDirty = true
        markEntriesDirty(in: playlist)
        save()
    }

    private func startSort(
        _ records: [SortRecord],
        option: SortOption,
        playlist: PlaylistModel,
        task: SortingTask
    ) {
        let playlistID = playlist.id
        let total = records.count
        let workItem = DispatchWorkItem { [weak self, weak playlist] in
            guard let self, let playlist else { return }
            let sortedEntries = self.sortedEntries(
                records,
                option: option,
                isCancelled: { task.cancellation.isCancelled },
                reportProgress: { processed in
                    DispatchQueue.main.async { [weak self, weak playlist] in
                        guard let self, let playlist,
                              self.sortingTasks[playlistID] === task,
                              !task.cancellation.isCancelled else { return }
                        playlist.sortingProgress = PlaylistModel.SortingProgress(
                            processed: min(processed, total), total: total, phase: "Sorting"
                        )
                    }
                }
            )
            guard let sortedEntries, !task.cancellation.isCancelled else { return }
            self.finishSorting(sortedEntries, playlist: playlist, task: task)
        }
        sortingWorkItems[playlistID] = workItem
        sortingQueue.async(execute: workItem)
    }

    private func startArtistAlbumTrackSort(
        _ entries: [PlaylistEntry],
        playlist: PlaylistModel,
        task: SortingTask
    ) {
        let playlistID = playlist.id
        let total = entries.count
        let workItem = DispatchWorkItem { [weak self, weak playlist] in
            guard let self, let playlist else { return }
            var records: [SortRecord] = []
            records.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() {
                guard !task.cancellation.isCancelled else { return }
                guard let tags = autoreleasepool(invoking: {
                    self.readArtistAlbumTrackTags(for: entry, isCancelled: { task.cancellation.isCancelled })
                }) else { return }
                records.append(SortRecord(
                    entry: entry,
                    key: "",
                    artist: tags.artist,
                    album: tags.album,
                    trackNumber: tags.trackNumber
                ))
                if (index + 1).isMultiple(of: 16) || index + 1 == total {
                    self.reportSortingProgress(
                        playlistID: playlistID,
                        playlist: playlist,
                        task: task,
                        processed: index + 1,
                        total: total,
                        phase: "Reading"
                    )
                }
            }
            guard !task.cancellation.isCancelled else { return }
            self.reportSortingProgress(
                playlistID: playlistID,
                playlist: playlist,
                task: task,
                processed: 0,
                total: total,
                phase: "Sorting"
            )
            guard let sortedEntries = self.sortedEntries(
                records,
                option: .artistAlbumTrack,
                isCancelled: { task.cancellation.isCancelled },
                reportProgress: { processed in
                    self.reportSortingProgress(
                        playlistID: playlistID,
                        playlist: playlist,
                        task: task,
                        processed: processed,
                        total: total,
                        phase: "Sorting"
                    )
                }
            ), !task.cancellation.isCancelled else { return }
            self.finishSorting(sortedEntries, playlist: playlist, task: task)
        }
        sortingWorkItems[playlistID] = workItem
        sortingQueue.async(execute: workItem)
    }

    private func reportSortingProgress(
        playlistID: UUID,
        playlist: PlaylistModel,
        task: SortingTask,
        processed: Int,
        total: Int,
        phase: String
    ) {
        DispatchQueue.main.async { [weak self, weak playlist] in
            guard let self, let playlist,
                  self.sortingTasks[playlistID] === task,
                  !task.cancellation.isCancelled else { return }
            playlist.sortingProgress = PlaylistModel.SortingProgress(
                processed: min(max(0, processed), total), total: total, phase: phase
            )
        }
    }

    private func finishSorting(_ sortedEntries: [PlaylistEntry], playlist: PlaylistModel, task: SortingTask) {
        let playlistID = playlist.id
        DispatchQueue.main.async { [weak self, weak playlist] in
            guard let self, let playlist,
                  self.sortingTasks[playlistID] === task,
                  !task.cancellation.isCancelled,
                  self.playlists.contains(where: { $0.id == playlistID }) else { return }
            self.sortingTasks.removeValue(forKey: playlistID)
            self.sortingWorkItems.removeValue(forKey: playlistID)
            playlist.entries = sortedEntries
            playlist.structureRevision &+= 1
            playlist.isDirty = true
            playlist.sortingProgress = nil
            self.markEntriesDirty(in: playlist)
            self.scheduleMetadata(for: playlist)
            self.save()
        }
    }

    func cancelSorting(for playlist: PlaylistModel) {
        let playlistID = playlist.id
        sortingTasks[playlistID]?.cancellation.cancel()
        sortingTasks.removeValue(forKey: playlistID)
        sortingWorkItems.removeValue(forKey: playlistID)?.cancel()
        playlist.sortingProgress = nil
    }

    func cancelAllSorting() {
        let tasks = sortingTasks
        let workItems = sortingWorkItems
        sortingTasks.removeAll()
        sortingWorkItems.removeAll()
        tasks.values.forEach { $0.cancellation.cancel() }
        workItems.values.forEach { $0.cancel() }
        tasks.keys.compactMap { playlist(id: $0) }.forEach { $0.sortingProgress = nil }
    }

    private func sortKey(for entry: PlaylistEntry, option: SortOption) -> String {
        switch option {
        case .title: return entry.title
        case .artistAlbumTrack: return ""
        case .fileName: return entry.url.lastPathComponent
        case .pathAndFileName: return entry.url.isFileURL ? entry.url.path : entry.url.absoluteString
        case .reverse: return ""
        }
    }

    private func readArtistAlbumTrackTags(
        for entry: PlaylistEntry,
        isCancelled: () -> Bool
    ) -> (artist: String?, album: String?, trackNumber: Int?)? {
        let asset = AVURLAsset(url: entry.url)
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata"]) {
            semaphore.signal()
        }

        var didLoad = false
        for _ in 0..<100 {
            if semaphore.wait(timeout: .now() + 0.1) == .success {
                didLoad = true
                break
            }
            if isCancelled() { return nil }
        }
        guard !isCancelled() else { return nil }
        guard didLoad else { return (nil, nil, nil) }

        let metadata = asset.commonMetadata + asset.metadata
        let artist = metadataText(in: metadata, id3Frame: "TPE1", commonKey: .commonKeyArtist)
        let album = metadataText(in: metadata, id3Frame: "TALB", commonKey: .commonKeyAlbumName)
        let trackNumber = metadataTrackNumber(in: metadata)
        return (artist, album, trackNumber)
    }

    private func metadataText(
        in metadata: [AVMetadataItem],
        id3Frame: String,
        commonKey: AVMetadataKey?
    ) -> String? {
        let frame = id3Frame.uppercased()
        let item = metadata.first { item in
            let key = (item.key as? String)?.uppercased()
            let identifier = item.identifier?.rawValue.uppercased()
            return key == frame || identifier?.hasSuffix("/\(frame)") == true
        } ?? commonKey.flatMap { key in metadata.first { $0.commonKey == key } }
        guard let value = item?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func metadataTrackNumber(in metadata: [AVMetadataItem]) -> Int? {
        let item = metadata.first { item in
            let key = (item.key as? String)?.uppercased()
            let identifier = item.identifier?.rawValue.uppercased()
            return key == "TRCK"
                || identifier?.hasSuffix("/TRCK") == true
                || identifier?.contains("TRACKNUMBER") == true
        }
        if let value = item?.stringValue,
           let token = value.split(whereSeparator: { !$0.isNumber }).first,
           let number = Int(token), number > 0 {
            return number
        }
        if let number = item?.numberValue?.intValue, number > 0 { return number }
        return nil
    }

    private func sortRecordPrecedes(_ lhs: SortRecord, _ rhs: SortRecord, option: SortOption) -> Bool {
        if option == .artistAlbumTrack {
            let lhsComplete = lhs.album != nil && lhs.trackNumber != nil
            let rhsComplete = rhs.album != nil && rhs.trackNumber != nil
            if lhsComplete != rhsComplete { return lhsComplete }

            let artistComparison = (lhs.artist ?? "").localizedStandardCompare(rhs.artist ?? "")
            if artistComparison != .orderedSame { return artistComparison == .orderedAscending }
            let albumComparison = (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
            if albumComparison != .orderedSame { return albumComparison == .orderedAscending }
            if lhs.trackNumber != rhs.trackNumber {
                return (lhs.trackNumber ?? Int.max) < (rhs.trackNumber ?? Int.max)
            }
            return false
        }
        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }

    private func sortedEntries(
        _ records: [SortRecord],
        option: SortOption,
        isCancelled: () -> Bool,
        reportProgress: (Int) -> Void
    ) -> [PlaylistEntry]? {
        guard !records.isEmpty else { return [] }
        if option == .reverse {
            var reversed: [PlaylistEntry] = []
            reversed.reserveCapacity(records.count)
            for (index, record) in records.reversed().enumerated() {
                if isCancelled() { return nil }
                reversed.append(record.entry)
                if index.isMultiple(of: 512) { reportProgress(index + 1) }
            }
            reportProgress(records.count)
            return reversed
        }

        var source = records
        var buffer = records
        var width = 1
        while width < records.count {
            if isCancelled() { return nil }
            var start = 0
            while start < records.count {
                let middle = min(start + width, records.count)
                let end = min(start + width * 2, records.count)
                var left = start
                var right = middle
                var destination = start
                while left < middle || right < end {
                    if destination.isMultiple(of: 512), isCancelled() { return nil }
                    if right >= end || (left < middle && !sortRecordPrecedes(source[right], source[left], option: option)) {
                        buffer[destination] = source[left]
                        left += 1
                    } else {
                        buffer[destination] = source[right]
                        right += 1
                    }
                    destination += 1
                }
                start = end
            }
            swap(&source, &buffer)
            reportProgress(min(records.count, width * 2))
            if width > records.count / 2 { break }
            width *= 2
        }
        reportProgress(records.count)
        return source.map(\.entry)
    }

    func addFiles(_ urls: [URL], to playlist: PlaylistModel, at insertionIndex: Int? = nil) {
        let audio = urls.filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return }
        let entries = audio.map { PlaylistEntry(url: $0, bookmarkData: securityScopedBookmark(for: $0)) }
        propagateBookmarks(from: entries)
        let index = min(max(0, insertionIndex ?? playlist.entries.count), playlist.entries.count)
        playlist.entries.insert(contentsOf: entries, at: index)
        playlist.structureRevision &+= 1
        playlist.appendToTotalDuration(entries)
        markEntriesDirty(in: playlist)
        playlist.isDirty = true; playlist.scannerState = .adding(playlist.entries.count); save(); finishEntryLoading(playlist)
    }

    func addFolder(_ folder: URL, to playlist: PlaylistModel, at insertionIndex: Int? = nil) {
        cancelledFolderPlaylistIDs.remove(playlist.id)
        folderQueue.async { [weak self, weak playlist] in
            guard let self, let playlist else { return }
            let deadline = Date().addingTimeInterval(30)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
            var batch: [URL] = []
            var nextInsertionIndex = insertionIndex
            for case let url as URL in enumerator {
                if Date() >= deadline || self.cancelledFolderPlaylistIDs.contains(playlist.id) { break }
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                batch.append(url)
                if batch.count == 32 {
                    nextInsertionIndex = self.appendBatch(batch, to: playlist, at: nextInsertionIndex)
                    batch.removeAll()
                }
            }
            _ = self.appendBatch(batch, to: playlist, at: nextInsertionIndex)
            DispatchQueue.main.async { self.finishEntryLoading(playlist) }
        }
    }

    func cancelFolderScans() { cancelledFolderPlaylistIDs.formUnion(playlists.map(\.id)) }

    func play(_ entry: PlaylistEntry, in playlist: PlaylistModel, revealIfNeeded: Bool = true) {
        // If an entry has no persistent access yet and the current process can
        // read its URL, retain that access for subsequent launches.
        if entry.bookmarkData == nil {
            if let bookmark = securityScopedBookmark(for: entry.url) {
                entry.bookmarkData = bookmark
                markEntriesDirty(in: playlist)
            }
        }
        // A direct double-click is how playback changes the active editor.
        // Discard only the current-playlist permutation here; an
        // all-playlists shuffle intentionally keeps its order when it crosses
        // from one editor to another.
        if activePlaylistID != playlist.id, shuffleOrderMode == .currentPlaylist {
            resetShuffleOrder()
        }
        activePlaylistID = playlist.id; focusedPlaylistID = playlist.id
        playlist.lastPlayedEntryID = entry.id; playingEntryID = entry.id
        if revealIfNeeded {
            if playlist.isVisible,
               let index = playlist.entries.firstIndex(where: { $0.id == entry.id }),
               !isVisibleInEditor(entry, in: playlist) {
                // ScrollViewReader applies the visual reveal asynchronously.
                // Update the scheduler's viewport now, rather than letting it
                // continue reading the old range until that layout pass.
                let maximumFirst = max(0, playlist.entries.count - playlist.visibleEntryCount)
                playlist.scrollPosition = min(
                    maximumFirst,
                    max(0, index - playlist.visibleEntryCount / 2)
                )
                metadataPriorityRevision &+= 1
                metadataReprioritizationSuppressedForPlaylistIDs.insert(playlist.id)
            }
            playbackRevealRevision &+= 1
        }
        // A playback change must keep metadata discovery alive. This starts a
        // worker only when the serial scanner is idle; an active read remains
        // untouched and the next pump turn uses the playing row, then the
        // visible range.
        scheduleMetadata(for: playlist)
        save()
    }

    func preferredEntryToPlay(in playlist: PlaylistModel) -> PlaylistEntry? {
        if activePlaylistID == playlist.id,
           let current = playingEntryID,
           let entry = playlist.entries.first(where: { $0.id == current && !$0.hasPlaybackError }) { return entry }
        if let previous = playlist.lastPlayedEntryID,
           let entry = playlist.entries.first(where: { $0.id == previous && !$0.hasPlaybackError }) { return entry }
        if let selected = playlist.entries.first(where: { playlist.selectedIDs.contains($0.id) && !$0.hasPlaybackError }) { return selected }
        return playlist.entries.first(where: { !$0.hasPlaybackError })
    }

    func firstPlayableEntry(in playlist: PlaylistModel) -> PlaylistEntry? {
        playlist.entries.first(where: { !$0.hasPlaybackError })
    }

    func lastPlayableEntry(in playlist: PlaylistModel) -> PlaylistEntry? {
        playlist.entries.reversed().first(where: { !$0.hasPlaybackError })
    }

    /// Adds a remote source without changing the current playlist. The first
    /// response bytes decide whether the URL is an audio/radio source or a
    /// remote M3U/PLS; only the latter is read to completion.
    func addURL(
        _ rawValue: String,
        to playlist: PlaylistModel,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            completion(.failure(PlaylistURLImportError.emptyURL))
            return
        }
        if let scheme = URL(string: trimmedValue)?.scheme?.lowercased(),
           !["http", "https"].contains(scheme) {
            completion(.failure(PlaylistURLImportError.unsupportedScheme))
            return
        }
        guard let url = Self.normalizedRemoteURL(from: trimmedValue) else {
            completion(.failure(PlaylistURLImportError.invalidURL))
            return
        }

        playlist.scannerState = .adding(playlist.entries.count)
        let token = UUID()
        let probe = RemoteURLProbe(url: url) { [weak self, weak playlist] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.finishURLImport(
                        token: token,
                        playlist: playlist,
                        result: .failure(error),
                        completion: completion
                    )
                }
            case .success(.stream(let streamURL)):
                DispatchQueue.main.async {
                    self.finishURLImport(
                        token: token,
                        playlist: playlist,
                        result: .success([ImportedPlaylistItem(url: streamURL, title: nil, duration: nil)]),
                        completion: completion
                    )
                }
            case .success(.playlist(let data, let baseURL)):
                self.folderQueue.async { [weak self, weak playlist] in
                    guard let self else { return }
                    let result: Result<[ImportedPlaylistItem], Error>
                    if let items = Self.parseRemotePlaylist(data: data, baseURL: baseURL), !items.isEmpty {
                        result = .success(items)
                    } else {
                        result = .failure(PlaylistURLImportError.invalidPlaylist)
                    }
                    DispatchQueue.main.async {
                        self.finishURLImport(token: token, playlist: playlist, result: result, completion: completion)
                    }
                }
            }
        }
        urlImportProbes[token] = probe
        probe.start()
    }

    private func finishURLImport(
        token: UUID,
        playlist: PlaylistModel?,
        result: Result<[ImportedPlaylistItem], Error>,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        urlImportProbes.removeValue(forKey: token)
        guard let playlist,
              playlists.contains(where: { $0.id == playlist.id }) else { return }

        switch result {
        case .failure(let error):
            finishEntryLoading(playlist)
            completion(.failure(error))
        case .success(let items):
            guard !items.isEmpty else {
                finishEntryLoading(playlist)
                completion(.failure(PlaylistURLImportError.invalidPlaylist))
                return
            }
            let entries = items.map { item in
                PlaylistEntry(
                    url: item.url,
                    title: item.title ?? Self.displayTitle(for: item.url),
                    duration: item.duration,
                    // A remote stream must not enter the ordinary local-file
                    // metadata scanner. Its title arrives from ICY metadata
                    // once playback starts.
                    metadataIsAvailable: true
                )
            }
            playlist.entries.append(contentsOf: entries)
            playlist.structureRevision &+= 1
            playlist.appendToTotalDuration(entries)
            playlist.isDirty = true
            markEntriesDirty(in: playlist)
            finishEntryLoading(playlist)
            save()
            completion(.success(entries.count))
        }
    }

    private static func normalizedRemoteURL(from rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private static func displayTitle(for url: URL) -> String {
        let pathTitle = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathTitle.isEmpty, pathTitle != "/", pathTitle != "." {
            return pathTitle
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    private static func parseRemotePlaylist(data: Data, baseURL: URL) -> [ImportedPlaylistItem]? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        let upper = text.uppercased()
        if upper.contains("[PLAYLIST]") || lines.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("FILE1=")
        }) {
            let items = parsePLS(lines, baseURL: baseURL)
            if !items.isEmpty { return items }
        }
        return parseM3U(lines, baseURL: baseURL)
    }

    private static func removingBOM(from value: String) -> String {
        value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
    }

    private static func parseM3U(_ lines: [String], baseURL: URL) -> [ImportedPlaylistItem] {
        var items: [ImportedPlaylistItem] = []
        items.reserveCapacity(min(lines.count, 256))
        var pendingTitle: String?
        var pendingDuration: TimeInterval?

        for rawLine in lines {
            let line = removingBOM(from: rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst(8))
                let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                pendingDuration = parts.first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                    .flatMap { $0 >= 0 ? $0 : nil }
                if parts.count > 1 {
                    let title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingTitle = title.isEmpty ? nil : title
                } else {
                    pendingTitle = nil
                }
                continue
            }
            guard !line.hasPrefix("#"), let url = remotePlaylistURL(line, relativeTo: baseURL) else { continue }
            items.append(ImportedPlaylistItem(url: url, title: pendingTitle, duration: pendingDuration))
            pendingTitle = nil
            pendingDuration = nil
        }
        return items
    }

    private static func parsePLS(_ lines: [String], baseURL: URL) -> [ImportedPlaylistItem] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: TimeInterval] = [:]

        for rawLine in lines {
            let line = removingBOM(from: rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)), !value.isEmpty {
                files[index] = value
            } else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)), !value.isEmpty {
                titles[index] = value
            } else if key.hasPrefix("length"), let index = Int(key.dropFirst(6)),
                      let length = TimeInterval(value), length >= 0 {
                lengths[index] = length
            }
        }

        return files.keys.sorted().compactMap { index in
            guard let value = files[index],
                  let url = remotePlaylistURL(value, relativeTo: baseURL) else { return nil }
            return ImportedPlaylistItem(url: url, title: titles[index], duration: lengths[index])
        }
    }

    private static func remotePlaylistURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    func entryToPlay(in playlist: PlaylistModel, step: Int, shuffle: Bool) -> PlaylistEntry? {
        guard !playlist.entries.isEmpty else { return nil }
        if shuffle { return shuffledEntry(for: .currentPlaylist, step: step)?.entry }
        guard let current = playingEntryID,
              let index = playlist.entries.firstIndex(where: { $0.id == current }) else {
            return firstPlayableEntry(in: playlist)
        }
        // The next-track path advances past unavailable items.  Previous keeps
        // its normal positional behaviour; an errored item can be retried only
        // by directly activating its row in the Playlist Editor.
        if step > 0 {
            return playlist.entries.dropFirst(index + 1).first { !$0.hasPlaybackError }
        }
        let candidate = index + step
        guard playlist.entries.indices.contains(candidate) else { return nil }
        return playlist.entries[candidate]
    }

    func markPlaybackErrorForActiveEntry(url: URL) {
        guard let playlist = activePlaylist,
              let id = playingEntryID,
              let entry = playlist.entries.first(where: { $0.id == id && $0.url == url }) else { return }
        guard !entry.hasPlaybackError else { return }
        entry.hasPlaybackError = true
    }

    func clearPlaybackErrorForActiveEntry(url: URL) {
        guard let playlist = activePlaylist,
              let id = playingEntryID,
              let entry = playlist.entries.first(where: { $0.id == id && $0.url == url }) else { return }
        guard entry.hasPlaybackError else { return }
        entry.hasPlaybackError = false
    }

    /// ICY metadata belongs to the currently playing remote entry. It changes
    /// the visible title but never creates or removes a playlist row.
    func updateStreamMetadata(_ rawTitle: String, for url: URL) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let playlist = activePlaylist,
              let id = playingEntryID,
              let entry = playlist.entries.first(where: { $0.id == id && $0.url == url }) else { return }

        entry.title = title
        entry.metadataIsAvailable = true
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let trackTitle = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
            entry.artist = artist.isEmpty ? nil : artist
            entry.trackTitle = trackTitle.isEmpty ? nil : trackTitle
        } else {
            entry.artist = nil
            entry.trackTitle = title
        }
        playlist.isDirty = true
        markEntriesDirty(in: playlist)
        save()
    }

    func focus(_ playlist: PlaylistModel) { focusedPlaylistID = playlist.id; save() }

    /// Applies the same row-selection rules used by Finder:
    /// - click selects one row;
    /// - Command-click toggles one row without disturbing the rest;
    /// - Shift-click selects the inclusive range from the selection anchor;
    /// - Command-Shift-click adds that range to the existing selection.
    ///
    /// The anchor is held separately from the selected set so a Command-click
    /// can deselect its row yet still be the start of the next Shift-click.
    func selectEntry(
        _ entry: PlaylistEntry,
        in playlist: PlaylistModel,
        extending: Bool,
        toggling: Bool
    ) {
        guard let targetIndex = playlist.entries.firstIndex(where: { $0.id == entry.id }) else { return }

        if extending {
            let anchorID = playlist.selectionAnchorID
                ?? playlist.entries.first(where: { playlist.selectedIDs.contains($0.id) })?.id
                ?? entry.id
            let anchorIndex = playlist.entries.firstIndex(where: { $0.id == anchorID }) ?? targetIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeIDs = Set(playlist.entries[range].map(\.id))
            playlist.selectedIDs = toggling ? playlist.selectedIDs.union(rangeIDs) : rangeIDs
            playlist.selectionAnchorID = playlist.entries[anchorIndex].id
            return
        }

        if toggling {
            if playlist.selectedIDs.contains(entry.id) {
                playlist.selectedIDs.remove(entry.id)
            } else {
                playlist.selectedIDs.insert(entry.id)
            }
        } else {
            playlist.selectedIDs = [entry.id]
        }
        playlist.selectionAnchorID = entry.id
    }

    /// Moves the single keyboard selection without triggering persistence or
    /// playlist-wide work. The visible editor decides how to reveal the row.
    @discardableResult
    func moveSelection(in playlist: PlaylistModel, by offset: Int) -> PlaylistEntry? {
        guard offset != 0, !playlist.entries.isEmpty else { return nil }

        let selectedIndices = playlist.entries.indices.filter {
            playlist.selectedIDs.contains(playlist.entries[$0].id)
        }
        let anchor: Int
        if offset > 0 {
            anchor = selectedIndices.max() ?? -1
        } else {
            anchor = selectedIndices.min() ?? playlist.entries.count
        }
        let target = min(max(0, anchor + offset), playlist.entries.count - 1)
        let entry = playlist.entries[target]
        playlist.selectedIDs = [entry.id]
        playlist.selectionAnchorID = entry.id
        return entry
    }

    /// Scroll only when keyboard navigation moved the selected row beyond the
    /// current viewport. This is deliberately based on the editor's measured
    /// visible range, not a fixed row count.
    func revealKeyboardSelectionIfNeeded(_ entry: PlaylistEntry, in playlist: PlaylistModel) {
        guard let index = playlist.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let first = playlist.scrollPosition
        let end = min(playlist.entries.count, first + max(1, playlist.visibleEntryCount))
        guard index < first || index >= end else { return }
        keyboardSelectionRevealRevision &+= 1
        keyboardSelectionReveal = KeyboardSelectionReveal(
            playlistID: playlist.id,
            entryID: entry.id,
            alignToBottom: index >= end,
            revision: keyboardSelectionRevealRevision
        )
    }

    func visibleRangeChanged(for playlist: PlaylistModel, firstEntry: Int, visibleCount: Int) {
        let position = max(0, min(firstEntry, max(0, playlist.entries.count - 1)))
        let count = max(1, visibleCount)
        guard playlist.scrollPosition != position || playlist.visibleEntryCount != count else { return }
        playlist.scrollPosition = position
        playlist.visibleEntryCount = count
        metadataPriorityRevision &+= 1
        if metadataReprioritizationSuppressedForPlaylistIDs.remove(playlist.id) != nil {
            // This range change is the delayed ScrollView reveal issued by
            // play(_:in:). The worker will use the new viewport after its
            // current request completes, without cancelling that request.
            // It may have gone idle while the view was animating, so ensure
            // the new visible range still has a worker to consume it.
            scheduleMetadata(for: playlist)
            return
        }
        requestMetadataReprioritization()
    }

    /// The editor publishes a coalesced viewport range. It is sufficient for
    /// playback navigation, where avoiding an unnecessary scroll is more
    /// important than repainting an already visible selected row.
    func isVisibleInEditor(_ entry: PlaylistEntry, in playlist: PlaylistModel) -> Bool {
        guard let index = playlist.entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        let first = min(max(0, playlist.scrollPosition), playlist.entries.count)
        let end = min(playlist.entries.count, first + max(1, playlist.visibleEntryCount))
        return index >= first && index < end
    }

    private func requestMetadataReprioritization() {
        pendingMetadataReprioritization?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingMetadataReprioritization = nil
            self?.reprioritizeMetadataReading()
        }
        pendingMetadataReprioritization = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    func removeSelected(from playlist: PlaylistModel) {
        let previousCount = playlist.entries.count
        playlist.entries.removeAll { playlist.selectedIDs.contains($0.id) }
        playlist.recalculateTotalDuration()
        playlist.selectedIDs.removeAll(); playlist.selectionAnchorID = nil; playlist.isDirty = true
        if playlist.entries.count != previousCount { playlist.structureRevision &+= 1 }
        repairTrackReferences(in: playlist)
        markEntriesDirty(in: playlist); save()
    }

    /// Error markers themselves are transient, but removing their rows is a
    /// normal playlist edit and therefore must be persisted.
    func removePlaybackErrorEntries(from playlist: PlaylistModel) {
        guard playlist.entries.contains(where: \.hasPlaybackError) else { return }
        playlist.entries.removeAll { $0.hasPlaybackError }
        playlist.structureRevision &+= 1
        playlist.recalculateTotalDuration()
        playlist.selectedIDs.formIntersection(Set(playlist.entries.map(\.id)))
        if let anchor = playlist.selectionAnchorID,
           !playlist.entries.contains(where: { $0.id == anchor }) {
            playlist.selectionAnchorID = nil
        }
        playlist.isDirty = true
        repairTrackReferences(in: playlist)
        markEntriesDirty(in: playlist); save()
    }

    func clear(_ playlist: PlaylistModel) {
        let hadEntries = !playlist.entries.isEmpty
        playlist.entries.removeAll(); playlist.selectedIDs.removeAll(); playlist.selectionAnchorID = nil; playlist.isDirty = true
        if hadEntries { playlist.structureRevision &+= 1 }
        playlist.clearTotalDuration()
        repairTrackReferences(in: playlist)
        markEntriesDirty(in: playlist); save()
    }

    func cropToSelection(_ playlist: PlaylistModel) {
        let previousCount = playlist.entries.count
        playlist.entries.removeAll { !playlist.selectedIDs.contains($0.id) }
        playlist.recalculateTotalDuration()
        playlist.selectedIDs = Set(playlist.entries.map(\.id)); playlist.isDirty = true
        if playlist.entries.count != previousCount { playlist.structureRevision &+= 1 }
        repairTrackReferences(in: playlist)
        markEntriesDirty(in: playlist); save()
    }

    func selectAll(in playlist: PlaylistModel) { playlist.selectedIDs = Set(playlist.entries.map(\.id)); save() }
    func selectNone(in playlist: PlaylistModel) { playlist.selectedIDs.removeAll(); save() }
    func invertSelection(in playlist: PlaylistModel) { playlist.selectedIDs = Set(playlist.entries.map(\.id)).subtracting(playlist.selectedIDs); save() }

    func selectByRating(_ stars: Int, in playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        playlist.selectedIDs = Set(playlist.entries.filter {
            TrackRating.stars(for: $0.rating) == max(0, min(5, stars))
        }.map(\.id))
        playlist.selectionAnchorID = nil
        save()
    }

    /// Dragging a selected row carries the complete selection in playlist order.
    /// Starting a drag from an unselected row keeps the native list behaviour
    /// useful by carrying that row alone.
    func dragPayload(for entry: PlaylistEntry, in playlist: PlaylistModel) -> PlaylistDragPayload? {
        let draggedEntries: [PlaylistEntry]
        if playlist.selectedIDs.contains(entry.id) {
            draggedEntries = playlist.entries.filter { playlist.selectedIDs.contains($0.id) }
        } else {
            draggedEntries = [entry]
        }
        guard !draggedEntries.isEmpty else { return nil }
        return PlaylistDragPayload(
            sourcePlaylistID: playlist.id,
            entryIDs: draggedEntries.map(\.id)
        )
    }

    /// Kept for SwiftUI drop integrations. The actual source gesture is
    /// AppKit-owned because a borderless hosting view does not reliably start
    /// SwiftUI's onDrag session from a Button row.
    func dragProvider(for entry: PlaylistEntry, in playlist: PlaylistModel) -> NSItemProvider {
        guard let payload = dragPayload(for: entry, in: playlist),
              let data = try? JSONEncoder().encode(payload) else { return NSItemProvider() }
        // Use an item-backed provider so AppKit advertises the custom type as
        // soon as the drag session begins; lazy-only representations can be
        // ignored by SwiftUI on borderless hosting windows.
        return NSItemProvider(item: data as NSData, typeIdentifier: PlaylistDragTransfer.typeIdentifier)
    }

    /// Moves entry objects, rather than re-creating them, so bookmarks,
    /// playback errors and metadata already read remain intact.
    func moveDraggedEntries(_ payload: PlaylistDragPayload, to destination: PlaylistModel, at insertionIndex: Int) {
        guard let source = playlist(id: payload.sourcePlaylistID),
              source.id != destination.id,
              playlists.contains(where: { $0.id == destination.id }),
              source.sortingProgress == nil,
              destination.sortingProgress == nil,
              !payload.entryIDs.isEmpty else { return }

        let requestedIDs = Set(payload.entryIDs)
        let movingEntries = source.entries.filter { requestedIDs.contains($0.id) }
        guard !movingEntries.isEmpty else { return }
        let movingIDs = Set(movingEntries.map(\.id))
        let targetIndex = min(max(0, insertionIndex), destination.entries.count)
        let movedPlayingEntry = playingEntryID.map(movingIDs.contains) == true
        let movedLastPlayedEntry = source.lastPlayedEntryID.flatMap { movingIDs.contains($0) ? $0 : nil }

        source.entries.removeAll { movingIDs.contains($0.id) }
        destination.entries.insert(contentsOf: movingEntries, at: targetIndex)
        source.selectedIDs.subtract(movingIDs)
        // A move establishes the transferred rows as the destination's sole
        // active selection, matching Finder-style list dragging.
        destination.selectedIDs = movingIDs
        if movedLastPlayedEntry != nil {
            source.lastPlayedEntryID = nil
            if destination.lastPlayedEntryID == nil {
                destination.lastPlayedEntryID = movedLastPlayedEntry
            }
        }
        if movedPlayingEntry {
            // Keep the playing object and playback engine intact, but make the
            // destination the source for subsequent next/previous commands.
            activePlaylistID = destination.id
        }
        source.scrollPosition = min(source.scrollPosition, max(0, source.entries.count - 1))
        source.structureRevision &+= 1
        destination.structureRevision &+= 1
        source.recalculateTotalDuration()
        destination.appendToTotalDuration(movingEntries)
        source.isDirty = true
        destination.isDirty = true
        repairTrackReferences(in: source)
        markEntriesDirty(in: source)
        markEntriesDirty(in: destination)
        metadataPriorityRevision &+= 1
        scheduleMetadata(for: source)
        scheduleMetadata(for: destination)
        requestMetadataReprioritization()
        save()
    }

    func savePlaylist(_ playlist: PlaylistModel, to url: URL) throws {
        try extendedM3UContents(for: playlist).write(to: url, atomically: true, encoding: .utf8)
        playlist.fileURL = url.resolvingSymlinksInPath().standardizedFileURL
        playlist.name = url.deletingPathExtension().lastPathComponent
        playlist.isDirty = false
        save()
    }

    /// Matches Winamp's M3UWriter: EXTM3U header, EXTINF metadata, then one
    /// path/URL per entry.  Unknown durations use the conventional -1 value.
    private func extendedM3UContents(for playlist: PlaylistModel) -> String {
        var lines = ["#EXTM3U"]
        for entry in playlist.entries {
            let seconds = entry.duration.map { Int($0.rounded()) } ?? -1
            let title = entry.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            lines.append("#EXTINF:\(seconds),\(title)")
            lines.append(entry.url.isFileURL ? entry.url.path : entry.url.absoluteString)
        }
        return lines.joined(separator: "\n").appending("\n")
    }

    @discardableResult func loadPlaylist(from url: URL) throws -> PlaylistModel {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = playlists.first(where: { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }) {
            existing.isVisible = true; activePlaylistID = existing.id; return existing
        }
        if ["m3u", "m3u8"].contains(canonical.pathExtension.lowercased()) {
            let content = try String(contentsOf: canonical, encoding: .utf8)
            var pendingTitle: String?
            var pendingDuration: TimeInterval?
            let entries = content.split(whereSeparator: \.isNewline).compactMap { line -> PlaylistEntry? in
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                if value.uppercased().hasPrefix("#EXTINF:") {
                    let metadata = String(value.dropFirst(8))
                    let parts = metadata.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    pendingDuration = parts.first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
                    pendingTitle = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
                    return nil
                }
                guard !value.hasPrefix("#") else { return nil }
                let itemURL: URL
                if let parsed = URL(string: value), parsed.scheme != nil { itemURL = parsed }
                else { itemURL = URL(fileURLWithPath: value, relativeTo: canonical.deletingLastPathComponent()).standardizedFileURL }
                defer { pendingTitle = nil; pendingDuration = nil }
                return PlaylistEntry(url: itemURL, title: pendingTitle, duration: pendingDuration, metadataIsAvailable: pendingTitle != nil || pendingDuration != nil)
            }
            let playlist = PlaylistModel(name: canonical.deletingPathExtension().lastPathComponent, entries: entries, fileURL: canonical)
            playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }
            markEntriesDirty(in: playlist); save(); scheduleMetadata(for: playlist)
            return playlist
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func statusText(for playlist: PlaylistModel, playbackIndicator: String?) -> String {
        if let sortingProgress = playlist.sortingProgress { return sortingProgress.phase }
        switch playlist.scannerState {
        case .adding: return "Adding"
        case .scanningFolder: return "Loading"
        case .readingMetadata: return "Reading"
        case .paused: return "Paused"
        case .idle: return (activePlaylistID == playlist.id ? "\(playbackIndicator ?? "")\(playlist.name)" : playlist.name)
        }
    }

    func statusCounter(for playlist: PlaylistModel) -> String? {
        if let progress = playlist.sortingProgress {
            return "\(progress.processed)/\(progress.total)"
        }
        switch playlist.scannerState {
        case .adding(let count), .scanningFolder(let count):
            return String(count)
        case .readingMetadata(let processed, let total):
            return "\(processed)/\(total)"
        case .idle, .paused:
            return nil
        }
    }

    private func appendBatch(_ batch: [URL], to playlist: PlaylistModel, at insertionIndex: Int?) -> Int? {
        guard !batch.isEmpty else { return insertionIndex }
        var followingIndex: Int?
        DispatchQueue.main.sync {
            let entries = batch.map { PlaylistEntry(url: $0, bookmarkData: self.securityScopedBookmark(for: $0)) }
            self.propagateBookmarks(from: entries)
            let index = min(max(0, insertionIndex ?? playlist.entries.count), playlist.entries.count)
            playlist.entries.insert(contentsOf: entries, at: index)
            followingIndex = index + entries.count
            playlist.structureRevision &+= 1
            playlist.appendToTotalDuration(entries)
            self.markEntriesDirty(in: playlist)
            playlist.isDirty = true; playlist.scannerState = .scanningFolder(playlist.entries.count)
            self.scheduleMetadata(for: playlist)
            self.save()
        }
        return followingIndex
    }

    private func finishEntryLoading(_ playlist: PlaylistModel) {
        guard playlists.contains(where: { $0.id == playlist.id }), playlist.scannerState != .paused else { return }
        if let progress = metadataProgress[playlist.id], progress.processed > 0 {
            playlist.scannerState = .readingMetadata(processed: progress.processed, total: progress.total)
        } else {
            playlist.scannerState = .idle
        }
        scheduleMetadata(for: playlist)
    }

    private func isLoadingEntries(_ playlist: PlaylistModel) -> Bool {
        switch playlist.scannerState {
        case .adding, .scanningFolder: return true
        case .idle, .readingMetadata, .paused: return false
        }
    }

    private func scheduleMetadata(for playlist: PlaylistModel) {
        guard !pausedPlaylistIDs.contains(playlist.id), playlist.sortingProgress == nil else { return }
        scannerLock.lock()
        let newWorkers = maximumMetadataOperations - metadataWorkersRunning
        metadataWorkersRunning += max(0, newWorkers)
        scannerLock.unlock()
        guard newWorkers > 0 else { return }
        for _ in 0..<newWorkers {
            metadataQueue.async { [weak self] in self?.processNextMetadata() }
        }
    }

    /// Rebuilds the foreground work set immediately.  Reads outside this set
    /// are cancelled instead of making a newly visible row wait for AVFoundation
    /// to finish an obsolete request (which may take several seconds on a slow
    /// volume or a remote URL).
    private func reprioritizeMetadataReading() {
        var preferredEntryIDs = Set<UUID>()
        if playlists.contains(where: { $0.id == activePlaylistID }),
           let playingEntryID {
            preferredEntryIDs.insert(playingEntryID)
        }
        for playlist in playlists where playlist.isVisible && !pausedPlaylistIDs.contains(playlist.id) {
            preferredEntryIDs.formUnion(playlist.selectedIDs)
            let start = min(max(0, playlist.scrollPosition), playlist.entries.count)
            let end = min(playlist.entries.count, start + playlist.visibleEntryCount)
            preferredEntryIDs.formUnion(playlist.entries[start..<end].map(\.id))
        }

        metadataAssetLock.lock()
        for (entryID, asset) in loadingMetadataAssets where !preferredEntryIDs.contains(entryID) {
            cancelledMetadataEntryIDs.insert(entryID)
            asset.cancelLoading()
        }
        metadataAssetLock.unlock()

        playlists.filter { $0.isVisible && !pausedPlaylistIDs.contains($0.id) && $0.sortingProgress == nil }
            .forEach { scheduleMetadata(for: $0) }
    }

    private func metadataRequestWasCancelled(_ entryID: UUID) -> Bool {
        metadataAssetLock.lock()
        defer { metadataAssetLock.unlock() }
        return cancelledMetadataEntryIDs.contains(entryID)
    }

    private func processNextMetadata() {
        var work: (playlist: PlaylistModel, entry: PlaylistEntry, total: Int, priorityRevision: Int, requestID: UInt64)?
        DispatchQueue.main.sync {
            let eligible = playlists
                .filter { $0.isVisible && !pausedPlaylistIDs.contains($0.id) && $0.sortingProgress == nil }
                .sorted { lhs, rhs in
                    let lhsPriority = lhs.id == focusedPlaylistID ? 0 : (lhs.id == activePlaylistID ? 1 : 2)
                    let rhsPriority = rhs.id == focusedPlaylistID ? 0 : (rhs.id == activePlaylistID ? 1 : 2)
                    return lhsPriority < rhsPriority
                }
            // Global order: the playing entry, then every visible range, then
            // all remaining entries.  Exactly one item is read per pump turn,
            // so a changed track or scroll position takes effect immediately.
            if let active = eligible.first(where: { $0.id == activePlaylistID }),
               let playingID = playingEntryID,
               let entry = active.entries.first(where: { $0.id == playingID && !$0.metadataIsAvailable && metadataInFlightRequests[$0.id] == nil }) {
                let requestID = nextMetadataRequestID
                nextMetadataRequestID &+= 1
                metadataInFlightRequests[entry.id] = requestID
                work = (active, entry, active.entries.count, metadataPriorityRevision, requestID)
                return
            }
            for playlist in eligible {
                if let entry = playlist.entries.first(where: {
                    playlist.selectedIDs.contains($0.id)
                        && !$0.metadataIsAvailable
                        && metadataInFlightRequests[$0.id] == nil
                }) {
                    let requestID = nextMetadataRequestID
                    nextMetadataRequestID &+= 1
                    metadataInFlightRequests[entry.id] = requestID
                    work = (playlist, entry, playlist.entries.count, metadataPriorityRevision, requestID)
                    return
                }
            }
            for playlist in eligible {
                let start = min(max(0, playlist.scrollPosition), playlist.entries.count)
                let end = min(playlist.entries.count, start + playlist.visibleEntryCount)
                if let entry = playlist.entries[start..<end].first(where: { !$0.metadataIsAvailable && metadataInFlightRequests[$0.id] == nil }) {
                    let requestID = nextMetadataRequestID
                    nextMetadataRequestID &+= 1
                    metadataInFlightRequests[entry.id] = requestID
                    work = (playlist, entry, playlist.entries.count, metadataPriorityRevision, requestID)
                    return
                }
            }
            for playlist in eligible {
                if let entry = playlist.entries.first(where: { !$0.metadataIsAvailable && metadataInFlightRequests[$0.id] == nil }) {
                    let requestID = nextMetadataRequestID
                    nextMetadataRequestID &+= 1
                    metadataInFlightRequests[entry.id] = requestID
                    work = (playlist, entry, playlist.entries.count, metadataPriorityRevision, requestID)
                    return
                }
            }
        }
        guard let work else {
            finishMetadataWorker()
            return
        }

        let result: (duration: TimeInterval?, artist: String?, title: String?, rating: UInt8, available: Bool) = autoreleasepool {
            let asset = AVURLAsset(url: work.entry.url)
            metadataAssetLock.lock()
            loadingMetadataAssets[work.entry.id] = asset
            metadataAssetLock.unlock()
            let semaphore = DispatchSemaphore(value: 0)
            asset.loadValuesAsynchronously(forKeys: ["duration", "commonMetadata"]) { semaphore.signal() }
            // cancelLoading() does not reliably invoke the completion handler
            // on every remote/server format. Polling the semaphore gives a
            // changed visible range or a newly playing track the worker within
            // 100 ms instead of waiting for the old 10-second timeout.
            var didLoad = false
            for _ in 0..<100 {
                if semaphore.wait(timeout: .now() + 0.1) == .success {
                    didLoad = true
                    break
                }
                if metadataRequestWasCancelled(work.entry.id) { return (nil, nil, nil, 0, false) }
            }
            guard didLoad else { return (nil, nil, nil, 0, false) }
            var error: NSError?
            guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded else { return (nil, nil, nil, 0, false) }
            let duration = asset.duration.seconds
            let artist = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
            let title = asset.commonMetadata.first(where: { $0.commonKey?.rawValue == "title" })?.stringValue
            let rating = TrackRatingStore.readOrInitialize(url: work.entry.url, allowWrite: true)?.rating ?? 0
            return (duration.isFinite && duration > 0 ? duration : nil, artist, title, rating, true)
        }
        let applyResult = DispatchWorkItem { [self] in
            metadataAssetLock.lock()
            loadingMetadataAssets.removeValue(forKey: work.entry.id)
            let wasCancelled = cancelledMetadataEntryIDs.remove(work.entry.id) != nil
            metadataAssetLock.unlock()
            guard metadataInFlightRequests[work.entry.id] == work.requestID else { return }
            metadataInFlightRequests.removeValue(forKey: work.entry.id)
            guard let owner = playlists.first(where: { playlist in
                playlist.entries.contains { $0.id == work.entry.id }
            }) else { return }
            guard !wasCancelled, !pausedPlaylistIDs.contains(owner.id), owner.sortingProgress == nil, !work.entry.metadataIsAvailable else { return }
            let previousDuration = work.entry.duration
            work.entry.duration = result.duration
            work.entry.rating = result.rating
            owner.replaceTotalDuration(previousDuration, with: result.duration)
            let artist = result.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (artist?.isEmpty == false ? artist : nil, title?.isEmpty == false ? title : nil) {
            case let (.some(artist), .some(title)):
                work.entry.artist = artist
                work.entry.trackTitle = title
                work.entry.title = "\(artist) - \(title)"
            case let (.some(artist), nil):
                work.entry.artist = artist
                work.entry.trackTitle = nil
                work.entry.title = artist
            case let (nil, .some(title)):
                work.entry.artist = nil
                work.entry.trackTitle = title
                work.entry.title = title
            case (nil, nil):
                work.entry.artist = nil
                work.entry.trackTitle = nil
                break
            }
            // A timeout/error is still a completed attempt; retrying it forever
            // would prevent lower-priority entries from ever being scanned.
            work.entry.metadataIsAvailable = true
            markEntriesDirty(in: owner)
            let previous = metadataProgress[owner.id] ?? (0, owner.entries.count)
            let progress = (previous.processed + 1, max(previous.total, owner.entries.count))
            metadataProgress[owner.id] = progress
            // Each visible row observes its own PlaylistEntry, so applying this
            // result refreshes only that row. The scanner status still follows
            // visible completions without invalidating the list during folder
            // insertion, where Loading remains the higher-priority state.
            let visibleStart = min(max(0, owner.scrollPosition), owner.entries.count)
            let visibleEnd = min(owner.entries.count, visibleStart + owner.visibleEntryCount)
            let completedEntryIsVisible = owner.entries[visibleStart..<visibleEnd]
                .contains { $0.id == work.entry.id }
            let shouldPublishUpdate = completedEntryIsVisible
                || progress.0 == progress.1
                || progress.0.isMultiple(of: 8)
            if !isLoadingEntries(owner),
               shouldPublishUpdate {
                owner.scannerState = .readingMetadata(processed: progress.0, total: progress.1)
            }
        }
        DispatchQueue.main.async(execute: applyResult)
        let priorityChanged = DispatchQueue.main.sync {
            metadataPriorityRevision != work.priorityRevision
        }
        let nextDelay = priorityChanged ? 0 : metadataWorkInterval
        metadataQueue.asyncAfter(deadline: .now() + nextDelay) { [weak self] in
            self?.processNextMetadata()
        }
    }

    private func finishMetadataWorker() {
        scannerLock.lock()
        metadataWorkersRunning = max(0, metadataWorkersRunning - 1)
        let isIdle = metadataWorkersRunning == 0
        scannerLock.unlock()
        guard isIdle else { return }
        DispatchQueue.main.async {
            self.metadataProgress.removeAll()
            self.playlists.forEach {
                if $0.scannerState != .paused && !self.isLoadingEntries($0) { $0.scannerState = .idle }
            }
            self.save()
        }
    }

    private func prioritize(_ entry: PlaylistEntry, in playlist: PlaylistModel) {
        // The scanner is serial; marking the playing entry unresolved causes its
        // metadata work to be scheduled before subsequent idle entries.
        if !entry.metadataIsAvailable { scheduleMetadata(for: playlist) }
    }
    private func addRecent(_ url: URL) { recentPlaylistURLs.removeAll { $0 == url }; recentPlaylistURLs.insert(url, at: 0); recentPlaylistURLs = Array(recentPlaylistURLs.prefix(10)) }

    private static let splitPlaylistPersistenceVersion = 2

    private struct Snapshot: Codable {
        var version: Int
        var recent: [URL]
        var playlists: [StoredPlaylist]
        var activePlaylistID: UUID?
        var focusedPlaylistID: UUID?
        var playingEntryID: UUID?
    }

    private struct StoredPlaylist: Codable {
        var id: UUID
        var name: String
        var fileURL: URL?
        var visible: Bool
        var shaded: Bool
        var frame: CGRect?
        var unshadedWidth: Double?
        var unshadedHeight: Double?
        var selection: [UUID]?
        var scrollPosition: Int?
        var lastPlayedEntryID: UUID?
        var automaticRatingEnabled: Bool?
    }

    private struct StoredEntry: Codable {
        var id: UUID; var url: URL; var bookmark: Data?; var title: String
        var artist: String?; var trackTitle: String?
        var duration: TimeInterval?; var metadata: Bool; var rating: UInt8?
    }

    private func markEntriesDirty(in playlist: PlaylistModel) {
        dirtyPlaylistEntryIDs.insert(playlist.id)
    }

    /// Repairs every ID owned by the main snapshot after entry removal or a
    /// partially missing persistence set. A stale non-nil cursor falls back
    /// to the first surviving entry, while an intentionally nil cursor stays
    /// nil. This keeps Stop semantics unchanged.
    @discardableResult
    private func repairTrackReferences(in playlist: PlaylistModel) -> Bool {
        let validIDs = Set(playlist.entries.map(\.id))
        let previousSelection = playlist.selectedIDs
        let previousLastPlayed = playlist.lastPlayedEntryID
        let previousPlaying = playingEntryID

        playlist.selectedIDs.formIntersection(validIDs)
        if let lastPlayed = playlist.lastPlayedEntryID, !validIDs.contains(lastPlayed) {
            playlist.lastPlayedEntryID = playlist.entries.first?.id
        }
        if activePlaylistID == playlist.id,
           let playing = playingEntryID,
           !validIDs.contains(playing) {
            playingEntryID = playlist.entries.first?.id
        }
        return previousSelection != playlist.selectedIDs
            || previousLastPlayed != playlist.lastPlayedEntryID
            || previousPlaying != playingEntryID
    }

    /// Most calls happen in bursts (folder scans, metadata updates, scrolling).
    /// The main snapshot is small; only dirty entry files are encoded and
    /// atomically replaced after the debounce interval.
    func save() {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingSaveWorkItem = nil
            self?.writeSnapshot()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func flushSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        writeSnapshot()
    }

    private func writeSnapshot() {
        let currentIDs = Set(playlists.map(\.id))
        dirtyPlaylistEntryIDs.formIntersection(currentIDs)
        for playlist in playlists where !FileManager.default.fileExists(atPath: entriesURL(for: playlist.id).path) {
            dirtyPlaylistEntryIDs.insert(playlist.id)
        }

        do {
            try FileManager.default.createDirectory(at: playlistEntriesDirectoryURL, withIntermediateDirectories: true)
            let dirtyPlaylists = playlists.filter { dirtyPlaylistEntryIDs.contains($0.id) }
            for playlist in dirtyPlaylists {
                let storedEntries = playlist.entries.map(storedEntry(from:))
                let data = try JSONEncoder().encode(storedEntries)
                try data.write(to: entriesURL(for: playlist.id), options: .atomic)
            }

            let stored = playlists.map { playlist in
                StoredPlaylist(
                    id: playlist.id,
                    name: playlist.name,
                    fileURL: playlist.fileURL,
                    visible: playlist.isVisible,
                    shaded: playlist.isWindowShaded,
                    frame: playlist.windowFrame,
                    unshadedWidth: playlist.unshadedWindowWidth.map(Double.init),
                    unshadedHeight: playlist.unshadedWindowHeight.map(Double.init),
                    selection: Array(playlist.selectedIDs),
                    scrollPosition: playlist.scrollPosition,
                    lastPlayedEntryID: playlist.lastPlayedEntryID,
                    automaticRatingEnabled: playlist.automaticRatingEnabled
                )
            }
            let snapshot = Snapshot(
                version: Self.splitPlaylistPersistenceVersion,
                recent: recentPlaylistURLs,
                playlists: stored,
                activePlaylistID: activePlaylistID,
                focusedPlaylistID: focusedPlaylistID,
                playingEntryID: playingEntryID
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)

            dirtyPlaylistEntryIDs.subtract(dirtyPlaylists.map(\.id))
            mainSnapshotNeedsRewrite = false
            cleanupOrphanedEntryFiles(keeping: currentIDs)
        } catch {
            // Retain dirty IDs so the next coalesced save or termination flush
            // retries the complete child-files-before-index transaction.
            return
        }
    }

    private func restore(invalidateMetadata: Bool = false) {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        let decoder = JSONDecoder()

        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.version == Self.splitPlaylistPersistenceVersion else { return }
        recentPlaylistURLs = snapshot.recent
        activePlaylistID = snapshot.activePlaylistID
        focusedPlaylistID = snapshot.focusedPlaylistID
        playingEntryID = snapshot.playingEntryID

        var storedEntries: [UUID: [StoredEntry]] = [:]
        for playlist in snapshot.playlists {
            let url = entriesURL(for: playlist.id)
            if let entryData = try? Data(contentsOf: url),
               let decoded = try? decoder.decode([StoredEntry].self, from: entryData) {
                storedEntries[playlist.id] = decoded
            } else {
                storedEntries[playlist.id] = []
                if !FileManager.default.fileExists(atPath: url.path) {
                    dirtyPlaylistEntryIDs.insert(playlist.id)
                }
            }
        }

        playlists = snapshot.playlists.map { playlist in
            var entriesNeedRewrite = invalidateMetadata
            let entries = (storedEntries[playlist.id] ?? []).map { storedEntry in
                let resolvedURL = resolvedBookmarkURL(storedEntry.bookmark)
                // Ad-hoc Debug signatures cannot retain an app-scoped
                // bookmark across rebuilds. Keeping that now-invalid data
                // would make playback reject an otherwise readable stored
                // URL merely because `bookmarkData` is non-nil.
                if storedEntry.bookmark != nil, resolvedURL == nil { entriesNeedRewrite = true }
                return PlaylistEntry(
                    id: storedEntry.id,
                    url: resolvedURL ?? storedEntry.url,
                    bookmarkData: resolvedURL == nil ? nil : storedEntry.bookmark,
                    title: storedEntry.title,
                    artist: storedEntry.artist,
                    trackTitle: storedEntry.trackTitle,
                    duration: storedEntry.duration,
                    metadataIsAvailable: invalidateMetadata ? false : storedEntry.metadata,
                    rating: storedEntry.rating ?? 0
                )
            }
            let model = PlaylistModel(id: playlist.id, name: playlist.name, entries: entries, fileURL: playlist.fileURL,
                                      automaticRatingEnabled: playlist.automaticRatingEnabled ?? RatingPreferences.shared.enableForAllPlaylists)
            model.isVisible = playlist.visible
            model.isWindowShaded = playlist.shaded
            model.windowFrame = playlist.frame
            model.unshadedWindowWidth = playlist.unshadedWidth.map { CGFloat($0) }
            model.unshadedWindowHeight = playlist.unshadedHeight.map { CGFloat($0) }
            model.selectedIDs = Set(playlist.selection ?? [])
            model.scrollPosition = playlist.scrollPosition ?? 0
            model.lastPlayedEntryID = playlist.lastPlayedEntryID
            if entriesNeedRewrite { dirtyPlaylistEntryIDs.insert(playlist.id) }
            return model
        }

        if !playlists.contains(where: { $0.id == activePlaylistID }) {
            activePlaylistID = playlists.first?.id
            mainSnapshotNeedsRewrite = true
        }
        if !playlists.contains(where: { $0.id == focusedPlaylistID }) {
            focusedPlaylistID = activePlaylistID ?? playlists.first?.id
            mainSnapshotNeedsRewrite = true
        }
        for playlist in playlists {
            if repairTrackReferences(in: playlist) { mainSnapshotNeedsRewrite = true }
        }
        cleanupOrphanedEntryFiles(keeping: Set(playlists.map(\.id)))
    }

    private func storedEntry(from entry: PlaylistEntry) -> StoredEntry {
        StoredEntry(
            id: entry.id,
            url: entry.url,
            bookmark: entry.bookmarkData,
            title: entry.title,
            artist: entry.artist,
            trackTitle: entry.trackTitle,
            duration: entry.duration,
            metadata: entry.metadataIsAvailable, rating: entry.rating
        )
    }

    private func entriesURL(for playlistID: UUID) -> URL {
        playlistEntriesDirectoryURL.appendingPathComponent("\(playlistID.uuidString).json", isDirectory: false)
    }

    private func cleanupOrphanedEntryFiles(keeping playlistIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: playlistEntriesDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let expectedNames = Set(playlistIDs.map { "\($0.uuidString).json" })
        for file in files where file.pathExtension.lowercased() == "json"
            && !expectedNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func securityScopedBookmark(for url: URL) -> Data? {
        let beganScope = url.startAccessingSecurityScopedResource()
        defer { if beganScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            return bookmark
        } catch {
            return nil
        }
    }

    private func resolvedBookmarkURL(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }

    /// Older snapshots contain paths only. When the user subsequently adds a
    /// file through the system picker, reuse its newly granted bookmark for
    /// every matching existing row instead of requiring a rebuilt playlist.
    private func propagateBookmarks(from entries: [PlaylistEntry]) {
        var bookmarksByPath: [String: Data] = [:]
        for entry in entries {
            if let bookmark = entry.bookmarkData {
                bookmarksByPath[entry.url.resolvingSymlinksInPath().standardizedFileURL.path] = bookmark
            }
        }
        guard !bookmarksByPath.isEmpty else { return }
        for playlist in playlists {
            var entriesChanged = false
            for entry in playlist.entries where entry.bookmarkData == nil {
                if let bookmark = bookmarksByPath[entry.url.resolvingSymlinksInPath().standardizedFileURL.path] {
                    entry.bookmarkData = bookmark
                    entriesChanged = true
                }
            }
            if entriesChanged { markEntriesDirty(in: playlist) }
        }
    }
}
