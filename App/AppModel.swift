import AppKit
import Carbon.HIToolbox
import CoreData
import SwiftData
import SrbCore
import UniformTypeIdentifiers
import WidgetKit

enum Pref {
    /// Words per lesson.
    static let lessonSize = "lessonSize"
    static let retention = "desiredRetention"
    static let autoSpeak = "autoSpeak"
    static let pushToTalk = "pushToTalk"
    static let strictDiacritics = "strictDiacritics"
    /// Which words the desktop word widget shows (`WidgetWordSource`), and the topic for `.topic`.
    static let widgetWords = "widgetWords"
    static let widgetTopic = "widgetTopic"
    /// Ids of notes that came in through the inbox (from a chat) and haven't been looked at yet.
    static let recentlyAdded = "recentlyAdded"
    /// Ids of the notes this device has had, to tell which came in through iCloud (`noticeArrivals`).
    static let knownNoteIDs = "knownNoteIDs"
    /// The lesson in progress (JSON), so it survives quitting the app.
    static let lesson = "lesson"
    /// iPhone: the claude.ai connector URL of the Srpski cloud (`<url>/mcp/<token>`). Empty: the
    /// cloud the Mac shared through iCloud, if any.
    static let cloudConnector = "cloudConnector"
    /// A chat has called the connector at least once (Words then stops offering to set one up).
    static let chatConnected = "chatConnected"
    /// The Words tab's "add words from a chat" banner was closed.
    static let chatBannerClosed = "chatBannerClosed"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let hotKeyLabel = "hotKeyLabel"
    /// The shortcut that opens the floating panel from any app.
    static let panelHotKeyCode = "panelHotKeyCode"
    static let panelHotKeyModifiers = "panelHotKeyModifiers"
    static let panelHotKeyLabel = "panelHotKeyLabel"
    /// Off: no Dock icon, the app lives in the menu bar only.
    static let showInDock = "showInDock"
    /// What the menu bar item shows (`MenuBarShows`), and how many minutes a word stays there.
    static let menuBarShows = "menuBarShows"
    static let menuBarMinutes = "menuBarMinutes"
    /// On: the main window is a Raycast-style panel over every app (`MainWindow.applyStyle`).
    static let floatingWindow = "floatingWindow"
    /// How many cards the quick-card shortcut asks before the panel goes away; 0: until done.
    static let quickCards = "quickCards"
    /// The kinds of forms cards don't ask (`WordForms.Group` raw values, comma-separated).
    /// Empty: all of them. The comparative starts off: it's a topic of its own, learned later.
    static let formsOff = "formsOff"
    /// The cases open one at a time (`CaseLadder`); off: every case switched on is asked.
    static let casesStepByStep = "casesStepByStep"
    /// The comparative was added to a `formsOff` set before it was a group of its own.
    static let comparisonOffSet = "comparisonOffSet"
    /// The level picked at first launch (`AppModel.newLevel`); empty: none. Per profile.
    static var newLevel: String { Profile.key("newLevel") }
    /// The first-launch screens were shown (or the deck had words already). Per profile.
    static var onboarded: String { Profile.key("onboarded") }

    static var formGroups: Set<WordForms.Group> {
        let off = (UserDefaults.standard.string(forKey: formsOff) ?? "").split(separator: ",").map(String.init)
        return Set(WordForms.Group.allCases).subtracting(off.compactMap(WordForms.Group.init(rawValue:)))
    }

    static func registerDefaults() {
        // Asked along with the other adjective forms before it could be switched off on its own.
        let store = UserDefaults.standard
        if !store.bool(forKey: comparisonOffSet), let off = store.string(forKey: formsOff) {
            let groups = off.split(separator: ",").map(String.init) + [WordForms.Group.comparison.rawValue]
            store.set(Array(Set(groups)).sorted().joined(separator: ","), forKey: formsOff)
        }
        store.set(true, forKey: comparisonOffSet)
        var defaults: [String: Any] = [
            formsOff: WordForms.Group.comparison.rawValue,
            casesStepByStep: true,
            lessonSize: 10,
            retention: 0.9,
            autoSpeak: false,
            pushToTalk: true,
            strictDiacritics: false,
            widgetWords: WidgetWordSource.mixed.rawValue,
        ]
        defaults[hotKeyCode] = kVK_ANSI_S
        defaults[hotKeyModifiers] = optionKey | cmdKey
        defaults[hotKeyLabel] = "⌥⌘S"
        defaults[panelHotKeyCode] = kVK_ANSI_K
        defaults[panelHotKeyModifiers] = optionKey | cmdKey
        defaults[panelHotKeyLabel] = "⌥⌘K"
        defaults[showInDock] = true
        defaults[floatingWindow] = true
        defaults[quickCards] = 1
        defaults[menuBarShows] = "word"
        defaults[menuBarMinutes] = 5
        UserDefaults.standard.register(defaults: defaults)
    }
}

/// Settings → Debug → "Try as a new user": a second deck on this device, local only (no iCloud,
/// no chat cloud, no widgets), that starts from the first-launch screens. The owner's own deck and
/// lesson stay as they were and come back when it's switched off. Read once per launch.
enum Profile {
    static let trialKey = "trialProfile"
    static let isTrial = UserDefaults.standard.bool(forKey: trialKey)
    /// The trial's deck, apart from the real one.
    static let trialFolder = SharedFiles.folder.appending(path: "Trial", directoryHint: .isDirectory)

    /// A setting that each profile keeps for itself: the open lesson, the level, onboarding.
    static func key(_ name: String) -> String { isTrial ? "trial." + name : name }
}

/// An alert to show (iOS; the Mac uses NSAlert right away).
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// App-wide state: the database, settings, voice and dictation.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let speaker = Speaker()
    let speechInput = SpeechInput()
    /// Bumped after every answer, import or settings change so views and the menu bar refresh.
    private(set) var revision = 0
    @ObservationIgnored private var dueKept: (revision: Int, minute: Int, lesson: Lesson?, count: Int)?
    /// Bumped whenever the menu bar popover opens.
    private(set) var quickOpenCount = 0
    /// Mac: what the menu bar asked the main window to start; the window's study screen takes it
    /// (and clears it) as soon as it's there.
    var windowRequest: WindowRequest?
    enum WindowRequest: Equatable {
        case lesson, review
        /// The lesson open on another device (its SyncDevice id), continued here.
        case elsewhere(String)
        /// The words a chat added that haven't been started, to pick from.
        case chatWords
    }
    /// The lesson being studied on this device, if any. Kept until you finish it or start another.
    /// Shared through iCloud so the other device can offer to continue it (`lessonsElsewhere`).
    var lesson: Lesson? {
        didSet { saveLesson() }
    }
    /// iOS: shown by the root view.
    var alert: AppAlert?
    /// No words at all: on a new iPhone that means iCloud hasn't brought the deck yet.
    private(set) var isEmpty = false
    /// What iCloud is doing, for the status line in Settings.
    private(set) var iCloud = ICloudStatus()
    /// The last local save, for `waitForICloudExport`. Not observed: it changes on every answer.
    @ObservationIgnored private var lastSave: Date?
    @ObservationIgnored private var inboxWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    /// iPhone: something changed since the last publish; written when the app goes to the background.
    @ObservationIgnored private var publishPending = false
    /// What the widgets were last given, so they're only reloaded when it changes.
    @ObservationIgnored private var lastWidgets: WidgetSnapshot?
    @ObservationIgnored private var syncRefreshTask: Task<Void, Never>?
    /// iPhone home: the app just opened (or came back after a while) and iCloud hasn't brought in
    /// what the other device did meanwhile. Home's banner says it's syncing instead of a count
    /// that's about to change: George saw the old number, then the new one.
    private(set) var catchingUp = false
    @ObservationIgnored private var catchUpLimit: Task<Void, Never>?
    @ObservationIgnored private var backgroundSince: Date?
    /// The notes this device has had (`Pref.knownNoteIDs`); nil until first counted.
    @ObservationIgnored private lazy var knownNoteIDs: Set<String>? =
        UserDefaults.standard.stringArray(forKey: Profile.key(Pref.knownNoteIDs)).map(Set.init)
    /// Words added from a chat on the phone; nil when no cloud is set up.
    @ObservationIgnored private var cloud: CloudSync? {
        didSet { cloudSource = cloud?.source }
    }
    /// Where the cloud came from, for Settings; nil: none.
    private(set) var cloudSource: CloudSync.Source?
    /// Cards and notes kept in memory between screens; dropped when notes are added or deleted.
    @ObservationIgnored let cache = StudyCache()

    /// False in a build made with `make-dmg.sh --no-icloud`. The iPhone app always has it.
    private static var hasICloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
    }

    private init() {
        Pref.registerDefaults()
        #if DEBUG && os(macOS)
        let snapshots = DebugSnapshots.directory != nil
        #else
        let snapshots = false
        #endif
        if !snapshots {
            recentlyAdded = UserDefaults.standard.stringArray(forKey: Profile.key(Pref.recentlyAdded)) ?? []
            lesson = UserDefaults.standard.data(forKey: Profile.key(Pref.lesson)).flatMap { try? JSONDecoder().decode(Lesson.self, from: $0) }
        }
        do {
            #if DEBUG && os(macOS)
            if DebugSnapshots.directory != nil {
                container = try SrbStore.inMemory()
                seedIfNeeded()
                return
            }
            #endif
            try FileManager.default.createDirectory(at: SharedFiles.inbox, withIntermediateDirectories: true)
            if Profile.isTrial {
                try FileManager.default.createDirectory(at: Profile.trialFolder, withIntermediateDirectories: true)
            }
            let store = (Profile.isTrial ? Profile.trialFolder : SharedFiles.folder).appending(path: "Srpski.store")
            if !Profile.isTrial { StoreBackup.beforeICloud(store) }
            do {
                // Without the entitlement CloudKit traps on a background queue instead of throwing.
                guard Self.hasICloudEntitlement, !SharedFiles.isTestCopy, !Profile.isTrial else { throw CocoaError(.featureUnsupported) }
                container = try Perf.measure("launch: open store") { try SrbStore.container(url: store, cloudKit: true) }
            } catch {
                // E.g. a build without the iCloud entitlement: study offline rather than not at all.
                NSLog("Srpski iCloud: can't sync, opening the deck without it: %@", String(describing: error))
                container = try SrbStore.container(url: store, cloudKit: false)
                iCloud.isOff = true
            }
        } catch {
            fatalError("Couldn't open the database: \(error)")
        }
        Perf.measure("launch: store passes") {
            let context = container.mainContext
            DeckImporter.migrateToLevels(in: context)
            DeckImporter.migrateTopics(in: context)
            Deduplicator.assignMissingUIDs(in: context)
            Deduplicator.mergeDuplicates(in: context)
            if !Profile.isTrial {
                importInbox()
                shareLesson()
                cloud = makeCloud()
            }
            updateIsEmpty()
            // Updated from a version without the first-launch screens: they're not for this deck.
            if !isEmpty { UserDefaults.standard.set(true, forKey: Pref.onboarded) }
        }
        // Not at launch: it held up the first screen (about half a second on the Mac). On the
        // iPhone nothing is new since the app last went to the background, and it goes out with
        // the rest then (flushPublish); the Mac writes it once answering pauses.
        schedulePublish()
        watchInbox()
        watchICloud()
        // Left for another app (the chat, say): what's waiting goes out now.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishIfPending() }
        }
        cloud?.start()
    }

    var engine: StudyEngine {
        var engine = StudyEngine(
            context: container.mainContext,
            scheduler: FSRSScheduler(desiredRetention: UserDefaults.standard.double(forKey: Pref.retention))
        )
        engine.cache = cache
        engine.lessonNoteIDs = Set(lesson?.noteIDs ?? [])
        engine.formGroups = Pref.formGroups
        engine.casesStepByStep = UserDefaults.standard.bool(forKey: Pref.casesStepByStep)
        return engine
    }

    var lessonSize: Int { max(UserDefaults.standard.integer(forKey: Pref.lessonSize), 3) }

    /// The level picked at first launch; words you add yourself start out at it. nil: none picked.
    /// Lessons and topics take every level: the New words list filters by level instead.
    var newLevel: String? {
        get {
            _ = revision
            return UserDefaults.standard.string(forKey: Pref.newLevel).flatMap { $0.isEmpty ? nil : $0 }
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: Pref.newLevel)
            didChange()
        }
    }

    /// The first-launch screens haven't been through yet, or Settings → Debug shows them.
    var needsOnboarding: Bool {
        _ = revision
        return onboardingPreview || !UserDefaults.standard.bool(forKey: Pref.onboarded)
    }

    /// Settings → Debug → Show onboarding: the screens on top of the deck you have, changing nothing.
    var onboardingPreview = false

    /// The first-launch screens are done: the chosen built-in words go in, new words come from the
    /// chosen level. No levels: the deck starts empty (words of one's own, or the ones iCloud brings).
    /// A preview just goes away.
    func finishOnboarding(levels: [String], newLevel: String?) {
        if onboardingPreview {
            onboardingPreview = false
            return
        }
        if !levels.isEmpty { StarterLibrary.add(levels: levels, to: self) }
        UserDefaults.standard.set(newLevel ?? "", forKey: Pref.newLevel)
        UserDefaults.standard.set(true, forKey: Pref.onboarded)
        didChange()
    }

    /// Shown on the lesson card and in the session header for a lesson of words just added from a chat.
    static let newWordsLessonLabel = "New words"

    /// Starts a lesson of new words from `topic` / `level` (nil = any). Returns false if there's nothing new there.
    @discardableResult
    func startLesson(topic: String?, level: String? = nil) -> Bool {
        guard let lesson = engine.startLesson(topic: topic, level: level, size: lessonSize) else { return false }
        self.lesson = lesson
        didChange()
        return true
    }

    /// A lesson of exactly these words, in this order. Returns false when none of them are still new.
    /// Built-in words among them that the deck doesn't have yet come in first, as words not
    /// started; nothing already in the deck changes.
    @discardableResult
    func startChosenLesson(noteIDs: [String]) -> Bool {
        let have = Set(engine.allNotes().map(\.noteID))
        let fromLibrary = noteIDs.filter { !have.contains($0) }
        if !fromLibrary.isEmpty { StarterLibrary.add(ids: fromLibrary, to: self) }
        guard let lesson = engine.startLesson(
            noteIDs: noteIDs, size: max(noteIDs.count, 1), label: Self.newWordsLessonLabel
        ) else { return false }
        self.lesson = lesson
        didChange()
        return true
    }

    func endLesson() {
        lesson = nil
        didChange()
    }

    func deleteWord(_ note: Note) throws {
        let context = container.mainContext
        context.delete(note)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        cache.invalidate()
        didChange()
    }

    /// Lessons open on the other device that aren't finished and aren't the one open here.
    func lessonsElsewhere() -> [SyncedLesson.Elsewhere] {
        let engine = engine
        return SyncedLesson.elsewhere(than: CloudSync.deviceID, in: container.mainContext).filter {
            $0.lesson != lesson && !engine.progress(of: $0.lesson).isFinished
        }
    }

    /// Continue here a lesson open on the other device. It replaces the one open here, like starting a new one.
    func takeOver(_ lesson: Lesson) {
        self.lesson = lesson
        didChange()
    }

    private func shareLesson() {
        #if DEBUG && os(macOS)
        if DebugSnapshots.directory != nil { return }
        #endif
        try? SyncedLesson.publish(lesson, device: CloudSync.deviceID, name: CloudSync.deviceName, in: container.mainContext)
    }

    private func saveLesson() {
        #if DEBUG && os(macOS)
        if DebugSnapshots.directory != nil { return } // headless snapshots share the real app's settings
        #endif
        let defaults = UserDefaults.standard
        if let lesson, let data = try? JSONEncoder().encode(lesson) {
            defaults.set(data, forKey: Profile.key(Pref.lesson))
        } else {
            defaults.removeObject(forKey: Profile.key(Pref.lesson))
        }
        if !Profile.isTrial { shareLesson() }
    }

    /// Words waiting for review (`reviewWaitingCount`: due, and quick repeats coming up), the open
    /// lesson's aside. Worked out once per change to the deck
    /// and minute: the window's tab, the menu bar, its popover, home and the widgets all show it,
    /// and each count goes through every card.
    func dueCount(now: Date = .now) -> Int {
        let minute = Int(now.timeIntervalSince1970 / 60)
        if let kept = dueKept, kept.revision == revision, kept.minute == minute, kept.lesson == lesson {
            return kept.count
        }
        let count = engine.reviewWaitingCount(now: now, excluding: lesson)
        dueKept = (revision, minute, lesson, count)
        return count
    }

    func didChange() {
        revision += 1
        updateIsEmpty()
        rememberLocalNotes()
        schedulePublish()
    }

    /// Words added or removed here (a chat's inbox, a level, by hand): known, and not news when
    /// iCloud next brings something. Only when the count moved, so answering costs nothing.
    private func rememberLocalNotes() {
        #if DEBUG && os(macOS)
        if DebugSnapshots.directory != nil { return }
        #endif
        let count = (try? container.mainContext.fetchCount(FetchDescriptor<Note>())) ?? 0
        guard count != knownNoteIDs?.count else { return }
        remember(Set(allNoteOrder().keys))
    }

    /// Words from a chat that iCloud brought: the cloud hands each chat deck to one device, which
    /// put them in its own `recentlyAdded`, and the other showed no "Words from chat" (the Mac took
    /// them in, the iPhone only got the notes). New ids here are those, except a level of
    /// built-in words picked on the other device: a chat brings built-in words too («smeti»,
    /// «kasniti»), but a few at a time, a level hundreds.
    private func noticeArrivals() {
        let order = allNoteOrder()
        let ids = Set(order.keys)
        defer { remember(ids) }
        guard let known = knownNoteIDs else { return }
        var arrived = ids.subtracting(known).subtracting(recentlyAdded)
        let builtIn = arrived.intersection(StarterLibrary.ids)
        if builtIn.count >= 50 { arrived.subtract(builtIn) }
        guard !arrived.isEmpty else { return }
        recentlyAdded += arrived.sorted { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) }
    }

    private func allNoteOrder() -> [String: Int] {
        let notes = (try? container.mainContext.fetch(FetchDescriptor<Note>())) ?? []
        return Dictionary(notes.map { ($0.noteID, $0.order) }, uniquingKeysWith: min)
    }

    private func remember(_ ids: Set<String>) {
        guard ids != knownNoteIDs else { return }
        knownNoteIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Profile.key(Pref.knownNoteIDs))
    }

    private func updateIsEmpty() {
        let empty = ((try? container.mainContext.fetchCount(FetchDescriptor<Note>())) ?? 0) == 0
        if empty != isEmpty { isEmpty = empty }
    }

    // MARK: iCloud

    /// Tracks every sync for the status line. After iCloud brings in changes from the other
    /// device: fold duplicates, drop cached cards and refresh. Imports come in bursts, so that
    /// waits until they settle.
    private func watchICloud() {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastSave = .now }
        }
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event
            else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.iCloud.record(event)
                if let error = event.error {
                    NSLog("Srpski iCloud: %@ failed: %@", String(describing: event.type), error.localizedDescription)
                }
                guard event.type == .import, event.endDate != nil else { return }
                if self.catchingUp {
                    // The first import since opening: the counts at once, not after the usual
                    // settling wait, which would keep the banner on "Syncing" two seconds more.
                    self.syncRefreshTask?.cancel()
                    self.refreshFromICloud()
                    self.endCatchUp()
                } else {
                    self.scheduleSyncRefresh()
                }
            }
        }
    }

    /// The app went to the background (iPhone).
    func wentToBackground() {
        backgroundSince = .now
        endCatchUp()
    }

    /// The app is in front again (iPhone): after a minute or more away the other device may have
    /// moved on, so home waits for iCloud's next import before showing counts.
    func cameToForeground() {
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        if Date.now.timeIntervalSince(since) >= 60 { beginCatchUp() }
    }

    /// Waits for iCloud's next import, at most a few seconds (offline, or nothing comes).
    private func beginCatchUp() {
        guard !iCloud.isOff else { return }
        if !catchingUp { catchingUp = true }
        catchUpLimit?.cancel()
        catchUpLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.endCatchUp()
        }
    }

    private func endCatchUp() {
        catchUpLimit?.cancel()
        catchUpLimit = nil
        if catchingUp { catchingUp = false }
    }

    /// Waits until what's been saved here has gone to iCloud, at most `limit`. On the way to the
    /// background: let go at once, the iPhone sent its last answers only when it next woke, and
    /// the Mac kept showing those words as due for minutes.
    func waitForICloudExport(limit: Duration = .seconds(25)) async {
        let end = ContinuousClock.now + limit
        while !iCloud.isOff, (lastSave ?? .distantPast) > (iCloud.exportedThrough ?? .distantPast), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func scheduleSyncRefresh() {
        syncRefreshTask?.cancel()
        syncRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refreshFromICloud()
        }
    }

    func refreshFromICloud() {
        let context = container.mainContext
        Perf.measure("sync: dedupe") {
            Deduplicator.assignMissingUIDs(in: context)
            Deduplicator.mergeDuplicates(in: context)
        }
        noticeArrivals()
        cache.invalidate()
        didChange()
        // The Mac's cloud settings may just have arrived.
        if cloud == nil, let fresh = makeCloud() {
            cloud = fresh
            fresh.start()
        }
    }

    /// iPhone without words yet: the deck that a new Mac starts with.
    func loadStarterDeck() {
        seedIfNeeded()
        cache.invalidate()
        didChange()
    }

    /// Rewriting notes.json, the tutor report and the widget data takes a moment (170 ms on the
    /// Mac), so it waits until answering pauses for half a minute instead of running after every
    /// card; the end of a session and leaving the app write it at once (`publishIfPending`).
    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.publishForMCP()
        }
    }

    /// Words from a chat came in: the widgets and the chat's copy of the deck shouldn't wait.
    private func publishNow() {
        publishTask?.cancel()
        publishForMCP(uploadNow: true)
    }

    /// Writes anything still waiting, e.g. when the app quits or goes to the background.
    func flushPublish() {
        publishIfPending()
        cloud?.flush()
    }

    /// Writes the deck files and the widgets now if a change is waiting: a session ended, or the
    /// Mac app was left (the chat may be asked about the deck next).
    func publishIfPending() {
        guard publishPending || publishTask.map({ !$0.isCancelled }) == true else { return }
        publishTask?.cancel()
        publishForMCP()
    }
    func didOpenQuickReview() { quickOpenCount += 1 }

    /// iPhone: the cloud connector was changed in Settings.
    func reconnectCloud() {
        if UserDefaults.standard.string(forKey: Pref.cloudConnector)?.isEmpty ?? true {
            // A cleared connector stops being offered to the other device.
            try? CloudJournal.share(url: "", token: "", device: CloudSync.deviceID, in: container.mainContext)
        }
        cloud?.stop()
        cloud = makeCloud()
        cloud?.start()
    }

    /// The URL to add to a chat, if this device has a cloud (its own, or the Mac's through iCloud).
    var chatConnectorURL: String? {
        _ = revision
        return cloud?.connectorURL
    }

    /// A connector of the learner's own from the cloud, used from now on.
    func createChatConnector() async throws {
        let connector = try await CloudSync.signUp()
        UserDefaults.standard.set(connector, forKey: Pref.cloudConnector)
        reconnectCloud()
        didChange()
    }

    /// Asks the cloud whether a chat has called the connector; remembers a yes.
    @discardableResult
    func checkChatConnected() async -> Date? {
        guard let seen = await cloud?.chatSeenAt() else { return nil }
        if !UserDefaults.standard.bool(forKey: Pref.chatConnected) {
            UserDefaults.standard.set(true, forKey: Pref.chatConnected)
        }
        return seen
    }

    /// iPhone background refresh: picks up words from a chat while the app isn't open.
    func pullFromCloud() async {
        await cloud?.pull()
        await cloud?.finishUpload()
    }

    private func makeCloud() -> CloudSync? {
        CloudSync(
            context: container.mainContext,
            importDeck: { [weak self] deck in try self?.importCloudDeck(deck) },
            didImport: { [weak self] in self?.publishNow() }
        )
    }

    func applyHotKey() {
        let defaults = UserDefaults.standard
        for slot in GlobalHotKey.Slot.allCases {
            GlobalHotKey.shared.register(
                slot,
                keyCode: UInt32(defaults.integer(forKey: slot.codeKey)),
                modifiers: UInt32(defaults.integer(forKey: slot.modifiersKey))
            )
        }
    }

    // MARK: MCP bridge

    /// Decks that the MCP server dropped into the inbox. Imported quietly: no alert mid-review.
    /// Notes that came in from a chat since you last dismissed them, oldest first. Shown on the
    /// Study home screen so you can see what was added, and learn the ones not started yet.
    var recentlyAdded: [String] = [] {
        didSet {
            #if DEBUG && os(macOS)
            if DebugSnapshots.directory != nil { return }
            #endif
            UserDefaults.standard.set(recentlyAdded, forKey: Profile.key(Pref.recentlyAdded))
        }
    }

    func dismissRecentlyAdded() {
        recentlyAdded = []
        didChange()
    }

    private func importInbox() {
        let result = Inbox.importPending(into: container.mainContext)
        absorb(result.summary)
        for failure in result.failures { NSLog("Srpski inbox: %@", failure) }
    }

    private func importCloudDeck(_ deck: DeckFile) throws {
        absorb(try DeckImporter.merge(deck, into: container.mainContext))
    }

    private func absorb(_ summary: ImportSummary) {
        if !summary.addedIDs.isEmpty {
            recentlyAdded += summary.addedIDs.filter { !recentlyAdded.contains($0) }
        }
        if summary.added + summary.updated + summary.deleted > 0 {
            // The other device may have imported the same deck.
            Deduplicator.mergeDuplicates(in: container.mainContext)
            cache.invalidate()
            didChange()
        }
    }

    private func watchInbox() {
        let fd = open(SharedFiles.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.importInbox() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        inboxWatcher = source
    }

    /// Writes notes.json and tutor-report.md so the MCP server can answer questions about the deck.
    private func publishForMCP(uploadNow: Bool = false) {
        Perf.measure("publish") { publish(uploadNow: uploadNow) }
    }

    private func publish(uploadNow: Bool) {
        publishTask = nil
        publishPending = false
        #if DEBUG && os(macOS)
        if DebugSnapshots.directory != nil { return }
        #endif
        // The trial deck is nobody's: the chat, the cloud and the widgets keep the real one.
        if Profile.isTrial { return }
        let engine = engine
        let snapshot = Perf.measure("publish: snapshot") { engine.notesSnapshot() }
        let report = Perf.measure("publish: report") { engine.tutorReport() }
        Perf.measure("publish: files") {
            try? snapshot.write()
            try? report.write(to: SharedFiles.tutorReport, atomically: true, encoding: .utf8)
        }
        Perf.measure("publish: cloud") { cloud?.publish(snapshot, report: report, now: uploadNow) }
        Perf.measure("publish: widgets") { publishForWidgets(engine) }
    }

    /// The words Settings → Which words picks, for the widgets and the Mac's menu bar word.
    func widgetWords(now: Date = .now) -> [Note] {
        let defaults = UserDefaults.standard
        let source = defaults.string(forKey: Pref.widgetWords).flatMap(WidgetWordSource.init(rawValue:)) ?? .mixed
        return engine.widgetWords(source, topic: defaults.string(forKey: Pref.widgetTopic), lesson: lesson, now: now)
    }

    /// The widget settings changed: only the widgets need writing again.
    func refreshWidgets() {
        publishForWidgets(engine)
    }

    private func publishForWidgets(_ engine: StudyEngine) {
        if Profile.isTrial { return }
        let now = Date.now
        let cards = engine.activeCards()
        let weekAhead = now.addingTimeInterval(7 * 86_400)
        let lessonProgress = lesson.map { engine.progress(of: $0) }
        let words = widgetWords(now: now).map { WidgetSnapshot.Word(cue: $0.cue, answer: $0.answer, info: $0.info) }

        let snapshot = WidgetSnapshot(
            updatedAt: now,
            dueNow: dueCount(now: now),
            newLeft: lessonProgress?.notStarted ?? 0,
            roundLearned: lessonProgress?.learned ?? 0,
            roundIntroduced: lessonProgress?.total ?? 0,
            upcoming: cards.filter { $0.phase != .new && $0.due > now && $0.due < weekAhead }.map(\.due).sorted(),
            words: words
        )
        // Same figures and words as last time (the time aside): nothing for the widgets to redraw.
        var unchanged = snapshot
        unchanged.updatedAt = lastWidgets?.updatedAt ?? now
        if unchanged == lastWidgets { return }
        lastWidgets = snapshot
        if SharedFiles.isTestCopy { return }
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Decks

    /// A new Mac deck starts with the built-in A1 words (the iPhone asks first, `finishOnboarding`).
    /// The A1 words into an empty deck: debug snapshots and "load the starter deck" by hand.
    private func seedIfNeeded() {
        let context = container.mainContext
        guard (try? context.fetchCount(FetchDescriptor<Note>())) == 0 else { return }
        _ = try? DeckImporter.merge(DeckFile(notes: StarterLibrary.notes(levels: [Level.a1.rawValue])), into: context)
        UserDefaults.standard.set(true, forKey: Pref.onboarded)
    }

    func pasteDeck() {
        let text = NSPasteboard.general.string(forType: .string)
        guard let text, !text.isEmpty else {
            showAlert(String(localized: "Nothing to paste"), String(localized: "Copy a deck (JSON) from your chat first."))
            return
        }
        importDeck(text, from: String(localized: "the clipboard"))
    }

    func openDeckFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose one or more deck files")
        guard panel.runModal() == .OK else { return }
        importDeckFiles(panel.urls)
    }

    /// Deck files picked in the open panel (Mac) or the file importer (iPhone).
    func importDeckFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                importDeck(try String(contentsOf: url, encoding: .utf8), from: url.lastPathComponent)
            } catch {
                showAlert(String(localized: "Couldn't read \(url.lastPathComponent)"), error.localizedDescription)
            }
        }
    }

    private func importDeck(_ text: String, from source: String) {
        do {
            let deck = try DeckFile.parse(text)
            let summary = try DeckImporter.merge(deck, into: container.mainContext)
            cache.invalidate()
            didChange()
            showAlert(String(localized: "Imported \(source)"), summary.description)
        } catch {
            showAlert(String(localized: "Couldn't import \(source)"), error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// iCloud sync as the Settings status line shows it: running, last finished, or failing.
struct ICloudStatus {
    /// The store opened without iCloud (e.g. a build without the entitlement).
    var isOff = false
    /// Setups, imports and exports that have started and not finished yet.
    private(set) var running: Set<UUID> = []
    private(set) var lastSynced: Date?
    /// The last failure, until a later sync succeeds.
    private(set) var error: String?
    /// The start of the last export that went through: an export started after a save carries it.
    private(set) var exportedThrough: Date?

    var isSyncing: Bool { !running.isEmpty }

    mutating func record(_ event: NSPersistentCloudKitContainer.Event) {
        guard let end = event.endDate else {
            running.insert(event.identifier)
            return
        }
        running.remove(event.identifier)
        if event.succeeded {
            if event.type == .export { exportedThrough = max(exportedThrough ?? .distantPast, event.startDate) }
            lastSynced = end
            error = nil
        } else if let failure = event.error {
            error = failure.localizedDescription
        }
    }
}

/// Copies the database aside once before iCloud sync first touches it, in case the move to a
/// synced store goes wrong: Application Support/Srpski/Backups/before-icloud-<date>/.
enum StoreBackup {
    private static let doneKey = "backedUpBeforeICloud"

    static func beforeICloud(_ store: URL) {
        let defaults = UserDefaults.standard
        let fm = FileManager.default
        guard !defaults.bool(forKey: doneKey) else { return }
        guard fm.fileExists(atPath: store.path) else {
            defaults.set(true, forKey: doneKey) // a new store has nothing to lose
            return
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let folder = store.deletingLastPathComponent().appending(path: "Backups/before-icloud-\(stamp)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: store.path + suffix)
                guard fm.fileExists(atPath: file.path) else { continue }
                let target = folder.appending(path: file.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: file, to: target)
            }
            defaults.set(true, forKey: doneKey)
        } catch {
            NSLog("Srpski: backup before iCloud failed: %@", error.localizedDescription)
        }
    }
}
