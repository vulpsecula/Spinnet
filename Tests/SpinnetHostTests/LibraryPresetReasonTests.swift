import SpinnetCore
import Testing
@testable import SpinnetHost

struct LibraryPresetReasonTests {
    @Test func unavailablePresetOffersTheSameRepairVisiblyAndToVoiceOver() {
        let preset = MenuItemPreset(pluginID: PluginID("com.example.spotify"), name: "Spotify",
                                    commands: [], declaration: .init(), unavailableReason: .externalAppMissing("Spotify"))

        #expect(preset.localizedStateLabel == localized("Unavailable"))
        let repair = localized("Install \("Spotify") to use \("Spotify") Commands")
        #expect(preset.localizedUnavailableReason == repair)
        #expect(preset.localizedAccessibilityLabel.contains(repair))
    }
}
