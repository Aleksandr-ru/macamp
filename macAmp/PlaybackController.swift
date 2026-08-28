import AVFoundation
import AppKit
import Combine
import Accelerate

/// High-frequency state is kept separate from transport state so spectrum
/// frames do not invalidate the whole player interface.
final class PlaybackVisualizationState: ObservableObject {
    @Published var spectrumLevels = Array(repeating: CGFloat(0), count: 16)
    @Published var waveformSamples = Array(repeating: CGFloat(0), count: 76)
}

final class PlaybackController: NSObject, ObservableObject {
    var onTrackFinished: (() -> Void)?
    @Published private(set) var title = "MACAMP — READY"
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bitrateKbps: Int?
    @Published private(set) var sampleRateKHz: Int?
    @Published private(set) var channelCount = 0
    let visualization = PlaybackVisualizationState()
    @Published var volume: Double = 0.8 { didSet { playerNode.volume = Float(volume) } }
    @Published var balance: Double = 0 { didSet { playerNode.pan = Float(min(1, max(-1, balance))) } }
    @Published var isShuffleEnabled = false {
        didSet { UserDefaults.standard.set(isShuffleEnabled, forKey: Self.shufflePreferenceKey) }
    }
    @Published var isRepeatEnabled = false {
        didSet { UserDefaults.standard.set(isRepeatEnabled, forKey: Self.repeatPreferenceKey) }
    }

    var currentURL: URL? { scopedURL }

    let equalizer = EqualizerController()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizerNode = AVAudioUnitEQ(numberOfBands: 10)
    private var sourceFile: AVAudioFile?
    /// AVAudioFile may block while indexing a VBR file on an SMB/NAS volume.
    /// AVPlayer can begin buffering such an URL without waiting for that index,
    /// so it is used as a time-bounded fallback for the initial start.
    private var streamingPlayer: AVPlayer?
    private var streamingStatusObservation: NSKeyValueObservation?
    private var streamingTimeObserver: Any?
    private var streamingOpenGeneration: Int?
    /// Once a volume has demonstrated that AVAudioFile indexing is slow, do
    /// not repeat that speculative open for every following track from it.
    private var streamingPreferredVolumeRoots = Set<String>()
    /// Opening a file on a network volume can block on I/O for seconds. Keep
    /// that work off the main run loop; the engine itself is still configured
    /// on the main thread once the file is ready.
    // Do not serialize potentially stalled network opens: a newly selected
    // track must be able to supersede an earlier URL immediately.
    private let fileOpenQueue = DispatchQueue(label: "ru.aleksandr.MacAmp.audio.open", qos: .userInitiated, attributes: .concurrent)
    private var fileOpenGeneration = 0
    /// A tiny PCM snapshot from the live audio graph. This avoids repeatedly
    /// seeking and decoding the source file just to draw the visualizer.
    private let analysisSamplesLock = NSLock()
    private var liveAnalysisSamples = Array(repeating: Float(0), count: 1_024)
    private var liveAnalysisSampleCount = 0
    private var liveAnalysisSampleRate = 0.0
    private var timer: Timer?
    private var scopedURL: URL?
    private var hasSecurityScope = false
    private var scheduledStartFrame: AVAudioFramePosition = 0
    /// Invalidates completion handlers from segments replaced by seek/restart.
    private var playbackGeneration = 0
    private var isSpectrumAnalysisScheduled = false
    private let spectrumQueue = DispatchQueue(label: "ru.aleksandr.MacAmp.spectrum", qos: .utility)
    private var routesThroughEqualizer = false
    private var isLiveAnalysisTapInstalled = false
    private var isVisualizationEnabled = true
    private var needsWaveformSamples = false
    private var isInterfaceVisible = true
    private var lastPublishedPosition = Date.distantPast
    private let positionPublishInterval: TimeInterval = 0.25
    /// Spectrum animation is updated at 6 FPS, but the less visible AUTO EQ
    /// correction only needs 3 FPS. Keeping the two cadences separate avoids
    /// spending an FFT on every visual frame.
    private let adaptiveAnalysisInterval: TimeInterval = 1.0 / 3.0
    private var lastAdaptiveAnalysis = Date.distantPast
    /// The visible analyzer has only 16 bands and 15 LED rows. It does not
    /// benefit from the more expensive window needed by Adaptive EQ.
    private let visualFFTSize = 512
    private var fftSize: Int { equalizer.adaptiveConfiguration.fftSize }
    private lazy var adaptiveFFTSetup: FFTSetup? = {
        vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
    }()
    private var smoothedBandEnergy = Array(repeating: -60.0, count: 10)
    private var hasAdaptiveAnalysisHistory = false
    private static let shufflePreferenceKey = "MacAmp.playback.shuffleEnabled"
    private static let repeatPreferenceKey = "MacAmp.playback.repeatEnabled"
    private lazy var fftWindow: [Float] = {
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return window
    }()
    private lazy var visualFFTWindow: [Float] = {
        var window = [Float](repeating: 0, count: visualFFTSize)
        vDSP_hann_window(&window, vDSP_Length(visualFFTSize), Int32(vDSP_HANN_NORM))
        return window
    }()

    override init() {
        super.init()
        // Keep these choices independent from window-layout persistence: a
        // damaged/older layout snapshot must never reset playback modes.
        if UserDefaults.standard.object(forKey: Self.shufflePreferenceKey) != nil {
            isShuffleEnabled = UserDefaults.standard.bool(forKey: Self.shufflePreferenceKey)
        }
        if UserDefaults.standard.object(forKey: Self.repeatPreferenceKey) != nil {
            isRepeatEnabled = UserDefaults.standard.bool(forKey: Self.repeatPreferenceKey)
        }
        configureAudioGraph()
        equalizer.onChange = { [weak self] in self?.applyEqualizer() }
    }

    deinit {
        timer?.invalidate()
        if let streamingTimeObserver { streamingPlayer?.removeTimeObserver(streamingTimeObserver) }
        engine.mainMixerNode.removeTap(onBus: 0)
        if let adaptiveFFTSetup { vDSP_destroy_fftsetup(adaptiveFFTSetup) }
        engine.stop()
    }

    func chooseTrack() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func togglePlayback() { sourceFile == nil && streamingPlayer == nil ? chooseTrack() : (isPlaying ? pause() : play()) }

    func play() {
        if let streamingPlayer { streamingPlayer.play(); isPlaying = true; isPaused = false; return }
        guard sourceFile != nil else { chooseTrack(); return }
        start(at: isPaused ? scheduledStartFrame : scheduledStartFrame + currentPlayedFrames())
    }

    func pause() {
        if let streamingPlayer {
            streamingPlayer.pause()
            isPlaying = false; isPaused = true
            return
        }
        scheduledStartFrame += currentPlayedFrames()
        playerNode.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        isPaused = true
    }

    func stop() {
        playbackGeneration += 1
        if let streamingPlayer {
            streamingPlayer.pause()
            streamingPlayer.seek(to: .zero)
            position = 0
            isPlaying = false
            isPaused = false
            visualization.spectrumLevels = Array(repeating: 0, count: 16)
            visualization.waveformSamples = Array(repeating: 0, count: 76)
            return
        }
        playerNode.stop()
        timer?.invalidate()
        timer = nil
        scheduledStartFrame = 0
        position = 0
        isPlaying = false
        isPaused = false
        visualization.spectrumLevels = Array(repeating: 0, count: 16)
        visualization.waveformSamples = Array(repeating: 0, count: 76)
    }

    /// Keeps analysis work proportional to what is actually on screen.  The
    /// audio engine is independent of the visualizer, so turning it off must
    /// also stop disk reads and DSP work rather than merely hiding the view.
    func setVisualization(enabled: Bool, waveform: Bool) {
        isVisualizationEnabled = enabled
        needsWaveformSamples = enabled && waveform
        updateLiveAnalysisTap()
        guard !enabled else { return }
        visualization.spectrumLevels = Array(repeating: 0, count: 16)
        visualization.waveformSamples = Array(repeating: 0, count: 76)
    }

    /// The audio graph keeps running in the background, but rendering state
    /// and file-based spectrum analysis have no user-visible value there.
    func setInterfaceVisible(_ visible: Bool) {
        guard isInterfaceVisible != visible else { return }
        isInterfaceVisible = visible
        updateLiveAnalysisTap()
        if isPlaying { startTimer() }
    }

    func seek(to value: Double) {
        if let streamingPlayer {
            let target = min(max(0, value), duration)
            position = target
            streamingPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            return
        }
        guard let sourceFile else { return }
        let target = min(max(0, value), duration)
        // Publish the target before scheduling the segment so the skin thumb does
        // not briefly fall back to its previous playback position on mouse-up.
        position = target
        start(at: AVAudioFramePosition(target * sourceFile.processingFormat.sampleRate))
    }

    private func configureAudioGraph() {
        engine.attach(playerNode)
        engine.attach(equalizerNode)
        for (index, band) in equalizerNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerController.frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        equalizerNode.globalGain = 0
        applyEqualizer()
    }

    private func applyEqualizer() {
        equalizerNode.globalGain = Float(equalizer.preamp)
        for (band, value) in zip(equalizerNode.bands, equalizer.bands) { band.gain = Float(value) }
        updateLiveAnalysisTap()

        // Bypassing AVAudioUnitEQ still leaves its ten filters on the render
        // route. Rebuild only when the user toggles EQ, so normal slider and
        // AUTO-EQ updates remain allocation-free graph parameter changes.
        guard sourceFile != nil, routesThroughEqualizer != equalizer.isEnabled else { return }
        reconfigureAudioGraphForEqualizerState()
    }

    private func connectAudioGraph(for format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(equalizerNode)
        routesThroughEqualizer = equalizer.isEnabled
        if routesThroughEqualizer {
            equalizerNode.bypass = false
            engine.connect(playerNode, to: equalizerNode, format: format)
            engine.connect(equalizerNode, to: engine.mainMixerNode, format: format)
        } else {
            equalizerNode.bypass = true
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        }
        updateLiveAnalysisTap()
    }

    /// Changing a graph connection requires stopping the engine. Preserve the
    /// exact source frame and immediately reschedule it, keeping an EQ toggle a
    /// short, deterministic transition instead of continuous DSP overhead.
    private func reconfigureAudioGraphForEqualizerState() {
        guard let file = sourceFile else { return }
        let wasPlaying = playerNode.isPlaying
        let resumeFrame = scheduledStartFrame + (wasPlaying ? currentPlayedFrames() : 0)
        playbackGeneration += 1
        playerNode.stop()
        engine.stop()
        engine.reset()
        connectAudioGraph(for: file.processingFormat)
        engine.prepare()
        do {
            try engine.start()
            scheduledStartFrame = resumeFrame
            if wasPlaying { start(at: resumeFrame) }
        } catch {
            title = "AUDIO ENGINE ERROR"
        }
    }

    private var needsLiveAnalysis: Bool {
        isInterfaceVisible && (isVisualizationEnabled || (equalizer.isEnabled && equalizer.isAdaptiveEnabled))
    }

    /// Tapping a node invokes code on the real-time audio render thread. Do not
    /// leave a no-op tap installed when neither the analyser nor AUTO EQ needs
    /// PCM data. The mixer is downstream from the optional EQ node, so it also
    /// works when the EQ is removed from the playback route.
    private func updateLiveAnalysisTap() {
        let shouldInstall = sourceFile != nil && needsLiveAnalysis
        guard shouldInstall != isLiveAnalysisTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isLiveAnalysisTapInstalled = false
        guard shouldInstall else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            guard let self,
                  let channels = buffer.floatChannelData else { return }
            let count = min(Int(buffer.frameLength), self.liveAnalysisSamples.count)
            guard count > 0 else { return }
            self.analysisSamplesLock.lock()
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 {
                self.liveAnalysisSamples.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.update(from: channels[0], count: count)
                }
            } else {
                for sample in 0..<count {
                    var mixed: Float = 0
                    for channel in 0..<channelCount { mixed += channels[channel][sample] }
                    self.liveAnalysisSamples[sample] = mixed / Float(channelCount)
                }
            }
            self.liveAnalysisSampleCount = count
            self.liveAnalysisSampleRate = buffer.format.sampleRate
            self.analysisSamplesLock.unlock()
        }
        isLiveAnalysisTapInstalled = true
    }

    /// PlaylistManager owns selection; the audio engine only opens the chosen URL.
    func open(_ url: URL) {
        fileOpenGeneration &+= 1
        let generation = fileOpenGeneration
        stopStreamingPlayback()
        // Commit the track switch before touching the new URL. Apart from
        // making the Playlist highlight immediate, this lets the progressive
        // fallback start even when the previous AVAudioFile is still present.
        playbackGeneration &+= 1
        playerNode.stop()
        timer?.invalidate(); timer = nil
        sourceFile = nil
        if hasSecurityScope { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil; hasSecurityScope = false
        isPlaying = false; isPaused = false
        title = "OPENING…"
        duration = 0
        bitrateKbps = nil
        if streamingPreferredVolumeRoots.contains(streamingVolumeRoot(for: url)) {
            startStreamingFallback(for: url, generation: generation)
            return
        }
        fileOpenQueue.async { [weak self] in
            // Security-scoped and remote-volume access may synchronously
            // contact a file provider. It must never delay painting the newly
            // active Playlist row on the main run loop.
            let obtainedSecurityScope = url.startAccessingSecurityScopedResource()
            // Do this filesystem query on the opening queue as well.  An SMB
            // or other network volume is not a candidate for AVAudioFile:
            // even when constructed off-main, later graph setup can force a
            // synchronous index/read on the event loop. AVPlayer buffers it
            // asynchronously and keeps all MacAmp windows responsive.
            let isNetworkVolume = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
            if isNetworkVolume {
                DispatchQueue.main.async { [weak self] in
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    guard let self, generation == self.fileOpenGeneration else { return }
                    self.startStreamingFallback(for: url, generation: generation)
                }
                return
            }
            let result = Result { try AVAudioFile(forReading: url) }
            DispatchQueue.main.async { [self] in
                guard let self else {
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                guard generation == self.fileOpenGeneration else {
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                // The streaming fallback already accepted this source. Do not
                // replace an audible, buffered track with a late AVAudioFile.
                guard self.streamingOpenGeneration != generation else {
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                guard case let .success(file) = result else {
                    self.title = "UNSUPPORTED AUDIO FILE"
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                if self.hasSecurityScope { self.scopedURL?.stopAccessingSecurityScopedResource() }
                do {
            self.playerNode.stop()
            // A file may use another format/sample rate. Reset the live graph
            // before reconnecting it so a previous scheduled segment cannot keep
            // the engine in a reconfiguration state after a second Open.
            self.engine.stop()
            self.engine.reset()
            self.engine.disconnectNodeOutput(self.playerNode)
            self.engine.disconnectNodeOutput(self.equalizerNode)
            self.sourceFile = file
            self.connectAudioGraph(for: file.processingFormat)
            self.engine.prepare()
            try self.engine.start()
            self.scopedURL = url
            self.hasSecurityScope = obtainedSecurityScope
            self.position = 0
            self.scheduledStartFrame = 0
            self.title = url.deletingPathExtension().lastPathComponent.uppercased()
            // Reading AVAudioFile.length can make AVFoundation scan a large
            // VBR file end-to-end, particularly on a network volume. Start
            // decoding first; duration remains unknown until it can be read
            // without holding up the initial playback path.
            self.sampleRateKHz = Int((file.processingFormat.sampleRate / 1_000).rounded())
            self.channelCount = Int(file.processingFormat.channelCount)
            self.smoothedBandEnergy = Array(repeating: -60, count: 10)
            self.hasAdaptiveAnalysisHistory = false
            self.start()
                } catch {
                    self.sourceFile = nil
                    self.title = "UNSUPPORTED AUDIO FILE"
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        // Give AVAudioFile a brief chance for normal local files. If it is
        // still opening, let AVPlayer buffer progressively instead of keeping
        // the UI in OPENING… behind a potentially unbounded index operation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.startStreamingFallback(for: url, generation: generation)
        }
    }

    private func startStreamingFallback(for url: URL, generation: Int) {
        guard generation == fileOpenGeneration, sourceFile == nil,
              streamingPlayer == nil, streamingOpenGeneration == nil else { return }
        streamingPreferredVolumeRoots.insert(streamingVolumeRoot(for: url))
        // AVPlayerItem(url:) can synchronously ask a file provider for header
        // data. Reserve this generation first, then construct it away from the
        // event loop so a second network click cannot freeze all windows.
        streamingOpenGeneration = generation
        fileOpenQueue.async { [weak self] in
            let obtainedSecurityScope = url.startAccessingSecurityScopedResource()
            let item = AVPlayerItem(url: url)
            DispatchQueue.main.async {
                guard let self, self.fileOpenGeneration == generation,
                      self.streamingOpenGeneration == generation else {
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                let player = AVPlayer(playerItem: item)
                self.streamingPlayer = player
                self.scopedURL = url
                self.hasSecurityScope = obtainedSecurityScope
                self.streamingStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self, self.fileOpenGeneration == generation,
                              self.streamingOpenGeneration == generation else { return }
                        guard item.status == .readyToPlay else {
                            if item.status == .failed {
                                self.stopStreamingPlayback()
                                if self.hasSecurityScope { self.scopedURL?.stopAccessingSecurityScopedResource() }
                                self.scopedURL = nil; self.hasSecurityScope = false
                                self.title = "SOURCE UNAVAILABLE"
                            }
                            return
                        }
                        self.playerNode.stop()
                        self.timer?.invalidate(); self.timer = nil
                        self.duration = item.duration.seconds.isFinite ? max(0, item.duration.seconds) : 0
                        self.position = 0
                        self.title = url.deletingPathExtension().lastPathComponent.uppercased()
                        self.installStreamingTimeObserver(on: player)
                        player.play()
                        self.isPlaying = true; self.isPaused = false
                    }
                }
            }
        }
    }

    private func installStreamingTimeObserver(on player: AVPlayer) {
        if let streamingTimeObserver { player.removeTimeObserver(streamingTimeObserver) }
        streamingTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self, self.streamingPlayer === player else { return }
            self.position = max(0, time.seconds)
            self.isPlaying = player.rate > 0
            self.isPaused = !self.isPlaying
        }
    }

    private func stopStreamingPlayback() {
        if let streamingTimeObserver { streamingPlayer?.removeTimeObserver(streamingTimeObserver) }
        streamingTimeObserver = nil
        streamingStatusObservation?.invalidate(); streamingStatusObservation = nil
        streamingPlayer?.pause(); streamingPlayer = nil
        streamingOpenGeneration = nil
    }

    /// Network shares mounted by Finder normally live at /Volumes/<share>.
    /// For other layouts, the parent directory remains a conservative session
    /// key and never changes the playback path for unrelated locations.
    private func streamingVolumeRoot(for url: URL) -> String {
        let components = url.pathComponents
        if components.count >= 3, components[1] == "Volumes" { return "/Volumes/\(components[2])" }
        return url.deletingLastPathComponent().path
    }

    private func start(at requestedFrame: AVAudioFramePosition? = nil) {
        guard let file = sourceFile else { return }
        playbackGeneration += 1
        let generation = playbackGeneration
        playerNode.stop()
        let completion: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack
        let finished: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.onTrackFinished?()
            }
        }
        if let requestedFrame {
            // Seeking is an explicit user action. Only this slower path needs
            // the file's total frame count in order to clamp and schedule a
            // finite segment.
            let frame = min(max(0, requestedFrame), file.length)
            guard frame < file.length else { stop(); return }
            scheduledStartFrame = frame
            playerNode.scheduleSegment(file, startingFrame: frame,
                                       frameCount: AVAudioFrameCount(file.length - frame),
                                       at: nil, completionCallbackType: completion,
                                       completionHandler: finished)
        } else {
            scheduledStartFrame = 0
            // scheduleFile streams frames as the render thread needs them and
            // does not require a costly full-file length scan before playing.
            playerNode.scheduleFile(file, at: nil, completionCallbackType: completion,
                                    completionHandler: finished)
        }
        do { if !engine.isRunning { try engine.start() } } catch { title = "AUDIO ENGINE ERROR"; return }
        playerNode.play()
        isPlaying = true
        isPaused = false
        startTimer()
    }

    private func currentPlayedFrames() -> AVAudioFramePosition {
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return 0 }
        return playerTime.sampleTime
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = isInterfaceVisible ? equalizer.adaptiveConfiguration.analysisInterval : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let file = self.sourceFile else { return }
            let rawPosition = Double(self.scheduledStartFrame + self.currentPlayedFrames()) / file.processingFormat.sampleRate
            let currentPosition = self.duration > 0 ? min(self.duration, rawPosition) : rawPosition
            // The time digits and progress thumb cannot display sub-quarter-
            // second changes.  Publishing them at the analyser cadence makes
            // the entire SwiftUI hierarchy redraw needlessly.
            if Date().timeIntervalSince(self.lastPublishedPosition) >= self.positionPublishInterval || currentPosition >= self.duration {
                self.position = currentPosition
                self.lastPublishedPosition = Date()
            }
            let nodeIsPlaying = self.playerNode.isPlaying
            if self.isPlaying != nodeIsPlaying { self.isPlaying = nodeIsPlaying }
            if nodeIsPlaying, self.isInterfaceVisible, self.isVisualizationEnabled {
                self.updateSpectrum(at: currentPosition, includesWaveform: self.needsWaveformSamples)
            }
        }
    }

    private func loadFormatDetails(for url: URL, file: AVAudioFile) {
        sampleRateKHz = Int((file.processingFormat.sampleRate / 1_000).rounded())
        channelCount = Int(file.processingFormat.channelCount)
        let asset = AVURLAsset(url: url)
        let bitrate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
        if bitrate > 0 {
            bitrateKbps = Int((bitrate / 1_000).rounded())
            return
        }

        // Some MP3s, especially VBR files without a usable Xing/VBR header,
        // expose a zero `estimatedDataRate` through AVFoundation. File size
        // divided by decoded duration is the correct average bitrate fallback.
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let fileSize, duration > 0 {
            bitrateKbps = Int((Double(fileSize) * 8 / duration / 1_000).rounded())
        } else {
            bitrateKbps = nil
        }
    }

    private func updateSpectrum(at _: TimeInterval, includesWaveform: Bool) {
        guard !isSpectrumAnalysisScheduled else { return }
        isSpectrumAnalysisScheduled = true
        let now = Date()
        let needsAdaptiveAnalysis = equalizer.isEnabled && equalizer.isAdaptiveEnabled && now.timeIntervalSince(lastAdaptiveAnalysis) >= adaptiveAnalysisInterval
        if needsAdaptiveAnalysis { lastAdaptiveAnalysis = now }
        let adaptiveWindow = fftWindow
        let visualWindow = visualFFTWindow
        let analysisSize = needsAdaptiveAnalysis ? fftSize : visualFFTSize
        spectrumQueue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.isSpectrumAnalysisScheduled = false } }
            self.analysisSamplesLock.lock()
            let available = self.liveAnalysisSampleCount
            let sampleRate = self.liveAnalysisSampleRate
            let samples = Array(self.liveAnalysisSamples.prefix(available))
            self.analysisSamplesLock.unlock()
            guard sampleRate > 0, samples.count >= analysisSize else { return }
            let latestSamples = Array(samples.suffix(visualFFTSize))
            // The two FFT passes are needed only by AUTO EQ. The visualizer
            // uses its own lightweight band sampler, so do not pay for DSP
            // that cannot affect playback while AUTO is disabled.
            let decibels = needsAdaptiveAnalysis
                ? self.bandDecibels(samples: samples, window: adaptiveWindow, sampleRate: sampleRate)
                : []
            // The skin contains fifteen physical LED rows.  Quantize before
            // publishing so imperceptible floating-point changes do not cause
            // another complete SwiftUI update.
            let levels = self.visualLevels(samples: latestSamples, window: visualWindow, sampleRate: sampleRate)
                .map { CGFloat(Int(($0 * 15).rounded(.down))) / 15 }
            let waveform: [CGFloat] = includesWaveform
                ? (0..<76).map { CGFloat(min(1, max(-1, latestSamples[min(self.visualFFTSize - 1, $0 * (self.visualFFTSize - 1) / 75)]))) }
                : []
            DispatchQueue.main.async {
                if self.visualization.spectrumLevels != levels { self.visualization.spectrumLevels = levels }
                if includesWaveform { self.visualization.waveformSamples = waveform }
                if needsAdaptiveAnalysis { self.updateAdaptiveEqualizer(with: decibels) }
            }
        }
    }

    private func monoSamples(channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, count: Int) -> [Float] {
        guard channelCount > 1 else { return Array(UnsafeBufferPointer(start: channels[0], count: count)) }
        var mono = [Float](repeating: 0, count: count)
        for channelIndex in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[channelIndex], 1, &mono, 1, vDSP_Length(count))
        }
        var divisor = Float(1.0 / Double(channelCount))
        vDSP_vsmul(mono, 1, &divisor, &mono, 1, vDSP_Length(count))
        return mono
    }

    /// The tap already receives the current decoded PCM window, so one FFT is
    /// enough for AUTO EQ; the former second pass only existed to compensate
    /// for repeatedly seeking through the source file.
    private func bandDecibels(samples: [Float], window: [Float], sampleRate: Double) -> [Double] {
        let power = fftPower(Array(samples.suffix(fftSize)), window: window)
        let frequencies = EqualizerController.frequencies.map(Double.init)
        return frequencies.enumerated().map { index, frequency in
            let lower = index == 0 ? frequency / sqrt(frequencies[1] / frequency) : sqrt(frequencies[index - 1] * frequency)
            let upper = index == frequencies.count - 1 ? frequency * sqrt(frequency / frequencies[index - 1]) : sqrt(frequency * frequencies[index + 1])
            let lowBin = max(1, Int(floor(lower * Double(fftSize) / sampleRate)))
            let highBin = min(fftSize / 2 - 1, max(lowBin, Int(ceil(upper * Double(fftSize) / sampleRate))))
            let meanPower = power[lowBin...highBin].reduce(0, +) / Double(highBin - lowBin + 1)
            return 10 * log10(max(meanPower, 1e-12))
        }
    }

    private func fftPower(_ samples: [Float], window: [Float]) -> [Double] {
        var windowed = zip(samples, window).map(*)
        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        let log2Size = vDSP_Length(log2(Float(fftSize)))
        guard let setup = adaptiveFFTSetup else { return Array(repeating: 0, count: halfSize) }
        windowed.withUnsafeMutableBufferPointer { source in
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                }
            }
        }
        var power = zip(real, imaginary).map { Double($0 * $0 + $1 * $1) }
        power[0] = Double(real[0] * real[0])
        return power
    }

    private func visualLevels(samples: [Float], window: [Float], sampleRate: Double) -> [CGFloat] {
        let sampleCount = samples.count
        return (0..<16).map { index in
            let frequency = min(sampleRate / 2 - 1, 45 * pow(2, Double(index) * 8.7 / 15))
            let bin = max(1, Int((Double(sampleCount) * frequency / sampleRate).rounded()))
            let coefficient = 2 * cos(2 * Double.pi * Double(bin) / Double(sampleCount))
            var p1 = 0.0, p2 = 0.0
            for sampleIndex in 0..<sampleCount {
                let p0 = Double(samples[sampleIndex] * window[sampleIndex]) + coefficient * p1 - p2
                p2 = p1; p1 = p0
            }
            let power = p2 * p2 + p1 * p1 - coefficient * p1 * p2
            let db = 20 * log10(max(sqrt(max(0, power)) / Double(sampleCount / 2), 0.000_000_1))
            return CGFloat(min(1, max(0, (db + 65) / 65)))
        }
    }

    private func updateAdaptiveEqualizer(with levels: [Double]) {
        guard equalizer.isAdaptiveEnabled else { return }
        let configuration = equalizer.adaptiveConfiguration
        // AUTO may have been restored before a new track is opened. Seed the
        // analyser from its first real frame instead of easing up from the
        // placeholder −60 dB curve, which made it appear inactive for seconds.
        if !hasAdaptiveAnalysisHistory {
            smoothedBandEnergy = levels
            hasAdaptiveAnalysisHistory = true
        }
        for index in levels.indices {
            let duration = levels[index] > smoothedBandEnergy[index]
                ? configuration.spectralAttackTime : configuration.spectralReleaseTime
            let alpha = 1 - exp(-configuration.analysisInterval / duration)
            smoothedBandEnergy[index] += (levels[index] - smoothedBandEnergy[index]) * alpha
        }

        let logFrequencies = EqualizerController.frequencies.map { log10(Double($0)) }
        // Normalise to the configurable pink-noise-like reference before
        // removing the remaining global linear tilt. Only local residuals are
        // allowed to drive the EQ, so a natural spectral slope stays intact.
        let reference = EqualizerController.frequencies.map { configuration.referenceSlopeDBPerOctave * log2(Double($0) / 1_000) }
        let normalised = zip(smoothedBandEnergy, reference).map(-)
        let meanX = logFrequencies.reduce(0, +) / Double(logFrequencies.count)
        let meanY = normalised.reduce(0, +) / Double(normalised.count)
        let denominator = zip(logFrequencies, normalised).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        let slope = denominator > 0 ? zip(logFrequencies, normalised).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / denominator : 0
        let residual = zip(logFrequencies, normalised).map { $1 - (slope * ($0 - meanX) + meanY) }
        let target = residual.map { -$0 * configuration.adaptationStrength }
        let estimatedPeakGain = target.max() ?? 0
        let preamp = estimatedPeakGain > configuration.preampHeadroom ? configuration.preampHeadroom - estimatedPeakGain : 0
        equalizer.updateAdaptive(targetBands: target, targetPreamp: preamp)
    }
}
