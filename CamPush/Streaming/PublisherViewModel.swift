import Foundation
import AVFoundation
import HaishinKit

@MainActor
final class PublisherViewModel: ObservableObject {
    enum SourceKind: String, Codable {
        case video
        case audio
    }

    struct SourceItem: Identifiable {
        let id: String
        let deviceID: String
        let label: String
        let kind: SourceKind
        var streamID: String
        var isPublishing: Bool
        var status: String
    }

    final class PublishSession {
        let connection = RTMPConnection()
        let stream: RTMPStream

        init() {
            stream = RTMPStream(connection: connection)
        }

        func stop() {
            stream.close()
            connection.close()
        }
    }

    @Published var rtmpURL: String = "rtmp://cam-push.hertz.page/live"
    @Published var sources: [SourceItem] = []
    @Published var summary: String = "idle"

    private var sessions: [String: PublishSession] = [:]

    func reloadDevices() async {
        await stopAll()

        var items: [SourceItem] = []

        let videos = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        ).devices

        let audios = AVCaptureDevice.devices(for: .audio)

        for (idx, d) in videos.enumerated() {
            let id = "video:\(d.uniqueID)"
            items.append(SourceItem(
                id: id,
                deviceID: d.uniqueID,
                label: d.localizedName,
                kind: .video,
                streamID: defaultStreamID(kind: .video, index: idx),
                isPublishing: false,
                status: "ready"
            ))
        }

        for (idx, d) in audios.enumerated() {
            let id = "audio:\(d.uniqueID)"
            items.append(SourceItem(
                id: id,
                deviceID: d.uniqueID,
                label: d.localizedName,
                kind: .audio,
                streamID: defaultStreamID(kind: .audio, index: idx),
                isPublishing: false,
                status: "ready"
            ))
        }

        sources = items
        updateSummary()
    }

    func togglePublish(sourceID: String) async {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        if sources[idx].isPublishing {
            await stop(sourceID: sourceID)
            return
        }
        await start(index: idx)
    }

    private func start(index: Int) async {
        if rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sources[index].status = "RTMP URL empty"
            return
        }
        if !isValidStreamID(sources[index].streamID) {
            sources[index].status = "invalid stream id"
            return
        }

        let kind = sources[index].kind
        switch kind {
        case .video:
            guard await requestAccess(for: .video) else {
                sources[index].status = "camera denied"
                return
            }
        case .audio:
            guard await requestAccess(for: .audio) else {
                sources[index].status = "mic denied"
                return
            }
        }

        let s = PublishSession()
        setupSessionSettings(s, kind: kind)

        guard let device = deviceForSource(sources[index]) else {
            sources[index].status = "device not found"
            return
        }

        switch kind {
        case .audio:
            s.stream.attachAudio(device)
        case .video:
            await withCheckedContinuation { continuation in
                s.stream.attachCamera(device) { _, _ in
                    continuation.resume(returning: ())
                }
            }
        }

        s.connection.connect(rtmpURL)
        s.stream.publish(sources[index].streamID)
        sessions[sources[index].id] = s
        sources[index].isPublishing = true
        sources[index].status = "publishing"
        updateSummary()
    }

    private func stop(sourceID: String) async {
        sessions[sourceID]?.stop()
        sessions.removeValue(forKey: sourceID)
        if let idx = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[idx].isPublishing = false
            sources[idx].status = "stopped"
        }
        updateSummary()
    }

    private func stopAll() async {
        for (_, s) in sessions {
            s.stop()
        }
        sessions.removeAll()
        for i in sources.indices {
            sources[i].isPublishing = false
            sources[i].status = "ready"
        }
        updateSummary()
    }

    private func updateSummary() {
        let live = sources.filter { $0.isPublishing }.count
        summary = "\(live) live / \(sources.count) total"
    }

    private func setupSessionSettings(_ session: PublishSession, kind: SourceKind) {
        if kind == .video {
            session.stream.videoSettings = VideoCodecSettings()
        } else {
            session.stream.audioSettings = AudioCodecSettings()
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func defaultStreamID(kind: SourceKind, index: Int) -> String {
        switch kind {
        case .video:
            return "cam-\(index + 1)"
        case .audio:
            return "mic-\(index + 1)"
        }
    }

    private func isValidStreamID(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count > 64 {
            return false
        }
        for ch in s {
            let ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "-" || ch == "_"
            if !ok {
                return false
            }
        }
        return true
    }

    private func deviceForSource(_ item: SourceItem) -> AVCaptureDevice? {
        switch item.kind {
        case .video:
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInUltraWideCamera,
                    .builtInTelephotoCamera,
                    .builtInDualCamera,
                    .builtInDualWideCamera,
                    .builtInTripleCamera,
                    .builtInTrueDepthCamera,
                ],
                mediaType: .video,
                position: .unspecified
            ).devices.first { $0.uniqueID == item.deviceID }
        case .audio:
            return AVCaptureDevice.devices(for: .audio).first { $0.uniqueID == item.deviceID }
        }
    }
}
