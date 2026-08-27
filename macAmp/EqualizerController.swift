import AVFoundation
import Combine

/// Tunable parameters for the local, real-time Adaptive EQ v2 algorithm.
/// They deliberately live outside the UI so DSP and presentation can run at
/// different rates.
struct AdaptiveEQConfiguration {
    // A 1024-sample window is ample for the 16-column Winamp visualizer and
    // keeps the optional adaptive EQ from waking a performance core too often.
    var fftSize = 1_024
    var fftOverlap = 0.5
    // 6 FPS is sufficient for the 76×15 classic pixel analyzer and avoids
    // continuously competing with audio rendering on portable Macs.
    var analysisInterval = 1.0 / 6.0
    var spectralAttackTime = 0.8
    var spectralReleaseTime = 1.8
    var referenceSlopeDBPerOctave = -3.0
    var adaptationStrength = 0.5
    var maximumCorrection = 4.0
    var deadZone = 0.5
    var attackTime = 1.0
    var releaseTime = 2.5
    var minimumPersistenceTime = 0.4
    var neighbourDifferenceLimit = 2.0
    var smoothnessPenalty = 0.18
    var maximumGlobalSlope = 3.0
    var preampHeadroom = 0.0
    var minimumAdaptivePreamp = -3.0
}

struct EqualizerPreset: Identifiable, Equatable, Codable {
    let name: String
    let preamp: Double
    let bands: [Double]
    var id: String { name }
}

struct EqualizerPersistentState: Codable {
    let isEnabled: Bool
    let isAdaptiveEnabled: Bool
    let basePreamp: Double
    let baseBands: [Double]
    let userPreampOffset: Double
    let userBandOffsets: [Double]
    let adaptivePreamp: Double
    let adaptiveBands: [Double]
    let selectedPresetName: String
}

/// UI-independent EQ state. Values are expressed in dB and are applied by PlaybackController.
final class EqualizerController: ObservableObject {
    static let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    private static let range = -20.0...20.0

    @Published var isEnabled = true { didSet { onChange?() } }
    @Published var isAdaptiveEnabled = false {
        didSet {
            UserDefaults.standard.set(isAdaptiveEnabled, forKey: adaptiveEnabledDefaultsKey)
            if isAdaptiveEnabled {
                adaptiveReturnTimer?.invalidate()
                adaptiveReturnTimer = nil
            } else if oldValue {
                beginAdaptiveReturn()
            }
            onChange?()
        }
    }
    @Published private(set) var preamp = 0.0
    @Published private(set) var bands = Array(repeating: 0.0, count: 10)
    @Published private(set) var selectedPresetName = "Flat"
    @Published private(set) var userPresets: [EqualizerPreset] = []

    /// Called on the main thread after every state mutation; the audio engine owns DSP objects.
    var onChange: (() -> Void)?
    var adaptiveConfiguration = AdaptiveEQConfiguration()
    private var basePreamp = 0.0
    private var baseBands = Array(repeating: 0.0, count: 10)
    private var userPreampOffset = 0.0
    private var userBandOffsets = Array(repeating: 0.0, count: 10)
    private var adaptivePreamp = 0.0
    private var adaptiveBands = Array(repeating: 0.0, count: 10)
    private var pendingAdaptiveBands = Array(repeating: 0.0, count: 10)
    private var pendingSince = Array(repeating: Date.distantPast, count: 10)
    private var adaptiveReturnTimer: Timer?
    private var presetPreampReturnTimer: Timer?
    private let customPresetsKey = "MacAmp.equalizer.customPresets"
    private let adaptiveEnabledDefaultsKey = "MacAmp.equalizer.adaptiveEnabled"

    static let factoryPresets: [EqualizerPreset] = [
        preset("Classical", [31,31,31,31,31,31,44,44,44,48]),
        preset("Club", [31,31,26,22,22,22,26,31,31,31]),
        preset("Dance", [16,20,28,32,32,42,44,44,32,32]),
        preset("Flat", [31,31,31,31,31,31,31,31,31,31]),
        preset("Laptop speakers/headphones", [24,14,23,38,36,29,24,16,11,8]),
        preset("Large hall", [15,15,22,22,31,40,40,40,31,31]),
        preset("Party", [20,20,31,31,31,31,31,31,20,20]),
        preset("Pop", [35,24,20,19,23,34,36,36,35,35]),
        preset("Reggae", [31,31,33,42,31,21,21,31,31,31]),
        preset("Rock", [19,24,41,45,38,25,17,14,14,14]),
        preset("Soft", [24,29,34,36,34,25,18,16,14,12]),
        preset("Ska", [36,40,39,33,25,22,17,16,14,16]),
        preset("Full Bass", [16,16,16,22,29,39,46,49,50,50]),
        preset("Soft Rock", [25,25,28,33,39,41,38,33,27,17]),
        preset("Full Treble", [48,48,48,39,27,14,6,6,6,4]),
        preset("Full Bass & Treble", [20,22,31,44,40,29,18,14,12,12]),
        preset("Live", [40,31,25,23,22,22,25,27,27,28]),
        preset("Techno", [19,22,31,41,40,31,19,16,16,17])
    ]

    init() {
        // Keep AUTO independent from the broader window-layout snapshot. That
        // snapshot can legitimately evolve, while the user's AUTO choice must
        // survive every restart and schema migration.
        if UserDefaults.standard.object(forKey: adaptiveEnabledDefaultsKey) != nil {
            isAdaptiveEnabled = UserDefaults.standard.bool(forKey: adaptiveEnabledDefaultsKey)
        }
        if let data = UserDefaults.standard.data(forKey: customPresetsKey),
           let decoded = try? JSONDecoder().decode([EqualizerPreset].self, from: data) {
            userPresets = decoded
        }
    }

    deinit {
        adaptiveReturnTimer?.invalidate()
        presetPreampReturnTimer?.invalidate()
    }

    func setBand(_ index: Int, db: Double) {
        guard bands.indices.contains(index) else { return }
        let value = clamp(db)
        if isAdaptiveEnabled { userBandOffsets[index] = value - baseBands[index] - adaptiveBands[index] }
        else { baseBands[index] = value }
        refreshFinalValues()
    }

    func setPreamp(_ db: Double) {
        let value = clamp(db)
        if isAdaptiveEnabled { userPreampOffset = value - basePreamp - adaptivePreamp }
        else { basePreamp = value }
        refreshFinalValues()
    }

    func setAllBands(_ db: Double) { for index in bands.indices { setBand(index, db: db) } }

    func load(_ preset: EqualizerPreset) {
        basePreamp = clamp(preset.preamp)
        baseBands = preset.bands.map(clamp)
        userPreampOffset = 0
        userBandOffsets = Array(repeating: 0, count: 10)
        selectedPresetName = preset.name
        // A preset must start with its own neutral Preamp. Keep the adaptive
        // band shape, but release the headroom correction without a click.
        beginPresetPreampReturn()
        refreshFinalValues()
    }

    /// Reset always returns every visible control to its physical centre (0 dB),
    /// including the current adaptive component when AUTO is enabled.
    func reset() {
        basePreamp = 0
        baseBands = Array(repeating: 0, count: 10)
        userPreampOffset = 0
        userBandOffsets = Array(repeating: 0, count: 10)
        adaptivePreamp = 0
        adaptiveBands = Array(repeating: 0, count: 10)
        selectedPresetName = "Flat"
        refreshFinalValues()
    }

    func saveCurrentPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EqualizerPreset(name: trimmed, preamp: preamp, bands: bands)
        userPresets.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        userPresets.append(preset)
        selectedPresetName = trimmed
        persistCustomPresets()
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        if selectedPresetName == name { selectedPresetName = "Flat" }
        persistCustomPresets()
    }

    func persistentState() -> EqualizerPersistentState {
        EqualizerPersistentState(
            isEnabled: isEnabled, isAdaptiveEnabled: isAdaptiveEnabled,
            basePreamp: basePreamp, baseBands: baseBands,
            userPreampOffset: userPreampOffset, userBandOffsets: userBandOffsets,
            adaptivePreamp: adaptivePreamp, adaptiveBands: adaptiveBands,
            selectedPresetName: selectedPresetName
        )
    }

    func restorePersistentState(_ state: EqualizerPersistentState) {
        guard state.baseBands.count == 10, state.userBandOffsets.count == 10, state.adaptiveBands.count == 10 else { return }
        isEnabled = state.isEnabled
        isAdaptiveEnabled = state.isAdaptiveEnabled
        basePreamp = clamp(state.basePreamp)
        baseBands = state.baseBands.map(clamp)
        userPreampOffset = state.userPreampOffset
        userBandOffsets = state.userBandOffsets
        adaptivePreamp = state.adaptivePreamp
        adaptiveBands = state.adaptiveBands.map { min(adaptiveConfiguration.maximumCorrection, max(-adaptiveConfiguration.maximumCorrection, $0)) }
        selectedPresetName = state.selectedPresetName
        refreshFinalValues()
    }

    /// Receives local (tilt-free) corrections from the analyser. Persistence,
    /// attack/release and all final safety limits are applied here so manual
    /// adjustments and the DSP always use the same final EQ state.
    func updateAdaptive(targetBands: [Double], targetPreamp: Double) {
        guard isAdaptiveEnabled, targetBands.count == 10 else { return }
        let configuration = adaptiveConfiguration
        let now = Date()
        var target = regularized(targetBands, configuration: configuration)
        for index in target.indices {
            if abs(target[index] - pendingAdaptiveBands[index]) >= configuration.deadZone {
                pendingAdaptiveBands[index] = target[index]
                pendingSince[index] = now
            }
            if now.timeIntervalSince(pendingSince[index]) < configuration.minimumPersistenceTime {
                target[index] = adaptiveBands[index]
            } else {
                target[index] = pendingAdaptiveBands[index]
            }
        }

        // Keep automatic boosts within the amount that can be protected by the
        // permitted adaptive preamp reduction. Manual/base boosts are retained.
        target = limitAutomaticBoostsForHeadroom(target, configuration: configuration)
        var didApplyAdaptiveCorrection = false
        for index in bands.indices {
            let duration = target[index] > adaptiveBands[index]
                ? configuration.attackTime : configuration.releaseTime
            let smoothing = smoothingFactor(duration: duration, interval: configuration.analysisInterval)
            if abs(target[index] - adaptiveBands[index]) >= 0.01 {
                adaptiveBands[index] += (target[index] - adaptiveBands[index]) * smoothing
                didApplyAdaptiveCorrection = true
            }
        }
        // Headroom is based on the prospective *final* band curve, not on the
        // sum of boosts. This keeps Preamp at 0 dB unless an actual peak gain
        // needs protection.
        let baseAndUserBands = zip(baseBands, userBandOffsets).map(+)
        let peakFinalBand = zip(baseAndUserBands, target).map(+).max() ?? 0
        let requiredFinalPreamp = min(0, configuration.preampHeadroom - peakFinalBand)
        let requiredAdaptivePreamp = requiredFinalPreamp - basePreamp - userPreampOffset
        let calculatedPreamp = min(0, max(configuration.minimumAdaptivePreamp, min(targetPreamp, requiredAdaptivePreamp)))
        // Do not fight the release animation started by a preset change.
        let protectedPreamp = presetPreampReturnTimer == nil ? calculatedPreamp : 0
        if abs(protectedPreamp - adaptivePreamp) >= 0.05 { didApplyAdaptiveCorrection = true }
        let preampDuration = protectedPreamp < adaptivePreamp ? configuration.attackTime : configuration.releaseTime
        adaptivePreamp += (protectedPreamp - adaptivePreamp) * smoothingFactor(duration: preampDuration, interval: configuration.analysisInterval)
        // The preset remains the adaptive base, but the final curve is no longer
        // identical to it and therefore must not be marked as selected in the UI.
        if didApplyAdaptiveCorrection { selectedPresetName = "" }
        refreshFinalValues()
    }

    func disableAdaptiveCorrection() {
        guard !isAdaptiveEnabled else { return }
        beginAdaptiveReturn()
    }

    private func refreshFinalValues() {
        let includeAdaptive = isAdaptiveEnabled || adaptiveReturnTimer != nil
        preamp = clamp(basePreamp + userPreampOffset + (includeAdaptive ? adaptivePreamp : 0))
        bands = bands.indices.map { clamp(baseBands[$0] + userBandOffsets[$0] + (includeAdaptive ? adaptiveBands[$0] : 0)) }
        onChange?()
    }

    private func regularized(_ rawTarget: [Double], configuration: AdaptiveEQConfiguration) -> [Double] {
        var target = rawTarget.map { min(configuration.maximumCorrection, max(-configuration.maximumCorrection, $0)) }
        // Adaptive EQ changes shape rather than overall level.
        let mean = target.reduce(0, +) / Double(target.count)
        target = target.map { abs($0 - mean) < configuration.deadZone ? 0 : $0 - mean }

        // A light second-derivative relaxation followed by hard neighbour and
        // end-to-end limits prevents a staircase/diagonal curve.
        for _ in 0..<8 {
            let previous = target
            for index in 1..<(target.count - 1) {
                let curvature = previous[index + 1] - 2 * previous[index] + previous[index - 1]
                target[index] += curvature * configuration.smoothnessPenalty
            }
            for index in 1..<target.count {
                let difference = target[index] - target[index - 1]
                if abs(difference) > configuration.neighbourDifferenceLimit {
                    let excess = (abs(difference) - configuration.neighbourDifferenceLimit) / 2
                    target[index] -= difference.sign == .plus ? excess : -excess
                    target[index - 1] += difference.sign == .plus ? excess : -excess
                }
            }
            let edgeDifference = target[target.count - 1] - target[0]
            if abs(edgeDifference) > configuration.maximumGlobalSlope {
                let excess = (abs(edgeDifference) - configuration.maximumGlobalSlope) / 2
                target[0] += edgeDifference.sign == .plus ? excess : -excess
                target[target.count - 1] -= edgeDifference.sign == .plus ? excess : -excess
            }
        }
        let finalMean = target.reduce(0, +) / Double(target.count)
        return target.map { min(configuration.maximumCorrection, max(-configuration.maximumCorrection, $0 - finalMean)) }
    }

    private func limitAutomaticBoostsForHeadroom(_ target: [Double], configuration: AdaptiveEQConfiguration) -> [Double] {
        let baseAndUser = zip(baseBands, userBandOffsets).map(+)
        let maximumAllowedBandGain = configuration.preampHeadroom - configuration.minimumAdaptivePreamp
        return target.indices.map { index in
            guard target[index] > 0 else { return target[index] }
            return min(target[index], maximumAllowedBandGain - baseAndUser[index])
        }
    }

    private func smoothingFactor(duration: Double, interval: Double) -> Double {
        1 - exp(-interval / max(duration, 0.001))
    }

    private func beginAdaptiveReturn() {
        guard adaptiveReturnTimer == nil else { return }
        adaptiveReturnTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let factor = self.smoothingFactor(duration: self.adaptiveConfiguration.releaseTime, interval: 1.0 / 30.0)
            self.adaptiveBands = self.adaptiveBands.map { abs($0) < 0.01 ? 0 : $0 + (0 - $0) * factor }
            self.adaptivePreamp = abs(self.adaptivePreamp) < 0.01 ? 0 : self.adaptivePreamp + (0 - self.adaptivePreamp) * factor
            self.refreshFinalValues()
            if self.adaptiveBands.allSatisfy({ $0 == 0 }) && self.adaptivePreamp == 0 {
                timer.invalidate()
                self.adaptiveReturnTimer = nil
                self.refreshFinalValues()
            }
        }
    }

    private func beginPresetPreampReturn() {
        presetPreampReturnTimer?.invalidate()
        guard abs(adaptivePreamp) >= 0.01 else {
            adaptivePreamp = 0
            return
        }
        presetPreampReturnTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let factor = self.smoothingFactor(duration: self.adaptiveConfiguration.releaseTime, interval: 1.0 / 30.0)
            self.adaptivePreamp += (0 - self.adaptivePreamp) * factor
            if abs(self.adaptivePreamp) < 0.01 {
                self.adaptivePreamp = 0
                timer.invalidate()
                self.presetPreampReturnTimer = nil
            }
            self.refreshFinalValues()
        }
    }

    private func clamp(_ value: Double) -> Double { min(Self.range.upperBound, max(Self.range.lowerBound, value)) }

    private func persistCustomPresets() {
        if let data = try? JSONEncoder().encode(userPresets) { UserDefaults.standard.set(data, forKey: customPresetsKey) }
    }

    private static func preset(_ name: String, _ winampValues: [Int]) -> EqualizerPreset {
        // Winamp's original 0...63 slider uses 31 as neutral and is vertically inverted.
        EqualizerPreset(name: name, preamp: 0, bands: winampValues.map { Double(31 - $0) * 20 / 31 })
    }
}
