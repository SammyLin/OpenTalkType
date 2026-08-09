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
    ("zh-TW", "中文（台灣）"), ("zh-CN", "中文（中國）"), ("en-US", "英文（美國）"),
    ("en-GB", "英文（英國）"), ("ja-JP", "日文"), ("ko-KR", "韓文"),
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
        case .general: "一般"
        case .modes: "模式"
        case .trigger: "觸發"
        case .insertion: "插入文字"
        case .audio: "音訊"
        case .replacements: "取代規則"
        case .appRules: "App 規則"
        case .automation: "自動化"
        case .backup: "備份"
        case .ai: "AI"
        case .permissions: "權限"
        case .about: "關於"
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
                Text("設定")
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
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
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
        Section("浮動視窗") {
            Toggle("說話時顯示浮動視窗", isOn: $showHUD)
            Picker("位置", selection: $hudStyle) {
                Text("瀏海（貼齊螢幕最上緣）").tag("notch")
                Text("螢幕下方置中").tag("bottom")
            }
            .frame(width: 340)
            .disabled(!showHUD)
            Text("「瀏海」會從螢幕上緣長出一塊黑色面板，左邊是音量、右邊是即時辨識的字；沒有瀏海的螢幕會變成貼在選單列下方的膠囊。浮動視窗永遠不會搶走鍵盤焦點。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("其他") {
            Toggle("開始與結束時播放提示音", isOn: $sound)
            Toggle("登入時自動啟動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
        }

        Section("翻譯") {
            Picker("翻譯成", selection: $target) {
                ForEach(translateLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            .frame(width: 340)
            Text("所有勾了「翻譯」的模式都送到這個語言。")
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
        Section("模式") {
            Text("一個模式就是一組提示詞加一顆鍵。要改按鍵請到「觸發」。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            ForEach(modes) { m in
                ModeRow(mode: m, edit: { editing = m },
                        remove: m.builtIn ? nil : { Store.shared.deleteMode(m.id) })
            }
            Button {
                editing = Mode(id: "", displayName: "", subtitle: "", sfSymbol: "wand.and.stars",
                               prompt: "", usesSelection: false, translates: false, builtIn: false)
            } label: { Label("新增模式", systemImage: "plus") }
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
                Badge(symbol: "terminal", text: "指令")
                    .help("整理完會執行：\(shell)")
            }
            if override != .inherit {
                Badge(symbol: "return", text: override == .on ? "一定送出" : "不送出")
            }
            KeyCaps(mode.keyCaps)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("編輯這個模式")
            if let remove {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("刪除這個模式")
            }
        }
    }
}

private struct Badge: View {
    let symbol: String
    let text: String

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
                Text(isNew ? "新增模式" : "編輯模式")
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
                TextField("名稱", text: $draft.displayName).frame(width: 180)
                TextField("SF Symbol", text: $draft.sfSymbol, prompt: Text("wand.and.stars"))
                    .frame(width: 180)
                Image(systemName: draft.sfSymbol.isEmpty ? "wand.and.stars" : draft.sfSymbol)
                    .foregroundStyle(Theme.accent)
            }
            TextField("一句話說明", text: $draft.subtitle).frame(maxWidth: .infinity)
            Toggle("先讀取選取的文字，把說的話當成對它的指令", isOn: $draft.usesSelection)
            Toggle("翻譯成「設定 → 一般」選的目標語言", isOn: $draft.translates)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("提示詞").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            TextEditor(text: $promptText)
                .font(Theme.mono)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .background(Theme.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.stroke))
            Text("防注入規則、字典和中英空格規則會自動接在後面，不用自己寫。翻譯模式可用 {{TARGET}} 代表目標語言。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Picker("貼上後自動送出", selection: $autoSubmit) {
                ForEach(AutoSubmit.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 340)
            Text("覆蓋「插入文字」裡的全域設定。給聊天視窗用的模式適合設成「一定送出」，寫文件的模式設成「一定不送出」。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                Text("整理完要執行的指令（選填）")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            TextField("", text: $shell, prompt: Text("例如：tee -a ~/notes.md"))
                .font(Theme.mono)
                .frame(maxWidth: .infinity)
            Text("這一行會交給 /bin/sh 執行，以你的身分、擁有你所有的檔案權限，等同你自己在終端機裡輸入。只填你看得懂而且是自己寫的指令。")
                .font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text("整理後的文字會從標準輸入送進去，也可以用 $OT_TRANSCRIPT（整理後）、$OT_RAW（原始逐字稿）、$OT_MODE、$OT_APP。指令若有輸出，輸出會取代要貼上的文字；沒有輸出就照原本的文字貼上。工作目錄是家目錄，逾時 15 秒，非零結束會把它的錯誤訊息顯示出來。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            if !isNew {
                Button("回復預設提示詞") {
                    UserDefaults.standard.removeObject(forKey: Prefs.systemPrompt(draft))
                    promptText = Prefs.defaultPrompt(draft)
                }
            }
            Spacer()
            Button("取消") { dismiss() }
            Button("儲存") { save() }
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
        Section("按住還是鎖定") {
            Text("按住 fn 說話、放開結束，這個永遠有效。按 Esc 隨時取消，取消不貼上也不留紀錄。")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("連按兩下 fn 鎖定，不用一直按著", isOn: $handsFree)
            Text("開啟後多一個手勢：0.4 秒內連按兩下 fn，麥克風就會一直開著，說完再按一下 fn 結束。長篇口述時手不用一直壓在鍵盤上。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("每個模式的按鍵") {
            Text("全部以 fn 為底，設定的是「再多按哪一顆鍵」。同一顆鍵綁在兩個模式上時，清單裡靠前的那個會贏。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(modes) { HotkeyRow(mode: $0) }
        }

        Section("安靜就自動結束") {
            Toggle("停止說話一段時間後自動結束", isOn: $silenceStop)
            LabeledSlider(title: "音量門檻", value: $silenceLevel, range: 0.01...0.9, step: 0.01,
                          text: String(format: "%.2f", silenceLevel))
                .disabled(!silenceStop)
            LabeledSlider(title: "安靜多久", value: $silenceSeconds, range: 0.5...10, step: 0.1,
                          text: String(format: "%.1f 秒", silenceSeconds))
                .disabled(!silenceStop)
            Text("要先聽到有人說話才會開始倒數，所以按下去還在想句子的時候不會被切斷。判斷用的是平滑過的音量，句子中間的短暫停頓不會誤判。門檻調高比較容易被判定成安靜；吵雜環境請調高，安靜的房間可以調低。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: Store.shared.revision) { modes = Store.shared.modes() }
    }
}

private struct LabeledSlider: View {
    let title: String
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
        Section("貼上方式") {
            Picker("方式", selection: $method) {
                ForEach(PasteMethod.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 340)
            Text(current.detail)
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("貼上之後") {
            Toggle("在結尾補一個空白", isOn: $trailingSpace)
            Text("連續講好幾段時，下一段不用自己先按空白鍵。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Toggle("自動按 Return 送出", isOn: $autoSubmit)
            Text("聊天視窗用得上，文件編輯器會直接換行。用「貼上（⌘V）」時，只有在對方 App 真的把剪貼簿讀走之後才會送出 Return；讀不到就不送，寧可讓你自己按。個別模式可以在「模式」裡覆蓋這一項。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("安全輸入") { SecureInputRow() }
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
            Text(enabled ? "有 App 正在使用安全輸入" : "沒有 App 佔用安全輸入")
                .font(Theme.body).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        Text(enabled
             ? SecureInput.advice
             : "安全輸入開啟時，任何 App 都不能替你送出按鍵，所以貼上和模擬打字都會失效。密碼欄位和終端機的「安全鍵盤輸入」會開啟它。遇到時文字仍會進剪貼簿、紀錄和選單列，不會弄丟。")
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
        Section("輸入裝置") {
            HStack(spacing: Theme.Space.m) {
                Picker("麥克風", selection: $deviceUID) {
                    Text("系統預設").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                .frame(width: 340)
                Button("重新掃描") { devices = SpeechEngine.inputDevices }
            }
            Text("每次開始說話前都會重新套用，所以在這裡換裝置不用重開 App，下一次按 fn 就生效。指定的裝置被拔掉時會自動回到系統預設；錄音途中被拔掉則會直接結束這一次，已經聽到的字照樣整理、貼上並存進紀錄。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("錄音時") {
            Toggle("錄音時把其他聲音靜音", isOn: $mute)
            Text("把預設輸出裝置的音量降到 0，結束時還原。影片和音樂會繼續播，只是聽不見；也會一起蓋掉本 App 自己的提示音。錄音途中你手動調的音量會在結束時被還原掉。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("保留錄音") {
            HStack(spacing: Theme.Space.m) {
                Picker("保留", selection: $retention) {
                    Text("不保留").tag(0)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .frame(width: 220)
                Button("在 Finder 顯示") { NSWorkspace.shared.open(SpeechEngine.audioDir) }
            }
            Text("留下的是辨識器實際聽到的 16 kHz 單聲道音檔，一分鐘約 2 MB，可以在「紀錄」裡展開該筆播放。選「不保留」會停止錄音，並在下次啟動時把已經存下來的檔案一併刪掉——關掉這個功能卻留下一堆舊錄音才是真的糟糕。錄音只留在這台 Mac，不會上傳。")
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
        Section("取代規則") {
            Text("AI 整理完、貼上之前，照順序做一次字面取代。第 1 條的結果會再交給第 2 條，所以順序有意義。適合固定的錯字、公司內部寫法，或把「笑臉」換成你要的符號。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Text("啟用").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 30)
                Text("找").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 170, alignment: .leading)
                Text("換成").font(Theme.caption).foregroundStyle(Theme.textTertiary).frame(width: 170, alignment: .leading)
                Text("Aa 區分大小寫　.* 正規表示式").font(Theme.caption).foregroundStyle(Theme.textTertiary)
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
                Text("還沒有任何規則。").font(Theme.body).foregroundStyle(Theme.textTertiary)
            }
            Button { rules.append(ReplacementRule()) } label: { Label("新增規則", systemImage: "plus") }
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
                TextField("", text: $rule.find, prompt: Text("要被換掉的字"))
                    .font(Theme.mono).frame(width: 170)
                TextField("", text: $rule.replace, prompt: Text("換成（可留空＝刪掉）"))
                    .font(Theme.mono).frame(width: 170)
                Toggle("Aa", isOn: $rule.caseSensitive).toggleStyle(.button)
                    .help("區分大小寫")
                Toggle(".*", isOn: $rule.isRegex).toggleStyle(.button)
                    .help("把「找」當成正規表示式")
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMoveDown)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if regexBroken {
                Text("這個正規表示式無法編譯，這條規則會被整條略過，其他規則照常執行。")
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
        Section("依 App 或網站自動換模式") {
            Text("在這些 App 或網站裡按下快捷鍵時，直接改用指定的模式，不必記第二組按鍵。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("比對順序：App＋網站 → 只有網站 → 只有 App；同一層由網域較長的勝出，都沒中就用按鍵選的模式。網站只在瀏覽器最前面時才有意義，而且子網域也算（填 google.com 會命中 docs.google.com，但不會命中 evilgoogle.com）。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, _ in
                AppRuleRow(rule: $rules[index], modes: modes) { remove(index) }
            }
            if rules.isEmpty {
                Text("還沒有任何規則。").font(Theme.body).foregroundStyle(Theme.textTertiary)
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
            Button("選擇 App…", action: pickApp)
            Text(newAppName.isEmpty ? "任何 App" : newAppName)
                .font(Theme.body).foregroundStyle(newAppName.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: 130, alignment: .leading).lineLimit(1)
            TextField("", text: $newHost, prompt: Text("網站（選填）")).frame(width: 150)
            Picker("", selection: $newMode) {
                ForEach(modes) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden().frame(width: 130)
            Button("新增") {
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
        panel.prompt = "選擇"
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
                .help(rule.bundleID.isEmpty ? "任何 App" : rule.bundleID)
            TextField("", text: $rule.host, prompt: Text("任何網站"))
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
        guard !bundleID.isEmpty else { return "任何 App" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}

// MARK: - 自動化

private struct AutomationPage: View {
    @AppStorage(Prefs.urlSchemeEnabled) private var urlScheme = false
    @AppStorage(Prefs.mcpEnabled) private var mcp = false

    private static let urlActions = """
    opentalktype://start?mode=dictate    開始聽寫，指定模式
    opentalktype://stop                  結束這一次，整理並貼上
    opentalktype://cancel                取消這一次，不貼上也不留紀錄
    opentalktype://run?mode=dictate&text=…  跳過麥克風，直接整理這段文字
    opentalktype://paste-last            把上一次的結果再貼一次
    """

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
        Section("網址控制") {
            Toggle("允許 opentalktype:// 連結控制這個 App", isOn: $urlScheme)
            Text("預設關閉，因為任何網頁都能打開這種連結。開啟後可以用「捷徑」、Raycast、Keyboard Maestro 或一行 open 指令觸發聽寫。認得的動作：")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            CodeBlock(text: Self.urlActions)
            Text("mode 省略時視為 dictate；填了不存在的模式會整個不做事，而不是退回預設模式。run 的文字上限 20,000 字。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("MCP 伺服器") {
            Toggle("允許以 --mcp 提供 MCP 服務", isOn: $mcp)
            Text("讓 Claude Code 之類的用戶端讀取紀錄與字典、觸發聽寫、整理文字。預設關閉：任何能執行這個檔案的本機程式都連得上，等於把聽寫紀錄開放給它。開啟後把下面這段貼進用戶端的 MCP 設定：")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            CodeBlock(text: mcpSnippet)
            Text("走標準輸入輸出，不開任何連接埠。把 App 搬到別的位置之後，這段路徑要重新複製一次。")
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
            Button(copied ? "已複製" : "複製") {
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
        Section("匯出") {
            Button("匯出設定檔…", action: export)
            Text("包含模式與提示詞、字典、取代規則、App 規則和偏好設定。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text("不包含 API 金鑰。金鑰放在 macOS 鑰匙圈，這個功能從頭到尾不會去讀它，所以匯出的檔案可以直接寄給別人或放進版本控制。也不包含聽寫紀錄——那是你說過的話，不是設定。")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("匯入") {
            Toggle("一併套用檔案裡的偏好設定", isOn: $applyPrefs)
            Button("匯入設定檔…", action: importBackup)
            Text("已經存在的東西一律保留：同 id 的模式整個略過，字典只補上新的變體，重複的取代規則和 App 規則跳過。不會刪掉任何現有資料。偏好設定是唯一會被覆蓋的部分，所以上面那個開關可以關掉。")
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
            status = "已匯出到 \(url.lastPathComponent)。"
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "匯入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try Store.shared.importBackup(Data(contentsOf: url), applyPrefs: applyPrefs)
            failed = false
            status = "匯入完成：模式 \(s.modes)、詞彙 \(s.terms)、取代規則 \(s.replacements)、"
                + "App 規則 \(s.appRules)、偏好設定 \(s.prefs)，略過 \(s.skipped) 筆。"
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
        Picker("供應商", selection: $provider) {
            ForEach(Provider.allCases) { Text($0.displayName).tag($0.rawValue) }
        }
        .frame(width: 320)

        TextField("模型", text: $model, prompt: Text(current.defaultModel))
            .frame(width: 320)

        if let detail = current.detail {
            Text(detail)
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }

        if current.needsBaseURL {
            TextField("伺服器網址", text: $baseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                .frame(width: 320)
        } else if current == .claudeCode {
            TextField("claude 指令路徑", text: $claudeBin, prompt: Text(Prefs.claudeBin ?? "找不到，請填完整路徑"))
                .frame(width: 320)
            Text(Prefs.claudeBin == nil
                 ? "偵測不到 claude 指令。裝好 Claude Code 後填入完整路徑（例如 ~/.local/bin/claude）。"
                 : "留空即自動尋找。逐字稿仍會送到 Anthropic，只是走訂閱計費而非 API 金鑰。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        } else {
            SecureField("API 金鑰", text: $key)
                .frame(width: 320)
                .onChange(of: key) { Keychain.set(key, for: Keychain.account(for: current)) }
                .task(id: provider) { key = Keychain.get(Keychain.account(for: current)) ?? "" }
            Text("金鑰存在 macOS 鑰匙圈，不會寫進偏好設定，也不會出現在任何紀錄或匯出的設定檔裡。")
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
        Section("供應商") { ProviderFields() }

        Section("語音辨識") {
            Picker("辨識引擎", selection: $engine) {
                ForEach(RecognitionEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 460)
            Text(currentEngine.detail).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Picker("辨識語言", selection: $locale) {
                ForEach(recognitionLocales, id: \.code) { Text($0.name).tag($0.code) }
            }
            .frame(width: 320)
        }

        Section("提示詞") {
            Text("和「模式」裡的提示詞欄位是同一個值，這裡是把全部排在一起改。")
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
                Button("回復預設") { text = "" }
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
        Section("狀態") {
            PermissionRow(title: "麥克風", ok: state.micGranted, action: "開啟麥克風設定") {
                Permissions.openMicrophoneSettings()
            }
            PermissionRow(title: "輔助使用", ok: state.axTrusted, action: "開啟輔助使用設定") {
                Permissions.openAccessibilitySettings()
            }
            HStack(spacing: Theme.Space.m) {
                Button("重新要求權限") { state.requestPermissions() }
                Button("重新檢查") { state.refreshPermissions() }
            }
        }

        Section("fn 鍵") {
            Text("如果按住 fn 會跳出表情符號或切換輸入法，請到「系統設定 → 鍵盤 → 按下 🌐 鍵時」改成「不執行任何動作」，OpenTalkType 才收得到完整的按住與放開。")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("重新編譯之後") {
            Text("這個 App 用 ad-hoc 簽章。每次重新編譯，系統會把它當成另一個 App，於是「輔助使用」的授權其實已經失效，但清單裡的勾勾看起來還在。遇到 fn 沒反應時，把清單裡的 OpenTalkType 移除再加一次。")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { state.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let title: String
    let ok: Bool
    let action: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Circle().fill(ok ? Theme.success : Theme.warning).frame(width: 8, height: 8)
            Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
            Text(ok ? "已授權" : "未授權").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(action, action: open)
        }
    }
}

// MARK: - 關於

private struct AboutPage: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("OpenTalkType").font(Theme.title).foregroundStyle(Theme.textPrimary)
            Text("版本 \(version)").font(Theme.body).foregroundStyle(Theme.textSecondary)
            Text("以 MIT 授權釋出的開放原始碼軟體。語音辨識在裝置上完成，只有要整理的逐字稿會送到你自己設定的 AI 供應商。")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("原始碼與問題回報", destination: repositoryURL).font(Theme.body)
        }
    }
}

// MARK: - Section chrome

/// A titled block. SwiftUI's own Section only earns its keep inside a List or a Form, and both
/// bring styling this design does not want.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
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
