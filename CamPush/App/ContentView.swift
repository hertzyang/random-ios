import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PublisherViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("RTMP URL", text: $vm.rtmpURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Refresh Devices") {
                        Task { await vm.reloadDevices() }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text(vm.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                List {
                    ForEach($vm.sources) { $source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(source.kind == .video ? "[CAM]" : "[MIC]")
                                    .font(.caption.monospaced())
                                Text(source.label)
                                    .font(.headline)
                                Spacer()
                                Text(source.isPublishing ? "LIVE" : "IDLE")
                                    .font(.caption)
                                    .foregroundStyle(source.isPublishing ? .green : .secondary)
                            }

                            TextField("Stream ID", text: $source.streamID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button(source.isPublishing ? "Stop" : "Start") {
                                    Task {
                                        await vm.togglePublish(sourceID: source.id)
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Spacer()

                                Text(source.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("Cam Push")
        }
        .task {
            await vm.reloadDevices()
        }
    }
}
