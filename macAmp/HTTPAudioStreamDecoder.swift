import AVFoundation
import AudioToolbox
import CFNetwork
import Combine
import Foundation
import Network

enum NetworkProxyMode: String, CaseIterable, Identifiable {
    case direct
    case system
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Do not use proxy"
        case .system: return "Use system proxy"
        case .custom: return "Use custom proxy"
        }
    }
}

private struct ParsedNetworkProxy {
    enum Kind { case http, https, socks }
    let kind: Kind
    let host: String
    let port: Int
    let username: String?
    let password: String?
}

enum NetworkProxyError: LocalizedError {
    case invalidAddress

    var errorDescription: String? {
        "Enter a proxy as http://host:port, https://host:port, or socks://host:port."
    }
}

struct NetworkProxySnapshot {
    let mode: NetworkProxyMode
    let customAddress: String

    func sessionConfiguration() throws -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // URLSession applies the request timeout to the lifetime of a data
        // task as well. A radio response is intentionally unbounded, so keep
        // the transport alive; HTTPAudioStreamDecoder owns a separate bounded
        // timeout which is cancelled as soon as response headers arrive.
        let continuousStreamLifetime: TimeInterval = 365 * 24 * 60 * 60
        configuration.timeoutIntervalForRequest = continuousStreamLifetime
        configuration.timeoutIntervalForResource = continuousStreamLifetime
        switch mode {
        case .system:
            // A nil override preserves System Settings, including PAC and
            // automatic proxy discovery.
            break
        case .direct:
            configuration.connectionProxyDictionary = Self.disabledProxyDictionary
            if #available(macOS 14.0, *) { configuration.proxyConfigurations = [] }
        case .custom:
            let proxy = try Self.parse(customAddress)
            if #available(macOS 14.0, *) {
                let endpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(proxy.host),
                    port: NWEndpoint.Port(rawValue: UInt16(proxy.port))!
                )
                var proxyConfiguration: ProxyConfiguration
                switch proxy.kind {
                case .socks:
                    proxyConfiguration = ProxyConfiguration(socksv5Proxy: endpoint)
                case .http:
                    proxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint)
                case .https:
                    proxyConfiguration = ProxyConfiguration(
                        httpCONNECTProxy: endpoint,
                        tlsOptions: NWProtocolTLS.Options()
                    )
                }
                proxyConfiguration.allowFailover = false
                if let username = proxy.username {
                    proxyConfiguration.applyCredential(username: username, password: proxy.password ?? "")
                }
                configuration.connectionProxyDictionary = Self.disabledProxyDictionary
                configuration.proxyConfigurations = [proxyConfiguration]
            } else {
                configuration.connectionProxyDictionary = Self.legacyDictionary(for: proxy)
            }
        }
        return configuration
    }

    var validationMessage: String? {
        guard mode == .custom else { return nil }
        do { _ = try Self.parse(customAddress); return nil }
        catch { return error.localizedDescription }
    }

    private static func parse(_ value: String) throws -> ParsedNetworkProxy {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw NetworkProxyError.invalidAddress
        }
        let kind: ParsedNetworkProxy.Kind
        let defaultPort: Int
        switch rawScheme {
        case "http": kind = .http; defaultPort = 8080
        case "https": kind = .https; defaultPort = 443
        case "socks", "socks5": kind = .socks; defaultPort = 1080
        default: throw NetworkProxyError.invalidAddress
        }
        let port = components.port ?? defaultPort
        guard (1...65_535).contains(port) else { throw NetworkProxyError.invalidAddress }
        return ParsedNetworkProxy(
            kind: kind,
            host: host,
            port: port,
            username: components.user,
            password: components.password
        )
    }

    private static var disabledProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
    }

    private static func legacyDictionary(for proxy: ParsedNetworkProxy) -> [AnyHashable: Any] {
        switch proxy.kind {
        case .socks:
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                kCFNetworkProxiesSOCKSPort as String: proxy.port
            ]
        case .http, .https:
            // Legacy CFNetwork distinguishes destination schemes rather than
            // proxy transport. Set both so every HTTP(S) radio URL is routed
            // through the chosen endpoint on macOS 11–13.
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port
            ]
        }
    }
}

final class NetworkPreferences: ObservableObject {
    private enum Key {
        static let mode = "macAmp.network.proxyMode"
        static let customAddress = "macAmp.network.customProxyAddress"
    }

    @Published var proxyMode: NetworkProxyMode {
        didSet { UserDefaults.standard.set(proxyMode.rawValue, forKey: Key.mode) }
    }
    @Published var customProxyAddress: String {
        didSet { UserDefaults.standard.set(customProxyAddress, forKey: Key.customAddress) }
    }

    var snapshot: NetworkProxySnapshot {
        NetworkProxySnapshot(mode: proxyMode, customAddress: customProxyAddress)
    }

    var validationMessage: String? { snapshot.validationMessage }

    init(defaults: UserDefaults = .standard) {
        proxyMode = defaults.string(forKey: Key.mode).flatMap(NetworkProxyMode.init(rawValue:)) ?? .system
        customProxyAddress = defaults.string(forKey: Key.customAddress) ?? ""
    }
}

/// Incrementally parses and decodes an Icecast/Shoutcast MP3 or AAC response.
/// Unlike AVPlayer.audioMix, this path works for unbounded HTTP radio streams
/// and delivers PCM to the app's AVAudioEngine graph.
final class HTTPAudioStreamDecoder: NSObject, URLSessionDataDelegate {
    var onReady: ((AVAudioFormat, Int?) -> Void)?
    var onBitrate: ((Int) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onMetadata: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let url: URL
    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.name = "ru.aleksandr.macAmp.http-audio"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: queue)
    }()
    private var task: URLSessionDataTask?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var fileStream: AudioFileStreamID?
    private var fileTypeHint: AudioFileTypeID = kAudioFileMP3Type
    private var converter: AudioConverterRef?
    private var converterSourceFormat: AudioStreamBasicDescription?
    private var sourceFormat = AudioStreamBasicDescription()
    private var preferredSourceFormat: AudioStreamBasicDescription?
    private var isReadyToProducePackets = false
    private var outputFormat: AVAudioFormat?
    private var hasReportedReady = false
    private var reportedOutputSampleRate: Double?
    private var reportedOutputChannelCount: AVAudioChannelCount?
    private var reportedBitrateKbps: Int?
    private var deliveredBitrateKbps: Int?
    private var icyMetadataInterval: Int?
    private var audioBytesRemaining = 0
    private var metadataBytesRemaining = 0
    private var metadata = Data()
    private var isCancelled = false
    private var packetDeliveryGeneration = 0
    private var parserRecoveryData = Data()

    private static let parserInputChunkBytes = 2 * 1_024
    private static let parserStallRecoveryBytes = 8 * 1_024

    init(url: URL, proxy: NetworkProxySnapshot) throws {
        self.url = url
        sessionConfiguration = try proxy.sessionConfiguration()
        super.init()
    }

    deinit { close() }

    func start() {
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("macAmp/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.task = task
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.fileStream == nil, !self.isCancelled else { return }
            self.fail(URLError(.timedOut))
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        task.resume()
    }

    func suspend() { task?.suspend() }
    func resume() { task?.resume() }

    func cancel() {
        isCancelled = true
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            fail(URLError(.badServerResponse))
            return
        }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        if let value = Self.header("icy-br", in: http), let bitrate = Int(value) {
            updateBitrate(bitrate)
        }
        if let value = Self.header("icy-metaint", in: http), let interval = Int(value), interval > 0 {
            icyMetadataInterval = interval
            audioBytesRemaining = interval
        }
        let contentType = (http.mimeType ?? "").lowercased()
        fileTypeHint = contentType.contains("aac") ? kAudioFileAAC_ADTSType : kAudioFileMP3Type
        let status = openFileStream()
        guard status == noErr else {
            completionHandler(.cancel)
            fail(HTTPAudioStreamError.cannotOpenParser(status))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled else { return }
        if icyMetadataInterval == nil {
            parseAudio(data)
            return
        }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < rawBuffer.count {
                if metadataBytesRemaining > 0 {
                    let count = min(metadataBytesRemaining, rawBuffer.count - offset)
                    metadata.append(base.advanced(by: offset), count: count)
                    metadataBytesRemaining -= count
                    offset += count
                    if metadataBytesRemaining == 0 {
                        publishMetadata()
                        audioBytesRemaining = icyMetadataInterval ?? 0
                    }
                } else if audioBytesRemaining == 0 {
                    metadata.removeAll(keepingCapacity: true)
                    metadataBytesRemaining = Int(base[offset]) * 16
                    offset += 1
                    if metadataBytesRemaining == 0 { audioBytesRemaining = icyMetadataInterval ?? 0 }
                } else {
                    let count = min(audioBytesRemaining, rawBuffer.count - offset)
                    parseAudio(Data(bytes: base.advanced(by: offset), count: count))
                    audioBytesRemaining -= count
                    offset += count
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isCancelled, let error else { return }
        fail(error)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // This delegate callback is serialized with parsing and conversion,
        // so Core Audio objects cannot be disposed while a packet callback is
        // still using them.
        close()
    }

    fileprivate func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard let fileStream else { return }
        switch propertyID {
        case kAudioFileStreamProperty_FormatList:
            preferredSourceFormat = preferredFormat(in: fileStream)
            if isReadyToProducePackets { reconfigureConverterForPreferredFormatIfNeeded() }
        case kAudioFileStreamProperty_DataFormat:
            var discoveredFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileStreamGetProperty(fileStream, propertyID, &size, &discoveredFormat) == noErr,
                  discoveredFormat.mSampleRate > 0, discoveredFormat.mChannelsPerFrame > 0 else { return }
            sourceFormat = preferredSourceFormat ?? discoveredFormat
            if isReadyToProducePackets { reconfigureConverterForPreferredFormatIfNeeded() }
        case kAudioFileStreamProperty_BitRate:
            var bitrate = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(fileStream, propertyID, &size, &bitrate) == noErr, bitrate > 0 {
                updateBitrate(Int((Double(bitrate) / 1_000).rounded()))
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            isReadyToProducePackets = true
            if let preferredSourceFormat { sourceFormat = preferredSourceFormat }
            reconfigureConverterForPreferredFormatIfNeeded()
            applyMagicCookie()
        default:
            break
        }
    }

    fileprivate func handlePackets(
        byteCount: UInt32,
        packetCount: UInt32,
        bytes: UnsafeRawPointer,
        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard packetCount > 0, byteCount > 0 else { return }
        packetDeliveryGeneration &+= 1
        configureConverterIfNeeded()
        guard converter != nil else { return }
        let data = Data(bytes: bytes, count: Int(byteCount))
        let packetDescriptions: [AudioStreamPacketDescription]
        if let descriptions {
            packetDescriptions = Array(UnsafeBufferPointer(start: descriptions, count: Int(packetCount)))
        } else {
            let packetSize = Int(byteCount) / Int(packetCount)
            packetDescriptions = (0..<Int(packetCount)).map {
                AudioStreamPacketDescription(
                    mStartOffset: Int64($0 * packetSize),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(packetSize)
                )
            }
        }
        decode(data: data, descriptions: packetDescriptions)
    }

    private func configureConverterIfNeeded() {
        guard converter == nil, sourceFormat.mSampleRate > 0, sourceFormat.mChannelsPerFrame > 0 else { return }
        let channels = AVAudioChannelCount(min(2, sourceFormat.mChannelsPerFrame))
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.mSampleRate,
            channels: channels,
            interleaved: false
        ) else { return }
        var input = sourceFormat
        var output = outputFormat.streamDescription.pointee
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return }
        var primeMethod = UInt32(kConverterPrimeMethod_None)
        AudioConverterSetProperty(
            converter,
            kAudioConverterPrimeMethod,
            UInt32(MemoryLayout<UInt32>.size),
            &primeMethod
        )
        self.converter = converter
        converterSourceFormat = sourceFormat
        self.outputFormat = outputFormat
        applyMagicCookie()
        let outputChanged = reportedOutputSampleRate != outputFormat.sampleRate
            || reportedOutputChannelCount != outputFormat.channelCount
        if !hasReportedReady || outputChanged {
            hasReportedReady = true
            reportedOutputSampleRate = outputFormat.sampleRate
            reportedOutputChannelCount = outputFormat.channelCount
            deliveredBitrateKbps = reportedBitrateKbps
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCancelled else { return }
                self.onReady?(outputFormat, self.reportedBitrateKbps)
            }
        }
    }

    private func updateBitrate(_ bitrateKbps: Int) {
        guard bitrateKbps > 0, bitrateKbps != reportedBitrateKbps else { return }
        reportedBitrateKbps = bitrateKbps
        guard hasReportedReady, bitrateKbps != deliveredBitrateKbps else { return }
        deliveredBitrateKbps = bitrateKbps
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onBitrate?(bitrateKbps)
        }
    }

    private func preferredFormat(in fileStream: AudioFileStreamID) -> AudioStreamBasicDescription? {
        var writable = DarwinBoolean(false)
        var byteCount: UInt32 = 0
        guard AudioFileStreamGetPropertyInfo(
            fileStream,
            kAudioFileStreamProperty_FormatList,
            &byteCount,
            &writable
        ) == noErr,
        byteCount >= UInt32(MemoryLayout<AudioFormatListItem>.stride) else { return nil }

        let count = Int(byteCount) / MemoryLayout<AudioFormatListItem>.stride
        let items = UnsafeMutablePointer<AudioFormatListItem>.allocate(capacity: count)
        defer { items.deallocate() }
        guard AudioFileStreamGetProperty(
            fileStream,
            kAudioFileStreamProperty_FormatList,
            &byteCount,
            items
        ) == noErr else { return nil }

        var playableIndex = UInt32(0)
        var playableIndexSize = UInt32(MemoryLayout<UInt32>.size)
        let playableStatus = AudioFormatGetProperty(
            kAudioFormatProperty_FirstPlayableFormatFromList,
            byteCount,
            items,
            &playableIndexSize,
            &playableIndex
        )
        if playableStatus == noErr, Int(playableIndex) < count {
            let format = items[Int(playableIndex)].mASBD
            if format.mSampleRate > 0, format.mChannelsPerFrame > 0 { return format }
        }

        // The list is sorted best-first by Core Audio. Retain a defensive
        // fallback for streams whose format list cannot be queried by the
        // current system decoder.
        return UnsafeBufferPointer(start: items, count: count)
            .lazy
            .map(\.mASBD)
            .first { $0.mSampleRate > 0 && $0.mChannelsPerFrame > 0 }
    }

    private func reconfigureConverterForPreferredFormatIfNeeded() {
        if let preferredSourceFormat { sourceFormat = preferredSourceFormat }
        guard let converterSourceFormat,
              !Self.sameFormat(converterSourceFormat, sourceFormat) else {
            configureConverterIfNeeded()
            return
        }
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        self.converterSourceFormat = nil
        outputFormat = nil
        configureConverterIfNeeded()
    }

    private static func sameFormat(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }

    private func applyMagicCookie() {
        guard let fileStream, let converter else { return }
        var writable = DarwinBoolean(false)
        var cookieSize = UInt32(0)
        guard AudioFileStreamGetPropertyInfo(
            fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable
        ) == noErr, cookieSize > 0 else { return }
        var cookie = Data(count: Int(cookieSize))
        let status = cookie.withUnsafeMutableBytes { buffer in
            AudioFileStreamGetProperty(
                fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return }
        _ = cookie.withUnsafeBytes { buffer in
            AudioConverterSetProperty(
                converter, kAudioConverterDecompressionMagicCookie, cookieSize, buffer.baseAddress!
            )
        }
    }

    private func decode(data: Data, descriptions: [AudioStreamPacketDescription]) {
        guard let converter, let outputFormat else { return }
        data.withUnsafeBytes { dataBuffer in
            descriptions.withUnsafeBufferPointer { descriptionBuffer in
                guard let bytes = dataBuffer.baseAddress,
                      let packetDescriptions = descriptionBuffer.baseAddress else { return }
                var context = HTTPAudioConverterInput(
                    bytes: bytes,
                    byteCount: UInt32(dataBuffer.count),
                    descriptions: packetDescriptions,
                    packetCount: UInt32(descriptionBuffer.count),
                    packetIndex: 0,
                    channelCount: sourceFormat.mChannelsPerFrame
                )
                // A converter may emit a small amount of internally buffered
                // PCM without requesting another source packet. Keep a hard
                // bound as a defensive guarantee against a malformed stream
                // making this network-queue loop spin forever.
                var conversionPassesRemaining = descriptions.count * 4 + 16
                while context.packetIndex < context.packetCount, conversionPassesRemaining > 0 {
                    conversionPassesRemaining -= 1
                    let oldIndex = context.packetIndex
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { return }
                    // A newly allocated AVAudioPCMBuffer has frameLength == 0,
                    // which also advertises zero writable bytes in its
                    // AudioBufferList. AudioConverter therefore produced no
                    // PCM and the player remained in BUFFERING forever.
                    buffer.frameLength = buffer.frameCapacity
                    var outputFrames = UInt32(buffer.frameCapacity)
                    let status = AudioConverterFillComplexBuffer(
                        converter,
                        httpAudioConverterInputProc,
                        &context,
                        &outputFrames,
                        buffer.mutableAudioBufferList,
                        nil
                    )
                    guard status == noErr || status == httpAudioConverterNoDataNow else {
                        fail(HTTPAudioStreamError.cannotDecode(status))
                        return
                    }
                    if outputFrames > 0 {
                        buffer.frameLength = AVAudioFrameCount(outputFrames)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.isCancelled else { return }
                            self.onBuffer?(buffer)
                        }
                    }
                    if outputFrames == 0, context.packetIndex == oldIndex { return }
                }
            }
        }
    }

    private func parseAudio(_ data: Data) {
        guard fileStream != nil, !data.isEmpty else { return }
        var offset = 0
        while offset < data.count, !isCancelled {
            let end = min(offset + Self.parserInputChunkBytes, data.count)
            let chunk = data[offset..<end]
            parserRecoveryData.append(chunk)
            let generationBeforeParsing = packetDeliveryGeneration
            let status = parseBytes(chunk)
            guard status == noErr else {
                fail(HTTPAudioStreamError.cannotParse(status))
                return
            }
            if packetDeliveryGeneration != generationBeforeParsing {
                parserRecoveryData.removeAll(keepingCapacity: true)
            } else if parserRecoveryData.count >= Self.parserStallRecoveryBytes {
                recoverStalledParser()
            }
            offset = end
        }
    }

    private func parseBytes(_ data: Data) -> OSStatus {
        guard let fileStream else { return kAudioFileUnspecifiedError }
        return data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(fileStream, UInt32(buffer.count), bytes, [])
        }
    }

    private func openFileStream() -> OSStatus {
        AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            httpStreamPropertyListener,
            httpStreamPacketsListener,
            fileTypeHint,
            &fileStream
        )
    }

    /// Some Shoutcast AAC+ stations concatenate a short introduction and the
    /// live encoder output in one HTTP response. AudioFileStream can accept
    /// the following ADTS bytes without an error yet stop producing packets at
    /// that logical boundary. Once a bounded amount of valid audio has passed
    /// without a packet callback, reopen the lightweight parser and replay
    /// only those stalled bytes. The AudioConverter is retained when the
    /// decoded format remains the same, avoiding a graph interruption.
    private func recoverStalledParser() {
        let recoveryData = parserRecoveryData
        parserRecoveryData.removeAll(keepingCapacity: true)
        guard !recoveryData.isEmpty else { return }

        if let fileStream { AudioFileStreamClose(fileStream) }
        fileStream = nil
        preferredSourceFormat = nil
        isReadyToProducePackets = false
        sourceFormat = AudioStreamBasicDescription()
        let openStatus = openFileStream()
        guard openStatus == noErr else {
            fail(HTTPAudioStreamError.cannotOpenParser(openStatus))
            return
        }

        let generationBeforeRecovery = packetDeliveryGeneration
        var offset = 0
        while offset < recoveryData.count, !isCancelled {
            let end = min(offset + Self.parserInputChunkBytes, recoveryData.count)
            let status = parseBytes(recoveryData[offset..<end])
            guard status == noErr else {
                fail(HTTPAudioStreamError.cannotParse(status))
                return
            }
            offset = end
        }
        if packetDeliveryGeneration == generationBeforeRecovery {
            // Wait for another full bounded window before retrying. This
            // prevents a malformed source from creating a tight reopen loop.
            parserRecoveryData.removeAll(keepingCapacity: true)
        }
    }

    private func publishMetadata() {
        guard let string = String(data: metadata, encoding: .utf8) else { return }
        let fields = string.split(separator: ";")
        guard let field = fields.first(where: { $0.lowercased().hasPrefix("streamtitle=") }),
              let equals = field.firstIndex(of: "=") else { return }
        var title = String(field[field.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("'") { title.removeFirst() }
        if title.hasSuffix("'") { title.removeLast() }
        guard !title.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onMetadata?(title) }
    }

    private func fail(_ error: Error) {
        guard !isCancelled else { return }
        isCancelled = true
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func close() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        converterSourceFormat = nil
        if let fileStream { AudioFileStreamClose(fileStream) }
        fileStream = nil
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { String(describing: $0.key).caseInsensitiveCompare(name) == .orderedSame }
            .map { String(describing: $0.value) }
    }
}

private enum HTTPAudioStreamError: LocalizedError {
    case cannotOpenParser(OSStatus)
    case cannotParse(OSStatus)
    case cannotDecode(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotOpenParser(let status): return "Cannot open the HTTP audio parser (\(status))."
        case .cannotParse(let status): return "Cannot parse the HTTP audio stream (\(status))."
        case .cannotDecode(let status): return "Cannot decode the HTTP audio stream (\(status))."
        }
    }
}

private struct HTTPAudioConverterInput {
    let bytes: UnsafeRawPointer
    let byteCount: UInt32
    let descriptions: UnsafePointer<AudioStreamPacketDescription>
    let packetCount: UInt32
    var packetIndex: UInt32
    let channelCount: UInt32
}

/// AudioConverter has no public "temporarily empty" constant. Its contract
/// explicitly permits a client-defined error for that condition; returning
/// noErr with zero packets instead marks a permanent end of stream.
private let httpAudioConverterNoDataNow = OSStatus(bitPattern: 0x6E64_7461) // 'ndta'

private func httpStreamPropertyListener(
    _ clientData: UnsafeMutableRawPointer,
    _ stream: AudioFileStreamID,
    _ propertyID: AudioFileStreamPropertyID,
    _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    Unmanaged<HTTPAudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue().handleProperty(propertyID)
}

private func httpStreamPacketsListener(
    _ clientData: UnsafeMutableRawPointer,
    _ byteCount: UInt32,
    _ packetCount: UInt32,
    _ bytes: UnsafeRawPointer,
    _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    Unmanaged<HTTPAudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue().handlePackets(
        byteCount: byteCount,
        packetCount: packetCount,
        bytes: bytes,
        descriptions: descriptions
    )
}

private func httpAudioConverterInputProc(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { packetCount.pointee = 0; return httpAudioConverterNoDataNow }
    let context = userData.assumingMemoryBound(to: HTTPAudioConverterInput.self)
    let remaining = context.pointee.packetCount - context.pointee.packetIndex
    let supplied = min(packetCount.pointee, remaining)
    guard supplied > 0 else { packetCount.pointee = 0; return httpAudioConverterNoDataNow }
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = context.pointee.channelCount
    data.pointee.mBuffers.mDataByteSize = context.pointee.byteCount
    data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: context.pointee.bytes)
    packetDescriptions?.pointee = UnsafeMutablePointer(
        mutating: context.pointee.descriptions.advanced(by: Int(context.pointee.packetIndex))
    )
    context.pointee.packetIndex += supplied
    packetCount.pointee = supplied
    return noErr
}
