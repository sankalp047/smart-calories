import SwiftUI

/// Two-point calibration wizard.
///
/// Instead of asking anyone to read hex, this captures a raw frame at two known
/// weights and solves the byte layout automatically — which is what lets the app
/// support scales it has never seen.
struct CalibrationView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var unit: WeightUnit = .grams
    @State private var entry = ""
    @State private var samples: [(frame: [UInt8], value: Double)] = []
    @State private var solved: ScaleDecoderConfig?
    @State private var failure: String?
    @State private var showAdvanced = false

    private var scale: ScaleService { env.scale }
    private var isReceiving: Bool { scale.latestFrame != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if !scale.isConnected {
                        notConnected
                    } else if let solved {
                        successCard(solved)
                    } else {
                        statusBanner
                        instructions
                        unitPicker
                        captureCard
                        if let failure { InlineMessage(kind: .error, text: failure) }
                        if !samples.isEmpty { capturedList }
                    }

                    if scale.isConnected {
                        advanced
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - States

    private var notConnected: some View {
        EmptyStateView(
            icon: "antenna.radiowaves.left.and.right.slash",
            title: "Connect your scale first",
            message: "Pair a scale on the Scale tab, then come back to calibrate it.",
            actionTitle: "Close",
            action: { dismiss() }
        )
        .glassCard()
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: isReceiving ? "dot.radiowaves.up.forward" : "hourglass")
                .foregroundStyle(isReceiving ? Theme.Palette.accent : Theme.Palette.carbs)
            Text(isReceiving
                 ? "Receiving data from the scale."
                 : "Connected, but no data yet — press the scale's button or add a little weight.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14,
                   tint: isReceiving ? Theme.Palette.accent : Theme.Palette.carbs)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How this works")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Put a known weight on the scale, type the number its own display shows, and capture. Do it twice with two clearly different weights — the app figures out the rest.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    private var unitPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UNIT SHOWN ON YOUR SCALE")
                .font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            Picker("", selection: $unit) {
                ForEach(WeightUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!samples.isEmpty)
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weight \(samples.count + 1) of 2")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(samples.isEmpty
                 ? "Place any known weight on the scale and let it settle."
                 : "Now place a clearly different weight and let it settle.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)

            HStack(spacing: 10) {
                TextField("0", text: $entry)
                    .keyboardType(.decimalPad)
                    .font(.numeric(30))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(Theme.Palette.controlFill)
                    }
                Text(unit.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            PrimaryButton(title: "Capture", icon: "camera.metering.center.weighted",
                          enabled: isReceiving && (Double(entry) ?? 0) > 0) {
                capture()
            }
        }
        .glassCard()
    }

    private var capturedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAPTURED")
                .font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                HStack {
                    Text("Sample \(index + 1)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Text("\(Int(sample.value)) \(unit.label)")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    private func successCard(_ config: ScaleDecoderConfig) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.Palette.accent)
            Text("Calibrated")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(scale.reading?.display ?? "—")
                .font(.numeric(46, .heavy))
                .foregroundStyle(Theme.Grad.accent)
                .contentTransition(.numericText())
            Text("Live reading — add or remove weight to confirm it tracks.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                detail("Byte offset", "\(config.weightOffset)")
                detail("Width", "\(config.weightLength) bytes")
                detail("Byte order", config.littleEndian ? "Little-endian" : "Big-endian")
                detail("Divisor", "÷\(Int(config.divisor))")
            }
            .padding(.top, 4)

            HStack(spacing: 10) {
                SecondaryButton(title: "Redo") { reset() }
                PrimaryButton(title: "Done") { dismiss() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .glassCard(radius: Theme.Radius.lg, padding: 22, tint: Theme.Palette.accent)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Advanced (raw frames)

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Raw notifications from the scale, newest first. Useful if calibration can't find the weight field.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 6)

                ForEach(scale.frames.prefix(20)) { frame in
                    HStack(alignment: .top, spacing: 8) {
                        Text(frame.time, format: .dateTime.minute().second())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(frame.hex)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                if scale.frames.isEmpty {
                    Text("No frames captured yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        } label: {
            Text("Advanced — raw data")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    // MARK: - Logic

    private func capture() {
        guard let frame = scale.latestFrame, let value = Double(entry), value > 0 else { return }
        Haptics.tap()
        samples.append((frame, value))
        entry = ""
        failure = nil

        guard samples.count >= 2 else { return }

        if let config = ScaleDecoder.solveTwoPoint(
            frameA: samples[0].frame, valueA: samples[0].value,
            frameB: samples[1].frame, valueB: samples[1].value,
            unit: unit
        ) {
            scale.save(config: config)
            withAnimation(Theme.Motion.spring) { solved = config }
            Haptics.success()
        } else {
            failure = "Couldn't identify the weight in those readings. Make sure you used two clearly different weights and that the scale had settled each time."
            samples.removeAll()
        }
    }

    private func reset() {
        withAnimation(Theme.Motion.spring) {
            samples.removeAll()
            solved = nil
            failure = nil
            entry = ""
        }
    }
}
