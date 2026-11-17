import SwiftUI

/// Floating primary action — a single FAB that fans its actions out on an arc.
///
/// Replaces the old two-pill action bar: the bottom of the screen stays empty
/// until the user asks for it, and the actions then appear within thumb reach
/// around the button they came from.
///
/// Pure action surface (no tab state). Each entry triggers a callback the
/// caller wires to `state.showModal(for:)` or similar.
///
/// - FAB:   tap or press-and-hold opens the fan; the plus rotates into an X.
/// - Fan:   Bolus is the hero (larger, mid-arc) but rests as neutral glass like
///   every other chip — the accent fill is reserved for the hover/select state.
///   Profil / Ziel are individually hideable via `showOverride` /
///   `showTempTarget` (driven from `UIUXStateModel.profileButton` /
///   `.useTargetButton`).
/// - Swipe: sliding a finger across the open fan highlights the entry
///   underneath (accent tint + scale + selection haptic); releasing there
///   triggers it.
/// - Scrim: dims and blurs everything behind the fan; tap it to close.
struct AuroraRadialMenu: View {
    let glucose: Double // drives FAB / hero color
    @Binding var isOpen: Bool

    var showOverride: Bool = true
    var showTempTarget: Bool = true
    /// Tint Profil / Ziel in the live status color when one is currently
    /// running, so the fan surfaces what's bending the loop at a glance.
    var profileActive: Bool = false
    var targetActive: Bool = false
    let onCarbs: () -> Void
    let onBolus: () -> Void
    /// Optional long-press on the bolus item — wired to Quick-Pick Boluses.
    /// A tap still opens the normal bolus screen.
    var onBolusLongPress: (() -> Void)? = nil
    let onDataTable: () -> Void
    let onStatistics: () -> Void
    let onProfile: () -> Void
    let onTarget: () -> Void
    let onAIHub: () -> Void
    let onSettings: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var pressing = false
    @State private var ringGrow = false
    /// Entry the finger is currently over during a swipe across the open fan —
    /// its chip lights up; releasing there triggers it.
    @State private var hoveredID: String? = nil

    private var status: AuroraGlucoseStatus { AuroraGlucoseStatus(mgdl: glucose) }

    // MARK: - Geometry

    private static let fabSize: CGFloat = 68
    private static let fabRadius: CGFloat = 23

    /// Arc radius and angular span. Both widen a little once Profil *and* Ziel
    /// are on (8 entries), so the chips keep their gaps instead of crowding.
    private var arcRadius: CGFloat { actions.count > 7 ? 160 : 152 }
    private var arcSpan: Double { actions.count > 7 ? 178 : 172 }

    // MARK: - Actions

    /// One entry on the arc.
    private struct FanAction: Identifiable {
        let id: String
        let label: String
        let icon: String
        var primary = false
        var tint: Color? = nil
        var longPress: (() -> Void)? = nil
        let action: () -> Void
    }

    /// Left-to-right along the arc, starting at the bottom-left arm: the two
    /// treatment entries (Carbs, Bolus) lead on the left where the thumb rests,
    /// the passive views follow, Einstellungen closes the arc bottom-right.
    private var actions: [FanAction] {
        var list: [FanAction] = [
            FanAction(
                id: "carbs",
                label: NSLocalizedString("Carbs", comment: "Aurora radial menu label"),
                icon: "fork.knife",
                action: onCarbs
            ),
            FanAction(
                id: "bolus",
                label: NSLocalizedString("Bolus", comment: "Aurora radial menu label"),
                icon: "syringe.fill",
                primary: true,
                longPress: onBolusLongPress,
                action: onBolus
            ),
            FanAction(
                id: "history",
                label: hubT("aur.fan.history"),
                icon: "clock.arrow.circlepath",
                action: onDataTable
            ),
            FanAction(
                id: "stats",
                label: NSLocalizedString("Statistics", comment: "Aurora radial menu label"),
                icon: "chart.pie.fill",
                action: onStatistics
            )
        ]
        if showOverride {
            list.append(FanAction(
                id: "profile",
                label: hubT("aur.profile"),
                icon: "person.fill",
                tint: profileActive ? status.main : nil,
                action: onProfile
            ))
        }
        if showTempTarget {
            // Short label — "Temporäres Ziel" (aur.tt) would collide with the
            // neighbouring chips' labels on the arc.
            list.append(FanAction(
                id: "target",
                label: hubT("aur.fan.target"),
                icon: "target",
                tint: targetActive ? status.main : nil,
                action: onTarget
            ))
        }
        list.append(FanAction(id: "aihub", label: "AI Hub", icon: "sparkles", action: onAIHub))
        list.append(FanAction(
            id: "settings",
            label: NSLocalizedString("Settings", comment: "Aurora radial menu label"),
            icon: "gearshape.fill",
            action: onSettings
        ))
        return list
    }

    /// Position of entry `index` on the arc, relative to the FAB center.
    private func offset(for index: Int) -> CGSize {
        let count = actions.count
        guard count > 1 else { return .zero }
        let step = arcSpan / Double(count - 1)
        let radians = (-arcSpan / 2 + Double(index) * step) * .pi / 180
        return CGSize(
            width: arcRadius * sin(radians),
            height: -arcRadius * cos(radians)
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            if isOpen { scrim }

            ZStack {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    fanItem(action, index: index)
                }
                fab
            }
            .frame(width: Self.fabSize, height: Self.fabSize)
            .coordinateSpace(name: "fan")
            // Swipe-to-select: sliding a finger across the open fan highlights
            // the entry underneath; lifting there triggers it. Simultaneous so
            // the chips' plain taps keep working.
            .simultaneousGesture(fanDragGesture)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.3), value: isOpen)
    }

    // MARK: - Swipe-to-select

    /// Tracks the finger across the fan (in the "fan" coordinate space, whose
    /// origin is the FAB's bounding box). Only swipes count as selection on
    /// release — short taps stay with the chips' own tap gestures, otherwise
    /// both would fire for the same touch.
    private var fanDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("fan"))
            .onChanged { value in
                guard isOpen else { return }
                let hit = hitTest(value.location)
                if hit != hoveredID {
                    if hit != nil { UISelectionFeedbackGenerator().selectionChanged() }
                    hoveredID = hit
                }
            }
            .onEnded { value in
                defer { hoveredID = nil }
                guard isOpen else { return }
                let travel = hypot(value.translation.width, value.translation.height)
                guard travel > 12,
                      let id = hitTest(value.location),
                      let action = actions.first(where: { $0.id == id })
                else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                close()
                action.action()
            }
    }

    /// Entry whose chip contains the point, or nil between chips.
    private func hitTest(_ point: CGPoint) -> String? {
        let fabCenter = CGPoint(x: Self.fabSize / 2, y: Self.fabSize / 2)
        for (index, action) in actions.enumerated() {
            let position = offset(for: index)
            let center = CGPoint(x: fabCenter.x + position.width, y: fabCenter.y + position.height)
            let reach: CGFloat = (action.primary ? 58 : 52) / 2 + 6
            if hypot(point.x - center.x, point.y - center.y) <= reach {
                return action.id
            }
        }
        return nil
    }

    // MARK: - Scrim

    private var scrim: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(scrimTint)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .transition(.opacity)
            .accessibilityLabel(Text(NSLocalizedString("Close", comment: "Aurora radial menu scrim")))
            .accessibilityAddTraits(.isButton)
    }

    private var scrimTint: Color {
        scheme == .dark
            ? Color(red: 4 / 255, green: 6 / 255, blue: 10 / 255).opacity(0.62)
            : Color(red: 226 / 255, green: 231 / 255, blue: 240 / 255).opacity(0.55)
    }

    // MARK: - Fan

    @ViewBuilder private func fanItem(_ action: FanAction, index: Int) -> some View {
        let target = offset(for: index)
        let size: CGFloat = action.primary ? 58 : 52
        let hovered = hoveredID == action.id

        VStack(spacing: 6) {
            chip(action, size: size, hovered: hovered)
                .scaleEffect(hovered ? 1.12 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovered)
            Text(action.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AuroraPalette.textPrimary(scheme))
                .fixedSize()
                .shadow(color: labelShadow, radius: 6, x: 0, y: 1)
                // Nudged toward the fan's (empty) center axis so long labels
                // clear the next chip further down the arc.
                .offset(x: -target.width / arcRadius * 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            close()
            action.action()
        }
        .modifier(OptionalLongPress(perform: action.longPress.map { press in
            {
                close()
                press()
            }
        }))
        // Collapsed, every entry sits scaled-down under the FAB, so opening
        // reads as the actions coming *out of* the button.
        .offset(isOpen ? target : .zero)
        .scaleEffect(isOpen ? 1 : 0.35)
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .animation(fanAnimation(index: index), value: isOpen)
        .accessibilityLabel(Text(action.label))
        .accessibilityAddTraits(.isButton)
    }

    /// Staggered spring — entries arrive left to right on open, and leave
    /// together on close so the fan doesn't linger.
    private func fanAnimation(index: Int) -> Animation {
        .spring(response: 0.34, dampingFraction: 0.68)
            .delay(isOpen ? Double(index) * 0.02 : 0)
    }

    /// All chips rest as neutral glass — the hero (Bolus) is only bigger, not
    /// pre-lit. Hovering tints the icon in the status color; the tile itself
    /// stays glass for every entry, hero included.
    @ViewBuilder private func chip(_ action: FanAction, size: CGFloat, hovered: Bool) -> some View {
        if action.primary {
            Image(systemName: action.icon)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(hovered ? status.main : AuroraPalette.textPrimary(scheme))
                .frame(width: size, height: size)
                .auroraGlass(radius: 19)
        } else {
            Image(systemName: action.icon)
                .font(.system(size: 22, weight: hovered || action.tint != nil ? .semibold : .regular))
                .foregroundStyle(hovered ? status.main : (action.tint ?? AuroraPalette.textPrimary(scheme)))
                .frame(width: size, height: size)
                .auroraGlass(radius: 18)
        }
    }

    private var labelShadow: Color {
        scheme == .dark ? Color.black.opacity(0.6) : Color.white.opacity(0.9)
    }

    // MARK: - FAB

    private var fab: some View {
        ZStack {
            if pressing { pressRing }

            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.white)
                .rotationEffect(.degrees(isOpen ? 45 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isOpen)
                .frame(width: Self.fabSize, height: Self.fabSize)
                .background(
                    RoundedRectangle(cornerRadius: Self.fabRadius, style: .continuous)
                        .fill(accentGradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.fabRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                        )
                        .shadow(color: status.main.opacity(0.5), radius: 15, x: 0, y: 10)
                )
                .scaleEffect(isOpen || pressing ? 0.9 : 1)
                .animation(.spring(response: 0.18, dampingFraction: 0.5), value: pressing)
                .animation(.spring(response: 0.18, dampingFraction: 0.5), value: isOpen)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.fabRadius, style: .continuous))
        // A plain tap toggles too, so the control stays discoverable without
        // knowing about the hold.
        .onTapGesture { toggle() }
        .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing = $0 }, perform: { toggle() })
        .accessibilityLabel(Text(NSLocalizedString("Actions", comment: "Aurora radial menu FAB")))
        .accessibilityAddTraits(.isButton)
    }

    /// Expanding ring that confirms the hold is registering.
    private var pressRing: some View {
        RoundedRectangle(cornerRadius: 27, style: .continuous)
            .stroke(status.main, lineWidth: 3)
            .frame(width: Self.fabSize + 8, height: Self.fabSize + 8)
            .scaleEffect(ringGrow ? 1.65 : 0.85)
            .opacity(ringGrow ? 0 : 0.55)
            .allowsHitTesting(false)
            .onAppear {
                ringGrow = false
                withAnimation(.easeOut(duration: 0.32)) { ringGrow = true }
            }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [status.main, AuroraPalette.deepened(status.main)],
            startPoint: UnitPoint(x: 0.33, y: 0),
            endPoint: UnitPoint(x: 0.67, y: 1)
        )
    }

    // MARK: - Open / close

    private func toggle() {
        UIImpactFeedbackGenerator(style: isOpen ? .light : .medium).impactOccurred()
        isOpen.toggle()
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
    }
}

/// Attaches a long-press only when the caller supplied one — a `nil` handler
/// must leave the plain tap gesture untouched.
private struct OptionalLongPress: ViewModifier {
    let perform: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let perform = perform {
            content.onLongPressGesture(minimumDuration: 0.5) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                perform()
            }
        } else {
            content
        }
    }
}
