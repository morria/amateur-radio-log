#if os(iOS)
import SwiftUI
import UIKit

/// A file URL queued for the share sheet, Identifiable so it can drive
/// `.sheet(item:)` directly.
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// UIActivityViewController wrapper for exporting files (Files, AirDrop,
/// Mail, ...). SwiftUI's ShareLink requires the payload up front, but our
/// export files are generated on tap — so present the classic controller
/// with the freshly written temp-file URL instead.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
