import SwiftUI

/// Returns a globally time-based pulse value between 0 and 1.
///
/// Border and symbols use the same clock, so separate views pulse in sync.
private func auroraPulseProgress(at date: Date) -> CGFloat {
    let halfCycle = 1.2
    let fullCycle = halfCycle * 2

    let elapsed = date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: fullCycle)

    let progress = elapsed / halfCycle
    return progress <= 1
        ? CGFloat(progress)
        : CGFloat(2 - progress)
}

private struct AuroraCriticalPulseModifier: ViewModifier {
    let active: Bool
    let color: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let pulse = auroraPulseProgress(at: context.date)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                color.opacity(0.38 + 0.62 * pulse),
                                lineWidth: 1.2 + 1.2 * pulse
                            )
                            .shadow(
                                color: color.opacity(0.18 + 0.57 * pulse),
                                radius: 2 + 6 * pulse
                            )
                            .scaleEffect(1 + 0.015 * pulse)
                            .allowsHitTesting(false)
                    }
                }
            }
    }
}

private struct AuroraCriticalSymbolPulseModifier: ViewModifier {
    let active: Bool
    let maximumScale: CGFloat

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let pulse = auroraPulseProgress(at: context.date)

                content
                    .scaleEffect(1 + (maximumScale - 1) * pulse)
            }
        } else {
            content
        }
    }
}

extension View {
    func auroraCriticalPulse(
        active: Bool,
        color: Color = .red,
        cornerRadius: CGFloat = 12
    ) -> some View {
        modifier(
            AuroraCriticalPulseModifier(
                active: active,
                color: color,
                cornerRadius: cornerRadius
            )
        )
    }

    func auroraCriticalSymbolPulse(
        active: Bool,
        maximumScale: CGFloat = 1.10
    ) -> some View {
        modifier(
            AuroraCriticalSymbolPulseModifier(
                active: active,
                maximumScale: maximumScale
            )
        )
    }
}
