import SwiftUI

/// Celebratory banner shown when a QSO completes an award milestone (Worked
/// All States, DXCC, …). Auto-dismisses after a few seconds, or on tap.
/// Presented by ContentView from `AppState.pendingMilestones`.
struct AchievementBanner: View {
    let milestone: AwardMilestone
    var onDismiss: () -> Void

    /// Flipped on appear so the success haptic fires once per banner.
    @State private var shown = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: milestone.icon)
                .font(.title)
                .foregroundStyle(.yellow)
                .shadow(radius: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Achievement Unlocked")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(milestone.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(milestone.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(milestone.title). \(milestone.detail)"))
        .sensoryFeedback(.success, trigger: shown)
        .onAppear { shown = true }
        // Auto-dismiss is owned by AppState (tied to the milestone queue, not
        // this view instance), so re-hosting the banner when the operation
        // screen opens/closes doesn't restart the timer. Tap still dismisses.
    }
}
