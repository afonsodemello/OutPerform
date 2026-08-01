//
//  DataExport.swift
//  OutPerform
//
//  Exports every stored daily record to a plain-text (.txt) file, and a small
//  UIKit share-sheet wrapper to send/save it.
//

import SwiftUI
import UIKit

enum DataExporter {

    /// Build a tab-separated .txt of all records (one row per day, newest first)
    /// with every field the app computes. Returns a temp-file URL.
    static func makeTextFile(from records: [DailyRecord]) throws -> URL {
        let columns: [(String, (DailyRecord) -> String)] = [
            ("date",              { Self.day($0.date) }),
            ("recovery",          { Self.n($0.recovery) }),
            ("readiness",         { Self.n($0.readiness) }),
            ("dayStrain",         { Self.n($0.dayStrain) }),
            ("activityStrain",    { Self.n($0.activityStrain) }),
            ("sleepPerformance",  { Self.n($0.sleepPerformance) }),
            ("stress",            { Self.n($0.stress) }),
            ("hrv_ms",            { Self.n($0.hrv) }),
            ("rmssd_ms",          { Self.n($0.rmssd) }),
            ("sdnn_ms",           { Self.n($0.sdnn) }),
            ("dfaAlpha1",         { Self.n($0.dfaAlpha1) }),
            ("restingHR_bpm",     { Self.n($0.restingHR) }),
            ("respiratoryRate",   { Self.n($0.respiratoryRate) }),
            ("spo2Avg_pct",       { Self.n($0.spo2Avg) }),
            ("spo2Min_pct",       { Self.n($0.spo2Min) }),
            ("skinTemp_C",        { Self.n($0.skinTempC) }),
            ("vo2Max",            { Self.n($0.vo2Max) }),
            ("acwr",              { Self.n($0.acwr) }),
            ("monotony",          { Self.n($0.monotony) }),
            ("sleepNeed_min",     { Self.n($0.sleepNeedMin) }),
            ("sleepDebt_min",     { Self.n($0.sleepDebtMin) }),
            ("totalSleep_min",    { Self.n($0.totalSleepMin) }),
            ("timeInBed_min",     { Self.n($0.timeInBedMin) }),
            ("rem_min",           { Self.n($0.remMin) }),
            ("deep_min",          { Self.n($0.deepMin) }),
            ("light_min",         { Self.n($0.coreMin) }),
            ("awake_min",         { Self.n($0.awakeMin) }),
            ("sleepEfficiency",   { Self.n($0.sleepEfficiency) }),
            ("restorative_pct",   { Self.n($0.restorativePct) }),
            ("wakeEvents",        { $0.wakeEvents.map(String.init) ?? "" }),
            ("apnea_ODI",         { Self.n($0.odi) }),
            ("dayTRIMP",          { Self.n($0.dayTRIMP) }),
            ("sleepOnset",        { Self.time($0.sleepOnset) }),
            ("sleepWake",         { Self.time($0.sleepWake) }),
            ("feeling_1to5",      { $0.feltGood.map(String.init) ?? "" })
        ]

        let sorted = records.sorted { $0.date > $1.date }
        var lines = ["OutPerform data export — \(Date().formatted(date: .abbreviated, time: .shortened))",
                     "rows: \(sorted.count)  (tab-separated; blank = no data)",
                     ""]
        lines.append(columns.map(\.0).joined(separator: "\t"))
        for r in sorted {
            lines.append(columns.map { $0.1(r) }.joined(separator: "\t"))
        }

        let text = lines.joined(separator: "\n")
        let stamp = Self.day(Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutPerform-export-\(stamp).txt")
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func n(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(format: "%.2f", v)
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static func day(_ d: Date) -> String { dayFmt.string(from: d) }
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static func time(_ d: Date?) -> String { d.map { timeFmt.string(from: $0) } ?? "" }
}

/// Identifiable wrapper so a generated file URL can drive `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal share-sheet wrapper.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
