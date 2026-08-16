#if os(iOS)
import SwiftUI

/// The log, on iPhone and iPad: a globe with the filters and contact list
/// alongside it.
///
/// This replaces the old split between a Log tab (a list) and a Map tab (a
/// map). They showed the same filtered contacts through two lenses, with two
/// filter surfaces to keep in step. Here the globe *is* the log, and the
/// panel carries the filters and the list, so one filter state visibly drives
/// both.
///
/// Presentation differs by width, because a sheet does not mean the same
/// thing on both:
///
/// - **Compact (iPhone):** a Maps-style bottom sheet. Collapsed it shows the
///   search field and filter chips; dragged up it becomes the full list.
///   Background interaction stays enabled through the medium detent so the
///   globe can still be spun.
/// - **Regular (iPad):** an `.inspector` — the platform's own trailing panel,
///   as in Freeform and Numbers.
///
///   Two earlier attempts were wrong in the same way. A fixed column squeezed
///   the globe between a sidebar that *overlays* and a panel that does not,
///   leaving it neither whole nor wide; a floating card kept the globe entire
///   but sat on top of it permanently. Both failed because the list could not
///   be *put away*, and on a log screen the balance between map and list
///   changes minute to minute. An inspector is resizable, remembers its
///   width, and comes with a toolbar control for dismissing it — so the globe
///   can be whole whenever it needs to be.
///
///   A three-column split view (Mail, Notes) is arguably the more canonical
///   iPad shape for list-plus-detail, but the middle column belongs to the
///   whole `NavigationSplitView` — Spots and Statistics would each have to
///   grow one they have no use for.
struct LogGlobeView: View {
    let allQSOs: [QSO]
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var detent: PresentationDetent = LogSheetDetents.collapsed
    /// Real state, not a computed binding.
    ///
    /// Presenting through `Binding(get:set:)` whose setter discards writes is
    /// an infinite-loop trap: SwiftUI writes `false` to dismiss, the getter
    /// keeps answering `true`, and it re-presents forever — a white screen
    /// with the CPU pinned.
    @State private var sheetPresented = false
    /// Whether the Log screen is actually on screen.
    ///
    /// In compact width the split view shows the sidebar *or* the detail, and
    /// `selectedTab` stays `.log` after backing out to the sidebar — so
    /// gating the sheet on the tab alone left it presented over the menu.
    @State private var isOnScreen = false
    /// iPad only. Open by default — the list is why this screen exists — but
    /// dismissable, which is the whole point of moving to an inspector.
    @AppStorage("logInspectorPresented") private var inspectorPresented = true

    private var isCompact: Bool { horizontalSizeClass == .compact }
    /// The view stays mounted (at zero opacity) while other tabs are on
    /// screen, but a sheet does not hide with its presenter — it would keep
    /// covering the window from behind whichever tab was selected.
    private var wantsSheet: Bool {
        isCompact && isOnScreen && appState.selectedTab == .log
    }

    var body: some View {
        Group {
            if isCompact {
                ContactMapView(qsos: allQSOs, chromeless: true)
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $sheetPresented) {
            LogSheetView(allQSOs: allQSOs,
                         selectedQSO: $selectedQSO,
                         onEdit: onEdit,
                         onDelete: onDelete)
                .presentationDetents(LogSheetDetents.all, selection: $detent)
                .presentationBackgroundInteraction(
                    .enabled(upThrough: LogSheetDetents.medium))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .interactiveDismissDisabled()
        }
        .onAppear {
            isOnScreen = true
            syncSheet()
        }
        .onDisappear {
            isOnScreen = false
            syncSheet()
        }
        .onChange(of: appState.selectedTab) { _, _ in syncSheet() }
        .onChange(of: horizontalSizeClass) { _, _ in syncSheet() }
        // "Show on Map" from a QSO detail centres the globe on a station; the
        // sheet has to drop out of the way or the thing it centred is behind it.
        .onChange(of: appState.mapHighlightQSOId) { _, id in
            guard id != nil else { return }
            detent = LogSheetDetents.collapsed
        }
    }

    private func syncSheet() {
        let wanted = wantsSheet
        if sheetPresented != wanted { sheetPresented = wanted }
    }

    /// iPad: the globe is the screen; the log is an inspector beside it.
    private var regularLayout: some View {
        ContactMapView(qsos: allQSOs, chromeless: true)
            .inspector(isPresented: $inspectorPresented) {
                LogSheetView(allQSOs: allQSOs,
                             selectedQSO: $selectedQSO,
                             onEdit: onEdit,
                             onDelete: onDelete)
                    .inspectorColumnWidth(min: 320, ideal: Self.panelWidth, max: 560)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                inspectorPresented.toggle()
                            } label: {
                                Label("Hide Log", systemImage: "sidebar.trailing")
                            }
                        }
                    }
            }
    }

    /// Wide enough for a callsign, its date and the band/mode chips without
    /// the search field truncating — 380 clipped its placeholder.
    private static let panelWidth: CGFloat = 420
}

/// Detents shared by the globe screen and its sheet — the same instances
/// everywhere, so selection and background interaction line up.
enum LogSheetDetents {
    /// Tall enough for the search field and filter chips, so the filters are
    /// usable without expanding over the globe they filter.
    static let collapsedHeight: CGFloat = 148
    static let collapsed = PresentationDetent.height(collapsedHeight)
    static let medium = PresentationDetent.fraction(0.45)
    static let expanded = PresentationDetent.large
    static let all: Set<PresentationDetent> = [collapsed, medium, expanded]
}

/// Contents of the log panel: the full filter set, then the contacts those
/// filters select.
struct LogSheetView: View {
    let allQSOs: [QSO]
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView(showsBackButton: false)
            Divider()
            QSOListView(allQSOs: allQSOs,
                        selectedQSO: $selectedQSO,
                        showsNavigationLinks: true,
                        onEdit: onEdit,
                        onDelete: onDelete)
        }
    }
}
#endif
