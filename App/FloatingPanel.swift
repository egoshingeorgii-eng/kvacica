import AppKit
import SwiftUI

/// Settings → Floating window: Study as a command line over every app, like Raycast. An NSPanel
/// of our own, not a SwiftUI window: SwiftUI kept bringing the title bar back to its windows.
/// No frame at all, a see-through backdrop with rounded corners, moved by dragging any empty
/// spot, on whichever Space you're in. Esc on its list puts it away (`MainWindow.putAway`).
@MainActor
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private var panel: KeyPanel?
    private var observer: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// Study's session and the page on show, here rather than in the view, so the shortcuts can
    /// set them before the panel comes up.
    fileprivate let holder = SessionHolder()
    fileprivate let state = PanelState()

    private var session: ReviewSession {
        let session = holder.session(for: AppModel.shared)
        if session.onPutAway == nil { session.onPutAway = { MainWindow.putAway() } }
        return session
    }

    func show() {
        let panel = panel ?? makePanel()
        updateLevel(keyWindow: nil)
        PointerGate.reset()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The open-app shortcut: the panel as you left it, but no longer quick (Esc goes back).
    func showStudy() {
        _ = panel ?? makePanel()
        session.endQuick()
        show()
    }

    /// The quick-card shortcut: straight to a card (or "All caught up"). Set up before the panel
    /// comes up and without animation, so home doesn't slide out as it appears.
    func showQuickCard() {
        _ = panel ?? makePanel()
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            state.page = .study
            session.reloadIfIdle(force: true)
            session.startQuick()
        }
        show()
    }

    /// One of the panel's pages (Settings from the menu bar).
    func showPage(_ page: PanelPage) {
        _ = panel ?? makePanel()
        session.endQuick()
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { state.page = page }
        show()
    }

    /// ⌘N: the New Word form over the panel's Words.
    func addWord() {
        showPage(.words)
        state.addingWord = true
    }

    /// The panel is up, on a quick card or "All caught up".
    var showsQuickCard: Bool { isKey && session.quick && state.page == .study }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Until then the panel stays when the app stops being active.
    private var stayUntil = Date.distantPast

    /// Showing or hiding the Dock icon drops the app to the background for a moment, which put
    /// the panel away right as you flipped the switch in it. It stays through that, up front.
    func stayThroughDockSwitch() {
        guard isVisible else { return }
        stayUntil = .now.addingTimeInterval(1.5)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.show()
        }
    }

    var isKey: Bool { panel?.isKeyWindow == true }
    var isVisible: Bool { panel?.isVisible == true }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: FloatingPanel.width, height: FloatingPanel.height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // Hidden, not just left behind, when you click into another app: like Raycast, it goes
        // away (`resignObserver`) and the shortcut brings it back. Not `hidesOnDeactivate`, which
        // brings it back by itself whenever the app is active again.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: FloatingPanelView().environment(AppModel.shared))
        // Where you last left it; the first time, a bit above the middle of the screen.
        if !panel.setFrameUsingName("FloatingPanel"), let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - FloatingPanel.width / 2,
                                         y: area.minY + area.height * 0.62 - FloatingPanel.height / 2))
        }
        panel.setFrameAutosaveName("FloatingPanel")
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.updateLevel(keyWindow: note.object as? NSWindow) }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date.now >= self.stayUntil else { return }
                self.hide()
            }
        }
        self.panel = panel
        return panel
    }

    /// Over other apps, but under the app's own windows (Words, Progress, Settings) while one
    /// of them is in front.
    private func updateLevel(keyWindow: NSWindow?) {
        guard let panel else { return }
        var level: NSWindow.Level = .floating
        if let keyWindow, keyWindow !== panel, keyWindow.canBecomeMain, keyWindow.sheetParent == nil {
            level = .normal
        }
        if panel.level != level { panel.level = level }
    }

    /// A borderless window can't take the keyboard unless it says so.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

/// The floating panel's size and corners: one panel, whatever screen of Study it shows.
enum FloatingPanel {
    static let width: CGFloat = 700
    static let height: CGFloat = 540
    static let corner: CGFloat = 16
}

extension EnvironmentValues {
    /// Study drawn as the floating panel itself: no headline over the list, no panel in a window.
    @Entry var floatingPanel = false
}

/// What the floating panel shows: Study, with a session of its own, or a page one of its
/// commands opened in place (Words, Progress, Settings).
@Observable
fileprivate final class PanelState {
    var page: PanelPage = .study
    /// The New Word form, over Words.
    var addingWord = false
}

private struct FloatingPanelView: View {
    @Environment(AppModel.self) private var model
    private var session: SessionHolder { FloatingPanelController.shared.holder }
    private var state: PanelState { FloatingPanelController.shared.state }
    private var page: PanelPage {
        get { state.page }
        nonmutating set { state.page = newValue }
    }
    /// Settings → Debug: pages come and go like the cards.
    @AppStorage(CardMotion.key) private var motion: CardMotion = .slide
    @AppStorage(CardMotion.speedKey) private var speed: MotionSpeed = .standard

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FloatingPanel.corner, style: .continuous)
        ZStack {
            switch page {
            case .study:
                ReviewView(injected: session.session(for: model))
                    .environment(\.floatingPanel, true)
                    .transition(motion.transition)
            case .words:
                PanelWordsPage(back: back, adding: Binding(get: { state.addingWord }, set: { state.addingWord = $0 }))
                    .transition(motion.transition)
            case .progress:
                PanelProgressPage(back: back).transition(motion.transition)
            case .settings:
                PanelSettingsPage(back: back).transition(motion.transition)
            case .chat:
                PanelChatPage(back: back).transition(motion.transition)
            }
        }
        .animation(speed.animation, value: page)
        .environment(\.openPanelPage) { page = $0 }
        .onChange(of: page) { PointerGate.reset() }
        .frame(width: FloatingPanel.width, height: FloatingPanel.height)
        .background(FloatingBackdrop(corner: FloatingPanel.corner))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }

    private func back() {
        page = .study
        // Not watching the deck while away: catch up.
        session.session(for: model).reloadIfIdle(force: true)
    }
}

/// The floating panel's see-through backdrop. Dragging it, anywhere nothing else takes the
/// click, moves the panel.
struct FloatingBackdrop: NSViewRepresentable {
    let corner: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = DragView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        // The blur comes from the window server, past any SwiftUI clipping: round it here.
        view.maskImage = Self.mask(corner: corner)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private static func mask(corner: CGFloat) -> NSImage {
        let edge = corner * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }

    private final class DragView: NSVisualEffectView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// The window with Words or Progress, opened from the floating panel.
struct SectionWindow: View {
    let tab: ContentView.Tab
    @State private var words = BuiltRows()
    @State private var progress = BuiltDashboard()

    var body: some View {
        Group {
            switch tab {
            case .words: WordsView(built: words)
            case .progress, .review: DashboardView(built: progress)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}
