//
//  FocusTest.swift
//  OutPerform
//
//  One stored reaction-time (PVT-style) test. Measured alertness from these is
//  the ground truth that calibrates the cognitive-readiness prediction, and the
//  history lets us show measured-vs-predicted over time.
//

import Foundation
import SwiftData

@Model
final class FocusTest {
    var date: Date = Date()
    /// Mean reaction time in milliseconds across valid taps.
    var meanReactionMs: Double = 0
    /// Best (fastest) reaction time, ms.
    var bestReactionMs: Double = 0
    /// Number of lapses (reactions slower than 500 ms).
    var lapses: Int = 0
    /// Number of false starts (tapped before the stimulus).
    var falseStarts: Int = 0
    /// Measured alertness 0–100 derived from the test.
    var measuredAlertness: Double = 0
    /// The model's predicted readiness at the moment the test was taken.
    var predictedAtTest: Double = 0

    init(date: Date, meanReactionMs: Double, bestReactionMs: Double, lapses: Int,
         falseStarts: Int, measuredAlertness: Double, predictedAtTest: Double) {
        self.date = date
        self.meanReactionMs = meanReactionMs
        self.bestReactionMs = bestReactionMs
        self.lapses = lapses
        self.falseStarts = falseStarts
        self.measuredAlertness = measuredAlertness
        self.predictedAtTest = predictedAtTest
    }
}
