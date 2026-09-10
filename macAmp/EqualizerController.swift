import Foundation
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

enum AdaptiveEQCorrectionRange: Int, CaseIterable, Identifiable {
    case `default` = 4
    case extended = 6

    var id: Int { rawValue }
    var maximumCorrection: Double { Double(rawValue) }
    var title: String {
        switch self {
        case .default: return "±4 dB (default)"
        case .extended: return "±6 dB"
        }
    }
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

enum EqualizerPresetFileError: LocalizedError {
    case invalidHeader
    case invalidRecordLength
    case invalidPresetName
    case invalidPresetValues
    case noPresets

    var errorDescription: String? {
        switch self {
        case .invalidHeader: return "The file is not a Winamp EQ library file."
        case .invalidRecordLength: return "The Winamp EQ library contains an incomplete preset record."
        case .invalidPresetName: return "The Winamp EQ library contains a preset with an invalid name."
        case .invalidPresetValues: return "The Winamp EQ library contains invalid equalizer values."
        case .noPresets: return "The Winamp EQ library does not contain any presets."
        }
    }
}

/// UI-independent EQ state. Values are expressed in dB and are applied by PlaybackController.
final class EqualizerController: ObservableObject {
    static let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    private static let range = -20.0...20.0

    @Published var isEnabled = true {
        didSet {
            if oldValue != isEnabled { onPersistenceChange?() }
            onChange?()
        }
    }
    @Published var isAdaptiveEnabled = false {
        didSet {
            guard oldValue != isAdaptiveEnabled else { return }
            UserDefaults.standard.set(isAdaptiveEnabled, forKey: adaptiveEnabledDefaultsKey)
            if isAdaptiveEnabled {
                adaptiveReturnTimer?.invalidate()
                adaptiveReturnTimer = nil
            } else if oldValue {
                beginAdaptiveReturn()
            }
            onPersistenceChange?()
            onChange?()
        }
    }
    @Published var adaptiveCorrectionRange: AdaptiveEQCorrectionRange = .default {
        didSet {
            if oldValue != adaptiveCorrectionRange { onPersistenceChange?() }
            adaptiveConfiguration.maximumCorrection = adaptiveCorrectionRange.maximumCorrection
            let maximum = adaptiveConfiguration.maximumCorrection
            adaptiveBands = adaptiveBands.map { min(maximum, max(-maximum, $0)) }
            pendingAdaptiveBands = pendingAdaptiveBands.map { min(maximum, max(-maximum, $0)) }
            UserDefaults.standard.set(adaptiveCorrectionRange.rawValue, forKey: adaptiveCorrectionRangeDefaultsKey)
            // The range applies to automatic band correction only. Keep the
            // current adaptive Preamp component untouched when it changes.
            refreshFinalValues()
        }
    }
    @Published private(set) var preamp = 0.0
    @Published private(set) var bands = Array(repeating: 0.0, count: 10)
    @Published private(set) var selectedPresetName = "Flat"
    @Published private(set) var userPresets: [EqualizerPreset] = []

    /// Called on the main thread after every state mutation; the audio engine owns DSP objects.
    var onChange: (() -> Void)?
    /// Called only for user-owned settings. Adaptive frames must not schedule a
    /// persistent-state write while the audio stream is playing.
    var onPersistenceChange: (() -> Void)?
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
    private let customPresetsKey = "macAmp.equalizer.customPresets"
    private let adaptiveEnabledDefaultsKey = "macAmp.equalizer.adaptiveEnabled"
    private let adaptiveCorrectionRangeDefaultsKey = "macAmp.equalizer.adaptiveCorrectionRange"
    private static let winampEQFSignature: [UInt8] = Array("Winamp EQ library file v1.1".utf8) + [0x1A, 0x21, 0x2D, 0x2D]
    private static let winampEQFNameFieldLength = 257
    private static let winampEQFRecordLength = winampEQFNameFieldLength + 11

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
        if let storedRange = UserDefaults.standard.object(forKey: adaptiveCorrectionRangeDefaultsKey) as? Int,
           let range = AdaptiveEQCorrectionRange(rawValue: storedRange) {
            adaptiveCorrectionRange = range
            adaptiveConfiguration.maximumCorrection = range.maximumCorrection
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
        onPersistenceChange?()
    }

    func setPreamp(_ db: Double) {
        let value = clamp(db)
        if isAdaptiveEnabled { userPreampOffset = value - basePreamp - adaptivePreamp }
        else { basePreamp = value }
        refreshFinalValues()
        onPersistenceChange?()
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
        onPersistenceChange?()
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
        onPersistenceChange?()
    }

    func saveCurrentPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EqualizerPreset(name: trimmed, preamp: preamp, bands: bands)
        userPresets.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        userPresets.append(preset)
        selectedPresetName = trimmed
        persistCustomPresets()
        onPersistenceChange?()
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        if selectedPresetName == name { selectedPresetName = "Flat" }
        persistCustomPresets()
        onPersistenceChange?()
    }

    @discardableResult
    func importUserPresets(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let imported = try Self.presets(fromWinampEQF: data)
        var merged = userPresets
        for preset in imported {
            merged.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
            merged.append(preset)
        }
        userPresets = merged
        persistCustomPresets()
        onPersistenceChange?()
        return imported.count
    }

    func exportUserPresets(to url: URL) throws {
        guard !userPresets.isEmpty else { throw EqualizerPresetFileError.noPresets }
        try Self.winampEQFData(for: userPresets).write(to: url, options: .atomic)
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
        if didApplyAdaptiveCorrection, !selectedPresetName.isEmpty { selectedPresetName = "" }
        refreshFinalValues()
    }

    func disableAdaptiveCorrection() {
        guard !isAdaptiveEnabled else { return }
        beginAdaptiveReturn()
    }

    private func refreshFinalValues() {
        let includeAdaptive = isAdaptiveEnabled || adaptiveReturnTimer != nil
        let nextPreamp = clamp(basePreamp + userPreampOffset + (includeAdaptive ? adaptivePreamp : 0))
        let nextBands = bands.indices.map {
            clamp(baseBands[$0] + userBandOffsets[$0] + (includeAdaptive ? adaptiveBands[$0] : 0))
        }
        let preampChanged = abs(preamp - nextPreamp) >= 0.001
        let bandsChanged = bands.count != nextBands.count || zip(bands, nextBands).contains {
            abs($0 - $1) >= 0.001
        }
        guard preampChanged || bandsChanged else { return }
        if preampChanged { preamp = nextPreamp }
        if bandsChanged { bands = nextBands }
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
            guard !InterfaceRenderGate.isSuspended else { return }
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
            guard !InterfaceRenderGate.isSuspended else { return }
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

    private static func presets(fromWinampEQF data: Data) throws -> [EqualizerPreset] {
        let signature = Data(winampEQFSignature)
        guard data.count >= signature.count, Data(data.prefix(signature.count)) == signature else {
            throw EqualizerPresetFileError.invalidHeader
        }
        let payloadLength = data.count - signature.count
        guard payloadLength % winampEQFRecordLength == 0 else {
            throw EqualizerPresetFileError.invalidRecordLength
        }
        guard payloadLength > 0 else { throw EqualizerPresetFileError.noPresets }

        var presets: [EqualizerPreset] = []
        presets.reserveCapacity(payloadLength / winampEQFRecordLength)
        var offset = signature.count
        while offset < data.count {
            let recordEnd = offset + winampEQFRecordLength
            guard recordEnd <= data.count else { throw EqualizerPresetFileError.invalidRecordLength }

            let nameField = data[offset..<(offset + winampEQFNameFieldLength)]
            guard let terminator = nameField.firstIndex(of: 0) else {
                throw EqualizerPresetFileError.invalidPresetName
            }
            let nameData = Data(nameField[..<terminator])
            guard let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .windowsCP1252),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EqualizerPresetFileError.invalidPresetName
            }

            let valuesStart = offset + winampEQFNameFieldLength
            let values = Array(data[valuesStart..<recordEnd])
            guard values.count == 11, values.allSatisfy({ $0 <= 63 }) else {
                throw EqualizerPresetFileError.invalidPresetValues
            }
            let bands = values.prefix(10).map(dbValue(fromWinamp:))
            let preamp = dbValue(fromWinamp: values[10])
            presets.append(EqualizerPreset(name: name, preamp: preamp, bands: bands))
            offset = recordEnd
        }
        return presets
    }

    private static func winampEQFData(for presets: [EqualizerPreset]) throws -> Data {
        var data = Data(winampEQFSignature)
        for preset in presets {
            guard preset.bands.count == 10 else { throw EqualizerPresetFileError.invalidPresetValues }
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EqualizerPresetFileError.invalidPresetName
            }
            data.append(contentsOf: try winampNameField(for: preset.name))
            let values = try (preset.bands + [preset.preamp]).map(winampValue(fromDB:))
            data.append(contentsOf: values)
        }
        return data
    }

    private static func winampNameField(for name: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(256, name.utf8.count))
        for character in name {
            let characterBytes = Array(String(character).utf8)
            guard bytes.count + characterBytes.count <= 256 else { break }
            bytes.append(contentsOf: characterBytes)
        }
        guard !bytes.isEmpty else { throw EqualizerPresetFileError.invalidPresetName }
        bytes.append(contentsOf: repeatElement(UInt8(0), count: winampEQFNameFieldLength - bytes.count))
        return bytes
    }

    private static func winampValue(fromDB value: Double) throws -> UInt8 {
        guard value.isFinite else { throw EqualizerPresetFileError.invalidPresetValues }
        let rawValue = Int((31 - value * 31 / 20).rounded())
        return UInt8(min(63, max(0, rawValue)))
    }

    private static func dbValue(fromWinamp value: UInt8) -> Double {
        min(20, max(-20, Double(31 - Int(value)) * 20 / 31))
    }

    private static func preset(_ name: String, _ winampValues: [Int]) -> EqualizerPreset {
        // Winamp's original 0...63 slider uses 31 as neutral and is vertically inverted.
        EqualizerPreset(name: name, preamp: 0, bands: winampValues.map { Double(31 - $0) * 20 / 31 })
    }
}
