import CGMBLEKit
import Combine
import G7SensorKit
import HealthKit
import LoopKitUI
import SwiftUI
import UIKit

extension CGM {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var deviceManager: DeviceDataManager!

        @Published var cgmSetupPresented: Bool = false
        @Published var cgmSettingsPresented: Bool = false
        @Published private(set) var cgmIdentifierToSetUp: String? = nil

        @Published var smoothGlucose = false
        @Published var sensorDays: Double = 10
        @Published var g6SensorCode = ""
        @Published var g6StartConfirmationPresented = false
        @Published var g6StopConfirmationPresented = false
        @Published var g6CalibrationValue = ""
        @Published var g6CalibrationConfirmationPresented = false
        @Published var g6CommandResultPresented = false
        @Published var g6CommandResultTitle = ""
        @Published var g6CommandResultMessage = ""

        override func subscribe() {
            subscribeSetting(\.smoothGlucose, on: $smoothGlucose, initial: { smoothGlucose = $0 })
            subscribeSetting(\.sensorDays, on: $sensorDays) { sensorDays = $0 }
        }

        var g6SensorCodeIsValid: Bool {
            g6SensorCode.count == 4 && TransmitterManager.isValidSensorCode(g6SensorCode)
        }

        func sanitizeG6SensorCode() {
            let digits = g6SensorCode.filter { $0.isNumber }
            g6SensorCode = String(digits.prefix(4))
        }

        var g6CalibrationValueMgDL: Int? {
            guard let value = Int(g6CalibrationValue),
                  (40 ... 400).contains(value)
            else {
                return nil
            }
            return value
        }

        var g6CalibrationValueIsValid: Bool {
            g6CalibrationValueMgDL != nil
        }

        func sanitizeG6CalibrationValue() {
            let digits = g6CalibrationValue.filter { $0.isNumber }
            g6CalibrationValue = String(digits.prefix(3))
        }

        func startG6Sensor(_ manager: G6CGMManager) {
            guard g6SensorCodeIsValid else { return }

            manager.setCommandResultHandler { [weak self, weak manager] command, error in
                guard case .startSensorWithCode = command else { return }

                manager?.setCommandResultHandler(nil)

                if let error {
                    self?.g6CommandResultTitle = "Sensor Start Failed"
                    self?.g6CommandResultMessage = error.localizedDescription
                } else {
                    self?.g6CommandResultTitle = "Sensor Start Command Completed"
                    self?.g6CommandResultMessage = "The Dexcom G6 start command was accepted by the transmitter."
                }

                self?.g6CommandResultPresented = true
            }

            manager.startSensor(sensorCode: g6SensorCode)
        }

        func stopG6Sensor(_ manager: G6CGMManager) {
            manager.setCommandResultHandler { [weak self, weak manager] command, error in
                guard case .stopSensor = command else { return }

                manager?.setCommandResultHandler(nil)

                if let error {
                    self?.g6CommandResultTitle = "Sensor Stop Failed"
                    self?.g6CommandResultMessage = error.localizedDescription
                } else {
                    self?.g6CommandResultTitle = "Sensor Stop Command Completed"
                    self?.g6CommandResultMessage = "The Dexcom G6 stop command was accepted by the transmitter."
                }

                self?.g6CommandResultPresented = true
            }

            manager.stopSensor()
        }

        func calibrateG6Sensor(_ manager: G6CGMManager) {
            guard let value = g6CalibrationValueMgDL else { return }
            let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(value))

            manager.setCommandResultHandler { [weak self, weak manager] command, error in
                guard case .calibrateSensor = command else { return }
                manager?.setCommandResultHandler(nil)

                if let error {
                    self?.g6CommandResultTitle = "Calibration Failed"
                    self?.g6CommandResultMessage = error.localizedDescription
                } else {
                    self?.g6CommandResultTitle = "Calibration Command Completed"
                    self?.g6CommandResultMessage = "The Dexcom G6 calibration command was accepted by the transmitter."
                }

                self?.g6CommandResultPresented = true
            }

            manager.calibrateSensor(to: quantity)
        }

        func removePumpAsCGM() {
            deviceManager.removePumpAsCGM()
        }

        func changeG6Transmitter(_ manager: G6CGMManager) {
            cgmIdentifierToSetUp = manager.pluginIdentifier
            cgmSettingsPresented = false
            cgmSetupPresented = true
        }

        func setupCGM(_ identifier: String?) {
            cgmIdentifierToSetUp = identifier
            cgmSetupPresented = identifier != nil && deviceManager.cgmManager == nil
            cgmSettingsPresented = identifier != nil && deviceManager.cgmManager?.pluginIdentifier == identifier && deviceManager
                .cgmManager?.isOnboarded == true
        }
    }
}

extension CGM.StateModel: CompletionDelegate {
    func completionNotifyingDidComplete(_: CompletionNotifying) {
        Task { @MainActor in
            setupCGM(nil)
        }
    }
}
