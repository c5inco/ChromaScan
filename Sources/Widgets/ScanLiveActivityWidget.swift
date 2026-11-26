import ActivityKit
import SwiftUI
import WidgetKit

struct ScanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScanLiveActivityAttributes.self) { context in
            LockScreenScanLiveActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.84))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        PigmentPassBadgeView(
                            phase: context.state.phase,
                            progress: context.state.progress,
                            size: 28,
                            cornerRadius: 7
                        )
                        Text("\(context.attributes.resolutionDPI) DPI")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailingView(context: context)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(phaseTitle(for: context.state.phase))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let progress = context.state.progress, !context.state.isTerminal {
                            PigmentProgressBar(progress: progress)
                        }

                        HStack(spacing: 8) {
                            Text(primaryDetailLine(context: context))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Spacer(minLength: 8)

                            if !context.state.isTerminal {
                                liveTimerView(context: context, foreground: .secondary)
                            }
                        }

                        Text("\(context.attributes.scannerName) · \(context.attributes.colorProfileName) · \(context.attributes.outputFormatName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                CompactPoppyLeadingView(phase: context.state.phase)
            } compactTrailing: {
                compactTrailingView(context: context)
            } minimal: {
                MinimalPoppyView(phase: context.state.phase, progress: context.state.progress)
            }
            .keylineTint(phaseTint(for: context.state.phase))
        }
    }

    // MARK: - Dynamic Island Helpers

    @ViewBuilder
    private func expandedTrailingView(context: ActivityViewContext<ScanLiveActivityAttributes>) -> some View {
        switch context.state.phase {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        case .scanning:
            if let pct = context.state.progressPercent {
                Text("\(pct)%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(ChromaTheme.cream)
            } else {
                ProgressView()
                    .tint(ChromaTheme.cream)
            }
        case .starting, .processing:
            ProgressView()
                .tint(ChromaTheme.cream)
        }
    }

    @ViewBuilder
    private func compactTrailingView(context: ActivityViewContext<ScanLiveActivityAttributes>) -> some View {
        switch context.state.phase {
        case .completed:
            Text("Done")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Text("Err")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        case .scanning:
            if let pct = context.state.progressPercent {
                Text("\(pct)%")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ChromaTheme.cream)
                    .lineLimit(1)
            } else {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(ChromaTheme.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 54, alignment: .trailing)
            }
        case .starting, .processing:
            Text(context.attributes.startedAt, style: .timer)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(ChromaTheme.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 54, alignment: .trailing)
        }
    }
}

// MARK: - Living Pigment-Pass Poppy Badge

private struct PigmentPassBadgeView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let phase: ScanLiveActivityPhase
    let progress: Double?
    let size: CGFloat
    let cornerRadius: CGFloat

    private var revealFraction: CGFloat {
        switch phase {
        case .starting:
            return 0.14
        case .scanning:
            if let progress {
                return CGFloat(min(0.95, max(0.08, progress)))
            }
            return 0.50
        case .processing, .completed:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    private var showsScannerBeam: Bool {
        phase == .starting || phase == .scanning
    }

    var body: some View {
        ZStack {
            // Unscanned warm-paper poppy (muted, awaiting scanner bar)
            Image("PoppyPaper")
                .resizable()
                .scaledToFill()
                .saturation(0.18)
                .brightness(-0.28)

            // Scanned region revealed in vivid Display P3 color above the beam
            if revealFraction > 0 {
                Image("PoppyPaper")
                    .resizable()
                    .scaledToFill()
                    .saturation(isLuminanceReduced ? 0.65 : 1.0)
                    .brightness(isLuminanceReduced ? -0.10 : 0.0)
                    .mask(alignment: .top) {
                        Rectangle()
                            .frame(height: size * revealFraction)
                    }
            }

            // Live glowing cyan scanner beam gliding down with progress
            if showsScannerBeam {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: max(0, size * revealFraction - 1.5))

                    ZStack {
                        if !isLuminanceReduced {
                            Rectangle()
                                .fill(Color.cyan.opacity(0.65))
                                .frame(height: 5)
                                .blur(radius: 2.5)
                        }
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.95), .cyan],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 2)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(isLuminanceReduced ? 0.12 : 0.22), lineWidth: 0.75)
        }
        .overlay(alignment: .bottomTrailing) {
            if phase == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: max(11, size * 0.34), weight: .bold))
                    .foregroundStyle(.white, .green)
                    .offset(x: 2, y: 2)
            } else if phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: max(11, size * 0.34), weight: .bold))
                    .foregroundStyle(.white, .orange)
                    .offset(x: 2, y: 2)
            }
        }
    }
}

// MARK: - Dynamic Island Poppy Slots

private struct CompactPoppyLeadingView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let phase: ScanLiveActivityPhase

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("PoppyCutout")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .saturation(phase == .failed ? 0.25 : (isLuminanceReduced ? 0.65 : 1.0))

            if phase == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white, .green)
                    .offset(x: 2, y: 2)
            } else if phase == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white, .orange)
                    .offset(x: 2, y: 2)
            }
        }
    }
}

private struct MinimalPoppyView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let phase: ScanLiveActivityPhase
    let progress: Double?

    var body: some View {
        ZStack {
            if phase == .completed {
                Circle()
                    .stroke(Color.green, lineWidth: 2)
            } else if phase == .failed {
                Circle()
                    .stroke(Color.orange, lineWidth: 2)
            } else if let progress {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1.0, max(0.04, progress))))
                    .stroke(
                        ChromaTheme.cream.opacity(isLuminanceReduced ? 0.7 : 1.0),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .stroke(ChromaTheme.cream.opacity(0.45), lineWidth: 1.5)
            }

            Image("PoppyCutout")
                .resizable()
                .scaledToFit()
                .padding(3.5)
                .saturation(phase == .failed ? 0.25 : (isLuminanceReduced ? 0.65 : 1.0))
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Vermilion-to-Cyan Progress Bar

private struct PigmentProgressBar: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let progress: Double

    private var clamped: CGFloat {
        CGFloat(min(1.0, max(0.0, progress)))
    }

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(4, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                ChromaTheme.vermilion.opacity(isLuminanceReduced ? 0.65 : 1.0),
                                Color.cyan.opacity(isLuminanceReduced ? 0.75 : 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 4.5)
    }
}

// MARK: - Lock Screen / Banner View

private struct LockScreenScanLiveActivityView: View {
    let context: ActivityViewContext<ScanLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                PigmentPassBadgeView(
                    phase: context.state.phase,
                    progress: context.state.progress,
                    size: 44,
                    cornerRadius: 11
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(lockScreenTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(context.attributes.scannerName) · \(context.attributes.colorProfileName) · \(context.attributes.outputFormatName)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                trailingBadge
            }

            if let progress = context.state.progress, !context.state.isTerminal {
                PigmentProgressBar(progress: progress)
            }

            HStack(spacing: 8) {
                Text(primaryDetailLine(context: context))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if !context.state.isTerminal {
                    liveTimerView(context: context, foreground: Color.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var lockScreenTitle: String {
        switch context.state.phase {
        case .starting, .scanning:
            return "Scanning · \(context.attributes.resolutionDPI) DPI"
        case .processing:
            return "Processing & Saving"
        case .completed:
            return "Scan Complete"
        case .failed:
            return "Scan Failed"
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        switch context.state.phase {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        case .scanning:
            if let pct = context.state.progressPercent {
                Text("\(pct)%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(ChromaTheme.cream)
            } else {
                ProgressView()
                    .tint(ChromaTheme.cream)
            }
        case .starting, .processing:
            ProgressView()
                .tint(ChromaTheme.cream)
        }
    }
}

// MARK: - Shared Formatting & Tint

private func phaseTitle(for phase: ScanLiveActivityPhase) -> String {
    switch phase {
    case .starting: return "Starting Scan"
    case .scanning: return "Scanning"
    case .processing: return "Processing"
    case .completed: return "Scan Complete"
    case .failed: return "Scan Failed"
    }
}

private func phaseTint(for phase: ScanLiveActivityPhase) -> Color {
    switch phase {
    case .starting, .scanning:
        return ChromaTheme.vermilion
    case .processing:
        return ChromaTheme.cream
    case .completed:
        return .green
    case .failed:
        return .orange
    }
}

private func primaryDetailLine(context: ActivityViewContext<ScanLiveActivityAttributes>) -> String {
    switch context.state.phase {
    case .completed:
        if let filename = context.state.filename, let detail = context.state.detailText, !detail.isEmpty {
            return "\(filename) · \(detail)"
        }
        return context.state.statusText
    case .failed:
        if let detail = context.state.detailText, !detail.isEmpty {
            return detail
        }
        return context.state.statusText
    case .starting, .scanning, .processing:
        return context.state.statusText
    }
}

@ViewBuilder
private func liveTimerView<S: ShapeStyle>(
    context: ActivityViewContext<ScanLiveActivityAttributes>,
    foreground: S
) -> some View {
    if context.state.phase == .scanning,
       let endTs = context.state.estimatedEndTimestamp {
        let endDate = Date(timeIntervalSince1970: endTs)
        let startDate = min(context.attributes.startedAt, endDate)
        Text("~\(Text(timerInterval: startDate...endDate, countsDown: true)) left")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 108, alignment: .trailing)
    } else {
        Text(context.attributes.startedAt, style: .timer)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 84, alignment: .trailing)
    }
}
