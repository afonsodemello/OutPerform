//
//  ExerciseSession.swift
//  OutPerform
//
//  A workout you recorded in the Exercise tab, and the on-device store that
//  keeps them (one JSON file per workout in Application Support/Exercise).
//

import Foundation
import Observation
import CoreLocation

enum ExerciseActivity: String, Codable, CaseIterable, Identifiable {
    case run, walk, hike, cycle, strength, hiit, yoga, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run:      return "Run"
        case .walk:     return "Walk"
        case .hike:     return "Hike"
        case .cycle:    return "Cycle"
        case .strength: return "Strength"
        case .hiit:     return "HIIT"
        case .yoga:     return "Yoga"
        case .other:    return "Workout"
        }
    }

    var systemImage: String {
        switch self {
        case .run:      return "figure.run"
        case .walk:     return "figure.walk"
        case .hike:     return "figure.hiking"
        case .cycle:    return "figure.outdoor.cycle"
        case .strength: return "figure.strengthtraining.traditional"
        case .hiit:     return "figure.highintensity.intervaltraining"
        case .yoga:     return "figure.yoga"
        case .other:    return "figure.mixed.cardio"
        }
    }

    /// Outdoor activities where GPS distance, speed and a route make sense.
    var usesGPSByDefault: Bool { [.run, .walk, .hike, .cycle].contains(self) }
    /// On-foot activities where steps and cadence make sense.
    var countsSteps: Bool { [.run, .walk, .hike].contains(self) }
    /// Show pace (min/km) rather than speed (km/h).
    var prefersPace: Bool { [.run, .walk, .hike].contains(self) }

    /// The app's strain model category.
    var workoutActivity: WorkoutActivity {
        switch self {
        case .run, .hike: return .running
        case .walk:       return .walking
        case .cycle:      return .cycling
        case .strength:   return .weightlifting
        case .hiit:       return .hiit
        case .yoga:       return .yoga
        case .other:      return .other
        }
    }
}

struct ExerciseSession: Codable, Identifiable, Hashable {
    struct HRSample: Codable, Hashable { var t: Date; var bpm: Int }
    struct RoutePoint: Codable, Hashable {
        var t: Date
        var lat: Double
        var lon: Double
        var altitude: Double
        var speed: Double   // m/s, < 0 when unknown
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }

    var id = UUID()
    var activity: ExerciseActivity
    var start: Date
    var end: Date
    /// Moving time, excluding pauses (s).
    var activeSeconds: Double
    var heartRate: [HRSample] = []
    var route: [RoutePoint] = []
    var distanceMeters: Double?
    var elevationGainMeters: Double?
    var steps: Int?
    var floorsAscended: Int?
    var kcal: Double?
    /// Seconds spent in zones 0 (below zone 1) … 5.
    var zoneSeconds: [Double] = Array(repeating: 0, count: 6)
    /// Time (s) of each completed kilometre.
    var splits: [Double] = []
    /// What the HR came from, e.g. "Fitbit Air".
    var heartRateSource: String?
    /// Recovered after the app was closed mid-workout.
    var recovered = false

    var avgHR: Int? { heartRate.isEmpty ? nil : heartRate.map(\.bpm).reduce(0, +) / heartRate.count }
    var maxHR: Int? { heartRate.map(\.bpm).max() }

    var avgSpeed: Double? {
        guard let d = distanceMeters, d > 0, activeSeconds > 0 else { return nil }
        return d / activeSeconds
    }

    /// As the strain engine sees it: minute-mean heart rate.
    var asWorkoutSession: WorkoutSession {
        let byMinute = Dictionary(grouping: heartRate) { Int($0.t.timeIntervalSince1970 / 60) }
        let hr = byMinute.keys.sorted().map { m -> QuantitySample in
            let vals = byMinute[m]!.map { Double($0.bpm) }
            let s = Date(timeIntervalSince1970: Double(m) * 60)
            return QuantitySample(start: s, end: s.addingTimeInterval(60), value: vals.reduce(0, +) / Double(vals.count))
        }
        return WorkoutSession(start: start, end: end, activity: activity.workoutActivity,
                              heartRates: hr, activeEnergyKcal: kcal)
    }
}

/// On-device store of recorded workouts.
@Observable
final class ExerciseStore {
    static let shared = ExerciseStore()

    private(set) var sessions: [ExerciseSession] = []
    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exercise", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.inProgressName }
            .compactMap { try? decoder.decode(ExerciseSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    func save(_ s: ExerciseSession) {
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: directory.appendingPathComponent("\(s.id.uuidString).json"), options: .atomic)
        sessions.removeAll { $0.id == s.id }
        sessions.insert(s, at: 0)
        sessions.sort { $0.start > $1.start }
    }

    func delete(_ s: ExerciseSession) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(s.id.uuidString).json"))
        sessions.removeAll { $0.id == s.id }
    }

    /// Workouts overlapping a time range (for the strain engine).
    func sessions(from: Date, to: Date) -> [ExerciseSession] {
        sessions.filter { $0.end >= from && $0.start <= to }
    }

    // MARK: In-progress autosave (survives the app being closed)

    static let inProgressName = "in-progress.json"

    func saveInProgress(_ s: ExerciseSession) {
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.inProgressName), options: .atomic)
    }

    func clearInProgress() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.inProgressName))
    }

    func loadInProgress() -> ExerciseSession? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.inProgressName)) else { return nil }
        return try? decoder.decode(ExerciseSession.self, from: data)
    }
}
