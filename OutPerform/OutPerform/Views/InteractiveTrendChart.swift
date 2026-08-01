//
//  InteractiveTrendChart.swift
//  OutPerform
//
//  A line/area chart you can scrub with your finger: drag left/right and the
//  callout shows that exact day's date and value.
//

import SwiftUI
import Charts

struct TrendPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct InteractiveTrendChart: View {
    let points: [TrendPoint]
    var tint: Color
    var domain: ClosedRange<Double>?
    var format: (Double) -> String

    @State private var selectedDate: Date?

    private var selected: TrendPoint? {
        guard let selectedDate, !points.isEmpty else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var shown: TrendPoint? { selected ?? points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = shown {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(format(p.value))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(tint)
                    Text(p.date.formatted(.dateTime.weekday(.abbreviated).day().month()))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if selected != nil {
                        Text("drag to browse").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Chart {
                ForEach(points) { p in
                    // `.monotone` stays smooth without the overshoot that made
                    // Catmull-Rom bulge past the axes / plot area.
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                if let sel = selected {
                    RuleMark(x: .value("Date", sel.date))
                        .foregroundStyle(.secondary.opacity(0.4))
                    PointMark(x: .value("Date", sel.date), y: .value("Value", sel.value))
                        .foregroundStyle(tint)
                        .symbolSize(140)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYScale(domain: yDomain)
            .chartPlotStyle { $0.clipped() }   // belt-and-braces: never draw outside
            .frame(height: 200)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let vals = points.map(\.value)
        let dataLo = vals.min() ?? 0, dataHi = vals.max() ?? 1
        if let domain {
            // Keep the metric's natural scale but always include actual data.
            return Swift.min(domain.lowerBound, dataLo)...Swift.max(domain.upperBound, dataHi)
        }
        let pad = max((dataHi - dataLo) * 0.15, 1)
        return (dataLo - pad)...(dataHi + pad)
    }
}
