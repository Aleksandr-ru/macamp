import AppKit
import AVFoundation
import Combine

/// Info metadata is loaded lazily and off the main thread.  Playlist scans do
/// not decode artwork or long text frames merely because a row is visible.
final class InfoWindowModel: ObservableObject {
    struct Content {
        enum CopyableTag: Int, CaseIterable {
            case artwork, artist, title, album, year, genre, lyrics, comment, url, copyright, filename, folder, fullPath

            var menuTitle: String {
                switch self {
                case .artwork: "Copy Image"
                case .artist: "Copy Artist"
                case .title: "Copy Title"
                case .album: "Copy Album"
                case .year: "Copy Year"
                case .genre: "Copy Genre"
                case .lyrics: "Copy Lyrics"
                case .comment: "Copy Comment"
                case .url: "Copy URL"
                case .copyright: "Copy Copyright"
                case .filename: "Copy Filename"
                case .folder: "Copy Folder"
                case .fullPath: "Copy Full Path"
                }
            }

            func value(in content: Content) -> String? {
                switch self {
                case .artwork: return nil
                case .artist: return content.fieldValue(label: "Artist:")
                case .title: return content.fieldValue(label: "Title:")
                case .album: return content.fieldValue(label: "Album:")
                case .year: return content.fieldValue(label: "Year:")
                case .genre: return content.fieldValue(label: "Genre:")
                case .lyrics: return content.lyrics
                case .comment: return content.comment
                case .url: return content.webURL
                case .copyright: return content.copyright
                case .filename:
                    guard let value = content.url?.lastPathComponent, !value.isEmpty else { return nil }
                    return value
                case .folder:
                    guard let value = content.url?.deletingLastPathComponent().path, !value.isEmpty else { return nil }
                    return value
                case .fullPath:
                    guard let value = content.url?.path, !value.isEmpty else { return nil }
                    return value
                }
            }

            func isAvailable(in content: Content) -> Bool {
                if self == .artwork { return content.artwork != nil }
                guard let value = value(in: content) else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        var url: URL?
        var artwork: NSImage?
        var rating = 0
        var fields: [(label: String, value: String)] = []
        var lyrics: String?
        var comment: String?
        var webURL: String?
        var copyright: String?
        var bitrate: String?
        var duration: String?
        var fileSize: String?
        var technicalInfo: [String] = []

        private func fieldValue(label: String) -> String? {
            fields.first(where: { $0.label == label })?.value
        }
    }

    @Published private(set) var content = Content()

    private var generation = UUID()
    /// AVFoundation can expose common and ID3 metadata in separate passes for
    /// the same local file. Once APIC was decoded, never replace it with an
    /// incomplete later metadata result for that URL.
    private var artworkCache: [URL: NSImage] = [:]
    private let queue = DispatchQueue(label: "ru.aleksandr.macAmp.info", qos: .utility)

    func show(_ url: URL?) { show(url, metadataDelay: 0) }

    /// Metadata/APIC extraction often performs another long sequential read of
    /// a network file. Let the audio renderer establish its buffer first.
    func showForPlayback(_ url: URL?) { show(url, metadataDelay: 2) }

    private func show(_ url: URL?, metadataDelay: TimeInterval) {
        guard content.url != url else { return }
        let token = UUID()
        generation = token
        content = Content(url: url, artwork: url.flatMap { artworkCache[$0] })
        guard let url else { return }

        let load = { [weak self] in self?.loadContent(for: url, token: token) }
        if metadataDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + metadataDelay) { [weak self] in
                guard self?.generation == token else { return }
                load()
            }
        } else {
            load()
        }
    }

    private func loadContent(for url: URL, token: UUID) {
        queue.async { [weak self] in
            let loaded = Self.loadContent(for: url)
            DispatchQueue.main.async {
                guard self?.generation == token else { return }
                guard let self else { return }
                var resolved = loaded
                if let artwork = loaded.artwork {
                    self.artworkCache[url] = artwork
                } else {
                    resolved.artwork = self.artworkCache[url]
                }
                self.content = resolved
            }
        }
    }

    private static func loadContent(for url: URL) -> Content {
        var result = Content(url: url)
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata", "duration"]) { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return result }

        let metadata = asset.commonMetadata + asset.metadata
        func id3(_ frame: String) -> AVMetadataItem? {
            metadata.first { item in
                let key = (item.key as? String)?.uppercased()
                let identifier = item.identifier?.rawValue.uppercased()
                return key == frame || identifier?.hasSuffix("/\(frame)") == true
            }
        }
        func text(_ item: AVMetadataItem?) -> String? {
            guard let value = item?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func firstText(id3Frame: String, commonKey: AVMetadataKey? = nil) -> String? {
            text(id3(id3Frame)) ?? commonKey.flatMap { key in text(metadata.first { $0.commonKey == key }) }
        }
        func tableText(id3Frame: String, commonKey: AVMetadataKey? = nil) -> String? {
            // Table cells are single metadata values. Some taggers leave CR/LF
            // or repeated whitespace inside TIT2, producing a misleading
            // blank visual line before Album.
            firstText(id3Frame: id3Frame, commonKey: commonKey)
                .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        let definitions: [(String, String, AVMetadataKey?)] = [
            ("Artist:", "TPE1", .commonKeyArtist),
            ("Title:", "TIT2", .commonKeyTitle),
            ("Album:", "TALB", .commonKeyAlbumName),
            ("Year:", "TYER", .commonKeyCreationDate),
            ("Genre:", "TCON", .commonKeyType)
        ]
        result.fields = definitions.compactMap { label, frame, commonKey in
            tableText(id3Frame: frame, commonKey: commonKey).map { (label, $0) }
        }
        result.lyrics = firstText(id3Frame: "USLT")
        result.comment = firstText(id3Frame: "COMM", commonKey: .commonKeyDescription)
        result.webURL = text(id3("WXXX"))
        result.copyright = firstText(id3Frame: "TCOP", commonKey: .commonKeyCopyrights)

        if let artworkData = id3("APIC")?.dataValue
            ?? metadata.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue {
            result.artwork = NSImage(data: artworkData)
        }
        if let popularity = id3("POPM") {
            let byte: Int?
            if let data = popularity.dataValue, let separator = data.firstIndex(of: 0), separator + 1 < data.endIndex {
                byte = Int(data[data.index(after: separator)])
            } else {
                byte = popularity.numberValue?.intValue
            }
            if let byte { result.rating = min(5, max(0, Int((Double(byte) * 5 / 255).rounded()))) }
        }

        var technical: [String] = []
        let duration = asset.duration.seconds
        if duration.isFinite, duration > 0 {
            result.duration = formattedDuration(duration)
            technical.append(result.duration!)
        }
        let fileSize = fileSize(for: url)
        let rate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
        if rate > 0 {
            result.bitrate = "\(Int((rate / 1_000).rounded())) kbps"
            technical.insert(result.bitrate!, at: 0)
        } else if let fileSize, duration.isFinite, duration > 0 {
            result.bitrate = "\(Int((Double(fileSize) * 8 / duration / 1_000).rounded())) kbps"
            technical.insert(result.bitrate!, at: 0)
        }
        if let fileSize {
            result.fileSize = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
            technical.append(result.fileSize!)
        }
        result.technicalInfo = technical
        return result
    }

    private static func fileSize(for url: URL) -> Int? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { return size }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// AppKit containment keeps the skinned GEN.BMP frame above the native
/// scrollers, whose background is transparent and which appear only on demand.
final class InfoPanelView: NSView {
    private let model: InfoWindowModel
    private let scaleState: InterfaceScale
    private let fontScale: PlaylistFontScale
    private let focus: WindowFocusState
    private let onClose: () -> Void
    private let onResize: (CGFloat, CGFloat) -> Void
    private let onDragChanged: () -> Void
    private let onDragEnded: () -> Void
    private let skin = WinampSkinStore()
    private let scrollView = NSScrollView()
    private let documentView = InfoDocumentView()
    private var observation = Set<AnyCancellable>()
    private var closePressed = false
    private var isRebuilding = false
    private var laidOutContentSize = NSSize(width: -.greatestFiniteMagnitude, height: -.greatestFiniteMagnitude)

    init(model: InfoWindowModel, scale: InterfaceScale, fontScale: PlaylistFontScale, focus: WindowFocusState,
         onClose: @escaping () -> Void, onResize: @escaping (CGFloat, CGFloat) -> Void,
         onDragChanged: @escaping () -> Void,
         onDragEnded: @escaping () -> Void) {
        self.model = model; self.scaleState = scale; self.fontScale = fontScale; self.focus = focus
        self.onClose = onClose; self.onResize = onResize
        self.onDragChanged = onDragChanged; self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)
        // `@Published` emits from `willSet`. Rebuild on the next main-loop
        // turn, after `model.content` has actually received the new payload;
        // otherwise a completed APIC briefly draws and is immediately
        // replaced by the previous, still-empty content state.
        model.$content.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildContent(resetScrollPosition: true) }
        }.store(in: &observation)
        focus.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }.store(in: &observation)
        scale.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.needsDisplay = true
                self?.needsLayout = true
                self?.laidOutContentSize = NSSize(width: -.greatestFiniteMagnitude, height: -.greatestFiniteMagnitude)
                self?.rebuildContent(resetScrollPosition: true)
            }
        }.store(in: &observation)
        fontScale.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.laidOutContentSize = NSSize(width: -.greatestFiniteMagnitude, height: -.greatestFiniteMagnitude)
                self?.rebuildContent(resetScrollPosition: false)
            }
        }.store(in: &observation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var pixelScale: CGFloat { CGFloat(scaleState.factor) }
    private var textScale: CGFloat { pixelScale * CGFloat(fontScale.factor) }
    private var contentRect: NSRect {
        let scale = pixelScale
        return NSRect(x: 11 * scale, y: 14 * scale,
                      width: max(1, bounds.width - 19 * scale), height: max(1, bounds.height - 34 * scale))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = pixelScale
        let logical = NSSize(width: max(125, Int((bounds.width / scale).rounded(.down))), height: max(58, Int((bounds.height / scale).rounded(.down))))
        if let image = skin.genericWindowImage(width: Int(logical.width), height: Int(logical.height), isActive: focus.isKey) {
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        }
        if closePressed, let pressed = skin.genericCloseButtonImage(pressed: true) {
            pressed.draw(in: closeRect, from: .zero, operation: .copy, fraction: 1)
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = contentRect
        let contentSize = scrollView.contentSize
        // Height is part of the layout decision: a resize can cross the
        // 3:2 threshold without changing the available width.
        if abs(contentSize.width - laidOutContentSize.width) > 0.5
            || abs(contentSize.height - laidOutContentSize.height) > 0.5 {
            rebuildContent()
        }
    }

    private func makeLabel(_ text: String, alignment: NSTextAlignment = .left,
                           lineBreakMode: NSLineBreakMode = .byWordWrapping) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 8 * textScale, weight: .regular)
        label.textColor = skin.playlistColors().normalText
        label.alignment = alignment
        label.maximumNumberOfLines = 0
        label.lineBreakMode = lineBreakMode
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.cell?.lineBreakMode = lineBreakMode
        return label
    }

    private func textHeight(_ text: String, width: CGFloat,
                            lineBreakMode: NSLineBreakMode = .byWordWrapping) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 8 * textScale, weight: .regular)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = lineBreakMode
        container.maximumNumberOfLines = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return max(ceil(font.boundingRectForFont.height), ceil(layoutManager.usedRect(for: container).height))
    }

    private func rebuildContent(resetScrollPosition: Bool = false) {
        guard !isRebuilding, scrollView.bounds.width > 0 else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let copyMenu = makeCopyMenu()
        documentView.menu = copyMenu

        let contentSize = scrollView.contentSize
        let width = max(1, contentSize.width)
        laidOutContentSize = contentSize
        let inset = 8 * pixelScale
        let usableWidth = max(1, width - inset * 2)
        let spacing = 8 * pixelScale
        // A window at least 50% wider than its content area is rendered as
        // two equal columns. This is evaluated for both initial display and
        // every resize in `layout()`.
        let usesTwoColumnLayout = contentSize.width >= contentSize.height * 1.5
        let outerColumnGap = usesTwoColumnLayout ? spacing : 0
        let columnWidth = usesTwoColumnLayout
            ? max(1, (usableWidth - outerColumnGap) * 0.5)
            : usableWidth
        let leftColumnX = inset
        let rightColumnX = leftColumnX + columnWidth + outerColumnGap
        var y = inset
        var leftArtworkHeight: CGFloat = 0
        func addLabel(_ text: String, alignment: NSTextAlignment = .left,
                      lineBreakMode: NSLineBreakMode = .byWordWrapping, height: CGFloat? = nil,
                      x: CGFloat = inset, width: CGFloat = usableWidth,
                      detectsLinks: Bool = false) {
            let rowHeight = height ?? textHeight(text, width: width, lineBreakMode: lineBreakMode)
            if detectsLinks {
                let label = InfoWrappedTextView(
                    text: text,
                    font: NSFont.monospacedSystemFont(ofSize: 8 * textScale, weight: .regular),
                    color: skin.playlistColors().normalText,
                    alignment: alignment,
                    detectsLinks: true
                )
                label.menu = copyMenu
                label.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                documentView.addSubview(label)
            } else {
                let label = makeLabel(text, alignment: alignment, lineBreakMode: lineBreakMode)
                label.menu = copyMenu
                label.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                documentView.addSubview(label)
            }
            y += rowHeight + spacing
        }

        if let artwork = model.content.artwork, let artworkSize = artwork.bitmapSize {
            // Album art must not become larger merely because the Info window
            // was widened.  Its maximum is the drawable content width of the
            // current minimum Info-window frame (rails and inner insets
            // excluded), while a narrower live window still clips it to the
            // available width.
            let minimumWindowArtworkWidth = max(1, CGFloat(skin.genericMinimumWindowWidth(title: "Info") - 35) * pixelScale)
            let imageWidth = min(artworkSize.width * pixelScale, columnWidth, minimumWindowArtworkWidth)
            let imageHeight = imageWidth * artworkSize.height / artworkSize.width
            let image = InfoArtworkView(image: artwork)
            image.menu = copyMenu
            let imageX = usesTwoColumnLayout
                ? leftColumnX + (columnWidth - imageWidth) * 0.5
                : (width - imageWidth) * 0.5
            image.frame = NSRect(x: imageX, y: y, width: imageWidth, height: imageHeight)
            documentView.addSubview(image)
            if usesTwoColumnLayout {
                leftArtworkHeight = imageHeight
            } else {
                y += imageHeight + spacing
            }
        }

        let rating = InfoRatingView(rating: model.content.rating, font: NSFont.monospacedSystemFont(ofSize: 16 * pixelScale, weight: .regular), color: skin.playlistColors().normalText)
        rating.menu = copyMenu
        rating.frame = NSRect(x: usesTwoColumnLayout ? rightColumnX : 0, y: y,
                              width: usesTwoColumnLayout ? columnWidth : width,
                              height: max(18 * pixelScale, rating.intrinsicContentSize.height))
        documentView.addSubview(rating)
        y += rating.frame.height + spacing

        let gap = 8 * pixelScale
        let tableColumnWidth = max(1, (columnWidth - gap) * 0.5)
        let tableFont = NSFont.monospacedSystemFont(ofSize: 8 * textScale, weight: .regular)
        let tableColor = skin.playlistColors().normalText
        for field in model.content.fields {
            let key = InfoWrappedTextView(text: field.label, font: tableFont, color: tableColor, alignment: .right)
            let value = InfoWrappedTextView(text: field.value, font: tableFont, color: tableColor, alignment: .left)
            key.menu = copyMenu
            value.menu = copyMenu
            let rowHeight = max(key.requiredHeight(for: tableColumnWidth), value.requiredHeight(for: tableColumnWidth))
            let tableX = usesTwoColumnLayout ? rightColumnX : inset
            key.frame = NSRect(x: tableX, y: y, width: tableColumnWidth, height: rowHeight)
            value.frame = NSRect(x: tableX + tableColumnWidth + gap, y: y, width: tableColumnWidth, height: rowHeight)
            documentView.addSubview(key); documentView.addSubview(value)
            y += rowHeight + spacing
        }
        let detailX = usesTwoColumnLayout ? rightColumnX : inset
        if let lyrics = model.content.lyrics { addLabel(lyrics, alignment: .center, x: detailX, width: columnWidth) }
        if let comment = model.content.comment { addLabel(comment, alignment: .center, x: detailX, width: columnWidth, detectsLinks: true) }
        if let webURL = model.content.webURL { addLabel(webURL, alignment: .center, x: detailX, width: columnWidth, detectsLinks: true) }
        if let copyright = model.content.copyright { addLabel(copyright, alignment: .center, x: detailX, width: columnWidth) }
        if let fileURL = model.content.url,
           let filename = fileURL.lastPathComponent.nilIfEmpty {
            let filenameView = InfoWrappedTextView(
                text: filename,
                font: NSFont.monospacedSystemFont(ofSize: 8 * textScale, weight: .regular),
                color: skin.playlistColors().normalText,
                alignment: .center,
                onClick: fileURL.isFileURL ? {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } : nil
            )
            filenameView.menu = copyMenu
            let filenameHeight = filenameView.requiredHeight(for: columnWidth)
            filenameView.frame = NSRect(x: detailX, y: y, width: columnWidth, height: filenameHeight)
            documentView.addSubview(filenameView)
            y += filenameHeight + spacing
        }
        if !model.content.technicalInfo.isEmpty {
            addLabel(model.content.technicalInfo.joined(separator: "   "), alignment: .center, x: detailX, width: columnWidth)
        }

        let height = max(scrollView.contentSize.height, y - spacing + inset, leftArtworkHeight + inset * 2)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if resetScrollPosition {
            // Info always begins with APIC (when present).  NSScrollView can
            // otherwise retain an offset from the previous, differently sized
            // document and leave the image immediately outside the viewport.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeCopyMenu() -> NSMenu {
        let menu = NSMenu()
        for tag in InfoWindowModel.Content.CopyableTag.allCases {
            guard tag.isAvailable(in: model.content) else { continue }
            let item = NSMenuItem(title: tag.menuTitle, action: #selector(copyTag(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let summary = NSMenuItem(title: "Copy Summary", action: #selector(copySummaryMenuItem(_:)), keyEquivalent: "c")
        summary.keyEquivalentModifierMask = [.command]
        summary.target = self
        summary.isEnabled = !summaryText.isEmpty
        menu.addItem(summary)
        return menu
    }

    @objc private func copyTag(_ sender: NSMenuItem) {
        guard let tag = InfoWindowModel.Content.CopyableTag(rawValue: sender.tag) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if tag == .artwork, let artwork = model.content.artwork {
            pasteboard.writeObjects([artwork])
            return
        }
        guard let value = tag.value(in: model.content) else { return }
        pasteboard.setString(value, forType: .string)
    }

    /// Available to AppDelegate's local key-event router so ⌘C remains local
    /// to the Info panel instead of becoming a global application shortcut.
    func copySummary() {
        guard !summaryText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText, forType: .string)
    }

    @objc private func copySummaryMenuItem(_ sender: NSMenuItem) {
        copySummary()
    }

    private var summaryText: String {
        let content = model.content
        var lines = content.fields.compactMap { field -> String? in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return "\(field.label.dropLast()): \(value)"
        }
        func append(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            lines.append("\(label): \(value)")
        }
        append("URL", content.webURL)
        append("Copyright", content.copyright)
        append("Filename", content.url?.lastPathComponent)
        append("Folder", content.url?.deletingLastPathComponent().path)
        append("Bitrate", content.bitrate)
        append("Duration", content.duration)
        append("Size", content.fileSize)
        return lines.joined(separator: "\n")
    }

    private var closeRect: NSRect { let scale = pixelScale; return NSRect(x: bounds.width - 11 * scale, y: bounds.height - 12 * scale, width: 9 * scale, height: 9 * scale) }
    private var resizeRect: NSRect { let scale = pixelScale; return NSRect(x: bounds.width - 20 * scale, y: 0, width: 20 * scale, height: 20 * scale) }
    private var titleRect: NSRect { let scale = pixelScale; return NSRect(x: 0, y: bounds.height - 20 * scale, width: max(1, bounds.width - 20 * scale), height: 20 * scale) }

    override func resetCursorRects() { addCursorRect(resizeRect, cursor: skin.cursor(named: "PSIZE.CUR") ?? SkinCursors.resizeNorthwestSoutheast); addCursorRect(titleRect, cursor: skin.cursor(named: "TITLEBAR.CUR") ?? .arrow) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) { trackClose(); return }
        if resizeRect.contains(point) { trackResize(); return }
        if titleRect.contains(point) { trackDrag() }
    }
    private func trackClose() {
        closePressed = true; needsDisplay = true; displayIfNeeded()
        defer { closePressed = false; needsDisplay = true }
        guard let window else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { if closeRect.contains(convert(event.locationInWindow, from: nil)) { onClose() }; return }
        }
    }
    private func trackDrag() {
        guard let window else { return }; let origin = window.frame.origin; let start = NSEvent.mouseLocation
        defer { onDragEnded() }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { return }
            let point = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            onDragChanged()
        }
    }
    private func trackResize() {
        guard let window else { return }; let startFrame = window.frame; let start = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { return }
            let point = NSEvent.mouseLocation; let scale = pixelScale
            onResize((startFrame.width + point.x - start.x) / scale, (startFrame.height - point.y + start.y) / scale)
        }
    }

    /// Cursor-update events can be delivered to the enclosing scroll view
    /// when this non-activating panel is not key. AppDelegate forwards those
    /// events here so interactive text remains discoverable in every state.
    func updateHoverCursor(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        guard contentRect.contains(point) else { return }
        let documentPoint = documentView.convert(point, from: self)
        if let target = documentView.hitTest(documentPoint) as? InfoCursorTarget {
            target.updateCursor(atWindowPoint: windowPoint)
        } else {
            NSCursor.arrow.set()
        }
    }
}

private protocol InfoCursorTarget: AnyObject {
    func updateCursor(atWindowPoint: NSPoint)
}

private final class InfoDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSImage {
    /// APIC carries bitmap dimensions; using the representation avoids a zero
    /// logical NSImage size from an asynchronously decoded image.
    var bitmapSize: NSSize? {
        if let representation = bestRepresentation(for: .zero, context: nil, hints: nil),
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

private final class InfoArtworkView: NSView {
    private let image: NSImage

    init(image: NSImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// NSTextField can apply an internal line limit while drawing a wrapping
/// label. The filename needs an unlimited TextKit layout, so its measurement
/// and rendering intentionally share this single stack. Word wrapping keeps
/// normal names readable; TextKit falls back to a character break only when a
/// single word is wider than the available line.
private final class InfoWrappedTextView: NSView, InfoCursorTarget {
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private let font: NSFont
    private let links: [(range: NSRange, url: URL)]
    private let onClick: (() -> Void)?
    private var cursorTrackingArea: NSTrackingArea?

    init(
        text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        detectsLinks: Bool = false,
        onClick: (() -> Void)? = nil
    ) {
        self.font = font
        self.onClick = onClick
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributedText = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        if detectsLinks,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            links = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let url = match.url else { return nil }
                // Keep the skin's normal text colour. The `.link` attribute
                // lets AppKit substitute the system link tint, while our own
                // hit testing already supplies the interactive behaviour.
                attributedText.addAttributes([
                    .foregroundColor: color,
                    .underlineColor: color,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.range)
                return (match.range, url)
            }
        } else {
            links = []
        }
        if onClick != nil {
            attributedText.addAttributes([
                .foregroundColor: color,
                .underlineColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: NSRange(text.startIndex..., in: text))
        }
        storage = NSTextStorage(attributedString: attributedText)
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.maximumNumberOfLines = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return max(ceil(font.boundingRectForFont.height), ceil(layoutManager.usedRect(for: container).height))
    }

    override func draw(_ dirtyRect: NSRect) {
        container.containerSize = bounds.size
        layoutManager.ensureLayout(for: container)
        layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: container), at: .zero)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
        guard !links.isEmpty else { return }
        container.containerSize = bounds.size
        layoutManager.ensureLayout(for: container)
        for link in links {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { [weak self] rect, _ in
                self?.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        cursorTrackingArea = nil
        guard onClick != nil || !links.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(atWindowPoint: event.locationInWindow)
    }

    func updateCursor(atWindowPoint windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        if onClick != nil || link(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp else { return }
        if let url = link(at: convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(url)
        } else {
            onClick?()
        }
    }

    private func link(at point: NSPoint) -> URL? {
        container.containerSize = bounds.size
        layoutManager.ensureLayout(for: container)
        let characterIndex = layoutManager.characterIndex(
            for: point,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return links.first(where: { NSLocationInRange(characterIndex, $0.range) })?.url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class InfoRatingView: NSView {
    private let rating: Int
    private let font: NSFont
    private let color: NSColor

    init(rating: Int, font: NSFont, color: NSColor) {
        self.rating = min(5, max(0, rating)); self.font = font; self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        let size = ("★" as NSString).size(withAttributes: [.font: font])
        return NSSize(width: size.width * 5, height: max(size.height, font.boundingRectForFont.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        let star = "★" as NSString
        let starWidth = star.size(withAttributes: [.font: font]).width
        let start = (bounds.width - starWidth * 5) * 0.5
        for index in 0..<5 {
            star.draw(at: NSPoint(x: start + CGFloat(index) * starWidth, y: 0), withAttributes: [.font: font, .foregroundColor: color.withAlphaComponent(index < rating ? 1 : 0.2)])
        }
    }
}
