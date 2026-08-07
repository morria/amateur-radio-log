import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Formatters

enum ChatFormatters {
    /// Day separators mark a *UTC* day — hams work in UTC and the server's
    /// stamps carry no date at all, so rendering these in local time would
    /// label them with the wrong date west of Greenwich.
    private static let daySeparatorFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter
    }()

    static func daySeparator(_ date: Date) -> String {
        daySeparatorFormatter.string(from: date)
    }
}

// MARK: - Bubble Palette

private enum ChatPalette {
    static var incoming: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemFill)
        #else
        return Color(nsColor: .quaternarySystemFill)
        #endif
    }

    static let outgoing = Color.accentColor
}

// MARK: - Bubble Row

/// One chat message. Outgoing right and tinted, incoming left and neutral;
/// the sender header only appears on the first message of a run, and a
/// message addressed to you is called out so a sked offer can't scroll past
/// unnoticed.
struct ChatBubbleRow: View {
    let message: ON4KSTMessage
    let showsSender: Bool
    let myCallsign: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isFromMe { Spacer(minLength: 48) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                if showsSender, !senderLabel.isEmpty {
                    Text(senderLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .overlay(directedOutline)

                footer
            }

            if !message.isFromMe { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(message.isFromMe ? ChatPalette.outgoing : ChatPalette.incoming)
    }

    @ViewBuilder
    private var directedOutline: some View {
        if message.isToMe {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange, lineWidth: 2)
        }
    }

    private var senderLabel: String {
        if message.isFromMe { return "" }
        if message.fromName.isEmpty { return message.from }
        return "\(message.from) · \(message.fromName)"
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let to = message.to {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 8))
                Text(message.isToMe ? String(localized: "to you") : to)
                    .font(.caption2.weight(.semibold))
            }
            Text(verbatim: "\(message.hhmm)Z")
                .font(.caption2)
                .monospacedDigit()
            if message.isFromMe, message.isEcho {
                // The server posting our line back to the room is the only
                // delivery confirmation this protocol offers.
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(message.isToMe ? Color.orange : Color.secondary)
        .padding(.horizontal, 6)
    }

    private var accessibilityLabel: Text {
        let who = message.isFromMe
            ? String(localized: "You")
            : (senderLabel.isEmpty ? message.from : senderLabel)
        if message.isToMe {
            return Text("\(who), addressed to you: \(message.text)")
        }
        if let to = message.to {
            return Text("\(who), addressed to \(to): \(message.text)")
        }
        return Text("\(who): \(message.text)")
    }
}

// MARK: - Notice Row

/// Centred, non-bubble rows: server text, DX-cluster spots and the app's own
/// status notes.
struct ChatNoticeRow: View {
    let message: ON4KSTMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(message.text)
                .font(isMonospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .multilineTextAlignment(isMonospaced ? .leading : .center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: isMonospaced ? .leading : .center)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String? {
        switch message.kind {
        case .dxSpot: return "antenna.radiowaves.left.and.right"
        case .announcement: return "megaphone"
        default: return nil
        }
    }

    /// Server text is often column-aligned (/HELP output, spot tables), so it
    /// is set left-aligned and monospaced rather than centred like a status
    /// note.
    private var isMonospaced: Bool {
        message.kind == .dxSpot || message.kind == .system || message.kind == .announcement
    }
}

// MARK: - Stations Heard

/// The roster of stations active in the room.
///
/// ON4KST has no documented user-list query and none is guessed at here: this
/// list is built from traffic actually seen since connecting, so every entry
/// is real. Tapping one addresses your next message to it.
struct ChatOperatorListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    private var session: ON4KSTSession { appState.on4kstSession }

    var body: some View {
        NavigationStack {
            Group {
                if session.operators.isEmpty {
                    ContentUnavailableView(
                        "No Stations Heard Yet",
                        systemImage: "person.2.slash",
                        description: Text("Stations appear here as they post to the room."))
                } else {
                    List(session.operators) { op in
                        Button {
                            onSelect(op.call)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(op.call)
                                        .font(.body.weight(.medium))
                                    if !op.name.isEmpty {
                                        Text(op.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(op.lastHeard, format: .relative(presentation: .numeric))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Stations Heard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(width: 380, height: 460)
            #endif
        }
    }
}

// MARK: - Server Log

/// Raw server text, newest last.
///
/// Roughly half of the ON4KST line grammar is undocumented — join/leave
/// notices, error text and the full "/HELP" command list among it. Rather
/// than pretend otherwise, everything the parser could not classify is kept
/// verbatim and shown here, so an operator can read the server's own answer
/// to any command they send.
struct ChatServerLogView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var session: ON4KSTSession { appState.on4kstSession }

    var body: some View {
        NavigationStack {
            Group {
                if session.serverLog.isEmpty {
                    ContentUnavailableView(
                        "No Server Output",
                        systemImage: "text.alignleft",
                        description: Text("Send /HELP from the room menu to list the server's commands."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(session.serverLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .navigationTitle("Server Log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(width: 520, height: 480)
            #endif
        }
    }
}

// MARK: - Credentials

/// ON4KST sign-in.
///
/// The service has no TLS and the password crosses the network in cleartext —
/// the server even echoes it back during login. That makes a dedicated,
/// not-reused password the only safe choice, and the screen says so instead
/// of burying it. The password is stored in the Keychain, never in a
/// preference file, and is redacted everywhere it could otherwise surface.
struct ChatCredentialsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var callsign = ""
    @State private var password = ""
    @State private var errorMessage: String?

    private var session: ON4KSTSession { appState.on4kstSession }

    private var canSave: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Callsign", text: $callsign)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .textContentType(.username)
                        #endif
                    SecureField("ON4KST Password", text: $password)
                        #if os(iOS)
                        .textContentType(.password)
                        #endif
                } header: {
                    Text("ON4KST Account")
                } footer: {
                    Text("Register free at on4kst.org. The chat service has no encrypted connection, so use a password you don't use anywhere else. It is kept in your Keychain.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sign In")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(width: 420, height: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if !session.didLoadCredentials { session.loadCredentials() }
                callsign = session.callsign
            }
        }
    }

    private func save() {
        do {
            try session.saveCredentials(callsign: callsign, password: password)
            password = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
