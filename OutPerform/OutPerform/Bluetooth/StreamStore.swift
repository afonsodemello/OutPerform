//
//  StreamStore.swift
//  OutPerform
//
//  On-device storage for the raw Bluetooth streams: every heart-rate
//  notification and every beat-to-beat interval the band sends. Nothing here
//  leaves the phone.
//
//  Format: compact append-only binary files, one pair per UTC day, under
//  Application Support/Streams. A day of 1 Hz heart rate is ~430 KB and a
//  day of beats ~800 KB, so months of history stay small and a 30-day
//  re-score reads in well under a second.
//
//    hr-<utcDay>.bin   5 bytes/record: UInt32 epoch seconds, UInt8 bpm
//    rr-<utcDay>.bin   8 bytes/record: UInt32 epoch seconds, UInt16 ms within
//                      that second (beat time), UInt16 RR interval in ms
//

import Foundation

/// One heart-rate reading. `t` is seconds since 1970.
nonisolated public struct HRPoint: Sendable, Hashable {
    public var t: Double
    public var bpm: Double
    public init(t: Double, bpm: Double) { self.t = t; self.bpm = bpm }
}

/// One heartbeat: `t` is the beat time (seconds since 1970), `rr` the interval
/// ending at that beat in milliseconds.
nonisolated public struct RRBeat: Sendable, Hashable {
    public var t: Double
    public var rr: Double
    public init(t: Double, rr: Double) { self.t = t; self.rr = rr }
}

actor StreamStore {
    static let shared = StreamStore()

    private let directory: URL
    private var hrBuffer: [HRPoint] = []
    private var rrBuffer: [RRBeat] = []
    private static let flushThreshold = 120

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Streams", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Keep the raw streams out of iCloud/iTunes backups: they are large and
        // can be rebuilt only from the band, so a backup copy has no value.
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Writing

    func append(hr: HRPoint) {
        hrBuffer.append(hr)
        if hrBuffer.count >= Self.flushThreshold { flush() }
    }

    func append(beats: [RRBeat]) {
        rrBuffer.append(contentsOf: beats)
        if rrBuffer.count >= Self.flushThreshold * 2 { flush() }
    }

    /// Write buffered samples to disk. Called on a size threshold, when the app
    /// backgrounds, and before every read.
    func flush() {
        if !hrBuffer.isEmpty {
            let grouped = Dictionary(grouping: hrBuffer) { Self.utcDay($0.t) }
            for (day, points) in grouped {
                var data = Data(capacity: points.count * 5)
                for p in points {
                    Self.appendUInt32(&data, UInt32(clamping: Int(p.t)))
                    data.append(UInt8(clamping: Int(p.bpm.rounded())))
                }
                append(data, to: fileURL(kind: "hr", day: day))
            }
            hrBuffer.removeAll(keepingCapacity: true)
        }
        if !rrBuffer.isEmpty {
            let grouped = Dictionary(grouping: rrBuffer) { Self.utcDay($0.t) }
            for (day, beats) in grouped {
                var data = Data(capacity: beats.count * 8)
                for b in beats {
                    let whole = floor(b.t)
                    Self.appendUInt32(&data, UInt32(clamping: Int(whole)))
                    Self.appendUInt16(&data, UInt16(clamping: Int(((b.t - whole) * 1000).rounded())))
                    Self.appendUInt16(&data, UInt16(clamping: Int(b.rr.rounded())))
                }
                append(data, to: fileURL(kind: "rr", day: day))
            }
            rrBuffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Reading

    func heartRate(from: Date, to: Date) -> [HRPoint] {
        flush()
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        var out: [HRPoint] = []
        for day in Self.utcDay(lo)...Self.utcDay(hi) {
            guard let data = try? Data(contentsOf: fileURL(kind: "hr", day: day)) else { continue }
            data.withUnsafeBytes { raw in
                let n = raw.count / 5
                out.reserveCapacity(out.count + n)
                for k in 0..<n {
                    let o = k * 5
                    let t = Double(Self.readUInt32(raw, o))
                    guard t >= lo, t <= hi else { continue }
                    out.append(HRPoint(t: t, bpm: Double(raw[o + 4])))
                }
            }
        }
        out.sort { $0.t < $1.t }
        return out
    }

    func beats(from: Date, to: Date) -> [RRBeat] {
        flush()
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        var out: [RRBeat] = []
        for day in Self.utcDay(lo)...Self.utcDay(hi) {
            guard let data = try? Data(contentsOf: fileURL(kind: "rr", day: day)) else { continue }
            data.withUnsafeBytes { raw in
                let n = raw.count / 8
                out.reserveCapacity(out.count + n)
                for k in 0..<n {
                    let o = k * 8
                    let t = Double(Self.readUInt32(raw, o)) + Double(Self.readUInt16(raw, o + 4)) / 1000
                    guard t >= lo, t <= hi else { continue }
                    out.append(RRBeat(t: t, rr: Double(Self.readUInt16(raw, o + 6))))
                }
            }
        }
        out.sort { $0.t < $1.t }
        return out
    }

    struct Summary: Sendable {
        var days: Int
        var bytes: Int
        var oldest: Date?
    }

    func summary() -> Summary {
        flush()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var days = Set<Int>()
        var bytes = 0
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            if let day = Int(name.split(separator: "-").last ?? "") { days.insert(day) }
            bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let oldest = days.min().map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        return Summary(days: days.count, bytes: bytes, oldest: oldest)
    }

    /// Delete every stored stream (used by "Reset all data").
    func deleteAll() {
        hrBuffer.removeAll()
        rrBuffer.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Helpers

    private func fileURL(kind: String, day: Int) -> URL {
        directory.appendingPathComponent("\(kind)-\(day).bin")
    }

    private func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func utcDay(_ t: Double) -> Int { Int(floor(t / 86_400)) }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }

    private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8))
    }

    private static func readUInt32(_ raw: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(raw[o]) | (UInt32(raw[o + 1]) << 8) | (UInt32(raw[o + 2]) << 16) | (UInt32(raw[o + 3]) << 24)
    }

    private static func readUInt16(_ raw: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8)
    }
}
