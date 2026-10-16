//
//  WorkoutRecorder.swift
//  OutPerform
//
//  Records a live workout from everything the phone and band can measure:
//
//   • Heart rate      — the Bluetooth band, once per second (zones, avg/max,
//                       calories via Keytel)
//   • Distance, speed, pace, route — GPS (outdoor activities), keeps running
//                       with the screen locked
//   • Steps, cadence, floors — the iPhone's motion coprocessor
//   • Elevation gain  — the barometer (falls back to GPS altitude)
//   • Splits          — time for each kilometre
//
//  Autosaves every 30 s, so a workout survives the app being closed; it's
//  recovered as a finished workout on the next launch.
//

import Foundation
import Observation
import CoreLocation
import CoreMotion

@Observable
final class WorkoutRecorder: NSObject {
    static let shared = WorkoutRecorder()

    enum State { case idle, running, paused }

    private(set) var state: State = .idle
    private(set) var activity: ExerciseActivity = .run
    private(set) var usesGPS = false
    private(set) var startDate: Date?

    // Live metrics
    private(set) var currentBPM: Int?
    private(set) var heartRate: [ExerciseSession.HRSample] = []
    private(set) var zoneSeconds: [Double] = Array(repeating: 0, count: 6)
    private(set) var kcal: Double = 0
    private(set) var distance: Double = 0          // m
    private(set) var currentSpeed: Double?          // m/s, smoothed
    private(set) var elevationGain: Double = 0      // m
    private(set) var steps: Int?
    private(set) var floors: Int?
    private(set) var cadence: Double?               // steps/min
    private(set) var route: [ExerciseSession.RoutePoint] = []
    private(set) var splits: [Double] = []
    private(set) var gpsAccuracy: Double?
    private(set) var locationDenied = false

    var isActive: Bool { state != .idle }

    // Timing
    private var activeAccum: TimeInterval = 0
    private var lastResume: Date?
    private var lastSplitAt: TimeInterval = 0

    // Inputs
    private let location = CLLocationManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private var lastLocation: CLLocation?
    private var altitudeAnchor: Double?
    private var lastHRAt: Date?
    private var restingHR: Double = 60
    private var lastAutosave = Date.distantPast

    private override init() {
        super.init()
        location.delegate = self
    }

    // MARK: Time

    func activeSeconds(at now: Date = Date()) -> TimeInterval {
        activeAccum + (state == .running ? lastResume.map { now.timeIntervalSince($0) } ?? 0 : 0)
    }

    // MARK: Control

    func start(activity: ExerciseActivity, useGPS: Bool, restingHR: Double?) {
        guard state == .idle else { return }
        reset()
        self.activity = activity
        self.usesGPS = useGPS
        self.restingHR = restingHR ?? 60
        let now = Date()
        startDate = now
        lastResume = now
        state = .running
        ZoneAlerter.shared.reset()

        if useGPS { startLocation() }
        if CMPedometer.isStepCountingAvailable(), activity.countsSteps || !useGPS {
            pedometer.startUpdates(from: now) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.handlePedometer(data) }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.handleAltitude(data.relativeAltitude.doubleValue) }
            }
        }
    }

    func pause() {
        guard state == .running, let r = lastResume else { return }
        activeAccum += Date().timeIntervalSince(r)
        lastResume = nil
        state = .paused
        lastLocation = nil      // don't draw a straight line across the pause
        autosave(force: true)
    }

    func resume() {
        guard state == .paused else { return }
        lastResume = Date()
        state = .running
    }

    /// Stop and save. Returns the saved workout (nil if it was under 30 s).
    @discardableResult
    func finish() -> ExerciseSession? {
        guard state != .idle else { return nil }
        if state == .running { pause() }
        stopSensors()
        let session = snapshot(end: Date())
        state = .idle
        ExerciseStore.shared.clearInProgress()
        ZoneAlerter.shared.reset()
        guard session.activeSeconds >= 30 else { return nil }
        ExerciseStore.shared.save(session)
        return session
    }

    func discard() {
        stopSensors()
        state = .idle
        ExerciseStore.shared.clearInProgress()
        ZoneAlerter.shared.reset()
        reset()
    }

    /// On launch: a workout left running when the app was closed becomes a
    /// saved, finished workout.
    func recoverIfNeeded() {
        guard state == .idle, var s = ExerciseStore.shared.loadInProgress() else { return }
        ExerciseStore.shared.clearInProgress()
        s.recovered = true
        if s.activeSeconds >= 30 { ExerciseStore.shared.save(s) }
    }

    // MARK: Heart rate (from BandManager, once per second)

    func observe(bpm: Int, at now: Date = Date()) {
        guard state != .idle else { return }
        currentBPM = bpm
        guard state == .running else { lastHRAt = now; return }
        let dt = min(5, lastHRAt.map { now.timeIntervalSince($0) } ?? 1)
        lastHRAt = now
        heartRate.append(.init(t: now, bpm: bpm))
        zoneSeconds[ZoneSettings.shared.zone(for: bpm)] += dt
        let s = AppSettings.shared
        let profile = BodyProfile(age: s.age, sex: s.biologicalSex, weightKg: s.weightKg, heightCm: s.heightCm)
        kcal += HRWorkoutDetector.kcalPerMinute(hr: Double(bpm), restingHR: restingHR,
                                                hrMax: Double(ZoneSettings.shared.maxHR), profile: profile) * dt / 60
        autosave()
    }

    // MARK: Sensors

    private func startLocation() {
        location.activityType = activity == .cycle ? .otherNavigation : .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 3
        location.pausesLocationUpdatesAutomatically = false
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()   // updates start in the delegate
        case .denied, .restricted:
            locationDenied = true
        default:
            beginLocationUpdates()
        }
    }

    private func beginLocationUpdates() {
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
    }

    private func stopSensors() {
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func handleLocation(_ loc: CLLocation) {
        gpsAccuracy = loc.horizontalAccuracy
        // Drop stale or inaccurate fixes (indoors, first cold fixes).
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 25,
              abs(loc.timestamp.timeIntervalSinceNow) < 10, state == .running else { return }
        if let last = lastLocation {
            let d = loc.distance(from: last)
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            guard dt > 0, d / dt < 40 else { return }   // reject GPS jumps (> 144 km/h)
            distance += d
            let instant = loc.speed >= 0 ? loc.speed : d / dt
            currentSpeed = currentSpeed.map { 0.7 * $0 + 0.3 * instant } ?? instant
            if !CMAltimeter.isRelativeAltitudeAvailable(), loc.verticalAccuracy >= 0, loc.verticalAccuracy < 15 {
                handleAltitude(loc.altitude, hysteresis: 3)
            }
            recordSplits()
        }
        lastLocation = loc
        route.append(.init(t: loc.timestamp, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                           altitude: loc.altitude, speed: loc.speed))
    }

    private func recordSplits() {
        let km = Int(distance / 1000)
        while splits.count < km {
            let now = activeSeconds()
            splits.append(now - lastSplitAt)
            lastSplitAt = now
        }
    }

    private func handlePedometer(_ data: CMPedometerData) {
        steps = data.numberOfSteps.intValue
        floors = data.floorsAscended?.intValue
        cadence = data.currentCadence.map { $0.doubleValue * 60 }
        // Indoors / no GPS: use the pedometer's distance for on-foot workouts.
        if !usesGPS, activity.countsSteps, let d = data.distance?.doubleValue {
            distance = d
            recordSplits()
        }
    }

    /// Climb only: count rises of at least `hysteresis` m, so sensor noise
    /// on flat ground doesn't add up.
    private func handleAltitude(_ altitude: Double, hysteresis: Double = 1) {
        guard state == .running else { altitudeAnchor = altitude; return }
        guard let anchor = altitudeAnchor else { altitudeAnchor = altitude; return }
        if altitude - anchor >= hysteresis {
            elevationGain += altitude - anchor
            altitudeAnchor = altitude
        } else if altitude < anchor {
            altitudeAnchor = altitude
        }
    }

    // MARK: Snapshot / autosave

    private func snapshot(end: Date) -> ExerciseSession {
        var s = ExerciseSession(activity: activity, start: startDate ?? end, end: end,
                                activeSeconds: activeSeconds(at: end))
        s.heartRate = heartRate
        s.route = route
        s.distanceMeters = distance > 0 ? distance : nil
        s.elevationGainMeters = elevationGain > 0 ? elevationGain : nil
        s.steps = steps
        s.floorsAscended = floors
        s.zoneSeconds = zoneSeconds
        s.splits = splits
        s.heartRateSource = heartRate.isEmpty ? nil : BandManager.shared.pairedName
        s.kcal = heartRate.isEmpty ? metKcal(seconds: s.activeSeconds) : kcal
        return s
    }

    /// Without heart rate: MET estimate (Compendium of Physical Activities).
    private func metKcal(seconds: Double) -> Double {
        let met: Double
        switch activity {
        case .run: met = 9.8
        case .walk: met = 3.5
        case .hike: met = 6.0
        case .cycle: met = 7.5
        case .strength: met = 5.0
        case .hiit: met = 8.0
        case .yoga: met = 2.5
        case .other: met = 5.0
        }
        return met * AppSettings.shared.weightKg * seconds / 3600
    }

    private func autosave(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAutosave) >= 30 else { return }
        lastAutosave = Date()
        ExerciseStore.shared.saveInProgress(snapshot(end: Date()))
    }

    private func reset() {
        currentBPM = nil; heartRate = []; zoneSeconds = Array(repeating: 0, count: 6); kcal = 0
        distance = 0; currentSpeed = nil; elevationGain = 0; steps = nil; floors = nil; cadence = nil
        route = []; splits = []; gpsAccuracy = nil; locationDenied = false
        activeAccum = 0; lastResume = nil; lastSplitAt = 0
        lastLocation = nil; altitudeAnchor = nil; lastHRAt = nil; startDate = nil
    }
}

extension WorkoutRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { for l in locations { self.handleLocation(l) } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationDenied = false
                if self.isActive && self.usesGPS { self.beginLocationUpdates() }
            case .denied, .restricted:
                self.locationDenied = true
            default: break
            }
        }
    }
}
