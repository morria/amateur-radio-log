import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Chat Room

/// The chat transcript for one ON4KST room, in the shape an iPhone owner
/// already knows: bubbles right for you and left for everyone else, a run of
/// messages from one station sharing a single name header, day separators,
/// and a composer pinned above the keyboard.
///
/// Server text that isn't chat — the welcome banner, "/HELP" output, inline
/// DX-cluster spots, anything the (undocumented) grammar doesn't cover — is
/// shown as a centred notice rather than hidden, because on this service that
/// text is often the useful part.
struct ChatRoomView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    let room: ON4KSTRoom

    @State private var draft = ""
    /// Station this message will be addressed to (sent as "/CQ CALL text").
    @State private var directedTo: String?
    @State private var showingOperators = false
    @State private var showingServerLog = false
    @State private var logPrefill: QSOEditData?
    @FocusState private var composerFocused: Bool

    private var session: ON4KSTSession { appState.on4kstSession }

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .safeAreaInset(edge: .top, spacing: 0) { connectionBanner }
            .navigationTitle(session.serverRoomName ?? room.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingOperators) {
                ChatOperatorListView { call in
                    directedTo = call
                    composerFocused = true
                }
            }
            .sheet(isPresented: $showingServerLog) {
                ChatServerLogView()
            }
            .sheet(item: $logPrefill) { prefill in
                LogEntryView(prefill: prefill, presentedAsSheet: true)
            }
            .onAppear {
                if !session.didLoadCredentials { session.loadCredentials() }
                session.isViewingRoom = true
                session.connect(to: room)
            }
            .onDisappear {
                // The session stays up so directed messages keep arriving;
                // only the unread suppression stops.
                session.isViewingRoom = false
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: session.suspend()
                case .active: session.resume()
                default: break
                }
            }
            .onChange(of: session.messages.last?.id) { _, _ in
                announceIfDirectedToMe()
            }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: session.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id.uuidString, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row.content {
        case .daySeparator(let date):
            // Formatted in UTC: the separator marks a UTC day, and rendering
            // it in local time would label it with the wrong date west of
            // Greenwich.
            Text(ChatFormatters.daySeparator(date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

        case .message(let message, let showsSender):
            if message.isBubble {
                ChatBubbleRow(message: message, showsSender: showsSender,
                              myCallsign: session.callsign)
                    .contextMenu { bubbleActions(for: message) }
            } else {
                ChatNoticeRow(message: message)
                    .contextMenu {
                        Button {
                            copy(message.raw)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func bubbleActions(for message: ON4KSTMessage) -> some View {
        if !message.isFromMe, !message.from.isEmpty {
            Button {
                directedTo = message.from
                composerFocused = true
            } label: {
                Label("Reply to \(message.from)", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                var data = QSOEditData()
                data.call = message.from
                if !message.fromName.isEmpty { data.name = message.fromName }
                logPrefill = data
            } label: {
                Label("Log QSO with \(message.from)", systemImage: "square.and.pencil")
            }
        }
        Button {
            copy(message.text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Connection banner

    /// Messages-style inline notice: only present when something is wrong or
    /// in progress, never as permanent chrome.
    @ViewBuilder
    private var connectionBanner: some View {
        if session.status != .connected {
            HStack(spacing: 8) {
                if session.status.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(session.status.tint)
                }
                Text(session.status.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if case .failed = session.status {
                    Button("Retry") { session.retry() }
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if let directedTo {
                directedChip(directedTo)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(composerPrompt, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                    #endif
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func directedChip(_ call: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.caption2)
            Text("To \(call)")
                .font(.caption.weight(.semibold))
            Button {
                directedTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Clear recipient")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .foregroundStyle(Color.accentColor)
    }

    private var composerPrompt: String {
        if draft.hasPrefix("/") { return String(localized: "Server command") }
        if let directedTo { return String(localized: "Message \(directedTo)") }
        return String(localized: "Message")
    }

    private var canSend: Bool {
        session.status == .connected
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        session.send(draft, to: directedTo)
        draft = ""
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showingOperators = true
                } label: {
                    Label("Stations Heard (\(session.operators.count))",
                          systemImage: "person.2")
                }
                Button {
                    showingServerLog = true
                } label: {
                    Label("Server Log", systemImage: "text.alignleft")
                }
                Divider()
                Button {
                    session.sendCommand("/HELP")
                } label: {
                    Label("Send /HELP", systemImage: "questionmark.circle")
                }
                .disabled(session.status != .connected)
                Divider()
                if session.status == .connected || session.status.isBusy {
                    Button(role: .destructive) {
                        session.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "bolt.horizontal.circle")
                    }
                } else {
                    Button {
                        session.connect(to: room)
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.circle")
                    }
                }
            } label: {
                Label("Room Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Helpers

    /// Directed messages are the whole point of the service — a sked offer
    /// aimed at you shouldn't scroll past unnoticed.
    private func announceIfDirectedToMe() {
        guard let last = session.messages.last, last.isToMe, !last.isFromMe else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - Row model

    private struct ChatRow: Identifiable {
        enum Content {
            case daySeparator(Date)
            case message(ON4KSTMessage, showsSender: Bool)
        }
        let id: String
        let content: Content
    }

    /// Adds day separators and works out which bubbles need a sender header:
    /// only the first of a consecutive run from the same station, the way
    /// Messages groups a burst of texts.
    private var rows: [ChatRow] {
        var result: [ChatRow] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var lastDay: Date?
        var lastBubbleSender: String?

        for message in session.messages {
            let day = calendar.startOfDay(for: message.timestamp)
            if lastDay != day {
                lastDay = day
                lastBubbleSender = nil
                result.append(ChatRow(id: "day-\(day.timeIntervalSince1970)",
                                      content: .daySeparator(day)))
            }
            if message.isBubble {
                let sender = message.isFromMe ? "" : message.from
                // A directed message always shows its header, so "to CALL"
                // can't be mistaken for the previous message's recipient.
                let showsSender = sender != lastBubbleSender || message.to != nil
                lastBubbleSender = message.to != nil ? nil : sender
                result.append(ChatRow(id: message.id.uuidString,
                                      content: .message(message, showsSender: showsSender)))
            } else {
                lastBubbleSender = nil
                result.append(ChatRow(id: message.id.uuidString,
                                      content: .message(message, showsSender: false)))
            }
        }
        return result
    }
}
