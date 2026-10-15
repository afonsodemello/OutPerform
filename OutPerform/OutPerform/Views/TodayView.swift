//
//  TodayView.swift
//  OutPerform
//
//  Home screen: the unified Readiness score plus recovery,
//  strain and sleep summaries, the day's recommendation and a check-in.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    @State private var showSettings = false

    private var latest: DailyRecord? { records.first { $0.recovery != nil } ?? records.first }
    /// Most recent record with any usable data (so we can show strain/sleep even
    /// while recovery is still calibrating).
    private var anyLatest: DailyRecord? {
        records.first { $0.recovery != nil || $0.hrv != nil || $0.dayStrain != nil || $0.sleepPerformance != nil }
            ?? records.first
    }
    /// Most recent day that has a full Readiness score. Recovery/Readiness reflect
    /// your last completed night, so this can legitimately be yesterday in the
    /// early morning before the source has published last night's HRV.
    private var scoredRecord: DailyRecord? { records.first { $0.readiness != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if appModel.engine.isRefreshing || appModel.engine.isFetchingRaw {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appModel.engine.isRefreshing
                                     ? "Computing your scores…"
                                     : "Fetching data from \(settings.dataSource.displayName)…")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("The app may briefly freeze — give it a moment.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if settings.dataSource == .bluetooth { LiveBandCard() }
                    if let illness = appModel.illnessSignal() {
                        banner("Early-warning", illness.message, .opRed)
                    }
                    calibrationBanner
                    if let today = anyLatest {
                        // Recovery/Readiness come from your last full night. If
                        // today's aren't computed yet (the source hasn't published
                        // last night's HRV), fall back to the most recent scored
                        // day instead of flashing "Calibrating".
                        let scored = scoredRecord
                        if let s = scored {
                            readinessHeader(s)
                        } else {
                            calibratingHeader
                        }
                        summaryRings(today: today, recoveryFrom: scored)
                        if let s = scored { recommendation(s) }
                        checkIn(today)
                    } else {
                        EmptyStateView(
                            title: "No scores yet",
                            message: appModel.engine.isRefreshing
                                ? "Crunching your data…"
                                : "Pull to refresh to sync \(settings.dataSource.displayName) and compute your scores.",
                            systemImage: "waveform.path.ecg")
                            .frame(minHeight: 360)
                    }
                    if let err = appModel.engine.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    syncStatus
                }
                .padding()
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await appModel.fetchNewData() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    /// Last-synced status at the bottom of Today. Tap to sync now.
    @ViewBuilder private var syncStatus: some View {
        HStack(spacing: 6) {
            if appModel.engine.isRefreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Syncing \(settings.dataSource.displayName)…")
            } else if let last = appModel.engine.lastRefresh {
                Image(systemName: "checkmark.circle")
                Text("Last synced \(last, style: .relative) · tap to refresh")
            } else {
                Image(systemName: "arrow.down.circle")
                Text("Pull down to sync")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture { Task { await appModel.fetchNewData() } }
    }

    // MARK: Sections

    /// Days of usable data — counts historical nights too, so a user with months
    /// of history is fully calibrated immediately. Mirrors the engine gate, which
    /// needs BOTH HRV and resting HR, so the "n/14" matches what actually unlocks.
    private var usableDays: Int { records.filter { $0.hrv != nil && $0.restingHR != nil }.count }

    @ViewBuilder private var calibrationBanner: some View {
        if AlgorithmConfig.shared.scoringModel == .openScience {
            // Open-science Charge unlocks after 4 nights and is "Building" to 14.
            let nights = records.filter { $0.hrv != nil }.count
            switch nights {
            case ..<BaselineState.minNightsSeed:
                banner("Calibrating — \(nights) of \(BaselineState.minNightsSeed) nights",
                       "Wear your band to sleep. Charge appears once your HRV baseline has \(BaselineState.minNightsSeed) nights.", .opYellow)
            case ..<BaselineState.minNightsTrust:
                banner("Building baselines", "Scores are live but still learning you (\(nights)/\(BaselineState.minNightsTrust) nights).", .opYellow)
            default:
                EmptyView()
            }
        } else {
            classicCalibrationBanner
        }
    }

    @ViewBuilder private var classicCalibrationBanner: some View {
        switch usableDays {
        case ..<7:
            banner("Calibrating — \(usableDays) of 14 days", "Baselines need ~14 nights of data. Scores are provisional until then.", .opYellow)
        case ..<14:
            banner("Provisional scores", "Baselines are still forming (\(usableDays)/14 nights). Accuracy improves as more data syncs.", .opYellow)
        default:
            EmptyView()
        }
    }

    private func banner(_ title: String, _ msg: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func readinessHeader(_ r: DailyRecord) -> some View {
        VStack(spacing: 8) {
            ScoreRing(progress: (r.readiness ?? 0) / 100,
                      color: readinessColor(r.readiness ?? 0),
                      lineWidth: 16, size: 200,
                      title: "Readiness", value: Fmt.score(r.readiness),
                      caption: readinessCaption(r.readiness))
            Text(r.date.formatted(date: .complete, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Shown instead of the Readiness ring while baseline-dependent scores are
    /// still calibrating — honest about what's not yet available.
    private var calibratingHeader: some View {
        VStack(spacing: 10) {
            ScoreRing(progress: Double(usableDays) / 14, color: .opYellow,
                      lineWidth: 16, size: 200, title: "Calibrating",
                      value: "\(usableDays)/14", caption: "nights")
            Text("Recovery, Readiness & Stress unlock after 14 nights of data. Strain and sleep are available now.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }

    /// Recovery comes from the last scored night (`recoveryFrom`); Strain & Sleep
    /// reflect `today` so the day's load stays live.
    private func summaryRings(today: DailyRecord, recoveryFrom: DailyRecord?) -> some View {
        let rec = recoveryFrom
        return HStack(spacing: 12) {
            NavigationLink { RecoveryDetailView(record: rec ?? today) } label: {
                if let rec, rec.recovery != nil {
                    miniRing("Recovery", rec.recovery, (rec.recovery ?? 0)/100,
                             (rec.recoveryZone?.color ?? .gray), suffix: "%")
                } else {
                    calibratingMini("Recovery")
                }
            }.buttonStyle(.plain)
            NavigationLink { StrainDetailView() } label: {
                miniRing("Strain", today.dayStrain, (today.dayStrain ?? 0)/21,
                         (today.strainZone?.color ?? .opBlue), suffix: "")
            }.buttonStyle(.plain)
            NavigationLink { SleepDetailView() } label: {
                miniRing("Sleep", today.sleepPerformance, (today.sleepPerformance ?? 0)/100,
                         .opPurple, suffix: "%")
            }.buttonStyle(.plain)
        }
    }

    private func miniRing(_ title: String, _ value: Double?, _ progress: Double, _ color: Color, suffix: String) -> some View {
        VStack(spacing: 6) {
            ScoreRing(progress: progress, color: color, lineWidth: 8, size: 96,
                      title: title,
                      value: value == nil ? "—" : (suffix == "%" ? Fmt.score(value) : Fmt.strain(value)),
                      caption: nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }

    /// A mini tile that reads "calibrating n/14" for not-yet-available scores.
    private func calibratingMini(_ title: String) -> some View {
        VStack(spacing: 6) {
            ScoreRing(progress: Double(usableDays) / 14, color: .opYellow, lineWidth: 8, size: 96,
                      title: title, value: "\(usableDays)/14", caption: nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }

    private func recommendation(_ r: DailyRecord) -> some View {
        SectionCard(title: "Today's guidance", systemImage: "lightbulb.fill") {
            Text(guidance(r)).font(.subheadline)
            if let zone = r.recoveryZone {
                Pill(text: zone.label, color: zone.color)
            }
        }
    }

    private func checkIn(_ r: DailyRecord) -> some View {
        SectionCard(title: "How do you feel?", systemImage: "face.smiling") {
            Text("Log this daily — after 30 days OutPerform learns which signals predict your best days.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(1...5, id: \.self) { v in
                    Button {
                        r.feltGood = v
                        try? r.modelContext?.save()
                    } label: {
                        Image(systemName: r.feltGood == v ? faceFill(v) : face(v))
                            .font(.title2)
                            .foregroundStyle(r.feltGood == v ? faceColor(v) : .secondary)
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Copy helpers

    private func readinessCaption(_ s: Double?) -> String {
        guard let s else { return "" }
        switch s {
        case ..<34: return "Take it easy"
        case ..<67: return "Train smart"
        default: return "Go for it"
        }
    }

    /// The fully-elapsed day before `r` — its strain is "yesterday's" load.
    private func previousDayStrain(before r: DailyRecord) -> Double? {
        let cal = Calendar.current
        guard let prevDay = cal.date(byAdding: .day, value: -1, to: r.date) else { return nil }
        return records.first { cal.isDate($0.date, inSameDayAs: prevDay) }?.dayStrain
    }

    private func guidance(_ r: DailyRecord) -> String {
        guard let rec = r.recovery else { return "Sync to see today's guidance." }
        let strainText: String
        if let s = previousDayStrain(before: r) {
            strainText = " Yesterday's strain was \(Fmt.strain(s))."
        } else {
            strainText = ""
        }
        switch RecoveryZone(score: rec) {
        case .green:
            return "You're primed. Your body can handle a high-strain day — push toward a strain of 14–18 if you've got a hard session planned.\(strainText)"
        case .yellow:
            return "Moderately recovered. Moderate training is fine; keep an eye on how you feel and avoid an all-out effort.\(strainText)"
        case .red:
            return "Low recovery. Prioritise rest, light movement and good sleep tonight. Hard training now adds risk without much reward.\(strainText)"
        }
    }

    private func face(_ v: Int) -> String {
        ["", "face.dashed", "cloud.rain", "minus.circle", "face.smiling", "star"][v]
    }
    private func faceFill(_ v: Int) -> String {
        ["", "face.dashed.fill", "cloud.rain.fill", "minus.circle.fill", "face.smiling.fill", "star.fill"][v]
    }
    private func faceColor(_ v: Int) -> Color {
        [.gray, .opRed, .opRed, .opYellow, .opGreen, .opGreen][v]
    }
}
