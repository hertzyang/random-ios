import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PublisherViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                TextField("Push Base URL", text: $vm.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                TextField("Display Name", text: $vm.displayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(vm.publisherActive ? "Stop Publisher" : "Start Publisher") {
                        Task { await vm.togglePublisher() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Refresh Devices") {
                        Task { await vm.reloadDevices(forceSync: true) }
                    }.buttonStyle(.bordered)
                    Spacer()
                }
                Text(vm.publisherStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                List {
                    ForEach($vm.sources) { $source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(source.kind == .video ? "[CAM]" : "[MIC]")
                                    .font(.caption.monospaced())
                                Text(source.label)
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $source.enabled)
                                    .labelsHidden()
                                    .onChange(of: source.enabled) { _ in
                                        Task { await vm.sourceToggled(sourceID: source.id) }
                                    }
                                Text(source.isPublishing ? "LIVE" : "IDLE")
                                    .font(.caption)
                                    .foregroundStyle(source.isPublishing ? .green : .secondary)
                            }

                            Text("name=\(source.name) stream=\(source.streamID.isEmpty ? "-" : source.streamID)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text(source.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
                Text(vm.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .navigationTitle("Cam Push")
        }
        .task {
            await vm.bootstrap()
        }
    }
}
