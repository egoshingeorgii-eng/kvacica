import SwiftUI
import SrbCore

struct ContentView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case review = "Study", words = "Words", progress = "Progress"
        var id: Self { self }

        var title: String {
            switch self {
            case .review: String(localized: "Study")
            case .words: String(localized: "Words")
            case .progress: String(localized: "Progress")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .review
    /// What the tabs keep while another one shows: the study session (a review in progress stays
    /// where it was), the Words rows and the Progress figures. Switching tabs made each again
    /// (Progress 150-180 ms) even when nothing had changed.
    @State private var session = SessionHolder()
    @State private var words = BuiltRows()
    @State private var progress = BuiltDashboard()
    @State private var adding = false
    @State private var chatting = false
    var body: some View {
        sections
            .sheet(isPresented: $adding) {
                NavigationStack { AddWordView() }
            }
            .sheet(isPresented: $chatting) {
                ChatConnectorPage()
                    .frame(width: 480, height: 620)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { chatting = false }
                        }
                    }
            }
            .toolbar {
                sectionPicker
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add Word…", systemImage: "plus") { adding = true }
                        .help("Add a word of your own")
                    Button("Words from Chat…", systemImage: "bubble.left.and.text.bubble.right") { chatting = true }
                        .help("Add words from Claude or ChatGPT")
                }
            }
    }

    private var sections: some View {
        Group {
            switch tab {
            case .review: ReviewView(injected: session.session(for: model))
            case .words: WordsView(built: words)
            case .progress: DashboardView(built: progress)
            }
        }
        .onChange(of: tab) {
            // Not watching the deck while away: catch up.
            if tab == .review { session.session(for: model).reloadIfIdle(force: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One toolbar button per section. On macOS 26 a shared glass background
    /// highlights the whole group, so each tab keeps its own.
    @ToolbarContentBuilder private var sectionPicker: some ToolbarContent {
        if #available(macOS 26, *) {
            tabButtons.sharedBackgroundVisibility(.hidden)
        } else {
            tabButtons
        }
    }

    private var tabButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            ForEach(Tab.allCases) { item in
                Toggle(title(for: item), isOn: Binding(
                    get: { tab == item },
                    set: { if $0 { tab = item } }
                ))
                .toggleStyle(.button)
            }
        }
    }

    private func title(for tab: Tab) -> String {
        _ = model.revision
        switch tab {
        case .review:
            let count = model.dueCount()
            return count > 0 ? String(localized: "Study (\(count))") : tab.title
        case .words, .progress:
            return tab.title
        }
    }
}
