import SwiftUI

// MARK: - Status presentation

extension ON4KSTSession.Status {
    var label: String {
        switch self {
        case .signedOut: return String(localized: "Not signed in")
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .signingIn: return String(localized: "Signing in…")
        case .connected: return String(localized: "Connected")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .failed(let message): return message
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting, .signingIn, .reconnecting: return .orange
        case .failed: return .red
        case .idle, .signedOut: return .secondary
        }
    }
}

// MARK: - Room List

/// Entry point for the chat feature: the ON4KST room list.
///
/// ON4KST is where VHF/UHF/microwave and low-band operators arrange skeds —
/// bands where a random contact is unlikely enough that you agree the time
/// and frequency first. Rooms are exclusive: one per connection, so opening
/// a different room signs in again.
struct ChatRoomListView: View {
    @Environment(AppState.self) private var appState
    @State private var showingCredentials = false

    private var session: ON4KSTSession { appState.on4kstSession }

    var body: some View {
        #if os(macOS)
        NavigationStack {
            roomList
                .navigationDestination(for: ON4KSTRoom.self) { ChatRoomView(room: $0) }
        }
        #else
        roomList
        #endif
    }

    private var roomList: some View {
        List {
            if session.hasCredentials {
                if session.activeRoom != nil { statusSection }
                roomsSection
                accountSection
            } else {
                signInSection
            }
            aboutSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("ON4KST Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingCredentials) {
            ChatCredentialsView()
        }
        .onAppear {
            if !session.didLoadCredentials { session.loadCredentials() }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.status.tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.serverRoomName ?? session.activeRoom?.name ?? "")
                        .font(.body)
                    Text(session.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .failed = session.status {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Session")
        }
    }

    private var roomsSection: some View {
        Section {
            ForEach(session.rooms) { room in
                NavigationLink(value: room) {
                    roomRow(room)
                }
            }
        } header: {
            Text("Rooms")
        } footer: {
            Text("You can be in one room at a time. Opening another room signs in again.")
        }
    }

    private func roomRow(_ room: ON4KSTRoom) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(session.isConnected(to: room) ? Color.green : Color.accentColor)
                .font(.body)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                if let coverage = room.coverage {
                    Text(coverage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if session.activeRoom == room, session.unreadCount > 0 {
                unreadBadge
            } else if session.isConnected(to: room) {
                Text("Connected")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var unreadBadge: some View {
        Text("\(session.unreadCount)")
            .font(.caption2.bold())
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(session.unreadDirected > 0 ? Color.orange : Color.secondary,
                        in: Capsule())
            .accessibilityLabel(session.unreadDirected > 0
                                ? Text("\(session.unreadCount) new, \(session.unreadDirected) addressed to you")
                                : Text("\(session.unreadCount) new"))
    }

    private var accountSection: some View {
        Section {
            LabeledContent("Signed in as", value: session.callsign)
            Button("Change Sign-In…") { showingCredentials = true }
            if session.activeRoom != nil {
                Button("Disconnect") { session.disconnect() }
            }
            Button("Sign Out", role: .destructive) { session.signOut() }
        } header: {
            Text("Account")
        }
    }

    private var signInSection: some View {
        Section {
            Button {
                showingCredentials = true
            } label: {
                Label("Sign In to ON4KST", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Sign In")
        } footer: {
            Text("Use your ON4KST callsign and password. Register free at on4kst.org — the app cannot create an account for you.")
        }
    }

    private var aboutSection: some View {
        Section {
            Text("ON4KST chat is used to arrange skeds on VHF, UHF, microwave and the low HF bands, where random contacts are unlikely.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "http://www.on4kst.org/chat/start.php")!) {
                Label("Open on4kst.org", systemImage: "safari")
            }
            .font(.caption)
        } footer: {
            Text("The chat connection stays up while the app is open. iOS suspends background apps, so the session closes when you leave and reconnects when you come back.")
        }
    }
}
