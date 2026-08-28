//
//  AppDelegate.swift
//  MacAmp
//
//  Created by Rebel on 27.03.2020.
//  Copyright © 2020 Aleksandr.ru. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine
import UniformTypeIdentifiers
import MediaPlayer

/// AppKit has no built-in equivalents of the CSS `move` and
/// `resize-northwest-southeast` cursors on all supported macOS versions.
/// Render those two classic cursor shapes consistently for every skin window.
enum SkinCursors {
    static let move: NSCursor = makeCursor(symbol: "arrow.up.and.down.and.arrow.left.and.right", pointSize: 15, outlined: true)
    /// The system's "busy but clickable" cursor is the arrow with the small
    /// spinning indicator used by macOS while background work continues.
    private static let busyFrames = systemBusyButClickableFrames()
    static let wait: NSCursor = busyFrames[busyFrames.index(busyFrames.startIndex, offsetBy: min(7, max(0, busyFrames.count - 1)))]
    private static var busyCursorUsers = 0
    static let resizeNorthwestSoutheast: NSCursor = {
        // macOS 15+ supplies the native, accessibility-aware outlined diagonal
        // resize cursor. Earlier macOS versions retain the visual fallback.
        if #available(macOS 15.0, *) {
            return NSCursor.__frameResize(from: .bottomRight, in: .all)
        }
        return makeCursor(symbol: "arrow.up.left.and.arrow.down.right", pointSize: 16, outlined: true)
    }()

    private static func makeCursor(symbol: String, pointSize: CGFloat, outlined: Bool) -> NSCursor {
        let size = NSSize(width: 20, height: 20)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        let rectangle = NSRect(origin: .zero, size: size)
        if outlined,
           let outline = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize + 2, weight: .bold)) {
            NSColor.white.set()
            // Draw an explicit one-pixel halo. It remains visible even when a
            // symbol's internal metrics do not scale its outer stroke evenly.
            for dx in [-1.0, 0.0, 1.0] {
                for dy in [-1.0, 0.0, 1.0] where dx != 0 || dy != 0 {
                    outline.draw(in: rectangle.offsetBy(dx: dx, dy: dy))
                }
            }
            outline.draw(in: rectangle)
        }
        if let inner = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold)) {
            NSColor.black.set()
            inner.draw(in: rectangle)
        }
        canvas.unlockFocus()
        return NSCursor(image: canvas, hotSpot: NSPoint(x: 10, y: 10))
    }

    static func beginBusyCursor() {
        busyCursorUsers += 1
        guard busyCursorUsers == 1 else { return }
        wait.push()
        wait.set()
    }

    static func endBusyCursor() {
        guard busyCursorUsers > 0 else { return }
        busyCursorUsers -= 1
        guard busyCursorUsers == 0 else { return }
        NSCursor.pop()
    }

    private static func systemBusyButClickableFrames() -> [NSCursor] {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors/busybutclickable/cursor.pdf"
        guard let strip = NSImage(contentsOf: URL(fileURLWithPath: path)),
              let source = strip.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [.arrow]
        }
        let frameHeight = 40
        guard source.width >= 28, source.height >= frameHeight else { return [.arrow] }
        return stride(from: 0, to: source.height, by: frameHeight).compactMap { y in
            guard let frame = source.cropping(to: CGRect(x: 0, y: y, width: 28, height: frameHeight)) else { return nil }
            // The source is a 2× cursor frame.  Keep a little extra point
            // space so the attached system busy badge is never clipped.
            return NSCursor(image: NSImage(cgImage: frame, size: NSSize(width: 18, height: 26)), hotSpot: NSPoint(x: 3.25, y: 3.25))
        }
    }
}

private final class PlayerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        // Keep the original mouse-down/up pair intact: SwiftUI drag gestures
        // depend on receiving both from the same event sequence. When a panel
        // is activated by this click, force a display after dispatching its
        // mouse-down so the skin can show the pressed frame immediately.
        let activatesPanel = event.type == .leftMouseDown && !isKeyWindow
        if activatesPanel {
            AppDelegate.shared?.bringPlayerWindowsToFront(active: self)
        }
        super.sendEvent(event)
        if activatesPanel {
            contentView?.layoutSubtreeIfNeeded()
            contentView?.displayIfNeeded()
        }
    }
}

final class WindowFocusState: ObservableObject {
    @Published var isKey = true
}

final class WindowShadeState: ObservableObject {
    @Published var isEnabled = false
}

final class EqualizerWindowState: ObservableObject {
    @Published var isVisible = false
}

final class PlaylistWindowState: ObservableObject {
    @Published var isVisible = false
}

final class InfoWindowState: ObservableObject {
    @Published var isVisible = false
}

final class EqualizerFocusState: ObservableObject { @Published var isKey = false }
final class EqualizerShadeState: ObservableObject { @Published var isEnabled = false }
final class PlaylistFocusState: ObservableObject { @Published var isKey = false }
final class PlaylistShadeState: ObservableObject { @Published var isEnabled = false }
final class PlaylistLayout: ObservableObject {
    @Published var width: CGFloat = 275
    @Published var height: CGFloat = 232
}

/// Per-editor presentation state.  It deliberately lives beside the window,
/// rather than in PlaylistModel, so model persistence remains AppKit-free.
private final class PlaylistWindowContext {
    let model: PlaylistModel
    let focus = PlaylistFocusState()
    let shade = PlaylistShadeState()
    let layout = PlaylistLayout()
    init(_ model: PlaylistModel, interfaceScale: CGFloat) {
        self.model = model
        shade.isEnabled = model.isWindowShaded
        if let frame = model.windowFrame {
            layout.width = max(275, model.unshadedWindowWidth ?? frame.width / interfaceScale)
            layout.height = max(116, model.unshadedWindowHeight ?? frame.height / interfaceScale)
        }
    }
}

/// Header controls use AppKit mouse tracking so the skin's pressed frame is
/// always shown and the action is delivered even when the panel was inactive.
struct SkinTitleControlHotspot: NSViewRepresentable {
    let normalImage: NSImage?
    let pressedImage: NSImage?
    let action: () -> Void

    func makeNSView(context: Context) -> SkinTitleControlNSView {
        let view = SkinTitleControlNSView()
        view.normalImage = normalImage
        view.pressedImage = pressedImage
        view.action = action
        return view
    }

    func updateNSView(_ nsView: SkinTitleControlNSView, context: Context) {
        nsView.normalImage = normalImage
        nsView.pressedImage = pressedImage
        nsView.action = action
        nsView.needsDisplay = true
    }
}

final class SkinTitleControlNSView: NSView {
    var normalImage: NSImage?
    var pressedImage: NSImage?
    var action: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        (isPressed ? pressedImage : normalImage)?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        displayIfNeeded()
        var invoke = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                invoke = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        isPressed = false
        if invoke { action?() }
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static weak var shared: AppDelegate?
    var currentInterfaceScale: Double { interfaceScale.factor }
    var window: NSWindow!
    private let interfaceScale = InterfaceScale()
    private let timeDisplayPreference = TimeDisplayPreference()
    private let windowFocus = WindowFocusState()
    private let windowShade = WindowShadeState()
    private let equalizerState = EqualizerWindowState()
    private let playlistState = PlaylistWindowState()
    private let infoState = InfoWindowState()
    private let equalizerFocus = EqualizerFocusState()
    private let equalizerShade = EqualizerShadeState()
    private let playlistFocus = PlaylistFocusState()
    private let playlistShade = PlaylistShadeState()
    private let playlistLayout = PlaylistLayout()
    private let playback = PlaybackController()
    private let playlistManager = PlaylistManager()
    private var preferencesWindow: NSWindow?
    private var equalizerWindow: NSWindow?
    private var playlistWindow: NSWindow?
    private var infoWindow: NSWindow?
    private let infoFocus = WindowFocusState()
    private let infoModel = InfoWindowModel()
    private var infoTargetURL: URL?
    private var infoLogicalSize = NSSize(width: 250, height: 300)
    private var playlistWindows: [UUID: NSWindow] = [:]
    private var playlistWindowContexts: [UUID: PlaylistWindowContext] = [:]
    private weak var lastActivePlaylistWindow: NSWindow?
    private var isEqualizerDocked = true
    private var equalizerDockOffset = NSPoint(x: 0, y: -116)
    private var equalizerWasMoved = false
    private var isRepositioningEqualizer = false
    private var isPlaylistDocked = true
    private var playlistDockOffset = NSPoint(x: 275, y: -116)
    private var lastAppliedInterfaceScale: CGFloat = 1
    private var playlistWasMoved = false
    private var isRepositioningPlaylist = false
    // Windows that were physically connected to the main player when its
    // title-bar drag began.  This is deliberately a group rather than a
    // single "docked playlist": every Playlist Editor is an equal window and
    // can be connected through another editor.
    private var mainDragGroupWindows: [NSWindow] = []
    private var mainDragWindowOffsets: [ObjectIdentifier: NSPoint] = [:]
    private var mainDragLastOrigin: NSPoint?
    private var scaleObserver: Any?
    private var focusObservers: [Any] = []
    private var isExplicitTerminationRequested = false
    private var persistenceCancellables = Set<AnyCancellable>()
    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var lastNowPlayingUpdate = Date.distantPast
    private var lastNowPlayingTitle = ""
    private var lastNowPlayingIsPlaying = false
    private var lastDirectMediaKeyEvent = Date.distantPast
    private var mediaKeyMonitor: Any?
    private var keyboardShortcutMonitor: Any?
    private var controlsMenu: NSMenu?
    private let persistentStateKey = "MacAmp.applicationPersistentState.v1"

    private struct PersistentState: Codable {
        var volume: Double
        var balance: Double
        var shuffle: Bool
        var repeatTrack: Bool
        var mainShade: Bool
        var equalizerVisible: Bool
        var equalizerShade: Bool
        var playlistVisible: Bool
        var playlistShade: Bool
        var playlistWidth: Double
        var playlistHeight: Double
        var mainOriginX: Double
        var mainOriginY: Double
        var equalizerOriginX: Double?
        var equalizerOriginY: Double?
        var playlistOriginX: Double?
        var playlistOriginY: Double?
        // Optional for compatibility with state snapshots created before the
        // Info window became persistent.
        var infoVisible: Bool?
        var infoWidth: Double?
        var infoHeight: Double?
        var infoOriginX: Double?
        var infoOriginY: Double?
        var equalizerDocked: Bool
        var playlistDocked: Bool
        var equalizer: EqualizerPersistentState
    }


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self
        restorePersistentState()
        playback.onTrackFinished = { [weak self] in self?.advancePlaylistAfterTrackFinished() }
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView(
            playback: playback,
            interfaceScale: interfaceScale,
            timeDisplayPreference: timeDisplayPreference,
            windowFocus: windowFocus,
            windowShade: windowShade,
            equalizerState: equalizerState,
            playlistState: playlistState,
            infoState: infoState
        )

        // Create the window and set the content view. 
        window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 275, height: 116),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.center()
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        applyInterfaceScale()
        if hasRestoredMainOrigin { window.setFrameOrigin(restoredMainOrigin) }
        window.makeKeyAndOrderFront(nil)
        focusObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                   object: window,
                                                   queue: .main) { [weak self] _ in
                self?.windowFocus.isKey = true
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                   object: window,
                                                   queue: .main) { [weak self] _ in
                self?.windowFocus.isKey = false
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification,
                                                   object: window,
                                                   queue: .main) { [weak self] _ in
                self?.refreshInterfaceVisibility()
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                                   object: window,
                                                   queue: .main) { [weak self] _ in
                self?.refreshInterfaceVisibility()
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                   object: NSApp,
                                                   queue: .main) { [weak self] _ in
                self?.refreshInterfaceVisibility()
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: NSApp,
                                                   queue: .main) { [weak self] _ in
                self?.raiseVisiblePlayerWindows()
                self?.refreshInterfaceVisibility()
            }
        ]
        refreshInterfaceVisibility()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: window,
                                               queue: .main) { [weak self] _ in
            self?.moveDockedEqualizer()
            self?.moveDockedPlaylist()
            self?.schedulePersistentStateSave()
        }
        connectFileMenu()
        connectPreferencesMenu()
        connectQuitMenu()
        connectControlsMenu()
        connectWindowMenu()
        installPlaybackShortcuts()
        installMediaKeyHandling()
        observeNowPlayingState()

        scaleObserver = NotificationCenter.default.addObserver(forName: .macAmpInterfaceScaleDidChange,
                                                                object: interfaceScale,
                                                                queue: .main) { [weak self] _ in
            self?.applyInterfaceScale()
        }

        restoreAuxiliaryWindows()
        observePersistentState()
        // Write the current schema immediately, including on a first launch
        // after a persistence-format update.
        savePersistentState()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if let mediaKeyMonitor { NSEvent.removeMonitor(mediaKeyMonitor) }
        if let keyboardShortcutMonitor { NSEvent.removeMonitor(keyboardShortcutMonitor) }
        pendingPersistenceWorkItem?.cancel()
        playlistManager.cancelFolderScans()
        playlistManager.flushSave()
        savePersistentState()
        playback.stop()
    }

    private func installPlaybackShortcuts() {
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalPlaybackShortcut(event) ? nil : event
        }
    }

    /// Local monitoring is the only AppKit path that consistently carries the
    /// key event's source panel for non-activating player windows.
    private func handleLocalPlaybackShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Arrow keys may carry AppKit's `.function` or `.numericPad` flag.
        // Those identify the hardware key; only real shortcut modifiers
        // should bypass context-sensitive Winamp bindings.
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard modifiers.intersection(shortcutModifiers).isEmpty else { return false }

        let sourceWindowNumber = event.window?.windowNumber
        let playlistID = sourceWindowNumber.flatMap { number in
            playlistWindows.first(where: { $0.value.windowNumber == number })?.key
        }

        // Playlist navigation intentionally takes precedence over the global
        // transport mapping. In classic Winamp the same arrows have different
        // meanings depending on the focused window.
        if let playlistID, let playlist = playlistManager.playlist(id: playlistID) {
            switch event.keyCode {
            case 126: // ↑ — Previous playlist row
                movePlaylistSelection(in: playlist, by: -1)
            case 125: // ↓ — Next playlist row
                movePlaylistSelection(in: playlist, by: 1)
            default:
                break
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                return true
            }
        }

        switch event.keyCode {
        case 6: // physical Z key — Previous
            playlistTransportAction(0)
        case 7: // physical X key — Play
            playFromActivePlaylist()
        case 8: // physical C key — Pause
            pausePlayback()
        case 9: // physical V key — Stop
            stopPlayback()
        case 11: // physical B key — Next
            playlistTransportAction(4)
        case 1: // physical S key — Shuffle
            playback.isShuffleEnabled.toggle()
            updateControlsMenuState()
        case 15: // physical R key — Repeat
            playback.isRepeatEnabled.toggle()
            updateControlsMenuState()
        case 123: // ← — Back 5 seconds
            seekPlayback(to: max(0, playback.position - 5))
        case 124: // → — Forward 5 seconds
            seekPlayback(to: min(playback.duration, playback.position + 5))
        case 125: // ↓ — Volume down
            playback.volume = max(0, playback.volume - 0.05)
        case 126: // ↑ — Volume up
            playback.volume = min(1, playback.volume + 0.05)
        default: return false
        }
        return true
    }

    private func movePlaylistSelection(in playlist: PlaylistModel, by offset: Int) {
        guard let entry = playlistManager.moveSelection(in: playlist, by: offset) else { return }
        selectInfoTarget(entry)
    }

    private func installMediaKeyHandling() {
        mediaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, self.handleMediaKeyEvent(event) else { return event }
            return nil
        }

        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.performRemoteMediaCommand(.previous) ?? .commandFailed }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.performRemoteMediaCommand(.next) ?? .commandFailed }
        commands.playCommand.addTarget { [weak self] _ in self?.performRemoteMediaCommand(.play) ?? .commandFailed }
        commands.pauseCommand.addTarget { [weak self] _ in self?.performRemoteMediaCommand(.pause) ?? .commandFailed }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.performRemoteMediaCommand(.toggle) ?? .commandFailed }
    }

    private func observeNowPlayingState() {
        playback.objectWillChange
            .sink { [weak self] _ in
                // ObservableObject publishes before assigning its new value.
                DispatchQueue.main.async { self?.updateNowPlayingInfo() }
            }
            .store(in: &persistenceCancellables)
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        let titleOrStateChanged = playback.title != lastNowPlayingTitle || playback.isPlaying != lastNowPlayingIsPlaying
        guard titleOrStateChanged || Date().timeIntervalSince(lastNowPlayingUpdate) >= 1 else { return }
        lastNowPlayingUpdate = Date()
        lastNowPlayingTitle = playback.title
        lastNowPlayingIsPlaying = playback.isPlaying
        // Keep an inactive session published as well.  If we clear it while
        // no track is loaded, macOS falls back to launching Music for the
        // first hardware Play key press instead of routing that press here.
        let hasTrack = playback.duration > 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: hasTrack ? playback.title : "MacAmp",
            MPMediaItemPropertyPlaybackDuration: hasTrack ? playback.duration : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: hasTrack ? playback.position : 0,
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying ? 1.0 : 0.0
        ]
    }

    private enum MediaCommand { case previous, play, pause, toggle, next }

    private func performRemoteMediaCommand(_ command: MediaCommand) -> MPRemoteCommandHandlerStatus {
        // The same hardware key can reach the foreground app first as an
        // NSEvent and immediately afterwards through Media Player.  The
        // NSEvent path is authoritative while the player is foreground; drop
        // only that duplicate remote delivery, keeping Control Center and
        // background controls functional.
        guard Date().timeIntervalSince(lastDirectMediaKeyEvent) > 0.35 else { return .success }
        return performMediaCommand(command)
    }

    private func performMediaCommand(_ command: MediaCommand) -> MPRemoteCommandHandlerStatus {
        switch command {
        case .previous: playlistTransportAction(0)
        case .next: playlistTransportAction(4)
        case .play:
            // A hardware Play key can be delivered once as an NSEvent and
            // once through MPRemoteCommandCenter.  The second delivery must
            // never restart the current track.
            guard !playback.isPlaying else { return .success }
            playFromActivePlaylist()
        case .pause: pausePlayback()
        case .toggle:
            if playback.isPlaying { pausePlayback() } else { playFromActivePlaylist() }
        }
        // Publish the new state in the same run-loop turn as the hardware
        // command.  The ObservableObject notification arrives before its
        // property assignment, so its deferred update is not sufficient for
        // media-session arbitration on the first press.
        DispatchQueue.main.async { [weak self] in self?.updateNowPlayingInfo() }
        return .success
    }

    private func handleMediaKeyEvent(_ event: NSEvent) -> Bool {
        // NX_SYSDEFINED subtype 8 carries the media-key identifier in the high
        // word of data1. Accept only key-down events; key-up is delivered too.
        guard event.subtype.rawValue == 8 else { return false }
        let key = Int((event.data1 & 0xFFFF_0000) >> 16)
        let state = Int((event.data1 & 0x0000_FF00) >> 8)
        // Consume both down and up events. Letting the up event propagate can
        // still make macOS hand the same media-key press to Music/another
        // default media app after MacAmp has already handled it.
        switch key {
        case 16:
            if state == 0xA {
                lastDirectMediaKeyEvent = Date()
                _ = performMediaCommand(.toggle)
            }   // NX_KEYTYPE_PLAY
        case 17:
            if state == 0xA {
                lastDirectMediaKeyEvent = Date()
                _ = performMediaCommand(.next)
            }     // NX_KEYTYPE_NEXT
        case 18:
            if state == 0xA {
                lastDirectMediaKeyEvent = Date()
                _ = performMediaCommand(.previous)
            } // NX_KEYTYPE_PREVIOUS
        default: return false
        }
        return true
    }

    private var restoredMainOrigin = NSPoint(x: 0, y: 0)
    private var hasRestoredMainOrigin = false
    private var restoredEqualizerOrigin: NSPoint?
    private var restoredPlaylistOrigin: NSPoint?
    private var shouldRestoreInfoWindow = false
    private var restoredInfoOrigin: NSPoint?

    private func restorePersistentState() {
        guard let data = UserDefaults.standard.data(forKey: persistentStateKey),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data) else { return }
        playback.volume = min(1, max(0, state.volume))
        playback.balance = min(1, max(-1, state.balance))
        // Shuffle/repeat are restored by PlaybackController from their own
        // small preferences, independently of this layout snapshot.
        windowShade.isEnabled = state.mainShade
        equalizerState.isVisible = state.equalizerVisible
        equalizerShade.isEnabled = state.equalizerShade
        playlistState.isVisible = state.playlistVisible
        playlistShade.isEnabled = state.playlistShade
        infoState.isVisible = state.infoVisible ?? false
        playlistLayout.width = max(275, CGFloat(state.playlistWidth))
        playlistLayout.height = max(116, CGFloat(state.playlistHeight))
        restoredMainOrigin = NSPoint(x: state.mainOriginX, y: state.mainOriginY)
        hasRestoredMainOrigin = true
        if let x = state.equalizerOriginX, let y = state.equalizerOriginY { restoredEqualizerOrigin = NSPoint(x: x, y: y) }
        if let x = state.playlistOriginX, let y = state.playlistOriginY { restoredPlaylistOrigin = NSPoint(x: x, y: y) }
        shouldRestoreInfoWindow = state.infoVisible ?? false
        if let width = state.infoWidth, let height = state.infoHeight {
            infoLogicalSize = NSSize(width: max(250, CGFloat(width)), height: max(116, CGFloat(height)))
        }
        if let x = state.infoOriginX, let y = state.infoOriginY { restoredInfoOrigin = NSPoint(x: x, y: y) }
        isEqualizerDocked = state.equalizerDocked
        equalizerWasMoved = !state.equalizerDocked
        isPlaylistDocked = state.playlistDocked
        playlistWasMoved = !state.playlistDocked
        playback.equalizer.restorePersistentState(state.equalizer)
    }

    private func restoreAuxiliaryWindows() {
        var equalizer: NSWindow?
        if equalizerState.isVisible {
            equalizer = makeEqualizerWindowIfNeeded()
        }
        // Playlist windows are restored from PlaylistManager below.  The old
        // single-window preference is intentionally not used here.
        // Layout first: it may move docked panels. Only then apply the saved
        // coordinates, so creating Playlist cannot displace restored EQ.
        applyInterfaceScale()
        if let equalizer, let restoredEqualizerOrigin {
            equalizer.setFrameOrigin(restoredEqualizerOrigin)
            if isEqualizerDocked {
                equalizerDockOffset = NSPoint(x: equalizer.frame.minX - window.frame.minX, y: equalizer.frame.minY - window.frame.minY)
            }
        }
        equalizer?.makeKeyAndOrderFront(nil)
        playlistManager.playlists.filter(\.isVisible).forEach { showPlaylistWindow(for: $0) }
        if shouldRestoreInfoWindow {
            let info = makeInfoWindowIfNeeded()
            if let restoredInfoOrigin { info.setFrameOrigin(restoredInfoOrigin) }
            infoModel.show(resolvedInfoTargetURL())
            info.makeKeyAndOrderFront(nil)
            infoState.isVisible = true
        }
    }

    private func savePersistentState() {
        let state = PersistentState(
            volume: playback.volume, balance: playback.balance,
            shuffle: playback.isShuffleEnabled, repeatTrack: playback.isRepeatEnabled,
            mainShade: windowShade.isEnabled,
            equalizerVisible: equalizerState.isVisible, equalizerShade: equalizerShade.isEnabled,
            playlistVisible: playlistState.isVisible, playlistShade: playlistShade.isEnabled,
            playlistWidth: Double(playlistLayout.width), playlistHeight: Double(playlistLayout.height),
            mainOriginX: Double(window.frame.origin.x), mainOriginY: Double(window.frame.origin.y),
            equalizerOriginX: equalizerWindow.map { Double($0.frame.origin.x) }, equalizerOriginY: equalizerWindow.map { Double($0.frame.origin.y) },
            playlistOriginX: playlistWindow.map { Double($0.frame.origin.x) }, playlistOriginY: playlistWindow.map { Double($0.frame.origin.y) },
            infoVisible: infoState.isVisible,
            infoWidth: Double(infoLogicalSize.width), infoHeight: Double(infoLogicalSize.height),
            infoOriginX: infoWindow.map { Double($0.frame.origin.x) }, infoOriginY: infoWindow.map { Double($0.frame.origin.y) },
            equalizerDocked: isEqualizerDocked, playlistDocked: isPlaylistDocked,
            equalizer: playback.equalizer.persistentState()
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: persistentStateKey)
            UserDefaults.standard.synchronize()
        }
    }

    private func observePersistentState() {
        let observableStates: [ObservableObjectPublisher] = [
            playback.equalizer.objectWillChange,
            windowShade.objectWillChange, equalizerState.objectWillChange,
            equalizerShade.objectWillChange, playlistState.objectWillChange,
            playlistShade.objectWillChange, playlistLayout.objectWillChange,
            infoState.objectWillChange
        ]
        observableStates.forEach { publisher in
            publisher.sink { [weak self] _ in self?.schedulePersistentStateSave() }
                .store(in: &persistenceCancellables)
        }
    }

    private func schedulePersistentStateSave() {
        pendingPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.savePersistentState() }
        pendingPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isExplicitTerminationRequested else {
            NSLog("MacAmp: cancelled an unexpected termination request")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainPlayer(nil)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showPlayer = NSMenuItem(title: "Show macAmp", action: #selector(showMainPlayer(_:)), keyEquivalent: "")
        showPlayer.target = self
        menu.addItem(showPlayer)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit macAmp", action: #selector(terminateApplication(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func applyInterfaceScale() {
        let scale = CGFloat(interfaceScale.factor)
        let scaleChanged = abs(scale - lastAppliedInterfaceScale) > 0.0001
        let scaleRatio = scale / lastAppliedInterfaceScale
        if scaleChanged {
            if isEqualizerDocked {
                equalizerDockOffset = NSPoint(x: equalizerDockOffset.x * scaleRatio, y: equalizerDockOffset.y * scaleRatio)
            }
            if isPlaylistDocked {
                playlistDockOffset = NSPoint(x: playlistDockOffset.x * scaleRatio, y: playlistDockOffset.y * scaleRatio)
            }
        }
        let baseHeight: CGFloat = windowShade.isEnabled ? 14 : 116
        let size = NSSize(width: 275 * scale, height: baseHeight * scale)
        let mainTop = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: mainTop - window.frame.height))
        window.minSize = size
        window.maxSize = size
        if let equalizerWindow {
            let equalizerSize = NSSize(width: 275 * scale, height: (equalizerShade.isEnabled ? 14 : 116) * scale)
            let equalizerTop = equalizerWindow.frame.maxY
            equalizerWindow.setContentSize(equalizerSize)
            equalizerWindow.setFrameOrigin(NSPoint(x: equalizerWindow.frame.minX, y: equalizerTop - equalizerWindow.frame.height))
            if isEqualizerDocked && !scaleChanged {
                equalizerDockOffset = NSPoint(x: equalizerWindow.frame.minX - window.frame.minX, y: equalizerWindow.frame.minY - window.frame.minY)
            }
            equalizerWindow.minSize = equalizerSize
            equalizerWindow.maxSize = equalizerSize
            moveDockedEqualizer()
        }
        if let playlistWindow {
            let playlistHeight: CGFloat = playlistShade.isEnabled ? 14 : playlistLayout.height
            let playlistSize = NSSize(width: playlistLayout.width * scale, height: playlistHeight * scale)
            let playlistTop = playlistWindow.frame.maxY
            // Lift the compact WindowShade size constraint before restoring the
            // full editor; otherwise AppKit clamps the requested expansion.
            if !playlistShade.isEnabled {
                playlistWindow.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            playlistWindow.setContentSize(playlistSize)
            playlistWindow.setFrameOrigin(NSPoint(x: playlistWindow.frame.minX, y: playlistTop - playlistWindow.frame.height))
            if isPlaylistDocked && !scaleChanged {
                playlistDockOffset = NSPoint(x: playlistWindow.frame.minX - window.frame.minX, y: playlistWindow.frame.minY - window.frame.minY)
            }
            if playlistShade.isEnabled {
                playlistWindow.minSize = NSSize(width: 275 * scale, height: 14 * scale)
                playlistWindow.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 14 * scale)
            } else {
                playlistWindow.minSize = NSSize(width: 275 * scale, height: 116 * scale)
            }
            moveDockedPlaylist()
        }
        // All Playlist Editors share the same logical skin size model.  Apply
        // scaling to every independently-created panel, preserving its top
        // edge and its individual windowshade state.
        for (id, playlistPanel) in playlistWindows {
            guard playlistPanel !== playlistWindow, let context = playlistWindowContexts[id] else { continue }
            let top = playlistPanel.frame.maxY
            let height = (context.shade.isEnabled ? 14 : context.layout.height) * scale
            playlistPanel.setContentSize(NSSize(width: context.layout.width * scale, height: height))
            playlistPanel.setFrameOrigin(NSPoint(x: playlistPanel.frame.minX, y: top - playlistPanel.frame.height))
            playlistPanel.minSize = NSSize(width: 275 * scale, height: context.shade.isEnabled ? 14 * scale : 116 * scale)
            playlistPanel.maxSize = context.shade.isEnabled ? NSSize(width: CGFloat.greatestFiniteMagnitude, height: 14 * scale) : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            context.model.windowFrame = playlistPanel.frame
        }
        if let infoWindow {
            let top = infoWindow.frame.maxY
            let minimumWidth = CGFloat(WinampSkinStore().genericMinimumWindowWidth(title: "Info"))
            infoLogicalSize.width = max(minimumWidth, infoLogicalSize.width)
            infoLogicalSize.height = max(116, infoLogicalSize.height)
            infoWindow.setContentSize(NSSize(width: infoLogicalSize.width * scale, height: infoLogicalSize.height * scale))
            infoWindow.setFrameOrigin(NSPoint(x: infoWindow.frame.minX, y: top - infoWindow.frame.height))
            infoWindow.minSize = NSSize(width: minimumWidth * scale, height: 116 * scale)
        }
        lastAppliedInterfaceScale = scale
    }

    private func connectFileMenu() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        configureFileItem("New Playlist", action: #selector(newPlaylist(_:)), in: fileMenu)
        configureFileItem("Open…", action: #selector(openDocument(_:)), in: fileMenu)
        configureFileItem("Close", action: #selector(closeFocusedPlaylist(_:)), in: fileMenu)
        configureFileItem("Save…", action: #selector(savePlaylist(_:)), in: fileMenu)
        configureFileItem("Save As…", action: #selector(savePlaylistAs(_:)), in: fileMenu)
        if let recent = fileMenu.items.first(where: { $0.title == "Open Recent" })?.submenu {
            rebuildRecentMenu(recent)
        }
    }

    private func connectControlsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let existing = mainMenu.item(withTitle: "Controls")?.submenu {
            controlsMenu = existing
            existing.removeAllItems()
        } else {
            let item = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Controls")
            item.submenu = menu
            let insertionIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" }) ?? mainMenu.items.count
            mainMenu.insertItem(item, at: insertionIndex)
            controlsMenu = menu
        }
        guard let controlsMenu else { return }
        controlsMenu.delegate = self

        addControlMenuItem("Previous", action: #selector(previousTrack(_:)), key: "z", to: controlsMenu)
        addControlMenuItem("Play", action: #selector(playTrack(_:)), key: "x", to: controlsMenu)
        addControlMenuItem("Pause", action: #selector(pauseTrack(_:)), key: "c", to: controlsMenu)
        addControlMenuItem("Stop", action: #selector(stopTrack(_:)), key: "v", to: controlsMenu)
        addControlMenuItem("Next", action: #selector(nextTrack(_:)), key: "b", to: controlsMenu)
        controlsMenu.addItem(.separator())
        addControlMenuItem("Back 5 Seconds", action: #selector(rewindFiveSeconds(_:)), key: menuKey(NSLeftArrowFunctionKey), to: controlsMenu)
        addControlMenuItem("Forward 5 Seconds", action: #selector(forwardFiveSeconds(_:)), key: menuKey(NSRightArrowFunctionKey), to: controlsMenu)
        addControlMenuItem("Volume Down", action: #selector(volumeDown(_:)), key: menuKey(NSDownArrowFunctionKey), to: controlsMenu)
        addControlMenuItem("Volume Up", action: #selector(volumeUp(_:)), key: menuKey(NSUpArrowFunctionKey), to: controlsMenu)
        controlsMenu.addItem(.separator())
        addControlMenuItem("Shuffle", action: #selector(toggleShuffle(_:)), key: "s", to: controlsMenu)
        addControlMenuItem("Repeat", action: #selector(toggleRepeat(_:)), key: "r", to: controlsMenu)
        updateControlsMenuState()
    }

    private func connectWindowMenu() {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu else { return }
        let item = menu.items.first(where: { $0.title == "Info" }) ?? NSMenuItem(title: "Info", action: nil, keyEquivalent: "")
        if item.menu == nil { menu.addItem(item) }
        item.target = self
        item.action = #selector(toggleInfo(_:))
        item.isEnabled = true
    }

    private func addControlMenuItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = []
        menu.addItem(item)
    }

    private func menuKey(_ keyCode: Int) -> String {
        UnicodeScalar(keyCode).map(String.init) ?? ""
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === controlsMenu { updateControlsMenuState() }
    }

    private func updateControlsMenuState() {
        controlsMenu?.item(withTitle: "Shuffle")?.state = playback.isShuffleEnabled ? .on : .off
        controlsMenu?.item(withTitle: "Repeat")?.state = playback.isRepeatEnabled ? .on : .off
    }

    @objc private func previousTrack(_ sender: Any?) { playlistTransportAction(0) }
    @objc private func playTrack(_ sender: Any?) { playFromActivePlaylist() }
    @objc private func pauseTrack(_ sender: Any?) { pausePlayback() }
    @objc private func stopTrack(_ sender: Any?) { stopPlayback() }

    func pausePlayback() { resetInfoTarget(); playback.pause() }
    func stopPlayback() { resetInfoTarget(); playback.stop() }
    @objc private func nextTrack(_ sender: Any?) { playlistTransportAction(4) }
    @objc private func rewindFiveSeconds(_ sender: Any?) { seekPlayback(to: max(0, playback.position - 5)) }
    @objc private func forwardFiveSeconds(_ sender: Any?) { seekPlayback(to: min(playback.duration, playback.position + 5)) }
    @objc private func volumeDown(_ sender: Any?) { playback.volume = max(0, playback.volume - 0.05) }
    @objc private func volumeUp(_ sender: Any?) { playback.volume = min(1, playback.volume + 0.05) }
    @objc private func toggleShuffle(_ sender: Any?) { playback.isShuffleEnabled.toggle(); updateControlsMenuState() }
    @objc private func toggleRepeat(_ sender: Any?) { playback.isRepeatEnabled.toggle(); updateControlsMenuState() }

    private func configureFileItem(_ title: String, action: Selector, in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.title == title }) else { return }
        item.target = self; item.action = action; item.isEnabled = true
    }

    private func rebuildRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasRecent = !playlistManager.recentPlaylistURLs.isEmpty
        menu.supermenu?.item(withTitle: "Open Recent")?.isEnabled = hasRecent
        guard hasRecent else { let item = NSMenuItem(title: "No Recent Playlists", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item); return }
        for url in playlistManager.recentPlaylistURLs {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecentPlaylist(_:)), keyEquivalent: "")
            item.representedObject = url; item.target = self; item.isEnabled = !playlistManager.isOpenPlaylist(at: url); menu.addItem(item)
        }
    }

    private func connectPreferencesMenu() {
        guard let applicationMenu = NSApp.mainMenu?.item(withTitle: "macAmp")?.submenu,
              let preferencesItem = applicationMenu.items.first(where: { $0.keyEquivalent == "," }) else { return }
        preferencesItem.target = self
        preferencesItem.action = #selector(showPreferences(_:))
        preferencesItem.isEnabled = true
    }

    private func connectQuitMenu() {
        guard let applicationMenu = NSApp.mainMenu?.item(withTitle: "macAmp")?.submenu,
              let quitItem = applicationMenu.items.first(where: { $0.keyEquivalent == "q" }) else { return }
        quitItem.target = self
        quitItem.action = #selector(terminateApplication(_:))
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["m3u", "m3u8"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let playlist = playlistManager.loadPlaylistAsynchronously(from: url) else { NSSound.beep(); return }
        showPlaylistWindow(for: playlist); connectFileMenu()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var didOpen = false
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()),
               let playlist = playlistManager.loadPlaylistAsynchronously(from: url) {
                showPlaylistWindow(for: playlist)
                connectFileMenu()
                didOpen = true
            }
        }
        sender.reply(toOpenOrPrint: didOpen ? .success : .failure)
    }

    @objc func newPlaylist(_ sender: Any?) {
        showPlaylistWindow(for: playlistManager.createPlaylist())
    }

    @objc func closeFocusedPlaylist(_ sender: Any?) {
        if let playlist = playlistManager.editingPlaylist { closePlaylistWindow(for: playlist) }
    }

    @objc func savePlaylist(_ sender: Any?) {
        guard let playlist = playlistManager.editingPlaylist else { return }
        if let url = playlist.fileURL { try? playlistManager.savePlaylist(playlist, to: url) }
        else { savePlaylistAs(sender) }
    }

    @objc func savePlaylistAs(_ sender: Any?) {
        guard let playlist = playlistManager.editingPlaylist else { return }
        let panel = NSSavePanel(); panel.allowedFileTypes = ["m3u"]; panel.nameFieldStringValue = "\(playlist.name).m3u"
        if panel.runModal() == .OK, let url = panel.url { try? playlistManager.savePlaylist(playlist, to: url); connectFileMenu() }
    }

    private func savePlaylistForClose(_ playlist: PlaylistModel) -> Bool {
        if let url = playlist.fileURL {
            do { try playlistManager.savePlaylist(playlist, to: url); return true }
            catch { NSSound.beep(); return false }
        }
        let panel = NSSavePanel(); panel.allowedFileTypes = ["m3u"]
        panel.nameFieldStringValue = "\(playlist.name).m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try playlistManager.savePlaylist(playlist, to: url); connectFileMenu(); return true }
        catch { NSSound.beep(); return false }
    }

    @objc func openRecentPlaylist(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let playlist = playlistManager.loadPlaylistAsynchronously(from: url) { showPlaylistWindow(for: playlist); connectFileMenu() }
    }

    /// The Playlist Editor has the same six compact transport controls as
    /// classic Winamp: previous, play, pause, stop, next and eject.
    func playlistTransportAction(_ index: Int) {
        resetInfoTarget()
        guard let playlist = playlistManager.activePlaylist else { return }
        switch index {
        case 0: playPlaylistEntry(playlistManager.entryToPlay(in: playlist, step: -1, shuffle: false), in: playlist)
        case 1: playFromActivePlaylist()
        case 2: pausePlayback()
        case 3: stopPlayback()
        case 4: playPlaylistEntry(playlistManager.entryToPlay(in: playlist, step: 1, shuffle: playback.isShuffleEnabled), in: playlist)
        case 5: addFilesToActivePlaylist()
        default: break
        }
    }

    private func playPlaylistEntry(_ entry: PlaylistEntry?, in playlist: PlaylistModel) {
        guard let entry else {
            if playback.isRepeatEnabled, let current = playlist.entries.first(where: { $0.id == playlistManager.playingEntryID }) {
                playlistManager.play(current, in: playlist); playback.open(current.url); infoModel.showForPlayback(current.url)
            }
            return
        }
        playlistManager.play(entry, in: playlist); playback.open(entry.url); infoModel.showForPlayback(entry.url)
    }

    /// Playlist rows call this route as well, so their double-click has the
    /// same Info Target reset semantics as every other transport command.
    func playPlaylistEntryFromSelection(_ entry: PlaylistEntry, in playlist: PlaylistModel) {
        resetInfoTarget()
        playlistManager.play(entry, in: playlist, revealIfNeeded: false)
        playback.open(entry.url)
        infoModel.showForPlayback(entry.url)
    }

    func seekPlayback(to position: TimeInterval) {
        resetInfoTarget()
        playback.seek(to: position)
    }

    /// Main Play never opens a file picker.  A playlist is the playback
    /// source: resume its last cursor, otherwise use selection, then entry 1.
    func playFromActivePlaylist() {
        resetInfoTarget()
        guard let playlist = playlistManager.activePlaylist,
              let entry = playlistManager.preferredEntryToPlay(in: playlist) else { return }
        if playback.currentURL == entry.url {
            if !playback.isPlaying { playback.play() }
        } else {
            playPlaylistEntry(entry, in: playlist)
        }
    }

    private func advancePlaylistAfterTrackFinished() {
        resetInfoTarget()
        guard let playlist = playlistManager.activePlaylist else { playback.stop(); return }
        if let next = playlistManager.entryToPlay(in: playlist, step: 1, shuffle: playback.isShuffleEnabled) {
            playPlaylistEntry(next, in: playlist)
        } else if playback.isRepeatEnabled,
                  let current = playlist.entries.first(where: { $0.id == playlistManager.playingEntryID }) {
            playPlaylistEntry(current, in: playlist)
        } else {
            playback.stop()
        }
    }

    /// Commands used by the skinned Playlist Editor menus.  NSOpenPanel is
    /// deliberately kept at the AppKit boundary; PlaylistManager remains UI-free.
    func addFilesToActivePlaylist() {
        guard let playlist = playlistManager.editingPlaylist else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = Array(PlaylistManager.supportedExtensions)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { playlistManager.addFiles(panel.urls, to: playlist) }
    }

    func chooseTracksForPlaybackPlaylist() {
        let playlist = playlistManager.editingPlaylist ?? playlistManager.createPlaylist()
        let panel = NSOpenPanel()
        panel.allowedFileTypes = Array(PlaylistManager.supportedExtensions)
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let firstNew = panel.urls.first { url in !playlist.entries.contains(where: { $0.url == url }) }
        playlistManager.addFiles(panel.urls, to: playlist)
        if let url = firstNew, let entry = playlist.entries.first(where: { $0.url == url }) {
            playPlaylistEntry(entry, in: playlist)
        }
    }

    func openPlaylistURL(_ url: URL) {
        guard let playlist = playlistManager.loadPlaylistAsynchronously(from: url) else { NSSound.beep(); return }
        showPlaylistWindow(for: playlist)
        connectFileMenu()
    }

    func addFolderToActivePlaylist() {
        guard let playlist = playlistManager.editingPlaylist else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { playlistManager.addFolder(url, to: playlist) }
    }

    func removeSelectedFromActivePlaylist() {
        if let playlist = playlistManager.editingPlaylist { playlistManager.removeSelected(from: playlist) }
    }

    func clearActivePlaylist() { if let playlist = playlistManager.editingPlaylist { playlistManager.clear(playlist) } }
    func cropActivePlaylist() { if let playlist = playlistManager.editingPlaylist { playlistManager.cropToSelection(playlist) } }
    func selectAllInActivePlaylist() { if let playlist = playlistManager.editingPlaylist { playlistManager.selectAll(in: playlist) } }
    func selectNoneInActivePlaylist() { if let playlist = playlistManager.editingPlaylist { playlistManager.selectNone(in: playlist) } }
    func invertSelectionInActivePlaylist() { if let playlist = playlistManager.editingPlaylist { playlistManager.invertSelection(in: playlist) } }

    @objc func showMainPlayer(_ sender: Any?) {
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        refreshInterfaceVisibility()
    }

    @objc func hideMainPlayer(_ sender: Any?) {
        window.orderOut(nil)
        refreshInterfaceVisibility()
    }

    private func refreshInterfaceVisibility() {
        // A visible player must keep its spectrum alive even when another app
        // owns keyboard focus.  Suspend expensive UI work only when this
        // window is actually hidden or miniaturized.
        playback.setInterfaceVisible(window.isVisible && !window.isMiniaturized)
    }

    /// The classic player is a set of panels: activating any one panel must
    /// raise the complete visible set above other applications.
    func bringPlayerWindowsToFront(active: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        raiseVisiblePlayerWindows()
        active.makeKeyAndOrderFront(nil)
    }

    /// All classic panels belong to one player surface. NSPanel does not
    /// automatically join the application's activation ordering, so Info must
    /// be raised explicitly alongside Main, EQ and Playlist windows.
    private func raiseVisiblePlayerWindows() {
        if window.isVisible { window.orderFrontRegardless() }
        if equalizerState.isVisible { equalizerWindow?.orderFrontRegardless() }
        if playlistState.isVisible { playlistWindows.values.forEach { $0.orderFrontRegardless() } }
        if infoState.isVisible { infoWindow?.orderFrontRegardless() }
    }

    @objc func showPreferences(_ sender: Any?) {
        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let preferences = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 172),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        preferences.title = "Settings"
        preferences.isReleasedWhenClosed = false
        preferences.contentView = NSHostingView(rootView: SettingsView(
            interfaceScale: interfaceScale,
            timeDisplayPreference: timeDisplayPreference
        ))
        preferences.center()
        preferences.makeKeyAndOrderFront(nil)
        preferencesWindow = preferences
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleWindowShade(_ sender: Any?) {
        windowShade.isEnabled.toggle()
        applyInterfaceScale()
    }

    @objc func toggleEqualizer(_ sender: Any?) {
        if equalizerState.isVisible {
            equalizerWindow?.orderOut(nil)
            equalizerState.isVisible = false
            return
        }

        let equalizer = makeEqualizerWindowIfNeeded()
        if !equalizerWasMoved { dockEqualizerBelowPlayer() }
        equalizer.makeKeyAndOrderFront(nil)
        equalizerState.isVisible = true
    }

    @objc func hideEqualizer(_ sender: Any?) {
        equalizerWindow?.orderOut(nil)
        equalizerState.isVisible = false
    }

    @objc func togglePlaylist(_ sender: Any?) {
        let visible = playlistWindows.values.contains { $0.isVisible } || playlistState.isVisible
        if visible {
            playlistWindows.forEach { id, window in
                window.orderOut(nil)
                if let model = playlistManager.playlist(id: id) { playlistManager.setVisible(false, for: model) }
            }
            playlistWindow?.orderOut(nil); playlistState.isVisible = false
            return
        }
        playlistManager.playlists.forEach { showPlaylistWindow(for: $0) }
    }

    @objc func toggleInfo(_ sender: Any?) {
        if let infoWindow, infoWindow.isVisible {
            infoWindow.orderOut(nil)
            infoState.isVisible = false
            schedulePersistentStateSave()
            return
        }
        let panel = makeInfoWindowIfNeeded()
        infoModel.show(resolvedInfoTargetURL())
        panel.makeKeyAndOrderFront(nil)
        infoState.isVisible = true
        schedulePersistentStateSave()
    }

    func selectInfoTarget(_ entry: PlaylistEntry) {
        infoTargetURL = entry.url
        infoModel.show(entry.url)
    }

    private func resetInfoTarget() {
        infoTargetURL = nil
        infoModel.show(resolvedInfoTargetURL())
    }

    /// Info may open before playback is started (including after restoring a
    /// session). In that case it still has a meaningful target: first an
    /// explicitly selected row, then the active playlist's playable entry.
    private func resolvedInfoTargetURL() -> URL? {
        if let infoTargetURL { return infoTargetURL }
        if let currentURL = playback.currentURL { return currentURL }

        // PlaybackController has no open AVAudioFile immediately after launch,
        // but PlaylistManager restores the playback cursor. That cursor is the
        // current playback target and takes precedence over a mere selection.
        if let active = playlistManager.activePlaylist {
            if let playingID = playlistManager.playingEntryID,
               let playing = active.entries.first(where: { $0.id == playingID }) { return playing.url }
            if let lastPlayedID = active.lastPlayedEntryID,
               let lastPlayed = active.entries.first(where: { $0.id == lastPlayedID }) { return lastPlayed.url }
        }

        let preferredPlaylists = [playlistManager.editingPlaylist, playlistManager.activePlaylist].compactMap { $0 }
        for playlist in preferredPlaylists {
            if let selected = playlist.entries.first(where: { playlist.selectedIDs.contains($0.id) }) { return selected.url }
        }
        for playlist in playlistManager.playlists where !preferredPlaylists.contains(where: { $0.id == playlist.id }) {
            if let selected = playlist.entries.first(where: { playlist.selectedIDs.contains($0.id) }) { return selected.url }
        }
        if let active = playlistManager.activePlaylist,
           let entry = playlistManager.preferredEntryToPlay(in: active) { return entry.url }
        return playlistManager.playlists.lazy.compactMap { $0.entries.first?.url }.first
    }

    private func makeInfoWindowIfNeeded() -> NSWindow {
        if let infoWindow { return infoWindow }
        let scale = CGFloat(interfaceScale.factor)
        let skin = WinampSkinStore()
        let minimumWidth = CGFloat(skin.genericMinimumWindowWidth(title: "Info"))
        infoLogicalSize.width = max(minimumWidth, infoLogicalSize.width)
        let panel = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: infoLogicalSize.width * scale, height: infoLogicalSize.height * scale), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: minimumWidth * scale, height: 116 * scale)
        panel.contentView = InfoPanelView(model: infoModel, scale: interfaceScale, focus: infoFocus,
            onClose: { [weak self, weak panel] in panel?.orderOut(nil); self?.infoState.isVisible = false; self?.schedulePersistentStateSave() },
            onResize: { [weak self, weak panel] width, height in self?.resizeInfo(panel, width: width, height: height) },
            onDragChanged: { [weak self, weak panel] in
                if let panel { self?.magnetWindowWhileDragging(panel) }
            },
            onDragEnded: { [weak self] in self?.schedulePersistentStateSave() })
        panel.setFrameOrigin(NSPoint(x: window.frame.maxX, y: window.frame.maxY - panel.frame.height))
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.infoFocus.isKey = true }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.infoFocus.isKey = false }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in self?.schedulePersistentStateSave() }
        infoWindow = panel
        return panel
    }

    private func resizeInfo(_ panel: NSWindow?, width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        let scale = CGFloat(interfaceScale.factor)
        let minimumWidth = CGFloat(WinampSkinStore().genericMinimumWindowWidth(title: "Info"))
        let logicalWidth = max(minimumWidth, ceil(width / 25) * 25)
        let requestedHeight = max(116, ceil(height / 29) * 29)
        let logicalHeight = magneticallySnappedResizeHeight(for: panel, requestedLogicalHeight: requestedHeight, scale: scale)
        let top = panel.frame.maxY
        infoLogicalSize = NSSize(width: logicalWidth, height: logicalHeight)
        panel.setContentSize(NSSize(width: logicalWidth * scale, height: logicalHeight * scale))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        schedulePersistentStateSave()
    }

    private func showPlaylistEditor() {
        let playlist = makePlaylistWindowIfNeeded()
        if !playlistWasMoved { dockPlaylistToPlayerRight() }
        playlist.makeKeyAndOrderFront(nil)
        playlistState.isVisible = true
    }

    /// Every model gets a real NSPanel.  This retains the classic skin while
    /// eliminating the old "one model, one reusable window" limitation.
    private func showPlaylistWindow(for model: PlaylistModel) {
        if let existing = playlistWindows[model.id] {
            playlistManager.setVisible(true, for: model)
            lastActivePlaylistWindow = existing
            existing.makeKeyAndOrderFront(nil); return
        }
        let scale = CGFloat(interfaceScale.factor)
        let context = PlaylistWindowContext(model, interfaceScale: scale)
        let initialHeight = (context.shade.isEnabled ? 14 : context.layout.height) * scale
        let panel = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: context.layout.width * scale, height: initialHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: PlaylistView(interfaceScale: interfaceScale, focus: context.focus, shade: context.shade, layout: context.layout, playback: playback, timeDisplayPreference: timeDisplayPreference, manager: playlistManager, playlist: model, onClose: { [weak self] in self?.closePlaylistWindow(for: model) }, onToggleShade: { [weak self] in self?.toggleFloatingPlaylistShade(panel, context: context) }, onDragEnded: { [weak self] in self?.finishFloatingPlaylistGesture(panel, model: model) }, onResize: { [weak self] width, height in self?.resizeFloatingPlaylist(panel, context: context, width: width, height: height) }, onShadeResize: { [weak self] width in self?.resizeFloatingPlaylist(panel, context: context, width: width, height: 14) }))
        let activeWindow = lastActivePlaylistWindow ?? playlistWindows.values.first(where: { $0.isKeyWindow }) ?? playlistWindows.values.first
        let origin = model.windowFrame.map { NSPoint(x: $0.minX, y: $0.minY) } ?? activeWindow.map { NSPoint(x: $0.frame.minX + 25 * scale, y: $0.frame.minY - 29 * scale) } ?? NSPoint(x: window.frame.maxX, y: window.frame.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel, weak model] _ in
            guard let self, let panel, let model else { return }
            model.windowFrame = panel.frame; self.playlistManager.save()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self, weak model] _ in
            context.focus.isKey = true
            if let model {
                self?.playlistManager.focus(model)
                self?.lastActivePlaylistWindow = panel
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            context.focus.isKey = false
        }
        playlistWindows[model.id] = panel; playlistWindowContexts[model.id] = context
        playlistManager.setVisible(true, for: model)
        playlistState.isVisible = true
        lastActivePlaylistWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func hidePlaylist(_ sender: Any?) {
        playlistWindow?.orderOut(nil)
        playlistState.isVisible = false
    }

    @objc func togglePlaylistWindowShade(_ sender: Any?) {
        playlistShade.isEnabled.toggle()
        applyInterfaceScale()
    }

    private func makePlaylistWindowIfNeeded() -> NSWindow {
        if let playlistWindow { return playlistWindow }
        let model = playlistManager.activePlaylist ?? playlistManager.createPlaylist()
        let scale = CGFloat(interfaceScale.factor)
        let playlist = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: playlistLayout.width * scale, height: playlistLayout.height * scale),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        playlist.isOpaque = false
        playlist.backgroundColor = .clear
        playlist.hasShadow = true
        playlist.isMovableByWindowBackground = false
        playlist.contentView = NSHostingView(rootView: PlaylistView(
            interfaceScale: interfaceScale,
            focus: playlistFocus,
            shade: playlistShade,
            layout: playlistLayout,
            playback: playback,
            timeDisplayPreference: timeDisplayPreference,
            manager: playlistManager,
            playlist: model,
            onClose: { [weak self] in if let model = self?.playlistManager.activePlaylist { self?.closePlaylistWindow(for: model) } },
            onToggleShade: { [weak self] in self?.togglePlaylistWindowShade(nil) },
            onDragEnded: { [weak self] in self?.playlistDragEnded() },
            onResize: { [weak self] width, height in self?.resizePlaylist(toLogicalWidth: width, height: height) },
            onShadeResize: { [weak self] width in self?.resizePlaylistWindowShade(toLogicalWidth: width) }
        ))
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: playlist, queue: .main) { [weak self, weak playlist] _ in
            guard let self, let playlist else { return }
            self.playlistFocus.isKey = true; self.lastActivePlaylistWindow = playlist
            if let id = self.playlistWindows.first(where: { $0.value === playlist })?.key,
               let model = self.playlistManager.playlist(id: id) {
                self.playlistManager.focus(model)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: playlist, queue: .main) { [weak self] _ in self?.playlistFocus.isKey = false }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: playlist, queue: .main) { [weak self] _ in
            guard let self, !self.isRepositioningPlaylist else { return }
            self.schedulePersistentStateSave()
        }
        playlistWindow = playlist
        // This window can also be created during state restoration, before
        // showPlaylistWindow(for:) runs.  Register it here so it participates
        // in magnetism with every subsequently opened editor.
        playlistWindows[model.id] = playlist
        lastActivePlaylistWindow = playlist
        return playlist
    }

    private func refreshPlaylistWindow() {
        guard let playlistWindow, let model = playlistManager.activePlaylist else { return }
        playlistWindow.contentView = NSHostingView(rootView: PlaylistView(
            interfaceScale: interfaceScale, focus: playlistFocus, shade: playlistShade,
            layout: playlistLayout, playback: playback,
            timeDisplayPreference: timeDisplayPreference, manager: playlistManager, playlist: model,
            onClose: { [weak self] in self?.closePlaylistWindow(for: model) },
            onToggleShade: { [weak self] in self?.togglePlaylistWindowShade(nil) },
            onDragEnded: { [weak self] in self?.playlistDragEnded() },
            onResize: { [weak self] width, height in self?.resizePlaylist(toLogicalWidth: width, height: height) },
            onShadeResize: { [weak self] width in self?.resizePlaylistWindowShade(toLogicalWidth: width) }
        ))
    }

    private func resizeFloatingPlaylist(_ panel: NSWindow, context: PlaylistWindowContext, width: CGFloat, height: CGFloat) {
        let scale = CGFloat(interfaceScale.factor)
        let logicalWidth = max(275, (width / 25).rounded() * 25)
        let requestedHeight = max(116, (height / 29).rounded() * 29)
        let logicalHeight = magneticallySnappedResizeHeight(for: panel, requestedLogicalHeight: requestedHeight, scale: scale)
        let displayedHeight = context.shade.isEnabled ? 14 : logicalHeight
        let top = panel.frame.maxY
        context.layout.width = logicalWidth; context.layout.height = logicalHeight
        context.model.unshadedWindowWidth = logicalWidth; context.model.unshadedWindowHeight = logicalHeight
        panel.setContentSize(NSSize(width: logicalWidth * scale, height: displayedHeight * scale))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        context.model.windowFrame = panel.frame; playlistManager.save()
    }

    private func toggleFloatingPlaylistShade(_ panel: NSWindow, context: PlaylistWindowContext) {
        let top = panel.frame.maxY
        context.model.unshadedWindowWidth = context.layout.width
        context.model.unshadedWindowHeight = context.layout.height
        context.shade.isEnabled.toggle()
        context.model.isWindowShaded = context.shade.isEnabled
        let scale = CGFloat(interfaceScale.factor)
        let height = (context.shade.isEnabled ? 14 : context.layout.height) * scale
        panel.setContentSize(NSSize(width: context.layout.width * scale, height: height))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        panel.minSize = NSSize(width: 275 * scale, height: context.shade.isEnabled ? 14 * scale : 116 * scale)
        panel.maxSize = context.shade.isEnabled
            ? NSSize(width: CGFloat.greatestFiniteMagnitude, height: 14 * scale)
            : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        context.model.windowFrame = panel.frame
        playlistManager.save()
    }

    private func finishFloatingPlaylistGesture(_ panel: NSWindow, model: PlaylistModel) {
        magnet(panel, against: [window, equalizerWindow, infoWindow].compactMap { $0 } + playlistWindows.values.filter { $0 !== panel })
        model.windowFrame = panel.frame; playlistManager.save()
    }

    private func closePlaylistWindow(for model: PlaylistModel) {
        if model.isDirty {
            let alert = NSAlert(); alert.messageText = "Save changes to \(model.name)?"
            alert.informativeText = "This playlist has unsaved changes."
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don't Save"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard savePlaylistForClose(model) else { return }
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        if playlistManager.playlists.count == 1 {
            playlistManager.setVisible(false, for: model)
            playlistWindows[model.id]?.orderOut(nil)
            playlistState.isVisible = false
            return
        }
        if playlistManager.activePlaylistID == model.id { playback.stop() }
        if let panel = playlistWindows[model.id] {
            if lastActivePlaylistWindow === panel { lastActivePlaylistWindow = playlistWindows.values.first(where: { $0 !== panel }) }
            panel.orderOut(nil); panel.close()
        }
        playlistWindows[model.id] = nil; playlistWindowContexts[model.id] = nil
        playlistManager.close(model); connectFileMenu()
    }

    func playlistDragEnded() {
        playlistWasMoved = true
        snapPlaylistIfNeeded()
        if let playlistWindow {
            magnet(playlistWindow, against: [window, equalizerWindow, infoWindow].compactMap { $0 } + playlistWindows.values.filter { $0 !== playlistWindow })
            updatePlaylistDocking()
        }
    }

    /// A 29 px vertical grid divides the main player's 116 px height. Thus an
    /// Info window can align exactly with both the top of the main window and
    /// the bottom of any Playlist Editor placed below it.
    func resizePlaylist(toLogicalWidth width: CGFloat, height: CGFloat) {
        let snappedWidth = max(275, ceil(width / 25) * 25)
        guard let playlistWindow else { return }
        let scale = CGFloat(interfaceScale.factor)
        let requestedHeight = max(116, ceil(height / 29) * 29)
        let snappedHeight = magneticallySnappedResizeHeight(for: playlistWindow, requestedLogicalHeight: requestedHeight, scale: scale)
        let size = NSSize(width: snappedWidth * scale, height: snappedHeight * scale)
        let frame = NSRect(x: playlistWindow.frame.minX,
                           y: playlistWindow.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        isRepositioningPlaylist = true
        playlistLayout.width = snappedWidth
        playlistLayout.height = snappedHeight
        playlistWindow.setFrame(frame, display: true)
        playlistWindow.minSize = NSSize(width: 275 * scale, height: 116 * scale)
        isRepositioningPlaylist = false
        playlistWasMoved = true
        // Resizing must preserve the user's chosen top-left relationship.
        // Docking is resolved only after a drag, never as a side effect here.
    }

    /// A bottom-right resize keeps the window's top fixed.  When its moving
    /// lower edge comes close to the lower edge of an adjacent skin window,
    /// use that exact height so a right-side Info panel can span the player
    /// and the Playlist Editor below it without a one-pixel seam.
    private func magneticallySnappedResizeHeight(for panel: NSWindow, requestedLogicalHeight: CGFloat, scale: CGFloat) -> CGFloat {
        let top = panel.frame.maxY
        let requestedBottom = top - requestedLogicalHeight * scale
        // Height is normally quantised to the 29 px Winamp row.  The target
        // edge can therefore be up to half a row away after quantisation;
        // use a half-row capture zone in *screen* coordinates so snapping is
        // equally reliable at 1× and 2× interface scale.
        let threshold: CGFloat = 15 * scale
        let candidates = [window, equalizerWindow, infoWindow].compactMap { $0 }
            + playlistWindows.values.filter { $0 !== panel }
        for candidate in candidates where candidate.isVisible && candidate !== panel {
            let frame = candidate.frame
            let horizontallyAdjacent = panel.frame.maxX >= frame.minX - threshold
                && panel.frame.minX <= frame.maxX + threshold
            guard horizontallyAdjacent, abs(requestedBottom - frame.minY) <= threshold else { continue }
            return max(116, (top - frame.minY) / scale)
        }
        return requestedLogicalHeight
    }

    /// In WindowShade mode the Playlist Editor exposes only its 9 px horizontal
    /// resize grip. Width remains on Winamp's 25 px grid; height stays 14 px.
    func resizePlaylistWindowShade(toLogicalWidth width: CGFloat) {
        guard playlistShade.isEnabled, let playlistWindow else { return }
        let snappedWidth = max(275, ceil(width / 25) * 25)
        let scale = CGFloat(interfaceScale.factor)
        playlistLayout.width = snappedWidth
        let frame = NSRect(x: playlistWindow.frame.minX,
                           y: playlistWindow.frame.minY,
                           width: snappedWidth * scale,
                           height: 14 * scale)
        playlistWindow.setFrame(frame, display: true)
        playlistWindow.minSize = NSSize(width: 275 * scale, height: 14 * scale)
        playlistWindow.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 14 * scale)
        playlistWasMoved = true
    }

    /// First appearance follows the classic layout: Playlist Editor to the right
    /// of Main Player, with a 232 px logical height (Main + Equalizer).
    private func dockPlaylistToPlayerRight() {
        guard let playlistWindow else { return }
        isRepositioningPlaylist = true
        playlistWindow.setFrameOrigin(NSPoint(x: window.frame.maxX, y: window.frame.maxY - playlistWindow.frame.height))
        playlistDockOffset = NSPoint(x: playlistWindow.frame.minX - window.frame.minX, y: playlistWindow.frame.minY - window.frame.minY)
        isRepositioningPlaylist = false
        isPlaylistDocked = true
    }

    private func moveDockedPlaylist() {
        guard isPlaylistDocked, playlistState.isVisible else { return }
        isRepositioningPlaylist = true
        playlistWindow?.setFrameOrigin(NSPoint(x: window.frame.minX + playlistDockOffset.x, y: window.frame.minY + playlistDockOffset.y))
        isRepositioningPlaylist = false
    }

    private func snapPlaylistIfNeeded() {
        guard let playlistWindow else { return }
        let expected = NSPoint(x: window.frame.maxX, y: window.frame.maxY - playlistWindow.frame.height)
        let delta = hypot(playlistWindow.frame.minX - expected.x, playlistWindow.frame.minY - expected.y)
        isPlaylistDocked = delta <= 12
        if isPlaylistDocked { dockPlaylistToPlayerRight() }
    }

    private func updatePlaylistDocking() {
        guard let playlistWindow else { return }
        isPlaylistDocked = isMagneticallyAttached(playlistWindow.frame, to: window.frame)
        if isPlaylistDocked { playlistDockOffset = NSPoint(x: playlistWindow.frame.minX - window.frame.minX, y: playlistWindow.frame.minY - window.frame.minY) }
    }

    private func makeEqualizerWindowIfNeeded() -> NSWindow {
        if let equalizerWindow { return equalizerWindow }
        let scale = CGFloat(interfaceScale.factor)
        let equalizer = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 275 * scale, height: 116 * scale),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        equalizer.isOpaque = false
        equalizer.backgroundColor = .clear
        equalizer.hasShadow = true
        equalizer.isMovableByWindowBackground = false
        equalizer.contentView = NSHostingView(rootView: EqualizerView(
            interfaceScale: interfaceScale,
            focus: equalizerFocus,
            shade: equalizerShade,
            playback: playback,
            equalizer: playback.equalizer
        ))
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: equalizer, queue: .main) { [weak self] _ in self?.equalizerFocus.isKey = true }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: equalizer, queue: .main) { [weak self] _ in self?.equalizerFocus.isKey = false }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: equalizer,
                                               queue: .main) { [weak self] _ in
            guard let self, !self.isRepositioningEqualizer else { return }
            self.schedulePersistentStateSave()
        }
        equalizerWindow = equalizer
        return equalizer
    }

    func equalizerDragEnded() {
        equalizerWasMoved = true
        snapEqualizerIfNeeded()
        if let equalizerWindow {
            magnet(equalizerWindow, against: [window, infoWindow].compactMap { $0 } + playlistWindows.values)
            updateEqualizerDocking()
        }
    }

    func mainWindowDragEnded() {
        let group = Set(mainDragGroupWindows.map(ObjectIdentifier.init))
        magnet(window, against: ([equalizerWindow, infoWindow].compactMap { $0 } + playlistWindows.values)
            .filter { !group.contains(ObjectIdentifier($0)) })
        moveMainDragGroup(by: NSPoint(
            x: window.frame.minX - (mainDragLastOrigin?.x ?? window.frame.minX),
            y: window.frame.minY - (mainDragLastOrigin?.y ?? window.frame.minY)
        ))
        mainDragGroupWindows.removeAll()
        mainDragWindowOffsets.removeAll()
        mainDragLastOrigin = nil
        schedulePersistentStateSave()
    }

    /// Starts a main-window gesture.  Determine the full connected component
    /// before the first movement, since after the player has moved even one
    /// pixel its neighbours no longer touch it.
    func beginMainWindowDrag() {
        // EQ has a persistent docking relationship with the player.  Do not
        // infer it solely from frame contact: after interface scaling AppKit
        // can leave a sub-pixel gap even though the windows are still docked.
        let dockedEqualizer = isEqualizerDocked && equalizerState.isVisible ? equalizerWindow : nil
        let candidates = ([equalizerWindow, infoWindow].compactMap { $0 } + playlistWindows.values)
            .filter { candidate in dockedEqualizer.map { candidate !== $0 } ?? true }
        var group: [NSWindow] = [window]
        if let dockedEqualizer { group.append(dockedEqualizer) }
        var remaining = candidates.filter { $0.isVisible }
        var expanded = true
        while expanded {
            expanded = false
            for candidate in remaining where group.contains(where: { windowsAreDocked($0, candidate) }) {
                group.append(candidate)
                expanded = true
            }
            if expanded {
                let groupIDs = Set(group.map(ObjectIdentifier.init))
                remaining.removeAll { groupIDs.contains(ObjectIdentifier($0)) }
            }
        }
        mainDragGroupWindows = group.filter { $0 !== window }
        mainDragWindowOffsets = Dictionary(uniqueKeysWithValues: mainDragGroupWindows.map {
            (ObjectIdentifier($0), NSPoint(x: $0.frame.minX - window.frame.minX, y: $0.frame.minY - window.frame.minY))
        })
        mainDragLastOrigin = window.frame.origin
    }

    /// Moves every playlist/EQ attached to the player by the same delta.  The
    /// model frame is updated immediately, so its persisted position matches
    /// what the user sees even before the drag finishes.
    func moveAttachedWindowsWithMain() {
        guard mainDragLastOrigin != nil else { return }
        // Position from the original relative coordinates, instead of adding
        // successive deltas.  AppKit may coalesce drag events, so deltas can
        // be observed after the main frame has already been redrawn.
        for panel in mainDragGroupWindows {
            guard let offset = mainDragWindowOffsets[ObjectIdentifier(panel)] else { continue }
            panel.setFrameOrigin(NSPoint(x: window.frame.minX + offset.x, y: window.frame.minY + offset.y))
            if let id = playlistWindows.first(where: { $0.value === panel })?.key,
               let model = playlistManager.playlist(id: id) {
                model.windowFrame = panel.frame
            }
        }
        mainDragLastOrigin = window.frame.origin
    }

    private func moveMainDragGroup(by delta: NSPoint) {
        guard delta != .zero else { return }
        for panel in mainDragGroupWindows {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y))
            if let id = playlistWindows.first(where: { $0.value === panel })?.key,
               let model = playlistManager.playlist(id: id) {
                model.windowFrame = panel.frame
            }
        }
    }

    /// Called for every drag event, rather than only on mouse-up, so the
    /// attraction is visible while the user is moving a skin window.
    func magnetWindowWhileDragging(_ movingWindow: NSWindow) {
        let allPlaylistWindows = playlistWindows.values.filter { $0 !== movingWindow }
        let visibleInfo = infoWindow?.isVisible == true && infoWindow !== movingWindow ? [infoWindow!] : []
        if movingWindow === window {
            let group = Set(mainDragGroupWindows.map(ObjectIdentifier.init))
            magnet(movingWindow, against: ([equalizerWindow].compactMap { $0 } + visibleInfo + allPlaylistWindows)
                .filter { !group.contains(ObjectIdentifier($0)) })
            moveAttachedWindowsWithMain()
            magnetMainDragGroupToScreen()
        } else if movingWindow === equalizerWindow {
            magnet(movingWindow, against: [window].compactMap { $0 } + visibleInfo + allPlaylistWindows)
        } else {
            magnet(movingWindow, against: [window, equalizerWindow].compactMap { $0 } + visibleInfo + allPlaylistWindows)
        }
    }

    /// Snaps a window to a screen edge or to a touching edge of another player
    /// panel. Existing EQ/playlist docking remains responsible for group moves.
    private func magnet(_ movingWindow: NSWindow, against neighbours: [NSWindow]) {
        let threshold: CGFloat = 12
        var frame = movingWindow.frame
        for neighbour in neighbours {
            let other = neighbour.frame
            // Snap to a neighbouring playlist even while the windows have not
            // started overlapping yet.  The old overlap-only branch made two
            // vertically offset editors feel like they had no magnetism.
            let verticallyClose = frame.maxY >= other.minY - threshold && frame.minY <= other.maxY + threshold
            let horizontallyClose = frame.maxX >= other.minX - threshold && frame.minX <= other.maxX + threshold
            if verticallyClose {
                if abs(frame.minX - other.maxX) <= threshold { frame.origin.x = other.maxX }
                if abs(frame.maxX - other.minX) <= threshold { frame.origin.x = other.minX - frame.width }
            }
            if horizontallyClose {
                if abs(frame.minY - other.maxY) <= threshold { frame.origin.y = other.maxY }
                if abs(frame.maxY - other.minY) <= threshold { frame.origin.y = other.minY - frame.height }
            }
            // Side-by-side windows also align to a common top or bottom edge.
            if abs(frame.maxY - other.maxY) <= threshold { frame.origin.y = other.maxY - frame.height }
            if abs(frame.minY - other.minY) <= threshold { frame.origin.y = other.minY }
            // Stacked windows also align to a common left or right edge.
            if abs(frame.minX - other.minX) <= threshold { frame.origin.x = other.minX }
            if abs(frame.maxX - other.maxX) <= threshold { frame.origin.x = other.maxX - frame.width }
            if frame.maxY > other.minY && frame.minY < other.maxY {
                if abs(frame.minX - other.maxX) <= threshold { frame.origin.x = other.maxX }
                if abs(frame.maxX - other.minX) <= threshold { frame.origin.x = other.minX - frame.width }
            }
            if frame.maxX > other.minX && frame.minX < other.maxX {
                if abs(frame.minY - other.maxY) <= threshold { frame.origin.y = other.maxY }
                if abs(frame.maxY - other.minY) <= threshold { frame.origin.y = other.minY - frame.height }
            }
        }
        // Screen edges have the final priority over window-to-window alignment.
        let screen = screenFrame(containing: frame) ?? NSScreen.main?.visibleFrame
        if let screen {
            if abs(frame.minX - screen.minX) <= threshold { frame.origin.x = screen.minX }
            if abs(frame.maxX - screen.maxX) <= threshold { frame.origin.x = screen.maxX - frame.width }
            if abs(frame.minY - screen.minY) <= threshold { frame.origin.y = screen.minY }
            if abs(frame.maxY - screen.maxY) <= threshold { frame.origin.y = screen.maxY - frame.height }
        }
        movingWindow.setFrameOrigin(frame.origin)
    }

    private func magnetDockedGroupToScreen() {
        var groupFrame = window.frame
        if isEqualizerDocked, let equalizerWindow { groupFrame = groupFrame.union(equalizerWindow.frame) }
        if isPlaylistDocked, let playlistWindow { groupFrame = groupFrame.union(playlistWindow.frame) }
        guard let screen = screenFrame(containing: window.frame) ?? NSScreen.main?.visibleFrame else { return }
        let threshold: CGFloat = 12
        var delta = NSPoint.zero
        if abs(groupFrame.minX - screen.minX) <= threshold { delta.x = screen.minX - groupFrame.minX }
        if abs(groupFrame.maxX - screen.maxX) <= threshold { delta.x = screen.maxX - groupFrame.maxX }
        if abs(groupFrame.minY - screen.minY) <= threshold { delta.y = screen.minY - groupFrame.minY }
        if abs(groupFrame.maxY - screen.maxY) <= threshold { delta.y = screen.maxY - groupFrame.maxY }
        guard delta != .zero else { return }
        window.setFrameOrigin(NSPoint(x: window.frame.minX + delta.x, y: window.frame.minY + delta.y))
        moveDockedEqualizer()
        moveDockedPlaylist()
    }

    private func magnetMainDragGroupToScreen() {
        var groupFrame = window.frame
        for panel in mainDragGroupWindows { groupFrame = groupFrame.union(panel.frame) }
        guard let screen = screenFrame(containing: window.frame) ?? NSScreen.main?.visibleFrame else { return }
        let threshold: CGFloat = 12
        var delta = NSPoint.zero
        if abs(groupFrame.minX - screen.minX) <= threshold { delta.x = screen.minX - groupFrame.minX }
        if abs(groupFrame.maxX - screen.maxX) <= threshold { delta.x = screen.maxX - groupFrame.maxX }
        if abs(groupFrame.minY - screen.minY) <= threshold { delta.y = screen.minY - groupFrame.minY }
        if abs(groupFrame.maxY - screen.maxY) <= threshold { delta.y = screen.maxY - groupFrame.maxY }
        guard delta != .zero else { return }
        window.setFrameOrigin(NSPoint(x: window.frame.minX + delta.x, y: window.frame.minY + delta.y))
        moveMainDragGroup(by: delta)
        mainDragLastOrigin = window.frame.origin
    }

    private func screenFrame(containing frame: NSRect) -> NSRect? {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(centre) })?.visibleFrame
    }

    private func isMagneticallyAttached(_ frame: NSRect, to other: NSRect) -> Bool {
        let epsilon: CGFloat = 0.5
        return abs(frame.minX - other.minX) <= epsilon || abs(frame.maxX - other.maxX) <= epsilon ||
            abs(frame.minX - other.maxX) <= epsilon || abs(frame.maxX - other.minX) <= epsilon ||
            abs(frame.minY - other.minY) <= epsilon || abs(frame.maxY - other.maxY) <= epsilon ||
            abs(frame.minY - other.maxY) <= epsilon || abs(frame.maxY - other.minY) <= epsilon
    }

    private func windowsAreDocked(_ first: NSWindow, _ second: NSWindow) -> Bool {
        let a = first.frame, b = second.frame
        let epsilon: CGFloat = 1
        let verticalContact = a.maxY >= b.minY - epsilon && a.minY <= b.maxY + epsilon
        let horizontalContact = a.maxX >= b.minX - epsilon && a.minX <= b.maxX + epsilon
        return (verticalContact && (abs(a.minX - b.maxX) <= epsilon || abs(a.maxX - b.minX) <= epsilon)) ||
            (horizontalContact && (abs(a.minY - b.maxY) <= epsilon || abs(a.maxY - b.minY) <= epsilon))
    }

    @objc func toggleEqualizerWindowShade(_ sender: Any?) {
        equalizerShade.isEnabled.toggle()
        applyInterfaceScale()
    }

    private func dockEqualizerBelowPlayer() {
        guard let equalizerWindow else { return }
        let size = equalizerWindow.frame.size
        isRepositioningEqualizer = true
        equalizerWindow.setFrameOrigin(NSPoint(x: window.frame.minX, y: window.frame.minY - size.height))
        equalizerDockOffset = NSPoint(x: equalizerWindow.frame.minX - window.frame.minX, y: equalizerWindow.frame.minY - window.frame.minY)
        isRepositioningEqualizer = false
        isEqualizerDocked = true
    }

    private func moveDockedEqualizer() {
        guard isEqualizerDocked, equalizerState.isVisible else { return }
        isRepositioningEqualizer = true
        equalizerWindow?.setFrameOrigin(NSPoint(x: window.frame.minX + equalizerDockOffset.x, y: window.frame.minY + equalizerDockOffset.y))
        isRepositioningEqualizer = false
    }

    private func snapEqualizerIfNeeded() {
        guard let equalizerWindow else { return }
        let expected = NSPoint(x: window.frame.minX, y: window.frame.minY - equalizerWindow.frame.height)
        let delta = hypot(equalizerWindow.frame.minX - expected.x, equalizerWindow.frame.minY - expected.y)
        isEqualizerDocked = delta <= 12
        if isEqualizerDocked {
            isRepositioningEqualizer = true
            equalizerWindow.setFrameOrigin(expected)
            isRepositioningEqualizer = false
        }
    }

    private func updateEqualizerDocking() {
        guard let equalizerWindow else { return }
        isEqualizerDocked = isMagneticallyAttached(equalizerWindow.frame, to: window.frame)
        if isEqualizerDocked { equalizerDockOffset = NSPoint(x: equalizerWindow.frame.minX - window.frame.minX, y: equalizerWindow.frame.minY - window.frame.minY) }
    }

    @objc func terminateApplication(_ sender: Any?) {
        playback.stop()
        isExplicitTerminationRequested = true
        NSApp.terminate(sender)
    }


}

/// Kept outside PlaylistView so playback's frequent position publications
/// redraw only this 90 px status field, never the full playlist editor.
private struct PlaylistStatusField: View {
    @ObservedObject var skin: WinampSkinStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var manager: PlaylistManager
    @ObservedObject var playlist: PlaylistModel

    var body: some View {
        let colors = skin.playlistColors()
        let counter = manager.statusCounter(for: playlist)
        let counterWidth = CGFloat((counter?.count ?? 0) * 5)
        let indicator: String = {
            guard manager.activePlaylistID == playlist.id else { return "" }
            if playback.isPlaying { return "▶" }
            if playback.isPaused { return "⏸" }
            return manager.playingEntryID == nil ? "" : "■"
        }()
        let color = colors.normalText.usingColorSpace(.deviceRGB) ?? colors.normalText
        return HStack(spacing: 2) {
            if playlist.scannerState == .idle, !indicator.isEmpty { Text(indicator) }
            Text(manager.statusText(for: playlist, playbackIndicator: nil))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let counter,
               let glyphs = skin.playlistWindowShadeGlyphTextImage(counter, width: Int(counterWidth), rightAligned: false) {
                Image(nsImage: glyphs).interpolation(.none).frame(width: counterWidth, height: 6)
            }
        }
        .font(.system(size: 7, weight: .regular, design: .monospaced))
        .foregroundColor(Color(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct SettingsView: View {
    @ObservedObject var interfaceScale: InterfaceScale
    @ObservedObject var timeDisplayPreference: TimeDisplayPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Interface")
                .font(.headline)
            HStack {
                Text("Scale")
                Slider(value: $interfaceScale.percent, in: 100...300, step: 10)
                Text("\(Int(interfaceScale.percent))%")
                    .frame(width: 38, alignment: .trailing)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle("Show remaining time", isOn: $timeDisplayPreference.showsRemainingTime)
        }
        .padding(20)
        .frame(width: 300, height: 172, alignment: .topLeading)
    }
}

/// Classic Playlist Editor rendered from `PLEDIT.BMP`, backed by a persistent
/// PlaylistModel and its independent window context.
private struct PlaylistView: View {
    @StateObject private var skin = WinampSkinStore()
    @ObservedObject var interfaceScale: InterfaceScale
    @ObservedObject var focus: PlaylistFocusState
    @ObservedObject var shade: PlaylistShadeState
    @ObservedObject var layout: PlaylistLayout
    // Playback position changes several times per second. The large editor
    // must not observe it directly, otherwise SwiftUI rebuilds every lazy row
    // and the skinned background for each time tick.
    let playback: PlaybackController
    @ObservedObject var timeDisplayPreference: TimeDisplayPreference
    @ObservedObject var manager: PlaylistManager
    @ObservedObject var playlist: PlaylistModel

    var body: some View {
        Group {
            if shade.isEnabled {
                playlistWindowShade
            } else {
                playlistEditor
            }
        }
        .scaleEffect(CGFloat(interfaceScale.factor), anchor: .topLeading)
        .frame(width: layout.width * CGFloat(interfaceScale.factor), height: (shade.isEnabled ? 14 : layout.height) * CGFloat(interfaceScale.factor), alignment: .topLeading)
    }

    private var playlistEditor: some View {
        ZStack(alignment: .topLeading) {
            if let image = skin.playlistEditorImage(width: Int(layout.width), height: Int(layout.height), isActive: focus.isKey) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.black
            }
            PlaylistDragArea(cursor: skin.cursor(named: "TITLEBAR.CUR"), onEnded: onDragEnded, onDoubleClick: onToggleShade)
                .frame(width: max(1, layout.width - 30), height: 14)
                .position(x: (layout.width - 30) / 2, y: 7)
            // Winamp's coordinates are left edges: width−20 and width−11.
            // SwiftUI's `position` is the centre of this 9 px control.
            playlistTitleButton(close: false, x: layout.width - 15.5, action: onToggleShade)
            playlistTitleButton(close: true, x: layout.width - 6.5, action: onClose)
            PlaylistResizeArea(cursor: skin.cursor(named: "PSIZE.CUR"), onResize: onResize)
                .frame(width: 20, height: 20)
                .position(x: layout.width - 10, y: layout.height - 10)
            playlistEntries
            playlistBottomControls
        }
        .frame(width: layout.width, height: layout.height)
    }

    private var playlistWindowShade: some View {
        // The resize grip occupies width−29...width−20.  End compact text at
        // width−31, leaving a two-pixel guard gap before that control.
        let compactLeft: CGFloat = 6
        let compactRight = max(compactLeft, layout.width - 31)
        let trackWidth = max(0, Int(compactRight - compactLeft))
        let isActivePlaylist = manager.activePlaylistID == playlist.id
        let current = playlist.entries.first { $0.id == manager.playingEntryID }
        let trackTitle = isActivePlaylist ? (current?.title ?? playlist.name) : playlist.name
        let compactDuration = isActivePlaylist ? (current?.duration ?? playback.duration) : playlist.totalDuration
        let hasTrack = isActivePlaylist ? compactDuration > 0 : !playlist.entries.isEmpty
        let colors = skin.playlistColors()
        let totalSeconds = max(0, Int(compactDuration.rounded(.down)))
        let inactiveSuffix = isActivePlaylist ? "" : "[\(playlist.entries.count)] \(formattedLongTime(playlist.totalDuration))"
        let durationTextWidth = isActivePlaylist && hasTrack
            ? (String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60).count + 2) * 5 : inactiveSuffix.count * 5
        // In WindowShade the playback state has one home: immediately before
        // the current title. The full editor shows that same state in its
        // lower status field instead of inside every list row.
        let compactIndicator = isActivePlaylist ? playbackIndicator : ""
        let indicatorWidth = compactIndicator.isEmpty ? 0 : 9
        let titleWidth = max(0, trackWidth - durationTextWidth - indicatorWidth - 4)
        return ZStack(alignment: .topLeading) {
            if let image = skin.playlistWindowShadeTitleImage(width: Int(layout.width), isActive: focus.isKey) {
                Image(nsImage: image).interpolation(.none)
            }
            if let track = skin.playlistWindowShadeTrackImage(
                time: compactDuration,
                showsTime: isActivePlaylist && hasTrack,
                width: trackWidth
            ) {
                Image(nsImage: track)
                    .interpolation(.none)
                    .frame(width: CGFloat(trackWidth), height: 6, alignment: .leading)
                    .position(x: compactLeft + CGFloat(trackWidth) / 2, y: 8)
            }
            if !isActivePlaylist,
               let statistics = skin.playlistWindowShadeGlyphTextImage(inactiveSuffix, width: trackWidth) {
                Image(nsImage: statistics)
                    .interpolation(.none)
                    .frame(width: CGFloat(trackWidth), height: 6, alignment: .leading)
                    .position(x: compactLeft + CGFloat(trackWidth) / 2, y: 8)
            }
            if !compactIndicator.isEmpty {
                Text(compactIndicator)
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .foregroundColor(playlistColor(colors.normalText))
                    .frame(width: CGFloat(indicatorWidth), height: 10, alignment: .leading)
                    .position(x: 8 + CGFloat(indicatorWidth) / 2, y: 8)
            }
            Text(trackTitle.uppercased())
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(playlistColor(colors.normalText))
                .frame(width: CGFloat(titleWidth), height: 10, alignment: .leading)
                .position(x: 8 + CGFloat(indicatorWidth) + CGFloat(titleWidth) / 2, y: 8)
            PlaylistDragArea(cursor: skin.cursor(named: "TITLEBAR.CUR"), onEnded: onDragEnded, onDoubleClick: onToggleShade)
                .frame(width: max(1, layout.width - 30), height: 14)
                .position(x: (layout.width - 30) / 2, y: 7)
            PlaylistWindowShadeResizeArea(cursor: skin.cursor(named: "PWSIZE.CUR") ?? .resizeLeftRight, onResize: onShadeResize)
                .frame(width: 9, height: 9)
                .position(x: layout.width - 24.5, y: 7.5)
            playlistTitleButton(close: false, x: layout.width - 15.5, action: onToggleShade)
            playlistTitleButton(close: true, x: layout.width - 6.5, action: onClose)
        }
        .frame(width: layout.width, height: 14)
    }

    let onClose: () -> Void
    let onToggleShade: () -> Void
    let onDragEnded: () -> Void
    let onResize: (CGFloat, CGFloat) -> Void
    let onShadeResize: (CGFloat) -> Void

    private func playlistTitleButton(close: Bool, x: CGFloat, action: @escaping () -> Void) -> some View {
        SkinTitleControlHotspot(
            normalImage: skin.playlistTitleControlImage(windowShade: shade.isEnabled, close: close, pressed: false),
            pressedImage: skin.playlistTitleControlImage(windowShade: shade.isEnabled, close: close, pressed: true),
            action: action
        )
        .frame(width: 9, height: 9)
        .position(x: x, y: 7)
    }

    private var playlistBottomControls: some View {
        ZStack(alignment: .topLeading) {
            playlistMenuHotspot(x: 25, index: 0, titles: ["Add Files…", "Add Folder…", "Add URL…"])
            playlistMenuHotspot(x: 54, index: 1, titles: ["Remove Selected", "Crop", "Clear Playlist", "Remove: Other…"])
            playlistMenuHotspot(x: 83, index: 2, titles: ["Select All", "Select None", "Invert Selection"])
            playlistMenuHotspot(x: 112, index: 3, titles: ["File Info", "Sort…", "Misc…"])
            playlistMenuHotspot(x: layout.width - 33, index: 4, titles: ["New Playlist", "Load Playlist…", "Save Playlist As…", "Clear Playlist"])

            PlaylistStatusField(skin: skin, playback: playback, manager: manager, playlist: playlist)
                .frame(width: 90, height: 8, alignment: .leading)
                .position(x: layout.width - 98, y: layout.height - 25)

            playlistTransportStrip
            playlistTimeDisplay
        }
    }

    private var playbackIndicator: String {
        guard manager.activePlaylistID == playlist.id else { return "" }
        if playback.isPlaying { return "▶" }
        if playback.isPaused { return "⏸" }
        return manager.playingEntryID == nil ? "" : "■"
    }

    private var playlistEntries: some View {
        let colors = skin.playlistColors()
        // Read the token so completed metadata becomes visible without having
        // to replace the higher-priority Loading/Adding status text.
        _ = playlist.metadataRevision
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(playlist.entries.indices, id: \.self) { index in
                        let entry = playlist.entries[index]
                        Button(action: { playlist.selectedIDs = [entry.id]; AppDelegate.shared?.selectInfoTarget(entry) }) {
                            let isPlayingEntry = entry.id == manager.playingEntryID && manager.activePlaylistID == playlist.id
                            let isSelected = playlist.selectedIDs.contains(entry.id)
                            HStack(spacing: 3) {
                                // `Text` string interpolation is localised by
                                // SwiftUI and can insert a thousands separator
                                // (e.g. "1 000") for Int values. Playlist row
                                // numbers are identifiers, not quantities.
                                Text(verbatim: "\(index + 1). \(entry.title)").lineLimit(1)
                                Spacer(minLength: 2)
                                Text(entry.duration.map(formattedTime) ?? "--:--")
                            }
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            // draw_pe.cpp: bit 2 (current) selects the text
                            // colour; bit 1 (selection) selects only the row
                            // background.  A selected current entry is white
                            // on the skin's SelectedBG, never black or green.
                            .foregroundColor(playlistColor(isPlayingEntry ? colors.currentText : colors.normalText))
                            .padding(.horizontal, 2).frame(height: 13)
                            .background(playlistColor(isSelected ? colors.selectedBackground : colors.background))
                        }.buttonStyle(PlainButtonStyle())
                        // Classic PLEDIT selects on a single click.  Playback
                        // is an explicit double-click action, so browsing a
                        // large list never accidentally interrupts audio.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            AppDelegate.shared?.playPlaylistEntryFromSelection(entry, in: playlist)
                        })
                        .id(entry.id)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PlaylistScrollOffsetKey.self, value: proxy.frame(in: .named("playlistEntries")).minY)
                })
            }
            .coordinateSpace(name: "playlistEntries")
            .background(playlistColor(colors.background))
            // Classic draw_pe_vslide draws its 8 px lane at width−15…width−7.
            // The native scroller is wider, but its trailing edge must still
            // meet x = width−7; otherwise an empty black strip appears between
            // the thumb and the skin's right rail.
            .frame(width: max(1, layout.width - 19), height: max(1, layout.height - 58))
            .position(x: 12 + max(1, layout.width - 19) / 2, y: 20 + max(1, layout.height - 58) / 2)
            .onChange(of: manager.playbackRevealRevision) { _ in
                guard manager.activePlaylistID == playlist.id,
                      let id = manager.playingEntryID,
                      let index = playlist.entries.firstIndex(where: { $0.id == id }) else { return }
                let visible = playlist.scrollPosition..<min(playlist.entries.count, playlist.scrollPosition + playlist.visibleEntryCount)
                // Do not disturb a row the user can already see.  Deferring
                // one main-loop turn guarantees LazyVStack has materialised an
                // off-screen destination before ScrollViewReader resolves it.
                if !visible.contains(index) {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onAppear {
                let position = min(max(0, playlist.scrollPosition), max(0, playlist.entries.count - 1))
                guard playlist.entries.indices.contains(position) else { return }
                DispatchQueue.main.async { proxy.scrollTo(playlist.entries[position].id, anchor: .top) }
            }
            .onPreferenceChange(PlaylistScrollOffsetKey.self) { offset in
                let visibleRows = max(1, Int(ceil(max(1, layout.height - 58) / 13)))
                manager.visibleRangeChanged(
                    for: playlist,
                    firstEntry: Int(max(0, (-offset / 13).rounded(.down))),
                    visibleCount: visibleRows
                )
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        var isDirectory: ObjCBool = false
                        DispatchQueue.main.async {
                            if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
                                AppDelegate.shared?.openPlaylistURL(url)
                            } else if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { manager.addFolder(url, to: playlist) }
                            else { manager.addFiles([url], to: playlist) }
                        }
                    }
                }
                return true
            }
        }
    }

    private func playlistColor(_ color: NSColor) -> Color {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Color(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    private var playlistTransportStrip: some View {
        ZStack(alignment: .topLeading) {
            playlistTransportButton(index: 0, x: 3.5, width: 7)
            playlistTransportButton(index: 1, x: 12, width: 10)
            playlistTransportButton(index: 2, x: 22, width: 10)
            playlistTransportButton(index: 3, x: 31.5, width: 9)
            playlistTransportButton(index: 4, x: 40.5, width: 9)
            playlistTransportButton(index: 5, x: 49, width: 8)
        }
        .frame(width: 53, height: 7)
        .position(x: layout.width - 117.5, y: layout.height - 11.5)
    }

    private func playlistTransportButton(index: Int, x: CGFloat, width: CGFloat) -> some View {
        PlaylistTransportHotspot(index: index)
            .frame(width: width, height: 7)
            .position(x: x, y: 3.5)
    }

    private var playlistTimeDisplay: some View {
        let wholeSeconds = max(0, Int(playlist.totalDuration.rounded(.down)))
        let image = skin.playlistTimeImage(
            minutes: min(999, wholeSeconds / 60),
            seconds: wholeSeconds % 60,
            isRemaining: false
        )
        return Group {
            if let image {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
            // Exact original placement: (width - 86, height - 15), 32×6 px.
            .frame(width: 32, height: 6, alignment: .leading)
            .position(x: layout.width - 70, y: layout.height - 12)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", min(99, value / 60), value % 60)
    }

    private func formattedLongTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }

    private func playlistMenuHotspot(x: CGFloat, index: Int, titles: [String]) -> some View {
        PlaylistMenuHotspot(titles: titles, pressedImage: skin.playlistMenuButtonPressedImage(index: index))
            .frame(width: 22, height: 18)
            .position(x: x, y: layout.height - 21)
    }
}

private struct PlaylistScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// AppKit receives the original mouse-down event, which is required to open a
/// native popup menu. SwiftUI Button actions occur too late (on mouse-up).
private struct PlaylistMenuHotspot: NSViewRepresentable {
    let titles: [String]
    let pressedImage: NSImage?

    func makeNSView(context: Context) -> PlaylistMenuHotspotNSView {
        let view = PlaylistMenuHotspotNSView()
        view.titles = titles
        view.pressedImage = pressedImage
        return view
    }

    func updateNSView(_ nsView: PlaylistMenuHotspotNSView, context: Context) {
        nsView.titles = titles
        nsView.pressedImage = pressedImage
    }
}

private final class PlaylistMenuHotspotNSView: NSView {
    var titles: [String] = []
    var pressedImage: NSImage? { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPressed else { return }
        pressedImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard !titles.isEmpty else { return }
        isPressed = true
        displayIfNeeded()

        let menu = NSMenu()
        for title in titles {
            let item = NSMenuItem(title: title, action: #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isPressed = false
    }

    @objc private func selectMenuItem(_ sender: NSMenuItem) {
        switch sender.title {
        case "Add Files…": AppDelegate.shared?.addFilesToActivePlaylist()
        case "Add Folder…": AppDelegate.shared?.addFolderToActivePlaylist()
        case "Remove Selected": AppDelegate.shared?.removeSelectedFromActivePlaylist()
        case "Clear Playlist": AppDelegate.shared?.clearActivePlaylist()
        case "Crop": AppDelegate.shared?.cropActivePlaylist()
        case "Select All": AppDelegate.shared?.selectAllInActivePlaylist()
        case "Select None": AppDelegate.shared?.selectNoneInActivePlaylist()
        case "Invert Selection": AppDelegate.shared?.invertSelectionInActivePlaylist()
        case "New Playlist": AppDelegate.shared?.newPlaylist(nil)
        case "Load Playlist…": AppDelegate.shared?.openDocument(nil)
        case "Save Playlist As…": AppDelegate.shared?.savePlaylistAs(nil)
        default: break
        }
    }
}

private struct PlaylistTransportHotspot: NSViewRepresentable {
    let index: Int

    func makeNSView(context: Context) -> PlaylistTransportHotspotNSView {
        let view = PlaylistTransportHotspotNSView()
        view.index = index
        return view
    }

    func updateNSView(_ nsView: PlaylistTransportHotspotNSView, context: Context) {
        nsView.index = index
    }
}

private final class PlaylistTransportHotspotNSView: NSView {
    var index = 0
    private var isPressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPressed else { return }
        // Classic PLEDIT has no separate pressed frames for these 7 px controls.
        // A recessed overlay preserves the skin artwork while the mouse is held.
        NSColor.black.withAlphaComponent(0.48).setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: 0.5, y: 0.5))
        edge.line(to: NSPoint(x: bounds.width - 0.5, y: 0.5))
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        displayIfNeeded()
        var activate = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                activate = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        isPressed = false
        if activate { AppDelegate.shared?.playlistTransportAction(index) }
    }
}

private struct PlaylistDragArea: NSViewRepresentable {
    let cursor: NSCursor?
    let onEnded: () -> Void
    let onDoubleClick: () -> Void
    func makeNSView(context: Context) -> PlaylistDragNSView {
        let view = PlaylistDragNSView()
        view.dragCursor = cursor
        view.onEnded = onEnded; view.onDoubleClick = onDoubleClick
        return view
    }
    func updateNSView(_ nsView: PlaylistDragNSView, context: Context) {
        nsView.dragCursor = cursor
        nsView.onEnded = onEnded; nsView.onDoubleClick = onDoubleClick
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// Shows an explicit wait cursor while a newly opened playlist is still being
/// parsed on the background queue.  It covers only an empty list, where there
/// are no rows to interact with, so AppKit can reliably own the cursor rect.
private struct PlaylistLoadingCursorArea: NSViewRepresentable {
    let isLoading: Bool

    func makeNSView(context: Context) -> PlaylistLoadingCursorNSView {
        let view = PlaylistLoadingCursorNSView()
        view.isLoading = isLoading
        return view
    }

    func updateNSView(_ nsView: PlaylistLoadingCursorNSView, context: Context) {
        guard nsView.isLoading != isLoading else { return }
        nsView.isLoading = isLoading
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class PlaylistLoadingCursorNSView: NSView {
    var isLoading = false
    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        // Explicitly transparent: SwiftUI otherwise composites a bare NSView
        // as an opaque black rectangle in this layered window.
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        dirtyRect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    override func resetCursorRects() {
        guard isLoading else { return }
        addCursorRect(bounds, cursor: SkinCursors.wait)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isLoading { SkinCursors.wait.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseEntered(with event: NSEvent) {
        if isLoading { SkinCursors.wait.set() }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

}

private final class PlaylistDragNSView: NSView {
    var dragCursor: NSCursor?
    var onEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragCursor ?? SkinCursors.move)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        let origin = window.frame.origin
        let start = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            AppDelegate.shared?.magnetWindowWhileDragging(window)
        }
        onEnded?()
    }
}

private struct PlaylistResizeArea: NSViewRepresentable {
    let cursor: NSCursor?
    let onResize: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> PlaylistResizeNSView {
        let view = PlaylistResizeNSView()
        view.resizeCursor = cursor
        view.onResize = onResize
        return view
    }
    func updateNSView(_ nsView: PlaylistResizeNSView, context: Context) {
        nsView.resizeCursor = cursor
        nsView.onResize = onResize
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class PlaylistResizeNSView: NSView {
    var resizeCursor: NSCursor?
    var onResize: ((CGFloat, CGFloat) -> Void)?
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor ?? SkinCursors.resizeNorthwestSoutheast)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initialFrame = window.frame
        let start = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            let scale = CGFloat(AppDelegate.shared?.currentInterfaceScale ?? 1)
            let logicalWidth = (initialFrame.width + point.x - start.x) / scale
            // AppKit grows a bottom-right drag downward by lowering the origin.
            let logicalHeight = (initialFrame.height - (point.y - start.y)) / scale
            onResize?(logicalWidth, logicalHeight)
        }
    }
}

/// The compact Playlist Editor has a dedicated horizontal-only resize grip at
/// x = width−29…width−20. Classic skins may supply `PWSIZE.CUR` for it.
private struct PlaylistWindowShadeResizeArea: NSViewRepresentable {
    let cursor: NSCursor
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> PlaylistWindowShadeResizeNSView {
        let view = PlaylistWindowShadeResizeNSView()
        view.resizeCursor = cursor
        view.onResize = onResize
        return view
    }

    func updateNSView(_ nsView: PlaylistWindowShadeResizeNSView, context: Context) {
        nsView.resizeCursor = cursor
        nsView.onResize = onResize
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class PlaylistWindowShadeResizeNSView: NSView {
    var resizeCursor: NSCursor = .resizeLeftRight
    var onResize: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initialFrame = window.frame
        let start = NSEvent.mouseLocation
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            let scale = CGFloat(AppDelegate.shared?.currentInterfaceScale ?? 1)
            let logicalWidth = (initialFrame.width + point.x - start.x) / scale
            onResize?(logicalWidth)
        }
    }
}

private struct EqualizerView: View {
    @StateObject private var skin = WinampSkinStore()
    @ObservedObject var interfaceScale: InterfaceScale
    @ObservedObject var focus: EqualizerFocusState
    @ObservedObject var shade: EqualizerShadeState
    @ObservedObject var playback: PlaybackController
    @ObservedObject var equalizer: EqualizerController
    @State private var activeSlider: Int?
    @State private var pressedEqualizerButton: Int?
    @State private var isPresetPressed = false

    var body: some View {
        Group {
            if shade.isEnabled {
                ZStack {
                    equalizerTitleBar(windowShade: true)
                    equalizerWindowShadeVolume
                    equalizerWindowShadeBalance
                }
                .frame(width: 275, height: 14)
            } else {
                ZStack(alignment: .topLeading) {
                    if let image = skin.equalizerBaseImage() {
                        Image(nsImage: image).interpolation(.none)
                    } else {
                        Color.black
                    }
                    equalizerTitleBar(windowShade: false)
                    equalizerGraph
                    equalizerToggleButtons
                    presetButton
                    quickButton(y: 37, value: 0)
                    quickButton(y: 69, value: 0.5)
                    quickButton(y: 96, value: 1)
                    equalizerSlider(index: 0, x: 21, db: equalizer.preamp)
                    ForEach(0..<10, id: \.self) { index in
                        equalizerSlider(index: index + 1, x: 78 + CGFloat(index * 18), db: equalizer.bands[index])
                    }
                }
                .frame(width: 275, height: 116)
            }
        }
        .scaleEffect(CGFloat(interfaceScale.factor), anchor: .topLeading)
        .frame(width: 275 * CGFloat(interfaceScale.factor), height: (shade.isEnabled ? 14 : 116) * CGFloat(interfaceScale.factor), alignment: .topLeading)
    }

    private func equalizerTitleBar(windowShade: Bool) -> some View {
        ZStack {
            if let title = windowShade
                ? skin.equalizerWindowShadeTitleImage(isActive: focus.isKey)
                : skin.equalizerTitleBarImage(isActive: focus.isKey) {
                Image(nsImage: title).interpolation(.none)
            }
            EqualizerDragArea(cursor: skin.cursor(named: "EQTITLE.CUR") ?? skin.cursor(named: "TITLEBAR.CUR"))
                .frame(width: 245, height: 14).position(x: 126.5, y: 7)
            equalizerTitleButton(.windowShade, x: 257.5, windowShade: windowShade) { AppDelegate.shared?.toggleEqualizerWindowShade(nil) }
            equalizerTitleButton(.close, x: 268.5, windowShade: windowShade) { AppDelegate.shared?.hideEqualizer(nil) }
        }
        .frame(width: 275, height: 14)
        .position(x: 137.5, y: 7)
    }

    private func equalizerTitleButton(
        _ control: WinampSkinStore.EqualizerTitleControl,
        x: CGFloat,
        windowShade: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SkinTitleControlHotspot(
            normalImage: skin.equalizerTitleControlImage(control, windowShade: windowShade, pressed: false),
            pressedImage: skin.equalizerTitleControlImage(control, windowShade: windowShade, pressed: true),
            action: action
        )
            .frame(width: 9, height: 9)
            .position(x: x, y: 7.5)
    }

    private var equalizerWindowShadeVolume: some View {
        ZStack {
            if let image = skin.equalizerWindowShadeThumb(isVolume: true, value: playback.volume) {
                Image(nsImage: image).interpolation(.none)
                    .position(x: 1.5 + CGFloat(playback.volume) * 94, y: 4.5)
            }
            Color.clear
                .frame(width: 101, height: 9)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in playback.volume = min(1, max(0, Double(value.location.x / 96))) }
                    .onEnded { value in playback.volume = min(1, max(0, Double(value.location.x / 96))) })
        }
        .frame(width: 101, height: 9)
        .position(x: 111.5, y: 7.5)
    }

    private var equalizerWindowShadeBalance: some View {
        ZStack {
            let normalized = (playback.balance + 1) / 2
            if let image = skin.equalizerWindowShadeThumb(isVolume: false, value: normalized) {
                Image(nsImage: image).interpolation(.none)
                    .position(x: 2.5 + CGFloat(normalized) * 39, y: 4.5)
            }
            Color.clear
                .frame(width: 43, height: 9)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in setWindowShadeBalance(value.location.x) }
                    .onEnded { value in setWindowShadeBalance(value.location.x) })
        }
        .frame(width: 43, height: 9)
        .position(x: 184.5, y: 7.5)
    }

    private func setWindowShadeBalance(_ location: CGFloat) {
        let balance = min(1, max(-1, Double(location / 42) * 2 - 1))
        playback.balance = abs(balance) <= 0.12 ? 0 : balance
    }

    private var equalizerGraph: some View {
        ZStack {
            EqualizerCurveShape(values: equalizer.bands.map(normalized))
                .stroke(Color(red: 1, green: 0.72, blue: 0.12), lineWidth: 1)
            Path { path in
                let y = (1 - CGFloat(normalized(equalizer.preamp))) * 18 + 0.5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: 113, y: y))
            }
            .stroke(Color(red: 0.95, green: 0.92, blue: 0.35), lineWidth: 1)
        }
        .frame(width: 113, height: 19)
        .clipped()
        .position(x: 142.5, y: 26.5)
    }

    private var equalizerToggleButtons: some View {
        Group {
            if let image = skin.equalizerOnAutoImage(
                on: equalizer.isEnabled,
                auto: equalizer.isAdaptiveEnabled,
                onPressed: pressedEqualizerButton == 0,
                autoPressed: pressedEqualizerButton == 1
            ) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 58, height: 12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                pressedEqualizerButton = value.location.x < 25 ? 0 : 1
            }
            .onEnded { value in
                let pressed = pressedEqualizerButton
                pressedEqualizerButton = nil
                guard pressed == (value.location.x < 25 ? 0 : 1) else { return }
                if pressed == 0 { equalizer.isEnabled.toggle() }
                else {
                    equalizer.isAdaptiveEnabled.toggle()
                    if !equalizer.isAdaptiveEnabled { equalizer.disableAdaptiveCorrection() }
                }
            })
        .position(x: 43, y: 24)
    }

    private var presetButton: some View {
        Group {
            if let image = skin.equalizerPresetsImage(pressed: isPresetPressed) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 44, height: 12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPresetPressed = true }
            .onEnded { value in
                isPresetPressed = false
                showPresetMenu(at: value.location)
            })
        .position(x: 239, y: 24)
    }

    private func quickButton(y: CGFloat, value: Double) -> some View {
        Button(action: { equalizer.setAllBands((value - 0.5) * 40) }) { Color.clear.frame(width: 25, height: 10) }
            .buttonStyle(PlainButtonStyle())
            .position(x: 54.5, y: y)
    }

    private func equalizerSlider(index: Int, x: CGFloat, db: Double) -> some View {
        Group {
            if let image = skin.equalizerSliderImage(
                position: Int((normalized(db) * 63).rounded()),
                pressed: activeSlider == index
            ) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
            .frame(width: 14, height: 63)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    activeSlider = index
                    let newDB = (1 - Double(gesture.location.y / 63)) * 40 - 20
                    if index == 0 { equalizer.setPreamp(newDB) }
                    else { equalizer.setBand(index - 1, db: newDB) }
                }
                .onEnded { _ in activeSlider = nil })
            .position(x: x + 7, y: 69.5)
    }

    private func normalized(_ db: Double) -> Double { min(1, max(0, (db + 20) / 40)) }

    private func showPresetMenu(at location: CGPoint) {
        let menu = NSMenu()
        for preset in EqualizerController.factoryPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(EqualizerPresetMenuTarget.loadPreset(_:)), keyEquivalent: "")
            item.target = EqualizerPresetMenuTarget.shared
            item.representedObject = PresetSelection(equalizer: equalizer, preset: preset)
            item.state = preset.name == equalizer.selectedPresetName ? .on : .off
            menu.addItem(item)
        }
        if !equalizer.userPresets.isEmpty {
            menu.addItem(.separator())
            for preset in equalizer.userPresets {
                let item = NSMenuItem(title: "User: \(preset.name)", action: #selector(EqualizerPresetMenuTarget.loadPreset(_:)), keyEquivalent: "")
                item.target = EqualizerPresetMenuTarget.shared
                item.representedObject = PresetSelection(equalizer: equalizer, preset: preset)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save current preset…", action: #selector(EqualizerPresetMenuTarget.savePreset(_:)), keyEquivalent: "")
        save.target = EqualizerPresetMenuTarget.shared
        save.representedObject = equalizer
        menu.addItem(save)
        if !equalizer.userPresets.isEmpty {
            let deleteMenu = NSMenu(title: "Delete user preset")
            for preset in equalizer.userPresets {
                let item = NSMenuItem(title: preset.name, action: #selector(EqualizerPresetMenuTarget.deletePreset(_:)), keyEquivalent: "")
                item.target = EqualizerPresetMenuTarget.shared
                item.representedObject = PresetSelection(equalizer: equalizer, preset: preset)
                deleteMenu.addItem(item)
            }
            let delete = NSMenuItem(title: "Delete user preset", action: nil, keyEquivalent: "")
            delete.submenu = deleteMenu
            menu.addItem(delete)
        }
        let reset = NSMenuItem(title: "Reset", action: #selector(EqualizerPresetMenuTarget.reset(_:)), keyEquivalent: "")
        reset.target = EqualizerPresetMenuTarget.shared
        reset.representedObject = equalizer
        menu.addItem(reset)
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: NSApp.keyWindow?.contentView ?? NSView())
    }
}

private final class PresetSelection: NSObject {
    let equalizer: EqualizerController
    let preset: EqualizerPreset
    init(equalizer: EqualizerController, preset: EqualizerPreset) { self.equalizer = equalizer; self.preset = preset }
}

private final class EqualizerPresetMenuTarget: NSObject {
    static let shared = EqualizerPresetMenuTarget()
    @objc func loadPreset(_ sender: NSMenuItem) { (sender.representedObject as? PresetSelection).map { $0.equalizer.load($0.preset) } }
    @objc func reset(_ sender: NSMenuItem) { (sender.representedObject as? EqualizerController)?.reset() }
    @objc func deletePreset(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PresetSelection else { return }
        selection.equalizer.deleteUserPreset(named: selection.preset.name)
    }
    @objc func savePreset(_ sender: NSMenuItem) {
        guard let equalizer = sender.representedObject as? EqualizerController else { return }
        let alert = NSAlert()
        alert.messageText = "Save equalizer preset"
        alert.informativeText = "The preset stores Preamp and all 10 EQ bands."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: equalizer.selectedPresetName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { equalizer.saveCurrentPreset(named: field.stringValue) }
    }
}

private struct EqualizerDragArea: NSViewRepresentable {
    let cursor: NSCursor?
    func makeNSView(context: Context) -> EqualizerDragNSView {
        let view = EqualizerDragNSView()
        view.dragCursor = cursor
        return view
    }
    func updateNSView(_ nsView: EqualizerDragNSView, context: Context) {
        nsView.dragCursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private struct EqualizerTitleButtonStyle: ButtonStyle {
    let normalImage: NSImage?
    let pressedImage: NSImage?

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if let image = configuration.isPressed ? pressedImage : normalImage {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .contentShape(Rectangle())
    }
}

private final class EqualizerDragNSView: NSView {
    var dragCursor: NSCursor?
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragCursor ?? SkinCursors.move)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            AppDelegate.shared?.toggleEqualizerWindowShade(nil)
            return
        }
        guard let window else { return }
        let origin = window.frame.origin
        let start = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            AppDelegate.shared?.magnetWindowWhileDragging(window)
        }
        AppDelegate.shared?.equalizerDragEnded()
    }
}

private struct EqualizerCurveShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty else { return Path() }
        var path = Path()
        for index in values.indices {
            let x = rect.minX + CGFloat(index) * rect.width / CGFloat(max(1, values.count - 1))
            let y = rect.minY + (1 - CGFloat(min(1, max(0, values[index])))) * max(0, rect.height - 1)
            let point = CGPoint(x: x, y: y)
            if index == values.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
