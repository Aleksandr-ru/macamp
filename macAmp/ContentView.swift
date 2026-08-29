import AppKit
import Combine
import SwiftUI

private enum VisualizationMode: Int {
    case off
    case spectrum
    case oscilloscope

    mutating func advance() {
        self = VisualizationMode(rawValue: rawValue == VisualizationMode.oscilloscope.rawValue ? 0 : rawValue + 1) ?? .off
    }
}

struct ContentView: View {
    @StateObject private var skin = WinampSkinStore()
    @ObservedObject var playback: PlaybackController
    @ObservedObject var interfaceScale: InterfaceScale
    @ObservedObject var timeDisplayPreference: TimeDisplayPreference
    @ObservedObject var windowFocus: WindowFocusState
    @ObservedObject var windowShade: WindowShadeState
    @ObservedObject var equalizerState: EqualizerWindowState
    @ObservedObject var playlistState: PlaylistWindowState
    @ObservedObject var infoState: InfoWindowState
    @State private var isSeeking = false
    @State private var seekPreviewPosition: Double?
    @State private var isAdjustingVolume = false
    @State private var isAdjustingBalance = false
    @State private var isEqualizerPressed = false
    @State private var isPlaylistPressed = false
    @State private var pressedPlayerControl: WinampSkinStore.PlayerControl?
    @State private var isShufflePressed = false
    @State private var isRepeatPressed = false
    @State private var pressedClutterbarButton: Int?
    @State private var pressedWindowShadeControl: Int?
    @State private var visualizationMode: VisualizationMode = .spectrum

    var body: some View {
        Group {
            if windowShade.isEnabled {
                skinTitleBar
                    .frame(width: 275, height: 14)
            } else {
                mainPlayerContent
            }
        }
        .scaleEffect(CGFloat(interfaceScale.factor), anchor: .topLeading)
        .frame(width: 275 * CGFloat(interfaceScale.factor),
               height: (windowShade.isEnabled ? 14 : 116) * CGFloat(interfaceScale.factor),
               alignment: .topLeading)
        .onAppear { updateVisualizationDemand() }
        .onChange(of: visualizationMode) { _ in updateVisualizationDemand() }
    }

    private var mainPlayerContent: some View {
        ZStack(alignment: .topLeading) {
            if let main = skin.bitmap(named: "MAIN.BMP") {
                Image(nsImage: main).resizable().interpolation(.none)
            } else {
                Color(red: 0.12, green: 0.13, blue: 0.18)
            }
            skinTitleBar
            playbackIndicator
            timeDisplay
            spectrumAnalyzer
            visualizationModeButtons
            ticker
            bitrateIndicator
            sampleRateIndicator
            channelIndicator
            progressBar
            volumeBar
            balanceBar
            equalizerButton
            playlistButton
            shuffleButton
            repeatButton
            controls
        }
        .frame(width: 275, height: 116)
    }

    private func updateVisualizationDemand() {
        playback.setVisualization(
            enabled: visualizationMode != .off,
            waveform: visualizationMode == .oscilloscope
        )
    }

    private var skinTitleBar: some View {
        ZStack {
            if let image = skin.titleBarImage(isActive: windowFocus.isKey,
                                               isWindowShaded: windowShade.isEnabled) {
                Image(nsImage: image)
                    .interpolation(.none)
            }
            SkinWindowDragArea(cursor: skin.cursor(named: "TITLEBAR.CUR"))
                .frame(width: 210, height: 14)
                .position(x: 132, y: 7)
            titleBarControlButton(.minimize, x: 248.5, isWindowActive: windowFocus.isKey, action: { AppDelegate.shared?.hideMainPlayer(nil) })
            titleBarControlButton(.windowShade, x: 257.5, isWindowActive: windowFocus.isKey, action: { AppDelegate.shared?.toggleWindowShade(nil) })
            titleBarControlButton(.close, x: 266.5, isWindowActive: windowFocus.isKey, action: { AppDelegate.shared?.terminateApplication(nil) })
            if windowShade.isEnabled {
                windowShadeSpectrum
                windowShadeTime
                windowShadeTimeControl
                windowShadePosition
                windowShadePositionControl
                windowShadeControls
            }
        }
        .frame(width: 275, height: 14)
        .position(x: 137.5, y: 7)
    }

    private var windowShadeTime: some View {
        let total = timeDisplayPreference.showsRemainingTime && playback.duration > 0
            ? max(0, Int((playback.duration - playback.position).rounded(.down)))
            : max(0, Int(playback.position.rounded(.down)))
        let minutes = min(total / 60, 99)
        let seconds = total % 60
        let showsMinus = timeDisplayPreference.showsRemainingTime && playback.duration > 0

        return Group {
            if let image = skin.windowShadeTimeImage(minutes: minutes, seconds: seconds, isRemaining: showsMinus) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 32, height: 6, alignment: .leading)
        // draw_time() updates exactly the 125...157 px compact time field.
        .position(x: 141, y: 8)
    }

    /// Winamp toggles elapsed/remaining time from the compact display at x: 129...157, y: 3...9.
    private var windowShadeTimeControl: some View {
        Color.clear
            .frame(width: 28, height: 6)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                timeDisplayPreference.toggle()
            })
            .position(x: 143, y: 6)
    }

    /// Winamp's windowshade visualizer is a separate 38×5-pixel surface at x: 79, y: 5.
    private var windowShadeSpectrum: some View {
        visualizationView(isWindowShade: true)
        .frame(width: 38, height: 5)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded { visualizationMode.advance() })
        .position(x: 98, y: 7.5)
    }

    private var windowShadePosition: some View {
        let progress = playback.duration > 0 ? playback.position / playback.duration : 0
        return Group {
            if let image = skin.windowShadePositionImage(progress: progress) {
                Image(nsImage: image).interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 17, height: 7)
        .position(x: 234.5, y: 7.5)
    }

    /// The compact position bar is draggable in the original player.
    /// Its active portion excludes the two-pixel left border: x 228...242, y 3...12.
    private var windowShadePositionControl: some View {
        Color.clear
            .frame(width: 14, height: 9)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seekFromWindowShadePosition(value.location.x)
                    }
                    .onEnded { value in
                        seekFromWindowShadePosition(value.location.x)
                    }
            )
            .position(x: 235, y: 7.5)
    }

    private func seekFromWindowShadePosition(_ location: CGFloat) {
        guard playback.duration > 0 else { return }
        // Winamp maps 13 pixels of the compact slider onto the entire track.
        let fraction = min(1, max(0, Double(location / 13)))
        AppDelegate.shared?.seekPlayback(to: playback.duration * fraction)
    }

    private var windowShadeControls: some View {
        // Winamp uses one continuous 58 px button strip at x: 167...225, y: 3...12.
        // A single gesture keeps it above the title-bar drag area in windowshade mode.
        Color.clear
            .frame(width: 58, height: 9)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pressedWindowShadeControl = windowShadeControlIndex(at: value.location.x)
                    }
                    .onEnded { value in
                        let pressed = pressedWindowShadeControl
                        let released = windowShadeControlIndex(at: value.location.x)
                        pressedWindowShadeControl = nil
                        guard let pressed, pressed == released else { return }
                        performWindowShadeControl(pressed)
                    }
            )
            .position(x: 196, y: 7.5)
    }

    private func windowShadeControlIndex(at x: CGFloat) -> Int? {
        switch x {
        case 0..<9: return 0       // previous: x 167...176
        case 9..<19: return 1      // play:     x 176...186
        case 19..<28: return 2     // pause:    x 186...195
        case 28..<37: return 3     // stop:     x 195...204
        case 37..<48: return 4     // next:     x 204...215
        case 48..<58: return 5     // eject:    x 215...225
        default: return nil
        }
    }

    private func performWindowShadeControl(_ control: Int) {
        switch control {
        case 0: AppDelegate.shared?.playlistTransportAction(0)
        case 1: AppDelegate.shared?.playFromActivePlaylist()
        case 2: AppDelegate.shared?.pausePlayback()
        case 3: AppDelegate.shared?.stopPlayback()
        case 4: AppDelegate.shared?.playlistTransportAction(4)
        case 5: AppDelegate.shared?.chooseTracksForPlaybackPlaylist()
        default: break
        }
    }

    private func titleBarControlButton(
        _ control: WinampSkinStore.TitleBarControl,
        x: CGFloat,
        isWindowActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SkinTitleControlHotspot(
            normalImage: isWindowActive ? skin.titleBarControlImage(control, pressed: false) : nil,
            pressedImage: isWindowActive ? skin.titleBarControlImage(control, pressed: true) : nil,
            action: action
        )
        .frame(width: 9, height: 9)
        .position(x: x, y: 7)
    }
}

private struct SkinTitleBarButtonStyle: ButtonStyle {
    let normalImage: NSImage?
    let pressedImage: NSImage?

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if let image = configuration.isPressed ? pressedImage : normalImage {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .contentShape(Rectangle())
    }
}

extension ContentView {
    private var ticker: some View {
        TickerDisplay(
            skin: skin,
            playback: playback,
            isAdjustingVolume: isAdjustingVolume,
            isAdjustingBalance: isAdjustingBalance
        )
        .position(x: 188, y: 32)
    }

    private var progressBar: some View {
        let displayedPosition = seekPreviewPosition ?? playback.pendingSeekPosition ?? playback.position
        let fraction = playback.duration > 0
            ? min(1, max(0, displayedPosition / playback.duration))
            : 0

        return ZStack(alignment: .leading) {
            if let track = skin.positionBarTrack() {
                Image(nsImage: track)
                    .interpolation(.none)
            } else {
                Color.black
            }

            if let thumb = skin.positionBarThumb(pressed: isSeeking) {
                Image(nsImage: thumb)
                    .interpolation(.none)
                    .offset(x: CGFloat(fraction) * 219)
            }
        }
        .frame(width: 248, height: 10, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isSeeking = true
                    previewSeek(toProgressBarLocation: value.location.x)
                }
                .onEnded { value in
                    previewSeek(toProgressBarLocation: value.location.x)
                    if let preview = seekPreviewPosition {
                        AppDelegate.shared?.seekPlayback(to: preview)
                    }
                    // The playback controller retains this target until it
                    // receives a frame from the newly scheduled segment.
                    seekPreviewPosition = nil
                    isSeeking = false
                }
        )
        .position(x: 140, y: 77)
    }

    private func previewSeek(toProgressBarLocation location: CGFloat) {
        guard playback.duration > 0 else { return }
        let fraction = min(1, max(0, Double(location / 248)))
        seekPreviewPosition = playback.duration * fraction
    }

    private var volumeBar: some View {
        ZStack(alignment: .leading) {
            if let image = skin.volumeBarImage(for: playback.volume) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.black
            }
            if let thumb = skin.volumeThumb(pressed: isAdjustingVolume) {
                Image(nsImage: thumb)
                    .interpolation(.none)
                    .offset(x: CGFloat(playback.volume) * 54)
            }
        }
        .frame(width: 68, height: 13)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isAdjustingVolume = true
                    setVolume(at: value.location.x)
                }
                .onEnded { value in
                    setVolume(at: value.location.x)
                    isAdjustingVolume = false
                }
        )
        .position(x: 141, y: 63.5)
    }

    private func setVolume(at location: CGFloat) {
        playback.volume = min(1, max(0, Double(location / 68)))
    }

    private var balanceBar: some View {
        ZStack(alignment: .leading) {
            if let image = skin.balanceBarImage(for: playback.balance) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.black
            }
            if let thumb = skin.balanceThumb(pressed: isAdjustingBalance) {
                Image(nsImage: thumb)
                    .interpolation(.none)
                    .offset(x: CGFloat((playback.balance + 1) / 2) * 24)
            }
        }
        .frame(width: 38, height: 13)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isAdjustingBalance = true
                    setBalance(at: value.location.x)
                }
                .onEnded { value in
                    setBalance(at: value.location.x)
                    isAdjustingBalance = false
                }
        )
        .position(x: 196, y: 63.5)
    }

    private func setBalance(at location: CGFloat) {
        let rawBalance = min(1, max(-1, Double(location / 38) * 2 - 1))
        // About 2.5 pixels on either side of the center snap to CENTER.
        playback.balance = abs(rawBalance) <= 0.13 ? 0 : rawBalance
    }

    private var bitrateIndicator: some View {
        skinNumber(playback.bitrateKbps, width: 27)
            .position(x: 124.5, y: 46)
    }

    private var sampleRateIndicator: some View {
        skinNumber(playback.sampleRateKHz, width: 29)
            .position(x: 170.5, y: 46)
    }

    private var channelIndicator: some View {
        let hasTrack = playback.channelCount > 0
        let isStereo = playback.channelCount >= 2
        return HStack(spacing: 0) {
            channelLabel(stereo: false, isActive: hasTrack && !isStereo, width: 27)
            channelLabel(stereo: true, isActive: hasTrack && isStereo, width: 29)
        }
        .frame(width: 56, height: 12, alignment: .leading)
        .position(x: 240, y: 47)
    }

    private func channelLabel(stereo: Bool, isActive: Bool, width: CGFloat) -> some View {
        Group {
            if let image = skin.channelIndicator(stereo: stereo, isActive: isActive) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: 12)
    }

    private func skinNumber(_ value: Int?, width: CGFloat) -> some View {
        let digits = value.map(String.init) ?? ""
        return HStack(spacing: 0) {
            ForEach(Array(digits.enumerated()), id: \.offset) { _, character in
                if let digit = character.wholeNumberValue, let glyph = skin.textDigit(digit) {
                    Image(nsImage: glyph)
                        .interpolation(.none)
                        .frame(width: 5, height: 6)
                }
            }
        }
        .frame(width: width, height: 12, alignment: .leading)
    }

    private var equalizerButton: some View {
        windowToggleButton(
            .equalizer,
            isActive: $equalizerState.isVisible,
            isPressed: $isEqualizerPressed,
            action: { AppDelegate.shared?.toggleEqualizer(nil) }
        )
        .position(x: 230.5, y: 64)
    }

    private var playlistButton: some View {
        windowToggleButton(
            .playlist,
            isActive: $playlistState.isVisible,
            isPressed: $isPlaylistPressed,
            action: { AppDelegate.shared?.togglePlaylist(nil) }
        )
        .position(x: 253.5, y: 64)
    }

    private var shuffleButton: some View {
        playbackToggleButton(
            .shuffle,
            isActive: $playback.isShuffleEnabled,
            isPressed: $isShufflePressed
        )
        .position(x: 187.5, y: 96.5)
    }

    private var repeatButton: some View {
        playbackToggleButton(
            .repeatTrack,
            isActive: $playback.isRepeatEnabled,
            isPressed: $isRepeatPressed
        )
        .position(x: 225, y: 96.5)
    }

    private func playbackToggleButton(
        _ toggle: WinampSkinStore.PlaybackToggle,
        isActive: Binding<Bool>,
        isPressed: Binding<Bool>
    ) -> some View {
        let width: CGFloat = toggle == .shuffle ? 47 : 28
        return Group {
            if let image = skin.playbackToggleImage(
                toggle,
                isActive: isActive.wrappedValue,
                isPressed: isPressed.wrappedValue
            ) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: 15)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed.wrappedValue = true }
                .onEnded { _ in
                    isPressed.wrappedValue = false
                    isActive.wrappedValue.toggle()
                }
        )
    }

    private func windowToggleButton(
        _ toggle: WinampSkinStore.WindowToggle,
        isActive: Binding<Bool>,
        isPressed: Binding<Bool>,
        action: (() -> Void)? = nil
    ) -> some View {
        Group {
            if let image = skin.windowToggleImage(
                toggle,
                isActive: isActive.wrappedValue,
                isPressed: isPressed.wrappedValue
            ) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 23, height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed.wrappedValue = true }
                .onEnded { _ in
                    isPressed.wrappedValue = false
                    if let action { action() } else { isActive.wrappedValue.toggle() }
                }
        )
    }

    private var timeDisplay: some View {
        let elapsedSeconds = max(0, Int(playback.position.rounded(.down)))
        let showsRemainingTime = timeDisplayPreference.showsRemainingTime && playback.duration > 0
        let totalSeconds = showsRemainingTime
            ? max(0, Int((playback.duration - playback.position).rounded(.down)))
            : elapsedSeconds
        let minutes = min(totalSeconds / 60, 99)
        let seconds = totalSeconds % 60

        return Button(action: timeDisplayPreference.toggle) {
            ZStack(alignment: .leading) {
                if showsRemainingTime {
                    timeMinusSign
                        .position(x: 1.5, y: 6.5)
                }
                HStack(spacing: 0) {
                    timeDigit(minutes / 10)
                    Color.clear.frame(width: 3)
                    timeDigit(minutes % 10)
                    Color.clear.frame(width: 9)
                    timeDigit(seconds / 10)
                    Color.clear.frame(width: 3)
                    timeDigit(seconds % 10)
                }
                .offset(x: 9)
            }
            .frame(width: 60, height: 13, alignment: .leading)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: 60, height: 13)
        .position(x: 69, y: 32.5)
    }

    private var playbackIndicator: some View {
        let indicator: WinampSkinStore.PlaybackIndicator = playback.hasPlaybackError
            ? .lostSync
            : (playback.isPlaying
            ? .play
            : (playback.isPaused ? .pause : .stop))
        return Group {
            if let image = skin.playbackIndicatorImage(indicator) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 11, height: 9)
        .position(x: 29.5, y: 32.5)
    }

    private var spectrumAnalyzer: some View {
        visualizationView(isWindowShade: false)
        .frame(width: 76, height: 15)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded { visualizationMode.advance() })
        .position(x: 62, y: 51.5)
    }

    @ViewBuilder
    private func visualizationView(isWindowShade: Bool) -> some View {
        VisualizationDisplay(
            visualization: playback.visualization,
            palette: skin.visualizationPalette,
            mode: visualizationMode,
            isWindowShade: isWindowShade
        )
    }

    private var visualizationModeButtons: some View {
        ZStack(alignment: .top) {
            Group {
                let highlightedButton = pressedClutterbarButton ?? (infoState.isVisible ? 2 : nil)
                if let image = skin.clutterbarImage(pressedButton: highlightedButton) {
                    Image(nsImage: image)
                        .interpolation(.none)
                } else {
                    Color.clear
                }
            }
            .frame(width: 8, height: 43)

        }
        .frame(width: 8, height: 43)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // The 8 px top row in the titlebar sprite is padding; button rows begin below it.
                    let index = min(4, max(0, Int((value.location.y - 8) / 8)))
                    pressedClutterbarButton = index
                }
                .onEnded { _ in
                    // Winamp's clutterbar rows are Options, AOT, Info,
                    // Double-size and Visualization.  The third row is I.
                    if pressedClutterbarButton == 2 { AppDelegate.shared?.toggleInfo(nil) }
                    pressedClutterbarButton = nil
                }
        )
        .position(x: 14, y: 43.5)
    }

    private var timeMinusSign: some View {
        Group {
            if let glyph = skin.timeMinusSign() {
                Image(nsImage: glyph)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 5, height: 1)
    }

    private func timeDigit(_ digit: Int) -> some View {
        Group {
            if let glyph = skin.timeDigit(digit) {
                Image(nsImage: glyph)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: 9, height: 13)
    }

    private var controls: some View {
        ZStack(alignment: .topLeading) {
            playerControlButton(.previous, x: 16, width: 23, action: { AppDelegate.shared?.playlistTransportAction(0) })
            playerControlButton(.play, x: 39, width: 23, action: { AppDelegate.shared?.playFromActivePlaylist() })
            playerControlButton(.pause, x: 62, width: 23, action: playback.pause)
            playerControlButton(.stop, x: 85, width: 23, action: playback.stop)
            playerControlButton(.next, x: 108, width: 22, action: { AppDelegate.shared?.playlistTransportAction(4) })
            playerControlButton(.eject, x: 136, y: 89, width: 22, height: 16, action: { AppDelegate.shared?.chooseTracksForPlaybackPlaylist() })
        }
    }

    private func playerControlButton(
        _ control: WinampSkinStore.PlayerControl,
        x: CGFloat,
        y: CGFloat = 88,
        width: CGFloat,
        height: CGFloat = 18,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if let image = skin.playerControlImage(control, pressed: pressedPlayerControl == control) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressedPlayerControl = control }
                .onEnded { _ in
                    pressedPlayerControl = nil
                    action()
                }
        )
        .position(x: x + width / 2, y: y + height / 2)
    }

    private func skinButton(x: CGFloat, y: CGFloat = 88, width: CGFloat, height: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.frame(width: width, height: height) }
            .buttonStyle(PlainButtonStyle())
            .position(x: x + width / 2, y: y + height / 2)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            playback: PlaybackController(),
            interfaceScale: InterfaceScale(),
            timeDisplayPreference: TimeDisplayPreference(),
            windowFocus: WindowFocusState(),
            windowShade: WindowShadeState(),
            equalizerState: EqualizerWindowState(),
            playlistState: PlaylistWindowState(),
            infoState: InfoWindowState()
        )
    }
}

/// Keeps the periodically-updated marquee state out of the main player view.
/// This prevents a long track title from invalidating the entire skin every 200 ms.
private struct TickerDisplay: View {
    @ObservedObject var skin: WinampSkinStore
    @ObservedObject var playback: PlaybackController
    let isAdjustingVolume: Bool
    let isAdjustingBalance: Bool
    @State private var tickerOffset: CGFloat = 0
    @State private var tickerPauseTicks = 10
    @State private var tickerSourceText = ""
    @State private var tickerTimer: Timer?

    var body: some View {
        let colors = skin.playlistColors()
        ZStack(alignment: .leading) {
            Text(tickerDisplayText)
                .lineLimit(1)
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(skinTextColor(colors.normalText))
                .fixedSize(horizontal: true, vertical: false)
                .offset(y: -1)
                .offset(x: -tickerOffset)
        }
        .frame(width: 154, height: 10, alignment: .topLeading)
        .background(Color.black.opacity(0.86))
        .clipped()
        .onAppear {
            resetTicker(for: statusText)
            startTickerTimer()
        }
        .onDisappear {
            tickerTimer?.invalidate()
            tickerTimer = nil
        }
        .onChange(of: statusText) { resetTicker(for: $0) }
    }

    private var statusText: String {
        if isAdjustingVolume {
            return "VOLUME: \(Int((playback.volume * 100).rounded()))%"
        }
        if isAdjustingBalance {
            let magnitude = Int((abs(playback.balance) * 100).rounded())
            if magnitude == 0 { return "BALANCE: CENTER" }
            return "BALANCE: \(playback.balance < 0 ? "L" : "R") \(magnitude)%"
        }
        return playback.title
    }

    private var tickerDisplayText: String {
        tickerShouldScroll ? "\(statusText)  ***  \(statusText)" : statusText
    }

    private var tickerShouldScroll: Bool {
        !isAdjustingVolume && !isAdjustingBalance && tickerTextWidth(statusText) > 154
    }

    private func tickerTextWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
        ]).width
    }

    private func skinTextColor(_ color: NSColor) -> Color {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Color(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            opacity: Double(rgb.alphaComponent)
        )
    }

    private func resetTicker(for text: String) {
        tickerSourceText = text
        tickerOffset = 0
        tickerPauseTicks = 10
    }

    private func advanceTicker() {
        guard !playback.isVisualUpdatesSuspended else { return }
        let text = statusText
        if tickerSourceText != text { resetTicker(for: text) }
        guard tickerShouldScroll else { return }
        if tickerPauseTicks > 0 {
            tickerPauseTicks -= 1
            return
        }
        tickerOffset += 5
        let cycleWidth = tickerTextWidth(text) + tickerTextWidth("  ***  ")
        if tickerOffset >= cycleWidth {
            tickerOffset = 0
            tickerPauseTicks = 10
        }
    }

    private func startTickerTimer() {
        tickerTimer?.invalidate()
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            advanceTicker()
        }
        if let tickerTimer {
            RunLoop.main.add(tickerTimer, forMode: .common)
        }
    }
}

/// Mirrors Winamp's separate spectrum drawing surface: updates here do not
/// invalidate controls, title text, or the static skin around it.
private struct VisualizationDisplay: View {
    @ObservedObject var visualization: PlaybackVisualizationState
    let palette: [NSColor]
    let mode: VisualizationMode
    let isWindowShade: Bool

    var body: some View {
        switch mode {
        case .off:
            Color.clear
        case .spectrum:
            if isWindowShade {
                WindowShadeSpectrumView(palette: palette, levels: visualization.spectrumLevels)
            } else {
                SpectrumAnalyzerView(palette: palette, levels: visualization.spectrumLevels)
            }
        case .oscilloscope:
            OscilloscopeView(
                palette: palette,
                samples: visualization.waveformSamples,
                width: isWindowShade ? 38 : 76,
                height: isWindowShade ? 5 : 15
            )
        }
    }
}

/// Classic Winamp spectrum area: 19 groups of three pixels, separated by one pixel.
private struct SpectrumAnalyzerView: View {
    let palette: [NSColor]
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<19, id: \.self) { column in
                let sourceBand = Int((Double(column) * 15 / 18).rounded())
                let level = levels.indices.contains(sourceBand) ? min(1, max(0, levels[sourceBand])) : 0
                let litRows = Int((level * 15).rounded(.down))
                VStack(spacing: 0) {
                    ForEach((0..<15).reversed(), id: \.self) { row in
                        Rectangle()
                            .fill(segmentColor(row: row, isLit: row < litRows))
                            .frame(height: 1)
                        if row > 0 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 3, height: 15, alignment: .bottom)
            }
        }
        .frame(width: 76, height: 15, alignment: .leading)
        .background(swiftUIColor(palette.first ?? .black))
        .clipped()
    }

    private func segmentColor(row: Int, isLit: Bool) -> Color {
        guard isLit else { return swiftUIColor(palette.dropFirst().first ?? .darkGray) }
        return swiftUIColor(palette[min(palette.count - 1, 17 - row)])
    }

    private func swiftUIColor(_ color: NSColor) -> Color {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Color(red: Double(rgb.redComponent),
                     green: Double(rgb.greenComponent),
                     blue: Double(rgb.blueComponent),
                     opacity: Double(rgb.alphaComponent))
    }
}

/// The original windowshade uses a 38×5 surface. It leaves every fourth pixel
/// column blank (`(x & 3) == 3`) and one final trailing background pixel.
private struct WindowShadeSpectrumView: View {
    let palette: [NSColor]
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<38, id: \.self) { column in
                if column == 37 || column & 3 == 3 {
                    segmentColor(row: 0, isLit: false).frame(width: 1, height: 5)
                } else {
                    let sourceBand = Int((Double(column) * 15 / 36).rounded())
                    let level = levels.indices.contains(sourceBand) ? min(1, max(0, levels[sourceBand])) : 0
                    let litRows = Int((level * 5).rounded(.down))
                    VStack(spacing: 0) {
                        ForEach((0..<5).reversed(), id: \.self) { row in
                            segmentColor(row: row, isLit: row < litRows).frame(height: 1)
                        }
                    }
                    .frame(width: 1, height: 5)
                }
            }
        }
        .frame(width: 38, height: 5, alignment: .leading)
        .background(segmentColor(row: 0, isLit: false))
        .clipped()
    }

    private func segmentColor(row: Int, isLit: Bool) -> Color {
        let color: NSColor
        if isLit { color = palette[min(palette.count - 1, 17 - row * 3)] }
        else { color = palette.dropFirst().first ?? .darkGray }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Color(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), opacity: Double(rgb.alphaComponent))
    }
}

/// Pixel-style oscilloscope used by the third classic Winamp visualization mode.
private struct OscilloscopeView: View {
    let palette: [NSColor]
    let samples: [CGFloat]
    let width: Int
    let height: Int

    var body: some View {
        let renderedSamples = (0..<width).map { index -> CGFloat in
            guard !samples.isEmpty else { return 0 }
            let sourceIndex = Int((Double(index) * Double(samples.count - 1) / Double(max(1, width - 1))).rounded())
            return samples[sourceIndex]
        }
        ZStack {
            swiftUIColor(palette.first ?? .black)
            WaveformShape(samples: renderedSamples)
                .stroke(swiftUIColor(palette.last ?? .green), lineWidth: 1)
        }
        .frame(width: CGFloat(width), height: CGFloat(height))
        .clipped()
    }

    private func swiftUIColor(_ color: NSColor) -> Color {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Color(red: Double(rgb.redComponent),
                     green: Double(rgb.greenComponent),
                     blue: Double(rgb.blueComponent),
                     opacity: Double(rgb.alphaComponent))
    }
}

private struct WaveformShape: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        var path = Path()
        for index in samples.indices {
            let value = min(1, max(-1, samples[index]))
            let x = rect.minX + CGFloat(index) * rect.width / CGFloat(samples.count - 1)
            let y = rect.minY + (1 - (value + 1) / 2) * max(0, rect.height - 1)
            let point = CGPoint(x: x, y: y)
            if index == samples.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Lets the skin title bar move a borderless AppKit window without stealing gestures from player controls.
private struct SkinWindowDragArea: NSViewRepresentable {
    let cursor: NSCursor?
    func makeNSView(context: Context) -> SkinWindowDragNSView {
        let view = SkinWindowDragNSView()
        view.dragCursor = cursor
        return view
    }
    func updateNSView(_ nsView: SkinWindowDragNSView, context: Context) {
        nsView.dragCursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class SkinWindowDragNSView: NSView {
    var dragCursor: NSCursor?
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragCursor ?? SkinCursors.move)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            AppDelegate.shared?.toggleWindowShade(nil)
            return
        }
        guard let window else { return }
        AppDelegate.shared?.beginMainWindowDrag()
        defer { AppDelegate.shared?.mainWindowDragEnded() }
        let origin = window.frame.origin
        let start = NSEvent.mouseLocation
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp { break }
            let location = NSEvent.mouseLocation
            let frameOrigin = NSPoint(x: origin.x + location.x - start.x,
                                      y: origin.y + location.y - start.y)
            AppDelegate.shared?.beginMainDragFrame()
            window.setFrame(NSRect(origin: frameOrigin, size: window.frame.size), display: false)
            // Keep the group in lockstep. Snapping is intentionally deferred
            // to mouse-up, so no neighbour/screen search delays drag events.
            AppDelegate.shared?.moveAttachedWindowsWithMain()
        }
    }
}
