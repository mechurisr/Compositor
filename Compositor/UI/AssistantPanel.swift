import SwiftUI

/// A minimal chat window for `AssistantSession`, shown in a `FloatingPanelController` the same
/// way Levels, Hue/Saturation, and the Keyboard Shortcuts sheet are. Stage 1's assistant can
/// only read the document, so there's nothing here to approve or undo yet — CLAUDE.md 2.8's
/// approval flow arrives once a mutating command family does.
struct AssistantPanel: View {
    @Bindable var assistant: AssistantSession
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            availabilityBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(assistant.messages) { message in
                            AssistantMessageRow(message: message)
                        }
                        if assistant.isResponding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("생각 중…").foregroundStyle(.secondary)
                            }.id("responding")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    if let last = assistant.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: assistant.isResponding) { _, responding in
                    if responding { proxy.scrollTo("responding", anchor: .bottom) }
                }
            }
            .frame(height: 320)
            HStack(spacing: 8) {
                TextField("문서에 대해 물어보세요…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit(send)
                Button("보내기", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isResponding)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var availabilityBanner: some View {
        if case .unavailable(let reason) = assistant.availability {
            HStack(alignment: .top, spacing: 8) {
                Text(reason).font(.callout).foregroundStyle(.orange)
                Spacer()
                Button("다시 확인") { assistant.refreshAvailability() }.font(.callout)
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await assistant.submit(text) }
    }
}

private struct AssistantMessageRow: View {
    let message: AssistantMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.role == .user ? "나" : "어시스턴트")
                .font(.caption).foregroundStyle(.secondary)
            Text(message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(message.id)
    }
}
