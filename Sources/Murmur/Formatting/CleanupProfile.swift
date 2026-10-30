import Foundation

/// Which pass cleans a transcript before it is typed.
enum CleanupEngine: String, CaseIterable, Sendable {
    /// `RuleBasedFormatter`: deterministic, zero latency, no model.
    case rules
    /// S1-mini by Superwhisper on the GPU through MLX. Steered by `CleanupProfile`.
    case s1Mini
    /// Apple's on-device Foundation Model. Unavailable until Apple Intelligence is ready.
    case appleIntelligence

    var displayName: String {
        switch self {
        case .rules: "Basic rules"
        // The license requires this exact name and capitalization wherever it's used.
        case .s1Mini: "S1-mini by Superwhisper"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    var detail: String {
        switch self {
        case .rules:
            "Strips fillers, fixes spacing and punctuation. Instant."
        case .s1Mini:
            "A 0.6B model trained only for transcript cleanup. Applies spoken corrections, writes "
                + "numbers, dates and emails, and follows the profile. Load once: about 1.5 GB "
                + "downloads, converts to 331 MB, then the original is deleted."
        case .appleIntelligence:
            "Apple's on-device model. Applies spoken corrections and formats lists. Ignores profiles."
        }
    }

    /// Engines whose output depends on the selected profile.
    var usesProfiles: Bool { self == .s1Mini }
}

/// Where the text is going, expressed as S1-mini's control line.
///
/// S1-mini was trained on exactly these axes and values, and its card warns that anything
/// outside them can make it hallucinate, so profiles are a closed set rather than free text.
enum CleanupProfile: String, CaseIterable, Sendable {
    case general
    case email
    case message
    case notes

    var displayName: String {
        switch self {
        case .general: "General"
        case .email: "Email"
        case .message: "Message"
        case .notes: "Notes"
        }
    }

    var detail: String {
        switch self {
        case .general: "Standard sentences and punctuation."
        case .email: "Greeting, body and sign-off on separate lines."
        case .message: "Keeps your phrasing; lowercase sentence starts, no final period."
        case .notes: "Turns three or more spoken items into bullets."
        }
    }

    enum Styling: String { case casual, semiCasual = "semi-casual", semiFormal = "semi-formal", formal }
    enum Structure: String { case prose, lists }
    enum Context: String { case general, email }

    var styling: Styling {
        switch self {
        case .general, .email, .notes: .semiFormal
        case .message: .semiCasual
        }
    }

    var structure: Structure { self == .notes ? .lists : .prose }

    var context: Context { self == .email ? .email : .general }

    /// The first line of S1-mini's user turn. Must match the trained format exactly.
    var controlLine: String {
        "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
    }
}
