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
                    HStack(spacing: 6) {
                        phaseIcon(for: context.state.phase)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(phaseTint(for: context.state.phase))
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
                            ProgressView(value: progress)
                                .tint(phaseTint(for: context.state.phase))
                        }

                        HStack(spacing: 8) {
                            Text(primaryDetailLine(context: context))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Spacer(minLength: 8)

                            if !context.state.isTerminal {
                                Text(context.attributes.startedAt, style: .timer)
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 84, alignment: .trailing)
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
                phaseIcon(for: context.state.phase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(phaseTint(for: context.state.phase))
            } compactTrailing: {
                compactTrailingView(context: context)
            } minimal: {
                minimalView(context: context)
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
                    .foregroundStyle(.cyan)
            } else {
                ProgressView()
                    .tint(.cyan)
            }
        case .starting, .processing:
            ProgressView()
                .tint(.cyan)
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
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            } else {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 54, alignment: .trailing)
            }
        case .starting, .processing:
            Text(context.attributes.startedAt, style: .timer)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 54, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func minimalView(context: ActivityViewContext<ScanLiveActivityAttributes>) -> some View {
        switch context.state.phase {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .scanning:
            if let progress = context.state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .tint(.cyan)
            } else {
                phaseIcon(for: context.state.phase)
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        case .starting, .processing:
            phaseIcon(for: context.state.phase)
                .font(.caption2)
                .foregroundStyle(.cyan)
        }
    }
}

// MARK: - Lock Screen / Banner View

private struct LockScreenScanLiveActivityView: View {
    let context: ActivityViewContext<ScanLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(phaseTint(for: context.state.phase).opacity(0.20))
                        .frame(width: 36, height: 36)
                    phaseIcon(for: context.state.phase)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(phaseTint(for: context.state.phase))
                }

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
                ProgressView(value: progress)
                    .tint(phaseTint(for: context.state.phase))
            }

            HStack(spacing: 8) {
                Text(primaryDetailLine(context: context))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if !context.state.isTerminal {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 84, alignment: .trailing)
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
                    .foregroundStyle(.cyan)
            } else {
                ProgressView()
                    .tint(.cyan)
            }
        case .starting, .processing:
            ProgressView()
                .tint(.cyan)
        }
    }
}

// MARK: - Shared Formatting & Iconography

private func phaseTitle(for phase: ScanLiveActivityPhase) -> String {
    switch phase {
    case .starting: return "Starting Scan"
    case .scanning: return "Scanning"
    case .processing: return "Processing"
    case .completed: return "Scan Complete"
    case .failed: return "Scan Failed"
    }
}

private func phaseIcon(for phase: ScanLiveActivityPhase) -> Image {
    switch phase {
    case .starting, .scanning:
        return Image(systemName: "scanner.fill")
    case .processing:
        return Image(systemName: "wand.and.stars")
    case .completed:
        return Image(systemName: "checkmark.circle.fill")
    case .failed:
        return Image(systemName: "exclamationmark.triangle.fill")
    }
}

private func phaseTint(for phase: ScanLiveActivityPhase) -> Color {
    switch phase {
    case .starting, .scanning:
        return .cyan
    case .processing:
        return .indigo
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
