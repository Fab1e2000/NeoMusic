import Foundation

/// 收藏专辑的加入时间。第一次看到的名单只建立基线，之后新出现的专辑才记下当前时间。
struct AlbumLibraryAdditions: Equatable, Codable, Sendable {
    var addedAt: [String: Date] = [:]
    var baselineRecorded = false

    mutating func stamp(_ id: Int64, at date: Date) {
        addedAt[String(id)] = date
    }

    mutating func observe(previous: [Int64], current: [Int64], now: Date) {
        let present = Set(current.map(String.init))
        if !baselineRecorded {
            baselineRecorded = true
        } else {
            let known = Set(previous.map(String.init))
            for id in current {
                let key = String(id)
                if !known.contains(key), addedAt[key] == nil { addedAt[key] = now }
            }
        }
        addedAt = addedAt.filter { present.contains($0.key) }
    }

    func date(_ id: Int64) -> Date? { addedAt[String(id)] }
}
