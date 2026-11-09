import AppKit
import Carbon.HIToolbox
import SwiftUI
import SrbCore
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    /// When the running app was built (its executable's date), to tell whether an install
    /// actually took: the version number never changes.
    static let buildDate: String = {
        let date = Bundle.main.executableURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Unknown")
    }()

    /// "1.0 (57)": the version and the build number, as App Store Connect and TestFlight show them.
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    /// The pages App Store Connect and the About section point to (cloud/src: privacy.js, support.js).
    static let privacyURL = URL(string: "https://srpski.egoshin.workers.dev/privacy")!
    static let supportURL = URL(string: "https://srpski.egoshin.workers.dev/support")!
    static let contactURL = URL(string: "mailto:egoshin.georgii@gmail.com")!

    /// iPhone: false while another tab is showing, so the form is not refreshed on every answer.
    var live = true
    /// The Settings window's width; the floating panel's page is wider.
    var formWidth: CGFloat = 480
    /// The floating panel shows one part at a time; the Settings window, all of them.
    var category: SettingsCategory?
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.lessonSize) private var lessonSize = 10
    @AppStorage(Pref.retention) private var retention = 0.9
    @AppStorage(Pref.autoSpeak) private var autoSpeak = false
    @AppStorage(Pref.pushToTalk) private var pushToTalk = true
    @AppStorage(Pref.strictDiacritics) private var strictDiacritics = false
    /// Read so the "Forms in cards" row shows the new count when you come back from its page.
    @AppStorage(Pref.formsOff) private var formsOff = ""
    @AppStorage(Pref.widgetWords) private var widgetWords = WidgetWordSource.mixed.rawValue
    @AppStorage(Pref.widgetTopic) private var widgetTopic = ""
    /// Applies the retention once the slider stops: each step redid home, the menu bar and the
    /// deck files.
    @State private var retentionSettled: Task<Void, Never>?
    /// Read from the system each time Settings opens: it can be changed in System Settings too.
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Pref.showInDock) private var showInDock = true
    @AppStorage(Pref.floatingWindow) private var floatingWindow = true
    @AppStorage(Pref.quickCards) private var quickCards = 1
    @AppStorage(Pref.menuBarShows) private var menuBarShows: MenuBarShows = .icon
    @AppStorage(Pref.menuBarMinutes) private var menuBarMinutes = 5
    @AppStorage(DebugExercise.key) private var debugExercise = ""
    @AppStorage(CardMotion.key) private var cardMotion: CardMotion = .slide
    @AppStorage(CardMotion.speedKey) private var motionSpeed: MotionSpeed = .standard
    @AppStorage(StudyStyle.key) private var studyStyle: StudyStyle = .cards

    var body: some View {
        tracksChanges(form)
            .formStyle(.grouped)
            .frame(width: formWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Mac: the Settings window, or one part of it in the floating panel.
    private var form: some View {
        Form {
            if shows(.sync) {
                Section("iCloud") {
                    ICloudStatusRow()
                }
                ConnectorSection()
            }
            if shows(.study) {
                Section("Study") {
                    LanguageRow()
                    Stepper("Words per lesson: \(lessonSize)", value: $lessonSize, in: 3...30)
                    Toggle(isOn: $strictDiacritics) {
                        Text("Count missing č ć š ž đ as mistakes")
                        Text("Off: “novcanik” counts as “novčanik”. A missing j in nj / lj is still flagged.")
                    }
                    LabeledContent("Desired retention") {
                        HStack {
                            Slider(value: $retention, in: 0.80...0.97, step: 0.01)
                            Text(retention, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            if shows(.forms) {
                FormGroupsList()
            }

            if shows(.voice) {
                Section("Voice") {
                    Text(model.speaker.voiceDescription)
                        .foregroundStyle(.secondary)
                    Toggle("Speak the answer after grading", isOn: $autoSpeak)
                        .disabled(!model.speaker.isAvailable)
                    if let locale = model.speechInput.locale {
                        Toggle(isOn: $pushToTalk) {
                            Text("Answer by voice: Tab, then just say it")
                            Text("\(locale.identifier) recognition, processed by Apple's servers. System dictation works either way.")
                        }
                    } else {
                        Text("Push-to-talk isn't available (no Serbian, Croatian or Bosnian speech recognition). System dictation still works in the answer field.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if shows(.widget) {
                Section("Desktop widget & menu bar") {
                    Picker(selection: $widgetWords) {
                        ForEach(WidgetWordSource.allCases, id: \.rawValue) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    } label: {
                        Text("Which words")
                        Text(String(localized: "For the desktop widget and the word in the menu bar. \(WidgetWordSource(rawValue: widgetWords)?.detail ?? "")"))
                    }
                    if widgetWords == WidgetWordSource.topic.rawValue {
                        Picker("Topic", selection: $widgetTopic) {
                            ForEach(topics, id: \.self) { Text(Topics.displayName($0)).tag($0) }
                        }
                        .onAppear {
                            if !topics.contains(widgetTopic), let first = topics.first { widgetTopic = first }
                        }
                    }
                }
            }

            if shows(.window) {
                Section("Window, menu bar & Dock") {
                    Toggle(isOn: $floatingWindow) {
                        Text("Floating window")
                        Text("Like Raycast: just the command line, over every app. Drag it by any empty spot; Esc puts it away. Words and Progress open from its list.")
                    }
                    LabeledContent("Open Kvačica shortcut") {
                        ShortcutRecorder(slot: .openApp)
                    }
                    LabeledContent {
                        ShortcutRecorder(slot: .quickReview)
                    } label: {
                        Text("Quick card shortcut")
                        Text(floatingWindow ? "From any app, straight to a card. Esc puts it away." : "From any app, the menu bar popover.")
                    }
                    if floatingWindow {
                        Picker(selection: $quickCards) {
                            Text(verbatim: "1").tag(1)
                            Text(verbatim: "3").tag(3)
                            Text(verbatim: "5").tag(5)
                            Text("Until done").tag(0)
                        } label: {
                            Text("Cards per shortcut")
                            Text("Then the panel goes away by itself.")
                        }
                        .pickerStyle(.menu)
                    }
                    Picker(selection: $menuBarShows) {
                        ForEach(MenuBarShows.allCases, id: \.self) { shows in
                            Text(shows.title).tag(shows)
                        }
                    } label: {
                        Text("Menu bar shows")
                        Text("A word to glance at between tasks, from Which words under Widget, with the review count after it. Looking at it doesn't count as a review.")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: menuBarShows) {
                        UserDefaults.standard.set(menuBarShows.rawValue, forKey: Pref.menuBarShows)
                        StatusBarController.settingsChanged?()
                    }
                    if menuBarShows != .icon {
                        Picker("New word every", selection: $menuBarMinutes) {
                            ForEach(MenuBarShows.intervals, id: \.self) { minutes in
                                Text(minutes == 60 ? "hour" : "\(minutes) min").tag(minutes)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle(isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin)) {
                        Text("Open at login")
                        Text("So the shortcuts work from the moment you log in.")
                    }
                    Toggle(isOn: $showInDock) {
                        Text("Show in Dock")
                        Text("Off: Kvačica lives in the menu bar only. The red button hides the window; open it again from the menu bar.")
                    }
                    .onChange(of: showInDock) { MainWindow.applyDockPolicy() }
                }
            }

            if shows(.debug) {
                // The iPhone has one card motion of its own (ReviewView.cardView).
                Section("Debug") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Build", value: Self.buildDate)
                    Button("Show onboarding") {
                        model.onboardingPreview = true
                        MainWindow.showWelcome()
                    }
                    Picker(selection: $studyStyle) {
                        ForEach(StudyStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        Text("Study screen")
                        Text("Palette: a headline and one list of commands, for the home screen and the cards.")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: studyStyle) {
                        UserDefaults.standard.set(studyStyle.rawValue, forKey: StudyStyle.key)
                    }
                    // Tag the case itself. A string tag on an Identifiable row doesn't match the
                    // selection, so the menu snaps back and the new value never reaches UserDefaults.
                    Picker(selection: $cardMotion) {
                        ForEach(CardMotion.allCases, id: \.self) { motion in
                            Text(motion.title).tag(motion)
                        }
                    } label: {
                        Text("Transition")
                        Text("Everywhere on the Mac: card to card, between screens, the panel's pages and the menu bar. Blur, zoom and 3D can’t touch the answer field, so it snaps at the end of those.")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: cardMotion) {
                        UserDefaults.standard.set(cardMotion.rawValue, forKey: CardMotion.key)
                    }
                    Picker("Speed", selection: $motionSpeed) {
                        ForEach(MotionSpeed.allCases, id: \.self) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: motionSpeed) {
                        UserDefaults.standard.set(motionSpeed.rawValue, forKey: CardMotion.speedKey)
                    }
                }
            }
        }
    }

    /// What the settings change beyond themselves, the same on both forms.
    private func tracksChanges(_ content: some View) -> some View {
        content
        .onChange(of: lessonSize) { model.didChange() }
        .onChange(of: retention) {
            retentionSettled?.cancel()
            retentionSettled = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { model.didChange() }
            }
        }
        // Only the widgets and the menu bar word show these.
        .onChange(of: widgetWords) { widgetWordsChanged() }
        .onChange(of: widgetTopic) { widgetWordsChanged() }
    }

    private func widgetWordsChanged() {
        model.refreshWidgets()
        StatusBarController.settingsChanged?()
    }

    private func shows(_ part: SettingsCategory) -> Bool {
        category == nil || category == part
    }

    private var topics: [String] {
        _ = model.revision
        // Every level's: the widget isn't tied to the level lessons take.
        return Set(model.engine.allNotes().map { $0.topic ?? TopicSummary.other }).sorted()
    }
}

/// The app's language. iPhone: the system's per-app Language setting, one tap away. Mac: the app's
/// own AppleLanguages, which is what System Settings → Language & Region → Applications writes;
/// it applies the next time the app opens.
private struct LanguageRow: View {
    /// The language the app runs in now.
    private static let running = Bundle.main.preferredLocalizations.first == "ru" ? "Русский" : "English"

    @State private var language = Language.saved
    @State private var changed = false

    var body: some View {
        Picker(selection: $language) {
            ForEach(Language.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Language")
            if changed { Text("Kvačica switches to it the next time it opens.") }
        }
        .onChange(of: language) {
            language.save()
            changed = true
        }
    }

    private enum Language: String, CaseIterable, Identifiable {
        case system, en, ru

        var id: Self { self }

        var title: String {
            switch self {
            case .system: String(localized: "Same as the system")
            case .en: "English"
            case .ru: "Русский"
            }
        }

        /// Read from the app's own defaults: `UserDefaults.standard` would fall back to the system's list.
        static var saved: Language {
            let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            guard let first = (own?["AppleLanguages"] as? [String])?.first else { return .system }
            return first.hasPrefix("ru") ? .ru : .en
        }

        func save() {
            if self == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
            }
        }
    }
}

/// The parts of Settings, one at a time in the floating panel.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case study, forms, voice, window, sync, widget, debug

    var id: Self { self }

    var title: String {
        switch self {
        case .study: String(localized: "Study")
        case .forms: String(localized: "Forms in cards")
        case .voice: String(localized: "Voice")
        case .window: String(localized: "Window & shortcuts")
        case .sync: String(localized: "iCloud & chat")
        case .widget: String(localized: "Widget")
        case .debug: String(localized: "Debug")
        }
    }

    var symbol: String {
        switch self {
        case .study: "graduationcap"
        case .forms: "tablecells"
        case .voice: "waveform"
        case .window: "keyboard"
        case .sync: "icloud"
        case .widget: "square.grid.2x2"
        case .debug: "ladybug"
        }
    }
}

extension WidgetWordSource {
    var title: String {
        switch self {
        case .mixed: String(localized: "Hard words and current lesson")
        case .lesson: String(localized: "Current lesson")
        case .hard: String(localized: "Hard words")
        case .started: String(localized: "Everything I've started")
        case .topic: String(localized: "One topic")
        }
    }

    /// For the iPhone Settings row, where the long title didn't fit.
    var shortTitle: String {
        switch self {
        case .mixed: String(localized: "Hard + lesson")
        case .lesson: String(localized: "Lesson")
        case .hard: String(localized: "Hard words")
        case .started: String(localized: "Started words")
        case .topic: String(localized: "One topic")
        }
    }

    var detail: String {
        switch self {
        case .mixed: String(localized: "Words you got wrong lately and the lesson's words come up most, mixed with the rest.")
        case .lesson: String(localized: "The open lesson's words, including ones you haven't seen yet.")
        case .hard: String(localized: "Only words you got wrong in the last 30 days.")
        case .started: String(localized: "Every word you've started, newest first.")
        case .topic: String(localized: "Every word of the topic, the ones you've started first.")
        }
    }
}

/// Whether iCloud is syncing right now, when it last finished, or why it failed.
/// Which forms cards ask: the noun cases one by one, plurals, adjectives and their comparative,
/// the verb's tenses.
/// A form that's off is still in the word's table, just not asked.
private struct FormGroupsList: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.formsOff) private var off = ""
    @AppStorage(Pref.casesStepByStep) private var stepByStep = true

    var body: some View {
        Section {
            Toggle(isOn: $stepByStep) {
                Text("Cases one at a time")
                Text(CaseLadder.steps.map { Self.title($0) }.joined(separator: " → "))
            }
            if stepByStep { ladderStatus }
        } header: {
            Text("Cases")
        } footer: {
            Text("The next case opens once you get \(CaseLadder.needed) of the last \(CaseLadder.window) right in the current one. A new case comes first on every word that has it, picked from the word's forms with its endings on the card; after a few times it's typed.")
        }
        Section {
            ForEach(Self.nouns, id: \.self) { toggle($0) }
        } header: {
            Text("Nouns")
        } footer: {
            Text("A plural or an adjective's case is asked only when that case is on too.")
        }
        Section("Adjectives") {
            toggle(.adjectives)
            toggle(.comparison)
        }
        Section {
            ForEach(Self.verbs, id: \.self) { toggle($0) }
        } header: {
            Text("Verbs")
        } footer: {
            Text("Forms that are off still show in the word's table.")
        }
    }

    /// Which case is being learned and how close the next one is.
    private var ladderStatus: some View {
        let ladder = model.engine.caseLadder()
        return VStack(alignment: .leading, spacing: 2) {
            Text("Now: \(Self.title(ladder.current))")
            if let next = ladder.next {
                Text("\(ladder.currentRight) of the last \(ladder.currentCount) right · then \(Self.title(next))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Every case is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let nouns: [WordForms.Group] = [.genitive, .dative, .accusative, .vocative, .instrumental, .locative, .plural]
    private static let verbs: [WordForms.Group] = [.present, .past, .imperative]

    private func toggle(_ group: WordForms.Group) -> some View {
        Toggle(isOn: Binding(
            get: { !offGroups.contains(group) },
            set: { on in
                var groups = offGroups
                if on { groups.remove(group) } else { groups.insert(group) }
                off = WordForms.Group.allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
            }
        )) {
            Text(Self.title(group))
            Text(Self.example(group))
        }
    }

    private var offGroups: Set<WordForms.Group> { Set(WordForms.Group.allCases).subtracting(Pref.formGroups) }

    /// "All", "None" or how many are on, for the row that opens the list.
    static var summary: String {
        let on = Pref.formGroups.count
        return on == WordForms.Group.allCases.count ? String(localized: "All")
            : on == 0 ? String(localized: "None") : String(localized: "\(on) of \(WordForms.Group.allCases.count)")
    }

    static func title(_ group: WordForms.Group) -> String {
        switch group {
        case .genitive: String(localized: "Genitive")
        case .dative: String(localized: "Dative")
        case .accusative: String(localized: "Accusative")
        case .vocative: String(localized: "Vocative")
        case .instrumental: String(localized: "Instrumental")
        case .locative: String(localized: "Locative")
        case .plural: String(localized: "Plurals")
        case .adjectives: String(localized: "Adjective forms")
        case .comparison: String(localized: "Comparative")
        case .present: String(localized: "Present tense")
        case .past: String(localized: "Past tense")
        case .imperative: String(localized: "Imperative")
        }
    }

    static func example(_ group: WordForms.Group) -> String {
        switch group {
        case .genitive: "Nema hleba."
        case .dative: "Radujem se moru."
        case .accusative: "Vidim kuću."
        case .vocative: "Zdravo, Marko!"
        case .instrumental: "Sa hlebom."
        case .locative: "Mislim o gradu."
        case .plural: "Ovo su knjige."
        case .adjectives: "Nema dobrog mesta."
        case .comparison: "Ovaj je bolji od onog."
        case .present: "ja čitam"
        case .past: "on je čitao"
        case .imperative: "Čitaj!"
        }
    }
}

private struct ICloudStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.iCloud
        // Redrawn every half minute so "2 min ago" keeps up.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                if status.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…")
                } else if status.isOff {
                    Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    Text("Off: this build can't use iCloud")
                } else if let error = status.error {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                } else if let synced = status.lastSynced {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                    Text("Synced \(synced.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                } else {
                    Image(systemName: "icloud").foregroundStyle(.secondary)
                    Text("Waiting for iCloud")
                }
            }
        }
    }
}

/// Mac: the cloud a chat sends words to, from a connector URL (cloud.json, if there is one, wins).
private struct ConnectorSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.cloudConnector) private var connector = ""
    @State private var draft = ""

    var body: some View {
        Section {
            if model.cloudSource == .file {
                LabeledContent("Cloud", value: String(localized: "Set up in cloud.json"))
            } else {
                TextField("Connector URL", text: $draft, prompt: Text(verbatim: "https://…/mcp/…"))
                    .autocorrectionDisabled()
                    .onSubmit(save)
                if draft != connector {
                    Button("Save", action: save)
                        .disabled(!draft.isEmpty && !CloudSync.isValidConnector(draft))
                }
            }
        } header: {
            Text("Words from chat")
        } footer: {
            Text("Paste the connector URL you were given, and add the same URL to your chat (Claude or ChatGPT) as a custom connector. Words you add or remove there come straight here, and to your iPhone through iCloud.")
        }
        .onAppear { draft = connector }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || CloudSync.isValidConnector(text) else { return }
        connector = text
        draft = text
        model.reconnectCloud()
    }
}

/// Click, then press the new shortcut (Esc cancels).
extension SettingsView {
    /// Kvačica as a login item.
    fileprivate func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct ShortcutRecorder: View {
    let slot: GlobalHotKey.Slot
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?
    /// Bumped to redraw once a new label is saved.
    @State private var saved = 0

    private var label: String {
        _ = saved
        return UserDefaults.standard.string(forKey: slot.labelKey) ?? ""
    }

    var body: some View {
        Button(monitor == nil ? label : String(localized: "Type shortcut…")) {
            monitor == nil ? start() : stop()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == kVK_Escape {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty
            else {
                NSSound.beep()
                return nil
            }
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: slot.codeKey)
            defaults.set(flags.carbonFlags, forKey: slot.modifiersKey)
            defaults.set(flags.symbols + key, forKey: slot.labelKey)
            saved += 1
            model.applyHotKey()
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
