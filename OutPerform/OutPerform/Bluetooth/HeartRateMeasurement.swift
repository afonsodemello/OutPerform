//
//  HeartRateMeasurement.swift
//  OutPerform
//
//  Decoder for the Bluetooth SIG standard Heart Rate Measurement
//  characteristic (0x2A37, Heart Rate Service 0x180D). This is the open,
//  documented profile the Fitbit Air uses when "Share heart rate" is on, and
//  the same one chest straps, Polar/Garmin/Wahoo sensors and gym equipment use.
//
//  Layout (Bluetooth Heart Rate Service spec v1.0):
//    byte 0      flags
//                  bit 0   HR value format: 0 = UInt8, 1 = UInt16 (LE)
//                  bits 1-2 sensor contact status (bit 2 = feature supported,
//                           bit 1 = contact detected)
//                  bit 3   energy expended field present (UInt16 kJ)
//                  bit 4   one or more RR-interval fields present
//    then        HR value (UInt8 or UInt16)
//    then        energy expended (UInt16), if flagged
//    then        RR intervals, UInt16 each, in units of 1/1024 s, if flagged
//

import Foundation

nonisolated public struct HeartRateMeasurement: Sendable, Equatable {
    public enum SensorContact: Sendable, Equatable {
        case notSupported
        case notDetected
        case detected
    }

    public var bpm: Int
    public var contact: SensorContact
    public var energyExpendedKJ: Int?
    /// Beat-to-beat intervals in milliseconds, oldest first.
    public var rrIntervalsMs: [Double]

    public init(bpm: Int, contact: SensorContact, energyExpendedKJ: Int? = nil, rrIntervalsMs: [Double] = []) {
        self.bpm = bpm
        self.contact = contact
        self.energyExpendedKJ = energyExpendedKJ
        self.rrIntervalsMs = rrIntervalsMs
    }

    /// Parse a raw characteristic value. Returns nil for a truncated packet.
    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var i = 1

        func u16() -> Int? {
            guard i + 1 < bytes.count else { return nil }
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
            return v
        }

        let bpm: Int
        if flags & 0x01 != 0 {
            guard let v = u16() else { return nil }
            bpm = v
        } else {
            guard i < bytes.count else { return nil }
            bpm = Int(bytes[i])
            i += 1
        }

        let contact: SensorContact
        if flags & 0x04 == 0 {
            contact = .notSupported
        } else {
            contact = flags & 0x02 != 0 ? .detected : .notDetected
        }

        var energy: Int?
        if flags & 0x08 != 0 {
            guard let v = u16() else { return nil }
            energy = v
        }

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while let raw = u16() {
                rr.append(Double(raw) * 1000.0 / 1024.0)
            }
        }

        return HeartRateMeasurement(bpm: bpm, contact: contact, energyExpendedKJ: energy, rrIntervalsMs: rr)
    }

    /// True when the band says it is off the wrist. Bands that don't report
    /// contact are treated as worn.
    public var isOffWrist: Bool { contact == .notDetected }
}
