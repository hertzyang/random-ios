import Foundation
import AVFoundation
import HaishinKit
import RTCHaishinKit

@MainActor
final class PublisherViewModel: ObservableObject {
    enum SourceKind: String, Codable {
        case video
        case audio
    }

    struct SourceItem: Identifiable, Codable {
        let id: String
        let deviceID: String
        let label: String
        let kind: SourceKind
        var name: String
        var title: String
        var enabled: Bool
        var streamID: String
        var path: String
        var isPublishing: Bool
        var status: String
    }

    private struct PublisherRegisterRequest: Codable {
        let display_name: String
        let client_id: String
    }

    private struct PublisherRegisterResponse: Codable {
        let publisher_id: String
        let token: String
    }

    private struct PublisherStreamsRequest: Codable {
        struct Stream: Codable {
            let name: String
            let title: String
            let media: String
            let enabled: Bool
        }
        let token: String
        let streams: [Stream]
    }

    private struct PublisherStreamsResponse: Codable {
        struct Stream: Codable {
            let id: String
            let name: String
            let path: String
        }
        let streams: [Stream]
    }

    private struct PublisherStateRequest: Codable {
        let token: String
        let stream_id: String
        let state: String
    }

    private struct PublisherUnregisterRequest: Codable {
        let token: String
        let client_id: String
    }

    private struct ControlCommand: Codable {
        let action: String
        let stream_id: String
        let path: String?
    }

    private final class ActivePublish {
        let mixer: MediaMixer
        let session: any StreamSession
        let sourceID: String
        var readyTask: Task<Void, Never>?

        init(mixer: MediaMixer, session: any StreamSession, sourceID: String) {
            self.mixer = mixer
            self.session = session
            self.sourceID = sourceID
        }

        func shutdown() async {
            readyTask?.cancel()
            try? await session.close()
            await mixer.removeOutput(session.stream)
            await mixer.stopRunning()
            try? await mixer.attachAudio(nil)
            try? await mixer.attachVideo(nil, track: 0)
        }
    }

    @Published var baseURL: String = "https://cam-push.hertz.page"
    @Published var displayName: String = "iPhone"
    @Published var publisherStatus: String = "idle"
    @Published var publisherActive: Bool = false
    @Published var sources: [SourceItem] = []
    @Published var summary: String = "0 live / 0 total"

    private let sourceStoreKey = "push_sources_v2"
    private let baseURLStoreKey = "push_base_url_v2"
    private let displayNameStoreKey = "push_display_name_v2"
    private let publisherAutoStoreKey = "push_publisher_auto_v2"
    private let clientIDStoreKey = "push_client_id_v2"

    private var publisherID: String = ""
    private var publisherToken: String = ""
    private var publisherClientID: String = ""
    private var controlTask: Task<Void, Never>?
    private var activePublishes: [String: ActivePublish] = [:] // key: streamID
    private var streamToSourceID: [String: String] = [:]
    private var factoryRegistered = false
    private var syncInFlight = false
    private var syncQueued = false

    func bootstrap() async {
        loadPersisted()
        await reloadDevices(forceSync: false)
        if publisherActive {
            await startPublisher()
        }
    }

    func togglePublisher() async {
        if publisherActive {
            await stopPublisher()
        } else {
            await startPublisher()
        }
    }

    func sourceToggled(sourceID: String) async {
        guard let idx = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        persist()
        if !sources[idx].enabled {
            if !sources[idx].streamID.isEmpty {
                await stopPublish(streamID: sources[idx].streamID)
            }
        }
        if publisherActive {
            await syncPublisherStreams()
        }
        updateSummary()
    }

    func reloadDevices(forceSync: Bool) async {
        var updated: [SourceItem] = []
        let previousByKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })

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

        let audios = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        ).devices

        for d in videos {
            let key = configKey(kind: .video, label: d.localizedName, deviceID: d.uniqueID)
            let old = previousByKey[key]
            updated.append(SourceItem(
                id: key,
                deviceID: d.uniqueID,
                label: d.localizedName,
                kind: .video,
                name: old?.name ?? key,
                title: old?.title ?? defaultTitle(for: d.localizedName),
                enabled: old?.enabled ?? false,
                streamID: old?.streamID ?? "",
                path: old?.path ?? "",
                isPublishing: old?.isPublishing ?? false,
                status: old?.status ?? "ready"
            ))
        }

        for d in audios {
            let key = configKey(kind: .audio, label: d.localizedName, deviceID: d.uniqueID)
            let old = previousByKey[key]
            updated.append(SourceItem(
                id: key,
                deviceID: d.uniqueID,
                label: d.localizedName,
                kind: .audio,
                name: old?.name ?? key,
                title: old?.title ?? defaultTitle(for: d.localizedName),
                enabled: old?.enabled ?? false,
                streamID: old?.streamID ?? "",
                path: old?.path ?? "",
                isPublishing: old?.isPublishing ?? false,
                status: old?.status ?? "ready"
            ))
        }

        sources = updated.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }

        if sources.isEmpty {
            publisherStatus = "no input devices"
        }
        persist()
        updateSummary()

        if forceSync && publisherActive {
            await syncPublisherStreams()
        }
    }

    private func startPublisher() async {
        do {
            try await configureAudioSessionForCapture()
            let cam = await requestAccess(for: .video)
            let mic = await requestAccess(for: .audio)
            if !cam || !mic {
                publisherStatus = "camera/microphone permission denied"
                return
            }
            await registerFactoriesIfNeeded()
            publisherActive = true
            persist()
            await reloadDevices(forceSync: false)
            try await ensurePublisherRegistered(forceNew: true)
            await syncPublisherStreams()
            connectPublisherControl()
            publisherStatus = "publisher: connected"
        } catch {
            publisherActive = false
            persist()
            publisherStatus = "publisher start failed: \(error.localizedDescription)"
        }
    }

    private func stopPublisher() async {
        publisherActive = false
        controlTask?.cancel()
        controlTask = nil

        for sid in Array(activePublishes.keys) {
            await stopPublish(streamID: sid)
        }

        await unregisterPublisherRemote()
        resetPublisherIdentity()
        persist()
        publisherStatus = "publisher stopped"
        updateSummary()
    }

    private func resetPublisherIdentity() {
        publisherID = ""
        publisherToken = ""
    }

    private func ensurePublisherRegistered(forceNew: Bool) async throws {
        if !forceNew && !publisherToken.isEmpty {
            return
        }
        if forceNew {
            resetPublisherIdentity()
        }

        let body = PublisherRegisterRequest(
            display_name: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            client_id: publisherClientID
        )
        let response: PublisherRegisterResponse = try await postJSON(
            path: "/api/hall/publisher/register",
            body: body
        )
        publisherID = response.publisher_id
        publisherToken = response.token
    }

    private func connectPublisherControl() {
        guard publisherActive, !publisherToken.isEmpty else { return }
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            guard let self else { return }
            var errorCount = 0
            while !Task.isCancelled && self.publisherActive {
                do {
                    let stream = try await self.openControlStream(token: self.publisherToken)
                    errorCount = 0
                    await MainActor.run { self.publisherStatus = "publisher: connected" }
                    for try await cmd in stream {
                        if Task.isCancelled || !self.publisherActive { break }
                        await self.handleControlCommand(cmd)
                    }
                    throw URLError(.networkConnectionLost)
                } catch {
                    errorCount += 1
                    await MainActor.run { self.publisherStatus = "publisher: reconnecting" }
                    if errorCount >= 2 {
                        await self.recoverPublisherControl()
                        errorCount = 0
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func recoverPublisherControl() async {
        guard publisherActive else { return }
        publisherStatus = "publisher: recovering"
        do {
            try await ensurePublisherRegistered(forceNew: true)
            await syncPublisherStreams()
            connectPublisherControl()
        } catch {
            publisherStatus = "publisher recover failed: \(error.localizedDescription)"
        }
    }

    private func publishConfigPayload() -> [PublisherStreamsRequest.Stream] {
        sources.map {
            PublisherStreamsRequest.Stream(
                name: $0.name,
                title: $0.title,
                media: $0.kind == .audio ? "audio" : "video",
                enabled: $0.enabled
            )
        }
    }

    private func syncPublisherStreams() async {
        guard publisherActive, !publisherToken.isEmpty else { return }
        if syncInFlight {
            syncQueued = true
            return
        }
        syncInFlight = true
        defer {
            syncInFlight = false
        }

        repeat {
            syncQueued = false
            do {
                let body = PublisherStreamsRequest(token: publisherToken, streams: publishConfigPayload())
                let resp: PublisherStreamsResponse = try await postJSON(path: "/api/hall/publisher/streams", body: body)
                var byName: [String: PublisherStreamsResponse.Stream] = [:]
                for s in resp.streams {
                    byName[s.name] = s
                }
                streamToSourceID.removeAll()

                for i in sources.indices {
                    let name = sources[i].name
                    if let mapped = byName[name] {
                        sources[i].streamID = mapped.id
                        sources[i].path = mapped.path
                        streamToSourceID[mapped.id] = sources[i].id
                        if sources[i].enabled {
                            if !sources[i].isPublishing {
                                sources[i].status = "waiting viewer"
                            }
                        } else {
                            sources[i].status = "disabled"
                        }
                    } else {
                        if !sources[i].streamID.isEmpty {
                            await stopPublish(streamID: sources[i].streamID)
                        }
                        sources[i].streamID = ""
                        sources[i].path = ""
                        sources[i].isPublishing = false
                        sources[i].status = sources[i].enabled ? "pending" : "disabled"
                    }
                }
                persist()
                updateSummary()
            } catch {
                publisherStatus = "sync failed: \(error.localizedDescription)"
            }
        } while syncQueued
    }

    private func handleControlCommand(_ cmd: ControlCommand) async {
        guard !cmd.stream_id.isEmpty else { return }
        if cmd.action == "start" {
            let path = cmd.path ?? ""
            await startPublish(streamID: cmd.stream_id, streamPath: path)
        } else if cmd.action == "stop" {
            await stopPublish(streamID: cmd.stream_id)
        }
    }

    private func startPublish(streamID: String, streamPath: String) async {
        guard publisherActive, !publisherToken.isEmpty else { return }
        guard activePublishes[streamID] == nil else { return }
        guard let sourceID = streamToSourceID[streamID],
              let idx = sources.firstIndex(where: { $0.id == sourceID }) else {
            return
        }
        guard sources[idx].enabled else { return }

        let source = sources[idx]
        guard let device = deviceForSource(source) else {
            sources[idx].status = "device unavailable"
            return
        }

        do {
            let whipURL = try makeWHIPURL(path: streamPath, token: publisherToken)
            let mixer = MediaMixer(captureSessionMode: .single)

            if source.kind == .audio {
                try await mixer.attachAudio(device)
            } else {
                try await mixer.attachVideo(device, track: 0)
            }
            await mixer.startRunning()

            let session = try await StreamSessionBuilderFactory.shared.make(whipURL)
                .setMode(.publish)
                .build()
            await mixer.addOutput(session.stream)

            let active = ActivePublish(mixer: mixer, session: session, sourceID: sourceID)
            active.readyTask = Task { [weak self] in
                guard let self else { return }
                for await rs in await session.readyState {
                    if Task.isCancelled { break }
                    if rs == .open {
                        await self.postPublisherState(streamID: streamID, state: "live")
                        await MainActor.run {
                            if let j = self.sources.firstIndex(where: { $0.id == sourceID }) {
                                self.sources[j].isPublishing = true
                                self.sources[j].status = "live"
                                self.updateSummary()
                            }
                        }
                    }
                }
            }

            activePublishes[streamID] = active
            sources[idx].isPublishing = true
            sources[idx].status = "starting"
            updateSummary()
            await postPublisherState(streamID: streamID, state: "starting")

            try await session.connect {
                Task { @MainActor [weak self] in
                    await self?.stopPublish(streamID: streamID)
                }
            }
        } catch {
            sources[idx].isPublishing = false
            sources[idx].status = "start failed: \(error.localizedDescription)"
            activePublishes.removeValue(forKey: streamID)
            await postPublisherState(streamID: streamID, state: "idle")
            updateSummary()
        }
    }

    private func stopPublish(streamID: String) async {
        if let active = activePublishes.removeValue(forKey: streamID) {
            await active.shutdown()
        }
        if let sid = streamToSourceID[streamID],
           let idx = sources.firstIndex(where: { $0.id == sid }) {
            sources[idx].isPublishing = false
            sources[idx].status = sources[idx].enabled ? "waiting viewer" : "disabled"
        }
        await postPublisherState(streamID: streamID, state: "idle")
        updateSummary()
    }

    private func postPublisherState(streamID: String, state: String) async {
        guard !publisherToken.isEmpty else { return }
        let body = PublisherStateRequest(token: publisherToken, stream_id: streamID, state: state)
        _ = try? await postJSON(path: "/api/hall/publisher/state", body: body) as EmptyResponse
    }

    private func unregisterPublisherRemote() async {
        if publisherToken.isEmpty && publisherClientID.isEmpty { return }
        let body = PublisherUnregisterRequest(token: publisherToken, client_id: publisherClientID)
        _ = try? await postJSON(path: "/api/hall/publisher/unregister", body: body) as EmptyResponse
    }

    private func openControlStream(token: String) async throws -> AsyncThrowingStream<ControlCommand, Error> {
        let base = try requireBaseURL()
        var comp = URLComponents(url: base.appendingPathComponent("api/hall/publisher/control"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comp?.url else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 0

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        if line.hasPrefix("data: ") {
                            let raw = String(line.dropFirst(6))
                            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  let data = raw.data(using: .utf8) else {
                                continue
                            }
                            if let cmd = try? JSONDecoder().decode(ControlCommand.self, from: data) {
                                continuation.yield(cmd)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func configureAudioSessionForCapture() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    private func registerFactoriesIfNeeded() async {
        if factoryRegistered { return }
        await StreamSessionBuilderFactory.shared.register(HTTPSessionFactory())
        factoryRegistered = true
    }

    private func requireBaseURL() throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: raw), let scheme = u.scheme, scheme == "https" || scheme == "http" else {
            throw URLError(.badURL)
        }
        return u
    }

    private func makeWHIPURL(path: String, token: String) throws -> URL {
        var url = try requireBaseURL()
            .appendingPathComponent("internal")
            .appendingPathComponent("hall")
            .appendingPathComponent("whip")
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        url.appendPathComponent("whip")
        var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let final = comp?.url else {
            throw URLError(.badURL)
        }
        url = final
        return url
    }

    private struct EmptyResponse: Codable {}

    private func postJSON<Req: Encodable, Resp: Decodable>(path: String, body: Req) async throws -> Resp {
        let base = try requireBaseURL()
        guard let url = URL(string: path, relativeTo: base) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CamPush", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if Resp.self == EmptyResponse.self {
            return EmptyResponse() as! Resp
        }
        return try JSONDecoder().decode(Resp.self, from: data)
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
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
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone],
                mediaType: .audio,
                position: .unspecified
            ).devices.first { $0.uniqueID == item.deviceID }
        }
    }

    private func updateSummary() {
        let live = sources.filter { $0.isPublishing }.count
        summary = "\(live) live / \(sources.count) total"
    }

    private func sanitizeSlug(_ raw: String) -> String {
        let s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        return s.isEmpty ? "stream" : s
    }

    private func configKey(kind: SourceKind, label: String, deviceID: String) -> String {
        let kindPrefix = kind == .audio ? "audio" : "video"
        let rawLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let clean = kind == .audio
            ? rawLabel.replacingOccurrences(of: "^default\\s*-\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^默认\\s*-\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : rawLabel
        let stable = clean.isEmpty ? deviceID.lowercased() : clean
        return sanitizeSlug("\(kindPrefix)-\(stable)")
    }

    private func defaultTitle(for label: String) -> String {
        let who = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(who) / \(label)"
    }

    private func loadPersisted() {
        let ud = UserDefaults.standard
        if let v = ud.string(forKey: baseURLStoreKey), !v.isEmpty {
            baseURL = v
        }
        if let n = ud.string(forKey: displayNameStoreKey), !n.isEmpty {
            displayName = n
        }
        if let cid = ud.string(forKey: clientIDStoreKey), !cid.isEmpty {
            publisherClientID = cid
        } else {
            publisherClientID = "pc-\(UUID().uuidString.prefix(10).lowercased())"
            ud.set(publisherClientID, forKey: clientIDStoreKey)
        }

        publisherActive = ud.bool(forKey: publisherAutoStoreKey)
        if let data = ud.data(forKey: sourceStoreKey),
           let saved = try? JSONDecoder().decode([SourceItem].self, from: data) {
            sources = saved
        }
    }

    private func persist() {
        let ud = UserDefaults.standard
        ud.set(baseURL, forKey: baseURLStoreKey)
        ud.set(displayName, forKey: displayNameStoreKey)
        ud.set(publisherActive, forKey: publisherAutoStoreKey)
        if let data = try? JSONEncoder().encode(sources) {
            ud.set(data, forKey: sourceStoreKey)
        }
    }
}
