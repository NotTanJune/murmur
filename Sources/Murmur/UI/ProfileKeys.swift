import SwiftUI

/// One chip per cleanup profile. The selected one is cream, ink-stroked and checked, so you
/// can tell which is active without reading anything. Picking one applies to the next hold.
struct ProfileKeys: View {
    /// Tighter chips, for shared rows.
    var dense = false
    /// Stacked, for the sidebar.
    var isVertical = false
    @State private var settings = Settings.shared

    var body: some View {
        ChoiceKeys(
            options: CleanupProfile.allCases,
            selection: $settings.cleanupProfile,
            title: \.displayName,
            help: \.detail,
            dense: dense,
            isVertical: isVertical
        )
    }
}
