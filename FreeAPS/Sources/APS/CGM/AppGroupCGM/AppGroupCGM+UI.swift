import Combine
import Foundation
import HealthKit
import LibreTransmitter
import LoopKit
import LoopKitUI
import Swinject

extension AppGroupCGM: CGMManagerUI {
    public static var onboardingImage: UIImage? {
        nil
    }

    public static func setupViewController(
        bluetoothProvider _: LoopKit.BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopKitUI.LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> LoopKitUI.SetupUIResult<LoopKitUI.CGMManagerViewController, LoopKitUI.CGMManagerUI>
    {
        .createdAndOnboarded(AppGroupCGM())
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> CGMManagerViewController
    {
        let settings = AppGroupCGMSettingsViewController(cgmManager: self, displayGlucosePreference: displayGlucosePreference)
        let nav = CGMManagerSettingsNavigationViewController(rootViewController: settings)
        return nav
    }

    public var smallImage: UIImage? {
        nil
    }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        if let appName = appGroupSource.latestReadingFrom?.displayName ?? appGroupSource.latestReadingFromOther {
            var components = [appName]

            if appGroupSource.latestReadingFrom == .xdrip,
               let metadata = appGroupSource.xDripMetadata
            {
                if let model = metadata.sensor?.model, !model.isEmpty {
                    if metadata.transmitter?.isAnubis == true {
                        components.append("\(model) / Anubis")
                    } else {
                        components.append(model)
                    }
                }

                if let startedAt = metadata.sensor?.startedAt {
                    let sensorStart = Date(timeIntervalSince1970: startedAt)
                    let age = max(0, Date().timeIntervalSince(sensorStart))
                    let days = Int(age / 86400)
                    let hours = Int(age.truncatingRemainder(dividingBy: 86400) / 3600)

                    if days > 0 {
                        components.append("\(days) T \(hours) h")
                    } else {
                        components.append("\(hours) h")
                    }
                }

                if let sensorState = metadata.sensor?.state, !sensorState.isEmpty {
                    switch sensorState {
                    case "active":
                        components.append("Aktiv")
                    case "warmup":
                        components.append("Aufwärmphase")
                    case "stopped":
                        components.append("Gestoppt")
                    case "expired":
                        components.append("Abgelaufen")
                    case "failed":
                        components.append("Fehler")
                    case "not_started":
                        components.append("Nicht gestartet")
                    default:
                        components.append(sensorState)
                    }
                }

                if let quality = metadata.latestData?.qualityCode, !quality.isEmpty {
                    switch quality {
                    case "reliable":
                        components.append("Zuverlässig")
                    case "persistent_noise":
                        components.append("Sensorrauschen")
                    case "excess_noise":
                        components.append("Starkes Sensorrauschen")
                    case "temporary_sensor_issue":
                        components.append("Sensorproblem")
                    case "flatline":
                        components.append("Flatline")
                    case "sensor_error":
                        components.append("Sensorfehler")
                    default:
                        components.append(quality)
                    }
                }
            }

            let highlightState: DeviceStatusHighlightState = {
                guard appGroupSource.latestReadingFrom == .xdrip,
                      let quality = appGroupSource.xDripMetadata?.latestData?.qualityCode
                else {
                    return .normalCGM
                }

                switch quality {
                case "sensor_error":
                    return .critical

                case "excess_noise",
                     "flatline",
                     "persistent_noise",
                     "temporary_sensor_issue":
                    return .warning

                default:
                    return .normalCGM
                }
            }()

            return AppGroupCGMStatusHighlight(
                localizedMessage: components.joined(separator: " • "),
                imageName: "dot.radiowaves.left.and.right",
                state: highlightState
            )
        }
        return AppGroupCGMStatusHighlight(
            localizedMessage: NSLocalizedString("No readings", comment: "App Group CGM not reading status"),
            imageName: "exclamationmark.circle.fill",
            state: .warning
        )
    }

    public var cgmStatusBadge: DeviceStatusBadge? {
        nil
    }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        nil
    }
}

struct AppGroupCGMStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}
