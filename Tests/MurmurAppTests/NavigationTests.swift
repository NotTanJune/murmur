import Testing
@testable import Murmur

@MainActor
@Suite struct NavigationTests {
    @Test("The gear opens Settings and a second click returns to the previous tab")
    func gearToggles() {
        let navigation = MainNavigation.shared
        let original = navigation.section
        defer { navigation.section = original }

        navigation.section = .dictionary
        navigation.toggleSettings()
        #expect(navigation.section == .settings)
        navigation.toggleSettings()
        #expect(navigation.section == .dictionary)

        navigation.section = .transcriptions
        navigation.toggleSettings()
        navigation.toggleSettings()
        #expect(navigation.section == .transcriptions)
    }
}
