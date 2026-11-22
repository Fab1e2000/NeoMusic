import Foundation
import XCTest
@testable import AudioStreaming

final class RemoteAudioSourceTests: XCTestCase {
    func testConsecutiveFailuresBackOffAndExhaustTheirBudgetUntilReset() {
        let retrier = Retrier(queue: .main)
        for delay in 1...5 {
            XCTAssertEqual(retrier.nextDelay, delay)
            XCTAssertTrue(retrier.schedule { XCTFail("Cancelled retry fired") })
            XCTAssertTrue(retrier.schedule { XCTFail("Duplicate retry fired") })
            retrier.cancelPending()
        }
        XCTAssertNil(retrier.nextDelay)
        XCTAssertFalse(retrier.schedule { XCTFail("Exhausted retry fired") })
        retrier.reset()
        XCTAssertEqual(retrier.nextDelay, 1)
    }

    func testProbeConnectionFailureIsReported() {
        let failed = expectation(description: "report transport error before headers")
        let (source, networking) = makeSource { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Range"), "bytes=0-1")
            request.client?.urlProtocol(request, didFailWithError: URLError(.cannotConnectToHost))
        }
        defer { source.close(); networking.session.invalidateAndCancel() }

        let delegate = SourceDelegate(onError: { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            failed.fulfill()
        })
        source.delegate = delegate
        source.seek(at: 0)
        wait(for: [failed], timeout: 3)
        withExtendedLifetime(delegate) {}
    }

    func testCloseCancelsInFlightProbe() {
        let started = expectation(description: "probe started")
        let stopped = expectation(description: "probe cancelled by close")
        let (source, networking) = makeSource(onStart: { _ in
            started.fulfill()
        }, onStop: { _ in
            stopped.fulfill()
        })
        defer { networking.session.invalidateAndCancel() }

        let delegate = SourceDelegate()
        source.delegate = delegate
        source.seek(at: 0)
        wait(for: [started], timeout: 3)
        source.close()
        wait(for: [stopped], timeout: 3)
        withExtendedLifetime(delegate) {}
    }

    func testIncompleteNonRangePrefixRestartsWithoutDuplicateBytes() {
        let complete = expectation(description: "reopened stream completed")
        let prefix = Data([1, 2, 3, 4])
        let suffix = Data([5, 6, 7, 8])
        var transferCount = 0
        let (source, networking) = makeSource { request in
            request.respond(length: 8)
            guard request.request.value(forHTTPHeaderField: "Range") == nil else { return }
            transferCount += 1
            request.client?.urlProtocol(request, didLoad: prefix)
            if transferCount == 2 {
                request.client?.urlProtocol(request, didLoad: suffix)
                request.client?.urlProtocolDidFinishLoading(request)
            }
        }
        defer { source.close(); networking.session.invalidateAndCancel() }

        var didSeek = false
        var afterSeek = Data()
        let delegate = SourceDelegate(onData: { data in
            if didSeek {
                afterSeek.append(data)
            } else {
                XCTAssertEqual(data, prefix)
                didSeek = true
                source.underlyingQueue.async { source.seek(at: 0) }
            }
        }, onEOF: {
            XCTAssertEqual(afterSeek, prefix + suffix)
            XCTAssertFalse(source.canSeek)
            complete.fulfill()
        })
        source.delegate = delegate
        source.seek(at: 0)
        wait(for: [complete], timeout: 3)
        withExtendedLifetime(delegate) {}
    }

    func testSourcePauseSuspendsUnderlyingTransferAndResumeRestartsIt() {
        let receiving = expectation(description: "stream is reading")
        let paused = expectation(description: "URLSession stream suspended")
        let resumed = expectation(description: "URLSession stream resumed")
        let firstBytes = Data([1, 2, 3, 4])
        var didSendFirstBytes = false
        let (source, networking) = makeSource { request in
            request.respond(length: 16)
            guard request.request.value(forHTTPHeaderField: "Range") == nil, !didSendFirstBytes else { return }
            didSendFirstBytes = true
            request.client?.urlProtocol(request, didLoad: firstBytes)
        }
        defer { source.close(); networking.session.invalidateAndCancel() }

        let delegate = SourceDelegate(onData: { data in
            XCTAssertEqual(data, firstBytes)
            receiving.fulfill()
        })
        source.delegate = delegate
        source.seek(at: 0)
        wait(for: [receiving], timeout: 3)

        source.suspend()
        networking.session.getAllTasks { tasks in
            let stream = tasks.first { $0.originalRequest?.value(forHTTPHeaderField: "Range") == nil }
            XCTAssertEqual(stream?.state, .suspended)
            paused.fulfill()
        }
        wait(for: [paused], timeout: 3)

        source.resume()
        networking.session.getAllTasks { tasks in
            let stream = tasks.first { $0.originalRequest?.value(forHTTPHeaderField: "Range") == nil }
            XCTAssertEqual(stream?.state, .running)
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 3)
        withExtendedLifetime(delegate) {}
    }

    func testSlowDecoderSuspendsTransferUntilPendingBytesDrain() async {
        let enteredDecoder = expectation(description: "first chunk reached the decoder")
        let drained = expectation(description: "queued chunks reached the decoder")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let data = Data(repeating: 0x42, count: 768 * 1024)
        var sent = false
        let (source, networking) = makeSource { request in
            request.respond(length: data.count * 2)
            guard request.request.value(forHTTPHeaderField: "Range") == nil, !sent else { return }
            sent = true
            request.client?.urlProtocol(request, didLoad: data)
        }
        defer { source.close(); networking.session.invalidateAndCancel() }

        var receivedBytes = 0
        let delegate = SourceDelegate(onData: { chunk in
            if receivedBytes == 0 {
                enteredDecoder.fulfill()
                XCTAssertEqual(releaseDecoder.wait(timeout: .now() + 5), .success)
            }
            receivedBytes += chunk.count
            if receivedBytes == data.count { drained.fulfill() }
        })
        source.delegate = delegate
        source.seek(at: 0)
        await fulfillment(of: [enteredDecoder], timeout: 3)

        let suspended = await transfer(in: networking.session, reaches: .suspended)
        XCTAssertTrue(suspended)
        releaseDecoder.signal()

        await fulfillment(of: [drained], timeout: 3)
        let resumed = await transfer(in: networking.session, reaches: .running)
        XCTAssertTrue(resumed)
        withExtendedLifetime(delegate) {}
    }

    private func transfer(in session: URLSession, reaches state: URLSessionTask.State) async -> Bool {
        for _ in 0..<100 {
            let tasks = await session.allTasks
            if tasks.contains(where: { $0.originalRequest?.value(forHTTPHeaderField: "Range") == nil && $0.state == state }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func makeSource(onStart: @escaping (AudioURLProtocol) -> Void,
                            onStop: @escaping (AudioURLProtocol) -> Void = { _ in }) -> (RemoteAudioSource, NetworkingClient) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioURLProtocol.self]
        AudioURLProtocol.onStart = onStart
        AudioURLProtocol.onStop = onStop
        let networking = NetworkingClient(configuration: configuration)
        let source = RemoteAudioSource(networking: networking,
                                       url: URL(string: "https://audiosource.invalid/song.mp3")!,
                                       underlyingQueue: DispatchQueue(label: "remote-audio-source-test"))
        return (source, networking)
    }
}

private final class AudioURLProtocol: URLProtocol {
    static var onStart: ((AudioURLProtocol) -> Void)?
    static var onStop: ((AudioURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?(self) }
    override func stopLoading() { Self.onStop?(self) }

    func respond(length: Int) {
        let headers = ["Content-Type": "audio/mpeg", "Content-Length": String(length), "Accept-Ranges": "none"]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

private final class SourceDelegate: AudioStreamSourceDelegate {
    let onData: (Data) -> Void
    let onError: (Error) -> Void
    let onEOF: () -> Void

    init(onData: @escaping (Data) -> Void = { _ in XCTFail("Unexpected audio data") },
         onError: @escaping (Error) -> Void = { XCTFail("Unexpected error: \($0)") },
         onEOF: @escaping () -> Void = { XCTFail("Unexpected end of stream") }) {
        self.onData = onData
        self.onError = onError
        self.onEOF = onEOF
    }

    func dataAvailable(source: CoreAudioStreamSource, data: Data) { onData(data) }
    func errorOccurred(source: CoreAudioStreamSource, error: Error) { onError(error) }
    func endOfFileOccurred(source: CoreAudioStreamSource) { onEOF() }
    func metadataReceived(data: [String: String]) {}
}
