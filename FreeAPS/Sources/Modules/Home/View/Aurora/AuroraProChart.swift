import Charts
import SwiftUI

/// Aurora Pro chart.
///
/// Independent from `AuroraMainChart`: it consumes the existing `ChartModel`
/// snapshot but owns its layout and rendering. The chart is deliberately fixed
/// to the selected 3/6/12/24 h window and does not use horizontal scrolling.
struct AuroraProChart: View {
    @ObservedObject var data: ChartModel

    var displayBasal: Bool = true
    var displayCarbs: Bool = true
    var displayBoluses: Bool = true
    let glucoseNow: Double

    @Environment(\.colorScheme) private var scheme
    @State private var panOffset: TimeInterval = 0
    @State private var dragStartOffset: TimeInterval?

    private let mainPlotHeight: CGFloat = 265
    private let basalTrackHeight: CGFloat = 58
    private let futureHours: Double = 2

    private var now: Date { Date() }
    private var chartStart: Date {
        now
            .addingTimeInterval(-Double(max(3, data.screenHours)) * 3600)
            .addingTimeInterval(panOffset)
    }

    private var chartEnd: Date {
        now
            .addingTimeInterval(futureHours * 3600)
            .addingTimeInterval(panOffset)
    }

    /// Gesamter aktuell sichtbarer Zeitraum einschließlich Vorhersage.
    private var visibleTimeSpan: TimeInterval {
        chartEnd.timeIntervalSince(chartStart)
    }

    /// Verschiebt Haupt- und Basalchart gemeinsam entlang der Zeitachse.
    private var timelinePanGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = panOffset
                }

                let chartWidth = max(UIScreen.main.bounds.width - 32, 1)
                let secondsPerPoint = visibleTimeSpan / chartWidth
                let initialOffset = dragStartOffset ?? panOffset

                let proposedOffset = initialOffset
                    - Double(value.translation.width) * secondsPerPoint

                // Der Ausgangszustand panOffset == 0 entspricht „Jetzt“.
                // Negative Werte zeigen ältere Zeiträume; positive Werte
                // würden den Chart weiter als den aktuellen Zeitraum schieben.
                let maxPastOffset: TimeInterval = -24 * 3600
                panOffset = max(maxPastOffset, min(0, proposedOffset))
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }

    private var isMmolL: Bool { data.units == .mmolL }

    /// Simulator-only visual test data. It activates only when there is no
    /// real glucose history. Physical-device builds can never enter this path.
    private var simulatorDemoEnabled: Bool {
        false
    }

    private func display(_ mgdl: Int) -> Double {
        isMmolL ? Double(mgdl) * 0.0555 : Double(mgdl)
    }

    private func display(_ value: Decimal) -> Double {
        let v = NSDecimalNumber(decimal: value).doubleValue
        return isMmolL ? v * 0.0555 : v
    }

    private var lowThreshold: Double { display(data.lowGlucose) }
    private var highThreshold: Double { display(data.highGlucose) }

    private var yLow: Double {
        let values = glucosePoints.map(\.value) + predictionSeries.flatMap(\.points).map(\.value)

        let fallback = isMmolL ? 4.0 : 70.0
        guard let minimum = values.min() else { return fallback }

        let padding = isMmolL ? 1.0 : 18.0
        let hardFloor = isMmolL ? 2.2 : 40.0
        let preferredFloor = isMmolL ? 3.0 : 55.0

        return max(hardFloor, min(preferredFloor, minimum - padding))
    }

    private var yHigh: Double {
        let values = glucosePoints.map(\.value) + predictionSeries.flatMap(\.points).map(\.value)

        let fallback = isMmolL ? 12.0 : 220.0
        guard let maximum = values.max() else { return fallback }

        let padding = isMmolL ? 1.5 : 25.0
        let preferredCeiling = isMmolL ? 12.0 : 220.0
        let hardCeiling = isMmolL ? 22.0 : 400.0

        return min(hardCeiling, max(preferredCeiling, maximum + padding))
    }

    private var status: AuroraGlucoseStatus {
        AuroraGlucoseStatus(mgdl: glucoseNow)
    }

    private func glucoseColor(for value: Double) -> Color {
        if value < lowThreshold { return .red }
        if value > highThreshold { return .orange }
        return .green
    }

    private func nearestGlucoseValue(to date: Date) -> Double? {
        glucosePoints.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.value
    }

    private struct GlucosePoint: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private var glucosePoints: [GlucosePoint] {
        if simulatorDemoEnabled { return demoGlucosePoints }

        return data.glucose
            .compactMap { reading -> GlucosePoint? in
                let date = reading.dateString
                guard date >= chartStart,
                      date <= now,
                      let raw = reading.glucose ?? reading.sgv,
                      raw > 0
                else { return nil }

                return GlucosePoint(date: date, value: display(raw))
            }
            .sorted { $0.date < $1.date }
    }

    private var demoGlucosePoints: [GlucosePoint] {
        let anchors: [(Double, Double)] = [
            (-360, 104), (-300, 108), (-255, 116), (-225, 150),
            (-195, 188), (-165, 176), (-135, 142), (-105, 104),
            (-80, 78), (-65, 64), (-45, 74), (-25, 92), (0, 106)
        ]

        func interpolatedMGDL(_ minute: Double) -> Double {
            if minute <= anchors[0].0 { return anchors[0].1 }
            if minute >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }

            for index in 0 ..< anchors.count - 1 {
                let a = anchors[index]
                let b = anchors[index + 1]
                guard minute >= a.0, minute <= b.0 else { continue }
                let f = (minute - a.0) / (b.0 - a.0)
                return a.1 + (b.1 - a.1) * f
            }
            return 106
        }

        return stride(from: -360.0, through: 0.0, by: 5.0).enumerated().map { index, minute in
            let mgdl = interpolatedMGDL(minute) + sin(Double(index) * 0.72) * 2.2
            return GlucosePoint(
                date: now.addingTimeInterval(minute * 60),
                value: isMmolL ? mgdl * 0.0555 : mgdl
            )
        }
    }

    private enum PredictionKind: String, CaseIterable, Identifiable {
        case iob = "IOB"
        case zt = "ZT"
        case cob = "COB"
        case uam = "UAM"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .iob: return .blue
            case .zt: return .purple
            case .cob: return .yellow
            case .uam: return .orange
            }
        }
    }

    private func predictionWidth(_ kind: PredictionKind) -> CGFloat {
        switch kind {
        case .uam:
            return 2.4
        case .cob:
            return 2.0
        case .iob:
            return 1.8
        case .zt:
            return 1.3
        }
    }

    private func predictionOpacity(_ kind: PredictionKind) -> Double {
        switch kind {
        case .uam:
            return 1.00
        case .cob:
            return 0.95
        case .iob:
            return 0.90
        case .zt:
            return 0.70
        }
    }

    private struct PredictionPoint: Identifiable {
        let kind: PredictionKind
        let index: Int
        let date: Date
        let value: Double
        var id: String { "\(kind.rawValue)-\(index)" }
    }

    private struct PredictionLine: Identifiable {
        let kind: PredictionKind
        let points: [PredictionPoint]
        var id: PredictionKind { kind }
    }

    private var predictionSeries: [PredictionLine] {
        if simulatorDemoEnabled { return demoPredictionSeries }

        guard !data.hidePredictions,
              let predictions = data.suggestion?.predictions
        else { return [] }

        let start = data.suggestion?.deliverAt ?? now

        func make(_ kind: PredictionKind, values: [Int]?) -> PredictionLine? {
            guard let values, !values.isEmpty else { return nil }

            let points = values.enumerated().compactMap { index, raw -> PredictionPoint? in
                let date = start.addingTimeInterval(TimeInterval(index) * 300)
                guard date <= chartEnd else { return nil }

                return PredictionPoint(
                    kind: kind,
                    index: index,
                    date: date,
                    value: display(raw)
                )
            }

            return points.isEmpty ? nil : PredictionLine(kind: kind, points: points)
        }

        return [
            make(.zt, values: predictions.zt),
            make(.iob, values: predictions.iob),
            make(.cob, values: predictions.cob),
            make(.uam, values: predictions.uam)
        ].compactMap { $0 }
    }

    private var demoPredictionSeries: [PredictionLine] {
        let paths: [(PredictionKind, [Double])] = [
            (.zt, [106, 101, 96, 91, 87, 84, 82, 82, 83, 85, 88, 91, 94]),
            (.iob, [106, 104, 102, 100, 98, 96, 95, 94, 94, 95, 97, 99, 101]),
            (.cob, [106, 112, 119, 126, 132, 136, 138, 137, 134, 130, 125, 120, 116]),
            (.uam, [106, 115, 126, 139, 149, 154, 151, 145, 138, 131, 125, 120, 116])
        ]

        return paths.map { kind, values in
            PredictionLine(
                kind: kind,
                points: values.enumerated().map { index, mgdl in
                    PredictionPoint(
                        kind: kind,
                        index: index,
                        date: now.addingTimeInterval(Double(index) * 600),
                        value: isMmolL ? mgdl * 0.0555 : mgdl
                    )
                }
            )
        }
    }

    private struct TreatmentHit: Identifiable {
        let date: Date
        let amount: Double
        let isSMB: Bool
        var id: String { "\(date.timeIntervalSince1970)-\(amount)-\(isSMB)" }
    }

    private var bolusHits: [TreatmentHit] {
        if simulatorDemoEnabled {
            return [
                TreatmentHit(date: now.addingTimeInterval(-222 * 60), amount: 1.80, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-195 * 60), amount: 0.35, isSMB: true),
                TreatmentHit(date: now.addingTimeInterval(-175 * 60), amount: 0.40, isSMB: true),
                TreatmentHit(date: now.addingTimeInterval(-150 * 60), amount: 0.30, isSMB: true),
                TreatmentHit(date: now.addingTimeInterval(-118 * 60), amount: 0.25, isSMB: true)
            ]
        }

        return data.boluses.compactMap { event in
            let isSMBEvent = event.type == .smb || event.isSMB == true
            let supported: Bool
            switch event.type {
            case .bolus,
                 .bolusWizard,
                 .correctionBolus,
                 .mealBolus,
                 .smb,
                 .snackBolus:
                supported = true
            default:
                supported = false
            }

            guard supported,
                  let amount = event.amount,
                  amount > 0,
                  event.timestamp >= chartStart,
                  event.timestamp <= now
            else { return nil }

            return TreatmentHit(
                date: event.timestamp,
                amount: NSDecimalNumber(decimal: amount).doubleValue,
                isSMB: isSMBEvent
            )
        }
    }

    private var carbHits: [TreatmentHit] {
        if simulatorDemoEnabled {
            return [
                TreatmentHit(date: now.addingTimeInterval(-230 * 60), amount: 35, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-92 * 60), amount: 12, isSMB: false)
            ]
        }

        return data.carbs.compactMap { entry in
            guard (entry.isFPU ?? false) == false,
                  entry.carbs > 0
            else { return nil }

            let date = entry.actualDate ?? entry.createdAt
            guard date >= chartStart, date <= now else { return nil }

            return TreatmentHit(
                date: date,
                amount: NSDecimalNumber(decimal: entry.carbs).doubleValue,
                isSMB: false
            )
        }
    }

    private var fpuHits: [TreatmentHit] {
        if simulatorDemoEnabled {
            return [
                TreatmentHit(date: now.addingTimeInterval(-215 * 60), amount: 4, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-185 * 60), amount: 7, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-155 * 60), amount: 10, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-125 * 60), amount: 8, isSMB: false),
                TreatmentHit(date: now.addingTimeInterval(-95 * 60), amount: 5, isSMB: false)
            ]
        }

        guard data.fpus else { return [] }

        return data.carbs.compactMap { entry in
            guard (entry.isFPU ?? false) == true,
                  entry.carbs > 0
            else { return nil }

            let date = entry.actualDate ?? entry.createdAt
            guard date >= chartStart, date <= now else { return nil }

            return TreatmentHit(
                date: date,
                amount: NSDecimalNumber(decimal: entry.carbs).doubleValue,
                isSMB: false
            )
        }
        .sorted { $0.date < $1.date }
    }

    private struct BasalPoint: Identifiable {
        let id: String
        let date: Date
        let rate: Double
    }

    private var profileBasalPoints: [BasalPoint] {
        if simulatorDemoEnabled {
            let values: [(Double, Double)] = [
                (-360, 1.10), (-300, 1.20), (-240, 1.35), (-180, 1.45),
                (-120, 1.30), (-60, 1.15), (0, 1.10)
            ]
            return values.enumerated().map { index, item in
                BasalPoint(
                    id: "demo-profile-\(index)",
                    date: now.addingTimeInterval(item.0 * 60),
                    rate: item.1
                )
            }
        }

        guard !data.basalProfile.isEmpty else { return [] }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: chartStart)
        let endDay = calendar.startOfDay(for: now)
        let dayCount = max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0)

        var points: [BasalPoint] = []

        for dayOffset in 0 ... dayCount {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay) else { continue }

            for entry in data.basalProfile {
                guard let date = calendar.date(byAdding: .minute, value: entry.minutes, to: day),
                      date >= chartStart,
                      date <= now
                else { continue }

                points.append(
                    BasalPoint(
                        id: "profile-\(dayOffset)-\(entry.minutes)",
                        date: date,
                        rate: NSDecimalNumber(decimal: entry.rate).doubleValue
                    )
                )
            }
        }

        var sorted = points.sorted { $0.date < $1.date }

        // Extend the active profile step to the current-time rule. Without
        // this endpoint Swift Charts stops drawing at the last profile change.
        if let last = sorted.last, last.date < now {
            sorted.append(
                BasalPoint(
                    id: "profile-now",
                    date: now,
                    rate: last.rate
                )
            )
        }

        return sorted
    }

    private struct BasalSegment: Identifiable {
        let start: Date
        let end: Date
        let rate: Double
        var id: String { "\(start.timeIntervalSince1970)-\(rate)" }
    }

    private var tempBasalSegments: [BasalSegment] {
        if simulatorDemoEnabled {
            return [
                BasalSegment(
                    start: now.addingTimeInterval(-205 * 60),
                    end: now.addingTimeInterval(-175 * 60),
                    rate: 2.20
                ),
                BasalSegment(
                    start: now.addingTimeInterval(-150 * 60),
                    end: now.addingTimeInterval(-120 * 60),
                    rate: 1.80
                ),
                BasalSegment(
                    start: now.addingTimeInterval(-82 * 60),
                    end: now.addingTimeInterval(-47 * 60),
                    rate: 0.0
                )
            ]
        }

        let events = data.tempBasals.sorted { $0.timestamp < $1.timestamp }
        guard events.count > 1 else { return [] }

        var segments: [BasalSegment] = []

        for index in 0 ..< (events.count - 1) {
            let rateEvent = events[index]
            let durationEvent = events[index + 1]

            guard rateEvent.type == .tempBasal,
                  durationEvent.type == .tempBasalDuration,
                  let rate = rateEvent.rate,
                  let durationMin = durationEvent.durationMin
            else { continue }

            let start = rateEvent.timestamp
            let end = min(start.addingTimeInterval(Double(durationMin) * 60), now)

            guard end >= chartStart, start <= now, end > start else { continue }

            segments.append(
                BasalSegment(
                    start: max(start, chartStart),
                    end: end,
                    rate: NSDecimalNumber(decimal: rate).doubleValue
                )
            )
        }

        return segments
    }

    /// Das aktuell laufende TempBasal wird im Basal-Track stärker dargestellt.
    private var activeTempBasalSegmentID: String? {
        tempBasalSegments
            .filter { $0.start <= now && $0.end >= now }
            .max { $0.start < $1.start }?
            .id
    }

    private func isActiveTempBasal(_ segment: BasalSegment) -> Bool {
        segment.id == activeTempBasalSegmentID
    }

    private func tempBasalFillOpacity(_ segment: BasalSegment) -> Double {
        isActiveTempBasal(segment) ? 0.38 : 0.18
    }

    private func tempBasalLineOpacity(_ segment: BasalSegment) -> Double {
        isActiveTempBasal(segment) ? 1.00 : 0.68
    }

    private func tempBasalLineWidth(_ segment: BasalSegment) -> CGFloat {
        isActiveTempBasal(segment) ? 2.2 : 1.25
    }

    private var basalMaximum: Double {
        let profile = profileBasalPoints.map(\.rate).max() ?? 0
        let temp = tempBasalSegments.map(\.rate).max() ?? 0
        return max(0.5, max(profile, temp))
    }

    // Dedicated lower treatment lanes for FPE and carbs. Basal is rendered
    // in its own chart track with a real U/h scale.
    private var fpeLaneFloor: Double { yLow + (yHigh - yLow) * 0.078 }
    private var fpeLaneCeiling: Double { yLow + (yHigh - yLow) * 0.125 }
    private var carbLaneFloor: Double { yLow + (yHigh - yLow) * 0.132 }
    private var carbLaneCeiling: Double { yLow + (yHigh - yLow) * 0.185 }

    /// Stagger insulin labels when several boluses/SMBs occur close together.
    /// The lane is deterministic in chronological order and resets once there
    /// is enough horizontal separation.
    private struct BolusLabelPlacement {
        let lane: Int
        let horizontal: CGFloat
    }

    /// Selects which SMB events receive a numeric label.
    ///
    /// Every SMB remains visible as a blue arrow. Manual boluses are always
    /// labelled separately in the chart rendering. For SMBs:
    /// - the newest SMB is always labelled;
    /// - older SMBs must be at least 0.30 E;
    /// - labels remain at least 35 minutes apart.
    private var labelledSMBIDs: Set<String> {
        let smbs = bolusHits
            .filter(\.isSMB)
            .sorted { $0.date > $1.date }

        guard let newest = smbs.first else {
            return []
        }

        var selected: Set<String> = [newest.id]
        var lastSelectedDate = newest.date

        for hit in smbs.dropFirst() {
            guard hit.amount >= 0.30 else {
                continue
            }

            let separation = lastSelectedDate.timeIntervalSince(hit.date)
            guard separation >= 35 * 60 else {
                continue
            }

            selected.insert(hit.id)
            lastSelectedDate = hit.date
        }

        return selected
    }

    private func shouldShowInsulinLabel(for hit: TreatmentHit) -> Bool {
        !hit.isSMB || labelledSMBIDs.contains(hit.id)
    }

    /// The most recent visible SMB receives stronger visual emphasis.
    private var newestSMBID: String? {
        bolusHits
            .filter(\.isSMB)
            .max { $0.date < $1.date }?
            .id
    }

    private func isNewestSMB(_ hit: TreatmentHit) -> Bool {
        hit.isSMB && hit.id == newestSMBID
    }

    /// Selects which FPE events receive a numeric label.
    ///
    /// Every FPE remains visible as an orange flame. The newest FPE is always
    /// labelled. Older entries require at least 8 g and 35 minutes separation.
    private var labelledFPUIDs: Set<String> {
        let fpus = fpuHits.sorted { $0.date > $1.date }

        guard let newest = fpus.first else {
            return []
        }

        var selected: Set<String> = [newest.id]
        var lastSelectedDate = newest.date

        for hit in fpus.dropFirst() {
            guard hit.amount >= 8 else {
                continue
            }

            let separation = lastSelectedDate.timeIntervalSince(hit.date)
            guard separation >= 35 * 60 else {
                continue
            }

            selected.insert(hit.id)
            lastSelectedDate = hit.date
        }

        return selected
    }

    private var newestFPUID: String? {
        fpuHits.max { $0.date < $1.date }?.id
    }

    private func shouldShowFPULabel(for hit: TreatmentHit) -> Bool {
        labelledFPUIDs.contains(hit.id)
    }

    private func isNewestFPU(_ hit: TreatmentHit) -> Bool {
        hit.id == newestFPUID
    }

    private var bolusLabelPlacements: [String: BolusLabelPlacement] {
        let sorted = bolusHits.sorted { $0.date < $1.date }
        var result: [String: BolusLabelPlacement] = [:]
        var clusterIndex = 0
        var previousDate: Date?

        let horizontalScale: CGFloat
        switch data.screenHours {
        case ...3: horizontalScale = 0.85
        case 4 ... 6: horizontalScale = 1.0
        case 7 ... 12: horizontalScale = 1.15
        default: horizontalScale = 1.3
        }

        let visibleSpan = max(chartEnd.timeIntervalSince(chartStart), 1)
        var leftEdgeIndex = 0

        for hit in sorted {
            if let previousDate,
               hit.date.timeIntervalSince(previousDate) <= 16 * 60
            {
                clusterIndex += 1
            } else {
                clusterIndex = 0
            }

            if hit.isSMB {
                let xFraction = hit.date.timeIntervalSince(chartStart) / visibleSpan
                let nearLeftEdge = xFraction < 0.12
                let nearRightEdge = xFraction > 0.88

                if nearLeftEdge {
                    // Keep left-edge labels close to their arrows: only two
                    // vertical rows, with additional separation handled
                    // horizontally to the right.
                    let lane = leftEdgeIndex % 2
                    let column = leftEdgeIndex / 2
                    let horizontal = (18 + CGFloat(column) * 18) * horizontalScale

                    result[hit.id] = BolusLabelPlacement(
                        lane: lane,
                        horizontal: horizontal
                    )
                    leftEdgeIndex += 1
                } else {
                    let lane = (clusterIndex / 2) % 4
                    let cycle = clusterIndex / 8

                    let side: CGFloat
                    if nearRightEdge {
                        side = -1
                    } else {
                        side = clusterIndex.isMultiple(of: 2) ? -1 : 1
                    }

                    let baseByLane: [CGFloat] = [20, 31, 42, 53]
                    var distance = baseByLane[lane] + CGFloat(cycle) * 9

                    if nearRightEdge {
                        distance += CGFloat(clusterIndex % 4) * 5
                    }

                    result[hit.id] = BolusLabelPlacement(
                        lane: lane,
                        horizontal: side * distance * horizontalScale
                    )
                }
            } else {
                result[hit.id] = BolusLabelPlacement(
                    lane: 0,
                    horizontal: 0
                )
            }

            previousDate = hit.date
        }

        return result
    }

    private func bolusLabelOffset(for hit: TreatmentHit) -> CGFloat {
        guard hit.isSMB else { return 0 }

        let placement = bolusLabelPlacements[hit.id]
        let xFraction = hit.date.timeIntervalSince(chartStart) / max(chartEnd.timeIntervalSince(chartStart), 1)

        // Near the left edge, cap vertical distance so labels remain visually
        // tied to their SMB arrows. Elsewhere keep the current four-lane spacing.
        if xFraction < 0.12 {
            return CGFloat(placement?.lane ?? 0) * 10
        }

        return CGFloat(placement?.lane ?? 0) * 14
    }

    private func bolusLabelHorizontalOffset(for hit: TreatmentHit) -> CGFloat {
        bolusLabelPlacements[hit.id]?.horizontal ?? 0
    }

    private func insulinAmountLabel(_ amount: Double) -> String {
        String(format: "%.2f", amount)
            .replacingOccurrences(of: ".", with: ",")
    }

    private func carbY(_ grams: Double) -> Double {
        let maxCarbs = max(20, NSDecimalNumber(decimal: data.maxCarbsValue).doubleValue)
        return carbLaneFloor + (min(grams, maxCarbs) / maxCarbs) * (carbLaneCeiling - carbLaneFloor)
    }

    private func fpuY(_ grams: Double) -> Double {
        let maxCarbs = max(20, NSDecimalNumber(decimal: data.maxCarbsValue).doubleValue)
        return fpeLaneFloor + (min(grams, maxCarbs) / maxCarbs) * (fpeLaneCeiling - fpeLaneFloor)
    }

    /// Place meal markers relative to the nearby glucose point so KH/FPE
    /// visually belong to the glucose trajectory instead of the chart floor.
    private func carbMarkerRange(for hit: TreatmentHit) -> (base: Double, top: Double) {
        let nearby = nearestGlucoseValue(to: hit.date) ?? (lowThreshold + (isMmolL ? 2.0 : 35.0))
        let offset = isMmolL ? 1.25 : 22.0
        let height = isMmolL ? 0.80 : 14.0
        let floorPadding = isMmolL ? 0.35 : 6.0
        let topPadding = isMmolL ? 0.40 : 7.0

        let base = max(yLow + floorPadding, nearby - offset - height)
        let top = min(nearby - topPadding, base + height)
        return (base, max(base + (isMmolL ? 0.1 : 2.0), top))
    }

    private func fpuCurveY(for hit: TreatmentHit) -> Double {
        let nearby = nearestGlucoseValue(to: hit.date) ?? (lowThreshold + (isMmolL ? 1.7 : 30.0))
        let amountLift = min(hit.amount, 12) * (isMmolL ? 0.020 : 0.35)
        let offset = isMmolL ? 1.15 : 21.0
        let floorPadding = isMmolL ? 0.25 : 5.0
        return max(yLow + floorPadding, nearby - offset + amountLift)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            chart
            legend
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .auroraGlass(radius: 20)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if simulatorDemoEnabled {
                Text("DEMO")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
            }

            Text(yRangeLabel)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(AuroraPalette.textMuted(scheme))
                .monospacedDigit()

            Spacer()

            ForEach([3, 6, 12, 24], id: \.self) { hours in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        data.screenHours = hours
                    }
                } label: {
                    Text("\(hours)H")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            data.screenHours == hours ? Color.white : AuroraPalette.textMuted(scheme)
                        )
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(
                                    data.screenHours == hours
                                        ? Color.purple.opacity(0.72)
                                        : Color.clear
                                )
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var yRangeLabel: String {
        if isMmolL {
            return "\(String(format: "%.1f", yLow))–\(String(format: "%.1f", yHigh))"
                .replacingOccurrences(of: ".", with: ",")
        }
        return "\(Int(yLow.rounded()))–\(Int(yHigh.rounded()))"
    }

    private var chart: some View {
        VStack(spacing: 4) {
            Chart {
                RectangleMark(
                    xStart: .value("start", chartStart),
                    xEnd: .value("end", chartEnd),
                    yStart: .value("low target", lowThreshold),
                    yEnd: .value("high target", highThreshold)
                )
                .foregroundStyle(Color.green.opacity(0.035))

                RuleMark(y: .value("low", lowThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                    .foregroundStyle(AuroraPalette.textFaint(scheme))

                RuleMark(y: .value("high", highThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                    .foregroundStyle(AuroraPalette.textFaint(scheme))

                RuleMark(x: .value("now", now))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    .foregroundStyle(Color.white.opacity(0.45))

                // Glucose trajectory: subtle connector plus range-colored CGM samples.
                ForEach(glucosePoints) { point in
                    LineMark(
                        x: .value("time", point.date),
                        y: .value("glucose", point.value),
                        series: .value("series", "glucose")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.white.opacity(0.28))
                }

                ForEach(glucosePoints) { point in
                    PointMark(
                        x: .value("time", point.date),
                        y: .value("glucose", point.value)
                    )
                    .symbolSize(18)
                    .foregroundStyle(glucoseColor(for: point.value))
                }

                ForEach(predictionSeries) { line in
                    ForEach(line.points) { point in
                        LineMark(
                            x: .value("prediction time", point.date),
                            y: .value("prediction glucose", point.value),
                            series: .value("prediction series", line.kind.rawValue)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: predictionWidth(line.kind),
                                lineCap: .round,
                                lineJoin: .round,
                                dash: line.kind == .zt ? [3, 3] : []
                            )
                        )
                        .foregroundStyle(
                            line.kind.color.opacity(predictionOpacity(line.kind))
                        )
                    }
                }

                if displayCarbs || simulatorDemoEnabled {
                    ForEach(carbHits) { hit in
                        let range = carbMarkerRange(for: hit)

                        BarMark(
                            x: .value("carb time", hit.date),
                            yStart: .value("carb base", range.base),
                            yEnd: .value("carb top", range.top),
                            width: .fixed(6)
                        )
                        .foregroundStyle(Color.green.opacity(0.88))
                        .annotation(position: .bottom, spacing: 2) {
                            HStack(spacing: 2) {
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 6.5, weight: .bold))
                                Text("\(Int(hit.amount.rounded()))g")
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Color.green)
                        }
                    }
                }

                if data.fpus || simulatorDemoEnabled {
                    ForEach(fpuHits) { hit in
                        let y = fpuCurveY(for: hit)

                        PointMark(
                            x: .value("fpu point time", hit.date),
                            y: .value("fpu point", y)
                        )
                        .symbolSize(20)
                        .foregroundStyle(Color.orange)
                        .annotation(position: .bottom, spacing: 2) {
                            VStack(spacing: 2) {
                                Image(systemName: "flame.fill")
                                    .font(
                                        .system(
                                            size: isNewestFPU(hit) ? 8 : 6.5,
                                            weight: .bold
                                        )
                                    )

                                if shouldShowFPULabel(for: hit) {
                                    Text(
                                        String(format: "%.0f", hit.amount)
                                            .replacingOccurrences(of: ".", with: ",")
                                    )
                                    .font(
                                        .system(
                                            size: isNewestFPU(hit) ? 8 : 7,
                                            weight: .bold,
                                            design: .rounded
                                        )
                                    )
                                    .monospacedDigit()
                                    .fixedSize()
                                    .padding(.horizontal, isNewestFPU(hit) ? 4.5 : 3)
                                    .padding(.vertical, isNewestFPU(hit) ? 1.2 : 0.5)
                                    .background(
                                        Capsule()
                                            .fill(
                                                Color.orange.opacity(
                                                    isNewestFPU(hit) ? 0.24 : 0.13
                                                )
                                            )
                                    )
                                }
                            }
                            .foregroundStyle(
                                Color.orange.opacity(isNewestFPU(hit) ? 1.0 : 0.82)
                            )
                        }
                    }
                }

                if displayBoluses || simulatorDemoEnabled {
                    ForEach(bolusHits) { hit in
                        if let glucose = nearestGlucoseValue(to: hit.date) {
                            PointMark(
                                x: .value("bolus time", hit.date),
                                y: .value("bolus glucose", glucose)
                            )
                            .symbolSize(1)
                            .foregroundStyle(Color.clear)
                            .annotation(position: .top, alignment: .center, spacing: 1) {
                                VStack(spacing: 2) {
                                    Image(systemName: hit.isSMB ? "arrow.down" : "syringe.fill")
                                        .font(
                                            .system(
                                                size: hit.isSMB
                                                    ? (isNewestSMB(hit) ? 10 : 8)
                                                    : 9,
                                                weight: .heavy
                                            )
                                        )
                                        .foregroundStyle(
                                            hit.isSMB
                                                ? Color.blue.opacity(isNewestSMB(hit) ? 1.0 : 0.82)
                                                : Color.cyan
                                        )

                                    if shouldShowInsulinLabel(for: hit) {
                                        Text(insulinAmountLabel(hit.amount))
                                            .font(
                                                .system(
                                                    size: isNewestSMB(hit) ? 8.4 : 7.2,
                                                    weight: .heavy,
                                                    design: .rounded
                                                )
                                            )
                                            .monospacedDigit()
                                            .fixedSize()
                                            .padding(
                                                .horizontal,
                                                isNewestSMB(hit) ? 5 : 3.5
                                            )
                                            .padding(
                                                .vertical,
                                                isNewestSMB(hit) ? 1.2 : 0.5
                                            )
                                            .foregroundStyle(hit.isSMB ? Color.blue : Color.cyan)
                                            .background(
                                                Capsule()
                                                    .fill(
                                                        (hit.isSMB ? Color.blue : Color.cyan)
                                                            .opacity(
                                                                hit.isSMB
                                                                    ? (isNewestSMB(hit) ? 0.28 : 0.14)
                                                                    : 0.22
                                                            )
                                                    )
                                            )
                                    }
                                }
                                .offset(
                                    x: bolusLabelHorizontalOffset(for: hit),
                                    y: -(10 + bolusLabelOffset(for: hit))
                                )
                            }
                        }
                    }
                }
            }
            .chartXScale(domain: chartStart ... chartEnd)
            .chartYScale(domain: yLow ... yHigh)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                    if data.displayXgridLines {
                        AxisGridLine()
                            .foregroundStyle(AuroraPalette.hairline(scheme).opacity(0.55))
                    }

                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(AuroraPalette.textMuted(scheme))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .stride(by: yAxisStride)) { value in
                    if data.displayYgridLines {
                        AxisGridLine()
                            .foregroundStyle(AuroraPalette.hairline(scheme).opacity(0.45))
                    }

                    if data.yGridLabels {
                        AxisValueLabel {
                            if let value = value.as(Double.self) {
                                Text(isMmolL ? String(format: "%.1f", value) : "\(Int(value.rounded()))")
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .foregroundStyle(AuroraPalette.textMuted(scheme))
                            }
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot
                    .background(Color.black.opacity(scheme == .dark ? 0.11 : 0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(height: mainPlotHeight)

            if displayBasal {
                basalTrack
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(timelinePanGesture)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    withAnimation(.easeOut(duration: 0.25)) {
                        panOffset = 0
                    }
                }
        )
    }

    private var basalTrack: some View {
        Chart {
            // Profilbasal bleibt als ruhige Referenz sichtbar.
            ForEach(profileBasalPoints) { point in
                LineMark(
                    x: .value("profile time", point.date),
                    y: .value("profile basal", point.rate),
                    series: .value("series", "profile-basal")
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(
                    StrokeStyle(
                        lineWidth: 1.0,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .foregroundStyle(Color.cyan.opacity(0.42))
            }

            // TempBasal-Flächen zeigen die tatsächlichen Loop-Eingriffe.
            ForEach(tempBasalSegments) { segment in
                if segment.rate > 0 {
                    RectangleMark(
                        xStart: .value("temp start", segment.start),
                        xEnd: .value("temp end", segment.end),
                        yStart: .value("temp base", 0.0),
                        yEnd: .value("temp rate", segment.rate)
                    )
                    .foregroundStyle(
                        Color.cyan.opacity(tempBasalFillOpacity(segment))
                    )

                    // Klare Oberkante für die tatsächlich gesetzte Rate.
                    RuleMark(
                        xStart: .value("temp line start", segment.start),
                        xEnd: .value("temp line end", segment.end),
                        y: .value("temp line rate", segment.rate)
                    )
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: tempBasalLineWidth(segment),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .foregroundStyle(
                        Color.cyan.opacity(tempBasalLineOpacity(segment))
                    )
                } else {
                    // Null-Basal wäre als Fläche unsichtbar und erhält deshalb
                    // eine deutlich erkennbare rote Linie knapp über der Nullachse.
                    RuleMark(
                        xStart: .value("zero basal start", segment.start),
                        xEnd: .value("zero basal end", segment.end),
                        y: .value(
                            "zero basal",
                            max(basalTrackMaximum * 0.025, 0.03)
                        )
                    )
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: isActiveTempBasal(segment) ? 2.4 : 1.6,
                            lineCap: .round,
                            dash: [4, 2]
                        )
                    )
                    .foregroundStyle(
                        Color.red.opacity(
                            isActiveTempBasal(segment) ? 1.0 : 0.75
                        )
                    )
                }
            }
        }
        .chartXScale(domain: chartStart ... chartEnd)
        .chartYScale(domain: 0 ... basalTrackMaximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(
                position: .trailing,
                values: [0, basalTrackMaximum / 2, basalTrackMaximum]
            ) { value in
                AxisGridLine()
                    .foregroundStyle(AuroraPalette.hairline(scheme).opacity(0.28))

                AxisValueLabel {
                    if let value = value.as(Double.self) {
                        Text(basalAxisLabel(value))
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cyan.opacity(0.85))
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.cyan.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .overlay(alignment: .topLeading) {
            Text("Basal")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cyan.opacity(0.75))
                .padding(.leading, 5)
                .padding(.top, 2)
        }
        .frame(height: basalTrackHeight)
    }

    private var basalTrackMaximum: Double {
        let padded = basalMaximum * 1.15
        return max(0.5, ceil(padded * 2) / 2)
    }

    private func basalAxisLabel(_ value: Double) -> String {
        if value == 0 {
            return "0"
        }

        let formatted = String(format: "%.2f", value)
            .replacingOccurrences(of: ".", with: ",")
            .replacingOccurrences(of: ",00", with: "")
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)

        return value == basalTrackMaximum ? "\(formatted) E/h" : formatted
    }

    private var yAxisStride: Double {
        if isMmolL {
            let span = yHigh - yLow
            return span <= 8 ? 2 : 4
        }

        let span = yHigh - yLow
        if span <= 160 { return 40 }
        if span <= 260 { return 50 }
        return 100
    }

    private var hourStride: Int {
        switch data.screenHours {
        case ...3: return 1
        case 4 ... 6: return 2
        case 7 ... 12: return 3
        default: return 6
        }
    }

    private var legend: some View {
        HStack(spacing: 7) {
            ForEach(PredictionKind.allCases) { kind in
                legendItem(kind.rawValue, color: kind.color)
            }

            Spacer(minLength: 2)

            legendItem("KH", color: .green)
            legendItem("FPE", color: .orange)
            legendItem("SMB", color: .blue)
            legendItem("Bolus", color: .cyan)
            legendItem("Basal", color: .cyan)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private func legendItem(_ text: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 6.8, weight: .semibold, design: .rounded))
                .foregroundStyle(AuroraPalette.textMuted(scheme))
        }
    }
}
