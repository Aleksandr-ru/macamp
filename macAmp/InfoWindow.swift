import AppKit
import AVFoundation
import Combine

/// Info metadata is loaded lazily and off the main thread.  Playlist scans do
/// not decode artwork or long text frames merely because a row is visible.
final class InfoWindowModel: ObservableObject {
    struct Content {
        var url: URL?
        var artwork: NSImage?
        var rating = 0
        var fields: [(label: String, value: String)] = []
        var lyrics: String?
        var comment: String?
        var webURL: String?
        var copyright: String?
        var technicalInfo: [String] = []
    }

    @Published private(set) var content = Content()

    private var generation = UUID()
    /// AVFoundation can expose common and ID3 metadata in separate passes for
    /// the same local file. Once APIC was decoded, never replace it with an
    /// incomplete later metadata result for that URL.
    private var artworkCache: [URL: NSImage] = [:]
    private let queue = DispatchQueue(label: "ru.aleksandr.MacAmp.info", qos: .utility)

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
        if duration.isFinite, duration > 0 { technical.append(formattedDuration(duration)) }
        let fileSize = fileSize(for: url)
        let rate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
        if rate > 0 {
            technical.insert("\(Int((rate / 1_000).rounded())) kbps", at: 0)
        } else if let fileSize, duration.isFinite, duration > 0 {
            technical.insert("\(Int((Double(fileSize) * 8 / duration / 1_000).rounded())) kbps", at: 0)
        }
        if let fileSize { technical.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)) }
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
    private var laidOutContentWidth: CGFloat = -.greatestFiniteMagnitude

    init(model: InfoWindowModel, scale: InterfaceScale, focus: WindowFocusState,
         onClose: @escaping () -> Void, onResize: @escaping (CGFloat, CGFloat) -> Void,
         onDragChanged: @escaping () -> Void,
         onDragEnded: @escaping () -> Void) {
        self.model = model; self.scaleState = scale; self.focus = focus
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
                self?.laidOutContentWidth = -.greatestFiniteMagnitude
                self?.rebuildContent(resetScrollPosition: true)
            }
        }.store(in: &observation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var pixelScale: CGFloat { CGFloat(scaleState.factor) }
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
        let width = scrollView.contentSize.width
        if abs(width - laidOutContentWidth) > 0.5 { rebuildContent() }
    }

    private func makeLabel(_ text: String, alignment: NSTextAlignment = .left,
                           lineBreakMode: NSLineBreakMode = .byWordWrapping) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 8 * pixelScale, weight: .regular)
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
        let font = NSFont.monospacedSystemFont(ofSize: 8 * pixelScale, weight: .regular)
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

        let width = max(1, scrollView.contentSize.width)
        laidOutContentWidth = width
        let inset = 8 * pixelScale
        let usableWidth = max(1, width - inset * 2)
        let spacing = 8 * pixelScale
        var y = inset
        func addLabel(_ text: String, alignment: NSTextAlignment = .left,
                      lineBreakMode: NSLineBreakMode = .byWordWrapping, height: CGFloat? = nil) {
            let label = makeLabel(text, alignment: alignment, lineBreakMode: lineBreakMode)
            let rowHeight = height ?? textHeight(text, width: usableWidth, lineBreakMode: lineBreakMode)
            label.frame = NSRect(x: inset, y: y, width: usableWidth, height: rowHeight)
            documentView.addSubview(label)
            y += rowHeight + spacing
        }

        if let artwork = model.content.artwork, let artworkSize = artwork.bitmapSize {
            // Album art must not become larger merely because the Info window
            // was widened.  Its maximum is the drawable content width of the
            // current minimum Info-window frame (rails and inner insets
            // excluded), while a narrower live window still clips it to the
            // available width.
            let minimumWindowArtworkWidth = max(1, CGFloat(skin.genericMinimumWindowWidth(title: "Info") - 35) * pixelScale)
            let imageWidth = min(artworkSize.width * pixelScale, usableWidth, minimumWindowArtworkWidth)
            let imageHeight = imageWidth * artworkSize.height / artworkSize.width
            let image = InfoArtworkView(image: artwork)
            image.frame = NSRect(x: (width - imageWidth) * 0.5, y: y, width: imageWidth, height: imageHeight)
            documentView.addSubview(image)
            y += imageHeight + spacing
        }

        let rating = InfoRatingView(rating: model.content.rating, font: NSFont.monospacedSystemFont(ofSize: 16 * pixelScale, weight: .regular), color: skin.playlistColors().normalText)
        rating.frame = NSRect(x: 0, y: y, width: width, height: max(18 * pixelScale, rating.intrinsicContentSize.height))
        documentView.addSubview(rating)
        y += rating.frame.height + spacing

        let gap = 8 * pixelScale
        let columnWidth = max(1, (usableWidth - gap) * 0.5)
        let tableFont = NSFont.monospacedSystemFont(ofSize: 8 * pixelScale, weight: .regular)
        let tableColor = skin.playlistColors().normalText
        for field in model.content.fields {
            let key = InfoWrappedTextView(text: field.label, font: tableFont, color: tableColor, alignment: .right)
            let value = InfoWrappedTextView(text: field.value, font: tableFont, color: tableColor, alignment: .left)
            let rowHeight = max(key.requiredHeight(for: columnWidth), value.requiredHeight(for: columnWidth))
            key.frame = NSRect(x: inset, y: y, width: columnWidth, height: rowHeight)
            value.frame = NSRect(x: inset + columnWidth + gap, y: y, width: columnWidth, height: rowHeight)
            documentView.addSubview(key); documentView.addSubview(value)
            y += rowHeight + spacing
        }
        if let lyrics = model.content.lyrics { addLabel(lyrics, alignment: .center) }
        if let comment = model.content.comment { addLabel(comment, alignment: .center) }
        if let webURL = model.content.webURL { addLabel(webURL, alignment: .center) }
        if let copyright = model.content.copyright { addLabel(copyright, alignment: .center) }
        if let filename = model.content.url?.lastPathComponent, !filename.isEmpty {
            let filenameView = InfoWrappedTextView(
                text: filename,
                font: NSFont.monospacedSystemFont(ofSize: 8 * pixelScale, weight: .regular),
                color: skin.playlistColors().normalText,
                alignment: .center
            )
            let filenameHeight = filenameView.requiredHeight(for: usableWidth)
            filenameView.frame = NSRect(x: inset, y: y, width: usableWidth, height: filenameHeight)
            documentView.addSubview(filenameView)
            y += filenameHeight + spacing
        }
        if !model.content.technicalInfo.isEmpty {
            addLabel(model.content.technicalInfo.joined(separator: "   "), alignment: .center)
        }

        let height = max(scrollView.contentSize.height, y - spacing + inset)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if resetScrollPosition {
            // Info always begins with APIC (when present).  NSScrollView can
            // otherwise retain an offset from the previous, differently sized
            // document and leave the image immediately outside the viewport.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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
private final class InfoWrappedTextView: NSView {
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private let font: NSFont

    init(text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        self.font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
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
