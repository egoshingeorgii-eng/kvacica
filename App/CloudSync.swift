import AppKit
import Foundation
import SrbCore
import SwiftData

/// Keeps the Srpski cloud (`cloud/`, a Cloudflare Worker) in step with the app, so a chat on the
/// phone can add and delete words while the Mac is off. Where the cloud is comes from, in order:
/// - the Mac's Application Support/Srpski/cloud.json: `{"url": "https://…workers.dev", "token": "…"}`;
/// - a claude.ai connector URL pasted in the iPhone's Settings (`<url>/mcp/<token>`);
/// - what the Mac shared through iCloud (`SyncDevice`), so the iPhone needs no setup.
///
/// The cloud keeps a numbered journal of the decks a chat sent. Both devices pull: whichever
/// pulls first imports a deck straight into the database and only then acks it, and iCloud
/// brings the result to the other one. Importing the same deck twice changes nothing. A device
/// imports only once iCloud has brought it what the other one imported (see `behindSince`).
///
/// - Pulls on launch, every 5 minutes, whenever the app comes to the front and, on the iPhone,
///   when iOS wakes it for a background refresh.
/// - Uploads notes.json and the tutor report with the journal number the deck includes, so the
///   chat sees what's in the deck plus whatever came after.
@MainActor
final class CloudSync {
    private struct Config: Decodable {
        var url: URL
        var token: String
    }

    enum Source {
        case file, connector, iCloud
    }

    static let configFile = SharedFiles.folder.appending(path: "cloud.json")
    /// iPhone background refresh (BGTaskSchedulerPermittedIdentifiers in project.yml).
    nonisolated static let refreshTask = "com.georgiiegoshin.srpski.cloud"

    /// This device's row in `SyncDevice`. Kept in UserDefaults, which iCloud doesn't sync.
    static var deviceID: String {
        let key = "syncDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Shown next to this device's lesson on the other one.
    static var deviceName: String {
        "Mac"
    }

    let source: Source
    private let config: Config
    private let context: ModelContext
    /// Imports one journal deck into the database; throws if it couldn't be saved.
    private let importDeck: (DeckFile) throws -> Void
    /// After a pull imported something: the chat should see it right away.
    private let didImport: () -> Void
    private var timer: Timer?
    private var pulling = false
    /// Since when the cloud has had decks for this device while iCloud hadn't yet brought what
    /// another device imported. After `iCloudPatience` this device imports anyway: the other one
    /// may never sync (iCloud off, deleted app).
    private var behindSince: Date?
    private static let iCloudPatience: TimeInterval = 10 * 60
    /// Entries and report of the last successful upload, to skip uploading the same thing again.
    private var uploaded: Data?
    /// The newest snapshot the cloud hasn't got yet.
    private var waiting: (body: Data, key: Data)?
    private var uploadTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    init?(context: ModelContext, importDeck: @escaping (DeckFile) throws -> Void, didImport: @escaping () -> Void) {
        if let data = try? Data(contentsOf: Self.configFile),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = config
            source = .file
        } else if let connector = UserDefaults.standard.string(forKey: Pref.cloudConnector),
                  let config = Self.config(fromConnector: connector) {
            self.config = config
            source = .connector
        } else if let shared = CloudJournal.sharedCloud(in: context), let url = URL(string: shared.url) {
            config = Config(url: url, token: shared.token)
            source = .iCloud
        } else {
            return nil
        }
        self.context = context
        self.importDeck = importDeck
        self.didImport = didImport
    }

    /// `https://srpski.example.workers.dev/mcp/<token>` → the worker's URL and the token.
    private static func config(fromConnector text: String) -> Config? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "/mcp/", options: .backwards),
              let url = URL(string: String(trimmed[..<range.lowerBound])), url.scheme?.hasPrefix("http") == true
        else { return nil }
        let token = trimmed[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return token.isEmpty ? nil : Config(url: url, token: token)
    }

    static func isValidConnector(_ text: String) -> Bool { config(fromConnector: text) != nil }

    /// The cloud a new learner signs up with.
    static let defaultCloud = URL(string: "https://srpski.egoshin.workers.dev")!

    /// A connector URL of the learner's own, made by the cloud (POST /signup).
    static func signUp() async throws -> String {
        var request = URLRequest(url: defaultCloud.appending(path: "signup"), timeoutInterval: 20)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Reply: Decodable { var connector: String?; var error: String? }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard status == 200, let connector = reply?.connector, isValidConnector(connector) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: reply?.error ?? "HTTP \(status)"])
        }
        return connector
    }

    /// The URL to add to a chat as a connector, wherever this cloud came from.
    var connectorURL: String {
        config.url.appending(path: "mcp/\(config.token)").absoluteString
    }

    /// When a chat last called the connector; nil if never (or the cloud couldn't say).
    func chatSeenAt() async -> Date? {
        struct Status: Decodable { var chatSeenAt: String? }
        guard let data = try? await send("GET", "sync/status"),
              let seen = try? JSONDecoder().decode(Status.self, from: data).chatSeenAt
        else { return nil }
        return ISO8601DateFormatter.withFraction.date(from: seen) ?? ISO8601DateFormatter().date(from: seen)
    }

    func start() {
        if source != .iCloud {
            // The other device picks this up through iCloud.
            try? CloudJournal.share(url: config.url.absoluteString, token: config.token, device: Self.deviceID, in: context)
        }
        Task { await pull() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        activeObserver = NotificationCenter.default.addObserver(forName: didBecomeActive, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    // MARK: Pull

    /// Imports the decks no device has imported yet, in journal order, and acks the ones that went in.
    func pull() async {
        guard !pulling else { return }
        pulling = true
        defer { pulling = false }
        do {
            let data = try await send("GET", "sync/pending")
            let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let decks = reply?["decks"] as? [[String: Any]], !decks.isEmpty else {
                behindSince = nil
                return
            }
            // A cloud from before `applied` sends none: nothing to wait for.
            let applied = reply?["applied"] as? Int ?? 0
            if CloudJournal.isCaughtUp(with: applied, in: context) {
                behindSince = nil
            } else {
                let since = behindSince ?? .now
                behindSince = since
                guard Date.now.timeIntervalSince(since) >= Self.iCloudPatience else {
                    NSLog("Srpski cloud: waiting for iCloud to bring deck %d before importing more", applied)
                    return
                }
            }
            var done: [Int] = []
            for item in decks.sorted(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) {
                guard let id = item["id"] as? Int, let raw = item["deck"] else { continue }
                do {
                    let json = try JSONSerialization.data(withJSONObject: raw)
                    let deck = try DeckFile.parse(String(decoding: json, as: UTF8.self))
                    // Saved with the deck's words, in one go.
                    CloudJournal.mark(id, device: Self.deviceID, in: context)
                    do {
                        try importDeck(deck)
                    } catch {
                        // Not saved: try again next time, and keep the order.
                        context.rollback()
                        NSLog("Srpski cloud: importing deck %d failed: %@", id, error.localizedDescription)
                        break
                    }
                } catch {
                    // The cloud checked it, so this never imports; don't let it hold up the rest.
                    NSLog("Srpski cloud: skipping unreadable deck %d: %@", id, error.localizedDescription)
                }
                try? CloudJournal.record(id, device: Self.deviceID, in: context)
                done.append(id)
            }
            guard !done.isEmpty else { return }
            didImport()
            // A failed ack only means the same decks come again; importing twice changes nothing.
            _ = try await send("POST", "sync/ack", body: JSONSerialization.data(withJSONObject: ["ids": done]))
        } catch {
            NSLog("Srpski cloud: pull failed: %@", error.localizedDescription)
        }
    }

    // MARK: Upload

    /// Called after every notes.json rewrite. Uploads once answering has paused for half a minute,
    /// or right away (`now`) after words from a chat came in.
    func publish(_ snapshot: NotesSnapshot, report: String, now: Bool = false) {
        let journal = CloudJournal.applied(in: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let entries = try? encoder.encode(snapshot.entries),
              let notes = try? encoder.encode(snapshot),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "notes": String(decoding: notes, as: UTF8.self), "report": report, "journal": journal,
              ])
        else { return }
        // exportedAt changes every time; only the content counts.
        let key = entries + Data(report.utf8) + Data(String(journal).utf8)
        guard key != uploaded else {
            waiting = nil
            return
        }
        waiting = (body, key)
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: .seconds(30)) }
            guard !Task.isCancelled else { return }
            await self?.upload()
        }
    }

    /// Waits for an upload that has started (iPhone background refresh).
    func finishUpload() async {
        await uploadTask?.value
    }

    private func upload() async {
        guard let (body, key) = waiting else { return }
        do {
            let (_, status) = try await send("PUT", "sync/state", body: body, accepting: [409])
            if status == 409 {
                // The cloud has a snapshot that includes more of the journal: this device hasn't
                // got everything from iCloud yet. The next change after it has goes up.
                NSLog("Srpski cloud: the cloud has a newer snapshot; waiting for iCloud")
            } else {
                uploaded = key
            }
            if waiting?.key == key { waiting = nil }
        } catch {
            NSLog("Srpski cloud: upload failed: %@", error.localizedDescription)
        }
    }

    /// Sends a waiting snapshot before the app quits; gives up after a few seconds.
    func flush() {
        uploadTask?.cancel()
        guard let (body, _) = waiting else { return }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request("PUT", "sync/state", body: body)) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: config.url.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try await send(method, path, body: body, accepting: []).data
    }

    /// `accepting`: other statuses that aren't an error.
    private func send(_ method: String, _ path: String, body: Data?, accepting: Set<Int>) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request(method, path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || accepting.contains(status) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path): HTTP \(status)"])
        }
        return (data, status)
    }
}

private extension ISO8601DateFormatter {
    /// What JavaScript's toISOString writes: milliseconds and a Z.
    static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
