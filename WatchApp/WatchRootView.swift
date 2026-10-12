import SwiftUI

private let accent = Color(red: 0.204, green: 0.831, blue: 0.600)

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @StateObject private var streamer = WatchWorkoutStreamer()

    var body: some View {
        TabView {
            todayTab.tag(0)
            liveHeartTab.tag(1)
            waterTab.tag(2)
            favoritesTab.tag(3)
        }
        .tabViewStyle(.verticalPage)
    }

    // MARK: - Live heart stream

    /// Streams the Watch's heart sensor to the iPhone app. The workout
    /// session keeps the sensor at ~1 Hz; the phone treats it exactly like a
    /// WHOOP broadcast.
    private var liveHeartTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: streamer.isStreaming)

                if let bpm = streamer.bpm {
                    Text("\(bpm)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("streaming to iPhone")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if streamer.isStreaming {
                    Text("Reading…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Stream live heart rate to the app — no WHOOP needed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let error = streamer.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    streamer.isStreaming ? streamer.stop() : streamer.start()
                } label: {
                    Text(streamer.isStreaming ? "Stop" : "Start streaming")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .tint(streamer.isStreaming ? .red : accent)
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(Color.red.gradient.opacity(0.15), for: .tabView)
    }

    // MARK: - Today

    private var todayTab: some View {
        let snap = model.snapshot
        return ScrollView {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: snap.progress)
                        .stroke(snap.eaten > snap.goal ? Color.red : accent,
                                style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.4), value: snap.progress)
                    VStack(spacing: 0) {
                        Text("\(Int(abs(snap.remaining)))")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(snap.eaten > snap.goal ? "over" : "left")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 108)

                HStack(spacing: 10) {
                    stat("Eaten", Int(snap.eaten), accent)
                    stat("Burned", Int(snap.burned), .orange)
                }

                if snap.proteinTarget > 0 {
                    stat("Protein", Int(snap.protein), .blue,
                         suffix: " / \(Int(snap.proteinTarget))g")
                }
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(accent.gradient.opacity(0.18), for: .tabView)
    }

    private func stat(_ label: String, _ value: Int, _ tint: Color, suffix: String = "") -> some View {
        VStack(spacing: 1) {
            Text("\(value)\(suffix)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Water

    private var waterTab: some View {
        let snap = model.snapshot
        return VStack(spacing: 10) {
            Text("Water").font(.headline)
            Text("\(Int(snap.waterMl)) / \(Int(snap.waterTarget)) ml")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ProgressView(value: min(snap.waterMl / max(snap.waterTarget, 1), 1))
                .tint(.cyan)

            HStack(spacing: 8) {
                ForEach([250.0, 500.0], id: \.self) { amount in
                    Button {
                        model.send(.logWater(ml: amount))
                    } label: {
                        Text("+\(Int(amount))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.cyan)
                }
            }

            if let feedback = model.lastActionFeedback {
                Text(feedback).font(.system(size: 11)).foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Favourites

    private var favoritesTab: some View {
        Group {
            if model.snapshot.favorites.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "star").font(.title3).foregroundStyle(.secondary)
                    Text("Star foods on your iPhone to quick-log them here.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                List(model.snapshot.favorites) { favorite in
                    Button {
                        model.send(.logFavorite(id: favorite.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(favorite.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(Int(favorite.grams)) g · \(Int(favorite.calories)) kcal")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
