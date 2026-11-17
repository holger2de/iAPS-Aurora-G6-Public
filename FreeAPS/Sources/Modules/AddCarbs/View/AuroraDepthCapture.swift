import ARKit
import Combine
import CoreImage
import Foundation
import simd
import UIKit
import Vision

// MARK: - Aurora LiDAR depth capture and diagnostics

struct AuroraDepthSnapshot: Sendable, Equatable {
    let capturedAt: Date
    let centerDepth: Float?
    let meanDepth: Float?
    let standardDeviation: Float?
    let nearDepthPercentile: Float?
    let medianDepth: Float?
    let farDepthPercentile: Float?
    let reliefDepth: Float?
    let minimumDepth: Float?
    let maximumDepth: Float?
    let sampleCount: Int
    let depthMapWidth: Int
    let depthMapHeight: Int

    var hasUsableDepthData: Bool {
        guard let meanDepth,
              meanDepth.isFinite,
              meanDepth > 0.05,
              sampleCount > 0
        else {
            return false
        }

        return true
    }
}

struct AuroraForegroundMask: Sendable, Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let foregroundPixelCount: Int

    var totalPixelCount: Int {
        width * height
    }

    var coverage: Float {
        guard totalPixelCount > 0 else {
            return 0
        }

        return Float(foregroundPixelCount)
            / Float(totalPixelCount)
    }

    func containsForeground(
        normalizedX: Float,
        normalizedY: Float
    ) -> Bool {
        guard width > 0,
              height > 0,
              pixels.count == width * height
        else {
            return false
        }

        let clampedX = min(1, max(0, normalizedX))
        let clampedY = min(1, max(0, normalizedY))

        let x = min(
            width - 1,
            Int(clampedX * Float(width))
        )

        let y = min(
            height - 1,
            Int(clampedY * Float(height))
        )

        return pixels[y * width + x] != 0
    }
}

struct AuroraCameraGeometry: @unchecked Sendable {
    /// Camera pose in ARKit world coordinates at capture time.
    let transform: simd_float4x4

    /// Camera calibration matrix for imageResolution.
    let intrinsics: simd_float3x3

    /// Resolution for which the intrinsics are defined.
    let imageResolutionWidth: Int
    let imageResolutionHeight: Int

    /// Angle between the camera viewing direction and straight down
    /// in the gravity-aligned ARKit world coordinate system.
    ///
    /// 0 degrees = camera points vertically downward.
    /// 90 degrees = camera points horizontally.
    var downwardViewAngleDegrees: Float {
        let forward = SIMD3<Float>(
            -transform.columns.2.x,
            -transform.columns.2.y,
            -transform.columns.2.z
        )

        let length = simd_length(forward)

        guard length > 0 else {
            return .nan
        }

        let normalizedForward = forward / length
        let straightDown = SIMD3<Float>(0, -1, 0)

        let cosine = max(
            -1,
            min(
                1,
                simd_dot(
                    normalizedForward,
                    straightDown
                )
            )
        )

        return acos(cosine) * 180 / .pi
    }
}

struct AuroraMetricGeometry: Sendable {
    let pointCount: Int

    /// Axis-aligned extent of the foreground point cloud in camera space.
    let widthMeters: Float
    let heightMeters: Float
    let depthMeters: Float

    /// Foreground points transformed into the shared ARKit world coordinate system.
    let worldPoints: [SIMD3<Float>]

    var widthCentimeters: Float { widthMeters * 100 }
    var heightCentimeters: Float { heightMeters * 100 }
    var depthCentimeters: Float { depthMeters * 100 }
}

struct AuroraFusedGeometry: Sendable {
    let pointCount: Int
    let extentX: Float
    let extentY: Float
    let extentZ: Float

    let yP02: Float
    let yP10: Float
    let yP50: Float
    let yP90: Float
    let yP98: Float

    let cut05PointCount: Int
    let cut05ExtentX: Float
    let cut05ExtentZ: Float

    let cut10PointCount: Int
    let cut10ExtentX: Float
    let cut10ExtentZ: Float

    let cut15PointCount: Int
    let cut15ExtentX: Float
    let cut15ExtentZ: Float

    let orientedPointCount: Int
    let orientedLength: Float
    let orientedWidth: Float
    let objectHeight: Float

    let volume5mmCubicMeters: Float
    let volume7_5mmCubicMeters: Float
    let volume10mmCubicMeters: Float

    var extentXCentimeters: Float { extentX * 100 }

    var volume5mmMilliliters: Float {
        volume5mmCubicMeters * 1_000_000
    }

    var volume7_5mmMilliliters: Float {
        volume7_5mmCubicMeters * 1_000_000
    }

    var volume10mmMilliliters: Float {
        volume10mmCubicMeters * 1_000_000
    }

    var extentYCentimeters: Float { extentY * 100 }
    var extentZCentimeters: Float { extentZ * 100 }

    var yP02Centimeters: Float { yP02 * 100 }
    var yP10Centimeters: Float { yP10 * 100 }
    var yP50Centimeters: Float { yP50 * 100 }
    var yP90Centimeters: Float { yP90 * 100 }
    var yP98Centimeters: Float { yP98 * 100 }
}

enum AuroraCaptureRole: String, Sendable {
    case top
    case tilted
    case side
}

struct AuroraClassifiedCapture {
    let captureIndex: Int
    let role: AuroraCaptureRole
    let downwardAngleDegrees: Float
    let capture: AuroraMealCapture
}

func auroraClassifyCaptures(
    _ captures: [AuroraMealCapture]
) -> [AuroraClassifiedCapture] {
    let candidates =
        captures.enumerated().compactMap {
            index,
                capture -> (
                    index: Int,
                    angle: Float,
                    capture: AuroraMealCapture
                )? in

            guard let angle =
                capture.cameraGeometry?
                    .downwardViewAngleDegrees,
                    angle.isFinite
            else {
                return nil
            }

            return (
                index: index,
                angle: angle,
                capture: capture
            )
        }
        .sorted {
            $0.angle < $1.angle
        }

    guard !candidates.isEmpty else {
        return []
    }

    if candidates.count == 1 {
        let item = candidates[0]

        return [
            AuroraClassifiedCapture(
                captureIndex: item.index,
                role: .top,
                downwardAngleDegrees: item.angle,
                capture: item.capture
            )
        ]
    }

    if candidates.count == 2 {
        return [
            AuroraClassifiedCapture(
                captureIndex: candidates[0].index,
                role: .top,
                downwardAngleDegrees: candidates[0].angle,
                capture: candidates[0].capture
            ),
            AuroraClassifiedCapture(
                captureIndex: candidates[1].index,
                role: .side,
                downwardAngleDegrees: candidates[1].angle,
                capture: candidates[1].capture
            )
        ]
    }

    let top = candidates.first!
    let side = candidates.last!

    let middleCandidates =
        Array(candidates.dropFirst().dropLast())

    // If more than three captures ever exist, use the middle view
    // closest to 45 degrees as the tilted geometry view.
    let tilted =
        middleCandidates.min {
            abs($0.angle - 45) <
                abs($1.angle - 45)
        }!

    return [
        AuroraClassifiedCapture(
            captureIndex: top.index,
            role: .top,
            downwardAngleDegrees: top.angle,
            capture: top.capture
        ),
        AuroraClassifiedCapture(
            captureIndex: tilted.index,
            role: .tilted,
            downwardAngleDegrees: tilted.angle,
            capture: tilted.capture
        ),
        AuroraClassifiedCapture(
            captureIndex: side.index,
            role: .side,
            downwardAngleDegrees: side.angle,
            capture: side.capture
        )
    ]
}

struct AuroraTopViewVolume: Sendable {
    let captureIndex: Int
    let downwardAngleDegrees: Float
    let pointCount: Int
    let supportY: Float
    let volume5mmCubicMeters: Float
    let volume7_5mmCubicMeters: Float
    let volume10mmCubicMeters: Float

    let inner10mmVolume5mmCubicMeters: Float
    let inner15mmVolume5mmCubicMeters: Float
    let heightP02Meters: Float
    let heightP10Meters: Float
    let heightP25Meters: Float
    let heightP50Meters: Float
    let heightP75Meters: Float
    let heightP90Meters: Float
    let heightP98Meters: Float

    let shapePointCount: Int
    let shapeMajorAxisMeters: Float
    let shapeMinorAxisMeters: Float
    let shapeFootprintSquareMeters: Float
    let shapeAxisRatio: Float

    var shapeMajorAxisCentimeters: Float {
        shapeMajorAxisMeters * 100
    }

    var shapeMinorAxisCentimeters: Float {
        shapeMinorAxisMeters * 100
    }

    var shapeFootprintSquareCentimeters: Float {
        shapeFootprintSquareMeters * 10000
    }

    var shapeEquivalentDiameterCentimeters: Float {
        guard shapeFootprintSquareMeters > 0 else {
            return 0
        }

        return 2 * sqrt(shapeFootprintSquareMeters / .pi) * 100
    }

    var volume5mmMilliliters: Float {
        volume5mmCubicMeters * 1_000_000
    }

    var volume7_5mmMilliliters: Float {
        volume7_5mmCubicMeters * 1_000_000
    }

    var volume10mmMilliliters: Float {
        volume10mmCubicMeters * 1_000_000
    }

    var inner10mmVolume5mmMilliliters: Float {
        inner10mmVolume5mmCubicMeters * 1_000_000
    }

    var inner15mmVolume5mmMilliliters: Float {
        inner15mmVolume5mmCubicMeters * 1_000_000
    }
}

func auroraTopViewVolume(
    from captures: [AuroraMealCapture]
) -> AuroraTopViewVolume? {
    guard let top =
        auroraClassifyCaptures(captures)
            .first(where: { $0.role == .top }),
            let metric = top.capture.metricGeometry
    else {
        return nil
    }

    let points =
        metric.worldPoints.filter {
            $0.x.isFinite &&
                $0.y.isFinite &&
                $0.z.isFinite
        }

    guard points.count >= 200 else {
        return nil
    }

    let sortedY = points.map(\.y).sorted()

    func percentile(
        _ fraction: Double,
        in values: [Float]
    ) -> Float {
        let position =
            fraction * Double(values.count - 1)

        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))

        if lower == upper {
            return values[lower]
        }

        let weight =
            Float(position - Double(lower))

        return values[lower]
            + (values[upper] - values[lower]) * weight
    }

    let heightP02 =
        percentile(0.02, in: sortedY)

    let heightP10 =
        percentile(0.10, in: sortedY)

    let heightP25 =
        percentile(0.25, in: sortedY)

    let heightP50 =
        percentile(0.50, in: sortedY)

    let heightP75 =
        percentile(0.75, in: sortedY)

    let heightP90 =
        percentile(0.90, in: sortedY)

    let heightP98 =
        percentile(0.98, in: sortedY)

    let supportY = heightP10
    let upperY = heightP98

    func topViewShapeGeometry()
        -> (
            pointCount: Int,
            majorAxis: Float,
            minorAxis: Float,
            footprintArea: Float,
            axisRatio: Float
        )
    {
        let shapePoints = points.filter { point in
            let height =
                min(
                    max(0, point.y - supportY),
                    max(0, upperY - supportY)
                )

            return height >= 0.010
        }

        guard shapePoints.count >= 20 else {
            return (shapePoints.count, 0, 0, 0, 0)
        }

        func robustShapeBounds(
            _ values: [Float]
        ) -> (lower: Float, upper: Float)? {
            let sorted =
                values
                    .filter(\.isFinite)
                    .sorted()

            guard sorted.count >= 20 else {
                return nil
            }

            func percentile(_ fraction: Double) -> Float {
                let position =
                    fraction * Double(sorted.count - 1)

                let lower =
                    Int(position.rounded(.down))
                let upper =
                    Int(position.rounded(.up))

                if lower == upper {
                    return sorted[lower]
                }

                let weight =
                    Float(position - Double(lower))

                return sorted[lower]
                    + (sorted[upper] - sorted[lower]) * weight
            }

            return (
                percentile(0.02),
                percentile(0.98)
            )
        }

        let meanX =
            shapePoints.reduce(Float.zero) { $0 + $1.x }
                / Float(shapePoints.count)

        let meanZ =
            shapePoints.reduce(Float.zero) { $0 + $1.z }
                / Float(shapePoints.count)

        var covarianceXX: Float = 0
        var covarianceXZ: Float = 0
        var covarianceZZ: Float = 0

        for point in shapePoints {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            covarianceXX += dx * dx
            covarianceXZ += dx * dz
            covarianceZZ += dz * dz
        }

        let divisor = Float(shapePoints.count)

        covarianceXX /= divisor
        covarianceXZ /= divisor
        covarianceZZ /= divisor

        let angle =
            0.5 * atan2(
                2 * covarianceXZ,
                covarianceXX - covarianceZZ
            )

        let cosine = cos(angle)
        let sine = sin(angle)

        var axis1: [Float] = []
        var axis2: [Float] = []

        axis1.reserveCapacity(shapePoints.count)
        axis2.reserveCapacity(shapePoints.count)

        struct ShapeCell: Hashable {
            let x: Int
            let z: Int
        }

        let cellSize: Float = 0.005
        var occupiedCells = Set<ShapeCell>()

        for point in shapePoints {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            let alignedX =
                dx * cosine + dz * sine

            let alignedZ =
                -dx * sine + dz * cosine

            axis1.append(alignedX)
            axis2.append(alignedZ)

            occupiedCells.insert(
                ShapeCell(
                    x: Int(floor(alignedX / cellSize)),
                    z: Int(floor(alignedZ / cellSize))
                )
            )
        }

        guard let bounds1 =
            robustShapeBounds(axis1),
            let bounds2 =
            robustShapeBounds(axis2)
        else {
            return (shapePoints.count, 0, 0, 0, 0)
        }

        let extent1 =
            bounds1.upper - bounds1.lower

        let extent2 =
            bounds2.upper - bounds2.lower

        let majorAxis =
            max(extent1, extent2)

        let minorAxis =
            min(extent1, extent2)

        #if DEBUG
            let diagnosticRadius =
                max(majorAxis, minorAxis) / 2

            if diagnosticRadius > 0 {
                var radialZones =
                    Array(
                        repeating: [Float](),
                        count: 11
                    )

                for point in points {
                    let dx = point.x - meanX
                    let dz = point.z - meanZ

                    let radialDistance =
                        sqrt(dx * dx + dz * dz)

                    let normalizedRadius =
                        radialDistance / diagnosticRadius

                    let zoneIndex =
                        Int(floor(normalizedRadius * 10))

                    guard zoneIndex >= 0,
                          zoneIndex < radialZones.count
                    else {
                        continue
                    }

                    radialZones[zoneIndex].append(
                        point.y - supportY
                    )
                }

                func radialPercentile(
                    _ fraction: Double,
                    values: [Float]
                ) -> Float {
                    guard !values.isEmpty else {
                        return 0
                    }

                    let sorted = values.sorted()

                    let position =
                        fraction * Double(sorted.count - 1)

                    let lower =
                        Int(position.rounded(.down))

                    let upper =
                        Int(position.rounded(.up))

                    if lower == upper {
                        return sorted[lower]
                    }

                    let weight =
                        Float(position - Double(lower))

                    return sorted[lower]
                        + (sorted[upper] - sorted[lower])
                        * weight
                }

                for index in radialZones.indices {
                    let values = radialZones[index]

                    guard !values.isEmpty else {
                        continue
                    }

                    let lowerRadius =
                        Float(index) * 0.10

                    let upperRadius =
                        Float(index + 1) * 0.10

                    print(
                        String(
                            format:
                            "AURORA RADIAL RING: r=%.1f-%.1f n=%d P10=%.2fcm P50=%.2fcm P90=%.2fcm",
                            lowerRadius,
                            upperRadius,
                            values.count,
                            radialPercentile(
                                0.10,
                                values: values
                            ) * 100,
                            radialPercentile(
                                0.50,
                                values: values
                            ) * 100,
                            radialPercentile(
                                0.90,
                                values: values
                            ) * 100
                        )
                    )
                }

                var radialMedians: [Float?] =
                    Array(
                        repeating: nil,
                        count: radialZones.count
                    )

                for index in radialZones.indices {
                    let values = radialZones[index]

                    guard !values.isEmpty else {
                        continue
                    }

                    radialMedians[index] =
                        radialPercentile(
                            0.50,
                            values: values
                        )
                }

                var bestBoundaryIndex: Int?
                var bestMedianJump: Float = 0

                // Diagnostic only:
                // Search the outer half of the radial
                // profile for the strongest upward
                // P50 transition.
                for index in 5 ..< min(
                    radialMedians.count,
                    10
                ) {
                    guard let previous =
                        radialMedians[index - 1],
                        let current =
                        radialMedians[index]
                    else {
                        continue
                    }

                    let jump =
                        current - previous

                    if jump > bestMedianJump {
                        bestMedianJump = jump
                        bestBoundaryIndex = index
                    }
                }

                if let boundaryIndex =
                    bestBoundaryIndex,
                    bestMedianJump >= 0.005
                {
                    let normalizedBoundary =
                        Float(boundaryIndex) * 0.10

                    let boundaryRadiusCentimeters =
                        normalizedBoundary
                            * diagnosticRadius
                            * 100

                    let confidence =
                        min(
                            Float(1),
                            max(
                                Float(0),
                                (
                                    bestMedianJump - 0.005
                                ) / 0.020
                            )
                        )

                    print(
                        String(
                            format:
                            "AURORA FOOD BOUNDARY: normalized=%.2f radius=%.2fcm P50jump=%.2fcm confidence=%.2f",
                            normalizedBoundary,
                            boundaryRadiusCentimeters,
                            bestMedianJump * 100,
                            confidence
                        )
                    )
                } else {
                    print(
                        "AURORA FOOD BOUNDARY: unavailable"
                    )
                }
            }
        #endif

        let footprintArea =
            Float(occupiedCells.count)
                * cellSize
                * cellSize

        let axisRatio =
            majorAxis > 0
                ? minorAxis / majorAxis
                : 0

        return (
            shapePoints.count,
            majorAxis,
            minorAxis,
            footprintArea,
            axisRatio
        )
    }

    let shapeGeometry =
        topViewShapeGeometry()

    func integratedVolume(
        cellSize: Float,
        insetMeters: Float = 0
    ) -> Float {
        struct CellKey: Hashable {
            let x: Int
            let z: Int
        }

        var heights: [CellKey: [Float]] = [:]

        let validPoints = points.filter { point in
            let height =
                min(
                    max(0, point.y - supportY),
                    max(0, upperY - supportY)
                )

            return height >= 0.010
        }

        guard !validPoints.isEmpty else {
            return 0
        }

        func robustBounds(
            _ values: [Float]
        ) -> (lower: Float, upper: Float)? {
            let sorted =
                values
                    .filter(\.isFinite)
                    .sorted()

            guard sorted.count >= 20 else {
                return nil
            }

            func boundPercentile(
                _ fraction: Double
            ) -> Float {
                let position =
                    fraction * Double(sorted.count - 1)

                let lower =
                    Int(position.rounded(.down))

                let upper =
                    Int(position.rounded(.up))

                if lower == upper {
                    return sorted[lower]
                }

                let weight =
                    Float(position - Double(lower))

                return sorted[lower]
                    + (sorted[upper] - sorted[lower])
                    * weight
            }

            return (
                boundPercentile(0.02),
                boundPercentile(0.98)
            )
        }

        guard let xBounds =
            robustBounds(validPoints.map(\.x)),
            let zBounds =
            robustBounds(validPoints.map(\.z))
        else {
            return 0
        }

        let meanX =
            validPoints.reduce(Float.zero) { $0 + $1.x }
                / Float(validPoints.count)

        let meanZ =
            validPoints.reduce(Float.zero) { $0 + $1.z }
                / Float(validPoints.count)

        var covarianceXX: Float = 0
        var covarianceXZ: Float = 0
        var covarianceZZ: Float = 0

        for point in validPoints {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            covarianceXX += dx * dx
            covarianceXZ += dx * dz
            covarianceZZ += dz * dz
        }

        let divisor = Float(validPoints.count)

        covarianceXX /= divisor
        covarianceXZ /= divisor
        covarianceZZ /= divisor

        let angle =
            0.5 * atan2(
                2 * covarianceXZ,
                covarianceXX - covarianceZZ
            )

        let cosine = cos(angle)
        let sine = sin(angle)

        let alignedXValues =
            validPoints.map { point in
                let dx = point.x - meanX
                let dz = point.z - meanZ
                return dx * cosine + dz * sine
            }

        let alignedZValues =
            validPoints.map { point in
                let dx = point.x - meanX
                let dz = point.z - meanZ
                return -dx * sine + dz * cosine
            }

        guard let alignedXBounds =
            robustBounds(alignedXValues),
            let alignedZBounds =
            robustBounds(alignedZValues)
        else {
            return 0
        }

        for point in validPoints {
            let height =
                min(
                    max(0, point.y - supportY),
                    max(0, upperY - supportY)
                )

            let dx = point.x - meanX
            let dz = point.z - meanZ

            let alignedX =
                dx * cosine + dz * sine

            let alignedZ =
                -dx * sine + dz * cosine

            if insetMeters > 0 {
                guard alignedX >=
                    alignedXBounds.lower + insetMeters,
                    alignedX <=
                    alignedXBounds.upper - insetMeters,
                    alignedZ >=
                    alignedZBounds.lower + insetMeters,
                    alignedZ <=
                    alignedZBounds.upper - insetMeters
                else {
                    continue
                }
            }

            let key = CellKey(
                x: Int(floor(alignedX / cellSize)),
                z: Int(floor(alignedZ / cellSize))
            )

            heights[key, default: []].append(height)
        }

        let cellArea =
            cellSize * cellSize

        var volume: Float = 0
        var summedCellHeights: Float = 0
        var populatedCellCount = 0

        for values in heights.values {
            guard !values.isEmpty else {
                continue
            }

            let meanHeight =

                values.reduce(Float.zero, +)

                / Float(values.count)

            summedCellHeights += meanHeight
            populatedCellCount += 1

            volume +=

                cellArea * meanHeight
        }

        #if DEBUG
            let occupiedArea =
                Float(populatedCellCount) * cellArea

            let averageCellHeight =
                populatedCellCount > 0
                    ? summedCellHeights / Float(populatedCellCount)
                    : 0

            print(
                String(
                    format:
                    "AURORA GRID: cell=%.1fmm inset=%.1fmm validPoints=%d cells=%d area=%.1fcm2 meanHeight=%.2fcm volume=%.0fml",
                    cellSize * 1000,
                    insetMeters * 1000,
                    validPoints.count,
                    populatedCellCount,
                    occupiedArea * 10000,
                    averageCellHeight * 100,
                    volume * 1_000_000
                )
            )
        #endif

        return volume
    }

    return AuroraTopViewVolume(
        captureIndex: top.captureIndex,
        downwardAngleDegrees: top.downwardAngleDegrees,
        pointCount: points.count,
        supportY: supportY,
        volume5mmCubicMeters:
        integratedVolume(cellSize: 0.005),
        volume7_5mmCubicMeters:
        integratedVolume(cellSize: 0.0075),
        volume10mmCubicMeters:
        integratedVolume(cellSize: 0.010),

        inner10mmVolume5mmCubicMeters:
        integratedVolume(
            cellSize: 0.005,
            insetMeters: 0.010
        ),

        inner15mmVolume5mmCubicMeters:
        integratedVolume(
            cellSize: 0.005,
            insetMeters: 0.015
        ),
        heightP02Meters:
        heightP02,
        heightP10Meters:
        heightP10,
        heightP25Meters:
        heightP25,
        heightP50Meters:
        heightP50,
        heightP75Meters:
        heightP75,
        heightP90Meters:
        heightP90,
        heightP98Meters:
        heightP98,
        shapePointCount:
        shapeGeometry.pointCount,
        shapeMajorAxisMeters:
        shapeGeometry.majorAxis,
        shapeMinorAxisMeters:
        shapeGeometry.minorAxis,
        shapeFootprintSquareMeters:
        shapeGeometry.footprintArea,
        shapeAxisRatio:
        shapeGeometry.axisRatio
    )
}

func auroraFusedGeometry(
    from captures: [AuroraMealCapture]
) -> AuroraFusedGeometry? {
    let points =
        captures
            .compactMap(\.metricGeometry)
            .flatMap(\.worldPoints)

    guard points.count >= 200 else {
        return nil
    }

    func robustBounds(
        _ values: [Float]
    ) -> (lower: Float, upper: Float)? {
        let sorted = values
            .filter(\.isFinite)
            .sorted()

        guard sorted.count >= 20 else {
            return nil
        }

        func percentile(_ fraction: Double) -> Float {
            let position =
                fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))

            if lower == upper {
                return sorted[lower]
            }

            let weight =
                Float(position - Double(lower))

            return sorted[lower]
                + (sorted[upper] - sorted[lower]) * weight
        }

        return (
            percentile(0.02),
            percentile(0.98)
        )
    }

    let yValues = points.map(\.y).filter(\.isFinite).sorted()

    guard let x = robustBounds(points.map(\.x)),
          let y = robustBounds(points.map(\.y)),
          let z = robustBounds(points.map(\.z)),
          yValues.count >= 20
    else {
        return nil
    }

    func yPercentile(_ fraction: Double) -> Float {
        let position =
            fraction * Double(yValues.count - 1)

        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))

        if lower == upper {
            return yValues[lower]
        }

        let weight =
            Float(position - Double(lower))

        return yValues[lower]
            + (yValues[upper] - yValues[lower]) * weight
    }

    let supportY = yPercentile(0.10)

    func geometryAboveSupport(
        offset: Float
    ) -> (count: Int, x: Float, z: Float) {
        let filtered =
            points.filter {
                $0.y >= supportY + offset
            }

        guard filtered.count >= 20,
              let bx = robustBounds(filtered.map(\.x)),
              let bz = robustBounds(filtered.map(\.z))
        else {
            return (filtered.count, 0, 0)
        }

        return (
            filtered.count,
            bx.upper - bx.lower,
            bz.upper - bz.lower
        )
    }

    let cut05 = geometryAboveSupport(offset: 0.005)
    let cut10 = geometryAboveSupport(offset: 0.010)
    let cut15 = geometryAboveSupport(offset: 0.015)

    let objectPoints =
        points.filter {
            $0.y >= supportY + 0.010
        }

    func orientedXZGeometry(
        _ input: [SIMD3<Float>]
    ) -> (count: Int, length: Float, width: Float) {
        guard input.count >= 20 else {
            return (input.count, 0, 0)
        }

        let meanX =
            input.reduce(Float.zero) { $0 + $1.x }
                / Float(input.count)

        let meanZ =
            input.reduce(Float.zero) { $0 + $1.z }
                / Float(input.count)

        var covarianceXX: Float = 0
        var covarianceXZ: Float = 0
        var covarianceZZ: Float = 0

        for point in input {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            covarianceXX += dx * dx
            covarianceXZ += dx * dz
            covarianceZZ += dz * dz
        }

        let divisor = Float(input.count)

        covarianceXX /= divisor
        covarianceXZ /= divisor
        covarianceZZ /= divisor

        // Principal-axis angle for the 2x2 covariance matrix.
        let angle =
            0.5 * atan2(
                2 * covarianceXZ,
                covarianceXX - covarianceZZ
            )

        let cosine = cos(angle)
        let sine = sin(angle)

        var axis1: [Float] = []
        var axis2: [Float] = []

        axis1.reserveCapacity(input.count)
        axis2.reserveCapacity(input.count)

        for point in input {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            axis1.append(
                dx * cosine + dz * sine
            )

            axis2.append(
                -dx * sine + dz * cosine
            )
        }

        guard let bound1 = robustBounds(axis1),
              let bound2 = robustBounds(axis2)
        else {
            return (input.count, 0, 0)
        }

        let extent1 = bound1.upper - bound1.lower
        let extent2 = bound2.upper - bound2.lower

        return (
            input.count,
            max(extent1, extent2),
            min(extent1, extent2)
        )
    }

    let oriented = orientedXZGeometry(objectPoints)

    let objectHeight =
        max(
            0,
            yPercentile(0.98) - supportY
        )

    func integratedVolume(
        cellSize: Float
    ) -> Float {
        guard objectPoints.count >= 20,
              cellSize > 0
        else {
            return 0
        }

        let meanX =
            objectPoints.reduce(Float.zero) { $0 + $1.x }
                / Float(objectPoints.count)

        let meanZ =
            objectPoints.reduce(Float.zero) { $0 + $1.z }
                / Float(objectPoints.count)

        var covarianceXX: Float = 0
        var covarianceXZ: Float = 0
        var covarianceZZ: Float = 0

        for point in objectPoints {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            covarianceXX += dx * dx
            covarianceXZ += dx * dz
            covarianceZZ += dz * dz
        }

        let divisor = Float(objectPoints.count)

        covarianceXX /= divisor
        covarianceXZ /= divisor
        covarianceZZ /= divisor

        let angle =
            0.5 * atan2(
                2 * covarianceXZ,
                covarianceXX - covarianceZZ
            )

        let cosine = cos(angle)
        let sine = sin(angle)

        struct CellKey: Hashable {
            let x: Int
            let z: Int
        }

        var maximumHeightPerCell: [CellKey: Float] = [:]
        maximumHeightPerCell.reserveCapacity(
            objectPoints.count / 4
        )

        for point in objectPoints {
            let dx = point.x - meanX
            let dz = point.z - meanZ

            let alignedX =
                dx * cosine + dz * sine

            let alignedZ =
                -dx * sine + dz * cosine

            let cellX =
                Int(floor(alignedX / cellSize))

            let cellZ =
                Int(floor(alignedZ / cellSize))

            let height =
                max(0, point.y - supportY)

            guard height.isFinite,
                  height > 0
            else {
                continue
            }

            let key = CellKey(
                x: cellX,
                z: cellZ
            )

            if let current = maximumHeightPerCell[key] {
                maximumHeightPerCell[key] =
                    max(current, height)
            } else {
                maximumHeightPerCell[key] = height
            }
        }

        let cellArea =
            cellSize * cellSize

        return maximumHeightPerCell.values.reduce(Float.zero) {
            $0 + cellArea * $1
        }
    }

    let volume5mm =
        integratedVolume(cellSize: 0.005)

    let volume7_5mm =
        integratedVolume(cellSize: 0.0075)

    let volume10mm =
        integratedVolume(cellSize: 0.010)

    return AuroraFusedGeometry(
        pointCount: points.count,
        extentX: x.upper - x.lower,
        extentY: y.upper - y.lower,
        extentZ: z.upper - z.lower,
        yP02: yPercentile(0.02),
        yP10: yPercentile(0.10),
        yP50: yPercentile(0.50),
        yP90: yPercentile(0.90),
        yP98: yPercentile(0.98),
        cut05PointCount: cut05.count,
        cut05ExtentX: cut05.x,
        cut05ExtentZ: cut05.z,
        cut10PointCount: cut10.count,
        cut10ExtentX: cut10.x,
        cut10ExtentZ: cut10.z,
        cut15PointCount: cut15.count,
        cut15ExtentX: cut15.x,
        cut15ExtentZ: cut15.z,
        orientedPointCount: oriented.count,
        orientedLength: oriented.length,
        orientedWidth: oriented.width,
        objectHeight: objectHeight,
        volume5mmCubicMeters: volume5mm,
        volume7_5mmCubicMeters: volume7_5mm,
        volume10mmCubicMeters: volume10mm
    )
}

struct AuroraMealCapture: @unchecked Sendable {
    let image: UIImage
    let depthSnapshot: AuroraDepthSnapshot?
    let foregroundMask: AuroraForegroundMask?
    let cameraGeometry: AuroraCameraGeometry?
    let metricGeometry: AuroraMetricGeometry?
    let capturedAt: Date

    init(
        image: UIImage,
        depthSnapshot: AuroraDepthSnapshot?,
        foregroundMask: AuroraForegroundMask? = nil,
        cameraGeometry: AuroraCameraGeometry? = nil,
        metricGeometry: AuroraMetricGeometry? = nil,
        capturedAt: Date = Date()
    ) {
        self.image = image
        self.depthSnapshot = depthSnapshot
        self.foregroundMask = foregroundMask
        self.cameraGeometry = cameraGeometry
        self.metricGeometry = metricGeometry
        self.capturedAt = capturedAt
    }

    var hasUsableDepthData: Bool {
        depthSnapshot?.hasUsableDepthData == true
    }
}

final class AuroraDepthProbeModel: NSObject, ObservableObject, ARSessionDelegate {
    private struct StoredDepthFrame {
        let values: [Float]
        let edgeStrengths: [UInt8]
        let width: Int
        let height: Int
        let capturedAt: Date
        let cameraGeometry: AuroraCameraGeometry
    }

    @Published var centerDepth: Float?
    @Published var minimumDepth: Float?
    @Published var maximumDepth: Float?
    @Published var depthWidth = 0
    @Published var depthHeight = 0
    @Published var roiMeanDepth: Float?
    @Published var roiStandardDeviation: Float?
    @Published var roiSampleCount = 0
    @Published var heatmapImage: UIImage?
    @Published private(set) var latestSnapshot: AuroraDepthSnapshot?
    @Published private(set) var latestMealCapture: AuroraMealCapture?
    @Published var receivedFrameCount = 0
    @Published var activeDepthSemantic = "noch nicht gestartet"
    @Published var depthStatus = "Warte auf AR-Frames …"

    private let imageContext = CIContext()
    private var latestDepthFrame: StoredDepthFrame?
    private var lastUpdate = Date.distantPast
    private var totalFrameCount = 0

    func start(session: ARSession) {
        let configuration = ARWorldTrackingConfiguration()

        let semanticDescription: String

        if ARWorldTrackingConfiguration
            .supportsFrameSemantics(.smoothedSceneDepth)
        {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
            semanticDescription = "smoothedSceneDepth"
        } else if ARWorldTrackingConfiguration
            .supportsFrameSemantics(.sceneDepth)
        {
            configuration.frameSemantics.insert(.sceneDepth)
            semanticDescription = "sceneDepth"
        } else {
            semanticDescription = "keine Tiefensemantik unterstützt"
        }

        DispatchQueue.main.async { [weak self] in
            self?.activeDepthSemantic = semanticDescription
            self?.depthStatus = "ARSession wird gestartet …"
        }

        session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    func session(_: ARSession, didUpdate frame: ARFrame) {
        totalFrameCount += 1
        let currentFrameCount = totalFrameCount

        guard Date().timeIntervalSince(lastUpdate) >= 0.2 else { return }
        lastUpdate = Date()

        let smoothedDepthAvailable = frame.smoothedSceneDepth != nil
        let sceneDepthAvailable = frame.sceneDepth != nil

        DispatchQueue.main.async { [weak self] in
            self?.receivedFrameCount = currentFrameCount
        }

        guard let depthData =
            frame.smoothedSceneDepth ?? frame.sceneDepth
        else {
            DispatchQueue.main.async { [weak self] in
                self?.depthStatus =
                    "Keine Depth Map – smoothed: \(smoothedDepthAvailable), scene: \(sceneDepthAvailable)"
            }
            return
        }

        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowStride =
            CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.stride

        let values = baseAddress.assumingMemoryBound(to: Float32.self)
        let center = values[(height / 2) * rowStride + (width / 2)]

        // Zentraler Messbereich:
        // ungefähr 20 % der Breite und Höhe der Depth Map.
        let roiHalfWidth = max(8, width / 10)
        let roiHalfHeight = max(8, height / 10)

        let roiMinX = max(0, width / 2 - roiHalfWidth)
        let roiMaxX = min(width - 1, width / 2 + roiHalfWidth)
        let roiMinY = max(0, height / 2 - roiHalfHeight)
        let roiMaxY = min(height - 1, height / 2 + roiHalfHeight)

        var roiSum: Double = 0
        var roiSumSquares: Double = 0
        var roiCount = 0
        var roiValues: [Float] = []
        roiValues.reserveCapacity(
            (roiMaxX - roiMinX + 1) * (roiMaxY - roiMinY + 1)
        )

        for y in roiMinY ... roiMaxY {
            for x in roiMinX ... roiMaxX {
                let value = values[y * rowStride + x]

                guard value.isFinite, value > 0.05, value < 5 else {
                    continue
                }

                let doubleValue = Double(value)
                roiSum += doubleValue
                roiSumSquares += doubleValue * doubleValue
                roiValues.append(value)
                roiCount += 1
            }
        }

        let roiMean: Float?
        let roiDeviation: Float?

        if roiCount > 0 {
            let mean = roiSum / Double(roiCount)
            let variance = max(
                0,
                roiSumSquares / Double(roiCount) - mean * mean
            )

            roiMean = Float(mean)
            roiDeviation = Float(variance.squareRoot())
        } else {
            roiMean = nil
            roiDeviation = nil
        }

        let rawSortedROIValues = roiValues.sorted()

        func percentile(
            _ fraction: Double,
            in sortedValues: [Float]
        ) -> Float? {
            guard !sortedValues.isEmpty else {
                return nil
            }

            let position =
                fraction * Double(sortedValues.count - 1)

            let lowerIndex = Int(position.rounded(.down))
            let upperIndex = Int(position.rounded(.up))

            if lowerIndex == upperIndex {
                return sortedValues[lowerIndex]
            }

            let weight = Float(position - Double(lowerIndex))
            let lower = sortedValues[lowerIndex]
            let upper = sortedValues[upperIndex]

            return lower + (upper - lower) * weight
        }

        // Robuste Hintergrundfilterung:
        // Der Median repräsentiert die dominante Oberfläche im zentralen
        // Messbereich. Die mediane absolute Abweichung (MAD) bestimmt,
        // welche Tiefenwerte geometrisch noch zu dieser Oberfläche gehören.
        let rawMedian = percentile(
            0.50,
            in: rawSortedROIValues
        )

        let absoluteDeviations = rawMedian.map { median in
            rawSortedROIValues
                .map { abs($0 - median) }
                .sorted()
        } ?? []

        let medianAbsoluteDeviation = percentile(
            0.50,
            in: absoluteDeviations
        )

        // Mindestens 3 cm Toleranz, höchstens 20 cm.
        // Der obere Grenzwert verhindert, dass entfernte Wände oder der
        // Hintergrund bei Seitenaufnahmen in die Mahlzeitengeometrie geraten.
        let adaptiveDepthTolerance = min(
            Float(0.20),
            max(
                Float(0.03),
                (medianAbsoluteDeviation ?? 0) * 6
            )
        )

        let filteredROIValues: [Float]

        if let rawMedian {
            let candidates = rawSortedROIValues.filter {
                abs($0 - rawMedian) <= adaptiveDepthTolerance
            }

            // Nur übernehmen, wenn noch ausreichend Messpunkte verbleiben.
            filteredROIValues =
                candidates.count >= max(100, rawSortedROIValues.count / 3)
                    ? candidates
                    : rawSortedROIValues
        } else {
            filteredROIValues = rawSortedROIValues
        }

        // Mittelwert und Streuung jetzt ausschließlich aus den robust
        // gefilterten Tiefenpunkten berechnen.
        let filteredMean: Float?
        let filteredDeviation: Float?

        if !filteredROIValues.isEmpty {
            let sum = filteredROIValues.reduce(0.0) {
                $0 + Double($1)
            }

            let mean = sum / Double(filteredROIValues.count)

            let squareSum = filteredROIValues.reduce(0.0) {
                let difference = Double($1) - mean
                return $0 + difference * difference
            }

            filteredMean = Float(mean)
            filteredDeviation = Float(
                (squareSum / Double(filteredROIValues.count))
                    .squareRoot()
            )
        } else {
            filteredMean = nil
            filteredDeviation = nil
        }

        // Kleinere Tiefe = näher an der Kamera.
        // P10 repräsentiert robuste nahe Flächen, P90 robuste ferne Flächen.
        let nearDepthPercentile = percentile(
            0.10,
            in: filteredROIValues
        )
        let medianDepth = percentile(
            0.50,
            in: filteredROIValues
        )
        let farDepthPercentile = percentile(
            0.90,
            in: filteredROIValues
        )

        let reliefDepth: Float? = {
            guard let nearDepthPercentile,
                  let farDepthPercentile,
                  farDepthPercentile >= nearDepthPercentile
            else {
                return nil
            }

            return farDepthPercentile - nearDepthPercentile
        }()

        var minimum = Float.greatestFiniteMagnitude
        var maximum: Float = 0

        // Für die Diagnose genügt ein grobes Raster; das reduziert die Last.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let value = values[y * rowStride + x]

                guard value.isFinite, value > 0.05, value < 5 else {
                    continue
                }

                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }

        let validCenter =
            center.isFinite && center > 0.05 && center < 5
                ? center
                : nil

        let validMinimum =
            minimum < Float.greatestFiniteMagnitude
                ? minimum
                : nil

        let validMaximum = maximum > 0 ? maximum : nil

        let heatmap = makeHeatmapImage(
            values: values,
            width: width,
            height: height,
            rowStride: rowStride,
            minimumDepth: validMinimum,
            maximumDepth: validMaximum
        )

        let capturedAt = Date()

        var copiedDepthValues = [Float](
            repeating: .nan,
            count: width * height
        )

        for y in 0 ..< height {
            for x in 0 ..< width {
                copiedDepthValues[y * width + x] =
                    values[y * rowStride + x]
            }
        }

        let alignedEdgeStrengths =
            makeAlignedEdgeStrengths(
                from: frame.capturedImage,
                targetWidth: width,
                targetHeight: height
            )
            ?? [UInt8](
                repeating: 0,
                count: width * height
            )

        let cameraGeometry = AuroraCameraGeometry(
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolutionWidth: Int(frame.camera.imageResolution.width),
            imageResolutionHeight: Int(frame.camera.imageResolution.height)
        )

        let storedDepthFrame = StoredDepthFrame(
            values: copiedDepthValues,
            edgeStrengths: alignedEdgeStrengths,
            width: width,
            height: height,
            capturedAt: capturedAt,
            cameraGeometry: cameraGeometry
        )

        let snapshot = AuroraDepthSnapshot(
            capturedAt: capturedAt,
            centerDepth: validCenter,
            meanDepth: filteredMean,
            standardDeviation: filteredDeviation,
            nearDepthPercentile: nearDepthPercentile,
            medianDepth: medianDepth,
            farDepthPercentile: farDepthPercentile,
            reliefDepth: reliefDepth,
            minimumDepth: validMinimum,
            maximumDepth: validMaximum,
            sampleCount: filteredROIValues.count,
            depthMapWidth: width,
            depthMapHeight: height
        )

        let cameraImage = makeCameraImage(
            from: frame.capturedImage
        )

        let mealCapture = cameraImage.map {
            AuroraMealCapture(
                image: $0,
                depthSnapshot: snapshot,
                cameraGeometry: cameraGeometry,
                capturedAt: capturedAt
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.centerDepth = validCenter
            self?.minimumDepth = validMinimum
            self?.maximumDepth = validMaximum
            self?.depthWidth = width
            self?.depthHeight = height
            self?.roiMeanDepth = filteredMean
            self?.roiStandardDeviation = filteredDeviation
            self?.roiSampleCount = filteredROIValues.count
            self?.heatmapImage = heatmap

            self?.latestSnapshot = snapshot
            self?.latestMealCapture = mealCapture
            self?.latestDepthFrame = storedDepthFrame

            self?.depthStatus =
                "Depth Map empfangen: smoothed \(frame.smoothedSceneDepth != nil), scene \(frame.sceneDepth != nil)"
        }
    }

    func captureCurrentSnapshot() -> AuroraDepthSnapshot? {
        guard let latestSnapshot,
              latestSnapshot.hasUsableDepthData
        else {
            return nil
        }

        return latestSnapshot
    }

    func captureCurrentMealCapture() -> AuroraMealCapture? {
        guard let latestMealCapture,
              latestMealCapture.hasUsableDepthData
        else {
            return nil
        }

        return latestMealCapture
    }

    func captureCurrentMealCaptureWithForegroundMask()
        -> AuroraMealCapture?
    {
        guard let capture = captureCurrentMealCapture() else {
            return nil
        }

        let mask =
            latestDepthFrame.flatMap(
                makeDepthConnectedMask
            )
            ?? makeForegroundMask(
                from: capture.image
            )

        #if DEBUG
            if let mask {
                print(
                    String(
                        format:
                        "AURORA SEGMENTATION: mask coverage %.1f%%",
                        mask.coverage * 100
                    )
                )
            } else {
                print(
                    "AURORA SEGMENTATION: no usable mask"
                )
            }
        #endif

        let maskedSnapshot: AuroraDepthSnapshot?

        if let mask,
           let depthFrame = latestDepthFrame,
           abs(
               depthFrame.capturedAt
                   .timeIntervalSince(capture.capturedAt)
           ) < 0.5
        {
            maskedSnapshot = makeMaskedDepthSnapshot(
                from: depthFrame,
                mask: mask,
                fallback: capture.depthSnapshot
            )
        } else {
            maskedSnapshot = capture.depthSnapshot
        }

        let metricGeometry: AuroraMetricGeometry?

        if let mask,
           let depthFrame = latestDepthFrame,
           abs(
               depthFrame.capturedAt
                   .timeIntervalSince(capture.capturedAt)
           ) < 0.5
        {
            metricGeometry = makeMetricGeometry(
                from: depthFrame,
                mask: mask
            )
        } else {
            metricGeometry = nil
        }

        return AuroraMealCapture(
            image: capture.image,
            depthSnapshot: maskedSnapshot,
            foregroundMask: mask,
            cameraGeometry: capture.cameraGeometry,
            metricGeometry: metricGeometry,
            capturedAt: capture.capturedAt
        )
    }

    private func makeMetricGeometry(
        from frame: StoredDepthFrame,
        mask: AuroraForegroundMask
    ) -> AuroraMetricGeometry? {
        let width = frame.width
        let height = frame.height

        guard width > 0,
              height > 0,
              frame.values.count == width * height,
              frame.cameraGeometry.imageResolutionWidth > 0,
              frame.cameraGeometry.imageResolutionHeight > 0
        else {
            return nil
        }

        let intrinsics = frame.cameraGeometry.intrinsics

        // ARCamera intrinsics refer to the full captured-image resolution.
        // Scale them to the lower-resolution LiDAR depth map.
        let scaleX =
            Float(width)
                / Float(frame.cameraGeometry.imageResolutionWidth)
        let scaleY =
            Float(height)
                / Float(frame.cameraGeometry.imageResolutionHeight)

        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY

        guard fx.isFinite,
              fy.isFinite,
              cx.isFinite,
              cy.isFinite,
              fx > 0,
              fy > 0
        else {
            return nil
        }

        var minimumX = Float.greatestFiniteMagnitude
        var maximumX = -Float.greatestFiniteMagnitude
        var minimumY = Float.greatestFiniteMagnitude
        var maximumY = -Float.greatestFiniteMagnitude
        var minimumZ = Float.greatestFiniteMagnitude
        var maximumZ = -Float.greatestFiniteMagnitude
        var pointCount = 0
        var worldPoints: [SIMD3<Float>] = []
        worldPoints.reserveCapacity(
            max(256, mask.foregroundPixelCount)
        )

        for y in 0 ..< height {
            let normalizedY =
                (Float(y) + 0.5) / Float(height)

            for x in 0 ..< width {
                let normalizedX =
                    (Float(x) + 0.5) / Float(width)

                guard mask.containsForeground(
                    normalizedX: normalizedX,
                    normalizedY: normalizedY
                ) else {
                    continue
                }

                let z = frame.values[y * width + x]

                guard z.isFinite,
                      z > 0.05,
                      z < 2.0
                else {
                    continue
                }

                let cameraX =
                    (Float(x) + 0.5 - cx) * z / fx
                let cameraY =
                    (Float(y) + 0.5 - cy) * z / fy

                minimumX = min(minimumX, cameraX)
                maximumX = max(maximumX, cameraX)
                minimumY = min(minimumY, cameraY)
                maximumY = max(maximumY, cameraY)
                minimumZ = min(minimumZ, z)
                maximumZ = max(maximumZ, z)

                let cameraPoint = SIMD4<Float>(
                    cameraX,
                    -cameraY,
                    -z,
                    1
                )

                let worldPoint4 =
                    frame.cameraGeometry.transform * cameraPoint

                let worldPoint = SIMD3<Float>(
                    worldPoint4.x,
                    worldPoint4.y,
                    worldPoint4.z
                )

                if worldPoint.x.isFinite,
                   worldPoint.y.isFinite,
                   worldPoint.z.isFinite
                {
                    worldPoints.append(worldPoint)
                }

                pointCount += 1
            }
        }

        guard pointCount >= 80,
              minimumX.isFinite,
              maximumX.isFinite,
              minimumY.isFinite,
              maximumY.isFinite,
              minimumZ.isFinite,
              maximumZ.isFinite
        else {
            return nil
        }

        let geometry = AuroraMetricGeometry(
            pointCount: pointCount,
            widthMeters: maximumX - minimumX,
            heightMeters: maximumY - minimumY,
            depthMeters: maximumZ - minimumZ,
            worldPoints: worldPoints
        )

        #if DEBUG
            print(
                String(
                    format:
                    "AURORA METRIC 3D: points=%d width=%.1f cm height=%.1f cm depth=%.1f cm",
                    geometry.pointCount,
                    geometry.widthCentimeters,
                    geometry.heightCentimeters,
                    geometry.depthCentimeters
                )
            )
        #endif

        return geometry
    }

    private func makeMaskedDepthSnapshot(
        from frame: StoredDepthFrame,
        mask: AuroraForegroundMask,
        fallback: AuroraDepthSnapshot?
    ) -> AuroraDepthSnapshot? {
        let width = frame.width
        let height = frame.height

        guard width > 0,
              height > 0,
              frame.values.count == width * height
        else {
            return fallback
        }

        var maskedValues: [Float] = []
        maskedValues.reserveCapacity(
            max(128, mask.foregroundPixelCount)
        )

        for y in 0 ..< height {
            let normalizedY =
                (Float(y) + 0.5) / Float(height)

            for x in 0 ..< width {
                let normalizedX =
                    (Float(x) + 0.5) / Float(width)

                guard mask.containsForeground(
                    normalizedX: normalizedX,
                    normalizedY: normalizedY
                ) else {
                    continue
                }

                let depth = frame.values[y * width + x]

                guard depth.isFinite,
                      depth > 0.05,
                      depth < 2.0
                else {
                    continue
                }

                maskedValues.append(depth)
            }
        }

        let minimumRequiredSamples = max(
            80,
            width * height / 1000
        )

        guard maskedValues.count >= minimumRequiredSamples else {
            #if DEBUG
                print(
                    "AURORA MASKED DEPTH: only "
                        + "\(maskedValues.count) valid samples; "
                        + "using ROI fallback"
                )
            #endif

            return fallback
        }

        let rawSortedValues = maskedValues.sorted()

        func percentile(
            _ fraction: Double,
            in sortedValues: [Float]
        ) -> Float? {
            guard !sortedValues.isEmpty else {
                return nil
            }

            let position =
                fraction * Double(sortedValues.count - 1)

            let lowerIndex =
                Int(position.rounded(.down))

            let upperIndex =
                Int(position.rounded(.up))

            if lowerIndex == upperIndex {
                return sortedValues[lowerIndex]
            }

            let weight =
                Float(position - Double(lowerIndex))

            let lower = sortedValues[lowerIndex]
            let upper = sortedValues[upperIndex]

            return lower + (upper - lower) * weight
        }

        guard let rawMedian = percentile(
            0.50,
            in: rawSortedValues
        ) else {
            return fallback
        }

        let absoluteDeviations =
            rawSortedValues
                .map { abs($0 - rawMedian) }
                .sorted()

        let medianAbsoluteDeviation =
            percentile(
                0.50,
                in: absoluteDeviations
            ) ?? 0

        let adaptiveTolerance = min(
            Float(0.15),
            max(
                Float(0.02),
                medianAbsoluteDeviation * 6
            )
        )

        let filteredValues =
            rawSortedValues.filter {
                abs($0 - rawMedian)
                    <= adaptiveTolerance
            }

        guard filteredValues.count >= minimumRequiredSamples else {
            #if DEBUG
                print(
                    "AURORA MASKED DEPTH: filtering left only "
                        + "\(filteredValues.count) samples; "
                        + "using ROI fallback"
                )
            #endif

            return fallback
        }

        let sum = filteredValues.reduce(0.0) {
            $0 + Double($1)
        }

        let mean =
            sum / Double(filteredValues.count)

        let squareSum =
            filteredValues.reduce(0.0) {
                let difference =
                    Double($1) - mean

                return $0 + difference * difference
            }

        let standardDeviation =
            Float(
                (
                    squareSum
                        / Double(filteredValues.count)
                ).squareRoot()
            )

        let nearDepth =
            percentile(0.10, in: filteredValues)

        let medianDepth =
            percentile(0.50, in: filteredValues)

        let farDepth =
            percentile(0.90, in: filteredValues)

        let reliefDepth: Float? = {
            guard let nearDepth,
                  let farDepth,
                  farDepth >= nearDepth
            else {
                return nil
            }

            return farDepth - nearDepth
        }()

        let centerIndex =
            (height / 2) * width + (width / 2)

        let rawCenterDepth =
            frame.values[centerIndex]

        let centerDepth: Float? =
            rawCenterDepth.isFinite
                && rawCenterDepth > 0.05
                && rawCenterDepth < 2.0
                ? rawCenterDepth
                : medianDepth

        let snapshot = AuroraDepthSnapshot(
            capturedAt: frame.capturedAt,
            centerDepth: centerDepth,
            meanDepth: Float(mean),
            standardDeviation: standardDeviation,
            nearDepthPercentile: nearDepth,
            medianDepth: medianDepth,
            farDepthPercentile: farDepth,
            reliefDepth: reliefDepth,
            minimumDepth: filteredValues.first,
            maximumDepth: filteredValues.last,
            sampleCount: filteredValues.count,
            depthMapWidth: width,
            depthMapHeight: height
        )

        #if DEBUG
            print(
                String(
                    format:
                    "AURORA MASKED DEPTH: coverage %.1f%%, samples %d, relief %.1f mm",
                    mask.coverage * 100,
                    filteredValues.count,
                    (reliefDepth ?? 0) * 1000
                )
            )
        #endif

        return snapshot
    }

    private func makeDepthConnectedMask(
        from frame: StoredDepthFrame
    ) -> AuroraForegroundMask? {
        let width = frame.width
        let height = frame.height
        let values = frame.values
        let edgeStrengths = frame.edgeStrengths

        guard width > 0,
              height > 0,
              values.count == width * height,
              edgeStrengths.count == width * height
        else {
            return nil
        }

        func isValidDepth(_ value: Float) -> Bool {
            value.isFinite && value > 0.05 && value < 2.0
        }

        let centerX = width / 2
        let centerY = height / 2
        var seedCandidates: [Float] = []

        for y in max(0, centerY - 3) ... min(height - 1, centerY + 3) {
            for x in max(0, centerX - 3) ... min(width - 1, centerX + 3) {
                let value = values[y * width + x]

                if isValidDepth(value) {
                    seedCandidates.append(value)
                }
            }
        }

        guard !seedCandidates.isEmpty else {
            return nil
        }

        seedCandidates.sort()

        let seedDepth =
            seedCandidates[seedCandidates.count / 2]

        let absoluteTolerance = min(
            Float(0.10),
            max(Float(0.025), seedDepth * 0.18)
        )

        let localTolerance = min(
            Float(0.045),
            max(Float(0.012), absoluteTolerance * 0.55)
        )

        let minX = width / 10
        let maxX = width - width / 10 - 1
        let minY = height / 12
        let maxY = height - height / 12 - 1

        let minimumUsefulPixels = max(
            80,
            width * height / 500
        )

        // Nur ausgeprägte RGB-Kanten stoppen das Wachstum.
        // Kleine Texturen und Reflexe innerhalb eines Lebensmittels sollen
        // die zusammenhängende Region nicht unnötig zerschneiden.
        let strongEdgeThreshold: UInt8 = 92

        func growRegion(
            useRGBEdges: Bool
        ) -> AuroraForegroundMask? {
            var visited = [Bool](
                repeating: false,
                count: width * height
            )

            var maskPixels = [UInt8](
                repeating: 0,
                count: width * height
            )

            var queue: [(Int, Int)] = [
                (centerX, centerY)
            ]

            var queueIndex = 0
            var foregroundCount = 0

            while queueIndex < queue.count {
                let (x, y) = queue[queueIndex]
                queueIndex += 1

                guard x >= minX,
                      x <= maxX,
                      y >= minY,
                      y <= maxY
                else {
                    continue
                }

                let index = y * width + x

                guard !visited[index] else {
                    continue
                }

                visited[index] = true

                let depth = values[index]

                guard isValidDepth(depth),
                      abs(depth - seedDepth) <= absoluteTolerance
                else {
                    continue
                }

                maskPixels[index] = 1
                foregroundCount += 1

                let neighbours = [
                    (x - 1, y),
                    (x + 1, y),
                    (x, y - 1),
                    (x, y + 1)
                ]

                for (nextX, nextY) in neighbours {
                    guard nextX >= minX,
                          nextX <= maxX,
                          nextY >= minY,
                          nextY <= maxY
                    else {
                        continue
                    }

                    let nextIndex =
                        nextY * width + nextX

                    let nextDepth =
                        values[nextIndex]

                    guard !visited[nextIndex],
                          isValidDepth(nextDepth),
                          abs(nextDepth - depth) <= localTolerance,
                          abs(nextDepth - seedDepth) <= absoluteTolerance
                    else {
                        continue
                    }

                    if useRGBEdges {
                        let currentEdge =
                            edgeStrengths[index]

                        let nextEdge =
                            edgeStrengths[nextIndex]

                        // Eine starke Kante an einem der beiden Pixel
                        // wird als mögliche Objektgrenze behandelt.
                        guard max(currentEdge, nextEdge)
                            < strongEdgeThreshold
                        else {
                            continue
                        }
                    }

                    queue.append(
                        (nextX, nextY)
                    )
                }
            }

            guard foregroundCount >= minimumUsefulPixels else {
                return nil
            }

            return AuroraForegroundMask(
                width: width,
                height: height,
                pixels: maskPixels,
                foregroundPixelCount:
                foregroundCount
            )
        }

        let depthOnlyMask =
            growRegion(useRGBEdges: false)

        let edgeGuidedMask =
            growRegion(useRGBEdges: true)

        guard let depthOnlyMask else {
            return edgeGuidedMask
        }

        guard let edgeGuidedMask else {
            return depthOnlyMask
        }

        let retainedFraction =
            Float(edgeGuidedMask.foregroundPixelCount)
                / Float(
                    max(
                        1,
                        depthOnlyMask.foregroundPixelCount
                    )
                )

        // Fallback, falls Spiegelungen, Schatten oder interne
        // Lebensmitteltexturen die RGB-Maske zu stark zerstückeln.
        let selectedMask: AuroraForegroundMask

        if retainedFraction >= 0.12 {
            selectedMask = edgeGuidedMask
        } else {
            selectedMask = depthOnlyMask
        }

        #if DEBUG
            print(
                String(
                    format:
                    "AURORA RGB-D: depth %.1f%%, edge %.1f%%, retained %.1f%%",
                    depthOnlyMask.coverage * 100,
                    edgeGuidedMask.coverage * 100,
                    retainedFraction * 100
                )
            )
        #endif

        return selectedMask
    }

    private func makeAlignedEdgeStrengths(
        from pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard targetWidth > 2,
              targetHeight > 2
        else {
            return nil
        }

        let sourceImage =
            CIImage(cvPixelBuffer: pixelBuffer)

        let scaleX =
            CGFloat(targetWidth)
                / sourceImage.extent.width

        let scaleY =
            CGFloat(targetHeight)
                / sourceImage.extent.height

        let scaledImage =
            sourceImage.transformed(
                by: CGAffineTransform(
                    scaleX: scaleX,
                    y: scaleY
                )
            )

        var rgba = [UInt8](
            repeating: 0,
            count: targetWidth * targetHeight * 4
        )

        let rendered = rgba.withUnsafeMutableBytes {
            rawBuffer -> Bool in

            guard let baseAddress =
                rawBuffer.baseAddress
            else {
                return false
            }

            imageContext.render(
                scaledImage,
                toBitmap: baseAddress,
                rowBytes: targetWidth * 4,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: targetWidth,
                    height: targetHeight
                ),
                format: .RGBA8,
                colorSpace:
                CGColorSpaceCreateDeviceRGB()
            )

            return true
        }

        guard rendered else {
            return nil
        }

        var luminance = [Float](
            repeating: 0,
            count: targetWidth * targetHeight
        )

        for index in 0 ..< targetWidth * targetHeight {
            let pixelIndex = index * 4

            let red = Float(rgba[pixelIndex])
            let green = Float(rgba[pixelIndex + 1])
            let blue = Float(rgba[pixelIndex + 2])

            luminance[index] =
                0.299 * red
                    + 0.587 * green
                    + 0.114 * blue
        }

        var edges = [UInt8](
            repeating: 0,
            count: targetWidth * targetHeight
        )

        for y in 1 ..< targetHeight - 1 {
            for x in 1 ..< targetWidth - 1 {
                func value(
                    _ offsetX: Int,
                    _ offsetY: Int
                ) -> Float {
                    luminance[
                        (y + offsetY) * targetWidth
                            + (x + offsetX)
                    ]
                }

                let gradientX =
                    -value(-1, -1)
                        + value(1, -1)
                        - 2 * value(-1, 0)
                        + 2 * value(1, 0)
                        - value(-1, 1)
                        + value(1, 1)

                let gradientY =
                    -value(-1, -1)
                        - 2 * value(0, -1)
                        - value(1, -1)
                        + value(-1, 1)
                        + 2 * value(0, 1)
                        + value(1, 1)

                let magnitude =
                    sqrt(
                        gradientX * gradientX
                            + gradientY * gradientY
                    )

                edges[y * targetWidth + x] =
                    UInt8(
                        min(
                            255,
                            max(0, magnitude * 0.34)
                        )
                    )
            }
        }

        return edges
    }

    private func makeForegroundMask(
        from image: UIImage
    ) -> AuroraForegroundMask? {
        guard #available(iOS 17.0, *),
              let cgImage = image.cgImage
        else {
            return nil
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            options: [:]
        )

        do {
            try handler.perform([request])

            guard let observation = request.results?.first else {
                return nil
            }

            let instanceMask = observation.instanceMask

            CVPixelBufferLockBaseAddress(
                instanceMask,
                .readOnly
            )

            defer {
                CVPixelBufferUnlockBaseAddress(
                    instanceMask,
                    .readOnly
                )
            }

            guard let baseAddress =
                CVPixelBufferGetBaseAddress(instanceMask)
            else {
                return nil
            }

            let width =
                CVPixelBufferGetWidth(instanceMask)

            let height =
                CVPixelBufferGetHeight(instanceMask)

            let bytesPerRow =
                CVPixelBufferGetBytesPerRow(instanceMask)

            let source = baseAddress
                .assumingMemoryBound(to: UInt8.self)

            var pixels = [UInt8](
                repeating: 0,
                count: width * height
            )

            var foregroundPixelCount = 0

            for y in 0 ..< height {
                let sourceRow = source
                    .advanced(by: y * bytesPerRow)

                for x in 0 ..< width {
                    let isForeground =
                        sourceRow[x] != 0

                    if isForeground {
                        pixels[y * width + x] = 1
                        foregroundPixelCount += 1
                    }
                }
            }

            guard foregroundPixelCount > 0 else {
                return nil
            }

            return AuroraForegroundMask(
                width: width,
                height: height,
                pixels: pixels,
                foregroundPixelCount:
                foregroundPixelCount
            )
        } catch {
            #if DEBUG
                print(
                    "AURORA VISION: foreground mask failed: "
                        + error.localizedDescription
                )
            #endif

            return nil
        }
    }

    private func makeCameraImage(
        from pixelBuffer: CVPixelBuffer
    ) -> UIImage? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(.right)

        guard let cgImage = imageContext.createCGImage(
            sourceImage,
            from: sourceImage.extent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func makeHeatmapImage(
        values: UnsafePointer<Float32>,
        width: Int,
        height: Int,
        rowStride: Int,
        minimumDepth: Float?,
        maximumDepth: Float?
    ) -> UIImage? {
        guard let minimumDepth,
              let maximumDepth,
              maximumDepth > minimumDepth
        else {
            return nil
        }

        let range = maximumDepth - minimumDepth
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0 ..< height {
            for x in 0 ..< width {
                let depth = values[y * rowStride + x]
                let pixelIndex = (y * width + x) * 4

                guard depth.isFinite, depth > 0.05, depth < 5 else {
                    pixels[pixelIndex] = 0
                    pixels[pixelIndex + 1] = 0
                    pixels[pixelIndex + 2] = 0
                    pixels[pixelIndex + 3] = 0
                    continue
                }

                let normalized = min(
                    1,
                    max(0, (depth - minimumDepth) / range)
                )

                let hue = CGFloat(normalized) * 0.66
                let color = UIColor(
                    hue: hue,
                    saturation: 1,
                    brightness: 1,
                    alpha: 1
                )

                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0

                color.getRed(
                    &red,
                    green: &green,
                    blue: &blue,
                    alpha: &alpha
                )

                pixels[pixelIndex] = UInt8(red * 255)
                pixels[pixelIndex + 1] = UInt8(green * 255)
                pixels[pixelIndex + 2] = UInt8(blue * 255)
                pixels[pixelIndex + 3] = 255
            }
        }

        guard let provider = CGDataProvider(
            data: Data(pixels) as CFData
        ) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.last.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        // Die ARKit-Depth-Map liegt quer vor; für die Portraitansicht drehen.
        return UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: .right
        )
    }
}
