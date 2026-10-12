import SwiftUI

/// Pick what your gym actually has; the plan is generated using only that,
/// substituting equivalent movements for any missing machine.
struct EquipmentBuilderView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onPlan: (WorkoutPlan) -> Void

    @State private var selected: Set<String> = []
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tap everything your gym has. The plan will only use what you pick, and swap in alternatives that train the same muscles for anything missing.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let errorMessage {
                            InlineMessage(kind: .error, text: errorMessage)
                        }

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(WorkoutCatalog.equipmentOptions, id: \.name) { item in
                                equipmentTile(item.name, item.icon)
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)

                PrimaryButton(
                    title: selected.isEmpty ? "Pick your equipment" : "Build my plan (\(selected.count))",
                    icon: "wand.and.stars",
                    isLoading: isGenerating,
                    enabled: !selected.isEmpty
                ) {
                    Task { await generate() }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Your gym")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func equipmentTile(_ name: String, _ icon: String) -> some View {
        let isOn = selected.contains(name)
        return Button {
            Haptics.tap()
            withAnimation(Theme.Motion.snappy) {
                if isOn { selected.remove(name) } else { selected.insert(name) }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isOn ? Theme.Palette.accent.opacity(0.12) : Theme.Palette.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .strokeBorder(isOn ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.hairline,
                                          lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        do {
            let plan = try await env.ai.generateWorkout(
                goal: env.profile?.goal.label ?? "general fitness",
                level: levelString(env.profile),
                sex: env.profile?.sex.label ?? "unspecified",
                context: contextString(env.profile),
                equipment: Array(selected).sorted()
            )
            Haptics.success()
            onPlan(plan)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }
}
