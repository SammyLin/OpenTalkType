import Foundation
import Security

// Preferences and secrets. No UI here -- the settings sheet lives in MainWindow.swift.
//
// Every non-secret value is a UserDefaults key registered with a default, so a view can
// bind with @AppStorage(Prefs.provider) and a background actor can read the same key
// through UserDefaults.standard and see the same default. Secrets go to the Keychain.

// MARK: - Enumerations stored as raw strings

enum Provider: String, CaseIterable, Identifiable, Sendable {
    case deepseek, claudeCode, anthropic, openai, gemini, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .claudeCode: String(localized: "Claude Code (local CLI)")
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .local: String(localized: "Local")
        }
    }

    /// Placeholder for the model field. LLM.swift uses this when the field is empty.
    var defaultModel: String {
        switch self {
        case .deepseek: "deepseek-chat"
        case .claudeCode: "haiku"
        case .anthropic: "claude-sonnet-4-5"
        case .openai: "gpt-4.1-mini"
        case .gemini: "gemini-2.5-flash"
        case .local: "qwen3:8b"
        }
    }

    /// Only .local shows the base URL field; the others are fixed endpoints in LLM.swift.
    var needsBaseURL: Bool { self == .local }

    /// .local talks to a keyless server; .claudeCode reuses the CLI's own logged-in session, so
    /// neither has an API key field.
    var needsKey: Bool { self != .local && self != .claudeCode }

    var detail: String? {
        switch self {
        case .claudeCode:
            String(localized: "Uses the Claude Code subscription you are already signed in to, so there is no key to enter. The cost is speed: every request cold-starts the CLI, measured at about 5 seconds against about 1 second for a direct API key.")
        case .deepseek:
            String(localized: "About 1 second in testing, native-quality Chinese, and very cheap. Needs a DeepSeek API key.")
        case .local:
            String(localized: "An OpenAI-compatible server on this Mac (Ollama, LM Studio). Transcripts never leave the machine.")
        default: nil
        }
    }
}

enum RecognitionEngine: String, CaseIterable, Identifiable, Sendable {
    case speechTranscriber, dictationTranscriber

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechTranscriber: String(localized: "SpeechTranscriber (fast, drops nothing)")
        case .dictationTranscriber: String(localized: "DictationTranscriber (takes dictionary hints, better at English)")
        }
    }

    var detail: String {
        switch self {
        case .speechTranscriber: String(localized: "Quick to respond and never drops a word, but it often misspells English terms, which the dictionary and the LLM then fix.")
        case .dictationTranscriber: String(localized: "Takes vocabulary hints, so English proper nouns come out more accurately, but in testing it swallows a whole word now and then.")
        }
    }
}

/// The key held together with fn. All three triggers hang off fn, so a binding is just
/// "which extra key upgrades the mode".
enum Companion: String, CaseIterable, Identifiable, Sendable {
    case none, leftShift, space, leftControl, leftOption, leftCommand

    var id: String { rawValue }

    /// Key cap shown on Home and in the hotkey rows. Empty for .none.
    var keyCap: String? {
        switch self {
        case .none: nil
        case .leftShift: "⇧"
        case .space: "space"
        case .leftControl: "⌃"
        case .leftOption: "⌥"
        case .leftCommand: "⌘"
        }
    }

    var displayName: String {
        switch self {
        case .none: String(localized: "fn alone")
        case .leftShift: String(localized: "fn + Left Shift")
        case .space: String(localized: "fn + Space")
        case .leftControl: String(localized: "fn + Left Control")
        case .leftOption: String(localized: "fn + Left Option")
        case .leftCommand: String(localized: "fn + Left Command")
        }
    }
}

/// Translation targets, and the English name substituted into the translate prompt. That third
/// column is not decoration: Locale's localizedString ignores the script subtag, so zh-Hant and
/// zh-Hans both come back as "Chinese" and two of the picker's options would do nothing.
/// Short list on purpose; the field takes any BCP-47 code and falls back to Locale for those.
let translateLanguages: [(code: String, name: String, english: String)] = [
    ("en", String(localized: "English"), "English"),
    ("ja", String(localized: "Japanese"), "Japanese"),
    ("ko", String(localized: "Korean"), "Korean"),
    ("zh-Hant", String(localized: "Traditional Chinese"), "Traditional Chinese"),
    ("zh-Hans", String(localized: "Simplified Chinese"), "Simplified Chinese"),
    ("es", String(localized: "Spanish"), "Spanish"),
    ("fr", String(localized: "French"), "French"),
    ("de", String(localized: "German"), "German"),
]

// MARK: - Prefs

enum Prefs {
    // General
    static let launchAtLogin = "launchAtLogin"
    static let showHUD = "showHUD"
    static let soundFeedback = "soundFeedback"
    static let translateTarget = "translateTarget"       // BCP-47 language code, e.g. "en"
    static let hasOnboarded = "hasOnboarded"

    // AI
    static let provider = "provider"                     // Provider.rawValue
    static let model = "model"                           // empty means Provider.defaultModel
    static let localBaseURL = "localBaseURL"
    static let claudeBinPath = "claudeBinPath"           // empty means search the usual install spots
    static let recognitionEngine = "recognitionEngine"   // RecognitionEngine.rawValue
    static let locale = "locale"                         // recognition locale identifier

    // History
    static let historyRetentionDays = "historyRetentionDays"  // 0 = 永久
    static let autoAddDictionaryTerms = "autoAddDictionaryTerms"

    /// Per-mode system prompt override. Empty string means "use the built-in default".
    static func systemPrompt(_ id: String) -> String { "prompt.\(id)" }
    static func systemPrompt(_ mode: Mode) -> String { systemPrompt(mode.id) }

    /// Per-mode hotkey override, a Companion.rawValue. fn is always the base key.
    static func companionKey(_ id: String) -> String { "hotkey.\(id)" }
    static func companionKey(_ mode: Mode) -> String { companionKey(mode.id) }

    // MARK: Defaults

    static var registry: [String: Any] {[
        launchAtLogin: false,
        showHUD: true,
        soundFeedback: true,
        translateTarget: "en",
        hasOnboarded: false,
        provider: Provider.deepseek.rawValue,
        model: "",
        localBaseURL: "http://127.0.0.1:11434/v1",
        claudeBinPath: "",
        recognitionEngine: RecognitionEngine.speechTranscriber.rawValue,
        locale: "zh-TW",
        historyRetentionDays: 30,
        autoAddDictionaryTerms: true,
        // Keys declared next to the code that owns them (Input.swift, SpeechEngine.swift,
        // SettingsSheet.swift) but registered here, because the registry is also what backup
        // export walks and what tells import which type to write.
        //
        // urlSchemeEnabled and mcpEnabled are deliberately absent: unregistered reads false,
        // which is the default they must have, and staying out of the registry is what keeps an
        // imported settings file from switching on a remote-control surface behind the user.
        hudStyle: "notch",
        handsFreeLock: true,
        pasteMethod: PasteMethod.paste.rawValue,
        appendTrailingSpace: false,
        autoSubmit: false,
        inputDeviceUID: "",
        silenceStop: false,
        silenceLevel: 0.12,
        silenceSeconds: 1.5,
        muteWhileRecording: false,
        audioRetentionDays: 0,
        // Literal ids: the registry is read before the database is open, and a user-made mode
        // registers nothing -- Prefs.companion falls back to .none for anything unregistered.
        systemPrompt("dictate"): "",
        systemPrompt("translate"): "",
        systemPrompt("ask"): "",
        companionKey("dictate"): Companion.none.rawValue,
        companionKey("translate"): Companion.leftShift.rawValue,
        companionKey("ask"): Companion.space.rawValue,
    ]}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: registry)
    }

    // MARK: Typed reads, for code that is not a SwiftUI view

    private static var ud: UserDefaults { .standard }

    static var providerValue: Provider {
        Provider(rawValue: ud.string(forKey: provider) ?? "") ?? .deepseek
    }

    static var engineValue: RecognitionEngine {
        RecognitionEngine(rawValue: ud.string(forKey: recognitionEngine) ?? "") ?? .speechTranscriber
    }

    static var localeValue: String { ud.string(forKey: locale) ?? "zh-TW" }

    static var modelValue: String {
        let m = (ud.string(forKey: model) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? providerValue.defaultModel : m
    }

    static var localBaseURLValue: String {
        ud.string(forKey: localBaseURL) ?? "http://127.0.0.1:11434/v1"
    }

    /// A GUI app inherits launchd's PATH, not the login shell's, so `claude` is never simply on
    /// PATH here. Take an explicit setting first, then probe the places the installer uses.
    static var claudeBin: String? {
        let explicit = (ud.string(forKey: claudeBinPath) ?? "").trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var retentionDays: Int { ud.integer(forKey: historyRetentionDays) }

    static var autoAddTerms: Bool { ud.bool(forKey: autoAddDictionaryTerms) }

    static var hudEnabled: Bool { ud.bool(forKey: showHUD) }

    static var translateTargetCode: String { ud.string(forKey: translateTarget) ?? "en" }

    /// English name of the translation target, substituted into the translate prompt.
    static var translateTargetEnglishName: String {
        let code = translateTargetCode
        return translateLanguages.first { $0.code == code }?.english
            ?? Locale(identifier: "en_US").localizedString(forLanguageCode: code)
            ?? code
    }

    static func companion(_ mode: Mode) -> Companion {
        Companion(rawValue: ud.string(forKey: companionKey(mode)) ?? "") ?? .none
    }

    static func setCompanion(_ c: Companion, for mode: Mode) {
        ud.set(c.rawValue, forKey: companionKey(mode))
    }

    /// The effective system prompt: the user's override, or the built-in default.
    static func prompt(for mode: Mode) -> String {
        let custom = (ud.string(forKey: systemPrompt(mode)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        // A user-made mode carries its prompt on the record; only the seeded three have a
        // built-in fallback in code.
        let own = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? defaultPrompt(mode) : own
    }

    /// Built-in prompts. `{{TARGET}}` in the translate prompt is replaced by LLM.swift with
    /// Prefs.translateTargetEnglishName. LLM.swift appends the dictionary terms block after
    /// whichever prompt is in effect, so a user override still gets the terms.
    static func defaultPrompt(_ mode: Mode) -> String {
        switch mode.id {
        case "dictate":
            """
            You clean up dictated speech into written text. Remove filler words, false starts \
            and self-corrections. Fix punctuation, casing and obvious recognition errors. Keep \
            the speaker's language, meaning, tone and terminology exactly. Never answer, \
            summarise, translate or add anything. Reply with the cleaned text only.
            """
        case "translate":
            """
            You translate dictated speech into {{TARGET}}. First clean up the speech, then \
            produce idiomatic {{TARGET}} that a native speaker would actually write, not a \
            literal gloss. Keep proper nouns and technical terms. Reply with the translation \
            only, with no notes and no original text.
            """
        case "ask":
            """
            You act on the user's selected text according to their spoken instruction. Return \
            only the replacement text, with no preamble, no explanation and no surrounding \
            quotes, so it can be pasted straight over the selection. Match the language and \
            formatting of the selection unless the instruction says otherwise. If there is no \
            selected text, answer the spoken question directly and concisely.
            """
        default:
            // A user-made mode that left its prompt empty still has to do something sane.
            """
            You clean up dictated speech into written text. Remove filler words and false starts, \
            fix punctuation and casing, and change nothing else.
            """
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "ai.3mi.opentalktype"

    /// Account name for a provider's API key, e.g. "apiKey.anthropic".
    static func account(for provider: Provider) -> String { "apiKey.\(provider.rawValue)" }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Empty value deletes the item. Delete-then-add instead of SecItemUpdate: one code path.
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
