//
//  Created by Dimitrios Chatzieleftheriou on 13/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

/// Access is serialized by the owning source's request lock.
final class Retrier {
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?
    private var attempts = 0

    init(queue: DispatchQueue) { self.queue = queue }

    var nextDelay: Int? { attempts < 5 ? attempts + 1 : nil }

    func schedule(_ callback: @escaping () -> Void) -> Bool {
        if pending != nil { return true }
        guard let delay = nextDelay else { return false }
        attempts += 1
        let work = DispatchWorkItem(block: callback)
        pending = work
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        return true
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func reset() {
        cancelPending()
        attempts = 0
    }
}
