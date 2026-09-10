import AppKit
import Combine
import Metal
import MetalKit
import QuartzCore
import simd

private struct MilkDropFullscreenVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct MilkDropWaveVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Native, deliberately small equivalents of the parameter groups used by a
/// MilkDrop preset.  Keeping these profiles in Swift avoids embedding the
/// large Butterchurn preset bundle and lets one Metal pipeline render every
/// variation.
private struct MilkDropPreset {
    var warp: Float
    var rotation: Float
    var zoom: Float
    var hueSpeed: Float
    var drift: SIMD2<Float>
    var hueOffset: Float
    var saturation: Float
    var brightness: Float
    var radialAmount: Float
    var spectrumGain: Float
    var waveformGain: Float
    var decay: Float
    var glow: Float
    var pulse: Float
    var waveWidth: Float
    var symmetry: Float
    /// A discrete family of patterns. It changes at the midpoint of a smooth
    /// preset blend; the remaining parameters continue to interpolate.
    var style: Float
    var waveTint: SIMD3<Float>

    func interpolated(to other: MilkDropPreset, amount: Float) -> MilkDropPreset {
        let t = max(0, min(1, amount))
        func mix(_ first: Float, _ second: Float) -> Float {
            first + (second - first) * t
        }
        return MilkDropPreset(
            warp: mix(warp, other.warp),
            rotation: mix(rotation, other.rotation),
            zoom: mix(zoom, other.zoom),
            hueSpeed: mix(hueSpeed, other.hueSpeed),
            drift: SIMD2(mix(drift.x, other.drift.x), mix(drift.y, other.drift.y)),
            hueOffset: mix(hueOffset, other.hueOffset),
            saturation: mix(saturation, other.saturation),
            brightness: mix(brightness, other.brightness),
            radialAmount: mix(radialAmount, other.radialAmount),
            spectrumGain: mix(spectrumGain, other.spectrumGain),
            waveformGain: mix(waveformGain, other.waveformGain),
            decay: mix(decay, other.decay),
            glow: mix(glow, other.glow),
            pulse: mix(pulse, other.pulse),
            waveWidth: mix(waveWidth, other.waveWidth),
            symmetry: mix(symmetry, other.symmetry),
            style: mix(style, other.style),
            waveTint: SIMD3(mix(waveTint.x, other.waveTint.x),
                            mix(waveTint.y, other.waveTint.y),
                            mix(waveTint.z, other.waveTint.z))
        )
    }
}

private enum MilkDropPresetLibrary {
    // These profiles map to distinct pattern families in the one feedback
    // shader. Preset changes still cost only uniform interpolation and never
    // require a pipeline rebuild or additional render pass.
    static let all: [MilkDropPreset] = [
        // Orbit: concentric audio rings.
        MilkDropPreset(warp: 0.018, rotation: 0.016, zoom: 1.004, hueSpeed: 0.018,
                       drift: SIMD2(0.001, -0.001), hueOffset: 0.57, saturation: 0.82,
                       brightness: 0.8, radialAmount: 0.30, spectrumGain: 0.72,
                       waveformGain: 0.82, decay: 0.948, glow: 0.85, pulse: 0.72,
                       waveWidth: 0.20, symmetry: 1.0, style: 0,
                       waveTint: SIMD3(0.25, 0.78, 1.0)),
        // Nebula: slow coloured clouds with no persistent white field.
        MilkDropPreset(warp: 0.035, rotation: -0.008, zoom: 0.998, hueSpeed: 0.011,
                       drift: SIMD2(0.002, 0.002), hueOffset: 0.34, saturation: 0.65,
                       brightness: 0.72, radialAmount: 0.18, spectrumGain: 0.62,
                       waveformGain: 1.05, decay: 0.955, glow: 0.72, pulse: 0.45,
                       waveWidth: 0.28, symmetry: 1.0, style: 1,
                       waveTint: SIMD3(0.36, 1.0, 0.62)),
        // Kaleidoscope: mirrored diagonal shards.
        MilkDropPreset(warp: 0.024, rotation: 0.026, zoom: 1.008, hueSpeed: 0.022,
                       drift: SIMD2(-0.001, 0.002), hueOffset: 0.10, saturation: 0.9,
                       brightness: 0.88, radialAmount: 0.40, spectrumGain: 0.75,
                       waveformGain: 0.78, decay: 0.94, glow: 0.92, pulse: 0.9,
                       waveWidth: 0.18, symmetry: 3.0, style: 2,
                       waveTint: SIMD3(1.0, 0.38, 0.26)),
        // Spectrum: a dark equalizer field with beat-driven column bursts.
        MilkDropPreset(warp: 0.013, rotation: -0.012, zoom: 1.002, hueSpeed: 0.008,
                       drift: SIMD2(0.002, 0), hueOffset: 0.70, saturation: 0.86,
                       brightness: 0.78, radialAmount: 0.12, spectrumGain: 1.05,
                       waveformGain: 0.9, decay: 0.934, glow: 0.8, pulse: 0.62,
                       waveWidth: 0.24, symmetry: 1.0, style: 3,
                       waveTint: SIMD3(0.84, 0.32, 1.0)),
        // Ribbons: broad waveform-shaped bands.
        MilkDropPreset(warp: 0.028, rotation: -0.021, zoom: 1.001, hueSpeed: 0.014,
                       drift: SIMD2(0.003, 0.001), hueOffset: 0.46, saturation: 0.72,
                       brightness: 0.76, radialAmount: 0.26, spectrumGain: 0.68,
                       waveformGain: 1.5, decay: 0.946, glow: 0.76, pulse: 0.66,
                       waveWidth: 0.42, symmetry: 2.0, style: 4,
                       waveTint: SIMD3(0.22, 0.92, 0.82)),
        // Tunnel: shrinking audio rings and a stronger perspective pull.
        MilkDropPreset(warp: 0.017, rotation: 0.038, zoom: 1.014, hueSpeed: 0.016,
                       drift: SIMD2(-0.002, -0.001), hueOffset: 0.88, saturation: 0.94,
                       brightness: 0.9, radialAmount: 0.48, spectrumGain: 0.6,
                       waveformGain: 0.86, decay: 0.938, glow: 0.98, pulse: 1.0,
                       waveWidth: 0.20, symmetry: 1.0, style: 5,
                       waveTint: SIMD3(1.0, 0.66, 0.20))
    ]
}

/// All values are grouped into float4s so the Swift and Metal layouts stay
/// identical on both Intel and Apple Silicon.
private struct MilkDropUniforms {
    var timeDelta = SIMD4<Float>(repeating: 0)
    var audio = SIMD4<Float>(repeating: 0)
    var visual = SIMD4<Float>(repeating: 0)
    var spectrum0 = SIMD4<Float>(repeating: 0)
    var spectrum1 = SIMD4<Float>(repeating: 0)
    var spectrum2 = SIMD4<Float>(repeating: 0)
    var spectrum3 = SIMD4<Float>(repeating: 0)
    var preset0 = SIMD4<Float>(repeating: 0)
    var preset1 = SIMD4<Float>(repeating: 0)
    var preset2 = SIMD4<Float>(repeating: 0)
    var preset3 = SIMD4<Float>(repeating: 0)
    var preset4 = SIMD4<Float>(repeating: 0)
}

/// A small native MilkDrop-style feedback renderer.
///
/// The renderer deliberately keeps the expensive part on the GPU: one
/// feedback pass and one presentation pass per frame.  Audio data comes from
/// PlaybackController's already decoded PCM analysis, so opening this window
/// does not create another decoder or FFT pipeline.
final class MilkDropMetalView: MTKView, MTKViewDelegate {
    private weak var visualization: PlaybackVisualizationState?
    private var observation = Set<AnyCancellable>()

    private let sampleLock = NSLock()
    private var latestSpectrum = Array(repeating: Float(0), count: 16)
    private var latestWaveform = Array(repeating: Float(0), count: 76)
    private var frameSpectrum = Array(repeating: Float(0), count: 16)
    private var frameWaveform = Array(repeating: Float(0), count: 76)
    private var frameWaveVertices = Array(
        repeating: MilkDropWaveVertex(position: SIMD2(0, 0), color: SIMD4(0, 0, 0, 0)),
        count: 76
    )

    private var commandQueue: MTLCommandQueue?
    private var feedbackPipeline: MTLRenderPipelineState?
    private var presentPipeline: MTLRenderPipelineState?
    private var wavePipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var fullscreenBuffer: MTLBuffer?
    private var feedbackTextures: [MTLTexture] = []
    private var feedbackIndex = 0
    private var feedbackTexturesNeedClear = false

    private var rendererAvailable = false
    private var renderingEnabled = false
    private var elapsedTime: Float = 0
    private var lastFrameTime: CFTimeInterval?
    private var currentPresetIndex = 0
    private var presetFrom = MilkDropPresetLibrary.all[0]
    private var presetTo = MilkDropPresetLibrary.all[0]
    private var presetTransitionStart: Float?
    private var nextPresetTime: Float = 15
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedTreble: Float = 0
    private var smoothedVolume: Float = 0
    private var bassBaseline: Float = 0
    private var beatPulse: Float = 0
    private var hasAudioBaseline = false

    private let presetTransitionDuration: Float = 2.7
    private let presetCycleInterval: Float = 15

    init(frame: NSRect, visualization: PlaybackVisualizationState) {
        self.visualization = visualization
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)

        enableSetNeedsDisplay = false
        isPaused = true
        preferredFramesPerSecond = 30
        autoResizeDrawable = false
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self

        configureRenderer(with: metalDevice)
        observeAudioState(visualization)
        let initialIndex = Int.random(in: 0..<MilkDropPresetLibrary.all.count)
        currentPresetIndex = initialIndex
        presetFrom = MilkDropPresetLibrary.all[initialIndex]
        presetTo = presetFrom
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The visualization is display-only. Returning nil keeps title-bar and
    /// resize clicks routed to VisualizationPanelView.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    /// Called by the containing panel whenever its visibility or playback
    /// state changes. Pausing MTKView alone is not enough: release the two
    /// feedback textures as well, so a hidden window retains no render target
    /// and cannot accidentally continue a GPU frame.
    func setRenderingEnabled(_ enabled: Bool) {
        let shouldRender = enabled && rendererAvailable
        guard renderingEnabled != shouldRender else {
            isPaused = !shouldRender
            return
        }
        renderingEnabled = shouldRender
        isPaused = !shouldRender
        lastFrameTime = nil
        elapsedTime = 0
        if shouldRender {
            nextPresetTime = presetCycleInterval
            hasAudioBaseline = false
            updateDrawableSize()
            needsDisplay = true
        } else {
            // A hidden window must not retain a half-finished transition. The
            // target is kept, so reopening is instantaneous and deterministic.
            presetTransitionStart = nil
            presetFrom = presetTo
            feedbackTextures.removeAll(keepingCapacity: false)
            feedbackIndex = 0
        }
    }

    /// Manual preset selection follows Webamp's normal (non-immediate)
    /// transition. It is safe while paused: the selected profile is simply
    /// rendered when playback resumes.
    func selectNextPreset() {
        guard rendererAvailable else { return }
        beginPresetTransition()
    }

    /// A successfully started source always advances to a distinct profile.
    /// This only changes a few parameters when the window is hidden; the
    /// display link and GPU work remain paused until it is visible again.
    func selectPresetForNewTrack() {
        if !renderingEnabled {
            presetTransitionStart = nil
            presetFrom = presetTo
        }
        hasAudioBaseline = false
        beatPulse = 0
        selectNextPreset()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildFeedbackTextures(for: size)
    }

    func draw(in view: MTKView) {
        guard renderingEnabled,
              let commandQueue,
              let feedbackPipeline,
              let presentPipeline,
              let wavePipeline,
              let sampler,
              let fullscreenBuffer,
              let drawable = view.currentDrawable,
              let presentPass = view.currentRenderPassDescriptor else { return }

        if feedbackTextures.count != 2 {
            rebuildFeedbackTextures(for: drawable.texture)
        }
        guard feedbackTextures.count == 2 else { return }

        let now = CACurrentMediaTime()
        let delta = min(0.1, max(0.001, Float(now - (lastFrameTime ?? now))))
        lastFrameTime = now
        elapsedTime += delta

        if elapsedTime >= nextPresetTime {
            beginPresetTransition()
        }
        let preset = currentPreset(at: elapsedTime)

        sampleLock.lock()
        for index in frameSpectrum.indices { frameSpectrum[index] = latestSpectrum[index] }
        for index in frameWaveform.indices { frameWaveform[index] = latestWaveform[index] }
        sampleLock.unlock()

        let rawBass = average(frameSpectrum, from: 0, to: 3)
        let rawMid = average(frameSpectrum, from: 3, to: 8)
        let rawTreble = average(frameSpectrum, from: 8, to: 16)
        let waveformRMS = rootMeanSquare(frameWaveform)
        updateAudioResponse(bass: rawBass, mid: rawMid, treble: rawTreble,
                            waveformRMS: waveformRMS, delta: delta)
        let bass = smoothedBass
        let mid = smoothedMid
        let treble = smoothedTreble
        let volume = smoothedVolume

        var uniforms = MilkDropUniforms()
        uniforms.timeDelta = SIMD4(elapsedTime, delta, bass, mid)
        uniforms.audio = SIMD4(treble, volume, beatPulse, waveformRMS)
        uniforms.visual = SIMD4(sin(elapsedTime * 0.16) * 0.035 + (mid - bass) * 0.02,
                                0.963 + volume * 0.018,
                                fmod(elapsedTime * 0.012 + treble * 0.12, 1),
                                0.025 + volume * 0.06)
        uniforms.spectrum0 = SIMD4(frameSpectrum[0], frameSpectrum[1], frameSpectrum[2], frameSpectrum[3])
        uniforms.spectrum1 = SIMD4(frameSpectrum[4], frameSpectrum[5], frameSpectrum[6], frameSpectrum[7])
        uniforms.spectrum2 = SIMD4(frameSpectrum[8], frameSpectrum[9], frameSpectrum[10], frameSpectrum[11])
        uniforms.spectrum3 = SIMD4(frameSpectrum[12], frameSpectrum[13], frameSpectrum[14], frameSpectrum[15])
        uniforms.preset0 = SIMD4(preset.warp, preset.rotation, preset.zoom, preset.hueSpeed)
        uniforms.preset1 = SIMD4(preset.drift.x, preset.drift.y, preset.hueOffset, preset.saturation)
        uniforms.preset2 = SIMD4(preset.brightness, preset.radialAmount,
                                 preset.spectrumGain, preset.waveformGain)
        uniforms.preset3 = SIMD4(preset.decay, preset.glow, preset.pulse, preset.waveWidth)
        uniforms.preset4 = SIMD4(preset.symmetry, preset.style, 0, 0)

        let writeIndex = feedbackIndex == 0 ? 1 : 0
        let history = feedbackTextures[feedbackIndex]
        let target = feedbackTextures[writeIndex]

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if feedbackTexturesNeedClear {
            for texture in feedbackTextures {
                let clearPass = MTLRenderPassDescriptor()
                clearPass.colorAttachments[0].texture = texture
                clearPass.colorAttachments[0].loadAction = .clear
                clearPass.colorAttachments[0].storeAction = .store
                clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                guard let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) else {
                    commandBuffer.commit()
                    return
                }
                clearEncoder.endEncoding()
            }
            feedbackTexturesNeedClear = false
        }

        let feedbackPass = MTLRenderPassDescriptor()
        feedbackPass.colorAttachments[0].texture = target
        feedbackPass.colorAttachments[0].loadAction = .dontCare
        feedbackPass.colorAttachments[0].storeAction = .store
        guard let feedbackEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: feedbackPass) else {
            commandBuffer.commit()
            return
        }

        feedbackEncoder.setRenderPipelineState(feedbackPipeline)
        feedbackEncoder.setVertexBuffer(fullscreenBuffer, offset: 0, index: 0)
        feedbackEncoder.setFragmentTexture(history, index: 0)
        feedbackEncoder.setFragmentSamplerState(sampler, index: 0)
        feedbackEncoder.setFragmentBytes(&uniforms,
                                         length: MemoryLayout<MilkDropUniforms>.stride,
                                         index: 0)
        feedbackEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        feedbackEncoder.endEncoding()

        presentPass.colorAttachments[0].loadAction = .dontCare
        presentPass.colorAttachments[0].storeAction = .store
        guard let presentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) else {
            commandBuffer.commit()
            return
        }
        presentEncoder.setRenderPipelineState(presentPipeline)
        presentEncoder.setVertexBuffer(fullscreenBuffer, offset: 0, index: 0)
        presentEncoder.setFragmentTexture(target, index: 0)
        presentEncoder.setFragmentSamplerState(sampler, index: 0)
        presentEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        let waveBrightness = 0.22 + volume * 0.58
        let waveColor = SIMD4<Float>(preset.waveTint.x * waveBrightness,
                                     preset.waveTint.y * waveBrightness,
                                     preset.waveTint.z * waveBrightness,
                                     min(0.8, 0.28 + preset.waveWidth))
        for index in frameWaveform.indices {
            let x = -0.96 + 1.92 * Float(index) / Float(frameWaveform.count - 1)
            frameWaveVertices[index] = MilkDropWaveVertex(
                position: SIMD2(x, frameWaveform[index] * (0.12 + volume * 0.1) * preset.waveformGain),
                color: waveColor
            )
        }
        presentEncoder.setRenderPipelineState(wavePipeline)
        presentEncoder.setVertexBytes(frameWaveVertices,
                                      length: MemoryLayout<MilkDropWaveVertex>.stride * frameWaveVertices.count,
                                      index: 0)
        presentEncoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: frameWaveform.count)
        presentEncoder.endEncoding()

        feedbackIndex = writeIndex
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func observeAudioState(_ visualization: PlaybackVisualizationState) {
        visualization.$milkDropSpectrumLevels.sink { [weak self] values in
            self?.copySpectrum(values)
        }.store(in: &observation)
        visualization.$waveformSamples.sink { [weak self] values in
            self?.copyWaveform(values)
        }.store(in: &observation)
    }

    private func copySpectrum(_ values: [CGFloat]) {
        sampleLock.lock()
        for index in latestSpectrum.indices {
            latestSpectrum[index] = index < values.count ? Float(max(0, min(1, values[index]))) : 0
        }
        sampleLock.unlock()
    }

    private func copyWaveform(_ values: [CGFloat]) {
        sampleLock.lock()
        for index in latestWaveform.indices {
            latestWaveform[index] = index < values.count ? Float(max(-1, min(1, values[index]))) : 0
        }
        sampleLock.unlock()
    }

    private func average(_ values: [Float], from start: Int, to end: Int) -> Float {
        guard start < end else { return 0 }
        var total: Float = 0
        for index in start..<min(end, values.count) { total += values[index] }
        return total / Float(max(1, min(end, values.count) - start))
    }

    private func rootMeanSquare(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Float = 0
        for value in values { sum += value * value }
        return min(1, sqrt(sum / Float(values.count)))
    }

    private func updateAudioResponse(bass: Float, mid: Float, treble: Float,
                                     waveformRMS: Float, delta: Float) {
        let volumeTarget = min(1, max(waveformRMS * 3.4,
                                      bass * 0.42 + mid * 0.34 + treble * 0.24))
        if !hasAudioBaseline {
            smoothedBass = bass
            smoothedMid = mid
            smoothedTreble = treble
            smoothedVolume = volumeTarget
            bassBaseline = bass
            hasAudioBaseline = true
        }

        smoothedBass = envelope(smoothedBass, target: bass,
                                attack: 0.025, release: 0.16, delta: delta)
        smoothedMid = envelope(smoothedMid, target: mid,
                               attack: 0.035, release: 0.19, delta: delta)
        smoothedTreble = envelope(smoothedTreble, target: treble,
                                  attack: 0.02, release: 0.12, delta: delta)
        smoothedVolume = envelope(smoothedVolume, target: volumeTarget,
                                  attack: 0.025, release: 0.2, delta: delta)

        let baselineAlpha = 1 - exp(-delta / 1.35)
        bassBaseline += (bass - bassBaseline) * baselineAlpha
        let transient = min(1, max(0, bass - bassBaseline) * 5.5)
        beatPulse = max(transient, beatPulse * exp(-delta / 0.16))
    }

    private func envelope(_ current: Float, target: Float,
                          attack: Float, release: Float, delta: Float) -> Float {
        let duration = target > current ? attack : release
        let alpha = 1 - exp(-delta / duration)
        return current + (target - current) * alpha
    }

    private func beginPresetTransition() {
        guard MilkDropPresetLibrary.all.count > 1 else { return }
        // Pick a random positive offset on the ring. This is uniform among
        // all other profiles and cannot spin indefinitely trying to avoid the
        // current profile.
        let nextIndex = (currentPresetIndex
                         + Int.random(in: 1..<MilkDropPresetLibrary.all.count))
            % MilkDropPresetLibrary.all.count

        let active = currentPreset(at: elapsedTime)
        presetFrom = active
        currentPresetIndex = nextIndex
        presetTo = MilkDropPresetLibrary.all[nextIndex]
        presetTransitionStart = elapsedTime
        nextPresetTime = elapsedTime + presetCycleInterval
    }

    private func currentPreset(at time: Float) -> MilkDropPreset {
        guard let start = presetTransitionStart else { return presetTo }
        let progress = (time - start) / presetTransitionDuration
        if progress >= 1 {
            presetTransitionStart = nil
            presetFrom = presetTo
            return presetTo
        }
        // Smoothstep keeps the two parameter sets from visibly snapping at
        // either end of the transition, like Butterchurn's default blend.
        let eased = progress * progress * (3 - 2 * progress)
        return presetFrom.interpolated(to: presetTo, amount: eased)
    }

    private func configureRenderer(with device: MTLDevice?) {
        guard let device,
              let library = device.makeDefaultLibrary(),
              let commandQueue = device.makeCommandQueue(),
              let feedbackFunction = library.makeFunction(name: "milkDropFeedback"),
              let presentFunction = library.makeFunction(name: "milkDropPresent"),
              let waveVertexFunction = library.makeFunction(name: "milkDropWaveVertex"),
              let waveFragmentFunction = library.makeFunction(name: "milkDropWaveFragment") else { return }

        let feedbackDescriptor = MTLRenderPipelineDescriptor()
        feedbackDescriptor.vertexFunction = library.makeFunction(name: "milkDropFullscreenVertex")
        feedbackDescriptor.fragmentFunction = feedbackFunction
        feedbackDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        let presentDescriptor = MTLRenderPipelineDescriptor()
        presentDescriptor.vertexFunction = library.makeFunction(name: "milkDropFullscreenVertex")
        presentDescriptor.fragmentFunction = presentFunction
        presentDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        let waveDescriptor = MTLRenderPipelineDescriptor()
        waveDescriptor.vertexFunction = waveVertexFunction
        waveDescriptor.fragmentFunction = waveFragmentFunction
        waveDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        waveDescriptor.colorAttachments[0].isBlendingEnabled = true
        waveDescriptor.colorAttachments[0].rgbBlendOperation = .add
        waveDescriptor.colorAttachments[0].alphaBlendOperation = .add
        waveDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        waveDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        waveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        waveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let feedbackPipeline = try? device.makeRenderPipelineState(descriptor: feedbackDescriptor),
              let presentPipeline = try? device.makeRenderPipelineState(descriptor: presentDescriptor),
              let wavePipeline = try? device.makeRenderPipelineState(descriptor: waveDescriptor) else { return }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat

        let fullscreenVertices = [
            MilkDropFullscreenVertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
            MilkDropFullscreenVertex(position: SIMD2(1, -1), uv: SIMD2(1, 1)),
            MilkDropFullscreenVertex(position: SIMD2(-1, 1), uv: SIMD2(0, 0)),
            MilkDropFullscreenVertex(position: SIMD2(1, 1), uv: SIMD2(1, 0))
        ]
        guard let fullscreenBuffer = device.makeBuffer(bytes: fullscreenVertices,
                                                        length: MemoryLayout<MilkDropFullscreenVertex>.stride * fullscreenVertices.count,
                                                        options: .storageModeShared),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return }

        self.commandQueue = commandQueue
        self.feedbackPipeline = feedbackPipeline
        self.presentPipeline = presentPipeline
        self.wavePipeline = wavePipeline
        self.sampler = sampler
        self.fullscreenBuffer = fullscreenBuffer
        rendererAvailable = true
    }

    private func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var width = max(1, Int((bounds.width * backingScale).rounded()))
        var height = max(1, Int((bounds.height * backingScale).rounded()))
        let maxPixels = 640 * 480
        let pixelScale = min(1, sqrt(Float(maxPixels) / Float(width * height)),
                             800 / Float(max(width, height)))
        width = max(1, Int((Float(width) * pixelScale).rounded()))
        height = max(1, Int((Float(height) * pixelScale).rounded()))
        let target = CGSize(width: width, height: height)
        if drawableSize != target { drawableSize = target }
    }

    private func rebuildFeedbackTextures(for texture: MTLTexture) {
        rebuildFeedbackTextures(for: CGSize(width: texture.width, height: texture.height))
    }

    private func rebuildFeedbackTextures(for size: CGSize) {
        guard let device, size.width > 0, size.height > 0 else {
            feedbackTextures.removeAll(keepingCapacity: false)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                    width: max(1, Int(size.width.rounded())),
                                                                    height: max(1, Int(size.height.rounded())),
                                                                    mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor) else {
            feedbackTextures.removeAll(keepingCapacity: false)
            return
        }
        feedbackTextures = [first, second]
        feedbackIndex = 0
        feedbackTexturesNeedClear = true
    }
}
