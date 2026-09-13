import AVFoundation
import AudioToolbox
import Foundation

/// Incrementally parses and decodes an Icecast/Shoutcast MP3 or AAC response.
/// Unlike AVPlayer.audioMix, this path works for unbounded HTTP radio streams
/// and delivers PCM to the app's AVAudioEngine graph.
final class HTTPAudioStreamDecoder: NSObject, URLSessionDataDelegate {
    var onReady: ((AVAudioFormat, Int?) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onMetadata: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let url: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let queue = OperationQueue()
        queue.name = "ru.aleksandr.macAmp.http-audio"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()
    private var task: URLSessionDataTask?
    private var fileStream: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var sourceFormat = AudioStreamBasicDescription()
    private var outputFormat: AVAudioFormat?
    private var hasReportedReady = false
    private var reportedBitrateKbps: Int?
    private var icyMetadataInterval: Int?
    private var audioBytesRemaining = 0
    private var metadataBytesRemaining = 0
    private var metadata = Data()
    private var isCancelled = false

    init(url: URL) {
        self.url = url
        super.init()
    }

    deinit { close() }

    func start() {
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("macAmp/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func suspend() { task?.suspend() }
    func resume() { task?.resume() }

    func cancel() {
        isCancelled = true
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
        if let value = Self.header("icy-br", in: http), let bitrate = Int(value) {
            reportedBitrateKbps = bitrate
        }
        if let value = Self.header("icy-metaint", in: http), let interval = Int(value), interval > 0 {
            icyMetadataInterval = interval
            audioBytesRemaining = interval
        }
        let contentType = (http.mimeType ?? "").lowercased()
        let hint: AudioFileTypeID = contentType.contains("aac") ? kAudioFileAAC_ADTSType : kAudioFileMP3Type
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            httpStreamPropertyListener,
            httpStreamPacketsListener,
            hint,
            &fileStream
        )
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
        case kAudioFileStreamProperty_DataFormat:
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileStreamGetProperty(fileStream, propertyID, &size, &sourceFormat) == noErr,
                  sourceFormat.mSampleRate > 0, sourceFormat.mChannelsPerFrame > 0 else { return }
            configureConverterIfNeeded()
        case kAudioFileStreamProperty_BitRate:
            var bitrate = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(fileStream, propertyID, &size, &bitrate) == noErr, bitrate > 0 {
                reportedBitrateKbps = Int((Double(bitrate) / 1_000).rounded())
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            configureConverterIfNeeded()
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
        self.outputFormat = outputFormat
        applyMagicCookie()
        if !hasReportedReady {
            hasReportedReady = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCancelled else { return }
                self.onReady?(outputFormat, self.reportedBitrateKbps)
            }
        }
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
        guard let fileStream, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress else { return }
            let status = AudioFileStreamParseBytes(fileStream, UInt32(buffer.count), bytes, [])
            if status != noErr { fail(HTTPAudioStreamError.cannotParse(status)) }
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
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func close() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
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
