import Foundation
import SwiftData

/// One per device. Synced through iCloud with the deck, so every device knows:
/// - how far through the Srpski cloud's (`cloud/`) journal of chat decks the deck already is
///   (`journal`), which the snapshot for the chat carries so the cloud can lay later decks over it;
/// - where the cloud is (`cloudURL`, `cloudToken`, written by the Mac from its cloud.json), so
///   the iPhone pulls words from a chat without any setup;
/// - the lesson open on this device (`lesson`), so another device can offer to continue it.
///
/// Each device writes only its own row, so iCloud never has two writers for one record.
@Model
public final class SyncDevice {
    public var deviceID: String = ""
    /// The highest cloud journal number this device has imported.
    public var journal: Int = 0
    public var cloudURL: String?
    public var cloudToken: String?
    /// The lesson open on this device, as JSON; nil: none.
    public var lesson: Data?
    /// When `lesson` last changed.
    public var lessonChangedAt: Date = Date.distantPast
    /// "Mac", "iPhone": shown next to its lesson on the other device.
    public var deviceName: String?

    public init(deviceID: String) {
        self.deviceID = deviceID
    }
}

@MainActor
public enum CloudJournal {
    /// The highest journal number any device has imported: the deck includes every chat deck up to it.
    public static func applied(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<SyncDevice>())) ?? []).map(\.journal).max() ?? 0
    }

    /// Notes that `device` imported journal decks up to `journal`. Saved with whatever else is pending.
    public static func record(_ journal: Int, device: String, in context: ModelContext) throws {
        let row = self.row(for: device, in: context)
        guard journal > row.journal else { return }
        row.journal = journal
        try context.save()
    }

    /// Marks `device` as having imported up to `journal` without saving: the import's own save
    /// takes the mark along, so iCloud brings the words and the mark to the other device together.
    /// A mark that arrived ahead of the words let that device claim words it didn't have yet.
    public static func mark(_ journal: Int, device: String, in context: ModelContext) {
        let row = self.row(for: device, in: context)
        if journal > row.journal { row.journal = journal }
    }

    /// Whether iCloud has brought this device every deck some device imported (`applied`, from
    /// the cloud). Importing more before that edits words still missing the other device's
    /// changes, and iCloud can then carry those words back without them.
    public static func isCaughtUp(with applied: Int, in context: ModelContext) -> Bool {
        self.applied(in: context) >= applied
    }

    /// The Mac shares where its cloud is, so the iPhone can use it too.
    public static func share(url: String, token: String, device: String, in context: ModelContext) throws {
        let row = self.row(for: device, in: context)
        guard row.cloudURL != url || row.cloudToken != token else { return }
        row.cloudURL = url
        row.cloudToken = token
        try context.save()
    }

    /// A cloud some device shared, if any.
    public static func sharedCloud(in context: ModelContext) -> (url: String, token: String)? {
        let rows = (try? context.fetch(FetchDescriptor<SyncDevice>())) ?? []
        for row in rows.sorted(by: { $0.journal > $1.journal }) {
            if let url = row.cloudURL, let token = row.cloudToken, !url.isEmpty, !token.isEmpty {
                return (url, token)
            }
        }
        return nil
    }

    static func row(for device: String, in context: ModelContext) -> SyncDevice {
        var descriptor = FetchDescriptor<SyncDevice>(predicate: #Predicate { $0.deviceID == device })
        descriptor.fetchLimit = 1
        if let row = try? context.fetch(descriptor).first { return row }
        let row = SyncDevice(deviceID: device)
        context.insert(row)
        return row
    }
}

/// Each device's open lesson, shared through `SyncDevice` so another device can show it and
/// continue it there. Nothing is taken over by itself: the learner picks.
@MainActor
public enum SyncedLesson {
    /// A lesson open on another device.
    public struct Elsewhere: Equatable, Sendable {
        public var device: String
        /// "Mac", "iPhone".
        public var deviceName: String
        public var lesson: Lesson
    }

    /// `lesson` is what's open on this device now (nil: none).
    public static func publish(_ lesson: Lesson?, device: String, name: String, in context: ModelContext, now: Date = .now) throws {
        let row = CloudJournal.row(for: device, in: context)
        let data = try lesson.map { try JSONEncoder().encode($0) }
        guard row.lesson != data || row.deviceName != name else { return }
        row.lesson = data
        row.deviceName = name
        row.lessonChangedAt = now
        try context.save()
    }

    /// Lessons open on other devices, the most recently opened first; the same lesson once.
    public static func elsewhere(than device: String, in context: ModelContext) -> [Elsewhere] {
        let rows = ((try? context.fetch(FetchDescriptor<SyncDevice>())) ?? [])
            .filter { $0.deviceID != device }
            .sorted { $0.lessonChangedAt > $1.lessonChangedAt }
        var result: [Elsewhere] = []
        for row in rows {
            guard let data = row.lesson, let lesson = try? JSONDecoder().decode(Lesson.self, from: data),
                  !result.contains(where: { $0.lesson == lesson })
            else { continue }
            result.append(Elsewhere(device: row.deviceID, deviceName: row.deviceName ?? "another device", lesson: lesson))
        }
        return result
    }
}
