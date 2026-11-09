import SwiftUI
import AppKit

/// Words from a chat: a connector link of one's own, made here with one tap, how to add it to
/// Claude or ChatGPT, and a line that turns into "Connected" once the chat has called it.
/// iPhone: Settings → Sync, the Words banner, its + menu and its empty state. Mac: the palette's
/// Words from chat and the main window's toolbar.
struct ChatConnectorPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.cloudConnector) private var connector = ""
    @AppStorage(Pref.chatConnected) private var connected = false
    @State private var creating = false
    @State private var failure: String?
    @State private var copied = false
    @State private var seenAt: Date?
    @State private var draft = ""
    @State private var pasting = false

    var body: some View {
        let link = model.chatConnectorURL
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Rings.accent)
                    Text("Ask Claude or ChatGPT for words and they show up here, with forms and examples.")
                        .font(.body)
                }
                .padding(.vertical, 6)
            }

            if let link {
                Section {
                    statusRow
                }
                Section {
                    step(1, String(localized: "Copy your link")) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            withAnimation(.snappy) { copied = true }
                        } label: {
                            Label(copied ? String(localized: "Copied") : String(localized: "Copy link"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BigOrangeButtonStyle())
                        .contentTransition(.symbolEffect(.replace))
                        .sensoryFeedback(.success, trigger: copied) { _, now in now }
                    }
                    step(2, String(localized: "Add it to your chat")) {
                        Group {
                            Text("Claude: Settings → Connectors → Add custom connector. Name it Kvačica and paste the link as its URL.")
                            Text("ChatGPT: Settings → Apps & Connectors, turn on developer mode, then create a connector named Kvačica with the link.")
                        }
                        .foregroundStyle(.secondary)
                    }
                    step(3, String(localized: "Ask for words")) {
                        Text("“Add the words from this text to Kvačica”, or “Give me 20 words for the doctor's”.")
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Anyone with the link can add words to your deck, so keep it to yourself.")
                }
            } else {
                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            if creating { ProgressView().tint(.white).padding(.trailing, 4) }
                            Text("Create my link")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BigOrangeButtonStyle())
                    .disabled(creating)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }

            Section {
                DisclosureGroup("Use a link you already have", isExpanded: $pasting) {
                    TextField("Connector URL", text: $draft)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    if draft != connector {
                        Button("Save", action: save)
                            .disabled(!draft.isEmpty && !CloudSync.isValidConnector(draft))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Words from chat")
        .onAppear { draft = connector }
        // While the page is up: turns into "Connected" a few seconds after the chat first calls.
        .task(id: link) {
            guard link != nil else { return }
            while !Task.isCancelled {
                if let seen = await model.checkChatConnected() {
                    withAnimation(.smooth) { seenAt = seen }
                }
                try? await Task.sleep(for: .seconds(seenAt == nil ? 4 : 60))
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let seenAt {
            Label {
                Text("Connected · last used \(seenAt.formatted(.relative(presentation: .named)))")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                Text(connected ? "Connected" : "Waiting for your chat…")
            } icon: {
                if connected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Rings.accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private func create() async {
        creating = true
        failure = nil
        do {
            try await model.createChatConnector()
            draft = connector
        } catch {
            failure = String(localized: "Couldn't make a link: \(error.localizedDescription)")
        }
        creating = false
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || CloudSync.isValidConnector(text) else { return }
        connector = text
        draft = text
        model.reconnectCloud()
        model.didChange()
    }
}

/// The big orange button of the onboarding pages (PillButton): 56 high, full width, white on orange.
struct BigOrangeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Rings.accent, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
