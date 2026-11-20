//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class NetworkDataStream {
    typealias StreamResult = Result<Response, Error>
    typealias StreamCompletion = (_ event: NetworkDataStream.ResponseEvent) -> Void

    enum State {
        case initialised
        case resumed
        case suspended
        case cancelled
        case finished
    }

    struct Response {
        let response: HTTPURLResponse?
        let data: Data?
    }

    enum ResponseEvent {
        case stream(StreamResult)
        case complete(Completion)
        case response(HTTPURLResponse?)
    }

    struct Completion {
        let response: HTTPURLResponse?
        let error: Error?
    }

    private var streamCallback: StreamCompletion?

    private let stateLock = UnfairLock()
    private let id: UUID

    private var state: State

    var isCancelled: Bool {
        stateLock.withLock { state == .cancelled }
    }

    /// the underlying task of the network request
    var task: URLSessionTask?

    var urlResponse: HTTPURLResponse? {
        task?.response as? HTTPURLResponse
    }

    init(id: UUID) {
        self.id = id
        state = .initialised
    }

    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let task = session.dataTask(with: request)
        self.task = task
        return task
    }

    @discardableResult
    func responseStream(completion: @escaping StreamCompletion) -> Self {
        stateLock.withLock { streamCallback = completion }
        return self
    }

    @discardableResult
    func resume() -> Self {
        stateLock.withLock {
            guard state.canBecome(.resumed) else { return }
            state = .resumed
            task?.resume()
        }
        return self
    }

    func cancel() {
        stateLock.withLock {
            guard state.canBecome(.cancelled) else { return }
            state = .cancelled
            streamCallback = nil
            task?.cancel()
            task = nil
        }
    }

    func suspend() {
        stateLock.withLock {
            // A newly created URLSessionTask is already suspended.
            guard state == .resumed else { return }
            state = .suspended
            task?.suspend()
        }
    }

    // These calls arrive on the serial URLSession delegate queue. Deliver before
    // returning so backpressure can stop more data from reaching the decoder queue.

    func didReceive(response: HTTPURLResponse?) {
        let callback = stateLock.withLock { streamCallback }
        callback?(.response(response))
    }

    func didReceive(data: Data, response: HTTPURLResponse?) {
        let callback = stateLock.withLock { streamCallback }
        callback?(.stream(.success(Response(response: response, data: data))))
    }

    func didComplete(with error: Error?, response: HTTPURLResponse?) {
        let callback: StreamCompletion? = stateLock.withLock {
            guard state.canBecome(.finished) else { return nil }
            state = .finished
            let callback = streamCallback
            streamCallback = nil
            return callback
        }
        if let error {
            callback?(.stream(.failure(error)))
        } else {
            callback?(.complete(Completion(response: response, error: nil)))
        }
    }
}

// MARK: Equatable & Hashable

extension NetworkDataStream: Equatable {
    static func == (lhs: NetworkDataStream, rhs: NetworkDataStream) -> Bool {
        lhs.id == rhs.id
    }
}

extension NetworkDataStream: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension NetworkDataStream.State {
    func canBecome(_ state: NetworkDataStream.State) -> Bool {
        switch (self, state) {
        case (.initialised, _):
            return true
        case (_, .initialised),
             (.cancelled, _),
             (.finished, _):
            return false
        case (.resumed, .cancelled),
             (.resumed, .suspended),
             (.suspended, .resumed),
             (.suspended, .cancelled):
            return true
        case (.suspended, .suspended),
             (.resumed, .resumed):
            return false
        case (_, .finished):
            return true
        }
    }
}
