import AVFoundation
import AppKit
import Combine
import Foundation

/// The persistent, window-independent playlist domain model.  Windows only
/// render this state; hiding a window never destroys a playlist or its work.
final class PlaylistEntry: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    @Published var title: String
    @Published var duration: TimeInterval?
    @Published var metadataIsAvailable = false

    init(id: UUID = UUID(), url: URL, title: String? = nil, duration: TimeInterval? = nil, metadataIsAvailable: Bool = false) {
        self.id = id; self.url = url; self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration; self.metadataIsAvailable = metadataIsAvailable
    }
}

final class PlaylistModel: ObservableObject, Identifiable {
    enum ScannerState: Equatable { case idle, adding(Int), scanningFolder(Int), readingMetadata(processed: Int, total: Int), paused }
    let id: UUID
    @Published var name: String
    @Published var entries: [PlaylistEntry]
    @Published var selectedIDs = Set<UUID>()
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
    /// A lightweight invalidation token for visible rows.  Metadata may be
    /// read while the status must remain "Loading", so scannerState cannot be
    /// used to refresh the row text in that phase.
    @Published var metadataRevision = 0
    /// Logical (unshaded) editor dimensions.  A shaded frame is only 14 px
    /// high and therefore cannot be used to restore the expanded height.
    @Published var unshadedWindowWidth: CGFloat?
    @Published var unshadedWindowHeight: CGFloat?
    @Published var scannerState: ScannerState = .idle
    @Published var isDirty = false
    var fileURL: URL?
    private var cachedTotalDuration: TimeInterval

    init(id: UUID = UUID(), name: String = "New Playlist", entries: [PlaylistEntry] = [], fileURL: URL? = nil) {
        self.id = id; self.name = name; self.entries = entries; self.fileURL = fileURL
        cachedTotalDuration = entries.compactMap(\.duration).reduce(0, +)
    }
    var totalDuration: TimeInterval { cachedTotalDuration }
    var hasUnknownDurations: Bool { entries.contains { $0.duration == nil } }
    func recalculateTotalDuration() { cachedTotalDuration = entries.compactMap(\.duration).reduce(0, +) }
    func appendToTotalDuration(_ newEntries: [PlaylistEntry]) {
        cachedTotalDuration += newEntries.compactMap(\.duration).reduce(0, +)
    }
    func addToTotalDuration(_ duration: TimeInterval?) { cachedTotalDuration += duration ?? 0 }
    func clearTotalDuration() { cachedTotalDuration = 0 }
}

/// Single authority for opening, saving and scanning playlists.  Its queues are
/// serial by design: network folders cannot create an unbounded number of jobs.
final class PlaylistManager: ObservableObject {
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"]
    @Published private(set) var playlists: [PlaylistModel] = []
    @Published private(set) var activePlaylistID: UUID?
    @Published private(set) var focusedPlaylistID: UUID?
    @Published private(set) var playingEntryID: UUID?
    /// A playback command may target the same restored entry ID, in which case
    /// observing `playingEntryID` alone emits no SwiftUI change.  This token
    /// represents the command itself and lets the editor reveal an off-screen
    /// current row on every transport start.
    @Published private(set) var playbackRevealRevision = 0
    @Published private(set) var recentPlaylistURLs: [URL] = []

    private let folderQueue = DispatchQueue(label: "ru.aleksandr.MacAmp.playlist.folder", qos: .utility)
    private let metadataQueue = DispatchQueue(label: "ru.aleksandr.MacAmp.playlist.metadata", qos: .background, attributes: .concurrent)
    private let persistenceURL: URL
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
    /// Accessed only on the main queue, alongside playlist models.
    private var metadataInFlightEntryIDs = Set<UUID>()
    /// AVFoundation loads can otherwise occupy both workers long after the
    /// user scrolls to another part of a large playlist.  This lock protects
    /// the assets while they are owned by metadata worker threads.
    private let metadataAssetLock = NSLock()
    private var loadingMetadataAssets: [UUID: AVURLAsset] = [:]
    private var cancelledMetadataEntryIDs = Set<UUID>()
    private var pendingMetadataReprioritization: DispatchWorkItem?
    private var pendingMetadataResume: DispatchWorkItem?
    /// Starting a remote track takes precedence over cosmetic tag discovery.
    /// AVFoundation otherwise opens the same file in two metadata workers and
    /// competes with the audio decoder for the network volume.
    private var metadataHoldUntil = Date.distantPast
    /// Keeps parsing off-main while pacing visual insertion.  Enqueuing all
    /// parsed chunks at once starves a run-loop frame and makes the Loading
    /// counter appear to jump from zero to a large number.
    private struct PendingPlaylistLoad {
        var entries: [PlaylistEntry] = []
        var nextIndex = 0
        var parserFinished = false
        var isDraining = false
    }
    private var pendingPlaylistLoads: [UUID: PendingPlaylistLoad] = [:]
    // The Loading counter is an exact row counter: advance it one entry at a
    // time, rather than reporting parser blocks such as 128 records.
    private let visibleLoadingBatchSize = 1
    private let visibleLoadingBatchInterval: TimeInterval = 1.0 / 60.0
    private var waitingCursorPlaylistIDs = Set<UUID>()
    private var pendingSaveWorkItem: DispatchWorkItem?
    /// Metadata discovery is intentionally gentle: it must never compete with
    /// audio rendering just to fill columns that are not currently visible.
    private let metadataWorkInterval: TimeInterval = 0.25

    init() {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("MacAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistenceURL = directory.appendingPathComponent("playlists.json")
        restore()
        if playlists.isEmpty { playlists = [PlaylistModel(name: "Playlist")] }
        DispatchQueue.main.async { [weak self] in self?.playlists.filter(\.isVisible).forEach { self?.scheduleMetadata(for: $0) } }
    }

    var activePlaylist: PlaylistModel? { playlists.first { $0.id == activePlaylistID } ?? playlists.first }
    var editingPlaylist: PlaylistModel? { playlists.first { $0.id == focusedPlaylistID } ?? activePlaylist }
    func playlist(id: UUID) -> PlaylistModel? { playlists.first { $0.id == id } }
    func isOpenPlaylist(at url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return playlists.contains { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }
    }

    @discardableResult func createPlaylist(name: String = "New Playlist") -> PlaylistModel {
        let playlist = PlaylistModel(name: name)
        playlists.append(playlist); focusedPlaylistID = playlist.id; save(); return playlist
    }

    /// Resolves symlinks before comparing paths, so every open route observes
    /// the one-window-per-saved-playlist rule.
    @discardableResult func openPlaylist(at url: URL) -> PlaylistModel {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = playlists.first(where: { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }) {
            existing.isVisible = true; focusedPlaylistID = existing.id; return existing
        }
        let playlist = PlaylistModel(name: canonical.deletingPathExtension().lastPathComponent, fileURL: canonical)
        playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }; save(); return playlist
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
        playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }; save()
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
        playlist.appendToTotalDuration(entries)
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
        guard playlists.count > 1 else { playlist.isVisible = false; save(); return }
        if let url = playlist.fileURL { addRecent(url) }
        let wasActive = activePlaylistID == playlist.id
        playlists.removeAll { $0.id == playlist.id }
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
        if visible { pausedPlaylistIDs.remove(playlist.id); scheduleMetadata(for: playlist) }
        else { pausedPlaylistIDs.insert(playlist.id); playlist.scannerState = .paused }
        save()
    }

    func addFiles(_ urls: [URL], to playlist: PlaylistModel) {
        let audio = urls.filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return }
        let entries = audio.map { PlaylistEntry(url: $0) }
        playlist.entries.append(contentsOf: entries)
        playlist.appendToTotalDuration(entries)
        playlist.isDirty = true; playlist.scannerState = .adding(playlist.entries.count); save(); finishEntryLoading(playlist)
    }

    func addFolder(_ folder: URL, to playlist: PlaylistModel) {
        cancelledFolderPlaylistIDs.remove(playlist.id)
        folderQueue.async { [weak self, weak playlist] in
            guard let self, let playlist else { return }
            let deadline = Date().addingTimeInterval(30)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
            var batch: [URL] = []
            for case let url as URL in enumerator {
                if Date() >= deadline || self.cancelledFolderPlaylistIDs.contains(playlist.id) { break }
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                batch.append(url)
                if batch.count == 32 { self.appendBatch(batch, to: playlist); batch.removeAll() }
            }
            self.appendBatch(batch, to: playlist)
            DispatchQueue.main.async { self.finishEntryLoading(playlist) }
        }
    }

    func cancelFolderScans() { cancelledFolderPlaylistIDs.formUnion(playlists.map(\.id)) }

    func play(_ entry: PlaylistEntry, in playlist: PlaylistModel, revealIfNeeded: Bool = true) {
        activePlaylistID = playlist.id; focusedPlaylistID = playlist.id
        playlist.lastPlayedEntryID = entry.id; playingEntryID = entry.id
        if revealIfNeeded { playbackRevealRevision &+= 1 }
        deferMetadataForPlaybackStart()
        save()
    }

    private func deferMetadataForPlaybackStart() {
        metadataHoldUntil = Date().addingTimeInterval(2)
        metadataAssetLock.lock()
        for (entryID, asset) in loadingMetadataAssets {
            cancelledMetadataEntryIDs.insert(entryID)
            asset.cancelLoading()
        }
        metadataAssetLock.unlock()
        pendingMetadataResume?.cancel()
        let resume = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.metadataHoldUntil = .distantPast
            self.playlists.filter { $0.isVisible && !self.pausedPlaylistIDs.contains($0.id) }
                .forEach { self.scheduleMetadata(for: $0) }
        }
        pendingMetadataResume = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: resume)
    }

    func preferredEntryToPlay(in playlist: PlaylistModel) -> PlaylistEntry? {
        if activePlaylistID == playlist.id,
           let current = playingEntryID,
           let entry = playlist.entries.first(where: { $0.id == current }) { return entry }
        if let previous = playlist.lastPlayedEntryID,
           let entry = playlist.entries.first(where: { $0.id == previous }) { return entry }
        if let selected = playlist.entries.first(where: { playlist.selectedIDs.contains($0.id) }) { return selected }
        return playlist.entries.first
    }

    func entryToPlay(in playlist: PlaylistModel, step: Int, shuffle: Bool) -> PlaylistEntry? {
        guard !playlist.entries.isEmpty else { return nil }
        if shuffle {
            // A shuffle transition must make progress.  Keep the only entry
            // eligible, but never immediately choose the currently playing
            // one when another track exists.
            let alternatives = playlist.entries.filter { $0.id != playingEntryID }
            return (alternatives.isEmpty ? playlist.entries : alternatives).randomElement()
        }
        guard let current = playingEntryID,
              let index = playlist.entries.firstIndex(where: { $0.id == current }) else { return playlist.entries.first }
        let candidate = index + step
        guard playlist.entries.indices.contains(candidate) else { return nil }
        return playlist.entries[candidate]
    }

    func focus(_ playlist: PlaylistModel) { focusedPlaylistID = playlist.id; save() }

    func visibleRangeChanged(for playlist: PlaylistModel, firstEntry: Int, visibleCount: Int) {
        let position = max(0, min(firstEntry, max(0, playlist.entries.count - 1)))
        let count = max(1, visibleCount)
        guard playlist.scrollPosition != position || playlist.visibleEntryCount != count else { return }
        playlist.scrollPosition = position
        playlist.visibleEntryCount = count
        requestMetadataReprioritization()
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
        playlist.entries.removeAll { playlist.selectedIDs.contains($0.id) }
        playlist.recalculateTotalDuration()
        playlist.selectedIDs.removeAll(); playlist.isDirty = true; save()
    }

    func clear(_ playlist: PlaylistModel) {
        playlist.entries.removeAll(); playlist.selectedIDs.removeAll(); playlist.isDirty = true
        playlist.clearTotalDuration()
        if activePlaylistID == playlist.id { playingEntryID = nil }
        save()
    }

    func cropToSelection(_ playlist: PlaylistModel) {
        playlist.entries.removeAll { !playlist.selectedIDs.contains($0.id) }
        playlist.recalculateTotalDuration()
        playlist.selectedIDs = Set(playlist.entries.map(\.id)); playlist.isDirty = true
        if let playing = playingEntryID, !playlist.entries.contains(where: { $0.id == playing }) { playingEntryID = nil }
        save()
    }

    func selectAll(in playlist: PlaylistModel) { playlist.selectedIDs = Set(playlist.entries.map(\.id)); save() }
    func selectNone(in playlist: PlaylistModel) { playlist.selectedIDs.removeAll(); save() }
    func invertSelection(in playlist: PlaylistModel) { playlist.selectedIDs = Set(playlist.entries.map(\.id)).subtracting(playlist.selectedIDs); save() }

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
            playlists.append(playlist); focusedPlaylistID = playlist.id; recentPlaylistURLs.removeAll { $0 == canonical }; save(); scheduleMetadata(for: playlist)
            return playlist
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func statusText(for playlist: PlaylistModel, playbackIndicator: String?) -> String {
        switch playlist.scannerState {
        case .adding: return "Adding"
        case .scanningFolder: return "Loading"
        case .readingMetadata: return "Reading"
        case .paused: return "Paused"
        case .idle: return (activePlaylistID == playlist.id ? "\(playbackIndicator ?? "")\(playlist.name)" : playlist.name)
        }
    }

    func statusCounter(for playlist: PlaylistModel) -> String? {
        switch playlist.scannerState {
        case .adding(let count), .scanningFolder(let count):
            return String(count)
        case .readingMetadata(let processed, let total):
            return "\(processed)/\(total)"
        case .idle, .paused:
            return nil
        }
    }

    private func appendBatch(_ batch: [URL], to playlist: PlaylistModel) {
        guard !batch.isEmpty else { return }
        DispatchQueue.main.sync {
            let entries = batch.map { PlaylistEntry(url: $0) }
            playlist.entries.append(contentsOf: entries)
            playlist.appendToTotalDuration(entries)
            playlist.isDirty = true; playlist.scannerState = .scanningFolder(playlist.entries.count)
            self.scheduleMetadata(for: playlist)
            self.save()
        }
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
        guard !pausedPlaylistIDs.contains(playlist.id) else { return }
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
        if let active = playlists.first(where: { $0.id == activePlaylistID }),
           let playingEntryID {
            preferredEntryIDs.insert(playingEntryID)
        }
        for playlist in playlists where playlist.isVisible && !pausedPlaylistIDs.contains(playlist.id) {
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

        playlists.filter { $0.isVisible && !pausedPlaylistIDs.contains($0.id) }
            .forEach { scheduleMetadata(for: $0) }
    }

    private func metadataRequestWasCancelled(_ entryID: UUID) -> Bool {
        metadataAssetLock.lock()
        defer { metadataAssetLock.unlock() }
        return cancelledMetadataEntryIDs.contains(entryID)
    }

    private func processNextMetadata() {
        var work: (playlist: PlaylistModel, entry: PlaylistEntry, total: Int)?
        DispatchQueue.main.sync {
            guard Date() >= metadataHoldUntil else { return }
            let eligible = playlists
                .filter { $0.isVisible && !pausedPlaylistIDs.contains($0.id) }
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
               let entry = active.entries.first(where: { $0.id == playingID && !$0.metadataIsAvailable && !metadataInFlightEntryIDs.contains($0.id) }) {
                metadataInFlightEntryIDs.insert(entry.id)
                work = (active, entry, active.entries.count)
                return
            }
            for playlist in eligible {
                let start = min(max(0, playlist.scrollPosition), playlist.entries.count)
                let end = min(playlist.entries.count, start + playlist.visibleEntryCount)
                if let entry = playlist.entries[start..<end].first(where: { !$0.metadataIsAvailable && !metadataInFlightEntryIDs.contains($0.id) }) {
                    metadataInFlightEntryIDs.insert(entry.id)
                    work = (playlist, entry, playlist.entries.count)
                    return
                }
            }
            for playlist in eligible {
                if let entry = playlist.entries.first(where: { !$0.metadataIsAvailable && !metadataInFlightEntryIDs.contains($0.id) }) {
                    metadataInFlightEntryIDs.insert(entry.id)
                    work = (playlist, entry, playlist.entries.count)
                    return
                }
            }
        }
        guard let work else {
            finishMetadataWorker()
            return
        }

        let result: (duration: TimeInterval?, title: String?, available: Bool) = autoreleasepool {
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
                if metadataRequestWasCancelled(work.entry.id) { return (nil, nil, false) }
            }
            guard didLoad else { return (nil, nil, false) }
            var error: NSError?
            guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded else { return (nil, nil, false) }
            let duration = asset.duration.seconds
            let title = asset.commonMetadata.first(where: { $0.commonKey?.rawValue == "title" })?.stringValue
            return (duration.isFinite && duration > 0 ? duration : nil, title, true)
        }
        let applyResult = DispatchWorkItem { [self] in
            metadataAssetLock.lock()
            loadingMetadataAssets.removeValue(forKey: work.entry.id)
            let wasCancelled = cancelledMetadataEntryIDs.remove(work.entry.id) != nil
            metadataAssetLock.unlock()
            metadataInFlightEntryIDs.remove(work.entry.id)
            guard !wasCancelled, !pausedPlaylistIDs.contains(work.playlist.id), !work.entry.metadataIsAvailable else { return }
            work.entry.duration = result.duration
            work.playlist.addToTotalDuration(result.duration)
            if let title = result.title, !title.isEmpty { work.entry.title = title }
            // A timeout/error is still a completed attempt; retrying it forever
            // would prevent lower-priority entries from ever being scanned.
            work.entry.metadataIsAvailable = true
            let previous = metadataProgress[work.playlist.id] ?? (0, work.total)
            let progress = (previous.processed + 1, max(previous.total, work.total))
            metadataProgress[work.playlist.id] = progress
            // The status field does not need a full SwiftUI invalidation for
            // every single file.  Updating it in small batches keeps scrolling
            // smooth while the displayed counter still advances regularly.
            if !isLoadingEntries(work.playlist),
               (progress.0 == progress.1 || progress.0.isMultiple(of: 8)) {
                work.playlist.scannerState = .readingMetadata(processed: progress.0, total: progress.1)
            }
            if progress.0.isMultiple(of: 8) { work.playlist.metadataRevision &+= 1 }
        }
        DispatchQueue.main.async(execute: applyResult)
        metadataQueue.asyncAfter(deadline: .now() + metadataWorkInterval) { [weak self] in
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

    private struct Snapshot: Codable { var recent: [URL]; var playlists: [StoredPlaylist]; var activePlaylistID: UUID?; var focusedPlaylistID: UUID?; var playingEntryID: UUID? }
    private struct StoredPlaylist: Codable { var id: UUID; var name: String; var fileURL: URL?; var visible: Bool; var shaded: Bool; var frame: CGRect?; var unshadedWidth: Double?; var unshadedHeight: Double?; var entries: [StoredEntry]; var selection: [UUID]?; var scrollPosition: Int?; var lastPlayedEntryID: UUID? }
    private struct StoredEntry: Codable { var id: UUID; var url: URL; var title: String; var duration: TimeInterval?; var metadata: Bool }
    /// Most calls happen in bursts (folder scans, metadata updates, scrolling).
    /// Writing a full JSON snapshot for every one of them creates O(n²) disk
    /// work for a playlist with n tracks.  Coalesce those mutations instead.
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
        let stored = playlists.map { p in StoredPlaylist(id: p.id, name: p.name, fileURL: p.fileURL, visible: p.isVisible, shaded: p.isWindowShaded, frame: p.windowFrame, unshadedWidth: p.unshadedWindowWidth.map(Double.init), unshadedHeight: p.unshadedWindowHeight.map(Double.init), entries: p.entries.map { StoredEntry(id: $0.id, url: $0.url, title: $0.title, duration: $0.duration, metadata: $0.metadataIsAvailable) }, selection: Array(p.selectedIDs), scrollPosition: p.scrollPosition, lastPlayedEntryID: p.lastPlayedEntryID) }
        if let data = try? JSONEncoder().encode(Snapshot(recent: recentPlaylistURLs, playlists: stored, activePlaylistID: activePlaylistID, focusedPlaylistID: focusedPlaylistID, playingEntryID: playingEntryID)) { try? data.write(to: persistenceURL, options: .atomic) }
    }
    private func restore() {
        guard let data = try? Data(contentsOf: persistenceURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        recentPlaylistURLs = snapshot.recent
        activePlaylistID = snapshot.activePlaylistID
        focusedPlaylistID = snapshot.focusedPlaylistID
        playingEntryID = snapshot.playingEntryID
        playlists = snapshot.playlists.map { p in let model = PlaylistModel(id: p.id, name: p.name, entries: p.entries.map { PlaylistEntry(id: $0.id, url: $0.url, title: $0.title, duration: $0.duration, metadataIsAvailable: $0.metadata) }, fileURL: p.fileURL); model.isVisible = p.visible; model.isWindowShaded = p.shaded; model.windowFrame = p.frame; model.unshadedWindowWidth = p.unshadedWidth.map { CGFloat($0) }; model.unshadedWindowHeight = p.unshadedHeight.map { CGFloat($0) }; model.selectedIDs = Set(p.selection ?? []); model.scrollPosition = p.scrollPosition ?? 0; model.lastPlayedEntryID = p.lastPlayedEntryID; return model }
    }
}
