import Foundation

/// Which engine hears a hold on the phone's keyboard: Bark Clean once it has loaded, Apple's
/// transcriber otherwise (still loading, not downloaded, the crash marker says Bark killed the
/// keyboard last time, or the setting names an engine the keyboard does not offer).
public enum KeyboardEngineChoice: Sendable, Equatable {
    case bark
    case apple

    public static func choose(setting: SpeechEngineChoice, barkReady: Bool, markerArmed: Bool) -> KeyboardEngineChoice {
        setting == .barkClean && barkReady && !markerArmed ? .bark : .apple
    }
}
