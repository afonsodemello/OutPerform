//
//  HealthDataProvider.swift
//  OutPerform
//
//  The source-agnostic interface every data backend implements. Apple Health
//  (HealthKit) and Google Health (Google Health API) both conform, so the rest
//  of the app never needs to know where data came from.
//

import Foundation

public enum HealthDataError: LocalizedError {
    case notAuthorized
    case notAvailable
    case signInRequired
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Health access has not been granted."
        case .notAvailable:  return "This data source isn't available on this device."
        case .signInRequired: return "Please sign in to your Google account first."
        case .network(let m): return m
        }
    }
}

/// All quantity values are returned in these canonical units:
///   heart rate / resting HR / respiratory rate : beats or breaths per minute
///   HRV SDNN : milliseconds
///   SpO2 : percent (e.g. 96.0)
///   temperature : degrees Celsius
///   VO2 max : mL/(kg·min)
protocol HealthDataProvider: AnyObject {
    var sourceType: DataSourceType { get }

    /// Whether this provider can be used at all on this device/account.
    func isAvailable() -> Bool

    /// Prompt for whatever authorization the backend needs.
    func requestAuthorization() async throws

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample]
    /// Beat-to-beat RR intervals (ms), each stamped at the beat time. Only Apple
    /// Watch records these (via the heartbeat series); other sources return [].
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample]
    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample]
    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample]
    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample]
    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample]
    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample]
    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment]
    func workouts(from: Date, to: Date) async throws -> [WorkoutSession]
    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample]
}

extension HealthDataProvider {
    func isAvailable() -> Bool { true }
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] { [] }
}
