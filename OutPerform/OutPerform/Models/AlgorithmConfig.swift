//
//  AlgorithmConfig.swift
//  OutPerform
//
//  User-tunable formula parameters (Settings → Advanced). Everything has a
//  a sensible default; power users can re-weight recovery,
//  change the strain curve, pick a max-HR method, etc. and recompute.
//

import Foundation
import Observation

@Observable
final class AlgorithmConfig {
    static let shared = AlgorithmConfig()
    private let defaults = UserDefaults.standard
    private let key = "algorithmConfig.v1"

    // MARK: Recovery weights
    var wHRV = 0.40
    var wRHR = 0.25
    var wResp = 0.10
    var wSleep = 0.25
    var includeTempPenalty = true
    var includeSpo2Penalty = true

    // MARK: Sleep performance weights
    var spEfficiency = 0.30
    var spRestorative = 0.30
    var spFulfillment = 0.25
    var spConsistency = 0.15

    // MARK: Strain
    enum HRMaxMethod: String, CaseIterable, Codable {
        case gellish, learned, max
        var displayName: String {
            switch self {
            case .gellish: return "Gellish formula"
            case .learned: return "Learned (95th pct HR)"
            case .max: return "Higher of the two"
            }
        }
    }
    var hrMaxMethod: HRMaxMethod = .max
    var strainScale = 150.0          // TRIMP scaling constant
    var strainCoefficient = 4.8      // log curve coefficient

    // MARK: Sleep need
    var defaultSleepNeedMin = 480.0

    // MARK: Mappings derived for the calculators

    var recoveryWeights: RecoveryCalculator.Weights {
        .init(hrv: wHRV, rhr: wRHR, resp: wResp, sleep: wSleep,
              includeTemp: includeTempPenalty, includeSpo2: includeSpo2Penalty)
    }
    var sleepWeights: SleepCalculator.Weights {
        .init(efficiency: spEfficiency, restorative: spRestorative,
              fulfillment: spFulfillment, consistency: spConsistency)
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var wHRV, wRHR, wResp, wSleep: Double
        var includeTempPenalty, includeSpo2Penalty: Bool
        var spEfficiency, spRestorative, spFulfillment, spConsistency: Double
        var hrMaxMethod: HRMaxMethod
        var strainScale, strainCoefficient, defaultSleepNeedMin: Double
    }

    init() { load() }

    func save() {
        let snap = Snapshot(wHRV: wHRV, wRHR: wRHR, wResp: wResp, wSleep: wSleep,
                            includeTempPenalty: includeTempPenalty, includeSpo2Penalty: includeSpo2Penalty,
                            spEfficiency: spEfficiency, spRestorative: spRestorative,
                            spFulfillment: spFulfillment, spConsistency: spConsistency,
                            hrMaxMethod: hrMaxMethod, strainScale: strainScale,
                            strainCoefficient: strainCoefficient, defaultSleepNeedMin: defaultSleepNeedMin)
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: key) }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        wHRV = s.wHRV; wRHR = s.wRHR; wResp = s.wResp; wSleep = s.wSleep
        includeTempPenalty = s.includeTempPenalty; includeSpo2Penalty = s.includeSpo2Penalty
        spEfficiency = s.spEfficiency; spRestorative = s.spRestorative
        spFulfillment = s.spFulfillment; spConsistency = s.spConsistency
        hrMaxMethod = s.hrMaxMethod; strainScale = s.strainScale
        strainCoefficient = s.strainCoefficient; defaultSleepNeedMin = s.defaultSleepNeedMin
    }

    func resetToDefaults() {
        wHRV = 0.40; wRHR = 0.25; wResp = 0.10; wSleep = 0.25
        includeTempPenalty = true; includeSpo2Penalty = true
        spEfficiency = 0.30; spRestorative = 0.30; spFulfillment = 0.25; spConsistency = 0.15
        hrMaxMethod = .max; strainScale = 150; strainCoefficient = 4.8; defaultSleepNeedMin = 480
        save()
    }
}
