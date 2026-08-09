import AppKit
import OSLog
import SwiftUI
import UserNotifications

// Entry point, app state and the menu bar extra.
//
// File map, so nobody builds the same thing twice:
//   App.swift        this file -- entry, AppState, scenes, menu bar extra, self-test harness
//   Settings.swift   Prefs keys and Keychain
//   Theme.swift      colours, radii, spacing, KeyCap
//   SpeechEngine.swift  microphone and on-device recognition
//   LLM.swift        provider calls, prompt assembly, stripWrapper
//   Input.swift      HotkeyWatcher (fn tap), paste insertion, selection reading
//   Store.swift      SQLite history and dictionary
//   MainWindow.swift Home / History / Dictionary panes and the settings sheet
//   Panels.swift     floating HUD and onboarding

// MARK: - Entry

@main
enum Main {
    static func main() {
        // --selftest runs pure logic only: no UI, no permissions, no network. It exits.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        Prefs.registerDefaults()
        // --mcp never returns, and the URL handler has to be installed before NSApplication
        // exists: an open-url Apple Event can arrive during launch.
        Automation.bootstrap()
        #if DEBUG
        // --set-key <provider> <key> writes through the app's own Keychain code, so the item's
        // ACL names this binary. A key added with /usr/bin/security instead belongs to security,
        // and the app blocks on an authorisation dialog it cannot answer when run headlessly.
        if let i = CommandLine.arguments.firstIndex(of: "--set-key"),
           CommandLine.arguments.count > i + 2,
           let provider = Provider(rawValue: CommandLine.arguments[i + 1]) {
            Keychain.set(CommandLine.arguments[i + 2], for: Keychain.account(for: provider))
            let stored = Keychain.get(Keychain.account(for: provider)) ?? ""
            print(stored.isEmpty ? "FAIL: key not stored" : "OK: \(provider.rawValue) key stored (\(stored.count) chars)")
            exit(stored.isEmpty ? 1 : 0)
        }

        // --try-llm "<text>" exercises the real cleanup stage headlessly, so the provider wiring
        // can be checked without a microphone. Run it through `launchctl asuser` to get the same
        // environment a GUI launch would hand the subprocess.
        if let i = CommandLine.arguments.firstIndex(of: "--try-llm") {
            let text = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            let modeID = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "dictate"
            let mode = Mode.named(modeID) ?? .dictate
            print("MODE: \(mode.id) (\(mode.displayName))  modes=\(Mode.allCases.map(\.id).joined(separator: ","))")
            // Run the main run loop rather than blocking on a semaphore: anything the work hops
            // to the main actor for would deadlock against a blocked main thread.
            nonisolated(unsafe) var code: Int32 = 0
            Task {
                do {
                    let out = try await llmComplete(mode: mode, text: text, selection: nil,
                                                    terms: Store.shared.terms())
                    print("IN : \(text)")
                    print("OUT: \(out)")
                    let known = Store.shared.terms().flatMap { [$0.text] + $0.variants }
                    let terms = (try? await extractTerms(from: out, known: known)) ?? []
                    print("TERMS: \(terms.isEmpty ? "(none)" : terms.joined(separator: ", "))")
                } catch {
                    print("FAIL: \(error.localizedDescription)")
                    code = 1
                }
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            exit(code)
        }
        #endif
        OpenTalkTypeApp.main()
    }
}

/// Stage timings for the release-to-paste path, so "it felt slow" can be answered with numbers.
/// Read them with:
///   log stream --predicate 'subsystem == "ai.3mi.opentalktype"' --info
enum Timings {
    static let log = Logger(subsystem: "ai.3mi.opentalktype", category: "timing")

    #if DEBUG
    /// Also to a file: the unified log swallowed these during a real investigation, and a
    /// measurement you cannot read is not a measurement.
    /// ~/Library/Application Support/OpenTalkType/timing.log
    static func mark(_ s: String) {
        log.info("\(s, privacy: .public)")
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let url = URL.applicationSupportDirectory.appending(path: "OpenTalkType/timing.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #else
    static func mark(_ s: String) { log.info("\(s, privacy: .public)") }
    #endif
}

/// Race `work` against a deadline and take whichever lands first, WITHOUT waiting for the loser.
///
/// withTaskGroup cannot do this, which is the trap this replaces. A group does not return until
/// every child has finished, and `cancelAll()` is only a request -- SpeechAnalyzer's finalize
/// ignores cancellation entirely. So the timer fired, `next()` handed back the timeout value, and
/// the group then sat at its own exit forever waiting for the child that never ends. Every
/// "timeout" written that way in this app was decoration: observed as 整理中 counting past forty
/// minutes with the main thread completely idle.
///
/// The loser here is abandoned, still running, and that is the point.
func firstOf<T: Sendable>(seconds: Double, timeout: T,
                          _ work: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task.detached { let v = await work(); once.resume(v) }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(timeout)
        }
    }
}

/// A continuation may be resumed exactly once; two racers means two callers who each think they
/// won. The lock is the whole job.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: sending T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - Model

/// A user-definable action: a name, an icon, the key held with fn, and the prompt that runs.
///
/// This was three hardcoded cases. It is a record now because "one prompt bound to one hotkey"
/// is the whole product, and which prompts a person wants is not something we can enumerate for
/// them -- a translator into Japanese, a commit-message writer, a shell-command formatter are all
/// the same machinery with different words.
///
/// `id` is a stable slug: it is what history rows store and what the per-mode Prefs keys hang off,
/// so renaming a mode never orphans its data. The three seeded ids keep their original spellings
/// (dictate / translate / ask) so existing rows keep resolving.
struct Mode: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var subtitle: String
    var sfSymbol: String
    /// Empty means "use the built-in default for this id". Only built-ins have one.
    var prompt: String
    /// Read the frontmost app's selection first and treat the speech as an instruction on it.
    var usesSelection: Bool
    /// Translate into Prefs.translateTarget. Separate from the prompt so the language picker and
    /// the {{TARGET}} token keep working for user-made translate modes.
    var translates: Bool
    /// Seeded modes cannot be deleted, only edited. Deleting one would break the key caps on Home
    /// and leave history rows pointing at nothing.
    var builtIn: Bool

    /// Kept so history rows, Prefs key names and the latch all keep spelling a mode the same way.
    var rawValue: String { id }

    /// Every mode the user has, seeded ones first. Reads through Store, which caches.
    static var allCases: [Mode] { Store.shared.modes() }

    static func named(_ id: String) -> Mode? { allCases.first { $0.id == id } }

    /// A stand-in for a history row whose mode was deleted, so the row still renders.
    static func placeholder(_ id: String) -> Mode {
        Mode(id: id, displayName: id, subtitle: "", sfSymbol: "questionmark.circle",
             prompt: "", usesSelection: false, translates: false, builtIn: false)
    }

    /// Key caps for the current binding: always fn, plus whatever companion is bound.
    var keyCaps: [String] {
        ["fn"] + (Prefs.companion(self).keyCap.map { [$0] } ?? [])
    }

    // The seeded three, for the code paths that legitimately mean one specific mode. Everything
    // that iterates or dispatches should go through allCases / named(_:) instead.
    static var dictate: Mode { named("dictate") ?? placeholder("dictate") }
    static var translate: Mode { named("translate") ?? placeholder("translate") }
    static var ask: Mode { named("ask") ?? placeholder("ask") }
}

enum Phase: Sendable {
    case idle, listening, thinking
}

enum Pane: String, CaseIterable, Identifiable {
    case home, history, dictionary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: "首頁"
        case .history: "紀錄"
        case .dictionary: "字典"
        }
    }

    var sfSymbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, ai, permissions, about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: "一般"
        case .ai: "AI"
        case .permissions: "權限"
        case .about: "關於"
        }
    }

    var sfSymbol: String {
        switch self {
        case .general: "gearshape"
        case .ai: "brain"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {
    /// One instance, because the launch sequence runs from the app delegate while the scenes
    /// hold the same object.
    static let shared = AppState()

    // Session
    var phase: Phase = .idle
    var mode: Mode = .dictate          // the mode latched for the current session
    var partialText = ""               // live partial transcript for the HUD
    var micLevel: Float = 0            // 0...1, smoothed
    var lastResult = ""                // last inserted text, for 重新貼上
    var lastRaw = ""                   // last RAW transcript, so a failed cleanup is recoverable
    var lastError: String?

    // Navigation
    var pane: Pane = .home
    var showSettings = false
    var settingsTab: SettingsTab = .general
    var needsOnboarding = !UserDefaults.standard.bool(forKey: Prefs.hasOnboarded)

    // Health, shown on Home and in the 權限 pane
    var micGranted = false
    var axTrusted = false
    var modelReady = false
    var modelStatus = ""               // human text, e.g. "下載中 42%"

    /// The fn event tap holds this unretained through refcon, so AppState must own it strongly
    /// or the callback is a use-after-free.
    var hotkeys: HotkeyWatcher?

    /// Same story for the recogniser owned by SpeechEngine.swift.
    var speech: SpeechEngine?

    /// Snapshotted at record start, because by insert time the menu or the HUD could be frontmost.
    private var sessionApp: NSRunningApplication?
    private var sessionStart = Date()

    var menuBarSymbol: String {
        switch phase {
        case .idle: "waveform"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        }
    }

    var phaseLabel: String {
        switch phase {
        case .idle: "待命"
        case .listening: "聆聽中"
        case .thinking: "整理中"
        }
    }

    // MARK: Lifecycle

    /// Called once at launch: start the hotkey tap, refresh permissions, purge old history.
    func start() {
        guard speech == nil else { return }   // a Window .task can run more than once
        let engine = SpeechEngine(self)
        speech = engine
        purgeOldData()
        armHotkeys()
        refreshPermissions()
        Task { await engine.prepareModel() }
    }

    /// Launch housekeeping, in the order the data owns itself: transcripts first, then the
    /// recordings the surviving rows no longer claim, then the files on disk no row ever claimed
    /// (a row deleted from 紀錄 hands its path back, and nothing was there to unlink it).
    ///
    /// The store never touches the filesystem, which is why the unlink is here.
    private func purgeOldData() {
        let days = Prefs.audioRetentionDaysValue
        let orphans = Store.shared.purge(olderThanDays: Prefs.retentionDays)
            + Store.shared.purgeAudio(olderThanDays: days)
        Task.detached(priority: .utility) {
            for path in orphans { try? FileManager.default.removeItem(atPath: path) }
            SpeechEngine.purgeAudio(days: days)
        }
    }

    /// A tap that came back nil means no Accessibility grant, and a nil CFMachPort never heals
    /// itself, so poll and build it again the moment the checkbox is ticked.
    func armHotkeys() {
        let watcher = hotkeys ?? HotkeyWatcher(self)
        hotkeys = watcher
        guard !watcher.start() else { return }
        Permissions.pollUntilTrusted { [weak self] in
            guard let self else { return }
            self.hotkeys?.start()
            self.refreshPermissions()
        }
    }

    /// AXIsProcessTrusted reflects live TCC state in-process; the mic check is AVCaptureDevice.
    func refreshPermissions() {
        axTrusted = Permissions.axTrusted
        micGranted = Permissions.micGranted
    }

    /// Prompts for both permissions and, on an Accessibility grant, restarts the tap.
    func requestPermissions() {
        Task {
            Permissions.promptForAccessibility()
            _ = await Permissions.requestMic()
            refreshPermissions()
            armHotkeys()
        }
    }

    // MARK: Session

    /// Press. Runs inside the event tap callback, so it does nothing but latch -- the panel,
    /// the microphone and the dictionary lookup all happen on the hop after.
    func startDictation(_ mode: Mode) {
        guard phase == .idle, let speech else { return }
        self.mode = mode
        phase = .listening
        partialText = ""
        lastError = nil
        // Snapshot now, never at insert time: by then the HUD or the menu could be frontmost.
        sessionApp = NSWorkspace.shared.frontmostApplication
        sessionStart = Date()

        // Shown synchronously, NOT inside the Task: on a fast press-release the stop path's
        // hide() could otherwise run first and the show() land after it, leaving the panel on
        // screen forever with the app back at .idle.
        if Prefs.hudEnabled { HUD.shared.show(self) }

        Task {
            play("Tink")
            await applyAppRule()
            do {
                try await speech.start(phrases: Store.shared.terms().map(\.text))
            } catch {
                lastError = error.localizedDescription
                notify("無法開始錄音", error.localizedDescription)
                phase = .idle
                HUD.shared.hide()
            }
        }
    }

    /// "In this app, or on this site, use that mode." Runs on the hop after the press, never in
    /// the tap callback: reading the browser's URL is an Accessibility round trip.
    ///
    /// Only ever overrides the mode bound to bare fn. Holding a companion key is an explicit
    /// choice for this one sentence, and a rule quietly overruling it would be a bug the user
    /// cannot see.
    private func applyAppRule() async {
        guard phase == .listening, Prefs.companion(mode) == .none,
              let app = sessionApp, let bundle = app.bundleIdentifier else { return }
        // Off the main actor: an AX read waits on the other app's run loop, and this one is the
        // event tap's. Blocking it is what earns a .tapDisabledByTimeout.
        let pid = app.processIdentifier
        let host = await Task.detached(priority: .userInitiated) { frontmostHost(pid: pid) }.value
        // The session can have ended while that was in flight.
        guard phase == .listening, let picked = Store.shared.mode(forApp: bundle, host: host) else { return }
        mode = picked
    }

    /// Release: stop recording, clean up, insert, log.
    /// Abandon the session: microphone off, nothing transcribed, nothing pasted, nothing stored.
    /// Bound to Escape, because changing your mind mid-sentence is common and the alternative was
    /// letting the app paste something you did not want.
    func cancelDictation() {
        guard phase != .idle, let speech else { return }
        phase = .idle
        partialText = ""
        micLevel = 0
        HUD.shared.hide()
        play("Funk")
        Task { await speech.cancel() }
    }

    func stopDictation() {
        guard phase == .listening, let speech else { return }
        phase = .thinking
        play("Pop")
        let t0 = Date()
        Timings.mark("--- release ---")
        let mode = self.mode
        let app = sessionApp?.localizedName ?? ""
        let duration = Date().timeIntervalSince(sessionStart)

        Task {
            Timings.mark("task entered \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            // The microphone goes off first: reading the selection round-trips a ⌘C through the
            // other app and can take over a second, and none of that should still be recorded.
            let raw = await speech.stop()
            Timings.mark("stop() \(String(format: "%.2f", Date().timeIntervalSince(t0)))s chars=\(raw.count)")
            // ponytail: the selection is read on release rather than on press, because fn + space
            // latches .ask a few milliseconds AFTER fn-down -- at press time the mode is not known
            // yet. Upgrade path: read it on the .upgrade edge if a slow app ever makes this lag.
            let selection = mode.usesSelection ? await readSelection() : nil
            if mode.usesSelection {
                Timings.mark("selection \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            }
            await finish(t0: t0, raw: raw, mode: mode, selection: selection, app: app, duration: duration)
        }
    }

    /// Everything after the microphone: clean up, insert, persist, learn. The failure policy is
    /// the point of this function -- the spoken words always survive in clipboard plus history.
    private func finish(t0: Date = Date(), raw: String, mode: Mode, selection: String?,
                        app: String, duration: Double) async {
        defer {
            phase = .idle
            partialText = ""
            micLevel = 0
            HUD.shared.hide()
        }
        guard !raw.isEmpty else { return }
        lastRaw = raw
        let lang = mode.translates ? Prefs.translateTargetCode : nil

        let cleaned: String
        do {
            Timings.mark("llm start \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            cleaned = try await withCleanupDeadline {
                try await self.process(raw, mode: mode, selection: selection, app: app)
            }
        } catch {
            // Cleanup failed: paste nothing, put the raw words on the clipboard, say so, and
            // write the row anyway so it is recoverable from 紀錄.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(raw, forType: .string)
            lastResult = ""
            lastError = error.localizedDescription
            notify("整理失敗，原始逐字稿已複製到剪貼簿", error.localizedDescription)
            attachAudio(Store.shared.insert(mode: mode, raw: raw, cleaned: "", app: app,
                                            targetLang: lang, duration: duration))
            return
        }

        lastResult = cleaned
        Timings.mark("llm done \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        if await !insertText(cleaned) {
            lastError = "沒有「輔助使用」權限，無法自動貼上。文字已放在剪貼簿，請按 ⌘V。"
            notify("無法自動貼上", lastError ?? "")
        }
        attachAudio(Store.shared.insert(mode: mode, raw: raw, cleaned: cleaned, app: app,
                                        targetLang: lang, duration: duration,
                                        model: "\(Prefs.providerValue.displayName) · \(Prefs.modelValue)"))
        Timings.mark("inserted \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        if Prefs.autoAddTerms {
            // The cheap half: whatever the cleanup visibly corrected, with the garbled run as an
            // alias so the literal rewrite catches it next time.
            Store.shared.learnTerms(raw: raw, cleaned: cleaned)
            // The half that actually finds proper nouns. Detached and unawaited: the text is
            // already pasted, so this costs the user nothing, and a failure here must never
            // surface as a dictation error.
            Task.detached(priority: .background) {
                let known = await Store.shared.terms().flatMap { [$0.text] + $0.variants }
                guard let found = try? await extractTerms(from: cleaned, known: known),
                      !found.isEmpty else { return }
                // A term the recogniser already spelled correctly needs no dictionary entry: it
                // would only clutter the list and pad the prompt. This is what was filling the
                // dictionary with component, parent and live.
                let lowerRaw = raw.lowercased()
                for t in found where !lowerRaw.contains(t.lowercased()) {
                    await Store.shared.saveTerm(id: nil, text: t, variants: [], source: .auto)
                }
            }
        }
    }

    /// The kept recording belongs to the row the session just wrote. Written after the insert
    /// because the file is only finalised once the transcript exists, and skipped entirely when
    /// 保留錄音 is off -- SpeechEngine leaves lastAudioPath nil then.
    private func attachAudio(_ entryID: Int64) {
        guard let speech, let path = speech.lastAudioPath, !path.isEmpty else { return }
        Store.shared.setAudio(entry: entryID, path: path, seconds: speech.lastAudioSeconds)
    }

    /// Dictionary rewrite plus the LLM call. Onboarding's 試講一句 reuses this untouched, which
    /// is why it throws rather than swallowing: the test has to name the stage that failed.
    ///
    /// `app` only fills OT_APP for a mode with a shell command, hence the default.
    func process(_ raw: String, mode: Mode, selection: String?, app: String = "") async throws -> String {
        try await llmComplete(mode: mode, text: raw, selection: selection,
                              terms: Store.shared.terms(), app: app)
    }

    /// A last-resort ceiling on the cleanup stage. Each provider has its own timeout, but two
    /// separate hangs have already left the HUD stuck on 整理中 with no way back, so the invariant
    /// "the panel always comes down" gets its own guard rather than trusting every code path.
    private func withCleanupDeadline(_ work: @escaping @Sendable () async throws -> String) async throws -> String {
        let outcome = await firstOf(seconds: 90, timeout: Result<String, Error>.failure(
            LLMError("整理超過 90 秒沒有回應，已中止。原始逐字稿保留在剪貼簿。"))) {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// 重新貼上 -- paste lastResult again, or lastRaw when the cleanup failed.
    func repasteLast() async {
        let text = lastResult.isEmpty ? lastRaw : lastResult
        guard !text.isEmpty else { return }
        if await !insertText(text) {
            lastError = "沒有「輔助使用」權限，無法自動貼上。文字已放在剪貼簿，請按 ⌘V。"
        }
    }

    private func play(_ name: String) {
        guard UserDefaults.standard.bool(forKey: Prefs.soundFeedback) else { return }
        NSSound(named: name)?.play()
    }

    /// The only user-visible failure channel while another app is frontmost.
    func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}

// MARK: - Scenes

/// The launch sequence has to run whether or not the main window is restored: with it living in
/// a view's .task, quitting with the window closed -- or being launched at login -- left the fn
/// tap unarmed, retention unenforced and the model never prepared, with nothing reporting it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Automation.open(url) }
    }
}

struct OpenTalkTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window("OpenTalkType", id: "main") {
            MainWindowView(state: state)
                .environment(state)
                .task { state.start() }
        }
        .defaultSize(width: 940, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { state.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("開始設定", id: "onboarding") {
            OnboardingView(state: state)
                .environment(state)
        }
        .defaultSize(width: 620, height: 520)
        .windowResizability(.contentSize)

        MenuBarExtra("OpenTalkType", systemImage: state.menuBarSymbol) {
            MenuBarMenu(state: state)
        }
    }
}

/// Menu bar extra contents. Owned here -- no other file should build a menu.
private struct MenuBarMenu: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.phaseLabel)

        Divider()

        if state.phase == .listening {
            Button("停止") { state.stopDictation() }
        } else {
            ForEach(Mode.allCases) { mode in
                Button("開始\(mode.displayName)") { state.startDictation(mode) }
            }
        }

        Button("重新貼上") { Task { await state.repasteLast() } }
            .disabled(state.lastResult.isEmpty && state.lastRaw.isEmpty)

        Divider()

        Button("開啟主視窗") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("設定…") {
            state.showSettings = true
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("重新執行首次設定") { openWindow(id: "onboarding") }

        Divider()

        Button("結束 OpenTalkType") { NSApp.terminate(nil) }
    }
}

// MARK: - Self-test harness

/// `OpenTalkType.app/Contents/MacOS/OpenTalkType --selftest` runs every pure-logic check,
/// prints one line each, and exits 0 only if all passed. No UI, no permissions, no network.
/// The check that did not exist, which is why the bug shipped twice.
///
/// The task-group version of firstOf deadlocked exactly here: it would hand back the timeout value
/// and then block at the group's exit waiting for work that never finishes, so this function would
/// never return and the whole self-test would hang instead of failing. Blocking the calling thread
/// is deliberate -- the work runs detached on the cooperative pool, so nothing is starved.
func selfTestDeadline(_ c: SelfTest.Check) {
    func race<T: Sendable>(_ seconds: Double, _ timeout: T,
                           _ work: @escaping @Sendable () async -> T) -> T? {
        let box = SelfTestBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await firstOf(seconds: seconds, timeout: timeout, work)
            done.signal()
        }
        // Generous: this is asserting that a 0.2s deadline fires, not how fast the machine is.
        return done.wait(timeout: .now() + 5) == .success ? box.value : nil
    }

    let started = Date()
    let late = race(0.2, "timeout") {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        return "work"
    }
    c(late == "timeout", "deadline/abandons-work-that-outlives-it",
      "expected the timeout value, got \(String(describing: late))")
    c(Date().timeIntervalSince(started) < 3, "deadline/returns-without-waiting-for-the-loser",
      "the racer waited for the abandoned work instead of walking away")

    let quick = race(5, "timeout") { "work" }
    c(quick == "work", "deadline/fast-work-wins",
      "expected the work's value, got \(String(describing: quick))")
}

private final class SelfTestBox<T>: @unchecked Sendable {
    var value: T?
}

enum SelfTest {
    /// (ok, name, detail) -- detail is printed only on failure and should read "expected X, got Y".
    typealias Check = (Bool, String, String) -> Void

    /// Each implementer appends exactly one entry, and touches nothing else in this file.
    private static var suites: [(Check) -> Void] {[
        selfTestSpeech,
        selfTestDictionary,
        selfTestStore,
        selfTestHotkey,
        selfTestLLM,
        selfTestPanels,
        selfTestAutomation,
        selfTestDeadline,
        // SELFTEST-SUITES
    ]}

    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func run() -> Never {
        let check: Check = { ok, name, detail in
            if ok {
                passed += 1
                print("PASS \(name)")
            } else {
                failed += 1
                print("FAIL \(name): \(detail)")
            }
        }
        for suite in suites { suite(check) }
        print("SELFTEST: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
