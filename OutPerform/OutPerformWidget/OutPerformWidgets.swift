//
//  OutPerformWidgets.swift
//  OutPerformWidget
//
//  Home-screen and lock-screen widgets for Readiness, Recovery, Strain, Sleep
//  and Suggested bedtime. Reads the latest scores the main app published to the
//  shared App Group.
//

import WidgetKit
import SwiftUI

// MARK: - Shared data

private enum Shared {
    static let suite = "group.mamilles.OutPerform"
    static let none = -1.0

    static func d(_ key: String) -> Double? {
        guard let ud = UserDefaults(suiteName: suite) else { return nil }
        let v = ud.double(forKey: key)
        return v == none ? nil : v
    }
    static var readiness: Double? { d("w.readiness") }
    static var recovery: Double? { d("w.recovery") }
    static var strain: Double? { d("w.strain") }
    static var sleep: Double? { d("w.sleep") }
    static var bedtime: Date? { d("w.bedtime").map { Date(timeIntervalSince1970: $0) } }
    static var calibratingNights: Int {
        Int(UserDefaults(suiteName: suite)?.double(forKey: "w.calibrating") ?? -1)
    }
    static var lastSynced: Date? {
        guard let ud = UserDefaults(suiteName: suite) else { return nil }
        let v = ud.double(forKey: "w.updated")
        return v == 0 ? nil : Date(timeIntervalSince1970: v)
    }
}

// MARK: - Colours (self-contained for the extension)

private extension Color {
    static let opGreen = Color(red: 0.30, green: 0.78, blue: 0.47)
    static let opYellow = Color(red: 0.98, green: 0.74, blue: 0.18)
    static let opRed = Color(red: 0.95, green: 0.35, blue: 0.35)
    static let opBlue = Color(red: 0.30, green: 0.62, blue: 0.95)
    static let opPurple = Color(red: 0.55, green: 0.45, blue: 0.95)
}

private func scoreColor(_ v: Double) -> Color {
    switch v { case ..<34: return .opRed; case ..<67: return .opYellow; default: return .opGreen }
}

// MARK: - Metric model

enum Metric: String, CaseIterable {
    case readiness, recovery, strain, sleep, bedtime

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .sleep: return "Sleep"
        case .bedtime: return "Bedtime"
        }
    }
    var systemImage: String {
        switch self {
        case .readiness: return "bolt.heart.fill"
        case .recovery: return "arrow.clockwise.heart.fill"
        case .strain: return "flame.fill"
        case .sleep: return "bed.double.fill"
        case .bedtime: return "alarm.fill"
        }
    }
    var tint: Color {
        switch self {
        case .readiness: return .opGreen
        case .recovery: return .opGreen
        case .strain: return .opBlue
        case .sleep: return .opPurple
        case .bedtime: return .opPurple
        }
    }

    func value(_ e: Entry) -> Double? {
        switch self {
        case .readiness: return e.readiness
        case .recovery: return e.recovery
        case .strain: return e.strain
        case .sleep: return e.sleep
        case .bedtime: return nil
        }
    }
    /// 0...1 progress for rings/gauges.
    func progress(_ e: Entry) -> Double {
        guard let v = value(e) else { return 0 }
        return self == .strain ? min(v / 21, 1) : v / 100
    }
    func display(_ e: Entry) -> String {
        switch self {
        case .bedtime:
            guard let b = e.bedtime else { return "—" }
            let f = DateFormatter(); f.timeStyle = .short
            return f.string(from: b)
        case .strain:
            guard let v = value(e) else { return "—" }
            return String(format: "%.1f", v)
        default:
            guard let v = value(e) else { return "—" }
            return "\(Int(v.rounded()))"
        }
    }
    func color(_ e: Entry) -> Color {
        if self == .strain || self == .bedtime { return tint }
        return value(e).map(scoreColor) ?? .gray
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    var date: Date
    var readiness: Double?
    var recovery: Double?
    var strain: Double?
    var sleep: Double?
    var bedtime: Date?
    var calibratingNights: Int
    var lastSynced: Date?

    static var sample: Entry {
        Entry(date: .now, readiness: 69, recovery: 53, strain: 8.4, sleep: 79,
              bedtime: Calendar.current.date(bySettingHour: 23, minute: 10, second: 0, of: .now),
              calibratingNights: -1,
              lastSynced: Calendar.current.date(byAdding: .minute, value: -42, to: .now))
    }
    static var current: Entry {
        Entry(date: .now, readiness: Shared.readiness, recovery: Shared.recovery,
              strain: Shared.strain, sleep: Shared.sleep, bedtime: Shared.bedtime,
              calibratingNights: Shared.calibratingNights, lastSynced: Shared.lastSynced)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? .sample : .current)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Refresh ~ every 30 min; the app also pushes reloads after each sync.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [.current], policy: .after(next)))
    }
}

// MARK: - Views

private struct Ring: View {
    var progress: Double, color: Color, value: String, caption: String?
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 7)
            Circle().trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: .init(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(color)
                if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Single-metric content for the home small + lock-screen families.
private struct MetricView: View {
    @Environment(\.widgetFamily) var family
    let metric: Metric
    let entry: Entry

    private var calibrating: Bool {
        entry.calibratingNights >= 0 && (metric == .readiness || metric == .recovery)
    }

    var body: some View {
        content.containerBackground(for: .widget) { widgetBackground(family) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            if calibrating {
                Gauge(value: Double(entry.calibratingNights), in: 0...14) { Image(systemName: metric.systemImage) }
                    .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Gauge(value: metric.progress(entry)) {
                    Image(systemName: metric.systemImage)
                } currentValueLabel: {
                    Text(metric.display(entry))
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
            }
        case .accessoryInline:
            Label(calibrating ? "\(metric.title) \(entry.calibratingNights)/14"
                              : "\(metric.title) \(metric.display(entry))",
                  systemImage: metric.systemImage)
        case .accessoryRectangular:
            OverviewRectangular(entry: entry)
        default: // systemSmall
            ZStack {
                if calibrating {
                    VStack(spacing: 6) {
                        Image(systemName: metric.systemImage).foregroundStyle(metric.tint)
                        Text("\(entry.calibratingNights)/14").font(.title2.bold())
                        Text("Calibrating").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        Ring(progress: metric.progress(entry), color: metric.color(entry),
                             value: metric.display(entry), caption: nil)
                            .frame(width: 78, height: 78)
                        Label(metric.title, systemImage: metric.systemImage)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The required per-widget background, appropriate to each family.
@ViewBuilder private func widgetBackground(_ family: WidgetFamily) -> some View {
    switch family {
    case .accessoryCircular: AccessoryWidgetBackground()
    case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge: Rectangle().fill(.fill.tertiary)
    default: Color.clear
    }
}

/// Lock-screen rectangular: a compact line per metric.
private struct OverviewRectangular: View {
    let entry: Entry
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Readiness \(Metric.readiness.display(entry))  ·  Recovery \(Metric.recovery.display(entry))%")
                    .font(.headline)
                Text("Strain \(Metric.strain.display(entry))  ·  Sleep \(Metric.sleep.display(entry))%")
                Text("Bed \(Metric.bedtime.display(entry))")
                if let synced = entry.lastSynced {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                        Text("Synced ") + Text(synced, style: .relative) + Text(" ago")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(intent: SyncNowIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .widgetAccentable()
    }
}

/// Home medium: all five metrics.
private struct OverviewMedium: View {
    let entry: Entry
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                cell(.readiness); cell(.recovery); cell(.strain); cell(.sleep)
            }
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill").foregroundStyle(Color.opPurple)
                Text("Suggested bedtime").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Metric.bedtime.display(entry)).font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 4) {
                Button(intent: SyncNowIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                if let synced = entry.lastSynced {
                    (Text("Synced ") + Text(synced, style: .relative) + Text(" ago"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not yet synced")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(4)
    }
    private func cell(_ m: Metric) -> some View {
        VStack(spacing: 4) {
            Ring(progress: m.progress(entry), color: m.color(entry), value: m.display(entry), caption: nil)
                .frame(width: 56, height: 56)
            Text(m.title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct OverviewSmall: View {
    let entry: Entry
    var body: some View {
        VStack(spacing: 6) {
            Ring(progress: Metric.readiness.progress(entry), color: Metric.readiness.color(entry),
                 value: Metric.readiness.display(entry), caption: "Readiness")
                .frame(width: 80, height: 80)
            HStack(spacing: 8) {
                mini("R", Metric.recovery, entry)
                mini("St", Metric.strain, entry)
                mini("Sl", Metric.sleep, entry)
            }.font(.system(size: 10))
            HStack(spacing: 3) {
                Button(intent: SyncNowIntent()) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                if let synced = entry.lastSynced {
                    Text(synced, style: .relative)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    private func mini(_ l: String, _ m: Metric, _ e: Entry) -> some View {
        VStack(spacing: 0) {
            Text(m.display(e)).font(.system(size: 12, weight: .semibold)).foregroundStyle(m.color(e))
            Text(l).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widgets

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OutPerformOverview", provider: Provider()) { entry in
            OverviewEntryView(entry: entry)
        }
        .configurationDisplayName("OutPerform")
        .description("Readiness, recovery, strain, sleep and bedtime at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct OverviewEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        content.containerBackground(for: .widget) { widgetBackground(family) }
    }
    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: OverviewMedium(entry: entry)
        case .accessoryRectangular: OverviewRectangular(entry: entry)
        default: OverviewSmall(entry: entry)
        }
    }
}

/// One widget per metric (home small + lock circular/inline/rectangular).
struct ReadinessWidget: Widget { var body: some WidgetConfiguration { metricConfig(.readiness) } }
struct RecoveryWidget: Widget { var body: some WidgetConfiguration { metricConfig(.recovery) } }
struct StrainWidget: Widget { var body: some WidgetConfiguration { metricConfig(.strain) } }
struct SleepWidget: Widget { var body: some WidgetConfiguration { metricConfig(.sleep) } }
struct BedtimeWidget: Widget { var body: some WidgetConfiguration { metricConfig(.bedtime) } }

private func metricConfig(_ metric: Metric) -> some WidgetConfiguration {
    // Plain String values (not interpolated literals) avoid WidgetKit's
    // "formatted text is not supported" crash for these display strings.
    let name: String = "OutPerform " + metric.title
    let desc: String = "Your " + metric.title.lowercased() + "."
    return StaticConfiguration(kind: "OutPerform.\(metric.rawValue)", provider: Provider()) { entry in
        MetricView(metric: metric, entry: entry)
    }
    .configurationDisplayName(name)
    .description(desc)
    .supportedFamilies(metric == .bedtime
        ? [.systemSmall, .accessoryInline, .accessoryRectangular]
        : [.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
}

@main
struct OutPerformWidgetBundle: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        ReadinessWidget()
        RecoveryWidget()
        StrainWidget()
        SleepWidget()
        BedtimeWidget()
    }
}
