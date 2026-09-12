import AppKit
import CodexPetCore
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CompanionModel: NSObject, ObservableObject, NSSpeechSynthesizerDelegate {
    enum Tab: String, CaseIterable { case chat = "Chat", activity = "Activity", pet = "Pet" }
    typealias Runner = @Sendable (String, @escaping CompanionChatService.Receiver) async throws -> Void

    @Published var tab: Tab = .chat
    @Published var draft = ""
    @Published private(set) var messages: [CompanionMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Ready when you are"
    @Published var error: String?
    @Published var compact = false
    @Published var speakReplies = false
    @Published var speaking = false
    @Published var attachments: [CompanionAttachment] = []
    @Published var activity: [SessionActivityItem] = []
    @Published var completed: [SessionActivityItem] = []
    @Published var titles: [String: String] = [:]
    @Published var openableIDs: Set<String> = []
    @Published var characters: [CharacterLibraryEntry] = []
    @Published var selectedCharacter = ""
    @Published var petSize: Double = 320
    @Published var petVoiceEnabled = true
    @Published var petVisible = true
    @Published var activeFilter = "All"

    var onOpenTask: ((String) -> Void)?
    var onAcknowledge: ((String) -> Void)?
    var onClearCompleted: (() -> Void)?
    var onSelectCharacter: ((String) -> Void)?
    var onResizePet: ((Double) -> Void)?
    var onTogglePet: ((Bool) -> Void)?
    var onTogglePetVoice: ((Bool) -> Void)?
    var onSettings: ((String) -> Void)?
    var onCreateCharacter: ((String) -> Void)?
    var onImportCharacter: (() -> Void)?
    var onCompactChange: (() -> Void)?
    var onClose: (() -> Void)?

    private let runner: Runner
    private let speech = NSSpeechSynthesizer()
    let dictation = CompanionDictation()
    private var dictationPrefix = ""
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var replyIDs: [String: UUID] = [:]
    private var retryMessages: [CompanionMessage]?
    private(set) var sentMessages: [CompanionMessage] = []

    init(runner: @escaping Runner = { prompt, receive in
        try await CompanionChatService().run(prompt: prompt, receive: receive)
    }) {
        self.runner = runner
        super.init()
        speech.delegate = self
        dictation.onText = { [weak self] text in
            guard let self else { return }
            self.draft = self.dictationPrefix + text
        }
        dictation.onError = { [weak self] message in self?.error = message }
    }

    var canSend: Bool { !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var attentionCount: Int { activity.filter { $0.state == .waiting }.count }
    var characterName: String { characters.first { $0.id == selectedCharacter }?.name ?? "Your companion" }

    func send() {
        guard canSend else { return }
        dictation.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = attachments.map { "\n\nAttached text (\($0.name)):\n\($0.text)" }.joined()
        let proposed = sentMessages + [CompanionMessage(role: .user, text: text + context)]
        do {
            let prompt = try CompanionChatPolicy.prompt(messages: proposed)
            messages.append(CompanionMessage(role: .user, text: text + (attachments.isEmpty ? "" : "\n\n📎 " + attachments.map(\.name).joined(separator: ", "))))
            sentMessages = proposed
            retryMessages = proposed
            draft = ""; attachments = []
            start(prompt)
        } catch { self.error = (error as? CompanionChatError)?.localizedDescription ?? CompanionChatError.failed.localizedDescription }
    }

    func retry() {
        guard !isRunning, let retryMessages else { return }
        do { start(try CompanionChatPolicy.prompt(messages: retryMessages)) }
        catch { self.error = CompanionChatError.tooLarge.localizedDescription }
    }

    private func start(_ prompt: String) {
        stopSpeech()
        let token = UUID()
        generation = token
        isRunning = true; status = "Connecting to Codex…"; error = nil
        // Replace partial output when retrying the same turn.
        let partialIDs = Set(replyIDs.values)
        messages.removeAll { partialIDs.contains($0.id) }
        replyIDs = [:]
        let runner = self.runner
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await runner(prompt) { event in
                    // The service emits serial events. Dispatch to the main queue
                    // preserves their order without an unbounded per-token Task.
                    DispatchQueue.main.async { [weak self] in self?.receive(event, token: token) }
                }
                DispatchQueue.main.async { [weak self] in self?.finish(token: token, failure: nil) }
            } catch {
                let failure = error is CancellationError ? "Reply stopped" :
                    ((error as? CompanionChatError)?.localizedDescription ?? CompanionChatError.failed.localizedDescription)
                DispatchQueue.main.async { [weak self] in self?.finish(token: token, failure: failure) }
            }
        }
    }

    private func receive(_ event: CompanionChatEvent, token: UUID) {
        guard generation == token else { return }
        switch event {
        case let .reply(id, text):
            status = "Replying…"
            if let messageID = replyIDs[id], let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].text = text
            } else {
                let message = CompanionMessage(role: .assistant, text: text)
                replyIDs[id] = message.id; messages.append(message)
            }
        case .status(let value): status = value
        case .completed: break
        }
    }

    private func finish(token: UUID, failure: String?) {
        guard generation == token else { return }
        generation = nil; task = nil; isRunning = false
        if let failure {
            error = failure; status = "Try again when you’re ready"
        } else {
            let reply = messages.filter { replyIDs.values.contains($0.id) }.map(\.text).joined(separator: "\n\n")
            guard !reply.isEmpty else { error = CompanionChatError.emptyReply.localizedDescription; return }
            sentMessages.append(CompanionMessage(role: .assistant, text: reply))
            retryMessages = nil; replyIDs = [:]; status = "Ready when you are"
            if speakReplies { readReply(reply) }
        }
    }

    func stop() {
        generation = nil; task?.cancel(); task = nil; isRunning = false
        status = "Reply stopped"; error = retryMessages == nil ? nil : "Reply stopped. You can retry when ready."; stopSpeech()
    }

    func newChat() {
        dictation.stop()
        stop(); messages = []; sentMessages = []; retryMessages = nil; replyIDs = [:]
        attachments = []; draft = ""; error = nil; status = "Ready when you are"
    }

    func readReply(_ text: String) {
        dictation.stop()
        stopSpeech()
        speaking = speech.startSpeaking(String(text.prefix(12_000)))
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        speaking = false
    }

    func stopSpeech() { speech.stopSpeaking(); speaking = false }
    func toggleCompact() { dictation.stop(); compact.toggle(); onCompactChange?() }
    func toggleDictation() {
        if dictation.isListening || dictation.isStarting { dictation.stop() }
        else {
            stopSpeech()
            dictationPrefix = draft.isEmpty ? "" : draft + " "
            dictation.start()
        }
    }

    func shutdown() { dictation.stop(); stop(); speech.stopSpeaking() }
    var canRetry: Bool { retryMessages != nil && !isRunning }
}

struct CompanionAttachment: Identifiable {
    let id = UUID()
    let name: String
    let text: String

    static func read(_ url: URL) throws -> CompanionAttachment {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CompanionChatError.tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= CompanionChatPolicy.maximumAttachmentBytes else {
            throw CompanionChatError.tooLarge
        }
        let data = try handle.read(upToCount: CompanionChatPolicy.maximumAttachmentBytes + 1) ?? Data()
        guard data.count <= CompanionChatPolicy.maximumAttachmentBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw CompanionChatError.tooLarge
        }
        return CompanionAttachment(name: url.lastPathComponent, text: text)
    }
}

final class CompanionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompanionPanelController: NSWindowController, NSWindowDelegate {
    let model = CompanionModel()
    private let activator = CodexDesktopActivator()
    private var activityGeneration = UUID()
    private var openabilityTask: Task<Void, Never>?
    private var targets: [String: String] = [:]

    init() {
        let panel = CompanionWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        panel.title = "Statelet Companion"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.minSize = NSSize(width: 400, height: 440)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CompanionView(model: model))
        model.onCompactChange = { [weak self] in self?.resizeForMode() }
        model.onClose = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { nil }

    func show(beside petFrame: NSRect) {
        guard let window else { return }
        if !window.isVisible {
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(petFrame) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? petFrame
            var frame = window.frame
            frame.origin = NSPoint(x: petFrame.maxX + 12, y: petFrame.midY - frame.height / 2)
            if frame.maxX > visible.maxX { frame.origin.x = petFrame.minX - frame.width - 12 }
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
            window.setFrame(frame, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        resolveOpenability()
    }

    private func resizeForMode() {
        guard let window else { return }
        var frame = window.frame
        let size = NSSize(width: 440, height: model.compact ? 116 : 640)
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.minSize = model.compact ? size : NSSize(width: 400, height: 440)
        if let visible = window.screen?.visibleFrame {
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }

    func updateActivity(snapshot: SessionActivitySnapshot?, acknowledged: Set<String>,
                        titles: [String: String], targets: [String: String]) {
        model.activity = snapshot?.active ?? []
        model.completed = SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: snapshot, acknowledgedIDs: acknowledged)
        model.titles = titles
        guard self.targets != targets else { return }
        self.targets = targets
        resolveOpenability()
    }

    private func resolveOpenability() {
        let targets = self.targets
        model.openableIDs = []
        openabilityTask?.cancel()
        let token = UUID(); activityGeneration = token
        openabilityTask = Task { [weak self] in
            guard let self else { return }
            let openable = await activator.openableIDs(for: targets)
            guard !Task.isCancelled, activityGeneration == token else { return }
            model.openableIDs = openable
        }
    }

    func windowWillClose(_ notification: Notification) { model.dictation.stop(); model.stopSpeech() }
    func shutdown() { openabilityTask?.cancel(); model.shutdown(); window?.close() }
}

private struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @State private var newPetName = ""
    @FocusState private var composerFocused: Bool
    private let accent = Color(red: 0.17, green: 0.49, blue: 0.44)

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.compact {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(accent)
                    TextField("Ask something…", text: $model.draft)
                        .textFieldStyle(.plain).onSubmit { model.compact = false; model.tab = .chat; model.onCompactChange?(); model.send() }
                        .accessibilityLabel("Quick chat message")
                    Button { model.toggleCompact() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Expand companion").accessibilityLabel("Expand companion")
                }.padding(14)
            } else {
                Picker("Companion section", selection: $model.tab) {
                    ForEach(CompanionModel.Tab.allCases, id: \.self) { tab in
                        Text(tab == .activity && model.attentionCount > 0 ? "Activity · \(model.attentionCount)" : tab.rawValue).tag(tab)
                    }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
                Divider()
                switch model.tab {
                case .chat: chat
                case .activity: activity
                case .pet: pet
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onChange(of: model.speakReplies) { enabled in if !enabled { model.stopSpeech() } }
        .onChange(of: model.tab) { _ in model.dictation.stop() }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.12))
                Image(systemName: "pawprint.fill").font(.system(size: 18)).foregroundStyle(accent)
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Statelet").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(model.isRunning ? model.status : model.characterName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isRunning { ProgressView().controlSize(.small).accessibilityLabel(model.status) }
            Button { model.toggleCompact() } label: {
                Image(systemName: model.compact ? "arrow.up.left.and.arrow.down.right" : "rectangle.compress.vertical")
            }.help(model.compact ? "Expand companion" : "Mini bar").accessibilityLabel(model.compact ? "Expand companion" : "Mini bar")
            Button { model.onSettings?("general") } label: { Image(systemName: "gearshape") }
                .help("Settings").accessibilityLabel("Settings")
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.top, 30).padding(.bottom, model.compact ? 0 : 18)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Codex · your sign-in", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("New chat", systemImage: "square.and.pencil") { model.newChat() }.labelStyle(.iconOnly)
                    .help("New chat clears this conversation from Statelet")
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty { welcome }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == .user ? "YOU" : "STATELET")
                                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                                Text(message.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if message.role == .assistant, !model.isRunning {
                                    Button { model.readReply(message.text) } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                                        .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .background(message.role == .user ? accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            .id(message.id)
                        }
                        if model.isRunning { Label(model.status, systemImage: "ellipsis").font(.system(size: 12)).foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                }.onChange(of: model.messages) { _ in reader.scrollTo("bottom", anchor: .bottom) }
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    if model.canRetry { Button("Retry reply") { model.retry() }.buttonStyle(.borderless) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            composer
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkle").font(.system(size: 30, weight: .light)).foregroundStyle(accent)
            Text("A little space\nto think together.").font(.system(size: 27, weight: .medium, design: .rounded)).lineSpacing(3)
            Text("Ask a question, shape an idea, or bring a little context. Your tasks and pet are one tab away.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                suggestion("Plan my next step", prompt: "Help me plan my next step. Ask me what I’m working on.")
                suggestion("Talk through an idea", prompt: "Help me think through an idea. Ask me a good starting question.")
            }
            Text("Text-only chat using your Codex sign-in. Messages use your Codex connection when you send. Statelet keeps this conversation in memory until New chat or quit.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(.vertical, 20)
    }

    private func suggestion(_ title: String, prompt: String) -> some View {
        Button(title) { model.draft = prompt; composerFocused = true }
            .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.attachments.isEmpty {
                ForEach(model.attachments) { attachment in
                    HStack {
                        Label(attachment.name, systemImage: "doc.text").lineLimit(1)
                        Spacer()
                        Button { model.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Remove \(attachment.name)")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless)
                }
            }
            TextField("Message Statelet…", text: $model.draft, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.plain).font(.system(size: 13)).focused($composerFocused)
                .accessibilityLabel("Message Statelet")
            HStack(spacing: 14) {
                Button { attachText() } label: { Image(systemName: "paperclip") }
                    .disabled(model.attachments.count >= 2 || model.isRunning).help("Attach UTF-8 text (up to 16 KB each)").accessibilityLabel("Attach text")
                CompanionDictationButton(dictation: model.dictation, action: model.toggleDictation)
                    .disabled(model.isRunning)
                Toggle(isOn: $model.speakReplies) { Image(systemName: model.speakReplies ? "speaker.wave.2" : "speaker.slash") }
                    .toggleStyle(.button).help("Read replies aloud using the macOS voice").accessibilityLabel("Read replies aloud")
                if model.speaking {
                    Button("Stop audio") { model.stopSpeech() }.font(.system(size: 11))
                } else {
                    Text("⌘ Return to send").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.isRunning {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop reply").help("Stop this reply")
                } else {
                    Button { model.send() } label: { Image(systemName: "arrow.up") }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!model.canSend)
                        .accessibilityLabel("Send message").help("Send message")
                }
            }.buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.24), lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8)
    }

    private func attachText() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .json, .sourceCode]
        panel.allowsMultipleSelection = false
        panel.message = "Attach text to your next message. It is sent only when you choose Send."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { model.attachments.append(try CompanionAttachment.read(url)) }
            catch { model.error = "Could not attach \(url.lastPathComponent). Choose a regular UTF-8 text file no larger than 16 KB." }
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    metric("Active", count: model.activity.count, color: accent)
                    metric("Needs you", count: model.attentionCount, color: .orange)
                    metric("Completed", count: model.completed.count, color: .secondary)
                }
                Picker("Filter activity", selection: $model.activeFilter) {
                    Text("All").tag("All"); Text("Needs you").tag("Needs you"); Text("Completed").tag("Completed")
                }.pickerStyle(.segmented).labelsHidden()
                let items = model.activeFilter == "Completed" ? [] : model.activity.filter { model.activeFilter != "Needs you" || $0.state == .waiting }
                if !items.isEmpty {
                    Text("IN PROGRESS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(items, id: \.id) { item in taskRow(item, completed: false) }
                }
                if model.activeFilter != "Needs you", !model.completed.isEmpty {
                    HStack {
                        Text("FINISHED").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Spacer(); Button("Clear unread") { model.onClearCompleted?() }.font(.system(size: 11)).buttonStyle(.borderless)
                    }
                    ForEach(model.completed, id: \.id) { item in taskRow(item, completed: true) }
                }
                if items.isEmpty && (model.activeFilter == "Needs you" || model.completed.isEmpty) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(accent)
                        Text(model.activeFilter == "Needs you" ? "Nothing needs your attention" : "A quiet moment").font(.headline)
                        Text("Codex and Grok activity appears here when Statelet receives their lifecycle events.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                }
                Text("Open a task in its agent app to reply, review permissions, or stop its work.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private func metric(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(count)").font(.system(size: 25, weight: .medium, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func taskRow(_ item: SessionActivityItem, completed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : item.state == .waiting ? "hand.raised.fill" : "circle.dotted")
                .foregroundStyle(item.state == .waiting && !completed ? Color.orange : accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.titles[item.id] ?? "\(item.provider.displayName) · \(item.category.displayName)").font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(completed ? "Completed" : item.state == .waiting ? "Needs your input" : item.state.rawValue.capitalized)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.openableIDs.contains(item.id) {
                    Text("Open in \(item.provider.displayName) manually").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.openableIDs.contains(item.id) {
                Button("Open") { model.onOpenTask?(item.id) }.controlSize(.small)
            }
            if completed {
                Button { model.onAcknowledge?(item.id) } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("Mark as read").accessibilityLabel("Mark task as read")
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make yourself at home.").font(.system(size: 23, weight: .medium, design: .rounded))
                    Text("Your character, your space, your pace.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("MY CHARACTERS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(model.characters, id: \.id) { character in
                        Button { model.onSelectCharacter?(character.id) } label: {
                            HStack {
                                Image(systemName: "pawprint").foregroundStyle(accent)
                                Text(character.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if character.id == model.selectedCharacter { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                            }.padding(14).background(character.id == model.selectedCharacter ? accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("Select \(character.name)")
                    }
                    HStack {
                        TextField("New character name", text: $newPetName).textFieldStyle(.roundedBorder)
                        Button("Create") {
                            model.onCreateCharacter?(newPetName.trimmingCharacters(in: .whitespacesAndNewlines)); newPetName = ""
                        }.disabled(newPetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                        Button("Import character…") { model.onImportCharacter?() }
                        Spacer()
                        Button("Edit animations") { model.onSettings?("animations") }
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Show desktop pet", isOn: Binding(get: { model.petVisible }, set: { model.onTogglePet?($0) }))
                    VStack(alignment: .leading) {
                        HStack { Text("Pet size"); Spacer(); Text("\(Int(model.petSize)) pt").foregroundStyle(.secondary) }
                        Slider(value: $model.petSize, in: 160...640, step: 10, onEditingChanged: { editing in
                            if !editing { model.onResizePet?(model.petSize) }
                        }).accessibilityLabel("Pet size")
                    }
                    Toggle("Play pet dialogue", isOn: Binding(get: { model.petVoiceEnabled }, set: { model.onTogglePetVoice?($0) }))
                    Button("Voice & dialogue settings…") { model.onSettings?("voice") }.buttonStyle(.borderless)
                }.font(.system(size: 12)).padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                Text("Create an empty character profile, then add your own animations. Imported character bundles use Statelet’s existing verification.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(20)
        }
    }
}

private struct CompanionDictationButton: View {
    @ObservedObject var dictation: CompanionDictation
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: dictation.isListening ? "mic.fill" : dictation.isStarting ? "hourglass" : "mic")
                .foregroundStyle(dictation.isListening ? Color.red : Color.primary)
        }
        .help(dictation.isListening ? "Stop dictation and review your message" : "Dictate on this Mac; review before sending")
        .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate message")
    }
}
