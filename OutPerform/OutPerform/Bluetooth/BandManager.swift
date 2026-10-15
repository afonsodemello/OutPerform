//
//  BandManager.swift
//  OutPerform
//
//  Talks directly to your band over Bluetooth Low Energy. No account, no
//  cloud: the phone subscribes to the band's standard Heart Rate Service and
//  writes every reading and every heartbeat interval to `StreamStore`.
//
//  Works with any band that broadcasts the standard Heart Rate profile
//  (0x180D). For a Fitbit Air, turn on Google Health app → device → "Share
//  heart rate" (and "Always visible" so it keeps advertising in the
//  background).
//
//  Lifecycle:
//   • Pair once from the Band screen. The peripheral UUID is remembered.
//   • After that the app keeps a pending connection open forever. iOS
//     reconnects as soon as the band is in range, including while the app
//     is suspended (`bluetooth-central` background mode). If iOS terminates
//     the app, state restoration relaunches it when the band reappears.
//   • Every 15 minutes of live data, `onScoringTick` fires so the app can
//     re-score the day from the stored streams (the same cadence NOOP uses).
//

import Foundation
import CoreBluetooth
import Observation
import UIKit

nonisolated enum BandUUID {
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    static let bodySensorLocation = CBUUID(string: "2A38")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let deviceInfoService = CBUUID(string: "180A")
    static let manufacturerName = CBUUID(string: "2A29")
    static let modelNumber = CBUUID(string: "2A24")
    static let firmwareRevision = CBUUID(string: "2A26")
}

struct DiscoveredBand: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
}

@Observable
final class BandManager: NSObject {
    static let shared = BandManager()

    enum ConnectionState: Equatable {
        case bluetoothOff
        case unauthorized
        case unsupported
        case idle
        case scanning
        case connecting
        case connected
        case reconnecting

        var label: String {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission needed"
            case .unsupported:  return "Bluetooth LE not supported"
            case .idle:         return "Not connected"
            case .scanning:     return "Searching…"
            case .connecting:   return "Connecting…"
            case .connected:    return "Connected"
            case .reconnecting: return "Waiting for band"
            }
        }
    }

    // MARK: Observable state

    private(set) var state: ConnectionState = .idle
    private(set) var discovered: [DiscoveredBand] = []

    private(set) var pairedID: UUID?
    private(set) var pairedName: String?
    private(set) var manufacturer: String?
    private(set) var model: String?
    private(set) var firmware: String?
    private(set) var batteryLevel: Int?

    /// Smoothed live heart rate: median of the last ~10 s (NOOP's display rule,
    /// so a single odd beat never flickers the number).
    private(set) var liveBPM: Int?
    private(set) var lastRRms: Double?
    /// True once the band has sent beat-to-beat intervals this session.
    /// Without RR, HRV and sleep staging fall back to heart-rate-only methods.
    private(set) var providesRR = false
    private(set) var isOffWrist = false
    private(set) var lastSampleAt: Date?
    private(set) var samplesThisSession = 0
    private(set) var beatsThisSession = 0
    /// Current HR zone (1–5 by %HRmax), for the live card and zone coaching.
    private(set) var liveZone: Int?

    /// Haptic zone coaching: buzz on entering zone 5, once on dropping to zone 1.
    var zoneCoaching: Bool {
        didSet { defaults.set(zoneCoaching, forKey: Keys.zoneCoaching) }
    }

    /// Called every `scoringInterval` while live data is flowing.
    var onScoringTick: (() -> Void)?
    static let scoringInterval: TimeInterval = 15 * 60

    // MARK: Private

    private enum Keys {
        static let pairedID = "band.pairedID"
        static let pairedName = "band.pairedName"
        static let zoneCoaching = "band.zoneCoaching"
        static let restoreID = "mamilles.OutPerform.band"
    }

    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var userRequestedDisconnect = false
    private var hrWindow: [(t: Date, v: Double)] = []
    private var lastBeatT: Double?
    private var lastScoringTick = Date()
    private var lastStoredSecond: Int?

    private override init() {
        zoneCoaching = UserDefaults.standard.bool(forKey: Keys.zoneCoaching)
        super.init()
        if let s = defaults.string(forKey: Keys.pairedID) { pairedID = UUID(uuidString: s) }
        pairedName = defaults.string(forKey: Keys.pairedName)
    }

    /// Create the central manager. Deferred until the user picks the Bluetooth
    /// source (or one is already paired) so other users never see the
    /// Bluetooth permission prompt.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Keys.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    var isStarted: Bool { central != nil }
    var isPaired: Bool { pairedID != nil }

    // MARK: Public actions

    func startScan() {
        start()
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: [BandUUID.heartRateService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        // Bands already connected to iOS (e.g. by another app) don't advertise.
        for p in central.retrieveConnectedPeripherals(withServices: [BandUUID.heartRateService]) {
            upsertDiscovered(p, rssi: -50)
        }
        if state != .connected { state = .scanning }
    }

    func stopScan() {
        guard let central, central.isScanning else { return }
        central.stopScan()
        if state == .scanning { state = isPaired ? .reconnecting : .idle }
    }

    func pair(with id: UUID) {
        stopScan()
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        pairedID = id
        pairedName = p.name ?? discovered.first { $0.id == id }?.name ?? "Heart-rate band"
        defaults.set(id.uuidString, forKey: Keys.pairedID)
        defaults.set(pairedName, forKey: Keys.pairedName)
        connect(p)
    }

    /// Forget the band: drop the connection and stop auto-reconnecting.
    /// Stored data is kept.
    func forget() {
        userRequestedDisconnect = true
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        pairedID = nil
        pairedName = nil
        manufacturer = nil; model = nil; firmware = nil; batteryLevel = nil
        liveBPM = nil; liveZone = nil; lastRRms = nil; providesRR = false
        defaults.removeObject(forKey: Keys.pairedID)
        defaults.removeObject(forKey: Keys.pairedName)
        state = central?.state == .poweredOn ? .idle : state
    }

    /// Flush buffered samples to disk (call when the app backgrounds).
    func flush() {
        Task { await StreamStore.shared.flush() }
    }

    // MARK: Connection

    private func connect(_ p: CBPeripheral) {
        userRequestedDisconnect = false
        peripheral = p
        p.delegate = self
        state = .connecting
        // No timeout on iOS: the request stays pending until the band is in range.
        central.connect(p, options: nil)
    }

    private func reconnectToPaired() {
        guard let central, central.state == .poweredOn, let id = pairedID else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        let known = central.retrievePeripherals(withIdentifiers: [id]).first
            ?? central.retrieveConnectedPeripherals(withServices: [BandUUID.heartRateService])
                .first { $0.identifier == id }
        guard let p = known else { return }
        connect(p)
        state = .reconnecting
    }

    private func upsertDiscovered(_ p: CBPeripheral, rssi: Int, advertisedName: String? = nil) {
        let name = advertisedName ?? p.name ?? "Heart-rate band"
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            discovered[i].rssi = rssi
            discovered[i].lastSeen = Date()
            if discovered[i].name == "Heart-rate band" { discovered[i].name = name }
        } else {
            discovered.append(DiscoveredBand(id: p.identifier, name: name, rssi: rssi, lastSeen: Date()))
        }
        discovered.sort { $0.rssi > $1.rssi }
    }

    // MARK: Ingest

    private func ingest(_ m: HeartRateMeasurement) {
        let now = Date()
        isOffWrist = m.isOffWrist
        guard !m.isOffWrist, (25...230).contains(m.bpm) else { return }

        // Store at most one HR point per second; many bands notify faster.
        let second = Int(now.timeIntervalSince1970)
        if second != lastStoredSecond {
            lastStoredSecond = second
            let point = HRPoint(t: now.timeIntervalSince1970, bpm: Double(m.bpm))
            Task { await StreamStore.shared.append(hr: point) }
            samplesThisSession += 1
        }

        if !m.rrIntervalsMs.isEmpty {
            providesRR = true
            lastRRms = m.rrIntervalsMs.last
            let beats = timestampBeats(m.rrIntervalsMs, receivedAt: now.timeIntervalSince1970)
            beatsThisSession += beats.count
            Task { await StreamStore.shared.append(beats: beats) }
        }

        // ~10 s median smoothing, max 40 values.
        hrWindow.append((now, Double(m.bpm)))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let sorted = hrWindow.map(\.v).sorted()
        liveBPM = Int(sorted[sorted.count / 2].rounded())
        lastSampleAt = now

        updateZone()

        if now.timeIntervalSince(lastScoringTick) >= Self.scoringInterval {
            lastScoringTick = now
            flush()
            onScoringTick?()
        }
    }

    /// RR intervals arrive in batches with no timestamps. Lay them on a
    /// continuous beat clock (each beat = previous beat + its interval), and
    /// re-anchor to the receive time when the clock drifts or after a gap.
    private func timestampBeats(_ rr: [Double], receivedAt now: Double) -> [RRBeat] {
        let total = rr.reduce(0, +) / 1000
        var t: Double
        if let last = lastBeatT, abs((last + total) - now) < 2.0 {
            t = last
        } else {
            t = now - total
        }
        var out: [RRBeat] = []
        out.reserveCapacity(rr.count)
        for interval in rr {
            t += interval / 1000
            out.append(RRBeat(t: t, rr: interval))
        }
        lastBeatT = t
        return out
    }

    private func updateZone() {
        guard let bpm = liveBPM else { liveZone = nil; return }
        let hrMax = 208 - 0.7 * Double(AppSettings.shared.age)   // Tanaka (2001)
        let pct = Double(bpm) / hrMax
        let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
        let previous = liveZone
        liveZone = zone
        guard zoneCoaching, let previous, previous != zone,
              UIApplication.shared.applicationState == .active else { return }
        let haptics = UINotificationFeedbackGenerator()
        if zone == 5 && previous < 5 {
            haptics.notificationOccurred(.warning)   // "ease off"
        } else if zone == 1 && previous > 1 {
            haptics.notificationOccurred(.success)   // "recovered"
        }
    }

    private func handleStateChange() {
        switch central.state {
        case .poweredOn:
            if isPaired {
                state = .reconnecting
                reconnectToPaired()
            } else {
                state = .idle
            }
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .idle
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.handleStateChange() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            if let p = restored.first(where: { $0.identifier == self.pairedID }) ?? restored.first {
                self.peripheral = p
                p.delegate = self
                if p.state == .connected {
                    self.state = .connected
                    p.discoverServices([BandUUID.heartRateService, BandUUID.batteryService, BandUUID.deviceInfoService])
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            guard rssi < 0 else { return }   // 127 = unavailable
            self.upsertDiscovered(peripheral, rssi: rssi, advertisedName: name)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.state = .connected
            self.samplesThisSession = 0
            self.beatsThisSession = 0
            self.lastBeatT = nil
            if self.pairedName == nil || self.pairedName == "Heart-rate band", let n = peripheral.name {
                self.pairedName = n
                self.defaults.set(n, forKey: Keys.pairedName)
            }
            peripheral.discoverServices([BandUUID.heartRateService, BandUUID.batteryService, BandUUID.deviceInfoService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.state = .reconnecting
            self.reconnectToPaired()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.liveBPM = nil
            self.liveZone = nil
            self.hrWindow.removeAll()
            self.flush()
            if self.userRequestedDisconnect || !self.isPaired {
                self.state = .idle
            } else {
                self.state = .reconnecting
                // Queue a pending reconnect immediately; iOS completes it when
                // the band comes back in range.
                self.connect(peripheral)
                self.state = .reconnecting
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                switch service.uuid {
                case BandUUID.heartRateService:
                    peripheral.discoverCharacteristics([BandUUID.heartRateMeasurement], for: service)
                case BandUUID.batteryService:
                    peripheral.discoverCharacteristics([BandUUID.batteryLevel], for: service)
                case BandUUID.deviceInfoService:
                    peripheral.discoverCharacteristics(
                        [BandUUID.manufacturerName, BandUUID.modelNumber, BandUUID.firmwareRevision], for: service)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case BandUUID.heartRateMeasurement:
                    peripheral.setNotifyValue(true, for: c)
                case BandUUID.batteryLevel:
                    peripheral.readValue(for: c)
                    if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
                case BandUUID.manufacturerName, BandUUID.modelNumber, BandUUID.firmwareRevision:
                    peripheral.readValue(for: c)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            switch uuid {
            case BandUUID.heartRateMeasurement:
                if let m = HeartRateMeasurement.parse(data) { self.ingest(m) }
            case BandUUID.batteryLevel:
                if let b = data.first { self.batteryLevel = Int(b) }
            case BandUUID.manufacturerName:
                self.manufacturer = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case BandUUID.modelNumber:
                self.model = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            case BandUUID.firmwareRevision:
                self.firmware = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            default: break
            }
        }
    }
}
