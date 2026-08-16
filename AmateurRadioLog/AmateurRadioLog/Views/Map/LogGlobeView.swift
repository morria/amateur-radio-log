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
/// - **Regular (iPad):** an inline side panel. A `.sheet` with detents at
///   regular width is presented as a *centred form sheet*, not a bottom
///   sheet — a slab floating over the middle of the screen.
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

    /// iPad: globe and panel side by side, so neither hides the other.
    private var regularLayout: some View {
        HStack(spacing: 0) {
            ContactMapView(qsos: allQSOs, chromeless: true)
            Divider()
            LogSheetView(allQSOs: allQSOs,
                         selectedQSO: $selectedQSO,
                         onEdit: onEdit,
                         onDelete: onDelete)
                .frame(width: 380)
                .background(.regularMaterial)
        }
    }
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
