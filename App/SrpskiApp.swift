import SwiftUI
import SrbCore

@main
struct SrpskiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Kvačica", id: "main") {
            ContentView()
                .environment(AppModel.shared)
                .frame(minWidth: 780, minHeight: 520)
                .background(MainWindowHook())
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Word…") { MainWindow.addWord() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Import Deck…") { AppModel.shared.openDeckFile() }
                    .keyboardShortcut("o")
                Button("Paste Deck") { AppModel.shared.pasteDeck() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                if Updates.isOn {
                    Button("Check for Updates…") { Updates.check() }
                }
            }
            // ⌘, with the floating panel on: its own Settings page, not a second window of them.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MainWindow.showSettingsPage() }
                    .keyboardShortcut(",")
            }
        }

        Window("Words", id: "words") {
            SectionWindow(tab: .words)
                .environment(AppModel.shared)
        }
        .defaultSize(width: 1000, height: 720)

        Window("Progress", id: "progress") {
            SectionWindow(tab: .progress)
                .environment(AppModel.shared)
        }
        .defaultSize(width: 1000, height: 720)

        // ⌘N from any window, the floating panel included: a window of its own, not a sheet on one.
        Window("New Word", id: "add-word") {
            NavigationStack { AddWordView() }
                .environment(AppModel.shared)
        }
        .windowResizability(.contentSize)

        // The first launch: the iPhone's onboarding pages, in a window of their own.
        Window("Welcome to Kvačica", id: "welcome") {
            WelcomeWindow()
                .environment(AppModel.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    /// Closing the window (⌘W) keeps the app in the menu bar; the red button only minimizes it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon, or opening the app again: the panel, never SwiftUI's own window for it.
    /// Without the panel, the window put away (hidden) comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MainWindow.floats || !flag {
            MainWindow.show()
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushPublish()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugSnapshots.checkAnswerFieldIfRequested()
        DebugSnapshots.renderDashboardIfRequested(model: AppModel.shared)
        DebugSnapshots.renderExercisesIfRequested(model: AppModel.shared)
        DebugSnapshots.renderHomeIfRequested(model: AppModel.shared)
        DebugSnapshots.renderReviewWindowIfRequested(model: AppModel.shared)
        DebugSnapshots.renderPaletteIfRequested(model: AppModel.shared)
        DebugSnapshots.renderMenuBarIfRequested(model: AppModel.shared)
        PerfBench.runIfRequested(model: AppModel.shared)
        if DebugSnapshots.directory != nil { return }
        #endif
        // Before launch finishes, so a hidden Dock icon doesn't flash up first.
        MainWindow.applyDockPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusBar = StatusBarController(model: AppModel.shared)
        self.statusBar = statusBar
        #if DEBUG
        if let dir = DebugSnapshots.directory {
            DebugSnapshots.run(in: dir) { statusBar.toggle() }
            return
        }
        #endif
        Updates.start()
        if AppModel.shared.needsOnboarding {
            DispatchQueue.main.async { MainWindow.showWelcome() }
        } else if MainWindow.floats {
            MainWindow.show()
        }
    }
}

/// The onboarding pages at the iPhone's size; the window goes when they're done.
private struct WelcomeWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView()
            .frame(width: 430, height: 760)
            .onChange(of: model.needsOnboarding) {
                guard !model.needsOnboarding else { return }
                dismissWindow(id: "welcome")
                MainWindow.show()
            }
    }
}

/// The main window, so the menu bar popover can bring it back.
@MainActor
enum MainWindow {
    fileprivate(set) static weak var window: NSWindow?
    fileprivate static var open: OpenWindowAction?
    fileprivate static var openSettings: OpenSettingsAction?
    /// Set by the menu bar item: closes its popover when the window comes up.
    static var willShow: (() -> Void)?
    /// Put away by the red button while there's no Dock icon to minimize into.
    private static var tucked = false

    static var showsInDock: Bool { UserDefaults.standard.bool(forKey: Pref.showInDock) }

    static func show() {
        willShow?()
        NSApp.activate(ignoringOtherApps: true)
        if floats {
            FloatingPanelController.shared.showStudy()
        } else if let window, window.isVisible || window.isMiniaturized || tucked {
            tucked = false
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
    }

    /// The shortcut from any app: up front if it isn't, away if it is.
    static func toggle() {
        let inFront = NSApp.isActive && (floats ? FloatingPanelController.shared.isKey : window?.isKeyWindow == true)
        if inFront { putAway() } else { show() }
    }

    /// The quick-card shortcut with the floating panel on: straight to a card; again: away.
    static func quickCard() {
        let panel = FloatingPanelController.shared
        if NSApp.isActive, panel.showsQuickCard {
            putAway()
            return
        }
        willShow?()
        NSApp.activate(ignoringOtherApps: true)
        panel.showQuickCard()
    }

    /// Settings from the menu bar: the panel's own page with the panel on, the window without.
    static func showSettingsPage() {
        guard floats else { return showSettings() }
        willShow?()
        NSApp.activate(ignoringOtherApps: true)
        FloatingPanelController.shared.showPage(.settings)
    }

    /// ⌘N: the form over the floating panel's Words, or a New Word window of its own.
    static func addWord() {
        guard floats else { return showWindow("add-word") }
        willShow?()
        NSApp.activate(ignoringOtherApps: true)
        FloatingPanelController.shared.addWord()
    }

    /// The first-launch pages (or Settings → Debug → Show onboarding).
    static func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        open?(id: "welcome")
    }

    /// Words or Progress, in a window of their own (from the floating panel).
    static func showWindow(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        open?(id: id)
    }

    /// From the menu bar popover: without a Dock icon the app menu (and its Settings…) never shows.
    static func showSettings() {
        willShow?()
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    /// With a Dock icon the red button minimizes into the Dock; without one it just hides the
    /// window, and the menu bar brings it back. The floating panel just goes, and with nothing
    /// else of the app on screen the app you were in comes back to the front.
    static func putAway() {
        if floats {
            FloatingPanelController.shared.hide()
            let others = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !others { NSApp.hide(nil) }
            return
        }
        guard let window else { return }
        if showsInDock {
            window.miniaturize(nil)
        } else {
            window.orderOut(nil)
            tucked = true
            NSApp.hide(nil)
        }
    }

    /// Settings → Floating window: the floating panel (`FloatingPanelController`) instead of
    /// this window.
    static var floats: Bool { UserDefaults.standard.bool(forKey: Pref.floatingWindow) }
    private static var appliedFloats: Bool?

    /// The setting turned on or off: swap the window for the panel or back. With the panel on,
    /// this window never shows: SwiftUI opens it at launch, so it's see-through and out of reach
    /// until it's closed (`keepAway`). Hidden instead of closed, SwiftUI brought it back when the
    /// app was opened again.
    fileprivate static func applyFloatingSetting() {
        guard let window else { return }
        let floats = self.floats
        window.alphaValue = floats ? 0 : 1
        window.ignoresMouseEvents = floats
        keepAway()
        guard appliedFloats != floats else { return }
        let first = appliedFloats == nil
        appliedFloats = floats
        guard !first else { return }
        if floats {
            FloatingPanelController.shared.show()
        } else {
            FloatingPanelController.shared.hide()
            show()
        }
    }

    /// With the panel on: the window closed, and the panel keeps the keyboard if it's up.
    /// Turning the setting off opens a new one.
    fileprivate static func keepAway() {
        guard floats, let window, window.isVisible else { return }
        window.close()
        tucked = false
        if FloatingPanelController.shared.isVisible { FloatingPanelController.shared.show() }
    }

    /// Shows or hides the Dock icon to match the setting.
    static func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = showsInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.isRunning else {
            NSApp.setActivationPolicy(policy)
            return
        }
        FloatingPanelController.shared.stayThroughDockSwitch()
        NSApp.setActivationPolicy(policy)
        // A window minimized into a Dock icon that's gone would be out of reach.
        if policy == .accessory, let window, window.isMiniaturized { window.deminiaturize(nil) }
        // Switching drops the app to the background; keep the window you were in (Settings) up front.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// The red button minimizes the window instead of closing it: the app stays where it was, and
/// the Dock icon or the menu bar brings it back.
private struct MainWindowHook: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Hook().onAppear {
            MainWindow.open = openWindow
            MainWindow.openSettings = openSettings
            // At launch the hook can come after applicationDidFinishLaunching asked for this.
            if AppModel.shared.needsOnboarding { MainWindow.showWelcome() }
        }
    }

    private struct Hook: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { HookView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class HookView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainWindow.window = window
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closePressed)
            }
            MainWindow.applyFloatingSetting()
            // SwiftUI orders the window in after this: put it away again once it has.
            DispatchQueue.main.async { MainWindow.applyFloatingSetting() }
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { MainWindow.applyFloatingSetting() }
                },
            ] + [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                 NSWindow.didChangeOcclusionStateNotification].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { MainWindow.keepAway() }
                }
            }
        }

        @objc private func closePressed(_ sender: Any?) {
            MainWindow.putAway()
        }
    }
}
