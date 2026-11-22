import MurmurKit

extension AppleSpeechEngine {
    /// An engine that biases the recognizer toward the user's dictionary terms. The main-actor
    /// hop is a real one: the engine asks from its own executor.
    static func biasedByDictionary() -> AppleSpeechEngine {
        AppleSpeechEngine(dictionaryPhrases: { await MainActor.run { DictionaryStore.shared.biasPhrases } })
    }
}
