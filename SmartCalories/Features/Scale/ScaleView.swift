import SwiftUI

struct ScaleView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showCalibration = false

    private var scale: ScaleService { env.scale }

    var body: some View {
        ScreenScaffold(title: "Scale", subtitle: scale.state.label) {
            content
        } trailing: {
            CircleIconButton(icon: "slider.horizontal.3") { showCalibration = true }
        }
        .screenBackground()
        .sheet(isPresented: $showCalibration) { CalibrationView() }
        .onAppear { scale.activate() }
    }

    @ViewBuilder
    private var content: some View {
        liveReadout

        if let error = scale.lastError {
            InlineMessage(kind: .error, text: error)
        }

        if scale.state == .poweredOff {
            InlineMessage(kind: .info, text: "Turn on Bluetooth to connect your scale.")
        }

        connectionControls

        if !scale.discovered.isEmpty {
            SectionHeader(title: "Nearby devices")
            VStack(spacing: 8) {
                ForEach(scale.discovered) { device in
                    deviceRow(device)
                }
            }
        }

        calibrationCard
    }

    // MARK: - Live readout

    private var liveReadout: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(scale.isConnected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 8, height: 8)
                    .glow(scale.isConnected ? Theme.Palette.accent : .clear, radius: 6, opacity: 0.9)
                Text(scale.isConnected ? (scale.connectedName ?? "Connected") : "Not connected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scale.isConnected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Spacer()
                if scale.isConnected, let reading = scale.reading, reading.isStable {
                    BadgePill(icon: "checkmark.circle.fill", text: "Stable", tint: Theme.Palette.accent)
                }
            }

            Text(scale.reading?.display ?? "—")
                .font(.numeric(72, .heavy))
                .foregroundStyle(scale.isConnected ? AnyShapeStyle(Theme.Grad.accent)
                                                   : AnyShapeStyle(Theme.Palette.textTertiary))
                .contentTransition(.numericText())
                .animation(Theme.Motion.snappy, value: scale.grams)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(scale.reading?.unit.label ?? "grams")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.textSecondary)

            if scale.isConnected && scale.reading == nil {
                Text("Connected — put something on the scale to see a reading.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(radius: Theme.Radius.lg, padding: 22)
    }

    // MARK: - Controls

    private var connectionControls: some View {
        HStack(spacing: 10) {
            if scale.state == .scanning {
                SecondaryButton(title: "Stop", icon: "stop.fill") { scale.stopScan() }
            } else {
                PrimaryButton(title: scale.isConnected ? "Scan again" : "Find my scale",
                              icon: "dot.radiowaves.left.and.right") {
                    scale.startScan()
                }
            }
            if scale.isConnected {
                SecondaryButton(title: "Disconnect") { scale.disconnect() }
                    .frame(width: 130)
            }
        }
    }

    private func deviceRow(_ device: ScaleService.Discovered) -> some View {
        Button {
            Haptics.tap()
            scale.connect(device)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "scalemass.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.Palette.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(signalLabel(device.rssi))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .glassCard(radius: Theme.Radius.md, padding: 12)
        }
        .buttonStyle(PressableStyle())
    }

    private func signalLabel(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: "Excellent signal"
        case (-70)..<(-55): "Good signal"
        default: "Weak signal · move closer"
        }
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Works with most scales")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Text("Kitchen scales don't publish how they encode weight. Put two known weights on yours, tell the app what the display says, and it works out the format automatically.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecondaryButton(title: "Calibrate my scale", icon: "slider.horizontal.3") {
                showCalibration = true
            }
            .padding(.top, 2)
        }
        .glassCard()
    }
}
