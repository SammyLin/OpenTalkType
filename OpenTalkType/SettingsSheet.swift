import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// The settings sheet: its own narrow sidebar over the main window. Every row here writes a
// Prefs key, a Store row or the Keychain -- nothing is decorative, and nothing is a placeholder.
//
// The sidebar has twelve pages, not the four SettingsTab cases. SettingsTab lives in App.swift
// and is what the rest of the app deep-links to (Home's status pills, the menu bar); it is
// mapped onto a page on the way in. Twelve rows is what "everything is one click away" costs
// once modes, triggers, insertion, audio, two rule tables, automation and backup all have to be
// reachable -- a single 一般 page holding all of it would be a scroll, not a place.

private let repositoryURL = URL(string: "https://github.com/3mi-ai/opentalktype")!

private let recognitionLocales: [(code: String, name: String)] = [
    ("zh-TW", String(localized: "Chinese (Taiwan)")),
    ("zh-CN", String(localized: "Chinese (China)")),
    ("en-US", String(localized: "English (US)")),
    ("en-GB", String(localized: "English (UK)")),
    ("ja-JP", String(localized: "Japanese")),
    ("ko-KR", String(localized: "Korean")),
]

/// The HUD placement key. Panels.swift reads the same string literal and says it must equal this
/// constant; defining it here is what makes that true, since Settings.swift is not this file's
/// to edit and the value is only ever written from this sheet.
extension Prefs {
    static let hudStyle = "hudStyle"
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Pages

private enum Page: String, CaseIterable, Identifiable {
    case general, modes, trigger, insertion, audio
    case replacements, appRules, automation, backup
    case ai, permissions, about

    var id: String { rawValue }

    /// Where a deep link from elsewhere in the app lands.
    init(_ tab: SettingsTab) {
        switch tab {
        case .general: self = .general
        case .ai: self = .ai
        case .permissions: self = .permissions
        case .about: self = .about
        }
    }

    var displayName: String {
        switch self {
        case .general: String(localized: "General")
        case .modes: String(localized: "Modes")
        case .trigger: String(localized: "Trigger")
        case .insertion: String(localized: "Text Insertion")
        case .audio: String(localized: "Audio")
        case .replacements: String(localized: "Replacements")
        case .appRules: String(localized: "App Rules")
        case .automation: String(localized: "Automation")
        case .backup: String(localized: "Backup")
        case .ai: String(localized: "AI")
        case .permissions: String(localized: "Permissions")
        case .about: String(localized: "About")
        }
    }

    var sfSymbol: String {
        switch self {
        case .general: "gearshape"
        case .modes: "square.stack.3d.up"
        case .trigger: "hand.tap"
        case .insertion: "text.cursor"
        case .audio: "waveform"
        case .replacements: "arrow.left.arrow.right"
        case .appRules: "app.badge.checkmark"
        case .automation: "link"
        case .backup: "arrow.up.arrow.down.square"
        case .ai: "brain"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

struct SettingsSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(Theme.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.m)
                    .padding(.bottom, Theme.Space.l)
                ForEach(Page.allCases) { p in
                    if p == .ai {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                            .padding(.vertical, Theme.Space.s)
                    }
                    TabRow(page: p, selected: page == p) { page = p }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.m)
            .frame(width: 176)
            .background(Theme.sidebar)

            Rectangle().fill(Theme.stroke).frame(width: 1)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        switch page {
                        case .general: GeneralPage()
                        case .modes: ModesPage()
                        case .trigger: TriggerPage()
                        case .insertion: InsertionPage()
                        case .audio: AudioPage()
                        case .replacements: ReplacementsPage()
                        case .appRules: AppRulesPage()
                        case .automation: AutomationPage()
                        case .backup: BackupPage()
                        case .ai: AIPage()
                        case .permissions: PermissionsPage(state: state)
                        case .about: AboutPage()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.xl)
                }
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
        }
        .frame(width: 900, height: 660)
        // The deep link is read on open and whenever it changes while the sheet is up, so
        // "點一下前往修正" on Home still lands on the right page.
        .onAppear { page = Page(state.settingsTab) }
        .onChange(of: state.settingsTab) { page = Page(state.settingsTab) }
    }
}

private struct TabRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: page.sfSymbol).font(.system(size: 12)).frame(width: 16)
                Text(page.displayName).font(Theme.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentSoft : .clear,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 一般

private struct GeneralPage: View {
    @AppStorage(Prefs.showHUD) private var showHUD = true
    @AppStorage(Prefs.hudStyle) private var hudStyle = "notch"
    @AppStorage(Prefs.soundFeedback) private var sound = true
    @AppStorage(Prefs.translateTarget) private var target = "en"
    @AppStorage(Prefs.launchAtLogin) private var launchAtLogin = false

    var body: some View {
        Section("Floating window") {
            Toggle("Show the floating window while you speak", isOn: $showHUD)
            Picker("Position", selection: $hudStyle) {
                Text("Notch (flush with the top of the screen)").tag("notch")
                Text("Centered near the bottom of the screen").tag("bottom")
            }
            .frame(width: 340)
            .disabled(!showHUD)
            Text("Notch grows a black panel out of the top edge of the screen, with the input level on the left and the live transcription on the right. On a screen without a notch it becomes a pill tucked under the menu bar. The floating window never takes keyboard focus.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Other") {
            Toggle("Play a sound when dictation starts and stops", isOn: $sound)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
        }

        Section("Translation") {
            Picker("Translate into", selection: $target) {
                ForEach(translateLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            .frame(width: 340)
            Text("Modes with translation turned on all target this language.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    /// ponytail: a failed register is reported by flipping the toggle back, with no alert. The
    /// only realistic cause is an unsigned build, which the 權限 tab already explains.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = !on
        }
    }
}

// MARK: - 模式

private struct ModesPage: View {
    @State private var editing: Mode?
    @State private var modes: [Mode] = []

    var body: some View {
        Section("Modes") {
            Text("A mode is a prompt plus a key. To change the key, go to Trigger.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            ForEach(modes) { m in
                ModeRow(mode: m, edit: { editing = m },
                        remove: m.builtIn ? nil : { Store.shared.deleteMode(m.id) })
            }
            Button {
                editing = Mode(id: "", displayName: "", subtitle: "", sfSymbol: "wand.and.stars",
                               prompt: "", usesSelection: false, translates: false, builtIn: false)
            } label: { Label("New Mode", systemImage: "plus") }
        }

        Color.clear.frame(height: 0)
            .sheet(item: $editing) { ModeEditor(mode: $0) }
            .task(id: Store.shared.revision) { modes = Store.shared.modes() }
    }
}

private struct ModeRow: View {
    let mode: Mode
    let edit: () -> Void
    /// nil for a built-in: those cannot be deleted, only edited.
    let remove: (() -> Void)?

    private var shell: String { Store.shared.shellCommand(mode.id) }
    private var override: AutoSubmit {
        AutoSubmit(rawValue: UserDefaults.standard.string(forKey: Prefs.autoSubmitKey(mode)) ?? "")
            ?? .inherit
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: mode.sfSymbol).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName).font(Theme.body).foregroundStyle(Theme.textPrimary)
                if !mode.subtitle.isEmpty {
                    Text(mode.subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.m)
            if !shell.isEmpty {
                Badge(symbol: "terminal", text: "Command")
                    .help("Runs after cleanup: \(shell)")
            }
            if override != .inherit {
                Badge(symbol: "return", text: override == .on ? "Always sends" : "Never sends")
            }
            KeyCaps(mode.keyCaps)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit this mode")
            if let remove {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this mode")
            }
        }
    }
}

private struct Badge: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(Theme.caption)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.cardHover, in: .rect(cornerRadius: Theme.Radius.chip))
    }
}

/// Create or edit a mode. The prompt field is the product: everything else is labelling, except
/// the shell command, which is arbitrary code execution and is labelled as such.
private struct ModeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Mode
    @State private var promptText: String
    @State private var shell: String
    @State private var autoSubmit: String
    private let isNew: Bool

    init(mode: Mode) {
        _draft = State(initialValue: mode)
        isNew = mode.id.isEmpty
        _promptText = State(initialValue: mode.id.isEmpty ? "" : Prefs.prompt(for: mode))
        _shell = State(initialValue: mode.id.isEmpty ? "" : Store.shared.shellCommand(mode.id))
        _autoSubmit = State(initialValue: mode.id.isEmpty ? AutoSubmit.inherit.rawValue
            : UserDefaults.standard.string(forKey: Prefs.autoSubmitKey(mode)) ?? AutoSubmit.inherit.rawValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(isNew ? "New Mode" : "Edit Mode")
                    .font(Theme.heading).foregroundStyle(Theme.textPrimary)
                identity
                prompt
                behaviour
                shellField
                buttons
            }
            .padding(Theme.Space.xl)
        }
        .frame(width: 660, height: 640)
        .background(Theme.background)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                TextField("Name", text: $draft.displayName).frame(width: 180)
                TextField("SF Symbol", text: $draft.sfSymbol, prompt: Text("wand.and.stars"))
                    .frame(width: 180)
                Image(systemName: draft.sfSymbol.isEmpty ? "wand.and.stars" : draft.sfSymbol)
                    .foregroundStyle(Theme.accent)
            }
            TextField("One-line description", text: $draft.subtitle).frame(maxWidth: .infinity)
            Toggle("Read the selected text first and treat what you say as an instruction for it", isOn: $draft.usesSelection)
            Toggle("Translate into the target language set in Settings → General", isOn: $draft.translates)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Prompt").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            TextEditor(text: $promptText)
                .font(Theme.mono)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .background(Theme.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.stroke))
            Text("The injection guard, the dictionary and the CJK spacing rules are appended automatically, so you do not have to write them. In a translating mode, {{TARGET}} stands for the target language.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Picker("Submit automatically after pasting", selection: $autoSubmit) {
                ForEach(AutoSubmit.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 340)
            Text("Overrides the global setting under Text Insertion. A mode meant for a chat window wants to submit every time; a mode for writing documents never should.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                Text("Command to run after cleanup (optional)")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            TextField("", text: $shell, prompt: Text("For example: tee -a ~/notes.md"))
                .font(Theme.mono)
                .frame(maxWidth: .infinity)
            Text("This line is handed to /bin/sh as you, with every file permission you have, exactly as if you had typed it in Terminal. Only put in commands you wrote yourself and understand.")
                .font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text("The cleaned-up text arrives on standard input, and is also available as $OT_TRANSCRIPT (cleaned up), $OT_RAW (the raw transcript), $OT_MODE and $OT_APP. If the command writes anything, its output replaces the text to be pasted; if it writes nothing, the original text is pasted. The working directory is your home folder, the timeout is 15 seconds, and a non-zero exit shows the command's error message.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            if !isNew {
                Button("Restore Default Prompt") {
                    UserDefaults.standard.removeObject(forKey: Prefs.systemPrompt(draft))
                    promptText = Prefs.defaultPrompt(draft)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        var m = draft
        if m.id.isEmpty { m.id = Store.shared.freeModeID(from: m.displayName) }
        if m.sfSymbol.trimmingCharacters(in: .whitespaces).isEmpty { m.sfSymbol = "wand.and.stars" }
        // The prompt lives in Prefs, not on the record, so built-ins and user modes read back
        // through exactly the same path and "回復預設" means the same thing for both.
        m.prompt = ""
        Store.shared.saveMode(m)
        Store.shared.setShellCommand(shell, for: m.id)
        UserDefaults.standard.set(promptText, forKey: Prefs.systemPrompt(m))
        UserDefaults.standard.set(autoSubmit, forKey: Prefs.autoSubmitKey(m))
        dismiss()
    }
}

// MARK: - 觸發

private struct TriggerPage: View {
    @AppStorage(Prefs.handsFreeLock) private var handsFree = true
    @AppStorage(Prefs.silenceStop) private var silenceStop = false
    @AppStorage(Prefs.silenceLevel) private var silenceLevel = 0.12
    @AppStorage(Prefs.silenceSeconds) private var silenceSeconds = 1.5
    @State private var modes: [Mode] = []

    var body: some View {
        Section("Hold or lock") {
            Text("Hold fn to speak and release to finish; this always works. Press Esc at any time to cancel, which pastes nothing and records nothing.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Double-tap fn to lock, so you do not have to hold it", isOn: $handsFree)
            Text("Adds one gesture: tap fn twice within 0.4 seconds and the microphone stays open until you tap fn again. Useful for long dictation, when holding a key down the whole time gets tiring.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Key for each mode") {
            Text("Everything starts from fn; what you pick here is the extra key held with it. When two modes claim the same key, the one higher in the list wins.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(modes) { HotkeyRow(mode: $0) }
        }

        Section("Stop on silence") {
            Toggle("Finish automatically once you stop speaking", isOn: $silenceStop)
            LabeledSlider(title: "Level threshold", value: $silenceLevel, range: 0.01...0.9, step: 0.01,
                          text: String(format: "%.2f", silenceLevel))
                .disabled(!silenceStop)
            LabeledSlider(title: "Silence for", value: $silenceSeconds, range: 0.5...10, step: 0.1,
                          text: String(format: String(localized: "%.1f s"), silenceSeconds))
                .disabled(!silenceStop)
            Text("The countdown only starts once speech has been heard, so nothing is cut off while you hold the key and think of a sentence. The decision uses a smoothed level, so a short pause mid-sentence is not mistaken for the end. A higher threshold makes silence easier to declare: raise it in a noisy room, lower it in a quiet one.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: Store.shared.revision) { modes = Store.shared.modes() }
    }
}

private struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range, step: step).frame(width: 240)
            Text(text).font(Theme.mono).foregroundStyle(Theme.textSecondary)
                .frame(width: 60, alignment: .leading)
        }
    }
}

private struct HotkeyRow: View {
    let mode: Mode
    @AppStorage private var companion: String

    init(mode: Mode) {
        self.mode = mode
        _companion = AppStorage(wrappedValue: Companion.none.rawValue, Prefs.companionKey(mode))
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: mode.sfSymbol).foregroundStyle(Theme.accent).frame(width: 18)
            Text(mode.displayName).font(Theme.body).foregroundStyle(Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
            KeyCaps(["fn"] + ((Companion(rawValue: companion) ?? .none).keyCap.map { [$0] } ?? []))
            Spacer(minLength: Theme.Space.l)
            Picker("", selection: $companion) {
                ForEach(Companion.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}

// MARK: - 插入文字

private struct InsertionPage: View {
    @AppStorage(Prefs.pasteMethod) private var method = PasteMethod.paste.rawValue
    @AppStorage(Prefs.appendTrailingSpace) private var trailingSpace = false
    @AppStorage(Prefs.autoSubmit) private var autoSubmit = false

    private var current: PasteMethod { PasteMethod(rawValue: method) ?? .paste }

    var body: some View {
        Section("How text is inserted") {
            Picker("Method", selection: $method) {
                ForEach(PasteMethod.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 340)
            Text(current.detail)
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("After pasting") {
            Toggle("Add a trailing space", isOn: $trailingSpace)
            Text("When you dictate several passages in a row, you do not have to type the space before the next one.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Toggle("Press Return to submit", isOn: $autoSubmit)
            Text("Handy in a chat window; a text editor will simply take the line break. When pasting with ⌘V, Return is only sent once the other app has actually read the clipboard: if it never does, nothing is sent and you press Return yourself. Individual modes can override this under Modes.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Secure input") { SecureInputRow() }
    }
}

/// Live because the whole point is to look at it while the offending app is in front. Polls once
/// a second: IsSecureEventInputEnabled has no notification, and a second is faster than a person
/// can switch windows and read.
private struct SecureInputRow: View {
    @State private var enabled = SecureInput.enabled

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Circle().fill(enabled ? Theme.warning : Theme.success).frame(width: 8, height: 8)
            Text(enabled ? "An app is using secure input" : "No app is holding secure input")
                .font(Theme.body).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        Text(enabled
             ? SecureInput.advice
             : String(localized: "While secure input is on, no app can send keystrokes on your behalf, so both pasting and simulated typing stop working. Password fields and Terminal's Secure Keyboard Entry turn it on. When that happens the text still reaches the clipboard, the history and the menu bar, so nothing is lost."))
            .font(Theme.caption)
            .foregroundStyle(enabled ? Theme.warning : Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        // ponytail: a poll, because there is no notification for this state. Stops with the view.
        Color.clear.frame(height: 0).task {
            while !Task.isCancelled {
                enabled = SecureInput.enabled
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - 音訊

private struct AudioPage: View {
    @AppStorage(Prefs.inputDeviceUID) private var deviceUID = ""
    @AppStorage(Prefs.muteWhileRecording) private var mute = false
    @AppStorage(Prefs.audioRetentionDays) private var retention = 0
    @State private var devices: [InputDevice] = []

    var body: some View {
        Section("Input device") {
            HStack(spacing: Theme.Space.m) {
                Picker("Microphone", selection: $deviceUID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                .frame(width: 340)
                Button("Rescan") { devices = SpeechEngine.inputDevices }
            }
            Text("The choice is applied again before every session, so changing devices here needs no restart: the next press of fn already uses it. If the chosen device is unplugged, the system default takes over; unplug it mid-recording and the session ends there, with everything heard so far still cleaned up, pasted and saved to history.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("While recording") {
            Toggle("Mute other audio while recording", isOn: $mute)
            Text("Drops the default output device to zero and restores it afterwards. Video and music keep playing, you just cannot hear them, and this silences the app's own start and stop sounds along with everything else. Any volume change you make by hand while recording is undone at the end.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Keep recordings") {
            HStack(spacing: Theme.Space.m) {
                Picker("Keep", selection: $retention) {
                    Text("Do not keep").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .frame(width: 220)
                Button("Show in Finder") { NSWorkspace.shared.open(SpeechEngine.audioDir) }
            }
            Text("What is kept is the 16 kHz mono audio the recognizer actually heard, about 2 MB per minute, playable by expanding the entry under History. Choosing Do not keep stops recording and deletes the files already saved on the next launch: turning the feature off and leaving a pile of old recordings behind would be the worse outcome. Recordings stay on this Mac and are never uploaded.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { devices = SpeechEngine.inputDevices }
    }
}

// MARK: - 取代規則

private struct ReplacementsPage: View {
    @State private var rules: [ReplacementRule] = []

    var body: some View {
        Section("Replacements") {
            Text("After the AI cleans the text up and before it is pasted, these literal replacements run in order. The result of rule 1 is handed to rule 2, so the order matters. Good for a misrecognition that keeps coming back, an in-house spelling, or turning a spoken word into the symbol you want.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Text("On").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 30)
                Text("Find").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 170, alignment: .leading)
                Text("Replace with").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 170, alignment: .leading)
                Text("Aa case-sensitive   .* regular expression").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, _ in
                RuleRow(rule: $rules[index],
                        canMoveUp: index > 0,
                        canMoveDown: index < rules.count - 1,
                        move: { move(index, by: $0) },
                        remove: { remove(index) })
            }
            if rules.isEmpty {
                Text("No rules yet.").font(Theme.body).foregroundStyle(Theme.textTertiary)
            }
            Button { rules.append(ReplacementRule()) } label: { Label("New Rule", systemImage: "plus") }
                // An unsaved row still has id 0, and two of them would collide as ForEach ids.
                .disabled(rules.last.map { $0.find.isEmpty } ?? false)
        }
        // Loaded once, not on every revision: the rows write straight through on each keystroke,
        // and reloading on the bump that write causes would yank the text field out from under
        // the cursor.
        .task { rules = Store.shared.replacementRules() }
    }

    private func move(_ index: Int, by delta: Int) {
        let to = index + delta
        guard rules.indices.contains(to) else { return }
        rules.swapAt(index, to)
        Store.shared.reorderReplacementRules(rules.map(\.id))
    }

    private func remove(_ index: Int) {
        let r = rules.remove(at: index)
        if r.id != 0 { Store.shared.deleteReplacementRule(r.id) }
    }
}

private struct RuleRow: View {
    @Binding var rule: ReplacementRule
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    private var regexBroken: Bool { rule.isRegex && !Store.regexIsValid(rule.find) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Toggle("", isOn: $rule.enabled).labelsHidden().frame(width: 30)
                TextField("", text: $rule.find, prompt: Text("Text to replace"))
                    .font(Theme.mono).frame(width: 170)
                TextField("", text: $rule.replace, prompt: Text("Replacement (empty deletes it)"))
                    .font(Theme.mono).frame(width: 170)
                Toggle("Aa", isOn: $rule.caseSensitive).toggleStyle(.button)
                    .help("Case-sensitive")
                Toggle(".*", isOn: $rule.isRegex).toggleStyle(.button)
                    .help("Treat Find as a regular expression")
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMoveDown)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if regexBroken {
                Text("This regular expression does not compile. The rule is skipped whole; the others still run.")
                    .font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        // Writes on every edit. A new row (id 0) is not stored until 找 has something in it,
        // and the id that comes back is written home so the next keystroke updates instead of
        // inserting a second copy.
        .onChange(of: rule) {
            let id = Store.shared.saveReplacementRule(rule)
            if rule.id == 0, id != 0 { rule.id = id }
        }
    }
}

// MARK: - App 規則

private struct AppRulesPage: View {
    @State private var rules: [AppRule] = []
    @State private var modes: [Mode] = []
    @State private var newBundleID = ""
    @State private var newAppName = ""
    @State private var newHost = ""
    @State private var newMode = ""

    var body: some View {
        Section("Switch mode by app or website") {
            Text("In these apps or on these sites the shortcut switches straight to the mode you name here, so there is no second key combination to remember.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Match order: app and site, then site alone, then app alone. Within a tier the longer domain wins, and when nothing matches, the mode chosen by the key is used. A site only means anything while a browser is frontmost, and subdomains count: google.com matches docs.google.com but not evilgoogle.com.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, _ in
                AppRuleRow(rule: $rules[index], modes: modes) { remove(index) }
            }
            if rules.isEmpty {
                Text("No rules yet.").font(Theme.body).foregroundStyle(Theme.textTertiary)
            }
            adder
        }
        // Same reason as the replacement rules: the rows save on every keystroke, so reloading
        // on the resulting revision bump would fight the text field.
        .task {
            rules = Store.shared.appRules()
            modes = Store.shared.modes()
            if newMode.isEmpty { newMode = modes.first?.id ?? "" }
        }
    }

    private var adder: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Choose App…", action: pickApp)
            Text(newAppName.isEmpty ? String(localized: "Any app") : newAppName)
                .font(Theme.body).foregroundStyle(newAppName.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            TextField("", text: $newHost, prompt: Text("Website (optional)")).frame(width: 150)
            Picker("", selection: $newMode) {
                ForEach(modes) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden().frame(width: 130)
            Button("Add") {
                Store.shared.saveAppRule(AppRule(bundleID: newBundleID, host: newHost, modeID: newMode))
                newBundleID = ""; newAppName = ""; newHost = ""
                // Re-read rather than append: (app, host) is an upsert, so a repeat pair edits
                // the existing row instead of adding one.
                rules = Store.shared.appRules()
            }
            .disabled(newMode.isEmpty || (newBundleID.isEmpty && newHost.trimmingCharacters(in: .whitespaces).isEmpty))
            Spacer(minLength: 0)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        newBundleID = id
        newAppName = FileManager.default.displayName(atPath: url.path)
    }

    private func remove(_ index: Int) {
        let r = rules.remove(at: index)
        if r.id != 0 { Store.shared.deleteAppRule(r.id) }
    }
}

private struct AppRuleRow: View {
    @Binding var rule: AppRule
    let modes: [Mode]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: rule.bundleID.isEmpty ? "globe" : "app.dashed")
                .font(.system(size: 11)).foregroundStyle(Theme.accent).frame(width: 16)
            Text(Self.appName(rule.bundleID))
                .font(Theme.body).foregroundStyle(Theme.textPrimary)
                .frame(width: 150, alignment: .leading).lineLimit(1)
                .help(rule.bundleID.isEmpty ? String(localized: "Any app") : rule.bundleID)
            TextField("", text: $rule.host, prompt: Text("Any website"))
                .font(Theme.mono).frame(width: 170)
            Image(systemName: "arrow.right").font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Picker("", selection: $rule.modeID) {
                ForEach(modes) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden().frame(width: 130)
            Spacer(minLength: 0)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .onChange(of: rule) { Store.shared.saveAppRule(rule) }
    }

    /// A bundle id is what the rule stores, but nobody recognises com.apple.dt.Xcode at a glance.
    static func appName(_ bundleID: String) -> String {
        guard !bundleID.isEmpty else { return String(localized: "Any app") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}

// MARK: - 自動化

private struct AutomationPage: View {
    @AppStorage(Prefs.urlSchemeEnabled) private var urlScheme = false
    @AppStorage(Prefs.mcpEnabled) private var mcp = false

    private static var urlActions: String {
        String(localized: """
        opentalktype://start?mode=dictate         Start dictating in the given mode
        opentalktype://stop                       Finish this session, clean up and paste
        opentalktype://cancel                     Cancel this session, paste nothing, record nothing
        opentalktype://run?mode=dictate&text=…    Skip the microphone and clean up this text
        opentalktype://paste-last                 Paste the previous result again
        """)
    }

    private var mcpSnippet: String {
        let path = Bundle.main.executablePath ?? "/Applications/OpenTalkType.app/Contents/MacOS/OpenTalkType"
        return """
        {
          "mcpServers": {
            "opentalktype": {
              "command": "\(path)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        Section("URL control") {
            Toggle("Allow opentalktype:// links to control this app", isOn: $urlScheme)
            Text("Off by default, because any web page can open a link like this. Turn it on to trigger dictation from Shortcuts, Raycast, Keyboard Maestro or a one-line open command. The actions it understands:")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            CodeBlock(text: Self.urlActions)
            Text("Leaving mode out means dictate. Naming a mode that does not exist does nothing at all, rather than falling back to the default. Text passed to run is capped at 20,000 characters.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("MCP server") {
            Toggle("Allow this app to serve MCP with --mcp", isOn: $mcp)
            Text("Lets a client such as Claude Code read your history and dictionary, trigger dictation and clean up text. Off by default: any local program that can run this binary can connect, which hands it your dictation history. Once it is on, paste the block below into the client's MCP configuration:")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            CodeBlock(text: mcpSnippet)
            Text("It speaks over standard input and output and opens no port. If you move the app somewhere else, copy this path again.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A read-only, selectable, copyable monospaced block. Selectable so a person can take one line,
/// with a button because taking all of it is the common case.
private struct CodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(Theme.Space.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardHover, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
            Button(copied ? "Copied" : "Copy") {
                copyToPasteboard(text)
                copied = true
            }
            .font(Theme.caption)
        }
    }
}

// MARK: - 備份

private struct BackupPage: View {
    @State private var applyPrefs = true
    @State private var status = ""
    @State private var failed = false

    var body: some View {
        Section("Export") {
            Button("Export Settings…", action: export)
            Text("Includes modes and their prompts, the dictionary, replacements, app rules and preferences.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text("It does not include API keys. Keys live in the macOS Keychain and this feature never reads them, so the exported file is safe to send to someone else or commit to version control. It does not include your dictation history either: that is what you said, not a setting.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Import") {
            Toggle("Also apply the preferences in the file", isOn: $applyPrefs)
            Button("Import Settings…", action: importBackup)
            Text("Anything you already have is kept: a mode with the same id is skipped whole, the dictionary only gains variants it did not have, and duplicate replacements and app rules are skipped. Nothing existing is ever deleted. Preferences are the one thing that gets overwritten, which is why the switch above can turn that off.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty {
                Text(status)
                    .font(Theme.body)
                    .foregroundStyle(failed ? Theme.danger : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue =
            "OpenTalkType-\(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Store.shared.exportBackup().write(to: url)
            failed = false
            status = String(format: String(localized: "Exported to %@."), url.lastPathComponent)
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try Store.shared.importBackup(Data(contentsOf: url), applyPrefs: applyPrefs)
            failed = false
            status = String(format: String(localized: "Imported %lld modes, %lld terms, %lld replacements, %lld app rules and %lld preferences. %lld skipped."),
                            s.modes, s.terms, s.replacements, s.appRules, s.prefs, s.skipped)
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }
}

// MARK: - AI

/// Provider, model, key and base URL. Onboarding's 供應商 step shows exactly the same controls,
/// so they live here once instead of being hand-copied into Panels.swift.
struct ProviderFields: View {
    @AppStorage(Prefs.provider) private var provider = Provider.deepseek.rawValue
    @AppStorage(Prefs.model) private var model = ""
    @AppStorage(Prefs.localBaseURL) private var baseURL = ""
    @AppStorage(Prefs.claudeBinPath) private var claudeBin = ""
    @State private var key = ""

    private var current: Provider { Provider(rawValue: provider) ?? .deepseek }

    var body: some View {
        Picker("Provider", selection: $provider) {
            ForEach(Provider.allCases) { Text($0.displayName).tag($0.rawValue) }
        }
        .frame(width: 320)

        TextField("Model", text: $model, prompt: Text(current.defaultModel))
            .frame(width: 320)

        if let detail = current.detail {
            Text(detail)
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }

        if current.needsBaseURL {
            TextField("Server URL", text: $baseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                .frame(width: 320)
        } else if current == .claudeCode {
            TextField("Path to the claude command", text: $claudeBin,
                      prompt: Text(Prefs.claudeBin ?? String(localized: "Not found, enter the full path")))
                .frame(width: 320)
            Text(Prefs.claudeBin == nil
                 ? "The claude command was not found. Install Claude Code, then enter the full path, for example ~/.local/bin/claude."
                 : "Leave this empty to find it automatically. Transcripts still go to Anthropic; they are billed to your subscription instead of an API key.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        } else {
            SecureField("API key", text: $key)
                .frame(width: 320)
                .onChange(of: key) { Keychain.set(key, for: Keychain.account(for: current)) }
                .task(id: provider) { key = Keychain.get(Keychain.account(for: current)) ?? "" }
            Text("The key is stored in the macOS Keychain. It is never written to preferences and never appears in the history or in an exported settings file.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct AIPage: View {
    @AppStorage(Prefs.recognitionEngine) private var engine = RecognitionEngine.speechTranscriber.rawValue
    @AppStorage(Prefs.locale) private var locale = "zh-TW"
    @State private var modes: [Mode] = []

    private var currentEngine: RecognitionEngine {
        RecognitionEngine(rawValue: engine) ?? .speechTranscriber
    }

    var body: some View {
        Section("Provider") { ProviderFields() }

        Section("Speech recognition") {
            Picker("Recognition engine", selection: $engine) {
                ForEach(RecognitionEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 460)
            Text(currentEngine.detail).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Picker("Recognition language", selection: $locale) {
                ForEach(recognitionLocales, id: \.code) { Text($0.name).tag($0.code) }
            }
            .frame(width: 320)
        }

        Section("Prompts") {
            Text("These are the same values as the prompt field under Modes; this page just lines them all up in one place.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            ForEach(modes) { PromptEditor(mode: $0) }
        }
        .task(id: Store.shared.revision) { modes = Store.shared.modes() }
    }
}

private struct PromptEditor: View {
    let mode: Mode
    @AppStorage private var text: String

    init(mode: Mode) {
        self.mode = mode
        _text = AppStorage(wrappedValue: "", Prefs.systemPrompt(mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Label(mode.displayName, systemImage: mode.sfSymbol)
                    .font(Theme.body).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Restore Default") { text = "" }
                    .disabled(text.isEmpty)
                    .font(Theme.caption)
            }
            TextEditor(text: Binding(get: { text.isEmpty ? Prefs.defaultPrompt(mode) : text },
                                     set: { text = $0 == Prefs.defaultPrompt(mode) ? "" : $0 }))
                .font(Theme.mono)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .background(Theme.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.stroke))
        }
    }
}

// MARK: - 權限

private struct PermissionsPage: View {
    @Bindable var state: AppState

    var body: some View {
        Section("Status") {
            PermissionRow(title: "Microphone", ok: state.micGranted, action: "Open Microphone Settings") {
                Permissions.openMicrophoneSettings()
            }
            PermissionRow(title: "Accessibility", ok: state.axTrusted, action: "Open Accessibility Settings") {
                Permissions.openAccessibilitySettings()
            }
            HStack(spacing: Theme.Space.m) {
                Button("Ask Again") { state.requestPermissions() }
                Button("Check Again") { state.refreshPermissions() }
            }
        }

        Section("The fn key") {
            Text("If holding fn brings up the emoji picker or switches input source, go to System Settings → Keyboard → Press Globe key to and choose Do Nothing, so OpenTalkType receives the full press and release.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("After a rebuild") {
            Text("This app is ad-hoc signed. Every rebuild looks like a different app to the system, so the Accessibility grant is really gone even though the checkbox in the list still looks ticked. When fn stops responding, remove OpenTalkType from that list and add it again.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { state.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let ok: Bool
    let action: LocalizedStringKey
    let open: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Circle().fill(ok ? Theme.success : Theme.warning).frame(width: 8, height: 8)
            Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
            Text(ok ? "Granted" : "Not granted").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(action, action: open)
        }
    }
}

// MARK: - 關於

private struct AboutPage: View {
    private let updater = Updater.shared
    @State private var auto = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("OpenTalkType").font(Theme.title).foregroundStyle(Theme.textPrimary)
            Text("Version \(version)").font(Theme.body).foregroundStyle(Theme.textSecondary)
            Text("Open-source software released under the MIT license. Speech recognition runs on device; only the transcript to be cleaned up is sent to the AI provider you configured.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Source code and issue tracker", destination: repositoryURL).font(Theme.body)

            if updater.isActive {
                Divider().padding(.vertical, Theme.Space.s)
                Toggle("Check for updates automatically", isOn: $auto)
                    .onChange(of: auto) { updater.automaticallyChecks = auto }
                Text("Updates are verified against a signing key built into this app, so an update cannot be swapped for someone else's build. The first install is a separate matter and is not signed; see the README.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            } else {
                Divider().padding(.vertical, Theme.Space.s)
                Text("Automatic updates are off in a development build. Move the app to Applications to enable them.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { auto = updater.automaticallyChecks }
    }
}

// MARK: - Section chrome

/// A titled block. SwiftUI's own Section only earns its keep inside a List or a Form, and both
/// bring styling this design does not want.
private struct Section<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: Theme.Space.m) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: Theme.Space.l)
        }
    }
}
