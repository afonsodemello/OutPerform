//
//  HealthMonitor.swift
//  OutPerform
//
//  Per-metric personal baselines, deviation alerts, and the multi-signal
//  illness/overtraining heuristic
//

import Foundation

public enum VitalMetric: String, Sendable, CaseIterable, Identifiable {
    case heartRate, hrv, respiratoryRate, spo2, skinTemp
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .heartRate: return "Resting HR"
        case .hrv: return "HRV"
        case .respiratoryRate: return "Respiratory rate"
        case .spo2: return "Blood oxygen"
        case .skinTemp: return "Skin temperature"
        }
    }
    /// For HRV a *drop* is the concerning direction; for the others a *rise* is.
    public var elevationIsConcerning: Bool { self != .hrv }
}

public struct Baseline: Sendable {
    public var mean: Double
    public var std: Double
    public var alertHigh: Double { mean + 2 * std }
    public var alertLow: Double { mean - 2 * std }
    public var redHigh: Double { mean + 3 * std }
    public var redLow: Double { mean - 3 * std }

    public init(values: [Double]) {
        self.mean = Stats.mean(values)
        self.std = Stats.stdDev(values)
    }
}

public enum AlertLevel: String, Sendable { case normal, yellow, red }

public struct VitalStatus: Sendable, Identifiable {
    public var metric: VitalMetric
    public var value: Double
    public var baseline: Baseline
    public var level: AlertLevel
    public var deviationStd: Double
    public var id: String { metric.rawValue }
}

public enum HealthMonitor {

    /// Classify today's value against a baseline band.
    public static func status(metric: VitalMetric, value: Double, baseline: Baseline) -> VitalStatus {
        let z = Stats.zScore(value, mean: baseline.mean, std: baseline.std)
        let abs = Swift.abs(z)
        let level: AlertLevel = abs >= 3 ? .red : (abs >= 2 ? .yellow : .normal)
        return VitalStatus(metric: metric, value: value, baseline: baseline,
                           level: level, deviationStd: z)
    }

    public struct IllnessAssessment: Sendable {
        public var signalCount: Int
        public var isFlagged: Bool { signalCount >= 3 }
        public var message: String?
    }

    /// Count metrics deviating > 1.5 std in their concerning direction.
    public static func illnessAssessment(_ statuses: [VitalStatus]) -> IllnessAssessment {
        var count = 0
        for s in statuses {
            let z = s.deviationStd
            let concerning = s.metric.elevationIsConcerning ? z : -z
            if concerning > 1.5 { count += 1 }
        }
        let message = count >= 3
            ? "Multiple vitals are outside your normal range. This can signal early illness, overtraining or high stress — consider a rest day."
            : nil
        return IllnessAssessment(signalCount: count, message: message)
    }
}
