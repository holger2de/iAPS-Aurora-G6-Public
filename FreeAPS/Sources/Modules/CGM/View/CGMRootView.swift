import CGMBLEKit
import LoopKitUI
import SwiftUI
import Swinject

extension CGM {
    struct RootView: BaseView {
        let resolver: Resolver
        let displayGlucosePreference: DisplayGlucosePreference
        @StateObject var state: StateModel

        private var daysFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
            displayGlucosePreference = resolver.resolve(DisplayGlucosePreference.self)!
        }

        var body: some View {
            NavigationView {
                Form {
                    if let cgmManager = state.deviceManager.cgmManager as? CGMManagerUI,
                       cgmManager.isOnboarded
                    {
                        Section(header: Text("Active CGM")) {
                            HStack {
                                Text("Type")
                                Spacer()
                                Text(cgmManager.localizedTitle)
                            }
                        }
                        Section {
                            if let status = cgmManager.cgmStatusHighlight?.localizedMessage {
                                HStack {
                                    Text(status.replacingOccurrences(of: "\n", with: " "))
                                }
                            }
                            if !cgmManager.providesBLEHeartbeat {
                                HStack {
                                    Text("CGM is not used as heartbeat.")
                                }
                            }
                        }
                        Section {
                            Button("CGM Configuration") {
                                state.setupCGM(cgmManager.pluginIdentifier)
                            }
                        }
                    } else if let pumpManager = state.deviceManager.cgmManager as? PumpManagerUI {
                        Section(header: Text("Active CGM")) {
                            HStack {
                                Text("Pump+CGM")
                                Spacer()
                                Text(pumpManager.localizedTitle)
                            }
                            Button("Stop using the pump as CGM") {
                                state.removePumpAsCGM()
                            }
                        }
                    } else {
                        Section {
                            ForEach(state.deviceManager.availableCGMManagers, id: \.identifier) { cgm in
                                VStack(alignment: .leading) {
                                    Button(cgm.localizedTitle) {
                                        state.setupCGM(cgm.identifier)
                                    }
                                }
                            }
                        }
                        header: {
                            Text("Connect to CGM")
                        }
                        footer: {
                            Text(
                                "To receive reading from xDrip4iOS, Glucose Direct or another compatible app, select Shared App Group CGM."
                            )
                            .font(.caption)
                        }
                    }

                    if let cgmManager = state.deviceManager.cgmManager,
                       cgmManager.isOnboarded
                    {
                        if KnownPlugins.allowCalibrations(for: cgmManager)
                        {
                            Text("Calibrations").navigationLink(to: .calibrations, from: self)
                        }

                        if let g6Manager = cgmManager as? G6CGMManager {
                            Section(header: Text("Dexcom G6")) {
                                HStack {
                                    Text("Transmitter ID")
                                    Spacer()
                                    Text(g6Manager.transmitter.ID)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Sender wechseln") {
                                    state.changeG6Transmitter(g6Manager)
                                }
                                Toggle(
                                    "Anubis",
                                    isOn: Binding(
                                        get: { g6Manager.isAnubis },
                                        set: { g6Manager.setAnubisModeEnabled($0) }
                                    )
                                )

                                TextField("Sensor code", text: $state.g6SensorCode)
                                    .keyboardType(.numberPad)
                                    .onChange(of: state.g6SensorCode) { _ in
                                        state.sanitizeG6SensorCode()
                                    }

                                Button("Start Sensor") {
                                    state.g6StartConfirmationPresented = true
                                }
                                .disabled(!state.g6SensorCodeIsValid)
                                .alert(
                                    "Start Dexcom G6 sensor?",
                                    isPresented: $state.g6StartConfirmationPresented
                                ) {
                                    Button("Cancel", role: .cancel) {}
                                    Button("Start Sensor") {
                                        state.startG6Sensor(g6Manager)
                                    }
                                } message: {
                                    Text("Sensor code: \(state.g6SensorCode)")
                                }

                                TextField("Kalibrierwert (mg/dL)", text: $state.g6CalibrationValue)
                                    .keyboardType(.numberPad)
                                    .onChange(of: state.g6CalibrationValue) { _ in
                                        state.sanitizeG6CalibrationValue()
                                    }

                                Button("Kalibrieren") {
                                    state.g6CalibrationConfirmationPresented = true
                                }
                                .disabled(!state.g6CalibrationValueIsValid)
                                .alert(
                                    "Dexcom G6 kalibrieren?",
                                    isPresented: $state.g6CalibrationConfirmationPresented
                                ) {
                                    Button("Abbrechen", role: .cancel) {}
                                    Button("Kalibrieren") {
                                        state.calibrateG6Sensor(g6Manager)
                                    }
                                } message: {
                                    Text("\(state.g6CalibrationValue) mg/dL")
                                }

                                Button("Stop Sensor", role: .destructive) {
                                    state.g6StopConfirmationPresented = true
                                }
                                .alert(
                                    "Stop Dexcom G6 sensor?",
                                    isPresented: $state.g6StopConfirmationPresented
                                ) {
                                    Button("Cancel", role: .cancel) {}
                                    Button("Stop Sensor", role: .destructive) {
                                        state.stopG6Sensor(g6Manager)
                                    }
                                }
                            }
                            .alert(
                                state.g6CommandResultTitle,
                                isPresented: $state.g6CommandResultPresented
                            ) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text(state.g6CommandResultMessage)
                            }
                        }

                        let isXDripAppGroup =
                            (cgmManager as? AppGroupCGM)?.appGroupSource.latestReadingFrom == .xdrip

                        // For xDrip the configured value is an age warning threshold,
                        // not an assumed hard sensor expiry.
                        if isXDripAppGroup ||
                            KnownPlugins.cgmExpirationByPluginIdentifier(state.deviceManager.cgmManager) == nil
                        {
                            Section {
                                HStack {
                                    TextField("0", value: $state.sensorDays, formatter: daysFormatter)
                                    Text("days").foregroundStyle(.secondary)
                                }
                            }
                            header: {
                                Text(isXDripAppGroup ? "Sensor Age Warning" : "Sensor Life-Span")
                            }
                            footer: {
                                if isXDripAppGroup {
                                    Text(
                                        "Set the sensor age at which iAPS should show a warning."
                                    )
                                } else {
                                    Text(
                                        "When using \(cgmManager.localizedTitle) iAPS doesn't know the type of sensor used or the sensor life-span."
                                    )
                                }
                            }
                        }

                        Section(header: Text("Experimental")) {
                            Toggle("Smooth Glucose Value", isOn: $state.smoothGlucose)
                        }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .navigationTitle("CGM")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $state.cgmSetupPresented) {
                    if let identifier = state.cgmIdentifierToSetUp {
                        CGMSetupView(
                            cgmIdentifier: identifier,
                            deviceManager: state.deviceManager,
                            completionDelegate: state,
                        )
                    }
                }
                .sheet(isPresented: $state.cgmSettingsPresented) {
                    if let identifier = state.cgmIdentifierToSetUp,
                       let cgmManager = state.deviceManager.cgmManager as? CGMManagerUI,
                       cgmManager.pluginIdentifier == identifier
                    {
                        CGMSettingsView(
                            cgmManager: cgmManager,
                            deviceManager: state.deviceManager,
                            completionDelegate: state,
                        )
                    }
                }
            }
        }
    }
}
