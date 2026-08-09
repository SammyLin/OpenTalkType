import AppIntents
import AppKit
import Foundation

// The automation surface: a URL scheme, App Intents, and an MCP server over stdio.
//
// Three doors into the same two functions -- `llmComplete` and `Store.shared` -- and nothing
// here reimplements either. The point of the file is that other software can drive dictation:
// Shortcuts, Raycast, Stream Deck, a shell script, or an agent speaking MCP.
//
// Trust boundary. A URL can be fired by any web page the user visits, and the MCP server hands
// a local process the user's entire dictation history. Both are therefore OFF by default and
// every parameter that crosses either boundary is validated here, once, in `URLCommand.parse`
// and in the tools/call argument checks. Nothing downstream re-validates.
//
// Entry points:
//   OpenTalkType --mcp     headless JSON-RPC on stdio, from Main.main via `Automation.bootstrap()`
//   opentalktype://...     AppDelegate.application(_:open:) -> `Automation.open`

// MARK: - Preferences owned by this file
//
// Deliberately unregistered in Prefs.registry: an unregistered bool reads false, and false is
// exactly the default both of these must have.
extension Prefs {
    /// Allow opentalktype:// URLs to drive the app. Off by default -- any web page can open one.
    static let urlSchemeEnabled = "urlSchemeEnabled"
    /// Allow `--mcp` to serve. Off by default -- it exposes history and the dictionary to any
    /// local process that can exec the binary.
    static let mcpEnabled = "mcpEnabled"
}

// MARK: - Bootstrap

enum Automation {
    static let scheme = "opentalktype"

    /// Ceiling on any text arriving from outside the app. A URL is a page-triggered channel and
    /// an LLM call costs money; 20k characters is far past any real dictation and far short of
    /// anything worth billing.
    static let maxTextLength = 20_000

    /// Called from `Main.main` immediately after `Prefs.registerDefaults()`, before the SwiftUI
    /// app starts. Returns normally in GUI mode; never returns in --mcp mode.
    static func bootstrap() {
        if CommandLine.arguments.contains("--mcp") { MCP.serve() }
        installURLHandler()
    }

    // MARK: URL scheme

    /// `.onOpenURL` would need the main window to exist, and this app spends most of its life
    /// with no window open at all. The Apple Event handler is the layer underneath it and works
    /// from `main()` onward.
    private static func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            urlHandler, andSelector: #selector(URLHandler.handle(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// NSAppleEventManager does not retain its handler. nonisolated(unsafe) because an NSObject
    /// is not Sendable: it is written once at launch and only ever called back on the main
    /// thread, which is where Apple Events are delivered.
    nonisolated(unsafe) private static let urlHandler = URLHandler()

    private final class URLHandler: NSObject {
        @MainActor
        @objc func handle(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: string) else { return }
            Automation.open(url)
        }
    }

    /// Parsed form of an `opentalktype://` URL. Nothing outside `parse` builds one, so an
    /// existing value is by construction a validated command.
    enum URLCommand: Equatable {
        case start(modeID: String)
        case stop
        case cancel
        case run(modeID: String, text: String)
        case pasteLast
    }

    /// The whole validation surface for the URL scheme. `modes` is injected rather than read
    /// from `Mode.allCases` so the self-test never depends on the user's database.
    ///
    /// Returns nil for anything unrecognised or malformed, and the caller does nothing with nil.
    /// An unknown host is not an error worth surfacing: it is most likely a newer build's verb
    /// or a typo in someone's script, and a dialog per stray link is its own attack.
    static func parse(_ url: URL, modes: [String]) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // opentalktype://stop puts the verb in `host`; opentalktype:stop puts it in `path`.
        let verb = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // queryItems percent-decodes for us; trim so ?mode=%20dictate is not a different mode.
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Absent means "the default mode". Present but unknown is a caller bug, and silently
        // dictating into the wrong mode is worse than doing nothing.
        func modeID() -> String? {
            let id = value("mode") ?? "dictate"
            return modes.contains(id) ? id : nil
        }

        switch verb {
        case "start":
            guard let id = modeID() else { return nil }
            return .start(modeID: id)
        case "stop":
            return .stop
        case "cancel":
            return .cancel
        case "paste-last", "pastelast":
            return .pasteLast
        case "run":
            guard let id = modeID(), let text = value("text"),
                  !text.isEmpty, text.count <= maxTextLength else { return nil }
            return .run(modeID: id, text: text)
        default:
            return nil
        }
    }

    @MainActor
    static func open(_ url: URL) {
        guard UserDefaults.standard.bool(forKey: Prefs.urlSchemeEnabled) else {
            // Once per launch, because the trigger is a link and a hostile page can fire
            // thousands. Silence here would look identical to a broken app to the one user who
            // followed a link on purpose.
            guard !warnedAboutDisabledScheme else { return }
            warnedAboutDisabledScheme = true
            AppState.shared.notify("已忽略 opentalktype:// 連結",
                                   "網址控制預設關閉。要啟用請到「設定 → 自動化」勾選「允許 opentalktype:// 連結控制這個 App」。")
            return
        }
        guard let command = parse(url, modes: Mode.allCases.map(\.id)) else { return }
        let state = AppState.shared
        switch command {
        case .start(let id):
            guard let mode = Mode.named(id) else { return }
            state.startDictation(mode)
        case .stop:
            state.stopDictation()
        case .cancel:
            state.cancelDictation()
        case .pasteLast:
            Task { await state.repasteLast() }
        case .run(let id, let text):
            guard let mode = Mode.named(id) else { return }
            Task { await runPipeline(mode: mode, text: text) }
        }
    }

    @MainActor private static var warnedAboutDisabledScheme = false

    /// `://run` -- the cleanup stage without the microphone, then the same insert-and-log tail
    /// the dictation path uses. `AppState.finish` is private and half of it is about the audio
    /// session, so the three lines that matter are repeated rather than the whole thing exposed.
    ///
    /// The failure policy is the app's, not this file's: the words go to the clipboard, to
    /// history and to the menu, whatever happened.
    @MainActor
    static func runPipeline(mode: Mode, text: String) async {
        let state = AppState.shared
        state.lastRaw = text
        do {
            let cleaned = try await state.process(text, mode: mode, selection: nil)
            state.lastResult = cleaned
            if await !insertText(cleaned) {
                state.notify("無法自動貼上", "文字已放在剪貼簿，請按 ⌘V。")
            }
            Store.shared.insert(mode: mode, raw: text, cleaned: cleaned, app: "URL",
                                targetLang: mode.translates ? Prefs.translateTargetCode : nil,
                                model: "\(Prefs.providerValue.displayName) · \(Prefs.modelValue)")
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            state.lastResult = ""
            state.lastError = error.localizedDescription
            state.notify("整理失敗，原文已複製到剪貼簿", error.localizedDescription)
            Store.shared.insert(mode: mode, raw: text, cleaned: "", app: "URL")
        }
    }
}

// MARK: - App Intents
//
// The cheapest automation surface macOS has: one struct each and the app appears in Shortcuts,
// Raycast, Stream Deck, Automator and Spotlight. No opt-in gate -- an intent only ever runs
// because a person built it into a shortcut and pressed it.

/// The mode ids the user actually has, so the Shortcuts editor shows a picker instead of a
/// free-text field that silently does nothing when misspelt.
struct ModeIDOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { Mode.allCases.map(\.id) }
}

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "開始聽寫"
    static let description = IntentDescription("開始一段語音輸入。放開 fn 或執行「停止聽寫」後，整理好的文字會貼到游標位置。")
    /// Never true: bringing OpenTalkType to the front would steal focus from the app the user
    /// is dictating into, and the text is pasted wherever the cursor was.
    static let openAppWhenRun = false

    @Parameter(title: "模式", optionsProvider: ModeIDOptions())
    var modeID: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.startDictation(modeID.flatMap(Mode.named) ?? .dictate)
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "停止聽寫"
    static let description = IntentDescription("結束目前這段語音輸入，整理後貼上。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.stopDictation()
        return .result()
    }
}

struct CancelDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "取消聽寫"
    static let description = IntentDescription("放棄目前這段語音輸入：不轉錄、不貼上、不留紀錄。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.cancelDictation()
        return .result()
    }
}

struct CleanUpTextIntent: AppIntent {
    static let title: LocalizedStringResource = "整理這段文字"
    static let description = IntentDescription("把一段文字送進和聽寫相同的整理流程，回傳整理後的文字。不會貼上。")
    static let openAppWhenRun = false

    @Parameter(title: "文字")
    var text: String

    @Parameter(title: "模式", optionsProvider: ModeIDOptions())
    var modeID: String?

    /// Not @MainActor: this is the one intent that can legitimately run while a dictation is in
    /// flight, and it touches neither AppState nor the audio session.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(value: "") }
        guard trimmed.count <= Automation.maxTextLength else {
            throw LLMError("文字超過 \(Automation.maxTextLength) 字，請先拆短。")
        }
        let mode = modeID.flatMap(Mode.named) ?? .dictate
        return .result(value: try await llmComplete(mode: mode, text: trimmed,
                                                    selection: nil, terms: Store.shared.terms()))
    }
}

struct AddDictionaryTermIntent: AppIntent {
    static let title: LocalizedStringResource = "加入字典詞彙"
    static let description = IntentDescription("把一個詞加進字典。「常被聽成」的寫法會在整理前先被改寫成正確拼法。")
    static let openAppWhenRun = false

    @Parameter(title: "詞彙")
    var term: String

    @Parameter(title: "常被聽成")
    var aliases: [String]?

    func perform() async throws -> some IntentResult {
        let name = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LLMError("詞彙不能是空的。") }
        Store.shared.saveTerm(id: nil, text: name,
                              variants: (aliases ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                              source: .manual)
        return .result()
    }
}

struct OpenTalkTypeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDictationIntent(),
                    phrases: ["用 \(.applicationName) 開始聽寫", "\(.applicationName) 開始說話"],
                    shortTitle: "開始聽寫", systemImageName: "waveform")
        AppShortcut(intent: StopDictationIntent(),
                    phrases: ["用 \(.applicationName) 停止聽寫", "\(.applicationName) 說完了"],
                    shortTitle: "停止聽寫", systemImageName: "stop.circle")
        AppShortcut(intent: CancelDictationIntent(),
                    phrases: ["用 \(.applicationName) 取消聽寫", "\(.applicationName) 不要了"],
                    shortTitle: "取消聽寫", systemImageName: "xmark.circle")
        AppShortcut(intent: CleanUpTextIntent(),
                    phrases: ["用 \(.applicationName) 整理文字", "\(.applicationName) 整理這段話"],
                    shortTitle: "整理文字", systemImageName: "text.badge.checkmark")
        AppShortcut(intent: AddDictionaryTermIntent(),
                    phrases: ["用 \(.applicationName) 加入字典詞彙", "\(.applicationName) 記住這個詞"],
                    shortTitle: "加入字典", systemImageName: "character.book.closed")
    }
}

// MARK: - MCP server
//
// `OpenTalkType --mcp` is a headless adapter over the same Store and LLM code the GUI uses:
// no window, no permission prompt, no microphone, no AppState. That last one is load-bearing --
// see `blockingCall`.
//
// Transport is the MCP stdio transport: one JSON-RPC 2.0 message per line on stdout, logs on
// stderr. JSONSerialization escapes newlines inside strings, so one object can never span two
// lines and the framing holds without a length header.

enum MCP {
    private static let protocolVersion = "2025-06-18"

    /// The real stdout, moved out of the way. Anything in the app that calls `print` -- Store
    /// logs a failed sqlite prepare -- would otherwise inject a bare line into the protocol and
    /// desynchronise the client. fd 1 now points at stderr, so a stray print is just a log line.
    private static let out: FileHandle = {
        let saved = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        return FileHandle(fileDescriptor: saved, closeOnDealloc: false)
    }()

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[opentalktype] \(message)\n".utf8))
    }

    static func serve() -> Never {
        _ = out                                   // claim stdout before anything can print
        guard UserDefaults.standard.bool(forKey: Prefs.mcpEnabled) else {
            log("MCP 伺服器未啟用。請開啟 OpenTalkType，到「設定 → 自動化」勾選「允許以 --mcp 提供 MCP 服務」。")
            exit(2)
        }
        log("ready on stdio, protocol \(protocolVersion)")
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(),
                      "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let response = handle(request) { send(response) }
        }
        exit(0)                                   // stdin closed: the client went away
    }

    /// One request in, one response out, or nil for a notification. Pure apart from the four
    /// tool bodies, which is what makes the protocol layer self-testable.
    static func handle(_ request: [String: Any]) -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        // No id member at all means a notification, and a notification is never answered --
        // not even to say the method was unknown.
        guard let id = request["id"].flatMap({ $0 is NSNull ? nil : $0 }) else { return nil }

        func ok(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }

        switch method {
        case "initialize":
            return ok([
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "opentalktype",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                ],
            ])

        case "ping":
            return ok([String: Any]())

        case "tools/list":
            return ok(["tools": toolSchemas])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else {
                return fail(-32602, "缺少 name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard toolSchemas.contains(where: { $0["name"] as? String == name }) else {
                return fail(-32602, "沒有這個工具：\(name)")
            }
            return ok(call(name, arguments))

        default:
            return fail(-32601, "不支援的方法：\(method)")
        }
    }

    // MARK: Tools

    private static func string(_ args: [String: Any], _ key: String) -> String {
        (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Descriptions are in English on purpose: they are read by a model, not by the user, and
    /// every published MCP server the clients were trained against is in English.
    ///
    /// Built one schema per property, not as one nested literal -- a heterogeneous dictionary
    /// literal four levels deep is where the Swift type-checker gives up.
    /// nonisolated(unsafe) because `Any` is not Sendable. Built once and never mutated.
    nonisolated(unsafe) static let toolSchemas: [[String: Any]] = {
        func tool(_ name: String, _ description: String,
                  _ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }
        func field(_ type: String, _ description: String) -> [String: Any] {
            ["type": type, "description": description]
        }
        var stringList = field("array", "Spellings the recogniser produces instead.")
        stringList["items"] = ["type": "string"]

        return [
            tool("opentalktype_clean_text",
                 "Run OpenTalkType's dictation cleanup pipeline over supplied text: applies the user dictionary, then the mode's prompt. Returns the cleaned text only.",
                 ["text": field("string", "The text to clean up."),
                  "mode": field("string", "Mode id, e.g. dictate / translate / ask. Defaults to dictate.")],
                 required: ["text"]),
            tool("opentalktype_history_search",
                 "Search the user's dictation history, newest first.",
                 ["query": field("string", "Substring to match against the raw and cleaned text. Omit to list everything."),
                  "mode": field("string", "Restrict to one mode id."),
                  "limit": field("integer", "Maximum rows, 1-200, default 20.")]),
            tool("opentalktype_add_term",
                 "Add a term to the user dictionary. Aliases are the mis-recognitions rewritten to the term before cleanup runs.",
                 ["term": field("string", "The correct spelling."), "aliases": stringList],
                 required: ["term"]),
            tool("opentalktype_list_modes",
                 "List the modes this user has defined, with their ids.",
                 [:]),
        ]
    }()

    private static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        switch name {
        case "opentalktype_clean_text":
            let text = string(args, "text")
            guard !text.isEmpty else { return result("text 不能是空的", isError: true) }
            guard text.count <= Automation.maxTextLength else {
                return result("text 超過 \(Automation.maxTextLength) 字", isError: true)
            }
            let modeID = string(args, "mode")
            guard let mode = modeID.isEmpty ? Mode.dictate : Mode.named(modeID) else {
                return result("沒有這個模式：\(modeID)", isError: true)
            }
            switch blockingCall({ try await llmComplete(mode: mode, text: text, selection: nil,
                                                        terms: Store.shared.terms()) }) {
            case .success(let cleaned): return result(cleaned)
            case .failure(let error): return result(error.localizedDescription, isError: true)
            }

        case "opentalktype_history_search":
            let modeID = string(args, "mode")
            if !modeID.isEmpty, Mode.named(modeID) == nil {
                return result("沒有這個模式：\(modeID)", isError: true)
            }
            let limit = min(max(args["limit"] as? Int ?? 20, 1), 200)
            let rows = Store.shared.entries(mode: modeID.isEmpty ? nil : Mode.named(modeID),
                                            search: string(args, "query")).prefix(limit)
            let iso = ISO8601DateFormatter()
            return result(json(rows.map { entry -> [String: Any] in
                ["id": entry.id,
                 "date": iso.string(from: entry.date),
                 "mode": entry.mode.id,
                 "text": entry.cleaned.isEmpty ? entry.raw : entry.cleaned,
                 "app": entry.app]
            }))

        case "opentalktype_add_term":
            let term = string(args, "term")
            guard !term.isEmpty else { return result("term 不能是空的", isError: true) }
            let aliases = (args["aliases"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            Store.shared.saveTerm(id: nil, text: term, variants: aliases, source: .manual)
            return result("已加入：\(term)")

        case "opentalktype_list_modes":
            return result(json(Mode.allCases.map { mode -> [String: Any] in
                ["id": mode.id, "name": mode.displayName, "subtitle": mode.subtitle,
                 "usesSelection": mode.usesSelection, "translates": mode.translates]
            }))

        default:
            return result("沒有這個工具：\(name)", isError: true)
        }
    }

    // MARK: Plumbing

    private static func result(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.withoutEscapingSlashes]) else { return }
        out.write(data)
        out.write(Data([0x0A]))
    }

    /// Blocks the main thread until an async call finishes, because the read loop is a plain
    /// blocking `readLine` and MCP is strictly one request at a time over stdio.
    ///
    /// Safe only because no tool touches AppState: the work runs on the cooperative pool, and a
    /// hop to the main actor from there would deadlock against this very wait. If a tool ever
    /// needs the GUI's state, this has to become a run-loop pump like --try-llm uses.
    private static func blockingCall(
        _ work: @escaping @Sendable () async throws -> String) -> Result<String, Error> {
        // A box rather than a captured local: Swift 6 will not let a closure that mutates an
        // inout-captured variable cross an isolation boundary, however unsafe you promise it is.
        // The semaphore is the synchronisation, so @unchecked is honest here.
        final class Box: @unchecked Sendable {
            var outcome: Result<String, Error> = .failure(LLMError("沒有回應"))
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.outcome = .success(try await work()) } catch { box.outcome = .failure(error) }
            done.signal()
        }
        done.wait()
        return box.outcome
    }
}

// MARK: - Self-test

func selfTestAutomation(_ c: SelfTest.Check) {
    // URL parsing. The mode list is injected, so these never depend on the user's database.
    let modes = ["dictate", "translate"]
    func parse(_ s: String) -> Automation.URLCommand? {
        URL(string: s).flatMap { Automation.parse($0, modes: modes) }
    }

    c(parse("opentalktype://start?mode=translate") == .start(modeID: "translate"),
      "url/start-with-mode", "expected .start(translate), got \(String(describing: parse("opentalktype://start?mode=translate")))")
    c(parse("opentalktype://start") == .start(modeID: "dictate"),
      "url/start-defaults-to-dictate", "expected .start(dictate)")
    // An unknown mode must not fall back to dictating into the wrong prompt.
    c(parse("opentalktype://start?mode=nope") == nil, "url/rejects-unknown-mode", "expected nil")
    c(parse("opentalktype://stop") == .stop, "url/stop", "expected .stop")
    c(parse("opentalktype://cancel") == .cancel, "url/cancel", "expected .cancel")
    c(parse("opentalktype://paste-last") == .pasteLast, "url/paste-last", "expected .pasteLast")

    // Percent-encoded Chinese has to survive, and whitespace around a value must not change it.
    let run = parse("opentalktype://run?mode=dictate&text=%E4%BB%8A%E5%A4%A9%E5%A4%A9%E6%B0%A3%E5%BE%88%E5%A5%BD")
    c(run == .run(modeID: "dictate", text: "今天天氣很好"), "url/run-decodes-utf8",
      "expected 今天天氣很好, got \(String(describing: run))")
    c(parse("opentalktype://run?text=hi") == .run(modeID: "dictate", text: "hi"),
      "url/run-defaults-to-dictate", "expected .run(dictate, hi)")
    c(parse("opentalktype://run?mode=dictate") == nil, "url/run-requires-text", "expected nil")
    c(parse("opentalktype://run?mode=dictate&text=%20%20") == nil, "url/run-rejects-blank-text",
      "expected nil")
    let huge = String(repeating: "a", count: Automation.maxTextLength + 1)
    c(parse("opentalktype://run?text=\(huge)") == nil, "url/run-rejects-oversized-text",
      "expected nil")

    c(parse("opentalktype://quit") == nil, "url/ignores-unknown-host", "expected nil")
    c(parse("https://example.com/start?mode=dictate") == nil, "url/rejects-other-scheme",
      "expected nil")

    // MCP protocol layer.
    func rpc(_ method: String, id: Any? = 1, params: [String: Any]? = nil) -> [String: Any]? {
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { request["id"] = id }
        if let params { request["params"] = params }
        return MCP.handle(request)
    }

    let initialize = rpc("initialize")?["result"] as? [String: Any]
    c(initialize?["protocolVersion"] as? String != nil, "mcp/initialize-reports-version",
      "expected a protocolVersion in the result")
    c((initialize?["capabilities"] as? [String: Any])?["tools"] != nil,
      "mcp/initialize-advertises-tools", "expected a tools capability")

    let listed = (rpc("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    let names = Set(listed.compactMap { $0["name"] as? String })
    c(names == ["opentalktype_clean_text", "opentalktype_history_search",
                "opentalktype_add_term", "opentalktype_list_modes"],
      "mcp/tools-list", "expected the four tools, got \(names.sorted())")
    // Every tool needs a schema, or a client cannot call it at all.
    c(listed.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" },
      "mcp/tools-have-object-schemas", "expected every tool to declare an object inputSchema")

    // A notification is never answered, not even to reject it.
    c(rpc("notifications/initialized", id: nil) == nil, "mcp/notification-gets-no-reply",
      "expected nil")
    c(rpc("does/not/exist", id: nil) == nil, "mcp/unknown-notification-gets-no-reply",
      "expected nil")

    let unknown = rpc("does/not/exist")?["error"] as? [String: Any]
    c(unknown?["code"] as? Int == -32601, "mcp/unknown-method-is-32601",
      "expected -32601, got \(String(describing: unknown?["code"]))")

    // An unknown tool must be rejected before anything is dispatched, so this never blocks.
    let badTool = rpc("tools/call", params: ["name": "rm_rf", "arguments": [String: Any]()])?["error"] as? [String: Any]
    c(badTool?["code"] as? Int == -32602, "mcp/unknown-tool-is-32602",
      "expected -32602, got \(String(describing: badTool?["code"]))")
    let noName = rpc("tools/call", params: [String: Any]())?["error"] as? [String: Any]
    c(noName?["code"] as? Int == -32602, "mcp/tools-call-requires-name", "expected -32602")

    // The id round-trips verbatim: a client that sends a string id must get a string id back.
    c(rpc("ping", id: "abc")?["id"] as? String == "abc", "mcp/echoes-string-id", "expected abc")
}
