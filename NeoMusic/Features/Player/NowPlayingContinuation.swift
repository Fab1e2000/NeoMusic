import Foundation

extension NowPlayingModel {
    func toggleAutomaticContinuation() {
        if isAutomaticContinuationEnabled { stopAutomaticContinuation(); return }
        guard hasCurrent, let owner = recommendationOwner?(current), fetchRecommendations != nil else { return }
        repeatMode = .off
        continuation = PlaybackQueueContinuation(ownerID: owner, kind: .recommendations)
        saveQueue()
        requestRecommendations()
    }

    func stopAutomaticContinuation() {
        guard isAutomaticContinuationEnabled else { return }
        let ended = endedWaitingForRecommendations && advanceAfterRecommendations == (hasCurrent ? entryIDs[currentIndex] : nil)
        continuation = nil
        hasRecommendationBatch = false
        recommendationTask?.cancel()
        recommendationTask = nil
        advanceAfterRecommendations = nil
        endedWaitingForRecommendations = false
        let playingEntry = hasCurrent ? entryIDs[currentIndex] : nil
        if let playingEntry { recommendedEntries.remove(playingEntry) }
        let remove = recommendedEntries
        recommendedEntries.removeAll()
        if !remove.isEmpty {
            queue = zip(entryIDs, queue).compactMap { remove.contains($0.0) ? nil : $0.1 }
            entryIDs.removeAll { remove.contains($0) }
            originalOrder.removeAll { remove.contains($0) }
            if let playingEntry, let index = entryIDs.firstIndex(of: playingEntry) { currentIndex = index }
        }
        if !suspended.isEmpty {
            var known = Set(queue.map(\.id))
            let restored = suspended.filter { known.insert($0.1.id).inserted }
            entryIDs.append(contentsOf: restored.map(\.0))
            queue.append(contentsOf: restored.map(\.1))
            suspended.removeAll()
            let retained = Set(entryIDs)
            originalOrder.removeAll { !retained.contains($0) }
        }
        prepareNext()
        if ended { isPlaying = false }
        saveQueue()
    }

    func replenish(_ token: PlaybackQueueContinuation, _ advance: Bool, _ ended: Bool) {
        guard token.kind == .recommendations else { replenishQueue?(token, advance, ended); return }
        guard recommendationOwner?(current) == token.ownerID else { stopAutomaticContinuation(); return }
        guard upcoming.count <= 1 else { return }
        if advance && next == nil {
            advanceAfterRecommendations = entryIDs[currentIndex]
            endedWaitingForRecommendations = endedWaitingForRecommendations || ended
        }
        requestRecommendations()
    }

    private func requestRecommendations() {
        guard let token = continuation, recommendationTask == nil, let fetchRecommendations else { return }
        let seed = current
        recommendationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let batch = try? await fetchRecommendations(seed)
            guard let self, !Task.isCancelled, continuation == token else { return }
            recommendationTask = nil
            guard recommendationOwner?(current) == token.ownerID else { stopAutomaticContinuation(); return }
            // Only the first successful response takes over the source queue.
            let ordinary = hasRecommendationBatch ? [] : entryIDs.indices.dropFirst(currentIndex + 1).filter {
                !userQueuedIDs.contains(entryIDs[$0]) && !recommendedEntries.contains(entryIDs[$0])
            }
            let parked = Set(ordinary.map { entryIDs[$0] })
            var known = Set(zip(entryIDs, queue).compactMap { parked.contains($0.0) ? nil : $0.1.id })
            let additions = (batch ?? []).filter { $0.unavailabilityReason == nil && known.insert($0.id).inserted }
            guard !additions.isEmpty else {
                stopAutomaticContinuation()
                return
            }
            if !parked.isEmpty {
                suspended = ordinary.map { (entryIDs[$0], queue[$0]) }
                queue = zip(entryIDs, queue).compactMap { parked.contains($0.0) ? nil : $0.1 }
                entryIDs.removeAll { parked.contains($0) }
            }
            hasRecommendationBatch = true
            let advance = advanceAfterRecommendations == entryIDs[currentIndex]
            let resume = advance && endedWaitingForRecommendations
            advanceAfterRecommendations = nil
            endedWaitingForRecommendations = false
            appendToEnd(additions, userQueued: false, recommended: true)
            onRecommendationsQueued?()

            if resume { isPlaying = true }
            if advance { select(currentIndex + 1) }
        }
    }
}
