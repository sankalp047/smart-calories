import SwiftUI
import Charts

/// Heart rate over time, from the raw per-second archive on disk.
///
/// The chart draws a min–max envelope with the per-bucket mean on top —
/// honest about the spread inside each bucket instead of pretending the
/// smoothed line is the whole story. Today buckets per minute; the 7-day
/// view per quarter-hour, which keeps both under ~1,500 marks.
struct HeartRateHistoryCard: View {
    @Environment(AppEnvironment.self) private var env

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case custom = "Custom"
        var id: String { rawValue }
    }

    /// Chart window resolved from the range + the typed custom minutes.
    private var windowStart: Date {
        let cal = Calendar.current
        switch range {
        case .today: return cal.startOfDay(for: Date())
        case .week: return cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .custom: return Date().addingTimeInterval(TimeInterval(-clampedMinutes * 60))
        }
    }

    private var bucketSeconds: Int {
        switch range {
        case .today: 60
        case .week: 900
        case .custom: HeartSampleStore.adaptiveBucketSeconds(windowSeconds: clampedMinutes * 60)
        }
    }

    /// The typed window, held to the promised 1–60 minute bounds.
    private var clampedMinutes: Int {
        min(60, max(1, Int(customMinutesText) ?? 15))
    }

    /// `-startHRRange "7 days"` pre-selects the range, same review affordance
    /// as startTab/startSheet.
    @State private var range: Range = UserDefaults.standard
        .string(forKey: "startHRRange").flatMap(Range.init) ?? .today
    @State private var customMinutesText = "15"
    @FocusState private var minutesFieldFocused: Bool
    @State private var buckets: [HeartSampleStore.Bucket] = []
    @State private var isLoading = true
    /// Guards against a slow load for one range landing after the user
    /// already switched to the other.
    @State private var loadToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)

            if range == .custom {
                HStack(spacing: 8) {
                    Text("Last")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    TextField("15", text: $customMinutesText)
                        .keyboardType(.numberPad)
                        .focused($minutesFieldFocused)
                        .font(.numeric(16))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 54)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.Palette.controlFill)
                        }
                        .onSubmit { reload() }
                        .onChange(of: minutesFieldFocused) { _, focused in
                            if !focused { reload() }
                        }
                    Text("minutes (1–60)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(Theme.Palette.accent).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Reading archive…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if buckets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(range == .today
                         ? "No heart data yet today — connect your WHOOP and it fills in live."
                         : "No heart data in the last 7 days.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart
                summaryRow
            }
        }
        .glassCard()
        .onAppear { reload() }
        .onChange(of: range) { _, _ in reload() }
        // Live mode: re-read every 5 s so incoming samples draw themselves.
        // The task is bound to the view's lifetime and only ticks in custom.
        .task(id: range) {
            guard range == .custom else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled, !minutesFieldFocused { reload() }
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(buckets) { bucket in
            // Envelope: the true min–max spread inside each bucket.
            AreaMark(
                x: .value("Time", bucket.date),
                yStart: .value("Min", bucket.minBpm),
                yEnd: .value("Max", bucket.maxBpm)
            )
            .foregroundStyle(Theme.Palette.alert.opacity(0.16))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", bucket.date),
                y: .value("BPM", bucket.avgBpm)
            )
            .foregroundStyle(Theme.Palette.alert)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: windowStart...Date())
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                AxisValueLabel(format: chartAxisFormat)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(height: 170)
    }

    private var chartAxisFormat: Date.FormatStyle {
        switch range {
        case .today: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .custom: .dateTime.hour().minute()
        }
    }

    private var summaryRow: some View {
        let low = buckets.map(\.minBpm).min() ?? 0
        let high = buckets.map(\.maxBpm).max() ?? 0
        let mean = buckets.isEmpty ? 0
            : buckets.reduce(0.0) { $0 + $1.avgBpm } / Double(buckets.count)
        return HStack(spacing: 14) {
            summaryStat("Low", "\(low)")
            summaryStat("Avg", "\(Int(mean.rounded()))")
            summaryStat("High", "\(high)")
            Spacer()
            Text("\(buckets.count) points")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    // MARK: - Loading

    /// File reads and parsing happen off the main actor; a day of samples is
    /// ~1.4 MB of CSV and must not stutter the UI.
    private func reload() {
        if buckets.isEmpty { isLoading = true }   // refreshes shouldn't flicker
        loadToken += 1
        let token = loadToken
        let store = env.heart.samples
        let start = windowStart
        let width = bucketSeconds
        // Snapshot the unflushed tail on the main actor — the live window
        // should include the seconds that haven't hit disk yet.
        let tail = store.bufferSnapshot()
        let fromTs = Int(start.timeIntervalSince1970)

        Task.detached(priority: .userInitiated) {
            var samples = store.samples(from: start, to: Date())
            samples.append(contentsOf: tail.filter { $0.ts >= fromTs })
            let result = HeartSampleStore.bucketed(samples, bucketSeconds: width)
            await MainActor.run {
                guard token == loadToken else { return }
                buckets = result
                isLoading = false
            }
        }
    }
}
