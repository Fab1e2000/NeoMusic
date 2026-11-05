// Adapted from NeoDizzy (GPL-3.0); see Resources/DownloadSourceNotices.txt.
import CommonCrypto
import Foundation

/// NCM container layout and cipher reference:
/// https://github.com/taurusxin/ncmdump/blob/4ede4cee1bad35bbf28a7b5524feeca0422a4feb/src/ncmcrypt.cpp
/// Independently implemented with bounded reads and CommonCrypto. Tags come from the download metadata.
nonisolated enum NeteaseDownloadedAudio {
    enum Failure: LocalizedError {
        case damagedContainer, unsupportedAudio
        var errorDescription: String? {
            switch self {
            case .damagedContainer: "NCM 文件损坏或加密格式不受支持，请重新下载"
            case .unsupportedAudio: "音频文件损坏或格式不受支持"
            }
        }
    }

    /// Returns a staged audio payload. Finalization validates playability before publication.
    /// The downloaded source is never modified.
    @concurrent static func prepare(_ source: URL, declaredType: String, staging: URL) async throws -> URL {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try input.read(upToCount: 8) ?? Data()
        if header != Data("CTENFDAM".utf8) {
            guard let format = audioFormat(header) else {
                throw declaredType.lowercased() == "ncm" ? Failure.damagedContainer : Failure.unsupportedAudio
            }
            let result = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(format)
            do {
                try FileManager.default.copyItem(at: source, to: result)
                try Task.checkCancellation()
                return result
            } catch {
                try? FileManager.default.removeItem(at: result)
                throw error
            }
        }
        return try decrypt(input, staging: staging)
    }

    private static func audioFormat(_ bytes: Data) -> String? {
        if bytes.starts(with: Data("fLaC".utf8)) { return "flac" }
        if bytes.starts(with: Data("ID3".utf8)) ||
            (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) { return "mp3" }
        return nil
    }

    private static func decrypt(_ input: FileHandle, staging: URL) throws -> URL {
        let size = try input.seekToEnd()
        try input.seek(toOffset: 10) // signature + reserved bytes
        func read(_ count: Int) throws -> Data {
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw Failure.damagedContainer }
            return data
        }
        func uint32() throws -> Int {
            let bytes = try read(4)
            return bytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        func skip(_ count: Int) throws {
            let offset = try input.offset()
            guard offset <= size, UInt64(count) <= size - offset else { throw Failure.damagedContainer }
            try input.seek(toOffset: offset + UInt64(count))
        }
        let keyLength = try uint32()
        guard keyLength > 0, keyLength <= 4096, keyLength % 16 == 0 else { throw Failure.damagedContainer }
        let encrypted = try read(keyLength).map { $0 ^ 0x64 }
        let coreKey = Array("hzHRAmso5kInbaxW".utf8)
        var plain = [UInt8](repeating: 0, count: keyLength + kCCBlockSizeAES128)
        var written = 0
        let capacity = plain.count
        let status = coreKey.withUnsafeBytes { key in
            encrypted.withUnsafeBytes { bytes in
                plain.withUnsafeMutableBytes { output in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, nil, bytes.baseAddress, bytes.count,
                            output.baseAddress, capacity, &written)
                }
            }
        }
        let prefix = Array("neteasecloudmusic".utf8)
        guard status == kCCSuccess, written > prefix.count,
              Array(plain.prefix(prefix.count)) == prefix else { throw Failure.damagedContainer }
        let key = Array(plain[prefix.count..<written])
        var box = Array(UInt8.min...UInt8.max)
        var previous = 0
        for index in 0..<256 {
            let next = (Int(box[index]) + previous + Int(key[index % key.count])) & 255
            box.swapAt(index, next)
            previous = next
        }
        let mask: [UInt8] = (0..<256).map { offset in
            let j = (offset + 1) & 255
            return box[(Int(box[j]) + Int(box[(Int(box[j]) + j) & 255])) & 255]
        }
        // Metadata and cover are not needed: the provider writes authoritative API tags afterwards.
        try skip(uint32())
        try skip(5) // CRC32 + image version
        let coverCapacity = try uint32()
        let coverLength = try uint32()
        guard coverLength <= coverCapacity else { throw Failure.damagedContainer }
        try skip(coverCapacity)

        let temporary = staging.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw Failure.damagedContainer }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var offset = 0
        var format: String?
        while true {
            try Task.checkCancellation()
            var bytes = try input.read(upToCount: 64 * 1024) ?? Data()
            if bytes.isEmpty { break }
            for index in bytes.indices { bytes[index] ^= mask[(offset + index) & 255] }
            if format == nil {
                format = audioFormat(bytes)
                guard format != nil else { throw Failure.unsupportedAudio }
            }
            try output.write(contentsOf: bytes)
            offset = (offset + bytes.count) & 255
        }
        guard let format else { throw Failure.damagedContainer }
        try Task.checkCancellation()
        try output.close()
        let result = temporary.deletingPathExtension().appendingPathExtension(format)
        try FileManager.default.moveItem(at: temporary, to: result)
        return result
    }
}
