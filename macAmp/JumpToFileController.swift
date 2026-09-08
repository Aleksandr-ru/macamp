import AppKit

/// Native counterpart of Winamp's modeless "Jump to file" dialog. The
/// controller snapshots lightweight search strings on the main thread, then
/// filters and sorts them off-main so large playlist collections do not stall
/// playback or window interaction while the user types.
final class JumpToFileController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private final class SearchToken {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private struct Candidate {
        let playlistID: UUID
        let entryID: UUID
        let title: String
        let playlistName: String
        let fileName: String
        let order: Int
    }

    private struct Result {
        let playlistID: UUID
        let entryID: UUID
        let title: String
        let playlistName: String
        let order: Int
    }

    private let manager: PlaylistManager
    private let scopedPlaylistID: UUID?
    private let activateResult: (UUID, UUID) -> Void
    private let searchQueue = DispatchQueue(label: "ru.aleksandr.macAmp.jump-search", qos: .userInitiated)
    private var searchWorkItem: DispatchWorkItem?
    private var searchToken: SearchToken?
    private var searchGeneration: UInt = 0
    private var results: [Result] = []

    private let searchField = NSTextField()
    private let allPlaylistsButton = NSButton(checkboxWithTitle: "Use all playlists", target: nil, action: nil)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(title: "Play", target: nil, action: nil)

    var onClose: (() -> Void)?

    init(
        manager: PlaylistManager,
        scopedPlaylistID: UUID?,
        searchesAllPlaylists: Bool,
        activateResult: @escaping (UUID, UUID) -> Void
    ) {
        self.manager = manager
        self.scopedPlaylistID = scopedPlaylistID
        self.activateResult = activateResult

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Jump to File"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        allPlaylistsButton.state = searchesAllPlaylists ? .on : .off
        buildInterface(in: panel)
        scheduleSearch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(relativeTo sourceWindow: NSWindow?) {
        guard let window else { return }
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(searchField)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let sourceWindow {
            let frame = window.frame
            let proposedOrigin = NSPoint(
                x: sourceWindow.frame.midX - frame.width / 2,
                y: sourceWindow.frame.midY - frame.height / 2
            )
            let proposedFrame = NSRect(origin: proposedOrigin, size: frame.size)
            window.setFrame(window.constrainFrameRect(proposedFrame, to: sourceWindow.screen), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        let searchBox = NSBox()
        searchBox.title = "Search for text"
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.placeholderString = "Track title or file name"
        searchBox.contentView?.addSubview(searchField)

        allPlaylistsButton.target = self
        allPlaylistsButton.action = #selector(searchScopeChanged(_:))
        allPlaylistsButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.title = "Track"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection(_:))
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        playButton.target = self
        playButton.action = #selector(activateSelection(_:))
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.keyEquivalent = "\r"
        playButton.isEnabled = false

        [searchBox, allPlaylistsButton, scrollView, statusLabel, cancelButton, playButton].forEach(content.addSubview(_:))

        NSLayoutConstraint.activate([
            searchBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchBox.heightAnchor.constraint(equalToConstant: 62),
            searchField.leadingAnchor.constraint(equalTo: searchBox.contentView!.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchBox.contentView!.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchBox.contentView!.centerYAnchor),

            allPlaylistsButton.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 8),
            allPlaylistsButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: allPlaylistsButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            playButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            playButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])

        // Keep the first Tab predictable: the scope switch immediately
        // follows the query, as it does visually in the dialog.
        searchField.nextKeyView = allPlaylistsButton
        allPlaylistsButton.nextKeyView = tableView
        tableView.nextKeyView = playButton
        playButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = searchField
    }

    func controlTextDidChange(_ notification: Notification) { scheduleSearch() }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -max(1, tableView.rows(in: tableView.visibleRect).length))
        case #selector(NSResponder.pageDown(_:)):
            moveSelection(by: max(1, tableView.rows(in: tableView.visibleRect).length))
        case #selector(NSResponder.insertTab(_:)):
            // `NSTextField` first sends Tab to its field editor. The search
            // field sits in an NSBox content view, whose responder chain can
            // otherwise skip the checkbox despite nextKeyView being set.
            window?.makeFirstResponder(allPlaylistsButton)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(nil)
        default:
            return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : (offset > 0 ? -1 : results.count)
        let row = min(max(0, current + offset), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        playButton.isEnabled = true
    }

    @objc private func searchScopeChanged(_ sender: NSButton) { scheduleSearch() }

    private func scheduleSearch() {
        searchWorkItem?.cancel()
        searchToken?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let token = SearchToken()
        searchToken = token
        results = []
        tableView.reloadData()
        playButton.isEnabled = false
        let searchesAll = allPlaylistsButton.state == .on
        let playlists: [PlaylistModel]
        if searchesAll {
            playlists = manager.playlists
        } else if let scopedPlaylistID, let playlist = manager.playlist(id: scopedPlaylistID) {
            playlists = [playlist]
        } else if let active = manager.activePlaylist {
            playlists = [active]
        } else {
            playlists = []
        }

        let trackCount = playlists.reduce(0) { $0 + $1.entries.count }
        let requiredLength = trackCount < 100 ? 1 : (trackCount < 1_000 ? 2 : 3)
        let tokens = searchField.stringValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        // Whitespace never helps satisfy the threshold. One complete token is
        // enough to begin filtering; all entered tokens must still match.
        guard tokens.contains(where: { $0.count >= requiredLength }) else {
            statusLabel.stringValue = "Enter at least \(requiredLength) non-space character\(requiredLength == 1 ? "" : "s")"
            return
        }

        var order = 0
        var candidates: [Candidate] = []
        candidates.reserveCapacity(trackCount)
        for playlist in playlists {
            for entry in playlist.entries {
                candidates.append(Candidate(
                    playlistID: playlist.id,
                    entryID: entry.id,
                    title: entry.title,
                    playlistName: playlist.name,
                    fileName: entry.url.deletingPathExtension().lastPathComponent,
                    order: order
                ))
                order += 1
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            let locale = Locale.current
            let foldedTokens = tokens.map { $0.folding(options: options, locale: locale) }
            var matches: [Result] = []
            matches.reserveCapacity(min(candidates.count, 256))
            for candidate in candidates {
                guard !token.isCancelled else { return }
                let searchable = "\(candidate.title) \(candidate.fileName)".folding(options: options, locale: locale)
                if foldedTokens.allSatisfy({ searchable.contains($0) }) {
                    matches.append(Result(
                        playlistID: candidate.playlistID,
                        entryID: candidate.entryID,
                        title: candidate.title,
                        playlistName: candidate.playlistName,
                        order: candidate.order
                    ))
                }
            }
            matches.sort {
                let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
                return comparison == .orderedSame ? $0.order < $1.order : comparison == .orderedAscending
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.results = matches
                self.tableView.reloadData()
                if !matches.isEmpty {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                self.playButton.isEnabled = !matches.isEmpty
                self.statusLabel.stringValue = "\(matches.count) result\(matches.count == 1 ? "" : "s")"
            }
        }
        searchWorkItem = workItem
        // A short debounce prevents obsolete full scans for each keystroke.
        searchQueue.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("resultCell")
        let field: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
        }
        let result = results[row]
        field.stringValue = allPlaylistsButton.state == .on
            ? "\(result.title)  —  \(result.playlistName)"
            : result.title
        field.toolTip = field.stringValue
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        playButton.isEnabled = results.indices.contains(tableView.selectedRow)
    }

    @objc private func activateSelection(_ sender: Any?) {
        let row = tableView.selectedRow
        guard results.indices.contains(row) else { return }
        let result = results[row]
        activateResult(result.playlistID, result.entryID)
        close()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        searchWorkItem?.cancel()
        searchToken?.cancel()
        searchGeneration &+= 1
        onClose?()
    }
}
