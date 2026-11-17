//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import AVFoundation
import Foundation
import Network

enum RemoteAudioSourceError: Error {
    case mp4NotSeekable
}

public class RemoteAudioSource: AudioStreamSource {
    public weak var delegate: AudioStreamSourceDelegate?

    public var position: Int {
        return seekOffset + relativePosition
    }

    public var length: Int {
        guard let parsedHeader = parsedHeaderOutput else { return 0 }
        return parsedHeader.fileLength
    }

    public var canSeek: Bool { supportsSeek }

    private let url: URL
    private let httpMethod: String?
    private let httpBody: Data?
    private let networkingClient: NetworkingClient
    private var streamRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]

    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int
    private var supportsSeek: Bool
    private var cachedPrefixData = Data()
    private var cachedPrefixEOF = false
    private var hasCompletedInitialRequest = false
    private var activeStreamGeneration = 0
    private let maxPrefixCacheBytes = 64 * 1024 * 1024

    var metadataStreamProcessor: MetadataStreamSource

    private var shouldTryParsingIcycastHeaders: Bool = false
    private let icycastHeadersProcessor: IcycastHeadersProcessor

    public var audioFileHint: AudioFileTypeID {
        guard let output = parsedHeaderOutput, output.typeId != 0 else {
            return audioFileType(fileExtension: url.pathExtension)
        }
        return output.typeId
    }

    private let mp4Restructure: RemoteMp4Restructure

    public let underlyingQueue: DispatchQueue
    let streamOperationQueue: OperationQueue
    let netStatusService: NetStatusProvider
    var waitingForNetwork = false
    let retrierTimeout: Retrier

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         icycastHeadersProcessor: IcycastHeadersProcessor,
         netStatusProvider: NetStatusProvider,
         retrier: Retrier,
         url: URL,
         httpMethod: String?,
         httpBody: Data?,
         underlyingQueue: DispatchQueue,
         httpHeaders: [String: String])
    {
        networkingClient = networking
        metadataStreamProcessor = metadataStreamSource
        self.url = url
        self.httpMethod = httpMethod
        self.httpBody = httpBody
        additionalRequestHeaders = httpHeaders
        relativePosition = 0
        seekOffset = 0
        supportsSeek = false
        netStatusService = netStatusProvider
        self.icycastHeadersProcessor = icycastHeadersProcessor
        self.underlyingQueue = underlyingQueue
        streamOperationQueue = OperationQueue()
        streamOperationQueue.underlyingQueue = underlyingQueue
        streamOperationQueue.maxConcurrentOperationCount = 1
        streamOperationQueue.isSuspended = true
        streamOperationQueue.name = "remote.audio.source.data.stream.queue"
        retrierTimeout = retrier
        mp4Restructure = RemoteMp4Restructure(url: url, networking: networkingClient)
        startNetworkService()
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     httpMethod: String?,
                     httpBody: Data?,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        let metadataParser = MetadataParser()
        let metadataProcessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        let netStatusProvider = NetStatusService(network: NWPathMonitor())
        let icyheaderProcessor = IcycastHeadersProcessor()
        let retrierTimeout = Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: nil)
        self.init(networking: networking,
                  metadataStreamSource: metadataProcessor,
                  icycastHeadersProcessor: icyheaderProcessor,
                  netStatusProvider: netStatusProvider,
                  retrier: retrierTimeout,
                  url: url,
                  httpMethod: httpMethod,
                  httpBody: httpBody,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: httpHeaders)
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        self.init(networking: networking,
                  url: url,
                  httpMethod: nil,
                  httpBody: nil,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: httpHeaders)
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue)
    {
        self.init(networking: networking,
                  url: url,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: [:])
    }

    public func close() {
        retrierTimeout.cancel()
        streamOperationQueue.isSuspended = false
        streamOperationQueue.cancelAllOperations()
        if let streamTask = streamRequest {
            streamTask.cancel()
            networkingClient.remove(task: streamTask)
        }
        streamRequest = nil
    }

    public func seek(at offset: Int) {
        activeStreamGeneration &+= 1
        let generation = activeStreamGeneration
        close()

        relativePosition = 0
        seekOffset = offset

        if parsedHeaderOutput?.isMp4 != true,
           !cachedPrefixData.isEmpty,
           offset >= 0,
           offset < cachedPrefixData.count || (offset == cachedPrefixData.count && cachedPrefixEOF)
        {
            retrierTimeout.cancel()
            metadataStreamProcessor.reset()
            icycastHeadersProcessor.reset()
            shouldTryParsingIcycastHeaders = false
            streamOperationQueue.isSuspended = false
            replayCachedPrefix(from: offset, generation: generation)
            return
        }

        // A response without byte-range support cannot open at a later offset.
        // Restart from the beginning and let AudioPlayer discard the prefix up
        // to the requested position; returning here would leave the stream dead.
        if !supportsSeek, offset != 0 {
            seekOffset = 0
        }

        mp4Restructure.clear()
        retrierTimeout.cancel()
        metadataStreamProcessor.reset()
        icycastHeadersProcessor.reset()
        shouldTryParsingIcycastHeaders = false

        performOpen(seek: seekOffset, generation: generation)
    }

    public func suspend() {
        streamOperationQueue.isSuspended = true
    }

    public func resume() {
        streamOperationQueue.isSuspended = false
    }

    // MARK: Private

    private func startNetworkService() {
        netStatusService.start { [weak self] connection in
            guard let self = self else { return }
            guard connection.isConnected else { return }
            if self.waitingForNetwork {
                self.seek(at: self.supportsSeek ? self.position : 0)
                self.waitingForNetwork = false
            }
        }
    }

    private func replayCachedPrefix(from offset: Int, generation: Int) {
        let snapshot = cachedPrefixData
        let reachedEOF = cachedPrefixEOF
        let canResumeNetwork = supportsSeek
        let chunkSize = 64 * 1024

        var cursor = offset
        while cursor < snapshot.count {
            let end = min(cursor + chunkSize, snapshot.count)
            let chunk = snapshot.subdata(in: cursor..<end)
            addStreamOperation { [weak self] in
                guard let self, self.activeStreamGeneration == generation else { return }
                self.delegate?.dataAvailable(source: self, data: chunk)
                self.relativePosition += chunk.count
            }
            cursor = end
        }

        if reachedEOF {
            addCompletionOperation { [weak self] in
                guard let self, self.activeStreamGeneration == generation else { return }
                self.delegate?.endOfFileOccurred(source: self)
            }
        } else if canResumeNetwork {
            addStreamOperation { [weak self] in
                guard let self, self.activeStreamGeneration == generation else { return }
                self.seekOffset = snapshot.count
                self.relativePosition = 0
                self.doPerfomOpen(seek: snapshot.count, generation: generation)
            }
        } else {
            performOpen(seek: 0, generation: generation)
        }
    }

    private func performOpen(seek seekOffset: Int, generation: Int) {
        if seekOffset == 0 {
            if hasCompletedInitialRequest {
                if parsedHeaderOutput?.isMp4 == true {
                    handleMp4Files(generation: generation)
                } else {
                    doPerfomOpen(seek: 0, generation: generation)
                }
                return
            }
            initialRequest { [weak self] in
                guard let self, self.activeStreamGeneration == generation else { return }
                self.hasCompletedInitialRequest = true
                if self.parsedHeaderOutput?.isMp4 == true {
                    self.handleMp4Files(generation: generation)
                } else {
                    self.doPerfomOpen(seek: 0, generation: generation)
                }
            }
        } else {
            if mp4Restructure.dataOptimized {
                let adjustedOffset = mp4Restructure.seekAdjusted(offset: seekOffset)
                doPerfomOpen(seek: adjustedOffset, generation: generation)
            } else {
                doPerfomOpen(seek: seekOffset, generation: generation)
            }
        }
    }

    private func doPerfomOpen(seek seekOffset: Int, generation: Int) {
        guard activeStreamGeneration == generation else { return }
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        streamRequest = networkingClient.stream(request: urlRequest)
            .responseStream { [weak self] event in
                guard let self, self.activeStreamGeneration == generation else { return }
                self.handleResponse(event: event, generation: generation)
            }
            .resume()

        metadataStreamProcessor.delegate = self
    }

    private func initialRequest(completion: @escaping () -> Void) {
        let urlRequest = fetchUrlForPartialContent(with: url)
        let task: NetworkDataStream = networkingClient.stream(request: urlRequest)
        task.responseStream { [weak self] event in
            switch event {
            case let .response(urlResponse):
                self?.parseResponseHeader(response: urlResponse)
                task.cancel()
                completion()
            default:
                break
            }
        }.resume()
    }

    private func handleMp4Files(generation: Int) {
        mp4Restructure.optimizeIfNeeded { [weak self] result in
            guard let self, self.activeStreamGeneration == generation else { return }
            switch result {
            case let .success(value):
                if let value {
                    self.addStreamOperation {
                        guard self.activeStreamGeneration == generation else { return }
                        let audioCount = self.processAudio(data: value.initialData)
                        self.relativePosition += audioCount
                    }
                    self.doPerfomOpen(seek: value.mdatOffset, generation: generation)
                } else {
                    self.doPerfomOpen(seek: 0, generation: generation)
                }
            case let .failure(failure):
                self.delegate?.errorOccurred(source: self, error: failure)
            }
        }
    }

    // MARK: - Network Handle Methods

    private func handleResponse(event: NetworkDataStream.ResponseEvent, generation: Int) {
        guard activeStreamGeneration == generation else { return }
        switch event {
        case let .response(urlResponse):
            parseResponseHeader(response: urlResponse)
            streamOperationQueue.isSuspended = false
        case let .stream(.success(response)):
            handleSuccessfulStreamEvent(response: response, generation: generation)
        case let .stream(.failure(error)):
            handleFailedStreamEvent(error: error)
        case let .complete(event):
            if let error = event.error {
                delegate?.errorOccurred(source: self, error: error)
            } else {
                addCompletionOperation { [weak self] in
                    guard let self, self.activeStreamGeneration == generation else { return }
                    if self.parsedHeaderOutput?.isMp4 != true,
                       self.seekOffset + self.relativePosition == self.cachedPrefixData.count
                    {
                        self.cachedPrefixEOF = true
                    }
                    self.delegate?.endOfFileOccurred(source: self)
                }
            }
        }
    }

    private func handleSuccessfulStreamEvent(response: NetworkDataStream.Response, generation: Int) {
        guard let audioData = response.data else {
            delegate?.errorOccurred(source: self, error: NetworkError.missingData)
            return
        }
        addStreamOperation { [weak self] in
            guard let self, self.activeStreamGeneration == generation else { return }
            if self.shouldTryParsingIcycastHeaders {
                let (header, extractedAudio) = self.icycastHeadersProcessor.process(data: audioData)
                if let header = header {
                    self.shouldTryParsingIcycastHeaders = false
                    let parser = IcycastHeaderParser()
                    self.parsedHeaderOutput = parser.parse(input: header)
                    if let metadataStep = self.parsedHeaderOutput?.metadataStep {
                        self.metadataStreamProcessor.metadataAvailable(step: metadataStep)
                    }
                }
                let audioCount = self.processAudio(data: extractedAudio)
                self.relativePosition += audioCount
                return
            }
            let audioCount = self.processAudio(data: audioData)
            self.relativePosition += audioCount
        }
    }

    private func handleFailedStreamEvent(error _: Error) {
        if !netStatusService.isConnected {
            waitingForNetwork = true
            return
        }
        waitingForNetwork = false
        retryOnError()
    }

    /// Processing audio data, extracting metadata if needed.
    /// - Parameter data: The audio to be processed
    /// - Returns: An `Int` value representing the amount of audio data bytes.
    private func processAudio(data: Data) -> Int {
        let output: Data
        if metadataStreamProcessor.canProcessMetadata {
            output = metadataStreamProcessor.processMetadata(data: data)
        } else {
            output = data
        }
        if parsedHeaderOutput?.isMp4 != true,
           seekOffset + relativePosition == cachedPrefixData.count,
           cachedPrefixData.count + output.count <= maxPrefixCacheBytes
        {
            cachedPrefixData.append(output)
        }
        delegate?.dataAvailable(source: self, data: output)
        return output.count
    }

    private func parseResponseHeader(response: HTTPURLResponse?) {
        guard let response = response else { return }
        let httpStatusCode = response.statusCode
        let parser = HTTPHeaderParser()
        parsedHeaderOutput = parser.parse(input: response)

        if parsedHeaderOutput == nil {
            shouldTryParsingIcycastHeaders = true
            checkHTTP(statusCode: httpStatusCode)
            return
        }

        if httpStatusCode == 206 {
            supportsSeek = true
        } else if let acceptRanges = parser.value(forHTTPHeaderField: HeaderField.acceptRanges, in: response) {
            supportsSeek = acceptRanges != "none"
        }

        // check to see if we have metadata to process
        if let metadataStep = parsedHeaderOutput?.metadataStep {
            metadataStreamProcessor.metadataAvailable(step: metadataStep)
        }
        checkHTTP(statusCode: httpStatusCode)
    }

    private func checkHTTP(statusCode: Int) {
        // check for error
        if statusCode == 416 { // range not satisfied error
            if length >= 0 { seekOffset = length }
            delegate?.endOfFileOccurred(source: self)
        } else if statusCode >= 300 {
            delegate?.errorOccurred(
                source: self,
                error: NetworkError.serverError
            )
        }
    }

    private func buildUrlRequest(with url: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = httpBody

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if supportsSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)-", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    private func fetchUrlForPartialContent(with url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = httpBody

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.addValue("bytes=0-1", forHTTPHeaderField: "Range")
        return urlRequest
    }

    private func retryOnError() {
        retrierTimeout.retry { [weak self] in
            guard let self = self else { return }
            self.seek(at: self.supportsSeek ? self.position : 0)
        }
    }

    // MARK: - Network Stream Operation Queue

    /// Schedules the given block on the stream operation queue
    ///
    /// - Parameter block: A closure to be executed
    private func addStreamOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.qualityOfService = .userInitiated
        streamOperationQueue.addOperation(operation)
    }

    /// Schedules the given block on the stream operation queue as a completion
    ///
    /// - Parameter block: A closure to be executed
    private func addCompletionOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.queuePriority = .veryLow
        streamOperationQueue.addOperation(operation)
    }
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String: String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        delegate?.metadataReceived(data: data)
    }
}
