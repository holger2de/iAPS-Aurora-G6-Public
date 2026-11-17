import CoreData
import SwiftUI
import Swinject

extension Home {
    /// The Aurora skin's home screen — glassmorphism redesign.
    /// Replaces the previous Breathe layout. Reuses `Home.StateModel`,
    /// `HomeProvider`, and the existing routing.
    struct AuroraHomeRootView: BaseView {
        let resolver: Resolver

        @StateObject var state: StateModel
        @State private var toast: String? = nil
        @State private var showRunLoopConfirm = false
        @State private var showStatusPopup = false
        @State private var displayAutoHistory = false
        @State private var displayDynamicHistory = false
        @State private var showOverrideDetail = false
        @State private var showCancelTempTargetAlert = false
        @State private var showExpirationAlert = false
        @State private var showQuickBolusPicker = false
        @State private var showQuickBolusNoHistory = false

        // Split-Bolus-Erinnerung aus dem AI-Hub-Mahlzeitenberater: Countdown-
        // Pille im freien Bereich. `reminderTick` treibt die Sekunden-Aktua-
        // lisierung, `laterReminder` fängt neu gesetzte/abgelaufene Reminder.
        @State private var laterReminder: AIHubMealSim.PendingReminder?
        @State private var reminderTick = Date()
        @State private var showCancelReminderDialog = false
        private let reminderTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        // Backup first-run prompt is handled centrally in Main.RootView so the
        // home view never instantiates on a fresh install. No Onboarding
        // FetchRequest or fullScreenCover needed here.

        @FetchRequest(
            entity: OverridePresets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)],
            predicate: NSPredicate(format: "name != %@", "" as String)
        ) private var fetchedProfiles: FetchedResults<OverridePresets>

        @FetchRequest(
            entity: Override.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) private var fetchedPercent: FetchedResults<Override>

        @FetchRequest(
            entity: Auto_ISF.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) private var fetchedAISF: FetchedResults<Auto_ISF>

        @FetchRequest(
            entity: InsulinConcentration.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)]
        ) private var concentration: FetchedResults<InsulinConcentration>

        @Environment(\.colorScheme) private var scheme
        @Environment(\.scenePhase) private var scenePhase

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        // MARK: - Derived view-model

        private var glucoseValue: Double {
            Double(state.recentGlucose?.glucose ?? 100)
        }

        private var glucoseDelta: Int? { state.glucoseDelta }

        /// Age of the latest CGM sample. Uses the same timestamp that feeds the chart.
        private var latestGlucoseAgeText: String {
            guard let date = state.recentGlucose?.dateString else { return "—" }
            let seconds = max(0, reminderTick.timeIntervalSince(date))
            let minutes = Int(seconds / 60)
            if minutes < 1 { return "gerade eben" }
            if minutes < 60 { return "vor \(minutes) min" }
            return "vor \(minutes / 60) h"
        }

        private var latestGlucoseClockText: String {
            guard let date = state.recentGlucose?.dateString else { return "" }
            return date.formatted(date: .omitted, time: .shortened)
        }

        /// Time since the most recent CGM sample.
        private var latestGlucoseAgeSeconds: TimeInterval? {
            guard let date = state.recentGlucose?.dateString else { return nil }
            return max(0, reminderTick.timeIntervalSince(date))
        }

        /// CGM connection warning begins after ten minutes without a new value.
        private var sensorConnectionWarning: Bool {
            guard let age = latestGlucoseAgeSeconds else { return true }
            return age >= 10 * 60
        }

        /// More than twenty minutes without CGM data is safety-critical.
        private var sensorConnectionCritical: Bool {
            guard let age = latestGlucoseAgeSeconds else { return true }
            return age >= 20 * 60
        }

        private var sensorConnectionColor: Color {
            if let warmupEndDate = state.g6SensorWarmupEndDate,
               warmupEndDate > reminderTick
            {
                return AuroraPalette.textPrimary(scheme)
            }

            if sensorConnectionCritical { return .red }
            if sensorConnectionWarning { return .orange }
            return sensorAgeColor
        }

        private var sensorConnectionText: String {
            if let warmupEndDate = state.g6SensorWarmupEndDate,
               warmupEndDate > reminderTick
            {
                let remaining = max(0, warmupEndDate.timeIntervalSince(reminderTick))
                let totalSeconds = Int(remaining.rounded(.up))
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                let seconds = totalSeconds % 60

                if hours > 0 {
                    return String(format: "Aufwärmen %d:%02d:%02d", hours, minutes, seconds)
                }

                return String(format: "Aufwärmen %02d:%02d", minutes, seconds)
            }

            guard sensorConnectionWarning else {
                return state.sensorAgeText
            }

            guard let seconds = latestGlucoseAgeSeconds else {
                return "Kein Wert"
            }

            let minutes = Int(seconds / 60)
            if minutes < 60 {
                return "vor \(minutes) min"
            }

            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return remainingMinutes == 0
                ? "vor \(hours) h"
                : "vor \(hours) h \(remainingMinutes) min"
        }

        private var glucoseTrendSymbol: String {
            switch state.recentGlucose?.direction {
            case .doubleUp,
                 .tripleUp: return "arrow.up"
            case .fortyFiveUp,
                 .singleUp: return "arrow.up.right"
            case .flat: return "arrow.right"
            case .fortyFiveDown,
                 .singleDown: return "arrow.down.right"
            case .doubleDown,
                 .tripleDown: return "arrow.down"
            default: return "minus"
            }
        }

        /// Anubis may intentionally run longer than ten days. Therefore age >10 d
        /// is a yellow advisory, not an expiry error. A red noise state will be
        /// added once Aurora exposes a reliable CGM-noise value in Home.StateModel.
        private var sensorAgeColor: Color {
            guard state.sensorAgeText != "—" else {
                return AuroraPalette.textMuted(scheme)
            }

            if state.usesXDripAppGroupCGM {
                guard let age = state.sensorAgeSeconds else {
                    return AuroraPalette.textMuted(scheme)
                }

                let warningAge = state.sensorDays * 86400
                guard warningAge > 0 else { return .green }

                return age >= warningAge ? .yellow : .green
            }

            if state.isAnubisTransmitter {
                guard let age = state.sensorAgeSeconds else {
                    return AuroraPalette.textMuted(scheme)
                }

                return age >= 10 * 86400 ? .yellow : .green
            }

            guard let remaining = state.sensorRemainingSeconds else {
                return .green
            }

            if remaining <= 6 * 3600 {
                return .red
            }

            if remaining <= 24 * 3600 {
                return .orange
            }

            return .green
        }

        /// Metrics are calculated from the glucose samples already loaded for
        /// the home chart. No Nightscout request or additional persistence is
        /// introduced by the dashboard.
        private var dashboardGlucoseSamples: [Double] {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            return state.data.glucose.compactMap { sample in
                guard
                    sample.dateString >= cutoff,
                    let glucose = sample.glucose,
                    glucose > 0
                else {
                    return nil
                }

                return Double(glucose)
            }
        }

        private var dashboardTIRText: String {
            let samples = dashboardGlucoseSamples
            guard !samples.isEmpty else { return "—" }
            let inRange = samples.filter { $0 >= 70 && $0 <= 180 }.count
            return "\(Int((Double(inRange) / Double(samples.count) * 100).rounded()))%"
        }

        private var dashboardGMIText: String {
            let samples = dashboardGlucoseSamples
            guard !samples.isEmpty else { return "—" }
            let mean = samples.reduce(0, +) / Double(samples.count)
            let gmi = 3.31 + 0.02392 * mean
            return String(format: "%.1f%%", gmi).replacingOccurrences(of: ".", with: ",")
        }

        private var loopStatus: AuroraLoopStatus {
            if state.errorMessage != nil { return .error }
            if state.isLooping { return .looping }
            let age = Date().timeIntervalSince(state.lastLoopDate)
            if age > 15 * 60 { return .stale }
            return .ok
        }

        private var loopAgeSeconds: TimeInterval {
            guard state.lastLoopDate != .distantPast else {
                return .infinity
            }

            return max(0, Date().timeIntervalSince(state.lastLoopDate))
        }

        private var loopStatusCritical: Bool {
            if state.errorMessage != nil {
                return true
            }

            guard state.closedLoop else {
                return false
            }

            return loopAgeSeconds >= 20 * 60
        }

        private var loopStatusWarning: Bool {
            if loopStatusCritical {
                return true
            }

            guard state.closedLoop else {
                return true
            }

            return loopAgeSeconds >= 10 * 60
        }

        private var loopStatusColor: Color {
            if loopStatusCritical {
                return .red
            }

            if state.isLooping {
                return .blue
            }

            if !state.closedLoop || loopStatusWarning {
                return .orange
            }

            return .green
        }

        private var loopStatusText: String {
            if state.errorMessage != nil {
                return "Fehler"
            }

            if state.isLooping {
                return "Loop läuft"
            }

            if !state.closedLoop {
                return "Open"
            }

            if state.lastLoopDate == .distantPast {
                return "Kein Loop"
            }

            if loopAgeSeconds >= 20 * 60 {
                return "Loop zu alt"
            }

            if loopAgeSeconds >= 10 * 60 {
                return ">10 min"
            }

            return "Closed"
        }

        private var loopLastRunText: String {
            guard state.lastLoopDate != .distantPast else {
                return "noch kein Loop"
            }

            if state.isLooping {
                return "läuft gerade"
            }

            let seconds = max(0, Date().timeIntervalSince(state.lastLoopDate))
            let minutes = Int(seconds / 60)

            if minutes < 1 {
                return "gerade eben"
            }

            if minutes < 60 {
                return "vor \(minutes) min"
            }

            let hours = minutes / 60
            let remainingMinutes = minutes % 60

            if remainingMinutes == 0 {
                return "vor \(hours) h"
            }

            return "vor \(hours) h \(remainingMinutes) min"
        }

        private var loopCaption: String {
            let age = Date().timeIntervalSince(state.lastLoopDate)
            if state.lastLoopDate == .distantPast { return "Loop · —" }
            let mins = Int(age / 60)
            if mins < 1 { return hubT("aur.loop.now") }
            if mins < 60 { return hubT("aur.loop.minago", mins) }
            let hours = mins / 60
            return hubT("aur.loop.hago", hours)
        }

        private var sensorCaption: String? {
            // Preserve the existing remaining-time display when explicitly
            // requested or when sensor expiry is less than 24 hours away.
            if !state.usesXDripAppGroupCGM,
               let info = state.calculateSensorInfo(),
               state.displayExpiration || info.expiresIn <= 24 * 3600
            {
                return info.text.replacingOccurrences(of: "Sensor: ", with: "")
            }

            // Otherwise show the actual sensor age with day/hour precision.
            if let age = state.sensorAgeSeconds {
                let days = Int(age / 86400)
                let hours = Int(age.truncatingRemainder(dividingBy: 86400) / 3600)

                if days > 0 {
                    return "\(days) T \(hours) h"
                }

                return "\(hours) h"
            }

            // Fallback only when no session start date is available.
            let days = Int(state.sensorDays.rounded())
            return days > 0 ? "\(days) Tg" : nil
        }

        /// Active Insulin (IOB) — comes from the current ChartModel snapshot.
        /// (`state.iobs` is a cumulative loop-stats sum across history and is
        /// NOT what should appear in the badge.)
        private var iobString: String {
            let v = Double(truncating: (state.data.iob ?? 0) as NSNumber)
            return String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
        }

        /// Carbs on board (COB) — from the latest suggestion.
        /// (`state.carbData` is a cumulative sum and would over-count.)
        private var cobString: String {
            let v = Int(state.data.suggestion?.cob ?? 0)
            return "\(v)"
        }

        private var autoISFString: String {
            let ratio = state.data.suggestion?.sensitivityRatio ?? 1
            let value = NSDecimalNumber(decimal: ratio).doubleValue
            return String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
        }

        private var currentBasalString: String {
            let rate = state.tempRate ?? 0
            let value = NSDecimalNumber(decimal: rate).doubleValue
            return String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
        }

        /// Insulin concentration factor (1.0 = U100, 2.0 = U200, …).
        private var insulinConcentration: Double {
            concentration.last?.concentration ?? 1
        }

        /// Pods can't report an exact reservoir level above 50 U — the pump
        /// layer substitutes this sentinel (see KnownPlugins.pumpReservoir).
        private static let reservoirSentinel = Decimal(0xDEAD_BEEF)

        /// Omnipod and Medtrum show the reservoir level as a filled silhouette in
        /// the icon slot (pod / nano asset); the numeric amount stays as the
        /// value to its right. Dana and Medtronic keep the cylinder icon.
        private var isOmnipod: Bool {
            state.pumpName.contains("Omni")
        }

        private var isMedtrum: Bool {
            state.pumpName.contains("Medtrum")
        }

        /// Filled pod/nano silhouette for the pump tile's icon slot, tinted with
        /// the glucose status color. `nil` for Dana/Medtronic (cylinder icon) or
        /// when no reservoir is known.
        private var pumpIconGraphic: AnyView? {
            guard let r = state.reservoir else { return nil }
            let color = pumpVisualColor
            // Real capacity so the fill is linear: Medtrum Nano is 200 U or 300 U,
            // Omnipod 200 U. Falls back to 200 if the pump didn't report one.
            let capacity = NSDecimalNumber(decimal: state.reservoirCapacity).doubleValue
            if isOmnipod {
                return AnyView(AuroraReservoirGraphic(
                    reservoir: r, fillColor: color, assetBase: "pod",
                    capacity: capacity, aspect: 0.72, yOffset: 2.5
                ))
            }
            if isMedtrum {
                // Nano PNG is a square (900×900) canvas with transparent padding,
                // so keep a 1:1 aspect — forcing the silhouette ratio would squash
                // the square horizontally (too narrow).
                return AnyView(AuroraReservoirGraphic(
                    reservoir: r, fillColor: color, assetBase: "nano",
                    capacity: capacity, aspect: 1.0, yOffset: 2.5
                ))
            }
            return nil
        }

        private var reservoirString: String {
            guard let r = state.reservoir else { return "—" }
            let conc = insulinConcentration
            // Pod sentinel: show a capped "50+" (scaled for concentration),
            // mirroring PumpView, instead of formatting the raw sentinel int.
            if r == Self.reservoirSentinel {
                return String(format: "%.0f+", 50 * conc)
            }
            // Reservoir is stored U100-equivalent; scale to the real delivered
            // units for diluted/concentrated insulin (e.g. U200 → ×2).
            let scaled = r * Decimal(conc)
            return String(format: "%.0f", NSDecimalNumber(decimal: scaled).doubleValue)
        }

        private var reservoirDeliveredUnits: Double? {
            guard let reservoir = state.reservoir,
                  reservoir != Self.reservoirSentinel
            else {
                return nil
            }

            let storedUnits = NSDecimalNumber(decimal: reservoir).doubleValue
            return storedUnits * insulinConcentration
        }

        /// Verhältnis aus aktuellem Reservoir und gemeldeter Pumpenkapazität.
        /// Beide Werte liegen auf derselben internen Konzentrationsbasis.
        /// Die sichtbare Reservoiranzeige bleibt davon unberührt und zeigt
        /// weiterhin immer die tatsächlich verfügbaren Einheiten.
        private var reservoirFraction: Double? {
            guard let reservoir = state.reservoir,
                  reservoir != Self.reservoirSentinel
            else {
                return nil
            }

            let current = NSDecimalNumber(decimal: reservoir).doubleValue
            let capacity = NSDecimalNumber(decimal: state.reservoirCapacity).doubleValue

            guard current >= 0, capacity > 0 else {
                return nil
            }

            return min(max(current / capacity, 0), 1)
        }

        private var reservoirWarning: Bool {
            guard let fraction = reservoirFraction else {
                return false
            }

            return fraction <= 0.20
        }

        private var reservoirCritical: Bool {
            guard let fraction = reservoirFraction else {
                return false
            }

            return fraction <= 0.05
        }

        private var reservoirColor: Color {
            guard let fraction = reservoirFraction else {
                return .cyan
            }

            if fraction <= 0.10 {
                return .red
            }

            if fraction <= 0.20 {
                return .orange
            }

            return .cyan
        }

        /// Farbe des Pumpensymbols:
        /// kritischer/niedriger Reservoirstand hat Vorrang,
        /// ansonsten folgt es dem aktuellen Pumpenstatus.
        private var pumpVisualColor: Color {
            if reservoirWarning {
                return reservoirColor
            }

            return pumpStatusColor
        }

        private var pumpCardCritical: Bool {
            pumpStatusCritical || reservoirCritical
        }

        /// Red "U200"-style badge text when a non-standard concentration is set
        /// and the user hasn't hidden it. `nil` for standard U100.
        private var reservoirBadge: String? {
            guard insulinConcentration != 1,
                  !state.settingsManager.settings.hideInsulinBadge
            else { return nil }
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return "U" + (f.string(from: insulinConcentration * 100 as NSNumber) ?? "")
        }

        /// Pods/patches keep delivering for a grace period after their nominal
        /// expiry. `pumpExpiresAtDate` is that *nominal* expiry: Omnipod reports
        /// `podState.expiresAt` (activatedAt + nominalPodLife, 72 h) and Medtrum is
        /// normalised to its grace-period start in `KnownPlugins`. Both pumps then
        /// have an 8 h grace window afterwards, so surface a "Grace" countdown
        /// instead of jumping straight to "Replace".
        private static let pumpGracePeriod: TimeInterval = 8 * 3600

        private var pumpSub: String? {
            guard let exp = state.pumpExpiresAtDate else { return nil }
            let interval = exp.timeIntervalSinceNow
            guard interval > 0 else {
                let graceLeft = Self.pumpGracePeriod + interval
                guard graceLeft > 0 else { return hubT("aur.pump.replace") }
                if graceLeft < 3600 { return hubT("aur.pump.grace", "\(Int(graceLeft / 60)) min") }
                return hubT("aur.pump.grace", "\(Int(graceLeft / 3600)) h")
            }
            // Under an hour the "0 T 0 h" readout is useless — switch to minutes.
            if interval < 3600 {
                return "\(Int(interval / 60)) min"
            }
            let days = Int(interval / 86400)
            let hours = Int((interval - Double(days) * 86400) / 3600)
            return "\(days) T \(hours) h"
        }

        /// Imminent pump/pod expiry warning for the pump tile's leading shield.
        /// `show` once ≤ 8 h of life remain (or expired), `pulsing` once < 2 h
        /// remain (or expired). Returns nil when no expiry date is reported.
        private var pumpExpiryWarning: (show: Bool, pulsing: Bool) {
            guard let exp = state.pumpExpiresAtDate else { return (false, false) }
            let interval = exp.timeIntervalSinceNow
            guard interval <= 8 * 3600 else { return (false, false) }
            return (true, interval < 2 * 3600)
        }

        // MARK: - Ring-corner pills (gated via UIUX toggles)

        /// Top-left: sensor — age or time-remaining depending on UIUX toggles,
        /// auto-surfaces when expiry is within 24 h regardless of toggles.
        /// The icon keeps the standard color; the exclamation-mark shield
        /// signals imminent expiry.
        ///
        /// Fallback: if the CGM did not report a `sessionStartDate` (so
        /// `calculateSensorInfo()` returns nil), we still show the configured
        /// sensor lifespan as a coarse "Xd" pill so the corner isn't empty.
        private var sensorInfo: (text: String, color: Color)? {
            if let info = state.calculateSensorInfo() {
                let nearExpiry =
                    !state.usesXDripAppGroupCGM &&
                    info.expiresIn <= 24 * 3600
                let showPill = state.displaySAGE || state.displayExpiration || nearExpiry
                guard showPill else { return nil }
                let text = info.text.replacingOccurrences(of: "Sensor: ", with: "")
                // No color escalation (red/orange/amber): tints read poorly on
                // light backgrounds and the exclamation-mark shield already
                // signals the upcoming change. Always use the standard icon color.
                return (text, AuroraPalette.textPrimary(scheme))
            }
            // Fallback when sessionStartDate is missing
            guard state.displaySAGE || state.displayExpiration else { return nil }
            let days = Int(state.sensorDays.rounded())
            guard days > 0 else { return nil }
            return ("\(days)d", AuroraPalette.textPrimary(scheme))
        }

        /// Imminent sensor expiry warning for the sensor pill's shield.
        /// `show` once ≤ 12 h of session remain (or expired) — sensors run for
        /// days, so we warn earlier than the pump. `pulsing` once < 2 h remain.
        private var sensorExpiryWarning: (show: Bool, pulsing: Bool) {
            guard !state.usesXDripAppGroupCGM else { return (false, false) }
            guard let info = state.calculateSensorInfo() else { return (false, false) }
            let interval = info.expiresIn
            guard interval <= 12 * 3600 else { return (false, false) }
            return (true, interval < 2 * 3600)
        }

        /// Top-right: predicted eventual glucose from the latest suggestion.
        private var eventualBGText: String? {
            guard state.displayeventualBG, let eventual = state.eventualBG else { return nil }
            if state.data.units == .mmolL {
                let v = Double(eventual) * 0.0555
                return String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
            }
            return "\(eventual)"
        }

        /// Bottom-left: current temp basal rate.
        private var tbrText: String? {
            guard state.displayTBR else { return nil }
            let rate = state.tempRate.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
            let formatted = String(format: "%.2f", rate).replacingOccurrences(of: ".", with: ",")
            return "\(formatted) E/h"
        }

        /// Bottom-right: autosens sensitivity ratio.
        private var isfText: String? {
            guard state.isfView else { return nil }
            let ratio = state.data.suggestion?.sensitivityRatio ?? 1
            let v = NSDecimalNumber(decimal: ratio).doubleValue
            return String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
        }

        // MARK: - Active override / temp-target badges (below the stat row)

        private var profileActive: Bool {
            fetchedPercent.first?.enabled ?? false
        }

        /// Compact label for the active-profile badge (mirrors breath's logic).
        private var profileBadgeText: String {
            guard let override = fetchedPercent.first, override.enabled else {
                return hubT("aur.profile")
            }
            if override.isPreset {
                if let profile = fetchedProfiles.first(where: { $0.id == override.id }),
                   let name = profile.name, !name.isEmpty, name != "EMPTY", name != "\u{0022}\u{0022}"
                {
                    return name.count > 14 ? String(name.prefix(14)) : name
                }
                return hubT("aur.profile")
            }
            if override.percentage != 100 {
                return "\(Int(override.percentage)) %"
            }
            if override.smbIsOff {
                return "No SMB"
            }
            return "Override"
        }

        private var tempTargetString: String? {
            state.tempTarget?.displayNameWithEndTime
        }

        /// True when the currently active override forces AutoISF on.
        private var aisfEnabledByOverride: Bool {
            guard let or = fetchedPercent.first, or.enabled else { return false }
            guard let aisf = fetchedAISF.first(where: { $0.id == or.id }) else { return false }
            return aisf.autoisf
        }

        /// True when the currently active override forces AutoISF off.
        private var aisfDisabledByOverride: Bool {
            guard let or = fetchedPercent.first, or.enabled else { return false }
            guard let aisf = fetchedAISF.first(where: { $0.id == or.id }) else { return false }
            return !aisf.autoisf
        }

        /// Open the right history sheet on ISF-pill tap — AutoISF if active,
        /// Dynamic ISF otherwise. Same dispatching the breath skin used.
        private func openISFHistory() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if (state.autoisf && !aisfDisabledByOverride) || aisfEnabledByOverride {
                displayAutoHistory = true
            } else {
                displayDynamicHistory = true
            }
        }

        // MARK: - Body

        private var compactHeightLayout: Bool {
            UIScreen.main.bounds.height < 900
        }

        var body: some View {
            ZStack {
                AuroraBackground()

                if compactHeightLayout {
                    VStack(spacing: 6) {
                        auroraProTitleBar
                            .padding(.horizontal, 12)

                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 6) {
                                proTopBar
                                auroraProStatusStrip
                                proSectionHeader(number: 2, title: "HAUPTGRAPH", accent: .purple)
                                AuroraProChart(
                                    data: state.data,
                                    displayBasal: state.displayMainChartBasalRate,
                                    displayCarbs: state.displayChartCarbs,
                                    displayBoluses: state.displayChartBoluses,
                                    glucoseNow: glucoseValue
                                )
                                proMetricsGrid
                                proActionGrid
                                reminderPill
                                    .padding(.top, 4)
                                    .animation(.easeInOut(duration: 0.3), value: laterReminder)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 72)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            auroraProTitleBar
                            proTopBar
                            auroraProStatusStrip
                            proSectionHeader(number: 2, title: "HAUPTGRAPH", accent: .purple)
                            AuroraProChart(
                                data: state.data,
                                displayBasal: state.displayMainChartBasalRate,
                                displayCarbs: state.displayChartCarbs,
                                displayBoluses: state.displayChartBoluses,
                                glucoseNow: glucoseValue
                            )
                            proMetricsGrid
                            proActionGrid
                            reminderPill
                                .padding(.top, 4)
                                .animation(.easeInOut(duration: 0.3), value: laterReminder)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                AuroraToast(message: $toast)

                VStack {
                    Spacer()

                    bolusOverlay
                        .padding(.horizontal, 12)
                        .padding(.bottom, 88)
                }
                .allowsHitTesting(state.bolusProgress != nil)
                .animation(.easeInOut(duration: 0.22), value: state.bolusProgress)
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
            .ignoresSafeArea(.keyboard)
            .onAppear { laterReminder = AIHubMealSim.pendingReminder() }
            .onReceive(reminderTimer) { now in
                reminderTick = now
                // Fängt neu gesetzte (aus dem AI-Hub-Sheet) und abgelaufene
                // Erinnerungen — die Pille erscheint/verschwindet von selbst.
                let current = AIHubMealSim.pendingReminder()
                if current != laterReminder { laterReminder = current }
            }
            .confirmationDialog(
                hubT("aur.reminder.cancel.title"),
                isPresented: $showCancelReminderDialog,
                titleVisibility: .visible
            ) {
                Button(hubT("aur.reminder.cancel.action"), role: .destructive) {
                    AIHubMealSim.cancelPendingReminder()
                    laterReminder = nil
                }
                Button(hubT("aur.reminder.keep"), role: .cancel) {}
            }
            .confirmationDialog(
                hubT("aur.loop.confirm"),
                isPresented: $showRunLoopConfirm,
                titleVisibility: .visible
            ) {
                Button(hubT("aur.loop.run")) {
                    state.runLoop()
                    toast = hubT("aur.loop.started")
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .sheet(isPresented: $showOverrideDetail) {
                overrideDetailSheet
                    .presentationDetents([.height(420), .medium])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                hubT("aur.tt.confirm"),
                isPresented: $showCancelTempTargetAlert,
                titleVisibility: .visible
            ) {
                Button(hubT("aur.tt.end"), role: .destructive) {
                    state.cancelTempTarget()
                    toast = hubT("aur.tt.ended")
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .sheet(isPresented: $showStatusPopup) {
                AuroraStatusSheet(state: state)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $displayAutoHistory) {
                AutoISFHistoryView(units: state.data.units)
                    .environment(\.colorScheme, scheme)
            }
            .sheet(isPresented: $displayDynamicHistory) {
                DynamicHistoryView(units: state.data.units)
                    .environment(\.colorScheme, scheme)
            }
            .sheet(isPresented: $showQuickBolusPicker) {
                QuickPickBolusesView(
                    suggestions: state.quickBolusHistory,
                    onEnact: { amount in await state.enactQuickBolus(amount: amount) },
                    isPresented: $showQuickBolusPicker
                )
                .environment(\.colorScheme, scheme)
            }
            .alert(
                hubT("qb.nohistory.title"),
                isPresented: $showQuickBolusNoHistory
            ) {
                Button(hubT("qb.ok"), role: .cancel) {}
            } message: {
                Text(hubT("qb.nohistory.body"))
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    state.startTimer()
                    state.refreshPumpStatus()
                    checkBuildExpiration()
                case .background,
                     .inactive: state.stopTimer()
                default: break
                }
            }
            .onAppear {
                state.refreshPumpStatus()
                checkBuildExpiration()
            }
            .alert(
                BuildExpirationManager.shared.alertTitle,
                isPresented: $showExpirationAlert
            ) {
                Button("OK", role: .cancel) {}
                Button(hubT("aur.moreinfo")) {
                    if let url = URL(string: "https://github.com/Artificial-Pancreas/iAPS/releases") {
                        UIApplication.shared.open(url)
                    }
                }
            } message: {
                Text(BuildExpirationManager.shared.alertMessage)
            }
        }

        // MARK: - Aurora Pro dashboard

        private var auroraProTitleBar: some View {
            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    state.showModal(for: .settings)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .semibold))
                }

                Text("AURORA")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("PRO")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.purple)
                    .padding(.leading, -7)

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showStatusPopup = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 19, weight: .semibold))
                }
            }
            .foregroundStyle(AuroraPalette.textPrimary(scheme))
            .padding(.horizontal, 4)
        }

        /// The compact top dashboard follows the approved Aurora Pro mock-up:
        /// TIR and GMI on the left, CGM in the centre, Loop and Sensor on the right.
        private var proTopBar: some View {
            HStack(spacing: 7) {
                proHeaderMetric(title: "TIR", value: dashboardTIRText, unit: "24 h", accent: .green)
                proHeaderMetric(title: "GMI", value: dashboardGMIText, unit: "24 h", accent: .cyan)

                VStack(spacing: 1) {
                    Text(state.cgmDisplayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.purple)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(formattedHeaderGlucose)
                            .font(.system(size: 48, weight: .heavy, design: .rounded))
                            .kerning(-1.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                            .monospacedDigit()
                            .layoutPriority(2)
                        Image(systemName: glucoseTrendSymbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AuroraGlucoseStatus(mgdl: glucoseValue).main)
                    }

                    Text(formattedHeaderDelta)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(AuroraGlucoseStatus(mgdl: glucoseValue).main)
                        .monospacedDigit()

                    Text(
                        latestGlucoseClockText
                            .isEmpty ? latestGlucoseAgeText : "\(latestGlucoseAgeText) (\(latestGlucoseClockText))"
                    )
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AuroraPalette.textMuted(scheme))
                    .monospacedDigit()
                }
                .foregroundStyle(AuroraPalette.textPrimary(scheme))
                .frame(minWidth: 102, maxWidth: .infinity)
                .layoutPriority(2)
                .padding(.vertical, 7)
                .padding(.horizontal, 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.purple.opacity(0.32), lineWidth: 1)
                }

                VStack(spacing: 4) {
                    Text("Loop")
                        .font(.system(size: 11.5, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(loopStatusColor)
                            .frame(width: 6, height: 6)
                        Text(loopStatusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(loopStatusColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    Text(loopLastRunText)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            loopStatusWarning
                                ? loopStatusColor
                                : AuroraPalette.textMuted(scheme)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .monospacedDigit()
                }
                .frame(width: 62)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            loopStatusWarning
                                ? loopStatusColor.opacity(0.14)
                                : Color.clear
                        )
                }
                .auroraCriticalPulse(
                    active: loopStatusCritical,
                    color: .red,
                    cornerRadius: 12
                )
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first:
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                showRunLoopConfirm = true

                            case .second:
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showStatusPopup = true
                            }
                        }
                )
                .padding(.trailing, 2)

                VStack(spacing: 5) {
                    Text(sensorConnectionWarning ? "LETZTER WERT" : "Sensor")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(
                            sensorConnectionWarning
                                ? sensorConnectionColor
                                : sensorConnectionColor
                        )

                    Text(
                        sensorConnectionWarning
                            ? sensorConnectionText
                            : (sensorCaption ?? "—")
                    )
                    .font(
                        .system(
                            size: sensorConnectionWarning ? 10 : 12,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(sensorConnectionColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .monospacedDigit()

                    Image(
                        systemName: sensorConnectionCritical
                            ? "exclamationmark.triangle.fill"
                            : "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        sensorConnectionWarning
                            ? sensorConnectionColor
                            : sensorConnectionColor
                    )
                    .auroraCriticalSymbolPulse(
                        active: sensorConnectionCritical,
                        maximumScale: 1.10
                    )
                }
                .frame(width: 62)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            sensorConnectionWarning
                                ? sensorConnectionColor.opacity(0.14)
                                : Color.clear
                        )
                }
                .auroraCriticalPulse(
                    active: sensorConnectionCritical,
                    color: .red,
                    cornerRadius: 12
                )
            }
            .padding(8)
            .auroraGlass(radius: 15)
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if state.alarm == nil { state.openCGM() }
                else { state.showModal(for: .snooze) }
            }
        }

        private func proHeaderMetric(title: String, value: String, unit: String, accent: Color) -> some View {
            AuroraProHeaderMetric(
                title: title,
                value: value,
                footer: unit,
                accent: accent,
                scheme: scheme
            )
        }

        private func proSectionHeader(number: Int, title: String, accent: Color) -> some View {
            AuroraProSectionHeader(number: number, title: title, accent: accent)
        }

        /// Pump status plus the compact operating metrics directly above the chart.
        /// Loop status remains visible in the hero card; the former Closed/Open
        /// Loop chip is replaced by useful pump information.
        private var auroraProStatusStrip: some View {
            VStack(spacing: 7) {
                pumpStatusRow

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        statusChip(
                            icon: "arrow.up.right",
                            title: "AutoISF",
                            value: "×\(autoISFString)",
                            accent: .purple
                        ) {
                            openISFHistory()
                        }

                        if profileActive {
                            statusChip(
                                icon: "shield.fill",
                                title: "Override",
                                value: profileBadgeText,
                                accent: .orange
                            ) {
                                showOverrideDetail = true
                            }
                        }

                        if let target = tempTargetString {
                            statusChip(
                                icon: "scope",
                                title: "Target",
                                value: target,
                                accent: .purple
                            ) {
                                showCancelTempTargetAlert = true
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollClipDisabled()
            }
        }

        private var pumpBolusActive: Bool {
            guard let status = state.pumpManagerStatus else {
                return false
            }

            switch status.bolusState {
            case .initiating,
                 .inProgress:
                return true
            case .canceling,
                 .noBolus:
                return false
            }
        }

        private var pumpSymbolPulsing: Bool {
            pumpCardCritical || pumpBolusActive
        }

        private var pumpStatusCritical: Bool {
            guard let status = state.pumpManagerStatus else {
                return true
            }

            return status.deliveryIsUncertain
        }

        private var pumpStatusColor: Color {
            guard let status = state.pumpManagerStatus else {
                return .red
            }

            if status.deliveryIsUncertain {
                return .red
            }

            switch status.bolusState {
            case .initiating,
                 .inProgress:
                return .blue
            case .canceling:
                return .orange
            case .noBolus:
                break
            }

            switch status.basalDeliveryState {
            case .resuming,
                 .suspended,
                 .suspending:
                return .orange
            case .active,
                 .cancelingTempBasal,
                 .initiatingTempBasal,
                 .tempBasal:
                return .green
            case nil:
                return .orange
            }
        }

        private var pumpStatusText: String {
            guard let status = state.pumpManagerStatus else {
                return state.pumpDisplayState == nil
                    ? "Nicht verbunden"
                    : "Keine Statusdaten"
            }

            if status.deliveryIsUncertain {
                return "Abgabe unsicher"
            }

            switch status.bolusState {
            case .initiating,
                 .inProgress:
                return "Bolus läuft"
            case .canceling:
                return "Bolus stoppt"
            case .noBolus:
                break
            }

            switch status.basalDeliveryState {
            case .suspended:
                return "Suspendiert"
            case .suspending:
                return "Suspendiert …"
            case .resuming:
                return "Wird fortgesetzt …"
            case .active,
                 .cancelingTempBasal,
                 .initiatingTempBasal,
                 .tempBasal:
                return "Verbunden"
            case nil:
                return "Status unbekannt"
            }
        }

        /// Verstrichene Zeit seit der tatsächlichen Aktivierung des
        /// aktuellen Medtrum-Patches.
        private var medtrumPatchElapsed: TimeInterval? {
            guard isMedtrum,
                  let activatedAt = state.pumpActivationDate
            else {
                return nil
            }

            return max(0, Date().timeIntervalSince(activatedAt))
        }

        private var medtrumPatchRuntimeText: String? {
            guard let elapsed = medtrumPatchElapsed else {
                return nil
            }

            let totalMinutes = max(0, Int(elapsed / 60))
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60

            return "\(days) Tg \(hours) h"
        }

        private var medtrumPatchRuntimeColor: Color {
            guard medtrumPatchElapsed != nil else {
                return AuroraPalette.textMuted(scheme)
            }

            guard let expiresAt = state.pumpExpiresAtDate else {
                return AuroraPalette.textPrimary(scheme)
            }

            let remaining = expiresAt.timeIntervalSince(Date())

            if remaining <= 6 * 60 * 60 {
                return .red
            }

            if remaining <= 24 * 60 * 60 {
                return .orange
            }

            return .green
        }

        private var pumpStatusRow: some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if state.pumpDisplayState != nil {
                    state.setupPump = true
                }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let graphic = pumpIconGraphic {
                            graphic
                                .frame(width: 30, height: 34)
                        } else {
                            Image(systemName: "cylinder.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(pumpVisualColor)
                                .frame(width: 30, height: 34)
                        }
                    }
                    .auroraCriticalSymbolPulse(
                        active: pumpSymbolPulsing,
                        maximumScale: pumpCardCritical ? 1.10 : 1.055
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text("PUMPE")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cyan)

                        Text(state.pumpName.isEmpty ? "—" : state.pumpName)
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(AuroraPalette.textPrimary(scheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reservoir")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraPalette.textMuted(scheme))

                        HStack(spacing: 4) {
                            Text("\(reservoirString) E")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundStyle(reservoirColor)
                                .monospacedDigit()

                            if let badge = reservoirBadge {
                                Text(badge)
                                    .font(.system(size: 7, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if let patchRuntime = medtrumPatchRuntimeText {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Laufzeit")
                                .font(
                                    .system(
                                        size: 10.5,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(
                                    AuroraPalette.textMuted(scheme)
                                )

                            Text(patchRuntime)
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .bold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(
                                    medtrumPatchRuntimeColor
                                )
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Status")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraPalette.textMuted(scheme))

                        HStack(spacing: 4) {
                            Circle()
                                .fill(pumpStatusColor)
                                .frame(width: 6, height: 6)

                            Text(pumpStatusText)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(pumpStatusColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AuroraPalette.textMuted(scheme))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cyan.opacity(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.cyan.opacity(0.42), lineWidth: 1)
                }
                .auroraCriticalPulse(
                    active: pumpCardCritical,
                    color: .red,
                    cornerRadius: 14
                )
            }
            .buttonStyle(.plain)
            .disabled(state.pumpDisplayState == nil)
        }

        private func statusChip(
            icon: String,
            title: String,
            value: String,
            accent: Color,
            action: (() -> Void)? = nil
        ) -> some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action?()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 12, alignment: .center)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent.opacity(0.95))
                            .lineLimit(1)

                        Text(value)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(AuroraPalette.textPrimary(scheme))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 0)
                }
                .frame(minWidth: 92, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(scheme == .dark ? 0.045 : 0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(accent.opacity(0.045))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(accent.opacity(0.42), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
        }

        private var proMetricsGrid: some View {
            HStack(spacing: 6) {
                AuroraProMetricCard(
                    title: "IOB",
                    value: iobString,
                    unit: "E",
                    icon: "drop.fill",
                    accent: .blue,
                    scheme: scheme
                )

                AuroraProMetricCard(
                    title: "COB",
                    value: cobString,
                    unit: "g",
                    icon: "carrot.fill",
                    accent: .orange,
                    scheme: scheme
                )

                AuroraProMetricCard(
                    title: "AutoISF",
                    value: autoISFString,
                    unit: "×",
                    icon: "arrow.up.right",
                    accent: .purple,
                    scheme: scheme
                )

                AuroraProMetricCard(
                    title: "Basal",
                    value: currentBasalString,
                    unit: "E/h",
                    icon: "waveform.path.ecg",
                    accent: .cyan,
                    scheme: scheme
                )
            }
        }

        /// All frequently used actions live directly on the dashboard.
        /// This removes the extra FAB/radial-menu tap while preserving the
        /// same routes and Quick-Bolus behaviour.
        private var proActionGrid: some View {
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    quickAction(title: "BOLUS", subtitle: "Insulin", icon: "syringe.fill", accent: .blue) {
                        state.showModal(for: .bolus(waitForSuggestion: true, fetch: false))
                    }
                    quickAction(title: "KH EINGABE", subtitle: "Carbs", icon: "apple.logo", accent: .green) {
                        state.showModal(for: .addCarbs(editMode: false, override: false, mode: .meal))
                    }
                    quickAction(title: "TEMP TARGET", subtitle: "Ziel", icon: "scope", accent: .purple) {
                        if state.tempTarget != nil { showCancelTempTargetAlert = true }
                        else { state.showModal(for: .addTempTarget) }
                    }
                    quickAction(title: "OVERRIDE", subtitle: "Loop", icon: "shield.fill", accent: .orange) {
                        if profileActive { showOverrideDetail = true }
                        else { state.showModal(for: .overrideProfilesConfig) }
                    }
                }

                HStack(spacing: 7) {
                    quickAction(title: "QUICK BOLUS", subtitle: "Schnell", icon: "bolt.fill", accent: .blue) {
                        guard state.enableQuickBolus else {
                            state.showModal(for: .bolus(waitForSuggestion: true, fetch: false))
                            return
                        }
                        state.loadQuickBolusSuggestions()
                        if state.quickBolusHistory.isEmpty {
                            showQuickBolusNoHistory = true
                        } else {
                            showQuickBolusPicker = true
                        }
                    }
                    quickAction(title: "DATEN", subtitle: "Tabelle", icon: "tablecells", accent: .cyan) {
                        state.showModal(for: .dataTable)
                    }
                    quickAction(title: "STATISTIK", subtitle: "Auswertung", icon: "chart.bar.fill", accent: .green) {
                        state.showModal(for: .statistics)
                    }
                    quickAction(title: "AI HUB", subtitle: "Assistent", icon: "sparkles", accent: .purple) {
                        state.showModal(for: .aiHub)
                    }
                }
            }
        }

        private func quickAction(
            title: String,
            subtitle: String,
            icon: String,
            accent: Color,
            action: @escaping () -> Void
        ) -> some View {
            AuroraProActionButton(
                title: title,
                subtitle: subtitle,
                icon: icon,
                accent: accent,
                action: action
            )
        }

        private var formattedHeaderGlucose: String {
            if state.data.units == .mmolL {
                return String(format: "%.1f", glucoseValue * 0.0555)
                    .replacingOccurrences(of: ".", with: ",")
            }
            return String(format: "%.0f", glucoseValue)
        }

        private var formattedHeaderDelta: String {
            guard let delta = glucoseDelta else { return "—" }
            let sign = delta > 0 ? "+" : ""
            if state.data.units == .mmolL {
                let value = Double(delta) * 0.0555
                return "\(sign)\(String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")) mmol/L"
            }
            return "\(sign)\(delta) mg/dL"
        }

        /// Throttled 90-day TestFlight build-expiration warning, mirroring the
        /// standard HomeRootView behaviour for the Aurora skin.
        private func checkBuildExpiration() {
            let manager = BuildExpirationManager.shared
            guard manager.shouldShowAlert else { return }
            manager.markAlertShown()
            showExpirationAlert = true
        }

        /// Small glass pill anchored to a corner of the Aurora ring.
        /// Used for sensor / eventual-BG / TBR / ISF when the matching toggle
        /// is on. The icon can be tinted independently of the text (e.g. for
        /// the sensor pill's expiry color).
        private func infoPill(icon: String, text: String, iconColor: Color? = nil) -> some View {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor ?? AuroraPalette.textPrimary(scheme))
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(AuroraPalette.textPrimary(scheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .auroraGlassPill()
        }

        /// "Stage" around the Aurora ring: the ring is centered in a full-width
        /// container, and the four corner pills are pinned to the SCREEN edges
        /// (not the ring frame). That gives Sensor / Eventual / TBR / ISF the
        /// same generous gutter the breath skin's StatusRow used.
        ///
        /// Tap on the ring → CGM setup (or snooze if a glucose alarm is active),
        /// long-press inverts that pair — mirrors the breath skin's behavior.
        private var ringStage: some View {
            ZStack {
                AuroraRing(
                    glucose: glucoseValue,
                    delta: glucoseDelta,
                    units: state.data.units,
                    trendCaption: nil,
                    direction: state.recentGlucose?.direction,
                    bolusProgress: state.bolusProgress.map { NSDecimalNumber(decimal: $0).doubleValue },
                    bolusTotal: state.bolusAmount.map { NSDecimalNumber(decimal: $0).doubleValue }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if state.alarm == nil {
                        state.openCGM()
                    } else {
                        state.showModal(for: .snooze)
                    }
                }
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    if state.alarm == nil {
                        state.showModal(for: .snooze)
                    } else {
                        state.openCGM()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let txt = tbrText {
                    infoPill(icon: "chart.bar", text: txt)
                        .padding(.leading, 18)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let txt = eventualBGText {
                    infoPill(icon: "arrow.right", text: txt)
                        .padding(.trailing, 18)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let s = sensorInfo {
                    infoPill(
                        icon: "sensor.tag.radiowaves.forward",
                        text: s.text,
                        iconColor: s.color
                    )
                    .overlay(alignment: .topLeading) {
                        let warning = sensorExpiryWarning
                        if warning.show {
                            PulsingWarningShield(
                                color: AuroraGlucoseStatus(mgdl: glucoseValue).main,
                                pulsing: warning.pulsing,
                                size: 16
                            )
                            .offset(x: -6, y: -8)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let txt = isfText {
                    infoPill(icon: "divide", text: txt)
                        .padding(.trailing, 18)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { openISFHistory() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.displayeventualBG)
            .animation(.easeInOut(duration: 0.25), value: state.displayTBR)
            .animation(.easeInOut(duration: 0.25), value: state.isfView)
            .animation(.easeInOut(duration: 0.25), value: state.displaySAGE)
            .animation(.easeInOut(duration: 0.25), value: state.displayExpiration)
        }

        /// Loop pill — sits centered between the ring and the chart.
        /// Tap → status sheet · long-press → run-loop confirmation.
        /// Pulsing ring around the dot while a loop is actually running.
        private var loopPill: some View {
            HStack(spacing: 8) {
                Text(loopCaption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AuroraPalette.textPrimary(scheme))
                ZStack {
                    Circle()
                        .fill(loopStatus.color)
                        .frame(width: 8, height: 8)
                        .shadow(color: loopStatus.color.opacity(0.5), radius: 6)
                    if state.isLooping {
                        Circle()
                            .stroke(loopStatus.color.opacity(0.6), lineWidth: 1)
                            .frame(width: 16, height: 16)
                            .scaleEffect(state.isLooping ? 1.4 : 1.0)
                            .opacity(state.isLooping ? 0 : 0.8)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: state.isLooping
                            )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .auroraGlassPill()
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showStatusPopup = true
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                showRunLoopConfirm = true
            }
        }

        private var badgeRow: some View {
            HStack(spacing: 10) {
                AuroraStatBadge(
                    icon: "drop.fill",
                    iconColor: AuroraPalette.textMuted(scheme),
                    value: iobString,
                    unit: "E",
                    label: NSLocalizedString("Insulin on Board", comment: "Aurora stat badge label")
                )
                AuroraStatBadge(
                    icon: "leaf.fill",
                    iconColor: AuroraPalette.textMuted(scheme),
                    value: cobString,
                    unit: "g",
                    label: NSLocalizedString("Carbs", comment: "Aurora stat badge label")
                )
                AuroraStatBadge(
                    icon: "cylinder.fill",
                    iconColor: AuroraPalette.textMuted(scheme),
                    value: reservoirString,
                    unit: "E",
                    label: pumpSub
                        .map { "\(NSLocalizedString("Pump", comment: "Aurora stat badge label")) \($0)" }
                        ?? NSLocalizedString("Pump", comment: "Aurora stat badge label"),
                    sub: nil,
                    badge: reservoirBadge,
                    badgeColor: AuroraGlucoseStatus(mgdl: glucoseValue).main,
                    warning: pumpExpiryWarning.show,
                    warningPulsing: pumpExpiryWarning.pulsing,
                    warningColor: AuroraGlucoseStatus(mgdl: glucoseValue).main,
                    // Omnipod/Medtrum: filled pod/nano silhouette in the icon slot
                    // (fill level, tinted with the glucose status color); the
                    // amount stays as the value to its right. Dana/Medtronic nil.
                    iconOverride: pumpIconGraphic,
                    onTap: {
                        // Mirror breath: only open settings when a pump is
                        // actually connected — otherwise the modal has nothing
                        // to show.
                        if state.pumpDisplayState != nil {
                            state.setupPump = true
                        }
                    }
                )
            }
        }

        /// Live bolus banner — only visible while a bolus is delivering.
        /// Sits between the active-override badges and the floating action bar
        /// so the user always has Stop within thumb reach.
        @ViewBuilder private var bolusOverlay: some View {
            if let progress = state.bolusProgress, progress > 0,
               let amount = state.bolusAmount
            {
                AuroraBolusOverlay(
                    progress: progress,
                    delivered: amount * progress,
                    total: amount,
                    accent: AuroraGlucoseStatus(mgdl: glucoseValue).main,
                    onCancel: { state.cancelBolus() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }

        /// Two compact glass pills — visible only when a profile override or a
        /// temp target is currently active. Tap → confirmation dialog to cancel.
        /// Mirrors the breath skin's "ActiveBadge" row right under the stat
        /// cards so the user always sees what's bending the loop.
        @ViewBuilder private var activeBadgeRow: some View {
            HStack(spacing: 10) {
                if profileActive {
                    activeBadge(
                        dotColor: AuroraPalette.pump,
                        text: profileBadgeText,
                        accessibility: hubT("aur.profile.a11y")
                    ) {
                        showOverrideDetail = true
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
                if let tt = tempTargetString {
                    activeBadge(
                        dotColor: AuroraPalette.Status.inMain,
                        text: tt,
                        accessibility: hubT("aur.tt.a11y")
                    ) {
                        showCancelTempTargetAlert = true
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: profileActive)
            .animation(.easeInOut(duration: 0.25), value: tempTargetString)
        }

        // MARK: - Split-Bolus-Erinnerung (Countdown im freien Bereich)

        @ViewBuilder private var reminderPill: some View {
            if let reminder = laterReminder {
                let remaining = reminder.fireDate.timeIntervalSince(reminderTick)
                let unitsText = reminderUnitsFormatter.string(from: reminder.units as NSNumber)
                    ?? String(format: "%.2f", reminder.units)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showCancelReminderDialog = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AuroraPalette.textMuted(scheme))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hubT("aur.reminder.title", "\(unitsText) E"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AuroraPalette.textPrimary(scheme))
                            Text(reminderRemainingText(remaining))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AuroraPalette.textMuted(scheme))
                                .monospacedDigit()
                        }
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(AuroraPalette.textMuted(scheme).opacity(0.6))
                            .padding(.leading, 2)
                    }
                    // Inhaltsgroß statt volle Breite; der umschließende VStack
                    // zentriert die Pille dadurch automatisch.
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .auroraGlassPill()
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                .accessibilityLabel(Text(hubT("aur.reminder.title", "\(unitsText) E")))
            }
        }

        /// Restlaufzeit: "in 1:47 Std" ab einer Stunde, sonst "in 12 Min",
        /// unter einer Minute "gleich". Wortteile lokalisiert, Zahlen fix.
        private func reminderRemainingText(_ seconds: TimeInterval) -> String {
            let total = max(0, Int(seconds.rounded()))
            if total < 60 { return hubT("aur.reminder.soon") }
            let minutes = total / 60
            if minutes >= 60 {
                return hubT("aur.reminder.in.hours", "\(minutes / 60):" + String(format: "%02d", minutes % 60))
            }
            return hubT("aur.reminder.in.minutes", "\(minutes)")
        }

        private var reminderUnitsFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            formatter.usesGroupingSeparator = false
            return formatter
        }

        private func activeBadge(
            dotColor: Color,
            text: String,
            accessibility: String,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: dotColor.opacity(0.5), radius: 4)
                    Text(text)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AuroraPalette.textPrimary(scheme))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .auroraGlassPill()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibility))
        }

        // MARK: - Override-Detail-Sheet

        /// Zeigt, was der aktive Override tatsächlich tut — Antwort auf
        /// „was ist gerade eingeschaltet?", ohne in Settings oder Loop-Status
        /// suchen zu müssen. Beenden ist von hier aus möglich.
        @ViewBuilder private var overrideDetailSheet: some View {
            if let override = fetchedPercent.first, override.enabled {
                let preset = fetchedProfiles.first(where: { $0.id == override.id })
                let isAI = (override.id ?? "").hasPrefix("ai-")
                let targetRaw = ((override.target ?? 0) as NSDecimalNumber) as Decimal
                let aisf = fetchedAISF.first(where: { $0.id == override.id })

                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        if let emoji = preset?.emoji, !emoji.isEmpty {
                            Text(emoji).font(.title2)
                        }
                        Text(
                            (preset?.name).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (override.percentage != 100 ? "\(Int(override.percentage)) %" : "Override")
                        )
                        .font(.title3.bold())
                        if isAI {
                            Image(systemName: "sparkles")
                                .font(.subheadline)
                                .foregroundStyle(.purple)
                        }
                        Spacer()
                    }

                    VStack(spacing: 12) {
                        overrideDetailRow(hubT("aur.or.insulin"), "\(Int(override.percentage)) %")
                        overrideDetailRow(
                            hubT("aur.tt"),
                            targetRaw > 6 ? overrideTargetText(targetRaw) : hubT("aur.or.profiletarget")
                        )
                        overrideDetailRow(hubT("aur.or.remaining"), overrideRemainingText(override))
                        overrideDetailRow("SMB", override.smbIsOff ? hubT("pd.off") : hubT("pd.on"))
                        if override.overrideAutoISF, let aisf {
                            overrideDetailRow("AutoISF", aisf.autoisf ? hubT("aur.or.forcedon") : hubT("aur.or.forcedoff"))
                        }
                        if let started = override.date {
                            overrideDetailRow(
                                hubT("aur.or.since"),
                                started.formatted(date: .omitted, time: .shortened)
                            )
                        }
                    }

                    Button {
                        state.cancelProfile()
                        showOverrideDetail = false
                        toast = hubT("aur.or.ended")
                    } label: {
                        Text(hubT("aur.or.end"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.red.opacity(0.85))
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }

        private func overrideDetailRow(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
        }

        private func overrideTargetText(_ mgdl: Decimal) -> String {
            state.data.units == .mmolL
                ? "\(mgdl.asMmolL) mmol/L"
                : "\(mgdl) mg/dl"
        }

        private func overrideRemainingText(_ override: Override) -> String {
            if override.indefinite { return hubT("pd.duration.indefinite") }
            let minutes = Double(truncating: (override.duration ?? 0) as NSNumber)
            guard minutes > 0, let start = override.date else { return "—" }
            let remaining = start.addingTimeInterval(minutes * 60).timeIntervalSinceNow
            guard remaining > 0 else { return hubT("aur.or.expiring") }
            let hours = Int(remaining) / 3600
            let mins = (Int(remaining) % 3600) / 60
            return hours > 0 ? "\(hours) h \(mins) min" : "\(mins) min"
        }
    }
}

// MARK: - Bolus overlay (live banner)

/// A calm glass banner shown while a bolus is in flight. Replaces the breath
/// skin's blue-drop overlay — the live status color drives the accent so the
/// banner sits visually with the rest of the Aurora skin.
struct AuroraBolusOverlay: View {
    let progress: Decimal
    let delivered: Decimal
    let total: Decimal
    let accent: Color
    let onCancel: () -> Void

    @State private var pulse = false
    @State private var cancelPressed = false
    @StateObject private var smooth = AuroraBolusProgressAnimator()

    @Environment(\.colorScheme) private var scheme

    /// Truthful pump fraction — drives the numeric "delivered" readout.
    private var realFraction: Double {
        let p = NSDecimalNumber(decimal: progress).doubleValue
        return min(1.0, max(0.0, p))
    }

    private var deliveredString: String {
        let d = NSDecimalNumber(decimal: delivered).doubleValue
        let t = NSDecimalNumber(decimal: total).doubleValue
        return String(format: "%.2f / %.2f E", d, t)
            .replacingOccurrences(of: ".", with: ",")
    }

    private var remainingString: String {
        let d = NSDecimalNumber(decimal: delivered).doubleValue
        let t = NSDecimalNumber(decimal: total).doubleValue
        return String(format: "Rest %.2f E", max(0, t - d))
            .replacingOccurrences(of: ".", with: ",")
    }

    private var percentString: String {
        "\(Int((realFraction * 100).rounded())) %"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AuroraPalette.textMuted(scheme))
                    .scaleEffect(pulse ? 1.08 : 0.92)
                    .opacity(pulse ? 1.0 : 0.75)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulse
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(hubT("aur.bolus.running"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AuroraPalette.textPrimary(scheme))

                    HStack(spacing: 8) {
                        Text(deliveredString)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(AuroraPalette.textPrimary(scheme))
                            .monospacedDigit()
                            .contentTransition(.numericText())

                        Text(remainingString)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(AuroraPalette.textMuted(scheme))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }

                Spacer(minLength: 8)

                Text(percentString)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Button {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    withAnimation(.easeOut(duration: 0.12)) { cancelPressed = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeOut(duration: 0.25)) { cancelPressed = false }
                    }
                    onCancel()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(hubT("aur.stop"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(accent)
                            .shadow(
                                color: accent.opacity(0.35),
                                radius: cancelPressed ? 2 : 6,
                                y: cancelPressed ? 1 : 2
                            )
                    )
                    .scaleEffect(cancelPressed ? 0.96 : 1.0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(hubT("aur.bolus.stop")))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AuroraPalette.hairline(scheme).opacity(0.8))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.6), accent],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * smooth.fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .auroraGlass(radius: 18)
        .onAppear {
            pulse = true
            smooth.sync(real: realFraction, total: NSDecimalNumber(decimal: total).doubleValue)
        }
        .onChange(of: progress) { _ in
            smooth.sync(real: realFraction, total: NSDecimalNumber(decimal: total).doubleValue)
        }
    }
}

// MARK: - Status sheet (Loop details + manual loop trigger)

/// Aurora-style sheet shown when the user taps the loop pill in the top row.
/// Surfaces the current loop status, last loop time, optional error message,
/// and the suggestion's reasoning conclusion.
struct AuroraStatusSheet: View {
    @ObservedObject var state: Home.StateModel

    @Environment(\.colorScheme) private var scheme

    private var loopAccent: Color {
        if state.errorMessage != nil { return AuroraLoopStatus.error.color }
        if state.isLooping { return AuroraLoopStatus.looping.color }
        let age = Date().timeIntervalSince(state.lastLoopDate)
        return age > 15 * 60 ? AuroraLoopStatus.stale.color : AuroraLoopStatus.ok.color
    }

    private var lastLoopText: String {
        guard state.lastLoopDate != .distantPast else { return "—" }
        let mins = Int(-state.lastLoopDate.timeIntervalSinceNow / 60)
        if mins < 1 { return hubT("aur.justnow") }
        if mins < 60 { return hubT("aur.ago.min", mins) }
        return hubT("aur.ago.h", mins / 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let err = state.errorMessage {
                    errorCard(err)
                }

                statusCard
                reasoningCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .background(AuroraBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hubT("aur.loop.status"))
                .font(.system(size: 28, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(AuroraPalette.textPrimary(scheme))
            Text(hubT("aur.loop.last", lastLoopText))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AuroraPalette.textMuted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(loopAccent)
                .frame(width: 12, height: 12)
                .shadow(color: loopAccent.opacity(0.5), radius: 6)
            Text(state.statusTitle.isEmpty ? hubT("aur.ready") : state.statusTitle)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(AuroraPalette.textPrimary(scheme))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .auroraGlass(radius: 22)
    }

    @ViewBuilder private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hubT("aur.loop.failed"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AuroraLoopStatus.error.color)
            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AuroraPalette.textMuted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraGlass(radius: 22)
    }

    @ViewBuilder private var reasoningCard: some View {
        if let suggestion = state.data.suggestion {
            VStack(alignment: .leading, spacing: 12) {
                Text(hubT("aur.reason"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(AuroraPalette.textMuted(scheme))

                // Raw oref metrics as colored chips, matching Trio's Loop status popup.
                TagCloudView(tags: suggestion.reasonParts, style: .prominent)

                Text(reasoningConclusion(for: suggestion).capitalizingFirstLetter())
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AuroraPalette.textPrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .auroraGlass(radius: 22)
        }
    }

    /// The reasoning conclusion without the verbose `Auto ISF { … }` block that iAPS
    /// appends to the reason string (see OpenAPS.swift). The detailed autoISF reasoning
    /// will live in a dedicated autoISF history view; here we keep the conclusion concise
    /// like Trio's Loop status.
    private func reasoningConclusion(for suggestion: Suggestion) -> String {
        var text = suggestion.reasonConclusion
        if let range = text.range(of: "Auto ISF {") {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Aurora Pro reusable UI foundation

/// Shared visual constants for the Aurora Pro dashboard. Keeping these values
/// in one place lets the components move into separate files later without
/// changing their public interfaces.
private enum AuroraProTheme {
    static let cardRadius: CGFloat = 14
    static let compactRadius: CGFloat = 12
    static let cardBorderOpacity = 0.24
    static let cardFillOpacity = 0.08
    static let horizontalSpacing: CGFloat = 7
}

private struct AuroraProSectionHeader: View {
    let number: Int
    let title: String
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 17, height: 17)
                .background(Circle().fill(accent))

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(accent)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, -5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bereich \(number): \(title)")
    }
}

private struct AuroraProHeaderMetric: View {
    let title: String
    let value: String
    let footer: String
    let accent: Color
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))

            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)

            Text(footer)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AuroraPalette.textMuted(scheme))
        }
        .foregroundStyle(AuroraPalette.textPrimary(scheme))
        .frame(width: 45, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                .fill(accent.opacity(AuroraProTheme.cardFillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                .stroke(accent.opacity(AuroraProTheme.cardBorderOpacity), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(footer)")
    }
}

private struct AuroraProActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))

                Text(title)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                    .fill(accent.opacity(0.34))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                    .stroke(accent.opacity(0.75), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

private struct AuroraProMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let accent: Color
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AuroraPalette.textMuted(scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(AuroraPalette.textPrimary(scheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(unit)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AuroraPalette.textMuted(scheme))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                .fill(accent.opacity(AuroraProTheme.cardFillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AuroraProTheme.compactRadius, style: .continuous)
                .stroke(accent.opacity(AuroraProTheme.cardBorderOpacity), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value) \(unit)")
    }
}
