import SwiftUI

/// One key per cleanup profile. The selected one is sunk, yellow and checked, so you can
/// tell which is active without reading anything. Picking one applies to the next hold.
struct ProfileKeys: View {
    @State private var settings = Settings.shared

    var body: some View {
        ChoiceKeys(
            options: CleanupProfile.allCases,
            selection: $settings.cleanupProfile,
            title: \.displayName,
            help: \.detail
        )
    }
}
