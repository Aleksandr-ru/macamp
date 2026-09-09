import AppKit
import Combine

/// The visualization window has its own panel type. It follows Info's generic
/// window geometry and skin chrome, but is deliberately independent from the
/// Info window implementation.
final class VisualizationPanelView: NSView {
    private let scaleState: InterfaceScale
    private let focus: WindowFocusState
    private let playback: PlaybackController
    private let skin = WinampSkinStore.shared
    private let onClose: () -> Void
    private let onResize: (CGFloat, CGFloat) -> Void
    private let onDragChanged: () -> Void
    private let onDragEnded: () -> Void
    private let visualizationView: MilkDropMetalView
    private var observation = Set<AnyCancellable>()
    private var closePressed = false

    init(scale: InterfaceScale, focus: WindowFocusState,
         playback: PlaybackController,
         onClose: @escaping () -> Void, onResize: @escaping (CGFloat, CGFloat) -> Void,
         onDragChanged: @escaping () -> Void, onDragEnded: @escaping () -> Void) {
        self.scaleState = scale
        self.focus = focus
        self.playback = playback
        self.onClose = onClose
        self.onResize = onResize
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.visualizationView = MilkDropMetalView(frame: .zero, visualization: playback.visualization)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(visualizationView)
        skin.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }.store(in: &observation)
        focus.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }.store(in: &observation)
        scale.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }.store(in: &observation)
        playback.$isPlaying.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateRenderingState() }
        }.store(in: &observation)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in self?.updateRenderingState() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in self?.updateRenderingState() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let changedWindow = notification.object as? NSWindow,
                  changedWindow === self.window else { return }
            self.updateRenderingState()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderingState()
    }

    private var pixelScale: CGFloat { CGFloat(scaleState.factor) }
    private var closeRect: NSRect {
        let scale = pixelScale
        return NSRect(x: bounds.width - 11 * scale, y: bounds.height - 12 * scale,
                      width: 9 * scale, height: 9 * scale)
    }
    private var resizeRect: NSRect {
        let scale = pixelScale
        return NSRect(x: bounds.width - 20 * scale, y: 0,
                      width: 20 * scale, height: 20 * scale)
    }
    private var titleRect: NSRect {
        let scale = pixelScale
        return NSRect(x: 0, y: bounds.height - 20 * scale,
                      width: max(1, bounds.width - 20 * scale), height: 20 * scale)
    }
    private var contentRect: NSRect {
        let scale = pixelScale
        return NSRect(x: 11 * scale, y: 14 * scale,
                      width: max(1, bounds.width - 19 * scale), height: max(1, bounds.height - 34 * scale))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = pixelScale
        let logical = NSSize(
            width: max(125, Int((bounds.width / scale).rounded(.down))),
            height: max(58, Int((bounds.height / scale).rounded(.down)))
        )
        if let image = skin.genericWindowImage(
            width: Int(logical.width), height: Int(logical.height),
            isActive: focus.isKey, title: "Visualization"
        ) {
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        }
        if closePressed, let pressed = skin.genericCloseButtonImage(pressed: true) {
            pressed.draw(in: closeRect, from: .zero, operation: .copy, fraction: 1)
        }
    }

    override func layout() {
        super.layout()
        visualizationView.frame = contentRect
    }

    /// Visibility is checked at the panel boundary as well as in the window
    /// controller. This covers orderOut, minimization and full occlusion, and
    /// keeps the Metal display link paused when no pixels can be seen.
    func updateRenderingState() {
        let isVisible = window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
            && NSApp.isActive
            && playback.isPlaying
        visualizationView.setRenderingEnabled(isVisible)
        playback.setMilkDropVisualization(enabled: isVisible)
    }

    func playbackDidStartNewTrack() {
        visualizationView.selectPresetForNewTrack()
    }

    override func resetCursorRects() {
        addCursorRect(resizeRect, cursor: skin.cursor(named: "PSIZE.CUR") ?? SkinCursors.resizeNorthwestSoutheast)
        addCursorRect(titleRect, cursor: skin.cursor(named: "TITLEBAR.CUR") ?? .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) { trackClose(); return }
        if resizeRect.contains(point) { trackResize(); return }
        if titleRect.contains(point) { trackDrag(); return }
        if contentRect.contains(point) { visualizationView.selectNextPreset() }
    }

    private func trackClose() {
        closePressed = true
        needsDisplay = true
        displayIfNeeded()
        defer {
            closePressed = false
            needsDisplay = true
        }
        guard let window else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp {
                if closeRect.contains(convert(event.locationInWindow, from: nil)) { onClose() }
                return
            }
        }
    }

    private func trackDrag() {
        guard let window else { return }
        let origin = window.frame.origin
        let start = NSEvent.mouseLocation
        defer { onDragEnded() }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { return }
            let point = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x,
                                          y: origin.y + point.y - start.y))
            onDragChanged()
        }
    }

    private func trackResize() {
        guard let window else { return }
        let startFrame = window.frame
        let start = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { return }
            let point = NSEvent.mouseLocation
            onResize((startFrame.width + point.x - start.x) / pixelScale,
                     (startFrame.height - point.y + start.y) / pixelScale)
        }
    }
}
