
import Combine
import SwiftUI

final class AppGroupCGMSettingsViewModel: ObservableObject {
    let appGroupSource: AppGroupSource
    @Published var latestReadingFrom: AppGroupSourceType? = nil
    @Published var latestReadingFromOther: String? = nil
    @Published var latestReadingDate: Date? = nil
    @Published var deviceAddress: String? = nil
    @Published var xDripMetadata: XDripCGMMetadataEnvelope? = nil

    let onDelete = PassthroughSubject<Void, Never>()
    let onClose = PassthroughSubject<Void, Never>()

    init(appGroupSource: AppGroupSource) {
        self.appGroupSource = appGroupSource
    }

    func viewDidAppear() {
        updateServiceStatus()
    }

    private func updateServiceStatus() {
        latestReadingDate = appGroupSource.latestReadingDate
        latestReadingFrom = appGroupSource.latestReadingFrom
        latestReadingFromOther = appGroupSource.latestReadingFromOther
        deviceAddress = appGroupSource.deviceAddress
        xDripMetadata = appGroupSource.xDripMetadata
    }
}

public struct AppGroupCGMSettingsView: View {
    @ObservedObject var viewModel: AppGroupCGMSettingsViewModel
    @State private var showingDeletionSheet = false

    init(viewModel: AppGroupCGMSettingsViewModel) {
        self.viewModel = viewModel
    }

    private var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()

        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("E, MMM d, hh:mm")

        return formatter
    }()

    public var body: some View {
        VStack {
            Spacer()
            Text(NSLocalizedString("Shared App Group CGM", comment: "Title for the Shared App Group CGM settings view"))
                .font(.title)
                .fontWeight(.semibold)
            Form {
                Section {
                    HStack {
                        Text("Quelle:")
                        Spacer()
                        Text(viewModel.latestReadingFrom?.displayName ?? viewModel.latestReadingFromOther ?? "--")
                    }
                    HStack {
                        Text("Letzter Wert:")
                        Spacer()
                        if let latestReadingDate = viewModel.latestReadingDate {
                            Text(timeFormatter.string(from: latestReadingDate))
                        } else {
                            Text("--")
                        }
                    }
                }
                if viewModel.latestReadingFrom == .xdrip,
                   let metadata = viewModel.xDripMetadata
                {
                    Section(header: Text("xDrip4iOS CGM")) {
                        if let sensorModel = metadata.sensor?.model, !sensorModel.isEmpty {
                            HStack {
                                Text("Sensor:")
                                Spacer()
                                Text(sensorModel)
                            }
                        }

                        if let startedAt = metadata.sensor?.startedAt {
                            let sensorStart = Date(timeIntervalSince1970: startedAt)
                            let age = max(0, Date().timeIntervalSince(sensorStart))
                            let days = Int(age / 86400)
                            let hours = Int(age.truncatingRemainder(dividingBy: 86400) / 3600)

                            HStack {
                                Text("Sensoralter:")
                                Spacer()
                                Text(days > 0 ? "\(days) T \(hours) h" : "\(hours) h")
                            }
                        }

                        if let sensorState = metadata.sensor?.state, !sensorState.isEmpty {
                            HStack {
                                Text("Sensorstatus:")
                                Spacer()
                                Text({
                                    switch sensorState {
                                    case "active": return "Aktiv"
                                    case "warmup": return "Aufwärmphase"
                                    case "stopped": return "Gestoppt"
                                    case "expired": return "Abgelaufen"
                                    case "failed": return "Fehler"
                                    case "not_started": return "Nicht gestartet"
                                    default: return sensorState
                                    }
                                }())
                            }
                        }

                        if let quality = metadata.latestData?.qualityCode, !quality.isEmpty {
                            HStack {
                                Text("Qualität:")
                                Spacer()
                                Text({
                                    switch quality {
                                    case "reliable": return "Zuverlässig"
                                    case "persistent_noise": return "Anhaltendes Sensorrauschen"
                                    case "excess_noise": return "Starkes Sensorrauschen"
                                    case "temporary_sensor_issue": return "Temporäres Sensorproblem"
                                    case "flatline": return "Keine Signaländerung"
                                    case "sensor_error": return "Sensorfehler"
                                    default: return quality
                                    }
                                }())
                            }
                        }

                        if let transmitter = metadata.transmitter {
                            HStack {
                                Text("Transmitter:")
                                Spacer()
                                if transmitter.isAnubis == true {
                                    Text("Anubis G6")
                                } else if let model = transmitter.model, !model.isEmpty {
                                    Text(model)
                                } else {
                                    Text("--")
                                }
                            }

                            if let identifier = transmitter.identifier, !identifier.isEmpty {
                                HStack {
                                    Text("Transmitter-ID:")
                                    Spacer()
                                    Text(identifier)
                                }
                            }

                            if let battery = transmitter.battery,
                               let value = battery.value
                            {
                                HStack {
                                    Text("Batterie:")
                                    Spacer()
                                    if battery.unit == "millivolts" {
                                        Text("\(Int(value)) mV")
                                    } else if battery.unit == "percent" {
                                        Text("\(Int(value)) %")
                                    } else {
                                        Text("\(value)")
                                    }
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Heartbeat")) {
                    VStack(alignment: .leading) {
                        if let cgmTransmitterDeviceAddress = viewModel.deviceAddress {
                            Text("CGM address :")
                            Text(cgmTransmitterDeviceAddress).font(.caption)
                        } else {
                            Text("CGM is not used as heartbeat.")
                        }
                    }
                }
                if let latestReadingFrom = viewModel.latestReadingFrom, let appURL = latestReadingFrom.appURL {
                    Section {
                        Button(
                            NSLocalizedString("Open \(latestReadingFrom.displayName)", comment: "Open the shared group app"),
                            action: {
                                UIApplication.shared.open(appURL)
                            }
                        )
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        deleteCGMButton
                        Spacer()
                    }
                }
            }
        }
        .navigationBarItems(
            trailing: Button(action: {
                self.viewModel.onClose.send()
            }, label: {
                Text("Done")
            })
        ).onAppear {
            viewModel.viewDidAppear()
        }
    }

    private var deleteCGMButton: some View {
        Button(action: {
            showingDeletionSheet = true
        }, label: {
            Text("Delete CGM").foregroundColor(.red)
        }).actionSheet(isPresented: $showingDeletionSheet) {
            ActionSheet(
                title: Text("Are you sure you want to delete this CGM?"),
                buttons: [
                    .destructive(Text("Delete CGM")) {
                        self.viewModel.onDelete.send()
                    },
                    .cancel()
                ]
            )
        }
    }
}
