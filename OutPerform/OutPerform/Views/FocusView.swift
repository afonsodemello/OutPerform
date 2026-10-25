//
//  FocusView.swift
//  OutPerform
//
//  "Perform" tab — cognitive focus curve, workout-timing curve, live user
//  feedback log, and the reaction-test calibration. Focus and workout peak
//  predictions adapt over time from user-reported "Feeling focused / energetic"
//  taps via an exponential moving average.
//

import SwiftUI
import SwiftData
import Charts

struct FocusView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    @Query(sort: \FocusTest.date, order: .reverse) private var tests: [FocusTest]

    // All feedback sorted newest-first; filter to today in the view.
    @Query(sort: \DailyFeedback.timestamp, order: .reverse) private var allFeedback: [DailyFeedback]

    @State private var showTest = false

    // Feedback popup state
    @State private var pendingKind: DailyFeedback.Kind? = nil   // non-nil opens the sheet
    @State private var pendingIntensity: Double = 3
    @State private var editingEntry: DailyFeedback? = nil       // non-nil → edit mode

    // All-time history sheets
    @State private var showFocusHistory = false
    @State private var showEnergyHistory = false

    private var todayRecord: DailyRecord? {
        records.first { ($0.totalSleepMin ?? 0) > 0 }
    }

    private var history: [DailyRecord] {
        guard let today = todayRecord else { return [] }
        return records.filter { $0 !== today }
    }

    /// Cognitive focus inputs, shifted by any user-feedback calibration.
    private var focusInputs: CognitiveInputs? {
        guard let today = todayRecord else { return nil }
        return FocusInputs.build(for: today, history: history,
                                 wakeMinuteFallback: settings.wakeMinuteOfDay,
                                 calibrationOffset: settings.focusCalibrationOffset,
                                 circadianPeakShift: settings.focusFeedbackShift)
    }

    /// Workout readiness inputs — same base data, energy feedback shift, no score calibration.
    private var workoutInputs: CognitiveInputs? {
        guard let today = todayRecord else { return nil }
        return FocusInputs.build(for: today, history: history,
                                 wakeMinuteFallback: settings.wakeMinuteOfDay,
                                 calibrationOffset: 0,
                                 circadianPeakShift: settings.energyFeedbackShift)
    }

    private var todayFeedback: [DailyFeedback] {
        let sod = Calendar.current.startOfDay(for: Date())
        return allFeedback.filter { $0.timestamp >= sod }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let fi = focusInputs {
                    VStack(spacing: 16) {
                        liveHeader(fi)
                        focusCurveCard(fi)
                        if let wi = workoutInputs { workoutCard(wi) }
                        FitnessAgeCard()
                        feedbackCard
                        windowsCard(fi)
                        driversCard(fi)
                        testCard
                        scienceCard
                    }
                    .padding()
                } else {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            title: "Not enough data",
                            message: "Perform needs at least one synced night of sleep. Once that's in, you'll see your focus curve, best workout windows, and can log how you feel.",
                            systemImage: "brain.head.profile")
                            .frame(minHeight: 320)
                        FitnessAgeCard()
                    }
                    .padding()
                }
            }
            .navigationTitle("Perform")
            .fullScreenCover(isPresented: $showTest) {
                ReactionTestView(predictedNow: currentScore(focusInputs) ?? 50)
            }
            .sheet(item: $pendingKind) { kind in
                feedbackSheet(kind: kind)
            }
            .sheet(isPresented: $showFocusHistory) {
                FeedbackHistoryView(kind: .focus)
            }
            .sheet(isPresented: $showEnergyHistory) {
                FeedbackHistoryView(kind: .energy)
            }
        }
    }

    // MARK: Live header

    private func liveHeader(_ inputs: CognitiveInputs) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let score = CognitiveReadinessCalculator.readiness(at: context.date, inputs: inputs)
            let zone = FocusZone(score: score)
            VStack(spacing: 10) {
                ScoreRing(progress: score / 100, color: zone.color, lineWidth: 16, size: 200,
                          title: "Focus now", value: Fmt.score(score), caption: zone.shortLabel)
                Pill(text: zone.label, color: zone.color)
                Text(guidanceNow(score: score, inputs: inputs, now: context.date))
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).padding(.horizontal)
            }
        }
    }

    // MARK: Focus curve

    private func focusCurveCard(_ inputs: CognitiveInputs) -> some View {
        let (from, to) = dayRange(inputs)
        let curve = CognitiveReadinessCalculator.curve(from: from, to: to, stepMinutes: 15, inputs: inputs)
        let windows = CognitiveReadinessCalculator.peakWindows(curve: curve)
        let focusLogs = todayFeedback.filter { $0.kind == .focus }
        let now = Date()
        return SectionCard(title: "Today's focus curve", systemImage: "chart.xyaxis.line") {
            Chart {
                ForEach(windows.indices, id: \.self) { i in
                    RectangleMark(xStart: .value("s", windows[i].start),
                                  xEnd: .value("e", windows[i].end))
                        .foregroundStyle(.opPurple.opacity(0.12))
                }
                ForEach(curve.indices, id: \.self) { i in
                    AreaMark(x: .value("time", curve[i].time), y: .value("focus", curve[i].score))
                        .foregroundStyle(.linearGradient(colors: [.opPurple.opacity(0.35), .opPurple.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("time", curve[i].time), y: .value("focus", curve[i].score))
                        .foregroundStyle(.opPurple).interpolationMethod(.catmullRom)
                }
                // User-reported focus moments as dots.
                ForEach(focusLogs, id: \.timestamp) { log in
                    PointMark(x: .value("time", log.timestamp),
                              y: .value("focus", CognitiveReadinessCalculator.readiness(at: log.timestamp, inputs: inputs)))
                        .foregroundStyle(.opPurple)
                        .symbolSize(80)
                        .annotation(position: .top) {
                            Image(systemName: "brain.head.profile")
                                .font(.caption2).foregroundStyle(.opPurple)
                        }
                }
                if now >= from && now <= to {
                    RuleMark(x: .value("now", now)).foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center) {
                            Text("now").font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
            }}
            .frame(height: 200)
            Text("Shaded bands are your peak focus periods. Purple dots show when you reported feeling focused.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Workout timing curve

    private func workoutCard(_ inputs: CognitiveInputs) -> some View {
        let (from, to) = dayRange(inputs)
        let curve = CognitiveReadinessCalculator.workoutCurve(from: from, to: to, stepMinutes: 15, inputs: inputs)
        let windows = CognitiveReadinessCalculator.bestWorkoutWindows(curve: curve)
        let energyLogs = todayFeedback.filter { $0.kind == .energy }
        let now = Date()
        return SectionCard(title: "Best time to train", systemImage: "figure.run") {
            Chart {
                ForEach(windows.indices, id: \.self) { i in
                    RectangleMark(xStart: .value("s", windows[i].start),
                                  xEnd: .value("e", windows[i].end))
                        .foregroundStyle(.opBlue.opacity(0.12))
                }
                ForEach(curve.indices, id: \.self) { i in
                    AreaMark(x: .value("time", curve[i].time), y: .value("score", curve[i].score))
                        .foregroundStyle(.linearGradient(colors: [.opBlue.opacity(0.35), .opBlue.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("time", curve[i].time), y: .value("score", curve[i].score))
                        .foregroundStyle(.opBlue).interpolationMethod(.catmullRom)
                }
                ForEach(energyLogs, id: \.timestamp) { log in
                    PointMark(x: .value("time", log.timestamp),
                              y: .value("score", CognitiveReadinessCalculator.workoutReadiness(at: log.timestamp, inputs: inputs)))
                        .foregroundStyle(.opBlue)
                        .symbolSize(80)
                        .annotation(position: .top) {
                            Image(systemName: "bolt.fill")
                                .font(.caption2).foregroundStyle(.opBlue)
                        }
                }
                if now >= from && now <= to {
                    RuleMark(x: .value("now", now)).foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center) {
                            Text("now").font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
            }}
            .frame(height: 160)

            if windows.isEmpty {
                Text("No strong training windows today — your body may benefit from rest or a light session.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(windows.indices, id: \.self) { i in
                    let w = windows[i]
                    if w.end >= now {
                        HStack {
                            Image(systemName: "flame.fill").foregroundStyle(.opBlue)
                            Text("\(Fmt.time(w.start)) – \(Fmt.time(w.end))")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Pill(text: "readiness \(Int(w.peakScore))", color: .opBlue)
                        }
                    }
                }
            }
            Text("Physical performance follows your core body temperature rhythm, peaking 1–2 h later than cognitive focus. Blue dots show when you reported feeling energetic.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: User feedback card

    private var feedbackCard: some View {
        SectionCard(title: "How I'm feeling", systemImage: "hand.thumbsup.fill") {
            // Focus section
            feedbackSection(kind: .focus, color: .opPurple, showHistory: $showFocusHistory)
            Divider()
            // Energy section
            feedbackSection(kind: .energy, color: .opBlue, showHistory: $showEnergyHistory)

            learnedPatternNote
        }
    }

    private func feedbackSection(kind: DailyFeedback.Kind, color: Color,
                                 showHistory: Binding<Bool>) -> some View {
        let todayEntries = todayFeedback.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 10) {
            // Log button
            Button { pendingKind = kind; pendingIntensity = 3 } label: {
                HStack(spacing: 10) {
                    Image(systemName: kind.icon).foregroundStyle(color).font(.title3)
                    Text("Log \(kind.label.lowercased()) now")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "plus.circle.fill").foregroundStyle(color)
                }
                .padding(12)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            // Today's entries for this kind
            if todayEntries.isEmpty {
                Text("No \(kind.label.lowercased()) logged today")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(todayEntries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.intensityDots)
                            .font(.caption).foregroundStyle(color)
                            .frame(width: 60, alignment: .leading)
                        Text(entry.intensityLabel)
                            .font(.subheadline)
                        Spacer()
                        Text(Fmt.time(entry.timestamp))
                            .font(.caption).foregroundStyle(.secondary)
                        // Edit
                        Button {
                            editingEntry = entry
                            pendingIntensity = Double(entry.intensity)
                            pendingKind = kind
                        } label: {
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { modelContext.delete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            // See all history
            Button { showHistory.wrappedValue = true } label: {
                HStack(spacing: 4) {
                    Text("See all \(kind.label.lowercased()) history")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Feedback entry sheet (log + edit)

    private func feedbackSheet(kind: DailyFeedback.Kind) -> some View {
        let color: Color = kind == .focus ? .opPurple : .opBlue
        let isEditing = editingEntry != nil
        return NavigationStack {
            VStack(spacing: 32) {
                Image(systemName: kind.icon)
                    .font(.system(size: 48)).foregroundStyle(color)

                VStack(spacing: 8) {
                    Text(isEditing ? "Edit \(kind.label)" : "How's your \(kind.label.lowercased())?")
                        .font(.title2.bold())
                    Text(intensityDescription(Int(pendingIntensity.rounded()), kind: kind))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .animation(.easeInOut(duration: 0.15), value: pendingIntensity)
                }

                // Slider 1–5
                VStack(spacing: 10) {
                    Slider(value: $pendingIntensity, in: 1...5, step: 1)
                        .tint(color)
                        .padding(.horizontal)
                    HStack {
                        Text("1").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(intensityStars(Int(pendingIntensity.rounded())))
                            .font(.title3).foregroundStyle(color)
                        Spacer()
                        Text("5").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    HStack {
                        Text("Very low").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Peak").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                Button {
                    saveFeedback(kind: kind, intensity: Int(pendingIntensity.rounded()))
                    editingEntry = nil
                    pendingKind = nil
                } label: {
                    Text(isEditing ? "Save changes" : "Log now")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(color, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .font(.headline)
                }
                .padding(.horizontal)
            }
            .padding(.top, 32)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingEntry = nil; pendingKind = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func intensityStars(_ v: Int) -> String { String(repeating: "★", count: v) + String(repeating: "☆", count: 5 - v) }

    private func intensityDescription(_ v: Int, kind: DailyFeedback.Kind) -> String {
        switch (kind, v) {
        case (.focus, 1): return "Struggling to concentrate, easily distracted"
        case (.focus, 2): return "Below average, thoughts keep wandering"
        case (.focus, 3): return "Moderate focus, getting things done"
        case (.focus, 4): return "Sharp and engaged, in the zone"
        case (.focus, 5): return "Peak — deep flow state, nothing breaking through"
        case (.energy, 1): return "Drained, barely getting through the day"
        case (.energy, 2): return "Low energy, dragging a bit"
        case (.energy, 3): return "Okay, functional but not great"
        case (.energy, 4): return "Feeling strong and ready to move"
        case (.energy, 5): return "Full energy — ready to push hard"
        default: return ""
        }
    }

    @ViewBuilder
    private var learnedPatternNote: some View {
        let fShift = settings.focusFeedbackShift
        let eShift = settings.energyFeedbackShift
        let fCount = allFeedback.filter { $0.kind == .focus }.count
        let eCount = allFeedback.filter { $0.kind == .energy }.count
        if (fCount >= 5 && abs(fShift) > 0.5) || (eCount >= 5 && abs(eShift) > 0.5) {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if fCount >= 5, abs(fShift) > 0.5 {
                    Text("Your focus tends to peak \(abs(fShift) < 1.5 ? "slightly" : "") \(fShift > 0 ? "later" : "earlier") than average — focus curve adjusted.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if eCount >= 5, abs(eShift) > 0.5 {
                    Text("Your energy tends to peak \(abs(eShift) < 1.5 ? "slightly" : "") \(eShift > 0 ? "later" : "earlier") than average — workout windows adjusted.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Deep-work windows

    private func windowsCard(_ inputs: CognitiveInputs) -> some View {
        let (from, to) = dayRange(inputs)
        let curve = CognitiveReadinessCalculator.curve(from: from, to: to, stepMinutes: 15, inputs: inputs)
        let now = Date()
        let upcoming = CognitiveReadinessCalculator.peakWindows(curve: curve).filter { $0.end >= now }
        return SectionCard(title: "Deep-work windows", systemImage: "scope") {
            if upcoming.isEmpty {
                Text("No more peak focus windows today — protect tomorrow's by getting to bed on time.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(upcoming.indices, id: \.self) { i in
                    HStack {
                        Image(systemName: "bolt.fill").foregroundStyle(.opPurple)
                        Text("\(Fmt.time(upcoming[i].start)) – \(Fmt.time(upcoming[i].end))")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Pill(text: "peak \(Int(upcoming[i].peakScore))", color: .opPurple)
                    }
                }
                Text("Schedule your hardest cognitive work in these windows; save email, chores and meetings for the dips.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Drivers

    private func driversCard(_ inputs: CognitiveInputs) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let d = CognitiveReadinessCalculator.drivers(at: context.date, inputs: inputs)
            SectionCard(title: "What's driving it", systemImage: "slider.horizontal.3") {
                ContributionBar(label: "Sleep pressure (rested)", score: d.sleepPressure)
                ContributionBar(label: "Body clock (circadian)", score: d.circadian)
                ContributionBar(label: "Recovery state (HRV)", score: d.recoveryState)
                ContributionBar(label: "Calm (low stress)", score: d.calm)
                ContributionBar(label: "Awakeness (inertia cleared)", score: d.sleepInertia)
                Text(driverHint(d)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Reaction test + calibration

    private var testCard: some View {
        SectionCard(title: "Calibrate with a reaction test", systemImage: "hand.tap.fill") {
            Text("A 1-minute reaction test measures your real alertness and tunes the prediction to you. The more you do it at different times, the sharper it gets.")
                .font(.caption).foregroundStyle(.secondary)
            Button { showTest = true } label: {
                Label("Take the test", systemImage: "play.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)

            if let last = tests.first {
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text("Last test").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(last.measuredAlertness)) measured").font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(Fmt.time(last.date)).font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(last.predictedAtTest)) predicted").font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if abs(settings.focusCalibrationOffset) > 0.5 {
                    Pill(text: String(format: "Calibration: %+.0f", settings.focusCalibrationOffset),
                         color: .opBlue)
                }
                if tests.count >= 2 { testHistoryChart }
            }
        }
    }

    private var testHistoryChart: some View {
        let recent = Array(tests.prefix(14)).reversed().map { $0 }
        return Chart {
            ForEach(recent.indices, id: \.self) { i in
                PointMark(x: .value("when", recent[i].date),
                          y: .value("measured", recent[i].measuredAlertness))
                    .foregroundStyle(.opPurple)
                PointMark(x: .value("when", recent[i].date),
                          y: .value("predicted", recent[i].predictedAtTest))
                    .foregroundStyle(.secondary).symbolSize(40)
            }
        }
        .chartYScale(domain: 0...100)
        .frame(height: 120)
    }

    // MARK: Science

    private var scienceCard: some View {
        SectionCard(title: "How this works", systemImage: "book.closed") {
            Text("Your focus score is a **prediction**, not a measurement. It's built on the Three-Process Model of alertness used in aviation and shift-work safety. Workout timing follows core body temperature research — physical performance peaks 1–2 h after cognitive focus, in the mid-to-late afternoon.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                bullet("Sleep pressure — alertness falls the longer you're awake.")
                bullet("Body clock — a daily rhythm that peaks late-afternoon with an early-afternoon dip.")
                bullet("Sleep inertia — grogginess for the first hour after waking.")
                bullet("HRV & stress — nudge the level up or down.")
                bullet("Feedback learning — your taps gradually shift the predicted peaks toward your actual rhythms.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.opPurple)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Logging + learning

    private func saveFeedback(kind: DailyFeedback.Kind, intensity: Int) {
        if let existing = editingEntry {
            // Update in place — keep original timestamp.
            existing.intensity = intensity
        } else {
            let entry = DailyFeedback(kind: kind, intensity: intensity)
            modelContext.insert(entry)
        }

        // Only shift the circadian curve from high-intensity reports (≥3), since a
        // "1 at 2pm" means you feel bad at 2pm — opposite signal from a "5 at 2pm".
        guard intensity >= 3 else { return }
        let inputs = kind == .focus ? focusInputs : workoutInputs
        guard let inp = inputs else { return }
        let (from, to) = dayRange(inp)
        let curve = kind == .focus
            ? CognitiveReadinessCalculator.curve(from: from, to: to, stepMinutes: 15, inputs: inp)
            : CognitiveReadinessCalculator.workoutCurve(from: from, to: to, stepMinutes: 15, inputs: inp)
        guard let predictedPeak = curve.max(by: { $0.score < $1.score }) else { return }
        let predictedHour = CognitiveReadinessCalculator.hourOfDay(predictedPeak.time)
        let actualHour    = CognitiveReadinessCalculator.hourOfDay(Date())
        // Weight the shift by how strong the feeling is (5 = full weight, 3 = half).
        let weight = Double(intensity - 2) / 3.0   // 3→0.33, 4→0.67, 5→1.0
        let diff = (actualHour - predictedHour) * weight
        let alpha = 0.25
        if kind == .focus {
            settings.focusFeedbackShift += alpha * (diff - settings.focusFeedbackShift)
        } else {
            settings.energyFeedbackShift += alpha * (diff - settings.energyFeedbackShift)
        }
    }

    // MARK: Helpers

    private func currentScore(_ inputs: CognitiveInputs?) -> Double? {
        inputs.map { CognitiveReadinessCalculator.readiness(at: Date(), inputs: $0) }
    }

    private func dayRange(_ inputs: CognitiveInputs) -> (Date, Date) {
        let from = inputs.wakeTime
        let to = Calendar.current.date(byAdding: .hour, value: 17, to: from) ?? from
        return (from, to)
    }

    private func guidanceNow(score: Double, inputs: CognitiveInputs, now: Date) -> String {
        let (from, to) = dayRange(inputs)
        let curve = CognitiveReadinessCalculator.curve(from: from, to: to, stepMinutes: 15, inputs: inputs)
        let nextPeak = CognitiveReadinessCalculator.peakWindows(curve: curve).first { $0.start > now }
        switch FocusZone(score: score) {
        case .peak:
            return "You're in a peak window — protect it for your hardest, most creative work. Silence notifications."
        case .high:
            return "Good focus. Tackle demanding tasks now." + nextPeakText(nextPeak)
        case .moderate:
            return "Steady focus — fine for routine work." + nextPeakText(nextPeak)
        case .low:
            let hoursAwake = now.timeIntervalSince(inputs.wakeTime) / 3600
            if hoursAwake < 1.5 { return "Sleep inertia — give yourself ~30–60 min (light + movement) before deep work." }
            return "Low focus. Do admin, take a walk, or a short nap." + nextPeakText(nextPeak)
        }
    }

    private func nextPeakText(_ window: FocusWindow?) -> String {
        guard let window else { return "" }
        return " Next peak window ~\(Fmt.time(window.start))."
    }

    private func driverHint(_ d: CognitiveDrivers) -> String {
        var weakest = ("sleep", d.sleepPressure)
        if d.circadian < weakest.1 { weakest = ("body clock", d.circadian) }
        if d.calm < weakest.1 { weakest = ("stress", d.calm) }
        if d.sleepInertia < weakest.1 { weakest = ("inertia", d.sleepInertia) }
        switch weakest.0 {
        case "sleep": return "Biggest limiter right now: sleep debt. More/earlier sleep raises the whole curve."
        case "body clock": return "You're in a circadian dip — it'll pass; don't fight it with stimulants late."
        case "stress": return "Elevated stress is dragging focus — a few minutes of breathwork can help."
        case "inertia": return "Still waking up — alertness will climb over the next hour."
        default: return ""
        }
    }
}

// MARK: - All-time feedback history sheet

struct FeedbackHistoryView: View {
    let kind: DailyFeedback.Kind
    @Query(sort: \DailyFeedback.timestamp, order: .reverse) private var all: [DailyFeedback]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private var entries: [DailyFeedback] { all.filter { $0.kind == kind } }
    private var color: Color { kind == .focus ? .opPurple : .opBlue }

    private var grouped: [(String, [DailyFeedback])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .none
        let groups = Dictionary(grouping: entries) { e in
            fmt.string(from: cal.startOfDay(for: e.timestamp))
        }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No \(kind.label) logs yet",
                        systemImage: kind.icon,
                        description: Text("Tap \"Log \(kind.label.lowercased()) now\" in the Perform tab whenever you notice how you're feeling.")
                    )
                } else {
                    List {
                        ForEach(grouped, id: \.0) { day, dayEntries in
                            Section(day) {
                                ForEach(dayEntries) { entry in
                                    HStack(spacing: 12) {
                                        Text(entry.intensityDots)
                                            .font(.caption).foregroundStyle(color)
                                            .frame(width: 64, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.intensityLabel).font(.subheadline)
                                            Text(Fmt.time(entry.timestamp))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { modelContext.delete(entry) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(kind.label) history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
