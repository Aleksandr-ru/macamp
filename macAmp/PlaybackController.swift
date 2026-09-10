import AVFoundation
import AppKit
import Combine
import Accelerate
import CoreAudio
import AudioToolbox
import os

/// A title-bar drag has a much stricter latency budget than normal playback.
/// Timers use this main-thread gate to defer cosmetic updates until mouse-up.
enum InterfaceRenderGate {
    static var isSuspended = false
}

enum ShuffleMode: Int, CaseIterable {
    case off = 0
    case currentPlaylist = 1
    case allPlaylists = 2

    var title: String {
        switch self {
        case .off: return "Off"
        case .currentPlaylist: return "Current Playlist"
        case .allPlaylists: return "All Playlists"
        }
    }
}

enum RepeatMode: Int, CaseIterable {
    case off = 0
    case currentTrack = 1
    case currentPlaylist = 2

    var title: String {
        switch self {
        case .off: return "Off"
        case .currentTrack: return "Current Track"
        case .currentPlaylist: return "Current Playlist"
        }
    }
}

enum VisualizationMode: Int {
    case off
    case spectrum
    case oscilloscope

    var analyzer: VisualizationAnalyzer {
        switch self {
        case .off: return .off
        case .spectrum: return .spectrum
        case .oscilloscope: return .oscilloscope
        }
    }

    mutating func advance() {
        self = VisualizationMode(rawValue: rawValue == VisualizationMode.oscilloscope.rawValue ? 0 : rawValue + 1) ?? .off
    }
}

enum VisualizationAnalyzer: String, CaseIterable, Identifiable {
    case off
    case spectrum
    case oscilloscope

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .spectrum: return "Spectrum analyzer"
        case .oscilloscope: return "Oscilloscope"
        }
    }

    var visualizationMode: VisualizationMode {
        switch self {
        case .off: return .off
        case .spectrum: return .spectrum
        case .oscilloscope: return .oscilloscope
        }
    }
}

/// High-frequency state is kept separate from transport state so spectrum
/// frames do not invalidate the whole player interface.
final class PlaybackVisualizationState: ObservableObject {
    @Published var spectrumLevels = Array(repeating: CGFloat(0), count: 16)
    /// Unquantized FFT levels for the MilkDrop renderer. The classic analyzer
    /// intentionally keeps its 15-row falloff, which is too coarse and slow
    /// for beat-reactive preset equations.
    @Published var milkDropSpectrumLevels = Array(repeating: CGFloat(0), count: 16)
    /// The peak marker is kept separately from the bar levels.  Winamp's
    /// classic renderer lets each marker fall independently of its column.
    @Published var spectrumPeaks = Array(repeating: CGFloat(0), count: 16)
    @Published var waveformSamples = Array(repeating: CGFloat(0), count: 76)

    private static let showsPeaksPreferenceKey = "macAmp.visualization.showsPeaks"
    private static let analyzerPreferenceKey = "macAmp.visualization.analyzer"

    @Published var analyzer: VisualizationAnalyzer {
        didSet {
            guard oldValue != analyzer else { return }
            UserDefaults.standard.set(analyzer.rawValue, forKey: Self.analyzerPreferenceKey)
        }
    }

    @Published var showsPeaks: Bool {
        didSet {
            guard oldValue != showsPeaks else { return }
            UserDefaults.standard.set(showsPeaks, forKey: Self.showsPeaksPreferenceKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        analyzer = defaults.string(forKey: Self.analyzerPreferenceKey)
            .flatMap(VisualizationAnalyzer.init(rawValue:)) ?? .spectrum
        showsPeaks = defaults.object(forKey: Self.showsPeaksPreferenceKey) == nil
            ? true
            : defaults.bool(forKey: Self.showsPeaksPreferenceKey)
    }
}

/// High-frequency clock updates are isolated from transport and settings.
/// A position tick must not invalidate every player and playlist view that
/// observes PlaybackController.
final class PlaybackClockState: ObservableObject {
    @Published fileprivate(set) var position: Double = 0
    @Published fileprivate(set) var pendingSeekPosition: Double?
}

/// Reuses all FFT storage. The spectrum queue is serial, so one workspace per
/// transform size avoids heap traffic without adding synchronization.
private final class FFTWorkspace {
    let size: Int
    private let halfSize: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]

    init?(size: Int) {
        self.size = size
        halfSize = size / 2
        log2Size = vDSP_Length(log2(Float(size)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        window = Array(repeating: 0, count: size)
        windowed = Array(repeating: 0, count: size)
        real = Array(repeating: 0, count: halfSize)
        imaginary = Array(repeating: 0, count: halfSize)
        power = Array(repeating: 0, count: halfSize)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func withPower<R>(samples: ArraySlice<Float>, _ body: ([Float]) -> R) -> R? {
        guard samples.count >= size else { return nil }
        let source = samples.suffix(size)
        source.withUnsafeBufferPointer { sourceBuffer in
            window.withUnsafeBufferPointer { windowBuffer in
                vDSP_vmul(sourceBuffer.baseAddress!, 1, windowBuffer.baseAddress!, 1,
                          &windowed, 1, vDSP_Length(size))
            }
        }
        windowed.withUnsafeMutableBufferPointer { sourceBuffer in
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    sourceBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfSize))
                }
            }
        }
        power[0] = real[0] * real[0]
        return body(power)
    }
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let type: String
    let isDefault: Bool
}

/// Keeps the output-device list in sync with Core Audio and remembers the
/// user's last explicit choice separately from the currently available route.
/// The preferred UID is intentionally retained when a device is unplugged so
/// the next launch can try that device again.
final class AudioOutputDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var selectedDeviceID: AudioDeviceID?
    @Published private(set) var selectedDeviceUID: String?
    @Published private(set) var defaultDeviceID: AudioDeviceID?

    var onDeviceSelected: ((AudioDeviceID) -> Void)?
    var onSelectedDeviceUnavailable: ((AudioDeviceID?) -> Void)?

    private static let preferredDeviceUIDKey = "macAmp.audio.preferredOutputDeviceUID"
    private static let deviceLogger = Logger(
        subsystem: "ru.aleksandr.macAmp",
        category: "AudioOutputDevices"
    )
    private let defaults: UserDefaults
    private let listenerQueue = DispatchQueue(label: "ru.aleksandr.macAmp.audio.devices", qos: .utility)
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var hasResolvedInitialSelection = false
    private var preferredDeviceUID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredDeviceUID = defaults.string(forKey: Self.preferredDeviceUIDKey)
        refreshDevices()
        installListeners()
    }

    deinit {
        var devicesAddress = Self.propertyAddress(kAudioHardwarePropertyDevices)
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &devicesAddress, listenerQueue, devicesListener)
        }
        var defaultAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        if let defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &defaultAddress, listenerQueue, defaultOutputListener)
        }
    }

    func selectDevice(_ deviceID: AudioDeviceID) {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        preferredDeviceUID = device.uid
        defaults.set(device.uid, forKey: Self.preferredDeviceUIDKey)
        guard selectedDeviceID != device.id else { return }
        selectedDeviceID = device.id
        selectedDeviceUID = device.uid
        onDeviceSelected?(device.id)
    }

    func refreshDevices() {
        let defaultID = Self.defaultOutputDeviceID()
        let refreshedDevices = Self.availableOutputDevices(defaultID: defaultID)
        let oldSelectedID = selectedDeviceID
        let oldSelectedUID = selectedDeviceUID

        devices = refreshedDevices
        defaultDeviceID = defaultID
        Self.deviceLogger.notice(
            "refreshed output devices count=\(refreshedDevices.count, privacy: .public) defaultID=\(defaultID ?? AudioDeviceID(kAudioObjectUnknown), privacy: .public)"
        )

        if !hasResolvedInitialSelection {
            let initialDevice = preferredDeviceUID.flatMap { uid in
                refreshedDevices.first(where: { $0.uid == uid })
            } ?? refreshedDevices.first(where: { $0.id == defaultID }) ?? refreshedDevices.first
            setCurrentDevice(initialDevice)
            hasResolvedInitialSelection = true
            return
        }

        if let oldSelectedUID,
           let stillAvailable = refreshedDevices.first(where: { $0.uid == oldSelectedUID }) {
            // A reconnect can expose a new AudioDeviceID for the same device.
            // Keep the route selected without treating it as a new user choice.
            let deviceIDChanged = selectedDeviceID != stillAvailable.id
            setCurrentDevice(stillAvailable)
            if deviceIDChanged { onDeviceSelected?(stillAvailable.id) }
            return
        }

        if oldSelectedID != nil {
            let fallback = refreshedDevices.first(where: { $0.id == defaultID }) ?? refreshedDevices.first
            setCurrentDevice(fallback)
            onSelectedDeviceUnavailable?(fallback?.id)
        } else {
            let fallback = refreshedDevices.first(where: { $0.id == defaultID }) ?? refreshedDevices.first
            setCurrentDevice(fallback)
            if let fallback { onDeviceSelected?(fallback.id) }
        }
    }

    private func setCurrentDevice(_ device: AudioOutputDevice?) {
        selectedDeviceID = device?.id
        selectedDeviceUID = device?.uid
    }

    private func installListeners() {
        var devicesAddress = Self.propertyAddress(kAudioHardwarePropertyDevices)
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        if AudioObjectAddPropertyListenerBlock(systemObjectID, &devicesAddress, listenerQueue, devicesListener) == noErr {
            self.devicesListener = devicesListener
        }

        var defaultAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        if AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultAddress, listenerQueue, defaultOutputListener) == noErr {
            self.defaultOutputListener = defaultOutputListener
        }
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func availableOutputDevices(defaultID: AudioDeviceID?) -> [AudioOutputDevice] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard deviceID != AudioDeviceID(kAudioObjectUnknown),
                  isAlive(deviceID),
                  outputChannelCount(deviceID) > 0,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let rawName = stringProperty(deviceID, selector: kAudioObjectPropertyName),
                  let rawTransport = transportTypeID(deviceID),
                  let presentation = outputPresentation(deviceID),
                  !uid.isEmpty else { return nil }
            let isServiceDevice = isSystemRouteProxy(name: rawName, uid: uid)
            logDevice(
                id: deviceID,
                uid: uid,
                rawName: rawName,
                rawTransport: rawTransport,
                presentation: presentation,
                isIncluded: !isServiceDevice
            )
            guard !isServiceDevice else { return nil }
            return AudioOutputDevice(
                id: deviceID,
                uid: uid,
                name: presentation.name,
                type: presentation.type,
                isDefault: deviceID == defaultID
            )
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func logDevice(
        id: AudioDeviceID,
        uid: String,
        rawName: String,
        rawTransport: UInt32,
        presentation: (name: String, type: String),
        isIncluded: Bool
    ) {
        let activeSubdeviceIDs = activeSubdeviceIDs(id)
        let mainSubdeviceUID = stringProperty(id, selector: kAudioAggregateDevicePropertyMainSubDevice) ?? ""
        let fullSubdeviceUIDs = stringArrayProperty(
            id,
            selector: kAudioAggregateDevicePropertyFullSubDeviceList
        )
        deviceLogger.notice(
            "device id=\(id, privacy: .public) uid=\(uid, privacy: .public) rawName=\(rawName, privacy: .public) rawTransport=\(rawTransport, privacy: .public) presentationName=\(presentation.name, privacy: .public) presentationType=\(presentation.type, privacy: .public) included=\(isIncluded, privacy: .public) activeSubdevices=\(String(describing: activeSubdeviceIDs), privacy: .public) mainSubdeviceUID=\(mainSubdeviceUID, privacy: .public) fullSubdeviceUIDs=\(String(describing: fullSubdeviceUIDs), privacy: .public)"
        )
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return true }
        return value != 0
    }

    private static func outputPresentation(_ deviceID: AudioDeviceID) -> (name: String, type: String)? {
        guard let rawName = stringProperty(deviceID, selector: kAudioObjectPropertyName),
              let rawTransport = transportTypeID(deviceID) else { return nil }

        if rawTransport == kAudioDeviceTransportTypeAggregate ||
           rawTransport == kAudioDeviceTransportTypeAutoAggregate,
           let airPlaySubdevice = airPlaySubdeviceID(in: deviceID),
           let airPlayName = stringProperty(airPlaySubdevice, selector: kAudioObjectPropertyName),
           !airPlayName.isEmpty {
            return (airPlayName, "AirPlay")
        }

        return (rawName, transportTypeName(rawTransport))
    }

    /// AVFoundation can create a per-process `CADefaultDeviceAggregate-*` route.
    /// It is an implementation detail (rather than a selectable hardware or
    /// network output), so it must never be shown in the device picker.
    private static func isSystemRouteProxy(name: String, uid: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.range(of: "CADefaultDevice", options: [.caseInsensitive, .anchored]) != nil ||
            uid.range(of: "CADefaultDeviceAggregate-", options: [.caseInsensitive, .anchored]) != nil
    }

    /// AirPlay can be wrapped in an automatically created aggregate device.
    /// The active list is not always populated for that wrapper, so also use
    /// its declared main subdevice and resolve the persistent UID back to an
    /// AudioDeviceID. This is a bounded lookup, not recursive traversal.
    private static func airPlaySubdeviceID(in aggregateID: AudioDeviceID) -> AudioDeviceID? {
        aggregateSubdeviceIDs(aggregateID).first(where: {
            transportTypeID($0) == kAudioDeviceTransportTypeAirPlay
        })
    }

    private static func aggregateSubdeviceIDs(_ aggregateID: AudioDeviceID) -> [AudioDeviceID] {
        var identifiers = activeSubdeviceIDs(aggregateID)
        if let mainSubdeviceUID = stringProperty(
            aggregateID,
            selector: kAudioAggregateDevicePropertyMainSubDevice
        ), let mainSubdeviceID = deviceID(forUID: mainSubdeviceUID) {
            identifiers.append(mainSubdeviceID)
        }
        for uid in stringArrayProperty(
            aggregateID,
            selector: kAudioAggregateDevicePropertyFullSubDeviceList
        ) {
            if let subdeviceID = deviceID(forUID: uid) {
                identifiers.append(subdeviceID)
            }
        }
        var seen = Set<AudioDeviceID>()
        return identifiers.filter { $0 != AudioDeviceID(kAudioObjectUnknown) && seen.insert($0).inserted }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        let cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func transportTypeID(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func transportTypeName(_ value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeAutoAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "Other"
        }
    }

    private static func activeSubdeviceIDs(_ deviceID: AudioDeviceID) -> [AudioDeviceID] {
        var address = propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }

        var subdeviceIDs = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = subdeviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return subdeviceIDs
    }

    private static func stringArrayProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> [String] {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return [] }
        let values = value.takeRetainedValue() as NSArray
        return values.compactMap { $0 as? String }
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = propertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let bufferList = rawList.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

final class PlaybackController: NSObject, ObservableObject {
    var onTrackFinished: (() -> Void)?
    /// These callbacks identify the source rather than relying on a global UI
    /// flag, so PlaylistManager can update only the entry being attempted.
    var onPlaybackError: ((URL) -> Void)?
    var onPlaybackReady: ((URL) -> Void)?
    @Published private(set) var title = "MACAMP — READY"
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    let clock = PlaybackClockState()
    var position: Double {
        get { clock.position }
        set { clock.position = newValue }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var bitrateKbps: Int?
    @Published private(set) var sampleRateKHz: Int?
    @Published private(set) var channelCount = 0
    @Published private(set) var isVisualUpdatesSuspended = false
    /// Mirrors Winamp's `draw_playicon(8)`: play glyph with the red
    /// lost-synchronization lamp after a source/opening failure.
    @Published private(set) var hasPlaybackError = false
    /// Keeps UI seeking ahead of a stale timer tick while the player node
    /// replaces its scheduled segment.
    private(set) var pendingSeekPosition: Double? {
        get { clock.pendingSeekPosition }
        set { clock.pendingSeekPosition = newValue }
    }
    let visualization = PlaybackVisualizationState()
    @Published var volume: Double = 0.8 { didSet { playerNode.volume = Float(volume) } }
    @Published var balance: Double = 0 { didSet { playerNode.pan = Float(min(1, max(-1, balance))) } }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet {
            UserDefaults.standard.set(shuffleMode.rawValue, forKey: Self.shuffleModePreferenceKey)
            if shuffleMode != .off, repeatMode != .off {
                repeatMode = .off
            }
        }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatModePreferenceKey)
            if repeatMode != .off, shuffleMode != .off {
                shuffleMode = .off
            }
        }
    }

    var currentURL: URL? { scopedURL }
    /// Changes only when `open` starts a new source attempt. Seeking and
    /// resuming may invoke onPlaybackReady again, but remain in this generation.
    var currentTrackGeneration: Int { fileOpenGeneration }

    let equalizer = EqualizerController()
    let outputDeviceManager = AudioOutputDeviceManager()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizerNode = AVAudioUnitEQ(numberOfBands: 10)
    private var sourceFile: AVAudioFile?
    /// AVAudioFile may block while indexing a VBR file on an SMB/NAS volume.
    /// AVPlayer can begin buffering such an URL without waiting for that index,
    /// so it is used as a time-bounded fallback for the initial start.
    private var streamingPlayer: AVPlayer?
    /// The AVPlayer route has no audio-engine mixer to tap. Keep its selected
    /// track so the same lightweight PCM tap can be installed only while the
    /// visualizer (or AUTO EQ) actually needs it.
    private var streamingAudioTrack: AVAssetTrack?
    private var streamingStatusObservation: NSKeyValueObservation?
    private var streamingEndObserver: Any?
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
    private let fileOpenQueue = DispatchQueue(label: "ru.aleksandr.macAmp.audio.open", qos: .userInitiated, attributes: .concurrent)
    /// Technical display data is cosmetic: never let its AVFoundation query
    /// compete with opening, buffering or rendering the selected track.
    private let formatDetailsQueue = DispatchQueue(label: "ru.aleksandr.macAmp.audio.format", qos: .utility)
    private var fileOpenGeneration = 0
    /// A tiny PCM snapshot from the live audio graph. This avoids repeatedly
    /// seeking and decoding the source file just to draw the visualizer.
    private let analysisSamplesLock = NSLock()
    private var liveAnalysisSamples = Array(repeating: Float(0), count: 1_024)
    private var analysisSnapshot = Array(repeating: Float(0), count: 1_024)
    private var liveAnalysisSampleCount = 0
    private var liveAnalysisSampleRate = 0.0
    private var timer: Timer?
    private var scopedURL: URL?
    /// The playlist is the authority for the user-facing track name. Keep it
    /// separately from transient states such as OPENING and decoder errors.
    private var preferredDisplayTitle = ""
    private var hasSecurityScope = false
    private var scheduledStartFrame: AVAudioFramePosition = 0
    /// Invalidates completion handlers from segments replaced by seek/restart.
    private var playbackGeneration = 0
    private var isSpectrumAnalysisScheduled = false
    private let spectrumQueue = DispatchQueue(label: "ru.aleksandr.macAmp.spectrum", qos: .utility)
    /// Winamp stores the visible bar height in Q4 and the peak position in
    /// Q8.  Keeping the same fixed-point domains preserves the old one-pixel
    /// hold before a marker starts to fall, without adding a timer per bar.
    private var visualBarHeightsQ4 = Array(repeating: 0, count: 16)
    private var visualPeakPositionsQ8 = Array(repeating: 0, count: 16)
    private var visualPeakVelocities = Array(repeating: Float(0), count: 16)
    private let visualBarFalloffQ4 = 12
    private let visualPeakFalloff: Float = 1.1
    private var routesThroughEqualizer = false
    private var isLiveAnalysisTapInstalled = false
    private var isStreamingAnalysisTapInstalled = false
    /// The classic analyzer and MilkDrop are separate consumers of the same
    /// PCM snapshot.  Keeping their demands independent lets closing one view
    /// stop its work without turning the other view off.
    private var mainVisualizationEnabled = true
    private var mainNeedsWaveformSamples = false
    private var milkDropVisualizationEnabled = false
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
    private lazy var adaptiveFFTWorkspace = FFTWorkspace(size: fftSize)
    private lazy var visualFFTWorkspace = FFTWorkspace(size: visualFFTSize)
    private var smoothedBandEnergy = Array(repeating: -60.0, count: 10)
    private var hasAdaptiveAnalysisHistory = false
    private static let shuffleModePreferenceKey = "macAmp.playback.shuffleMode"
    private static let repeatModePreferenceKey = "macAmp.playback.repeatMode"
    private static let legacyShufflePreferenceKey = "macAmp.playback.shuffleEnabled"
    private static let legacyRepeatPreferenceKey = "macAmp.playback.repeatEnabled"

    override init() {
        super.init()
        // Keep these choices independent from window-layout persistence: a
        // damaged/older layout snapshot must never reset playback modes.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.shuffleModePreferenceKey) != nil {
            shuffleMode = ShuffleMode(rawValue: defaults.integer(forKey: Self.shuffleModePreferenceKey)) ?? .off
        } else if defaults.bool(forKey: Self.legacyShufflePreferenceKey) {
            shuffleMode = .currentPlaylist
        }
        if defaults.object(forKey: Self.repeatModePreferenceKey) != nil {
            repeatMode = RepeatMode(rawValue: defaults.integer(forKey: Self.repeatModePreferenceKey)) ?? .off
        } else if defaults.bool(forKey: Self.legacyRepeatPreferenceKey) {
            repeatMode = .currentTrack
        }
        configureAudioGraph()
        outputDeviceManager.onDeviceSelected = { [weak self] deviceID in
            self?.switchOutputDevice(to: deviceID)
        }
        outputDeviceManager.onSelectedDeviceUnavailable = { [weak self] fallbackID in
            self?.handleOutputDeviceUnavailable(fallbackID: fallbackID)
        }
        applyOutputDevice(outputDeviceManager.selectedDeviceID)
        equalizer.onChange = { [weak self] in self?.applyEqualizer() }
    }

    deinit {
        timer?.invalidate()
        if let streamingEndObserver { NotificationCenter.default.removeObserver(streamingEndObserver) }
        if let streamingTimeObserver { streamingPlayer?.removeTimeObserver(streamingTimeObserver) }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    func chooseTrack() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func play() {
        if let streamingPlayer {
            if streamingTimeObserver == nil { installStreamingTimeObserver(on: streamingPlayer) }
            streamingPlayer.play(); isPlaying = true; isPaused = false
            return
        }
        guard sourceFile != nil else {
            // Stop releases a network AVPlayer completely so its decoder and
            // buffering work cannot delay input. Re-open the retained URL on
            // the next Play rather than showing a file picker.
            if let scopedURL { open(scopedURL) } else { chooseTrack() }
            return
        }
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
        if streamingPlayer != nil {
            // AVPlayer can retain a decoder and continue network buffering
            // after `pause()`. That work was visible as 40 ms mouse-event
            // queue delays after Play → Stop. Release it fully; `play()`
            // retains the URL and opens it again when requested.
            stopStreamingPlayback()
            if hasSecurityScope { scopedURL?.stopAccessingSecurityScopedResource() }
            hasSecurityScope = false
            position = 0
            pendingSeekPosition = nil
            isPlaying = false
            isPaused = false
            visualization.spectrumLevels = Array(repeating: 0, count: 16)
            visualization.milkDropSpectrumLevels = Array(repeating: 0, count: 16)
            visualization.spectrumPeaks = Array(repeating: 0, count: 16)
            visualization.waveformSamples = Array(repeating: 0, count: 76)
            resetSpectrumAnimation()
            return
        }
        playerNode.stop()
        timer?.invalidate()
        timer = nil
        // Unlike a cold launch, an AVAudioEngine keeps rendering silence after
        // its player node stops. Its mixer tap then continues taking locks and
        // copying PCM buffers, which is needless work and made window drags
        // slower after a Play → Stop cycle. Keep the graph configured, but
        // pause rendering and reinstall the tap only when playback resumes.
        engine.mainMixerNode.removeTap(onBus: 0)
        isLiveAnalysisTapInstalled = false
        engine.pause()
        scheduledStartFrame = 0
        position = 0
        pendingSeekPosition = nil
        isPlaying = false
        isPaused = false
        visualization.spectrumLevels = Array(repeating: 0, count: 16)
        visualization.milkDropSpectrumLevels = Array(repeating: 0, count: 16)
        visualization.spectrumPeaks = Array(repeating: 0, count: 16)
        visualization.waveformSamples = Array(repeating: 0, count: 76)
        resetSpectrumAnimation()
    }

    /// Keeps analysis work proportional to what is actually on screen.  The
    /// audio engine is independent of the visualizer, so turning it off must
    /// also stop disk reads and DSP work rather than merely hiding the view.
    func setVisualization(enabled: Bool, waveform: Bool) {
        mainVisualizationEnabled = enabled
        mainNeedsWaveformSamples = enabled && waveform
        updateVisualizationDemand()
    }

    /// MilkDrop reuses the analyzer's live PCM tap instead of decoding a
    /// second stream.  It is enabled only while the visualization window is
    /// visible and playback is active.
    func setMilkDropVisualization(enabled: Bool) {
        guard milkDropVisualizationEnabled != enabled else { return }
        milkDropVisualizationEnabled = enabled
        updateVisualizationDemand()
        if let streamingPlayer {
            installStreamingTimeObserver(on: streamingPlayer)
        } else if isPlaying, sourceFile != nil {
            startTimer()
        }
    }

    private func updateVisualizationDemand() {
        isVisualizationEnabled = mainVisualizationEnabled || milkDropVisualizationEnabled
        needsWaveformSamples = mainNeedsWaveformSamples || milkDropVisualizationEnabled
        updateLiveAnalysisTap()
        guard !isVisualizationEnabled else { return }
        visualization.spectrumLevels = Array(repeating: 0, count: 16)
        visualization.milkDropSpectrumLevels = Array(repeating: 0, count: 16)
        visualization.spectrumPeaks = Array(repeating: 0, count: 16)
        visualization.waveformSamples = Array(repeating: 0, count: 76)
        resetSpectrumAnimation()
    }

    /// State used by the classic peak animation belongs to the serial
    /// spectrum queue.  Reset it there so stopping or hiding the visualizer
    /// cannot race an in-flight FFT frame.
    private func resetSpectrumAnimation() {
        spectrumQueue.async { [weak self] in
            guard let self else { return }
            self.visualBarHeightsQ4 = Array(repeating: 0, count: 16)
            self.visualPeakPositionsQ8 = Array(repeating: 0, count: 16)
            self.visualPeakVelocities = Array(repeating: 0, count: 16)
        }
    }

    /// The audio graph keeps running in the background, but rendering state
    /// and file-based spectrum analysis have no user-visible value there.
    func setInterfaceVisible(_ visible: Bool) {
        guard isInterfaceVisible != visible else { return }
        isInterfaceVisible = visible
        updateLiveAnalysisTap()
        if let streamingPlayer {
            installStreamingTimeObserver(on: streamingPlayer)
            return
        }
        // AVPlayer owns its own periodic observer; installing the engine timer
        // as well would create a second wakeup source that can never produce a
        // position because streaming playback has no sourceFile.
        if isPlaying, streamingPlayer == nil { startTimer() }
    }

    /// Preserve playback while a connected player-window group is dragged,
    /// but stop publishing animation frames that would otherwise contend with
    /// AppKit's mouse-tracking loop.
    func setVisualUpdatesSuspended(_ suspended: Bool) {
        guard isVisualUpdatesSuspended != suspended else { return }
        isVisualUpdatesSuspended = suspended
        InterfaceRenderGate.isSuspended = suspended
        guard !suspended else { return }
        // Refresh the static position immediately; the next regular tick
        // restores spectrum/waveform animation without a burst of work.
        if let streamingPlayer {
            position = max(0, streamingPlayer.currentTime().seconds)
        } else if sourceFile != nil, isPlaying {
            startTimer()
        }
    }

    func seek(to value: Double) {
        if let streamingPlayer {
            let target = min(max(0, value), duration)
            pendingSeekPosition = target
            position = target
            streamingPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                DispatchQueue.main.async { self?.pendingSeekPosition = nil }
            }
            return
        }
        guard let sourceFile else { return }
        let target = min(max(0, value), duration)
        // Publish the target before scheduling the segment so the skin thumb does
        // not briefly fall back to its previous playback position on mouse-up.
        pendingSeekPosition = target
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

    private func applyOutputDevice(_ deviceID: AudioDeviceID?) {
        guard let deviceID else { return }
        if let streamingPlayer {
            streamingPlayer.audioOutputDeviceUniqueID = outputDeviceManager.selectedDeviceUID
            return
        }
        guard let outputUnit = engine.outputNode.audioUnit else { return }
        var currentDeviceID = deviceID
        _ = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func switchOutputDevice(to deviceID: AudioDeviceID) {
        if let streamingPlayer {
            streamingPlayer.audioOutputDeviceUniqueID = outputDeviceManager.selectedDeviceUID
            return
        }

        guard let file = sourceFile else {
            applyOutputDevice(deviceID)
            return
        }

        let wasPlaying = isPlaying || playerNode.isPlaying
        let wasPaused = isPaused
        let resumeFrame = scheduledStartFrame + (playerNode.isPlaying ? currentPlayedFrames() : 0)

        playbackGeneration += 1
        playerNode.stop()
        timer?.invalidate()
        timer = nil
        engine.stop()
        engine.reset()
        applyOutputDevice(deviceID)
        connectAudioGraph(for: file.processingFormat)
        if wasPlaying {
            engine.prepare()
        }

        do {
            if wasPlaying { try engine.start() }
            scheduledStartFrame = min(max(0, resumeFrame), file.length)
            if wasPlaying {
                start(at: scheduledStartFrame)
            } else {
                engine.mainMixerNode.removeTap(onBus: 0)
                isLiveAnalysisTapInstalled = false
                isPlaying = false
                isPaused = wasPaused
            }
        } catch {
            reportPlaybackError(for: scopedURL, title: "AUDIO ENGINE ERROR")
        }
    }

    private func handleOutputDeviceUnavailable(fallbackID: AudioDeviceID?) {
        let hadPlayback = isPlaying || isPaused || playerNode.isPlaying || streamingPlayer != nil
        if hadPlayback { stop() }
        applyOutputDevice(fallbackID)
    }

    private func applyEqualizer() {
        equalizerNode.globalGain = Float(equalizer.preamp)
        for (band, value) in zip(equalizerNode.bands, equalizer.bands) { band.gain = Float(value) }
        equalizerNode.bypass = !hasEffectiveEqualizerCorrection
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
            equalizerNode.bypass = !hasEffectiveEqualizerCorrection
            engine.connect(playerNode, to: equalizerNode, format: format)
            engine.connect(equalizerNode, to: engine.mainMixerNode, format: format)
        } else {
            equalizerNode.bypass = true
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        }
        updateLiveAnalysisTap()
    }

    /// A flat EQ should be acoustically identical to a direct route. Keeping
    /// the unit connected makes later slider changes cheap, while bypassing it
    /// lets Core Audio skip ten inactive filters during ordinary playback.
    private var hasEffectiveEqualizerCorrection: Bool {
        guard equalizer.isEnabled else { return false }
        if abs(equalizer.preamp) >= 0.001 { return true }
        return equalizer.bands.contains { abs($0) >= 0.001 }
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
            reportPlaybackError(for: scopedURL, title: "AUDIO ENGINE ERROR")
        }
    }

    private var needsLiveAnalysis: Bool {
        milkDropVisualizationEnabled
            || (isInterfaceVisible
                && (mainVisualizationEnabled || (equalizer.isEnabled && equalizer.isAdaptiveEnabled)))
    }

    private var liveAnalysisInterval: TimeInterval {
        if milkDropVisualizationEnabled { return 1.0 / 30.0 }
        return isInterfaceVisible ? equalizer.adaptiveConfiguration.analysisInterval : 1.0
    }

    /// Tapping a node invokes code on the real-time audio render thread. Do not
    /// leave a no-op tap installed when neither the analyser nor AUTO EQ needs
    /// PCM data. The mixer is downstream from the optional EQ node, so it also
    /// works when the EQ is removed from the playback route.
    private func updateLiveAnalysisTap() {
        if streamingPlayer != nil {
            updateStreamingAnalysisTap()
            return
        }
        let shouldInstall = sourceFile != nil && needsLiveAnalysis
        guard shouldInstall != isLiveAnalysisTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isLiveAnalysisTapInstalled = false
        guard shouldInstall else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            guard let self,
                  let channels = buffer.floatChannelData else { return }
            let count = min(Int(buffer.frameLength), self.liveAnalysisSamples.count)
            guard count > 0 else { return }
            let sourceOffset = max(0, Int(buffer.frameLength) - count)
            self.analysisSamplesLock.lock()
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 {
                self.liveAnalysisSamples.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.update(from: channels[0].advanced(by: sourceOffset), count: count)
                }
            } else {
                self.liveAnalysisSamples.withUnsafeMutableBufferPointer { destination in
                    let output = destination.baseAddress!
                    output.update(from: channels[0].advanced(by: sourceOffset), count: count)
                    for channel in 1..<channelCount {
                        vDSP_vadd(output, 1, channels[channel].advanced(by: sourceOffset), 1,
                                  output, 1, vDSP_Length(count))
                    }
                    var scale = Float(1) / Float(channelCount)
                    vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(count))
                }
            }
            self.liveAnalysisSampleCount = count
            self.liveAnalysisSampleRate = buffer.format.sampleRate
            self.analysisSamplesLock.unlock()
        }
        isLiveAnalysisTapInstalled = true
    }

    /// AVPlayer is used for network volumes so opening them cannot block the
    /// UI. Its decoded audio bypasses `engine.mainMixerNode`, therefore the
    /// visualizer must receive PCM through an `MTAudioProcessingTap` attached
    /// to the player's item.  Do not keep that tap active while it has no
    /// visual or adaptive-EQ consumer: its callback runs on the audio thread.
    private func updateStreamingAnalysisTap() {
        let shouldInstall = streamingPlayer != nil && streamingAudioTrack != nil && needsLiveAnalysis
        guard shouldInstall != isStreamingAnalysisTapInstalled else { return }
        guard let item = streamingPlayer?.currentItem else {
            isStreamingAnalysisTapInstalled = false
            return
        }
        item.audioMix = shouldInstall
            ? streamingAudioTrack.flatMap { streamingAudioMix(for: $0) }
            : nil
        isStreamingAnalysisTapInstalled = shouldInstall && item.audioMix != nil
    }

    /// PlaylistManager owns selection; the audio engine only opens the chosen URL.
    func open(_ requestedURL: URL, bookmarkData: Data? = nil, displayTitle: String? = nil) {
        let url: URL
        if let bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                url = resolvedURL
            } else {
                // Invalid persistent access must not suppress the original
                // URL. Unsandboxed Debug builds can still read it directly;
                // sandboxed builds will report a real access failure from the
                // normal AVAudioFile/AVPlayer opening path below.
                url = requestedURL
            }
        } else {
            url = requestedURL
        }
        let playlistTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let playlistTitle, !playlistTitle.isEmpty {
            preferredDisplayTitle = playlistTitle
        } else {
            preferredDisplayTitle = url.deletingPathExtension().lastPathComponent.uppercased()
        }
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
        hasPlaybackError = false
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
            // asynchronously and keeps all macAmp windows responsive.
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
                    self.reportPlaybackError(for: url, title: "UNSUPPORTED AUDIO FILE")
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
            self.title = self.preferredDisplayTitle
            // Reading AVAudioFile.length can make AVFoundation scan a large
            // VBR file end-to-end, particularly on a network volume. Start
            // decoding first; duration remains unknown until it can be read
            // without holding up the initial playback path.
            self.sampleRateKHz = Int((file.processingFormat.sampleRate / 1_000).rounded())
            self.channelCount = Int(file.processingFormat.channelCount)
            self.smoothedBandEnergy = Array(repeating: -60, count: 10)
            self.hasAdaptiveAnalysisHistory = false
            self.start()
            self.loadFormatDetails(for: url, file: file, generation: generation)
                } catch {
                    self.sourceFile = nil
                    self.reportPlaybackError(for: url, title: "UNSUPPORTED AUDIO FILE")
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

    /// Metadata scanning may finish after playback has already started. This
    /// keeps the main ticker synchronized with the live playlist row without
    /// replacing OPENING or an error message prematurely.
    func updateDisplayTitle(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        preferredDisplayTitle = normalized
        guard title != "OPENING…", !hasPlaybackError, currentURL != nil else { return }
        title = normalized
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
            let asset = AVURLAsset(url: url)
            // Track discovery can contact a file provider. It belongs on the
            // opening queue alongside AVPlayerItem construction, never in the
            // ready-to-play callback on the main run loop.
            let audioTrack = asset.tracks(withMediaType: .audio).first
            let bitrateKbps = audioTrack.map(\.estimatedDataRate).flatMap {
                $0 > 0 ? Int(($0 / 1_000).rounded()) : nil
            }
            let item = AVPlayerItem(asset: asset)
            DispatchQueue.main.async {
                guard let self, self.fileOpenGeneration == generation,
                      self.streamingOpenGeneration == generation else {
                    if obtainedSecurityScope { url.stopAccessingSecurityScopedResource() }
                    return
                }
                let player = AVPlayer(playerItem: item)
                player.audioOutputDeviceUniqueID = self.outputDeviceManager.selectedDeviceUID
                self.streamingPlayer = player
                self.streamingAudioTrack = audioTrack
                self.bitrateKbps = bitrateKbps
                self.scopedURL = url
                self.hasSecurityScope = obtainedSecurityScope
                self.updateLiveAnalysisTap()
                self.streamingEndObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    guard let self, self.fileOpenGeneration == generation,
                          self.streamingOpenGeneration == generation else { return }
                    self.onTrackFinished?()
                }
                self.streamingStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self, self.fileOpenGeneration == generation,
                              self.streamingOpenGeneration == generation else { return }
                        guard item.status == .readyToPlay else {
                            if item.status == .failed {
                                self.stopStreamingPlayback()
                                if self.hasSecurityScope { self.scopedURL?.stopAccessingSecurityScopedResource() }
                                self.scopedURL = nil; self.hasSecurityScope = false
                                self.reportPlaybackError(for: url, title: "SOURCE UNAVAILABLE")
                            }
                            return
                        }
                        self.playerNode.stop()
                        self.timer?.invalidate(); self.timer = nil
                        self.duration = item.duration.seconds.isFinite ? max(0, item.duration.seconds) : 0
                        self.position = 0
                        self.title = self.preferredDisplayTitle
                        self.loadStreamingBitrate(for: url, generation: generation)
                        self.installStreamingTimeObserver(on: player)
                        player.play()
                        self.isPlaying = true; self.isPaused = false
                        self.onPlaybackReady?(url)
                    }
                }
            }
        }
    }

    private func installStreamingTimeObserver(on player: AVPlayer) {
        if let streamingTimeObserver { player.removeTimeObserver(streamingTimeObserver) }
        streamingTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: liveAnalysisInterval, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self, self.streamingPlayer === player else { return }
            guard !self.isVisualUpdatesSuspended else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastPublishedPosition) >= self.positionPublishInterval {
                self.position = max(0, time.seconds)
                self.lastPublishedPosition = now
            }
            let playerIsPlaying = player.rate > 0
            if self.isPlaying != playerIsPlaying { self.isPlaying = playerIsPlaying }
            if self.isPaused == playerIsPlaying { self.isPaused = !playerIsPlaying }
            if playerIsPlaying, self.needsLiveAnalysis {
                self.updateSpectrum(at: time.seconds, includesWaveform: self.needsWaveformSamples)
            }
        }
    }

    private func stopStreamingPlayback() {
        if let streamingEndObserver { NotificationCenter.default.removeObserver(streamingEndObserver) }
        streamingEndObserver = nil
        if let streamingTimeObserver { streamingPlayer?.removeTimeObserver(streamingTimeObserver) }
        streamingTimeObserver = nil
        streamingStatusObservation?.invalidate(); streamingStatusObservation = nil
        streamingPlayer?.pause(); streamingPlayer = nil
        streamingAudioTrack = nil
        isStreamingAnalysisTapInstalled = false
        streamingOpenGeneration = nil
    }

    private func streamingAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: streamingTapInit,
            finalize: nil,
            prepare: nil,
            unprepare: nil,
            process: streamingTapProcess
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        ) == noErr, let tap else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Called on AVPlayer's real-time audio thread. It only retains the newest
    /// small PCM slice; FFT work remains on the existing utility queue.
    fileprivate func captureStreamingAnalysisSamples(
        from bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard frameCount > 0, let first = buffers.first, let data = first.mData else { return }
        let sampleCount = min(frameCount, liveAnalysisSamples.count)
        let samples = data.assumingMemoryBound(to: Float.self)
        analysisSamplesLock.lock()
        liveAnalysisSamples.withUnsafeMutableBufferPointer {
            $0.baseAddress!.update(from: samples.advanced(by: frameCount - sampleCount), count: sampleCount)
        }
        liveAnalysisSampleCount = sampleCount
        // AVPlayer's tap commonly supplies Float32 PCM. The FFT only needs a
        // valid frequency scale; 44.1 kHz is the conservative fallback when
        // a track does not expose its processing format to the tap.
        liveAnalysisSampleRate = 44_100
        analysisSamplesLock.unlock()
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
        updateLiveAnalysisTap()
        do { if !engine.isRunning { try engine.start() } } catch {
            reportPlaybackError(for: scopedURL, title: "AUDIO ENGINE ERROR")
            return
        }
        playerNode.play()
        isPlaying = true
        isPaused = false
        if let scopedURL { onPlaybackReady?(scopedURL) }
        startTimer()
    }

    private func reportPlaybackError(for url: URL?, title: String) {
        hasPlaybackError = true
        self.title = title
        if let url { onPlaybackError?(url) }
    }

    private func currentPlayedFrames() -> AVAudioFramePosition {
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return 0 }
        return playerTime.sampleTime
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = liveAnalysisInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let file = self.sourceFile else { return }
            guard !self.isVisualUpdatesSuspended else { return }
            let rawPosition = Double(self.scheduledStartFrame + self.currentPlayedFrames()) / file.processingFormat.sampleRate
            let currentPosition = self.duration > 0 ? min(self.duration, rawPosition) : rawPosition
            // The time digits and progress thumb cannot display sub-quarter-
            // second changes.  Publishing them at the analyser cadence makes
            // the entire SwiftUI hierarchy redraw needlessly.
            if Date().timeIntervalSince(self.lastPublishedPosition) >= self.positionPublishInterval || currentPosition >= self.duration {
                self.position = currentPosition
                self.pendingSeekPosition = nil
                self.lastPublishedPosition = Date()
            }
            let nodeIsPlaying = self.playerNode.isPlaying
            if self.isPlaying != nodeIsPlaying { self.isPlaying = nodeIsPlaying }
            if nodeIsPlaying, self.needsLiveAnalysis {
                self.updateSpectrum(at: currentPosition, includesWaveform: self.needsWaveformSamples)
            }
        }
    }

    private func loadFormatDetails(for url: URL, file: AVAudioFile, generation: Int) {
        let sampleRate = Int((file.processingFormat.sampleRate / 1_000).rounded())
        let channels = Int(file.processingFormat.channelCount)
        formatDetailsQueue.async { [weak self] in
            // AVAudioFile.length may scan a VBR source. Keep that work off the
            // main thread, but always publish the result: position navigation
            // cannot operate while duration remains at its opening value (0).
            let trackDuration = Double(file.length) / file.processingFormat.sampleRate
            let asset = AVURLAsset(url: url)
            let estimatedBitrate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
            let bitrate: Int?
            if estimatedBitrate > 0 {
                bitrate = Int((estimatedBitrate / 1_000).rounded())
            } else {
                // Some MP3s, especially VBR files without a usable Xing/VBR
                // header, expose no estimated rate. This fallback remains off
                // the main thread and runs only after playback has started.
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let fileSize, trackDuration > 0 {
                    bitrate = Int((Double(fileSize) * 8 / trackDuration / 1_000).rounded())
                } else {
                    bitrate = nil
                }
            }
            DispatchQueue.main.async {
                guard let self, self.fileOpenGeneration == generation,
                      self.sourceFile != nil, self.streamingOpenGeneration == nil else { return }
                self.sampleRateKHz = sampleRate
                self.channelCount = channels
                self.bitrateKbps = bitrate
                if trackDuration.isFinite, trackDuration > 0 {
                    self.duration = trackDuration
                }
            }
        }
    }

    /// Match the Info window's asset-loading sequence. An AVPlayerItem being
    /// ready does not guarantee its shared asset has populated a network
    /// track's estimated data rate yet.
    private func loadStreamingBitrate(for url: URL, generation: Int) {
        formatDetailsQueue.async { [weak self] in
            let asset = AVURLAsset(url: url)
            let semaphore = DispatchSemaphore(value: 0)
            asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata", "duration"]) {
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else { return }
            let rate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
            let duration = asset.duration.seconds
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let bitrate: Int?
            if rate > 0 {
                bitrate = Int((rate / 1_000).rounded())
            } else if let fileSize, duration.isFinite, duration > 0 {
                bitrate = Int((Double(fileSize) * 8 / duration / 1_000).rounded())
            } else {
                bitrate = nil
            }
            DispatchQueue.main.async {
                guard let self, self.fileOpenGeneration == generation,
                      self.streamingOpenGeneration == generation else { return }
                self.bitrateKbps = bitrate
                if duration.isFinite, duration > 0 {
                    self.duration = duration
                }
            }
        }
    }

    private func updateSpectrum(at _: TimeInterval, includesWaveform: Bool) {
        guard !isSpectrumAnalysisScheduled else { return }
        isSpectrumAnalysisScheduled = true
        let now = Date()
        let needsAdaptiveAnalysis = equalizer.isEnabled && equalizer.isAdaptiveEnabled && now.timeIntervalSince(lastAdaptiveAnalysis) >= adaptiveAnalysisInterval
        if needsAdaptiveAnalysis { lastAdaptiveAnalysis = now }
        let analysisSize = needsAdaptiveAnalysis ? fftSize : visualFFTSize
        spectrumQueue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.isSpectrumAnalysisScheduled = false } }
            self.analysisSamplesLock.lock()
            let available = self.liveAnalysisSampleCount
            let sampleRate = self.liveAnalysisSampleRate
            if available > 0 {
                self.analysisSnapshot.withUnsafeMutableBufferPointer { destination in
                    self.liveAnalysisSamples.withUnsafeBufferPointer { source in
                        destination.baseAddress!.update(from: source.baseAddress!, count: available)
                    }
                }
            }
            self.analysisSamplesLock.unlock()
            guard sampleRate > 0, available >= analysisSize else { return }
            let samples = self.analysisSnapshot.prefix(available)
            let latestSamples = samples.suffix(self.visualFFTSize)
            let decibels = needsAdaptiveAnalysis
                ? self.bandDecibels(samples: samples, sampleRate: sampleRate)
                : []
            // The skin contains fifteen physical LED rows.  Quantize before
            // publishing so imperceptible floating-point changes do not cause
            // another complete SwiftUI update.
            let rawLevels = self.visualLevels(samples: latestSamples, sampleRate: sampleRate)
            let dynamics = self.classicSpectrumDynamics(for: rawLevels)
            let levels = dynamics.bars
            let peaks = dynamics.peaks
            let waveform: [CGFloat] = includesWaveform
                ? (0..<76).map { column in
                    let offset = min(self.visualFFTSize - 1, column * (self.visualFFTSize - 1) / 75)
                    // ArraySlice keeps the source collection's indices, so use
                    // its start index instead of assuming the slice starts at 0.
                    let sample = latestSamples[latestSamples.index(latestSamples.startIndex, offsetBy: offset)]
                    return CGFloat(min(1, max(-1, sample)))
                }
                : []
            DispatchQueue.main.async {
                // A frame can finish after Stop or after the visualizer was
                // hidden.  Do not let that stale asynchronous result repaint
                // the cleared analyzer state.
                guard !self.isVisualUpdatesSuspended,
                      self.isPlaying,
                      self.needsLiveAnalysis else { return }
                if self.isInterfaceVisible, self.mainVisualizationEnabled {
                    if self.visualization.spectrumLevels != levels { self.visualization.spectrumLevels = levels }
                    if self.visualization.spectrumPeaks != peaks { self.visualization.spectrumPeaks = peaks }
                }
                if self.milkDropVisualizationEnabled,
                   self.visualization.milkDropSpectrumLevels != rawLevels {
                    self.visualization.milkDropSpectrumLevels = rawLevels
                }
                if includesWaveform { self.visualization.waveformSamples = waveform }
                if needsAdaptiveAnalysis { self.updateAdaptiveEqualizer(with: decibels) }
            }
        }
    }

    /// The tap already receives the current decoded PCM window, so one FFT is
    /// enough for AUTO EQ; the former second pass only existed to compensate
    /// for repeatedly seeking through the source file.
    private func bandDecibels(samples: ArraySlice<Float>, sampleRate: Double) -> [Double] {
        let frequencies = EqualizerController.frequencies.map(Double.init)
        return adaptiveFFTWorkspace?.withPower(samples: samples) { power in
            frequencies.enumerated().map { index, frequency in
                let lower = index == 0 ? frequency / sqrt(frequencies[1] / frequency) : sqrt(frequencies[index - 1] * frequency)
                let upper = index == frequencies.count - 1 ? frequency * sqrt(frequency / frequencies[index - 1]) : sqrt(frequency * frequencies[index + 1])
                let lowBin = max(1, Int(floor(lower * Double(fftSize) / sampleRate)))
                let highBin = min(fftSize / 2 - 1, max(lowBin, Int(ceil(upper * Double(fftSize) / sampleRate))))
                var sum: Float = 0
                for bin in lowBin...highBin { sum += power[bin] }
                let meanPower = Double(sum) / Double(highBin - lowBin + 1)
                return 10 * log10(max(meanPower, 1e-12))
            }
        } ?? Array(repeating: -120, count: frequencies.count)
    }

    /// A single 512-point FFT replaces sixteen independent Goertzel scans.
    /// The classic display has only sixteen columns, so nearest-bin sampling
    /// is both sufficient and substantially cheaper.
    private func visualLevels(samples: ArraySlice<Float>, sampleRate: Double) -> [CGFloat] {
        visualFFTWorkspace?.withPower(samples: samples) { power in
            (0..<16).map { index in
                let frequency = min(sampleRate / 2 - 1, 45 * pow(2, Double(index) * 8.7 / 15))
                let bin = min(power.count - 1, max(1, Int((Double(visualFFTSize) * frequency / sampleRate).rounded())))
                let magnitude = sqrt(Double(max(0, power[bin]))) / Double(visualFFTSize / 2)
                let db = 20 * log10(max(magnitude, 0.000_000_1))
                return CGFloat(min(1, max(0, (db + 65) / 65)))
            }
        } ?? Array(repeating: 0, count: 16)
    }

    /// Reproduces the classic Winamp analyzer's two independent falloff
    /// stages.  `barHeight` is the smoothed column (`bx` in draw_sa.cpp),
    /// while `peakHeight` is the falling marker (`t_bx`/`t_vx`).
    private func classicSpectrumDynamics(for rawLevels: [CGFloat])
        -> (bars: [CGFloat], peaks: [CGFloat]) {
        var bars = Array(repeating: CGFloat(0), count: 16)
        var peaks = Array(repeating: CGFloat(0), count: 16)

        for index in 0..<16 {
            let raw = rawLevels.indices.contains(index) ? rawLevels[index] : 0
            let value = min(15, max(0, Int((raw * 15).rounded(.down))))
            let valueQ4 = value << 4

            if valueQ4 < visualBarHeightsQ4[index] {
                visualBarHeightsQ4[index] = max(0, visualBarHeightsQ4[index] - visualBarFalloffQ4)
            } else {
                visualBarHeightsQ4[index] = valueQ4
            }
            let displayedValue = min(15, max(0, visualBarHeightsQ4[index] >> 4))
            bars[index] = CGFloat(displayedValue) / 15

            if visualPeakPositionsQ8[index] <= displayedValue * 256 {
                visualPeakPositionsQ8[index] = displayedValue * 256
                visualPeakVelocities[index] = 3
            }
            let displayedPeak = min(15, max(0, visualPeakPositionsQ8[index] / 256))
            peaks[index] = CGFloat(displayedPeak) / 15

            visualPeakPositionsQ8[index] -= Int(visualPeakVelocities[index])
            visualPeakVelocities[index] *= visualPeakFalloff
            if visualPeakPositionsQ8[index] < 0 { visualPeakPositionsQ8[index] = 0 }
        }

        return (bars, peaks)
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

private func streamingTapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func streamingTapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var sourceFlags: MTAudioProcessingTapFlags = 0
    var sourceFrames: CMItemCount = 0
    var sourceTimeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferList, &sourceFlags, &sourceTimeRange, &sourceFrames
    )
    numberFramesOut.pointee = status == noErr ? sourceFrames : 0
    flagsOut.pointee = sourceFlags
    guard status == noErr else { return }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let controller = Unmanaged<PlaybackController>.fromOpaque(storage).takeUnretainedValue()
    controller.captureStreamingAnalysisSamples(from: bufferList, frameCount: Int(sourceFrames))
}
