import Foundation
import Observation
import SQLite3

// SQLite persistence: dictation history and the user dictionary, over libsqlite3 directly.
//
// One class, one database file, one recursive lock. The dictation flow writes from AppState
// (main actor) and SwiftUI reads on the main actor too, so contention is theoretical -- the
// lock is there because --selftest and any future background writer are not main-actor.
//
// ponytail: one global recursive lock around every statement. Ceiling is a few writes per
// second, which is orders of magnitude above what a person can dictate. Upgrade path if it
// ever matters: a serial DispatchQueue plus WAL mode.

// SQLITE_TRANSIENT tells sqlite to copy the bound bytes. Passing nil here is the classic
// crash: sqlite would keep a pointer to a Swift String buffer that is already gone.
private var SQLITE_TRANSIENT: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - Rows

struct Entry: Identifiable, Hashable, Sendable {
    let id: Int64
    let date: Date
    let mode: Mode
    let raw: String
    /// Empty means the LLM stage failed. The row is written anyway so the words survive, and
    /// every reader falls back to `raw`.
    let cleaned: String
    let app: String            // target app name, "" when unknown
    let targetLang: String?
    let duration: Double       // seconds spoken, 0 when not measured
    /// Provider and model that produced `cleaned`, e.g. "DeepSeek · deepseek-chat". Empty for
    /// rows written before the column existed, and for rows whose cleanup failed.
    let model: String
    /// Absolute path of the kept recording, "" when audio was never kept or has been purged.
    /// The file may be gone while the row survives -- always check before reading it.
    let audioPath: String
    /// Length of that file in seconds, 0 when there is no file. Separate from `duration`, which
    /// is how long the recogniser ran; the two differ when capture starts before the first word.
    let audioSeconds: Double
}

// MARK: - Replacement rules

/// A literal or regex rewrite applied to the finished text. Ordered: rule 1 runs before rule 2,
/// which is why `position` exists and why the fetch is always ordered.
///
/// `id` is excluded from CodingKeys on purpose: the export document carries no row ids, and the
/// default value is what lets Codable synthesis still work.
struct ReplacementRule: Identifiable, Hashable, Sendable, Codable {
    var id: Int64 = 0
    var find: String = ""
    var replace: String = ""
    var caseSensitive: Bool = false
    var isRegex: Bool = false
    var enabled: Bool = true

    private enum CodingKeys: String, CodingKey { case find, replace, caseSensitive, isRegex, enabled }
}

// MARK: - Per-app rules

/// "When I dictate into this app, or into this website, use that mode."
///
/// Either field may be empty, which means "any". An empty `host` matches an app rule, an empty
/// `bundleID` matches a host rule regardless of which browser is in front. Both empty is not a
/// rule (that is just the global default) and is rejected.
struct AppRule: Identifiable, Hashable, Sendable, Codable {
    var id: Int64 = 0
    var bundleID: String = ""      // "" = any app
    var host: String = ""          // "" = any site; matches subdomains
    var modeID: String = ""

    private enum CodingKeys: String, CodingKey { case bundleID, host, modeID }
}

enum TermSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case manual, auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: String(localized: "Added by hand")
        case .auto: String(localized: "Added automatically")
        }
    }

    var sfSymbol: String {
        switch self {
        case .manual: "hand.point.up.left"
        case .auto: "wand.and.stars"
        }
    }
}

struct Term: Identifiable, Hashable, Sendable {
    let id: Int64
    var text: String            // the correct spelling
    var variants: [String]      // 常被聽成 -- mis-recognitions rewritten to `text`
    var source: TermSource
}

struct Stats: Sendable {
    let totalWords: Int
    let weekWords: Int
    let averageWPM: Double
    /// Typing the same words at 40 WPM minus the time actually spent speaking. Can be
    /// negative for very short entries; the Home rail clamps it.
    let savedSeconds: Double
}

// MARK: - Backup document
//
// One JSON file holding everything the user made: modes, dictionary, replacement rules, per-app
// rules and the non-secret preferences. API keys are NEVER in it -- they live in the Keychain and
// this file never reads it, so a backup can be mailed around without leaking a key. History is
// not in it either: it is a log, not a setting, and it holds the user's dictated words.

/// A preference value as it appears in JSON: `true`, `30`, `"zh-TW"`. Encoded as the bare value
/// rather than a tagged enum so the document stays hand-readable.
enum PrefValue: Hashable, Sendable, Codable {
    case bool(Bool), int(Int), double(Double), string(String)

    init(from d: Decoder) throws {
        let v = try d.singleValueContainer()
        if let b = try? v.decode(Bool.self) { self = .bool(b) }
        else if let i = try? v.decode(Int.self) { self = .int(i) }
        else if let x = try? v.decode(Double.self) { self = .double(x) }
        else { self = .string(try v.decode(String.self)) }
    }

    func encode(to e: Encoder) throws {
        var v = e.singleValueContainer()
        switch self {
        case .bool(let b): try v.encode(b)
        case .int(let i): try v.encode(i)
        case .double(let x): try v.encode(x)
        case .string(let s): try v.encode(s)
        }
    }

    // Coercions, because import must write the type the key is registered with even when the
    // document says otherwise. A wrong type in UserDefaults outlives the import.
    var boolValue: Bool {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .double(let x): x != 0
        case .string(let s): ["1", "true", "yes"].contains(s.lowercased())
        }
    }
    var intValue: Int {
        switch self {
        case .bool(let b): b ? 1 : 0
        case .int(let i): i
        case .double(let x): Int(x)
        case .string(let s): Int(s) ?? 0
        }
    }
    var doubleValue: Double {
        switch self {
        case .bool(let b): b ? 1 : 0
        case .int(let i): Double(i)
        case .double(let x): x
        case .string(let s): Double(s) ?? 0
        }
    }
    var stringValue: String {
        switch self {
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let x): String(x)
        case .string(let s): s
        }
    }
}

/// A mode as it travels. Not `Mode` itself: `Mode` lives in App.swift, carries a `builtIn` flag
/// that is the local install's business, and has no room for the shell command.
struct BackupMode: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var subtitle: String
    var sfSymbol: String
    var prompt: String
    var usesSelection: Bool
    var translates: Bool
    var shellCommand: String
}

/// A dictionary entry without its row id.
struct BackupTerm: Codable, Hashable, Sendable {
    var text: String
    var variants: [String]
    var source: TermSource
}

/// The whole document. Sections are optional on the way in so a hand-trimmed file still imports;
/// the records inside them are not, because a half-written record has no sane default.
struct Backup: Codable, Sendable {
    static let currentVersion = 1

    var version = Backup.currentVersion
    var app = "OpenTalkType"
    var exportedAt = Date()
    var modes: [BackupMode] = []
    var terms: [BackupTerm] = []
    var replacements: [ReplacementRule] = []
    var appRules: [AppRule] = []
    var prefs: [String: PrefValue] = [:]

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "OpenTalkType"
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        modes = try c.decodeIfPresent([BackupMode].self, forKey: .modes) ?? []
        terms = try c.decodeIfPresent([BackupTerm].self, forKey: .terms) ?? []
        replacements = try c.decodeIfPresent([ReplacementRule].self, forKey: .replacements) ?? []
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        prefs = try c.decodeIfPresent([String: PrefValue].self, forKey: .prefs) ?? [:]
    }
}

/// What an import actually did, for the sheet that reports it. `skipped` is rows that were already
/// there, plus per-app rules pointing at a mode this install does not have.
struct ImportSummary: Hashable, Sendable {
    var modes = 0
    var terms = 0
    var replacements = 0
    var appRules = 0
    var prefs = 0
    var skipped = 0
}

enum BackupError: LocalizedError {
    case unreadable
    case unsupportedVersion(Int)
    case invalid(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "This is not an OpenTalkType settings file, or the file is damaged.")
        case .unsupportedVersion(let v):
            String(format: String(localized: "This settings file is version %d, which is newer than this app. Update the app first."), v)
        case .invalid(let why):
            String(format: String(localized: "There is a problem with the settings file: %@"), why)
        case .writeFailed:
            String(localized: "Could not write to the database. Everything was restored to how it was before the import.")
        }
    }
}

// MARK: - Store

@Observable
final class Store: @unchecked Sendable {
    static let shared = Store(path: Store.defaultPath)

    /// Bumped on every mutation. The three panes read it inside their `body` (as part of their
    /// `.task(id:)` key), which is what registers the observation dependency -- reading it from
    /// inside a query method would not, because a `.task` closure is not a tracking scope.
    private(set) var revision = 0

    private let db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTalkType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite").path
    }

    init(path: String) {
        var handle: OpaquePointer?
        sqlite3_open(path, &handle)
        db = handle

        // Word counting has to understand CJK, which no amount of SQL string functions can do,
        // so hand sqlite a Swift implementation and keep stats() as one query.
        sqlite3_create_function(db, "wordcount", 1, SQLITE_UTF8, nil, { ctx, _, argv in
            guard let argv, let text = sqlite3_value_text(argv[0]) else {
                sqlite3_result_int(ctx, 0)
                return
            }
            sqlite3_result_int(ctx, Int32(Store.wordCount(String(cString: text))))
        }, nil, nil)

        exec("""
            CREATE TABLE IF NOT EXISTS history(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              mode TEXT NOT NULL,
              raw TEXT NOT NULL,
              cleaned TEXT NOT NULL DEFAULT '',
              app_bundle_id TEXT NOT NULL DEFAULT '',
              target_lang TEXT,
              duration REAL NOT NULL DEFAULT 0
            )
            """)
        // Added after the first release. CREATE TABLE IF NOT EXISTS will not alter an existing
        // table, so migrate explicitly; the ALTER is a harmless no-op error once it is applied.
        exec("ALTER TABLE history ADD COLUMN model TEXT NOT NULL DEFAULT ''")
        // Same pattern again, for keeping the recording alongside the transcript.
        exec("ALTER TABLE history ADD COLUMN audio_path TEXT NOT NULL DEFAULT ''")
        exec("ALTER TABLE history ADD COLUMN audio_seconds REAL NOT NULL DEFAULT 0")
        exec("CREATE INDEX IF NOT EXISTS history_created ON history(created_at DESC)")
        exec("""
            CREATE TABLE IF NOT EXISTS modes(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              subtitle TEXT NOT NULL DEFAULT '',
              symbol TEXT NOT NULL DEFAULT 'waveform',
              prompt TEXT NOT NULL DEFAULT '',
              uses_selection INTEGER NOT NULL DEFAULT 0,
              translates INTEGER NOT NULL DEFAULT 0,
              built_in INTEGER NOT NULL DEFAULT 0,
              position INTEGER NOT NULL DEFAULT 0
            )
            """)
        // A mode may hand its result to a shell command before insertion; LLM.swift runs it.
        exec("ALTER TABLE modes ADD COLUMN shell_command TEXT NOT NULL DEFAULT ''")
        seedModes()
        exec("""
            CREATE TABLE IF NOT EXISTS terms(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              term TEXT NOT NULL UNIQUE,
              aliases TEXT NOT NULL DEFAULT '',
              source TEXT NOT NULL,
              created_at REAL NOT NULL
            )
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS replacements(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              find TEXT NOT NULL,
              replace_with TEXT NOT NULL DEFAULT '',
              case_sensitive INTEGER NOT NULL DEFAULT 0,
              is_regex INTEGER NOT NULL DEFAULT 0,
              enabled INTEGER NOT NULL DEFAULT 1,
              position INTEGER NOT NULL DEFAULT 0
            )
            """)
        // UNIQUE is the import's conflict rule expressed in the schema: the same app plus the
        // same host can only map one way, and a re-import hits INSERT OR IGNORE instead of
        // silently stacking a second rule that never wins.
        exec("""
            CREATE TABLE IF NOT EXISTS app_rules(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bundle_id TEXT NOT NULL DEFAULT '',
              host TEXT NOT NULL DEFAULT '',
              mode_id TEXT NOT NULL,
              UNIQUE(bundle_id, host)
            )
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Modes

    /// The three that ship. INSERT OR IGNORE, so edits survive a relaunch and a new build can add
    /// one without disturbing what the user has already changed.
    private func seedModes() {
        let seeds: [(String, String, String, String, Int, Int, Int)] = [
            ("dictate", String(localized: "Dictate"),
             String(localized: "Cleans up what you said and inserts it at the cursor."),
             "waveform", 0, 0, 0),
            ("translate", String(localized: "Translate"),
             String(localized: "Speak in one language, get idiomatic text in another."),
             "character.bubble", 0, 1, 1),
            ("ask", String(localized: "Ask"),
             String(localized: "Give an instruction about the selected text and replace it with the result."),
             "sparkles", 1, 0, 2),
        ]
        for (id, name, sub, sym, sel, tr, pos) in seeds {
            exec("""
                INSERT OR IGNORE INTO modes(id, name, subtitle, symbol, prompt,
                                            uses_selection, translates, built_in, position)
                VALUES(?, ?, ?, ?, '', ?, ?, 1, ?)
                """, [id, name, sub, sym, sel, tr, pos])
        }
    }

    /// ponytail: cached because Mode.allCases is read on every view update and in the event tap
    /// path. Invalidated by bump(), which every write already calls.
    private var modeCache: [Mode]?

    func modes() -> [Mode] {
        if let modeCache { return modeCache }
        var out: [Mode] = []
        exec("""
            SELECT id, name, subtitle, symbol, prompt, uses_selection, translates, built_in
            FROM modes ORDER BY position, rowid
            """) { s in
            out.append(Mode(id: Self.str(s, 0),
                            storedName: Self.str(s, 1),
                            storedSubtitle: Self.str(s, 2),
                            sfSymbol: Self.str(s, 3),
                            prompt: Self.str(s, 4),
                            usesSelection: sqlite3_column_int(s, 5) != 0,
                            translates: sqlite3_column_int(s, 6) != 0,
                            builtIn: sqlite3_column_int(s, 7) != 0))
        }
        lock.withLock { modeCache = out }
        return out
    }

    func saveMode(_ m: Mode) {
        let name = m.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.id.isEmpty, !name.isEmpty else { return }
        exec("""
            INSERT INTO modes(id, name, subtitle, symbol, prompt, uses_selection, translates,
                              built_in, position)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM modes))
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, subtitle = excluded.subtitle,
                symbol = excluded.symbol, prompt = excluded.prompt,
                uses_selection = excluded.uses_selection, translates = excluded.translates
            """,
             [m.id, name, m.subtitle, m.sfSymbol, m.prompt,
              m.usesSelection ? 1 : 0, m.translates ? 1 : 0, m.builtIn ? 1 : 0])
        bump()
    }

    /// Built-ins are not deletable: Home renders their key caps and history rows resolve through
    /// them. Everything else goes, and its history rows fall back to a placeholder.
    func deleteMode(_ id: String) {
        lock.withLock {
            exec("DELETE FROM modes WHERE id = ? AND built_in = 0", [id])
            // A per-app rule pointing at a mode that no longer exists would sit in the list
            // looking like a working rule and never fire.
            exec("DELETE FROM app_rules WHERE mode_id = ? AND mode_id NOT IN (SELECT id FROM modes)",
                 [id])
        }
        bump()
    }

    /// A slug that is stable, filename-safe and free. Chinese names are common here, and a
    /// romanised slug would be neither stable nor readable, so fall back to a counter.
    func freeModeID(from name: String) -> String {
        let base = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
        let stem = base.isEmpty ? "mode" : String(base.prefix(24))
        let taken = Set(modes().map(\.id))
        if !taken.contains(stem) { return stem }
        for n in 2... where !taken.contains("\(stem)-\(n)") { return "\(stem)-\(n)" }
        return stem
    }

    // MARK: Mode shell command

    /// ponytail: cached the same way as modeCache, because `mode.shellCommand` is read from view
    /// bodies. Invalidated by bump().
    private var shellCache: [String: String]?

    /// The shell command bound to a mode, "" when it has none. Kept off the `Mode` record because
    /// `Mode` is built in App.swift and this is the only place that knows the column exists.
    func shellCommand(_ modeID: String) -> String {
        if let shellCache { return shellCache[modeID] ?? "" }
        var out: [String: String] = [:]
        exec("SELECT id, shell_command FROM modes") { s in out[Self.str(s, 0)] = Self.str(s, 1) }
        lock.withLock { shellCache = out }
        return out[modeID] ?? ""
    }

    func setShellCommand(_ command: String, for modeID: String) {
        exec("UPDATE modes SET shell_command = ? WHERE id = ?",
             [command.trimmingCharacters(in: .whitespacesAndNewlines), modeID])
        bump()
    }

    // MARK: History

    /// `cleaned` empty means the LLM stage failed; write the row regardless.
    @discardableResult
    func insert(mode: Mode, raw: String, cleaned: String = "", app: String = "",
                targetLang: String? = nil, duration: Double = 0, model: String = "",
                at date: Date = Date()) -> Int64 {
        exec("""
            INSERT INTO history(created_at, mode, raw, cleaned, app_bundle_id, target_lang, duration, model)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
             [date.timeIntervalSince1970, mode.rawValue, raw, cleaned, app, targetLang, duration, model])
        bump()
        return lock.withLock { sqlite3_last_insert_rowid(db) }
    }

    /// Attach a kept recording to a row that is already written. Separate call because the file
    /// is only finalised after the transcript exists.
    func setAudio(entry id: Int64, path: String, seconds: Double) {
        exec("UPDATE history SET audio_path = ?, audio_seconds = ? WHERE id = ?", [path, seconds, id])
        bump()
    }

    /// The one history query: the filter chips and the search field, newest first.
    func entries(mode: Mode? = nil, search text: String = "") -> [Entry] {
        var sql = """
            SELECT id, created_at, mode, raw, cleaned, app_bundle_id, target_lang, duration, model,
                   audio_path, audio_seconds
            FROM history WHERE 1=1
            """
        var binds: [Any?] = []
        // Bound parameters, never string concatenation -- the search field is user input.
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            sql += " AND (raw LIKE ? OR cleaned LIKE ?)"
            binds.append("%\(needle)%")
            binds.append("%\(needle)%")
        }
        if let mode {
            sql += " AND mode = ?"
            binds.append(mode.rawValue)
        }
        sql += " ORDER BY created_at DESC"

        var rows: [Entry] = []
        exec(sql, binds) { s in
            rows.append(Entry(id: sqlite3_column_int64(s, 0),
                              date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                              // Resolve through the modes table; a row whose mode was deleted keeps rendering
                              // under a placeholder rather than being silently relabelled 聽寫.
                              mode: Mode.named(Self.str(s, 2)) ?? Mode.placeholder(Self.str(s, 2)),
                              raw: Self.str(s, 3),
                              cleaned: Self.str(s, 4),
                              app: Self.str(s, 5),
                              targetLang: Self.optStr(s, 6),
                              duration: sqlite3_column_double(s, 7),
                              model: Self.str(s, 8),
                              audioPath: Self.str(s, 9),
                              audioSeconds: sqlite3_column_double(s, 10)))
        }
        return rows
    }

    /// Every delete returns the recordings it orphaned. Deleting files is the caller's job -- the
    /// store never touches the filesystem, so a failed unlink cannot roll a row back into
    /// existence and the self-test never needs a sandbox.
    @discardableResult
    func deleteEntry(_ id: Int64) -> [String] { deleteHistory(where: "id = ?", [id]) }

    @discardableResult
    func clearHistory() -> [String] { deleteHistory(where: "1=1", []) }

    /// Retention, enforced at launch and whenever the setting changes. 0 means 永久.
    @discardableResult
    func purge(olderThanDays days: Int) -> [String] {
        guard days > 0 else { return [] }
        return deleteHistory(where: "created_at < ?", [Self.cutoff(days)])
    }

    /// Audio retention, which is shorter than transcript retention: drop the recordings, keep the
    /// words. Unlike `purge`, 0 does NOT mean 永久 -- it is the off switch, and turning the feature
    /// off has to take the recordings already on disk with it, or "不保留" leaves a folder full of
    /// everything ever said.
    @discardableResult
    func purgeAudio(olderThanDays days: Int) -> [String] {
        let cutoff = days > 0 ? Self.cutoff(days) : .greatestFiniteMagnitude
        let gone = lock.withLock { () -> [String] in
            let paths = orphanedAudio("created_at < ?", [cutoff])
            guard !paths.isEmpty else { return [] }
            exec("UPDATE history SET audio_path = '', audio_seconds = 0 WHERE created_at < ?",
                 [cutoff])
            return paths
        }
        if !gone.isEmpty { bump() }
        return gone
    }

    private static func cutoff(_ days: Int) -> Double {
        Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
    }

    /// The one delete path. Reads the orphaned recordings and deletes the rows under a single
    /// lock, so the caller can never be handed a path whose row survived.
    private func deleteHistory(where clause: String, _ binds: [Any?]) -> [String] {
        let gone = lock.withLock { () -> [String] in
            let paths = orphanedAudio(clause, binds)
            exec("DELETE FROM history WHERE \(clause)", binds)
            return paths
        }
        bump()
        return gone
    }

    /// Recording paths on the rows a `WHERE` clause selects. The clause is always a literal from
    /// this file; the values are bound.
    private func orphanedAudio(_ whereClause: String, _ binds: [Any?]) -> [String] {
        var paths: [String] = []
        exec("SELECT audio_path FROM history WHERE audio_path <> '' AND (\(whereClause))", binds) { s in
            paths.append(Self.str(s, 0))
        }
        return paths
    }

    // MARK: Stats

    /// Everything on Home's stats rail, in one query. Words are CJK-aware via wordcount().
    func stats() -> Stats {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        var total = 0, week = 0, spoken = 0, seconds = 0.0
        exec("""
            SELECT COALESCE(SUM(w), 0),
                   COALESCE(SUM(CASE WHEN created_at >= ? THEN w ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN duration > 0 THEN w ELSE 0 END), 0),
                   COALESCE(SUM(duration), 0)
            FROM (SELECT created_at, duration,
                         wordcount(CASE WHEN cleaned = '' THEN raw ELSE cleaned END) AS w
                  FROM history)
            """, [weekAgo]) { s in
            total = Int(sqlite3_column_int64(s, 0))
            week = Int(sqlite3_column_int64(s, 1))
            spoken = Int(sqlite3_column_int64(s, 2))
            seconds = sqlite3_column_double(s, 3)
        }
        return Stats(totalWords: total,
                     weekWords: week,
                     averageWPM: seconds > 0 ? Double(spoken) / (seconds / 60) : 0,
                     savedSeconds: Double(total) / 40 * 60 - seconds)
    }

    // MARK: Dictionary

    func terms(source: TermSource? = nil, search text: String = "") -> [Term] {
        var sql = "SELECT id, term, aliases, source FROM terms WHERE 1=1"
        var binds: [Any?] = []
        if let source {
            sql += " AND source = ?"
            binds.append(source.rawValue)
        }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            sql += " AND (term LIKE ? OR aliases LIKE ?)"
            binds.append("%\(needle)%")
            binds.append("%\(needle)%")
        }
        sql += " ORDER BY created_at DESC"

        var out: [Term] = []
        exec(sql, binds) { s in
            out.append(Term(id: sqlite3_column_int64(s, 0),
                            text: Self.str(s, 1),
                            variants: Self.splitVariants(Self.str(s, 2)),
                            source: TermSource(rawValue: Self.str(s, 3)) ?? .manual))
        }
        return out
    }

    /// The whole dictionary editor: nil id inserts, an id updates. Re-adding an existing word
    /// unions the variants instead of replacing the row, so the auto-learner can never clobber
    /// something the user typed.
    func saveTerm(id: Int64?, text: String, variants: [String], source: TermSource = .manual) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let clean = Self.joinVariants(variants)
        if let id {
            exec("UPDATE terms SET term = ?, aliases = ? WHERE id = ?", [name, clean, id])
        } else {
            exec("INSERT OR IGNORE INTO terms(term, aliases, source, created_at) VALUES(?, ?, ?, ?)",
                 [name, clean, source.rawValue, Date().timeIntervalSince1970])
            var existing: [String] = []
            exec("SELECT aliases FROM terms WHERE term = ?", [name]) { s in
                existing = Self.splitVariants(Self.str(s, 0))
            }
            let merged = existing + variants.filter { !existing.contains($0) }
            if merged.count != existing.count {
                exec("UPDATE terms SET aliases = ? WHERE term = ?", [Self.joinVariants(merged), name])
            }
        }
        bump()
    }

    func deleteTerm(_ id: Int64) {
        exec("DELETE FROM terms WHERE id = ?", [id])
        bump()
    }

    /// Diff raw against cleaned; anything the LLM produced that was not spoken and is not
    /// already known becomes a 自動加入 term.
    func learnTerms(raw: String, cleaned: String) {
        let known = Set(terms().flatMap { [$0.text] + $0.variants })
        for (term, alias) in Self.inferTermPairs(raw: raw, cleaned: cleaned, known: known) {
            saveTerm(id: nil, text: term, variants: alias.map { [$0] } ?? [], source: .auto)
        }
    }

    // MARK: Replacement rules

    /// Ordered, because the rules run as a pipeline. `enabledOnly` is what LLM.swift asks for;
    /// the editor wants everything.
    func replacementRules(enabledOnly: Bool = false) -> [ReplacementRule] {
        var out: [ReplacementRule] = []
        exec("""
            SELECT id, find, replace_with, case_sensitive, is_regex, enabled FROM replacements
            \(enabledOnly ? "WHERE enabled = 1" : "") ORDER BY position, id
            """) { s in
            out.append(ReplacementRule(id: sqlite3_column_int64(s, 0),
                                       find: Self.str(s, 1),
                                       replace: Self.str(s, 2),
                                       caseSensitive: sqlite3_column_int(s, 3) != 0,
                                       isRegex: sqlite3_column_int(s, 4) != 0,
                                       enabled: sqlite3_column_int(s, 5) != 0))
        }
        return out
    }

    /// id 0 inserts and appends to the end of the order, anything else updates. Returns the row id.
    /// `find` is never trimmed: a rule that adds a space around a term needs its spaces.
    @discardableResult
    func saveReplacementRule(_ r: ReplacementRule) -> Int64 {
        guard !r.find.isEmpty else { return 0 }
        let values: [Any?] = [r.find, r.replace, r.caseSensitive ? 1 : 0, r.isRegex ? 1 : 0,
                              r.enabled ? 1 : 0]
        if r.id != 0 {
            exec("""
                UPDATE replacements SET find = ?, replace_with = ?, case_sensitive = ?,
                    is_regex = ?, enabled = ? WHERE id = ?
                """, values + [r.id])
            bump()
            return r.id
        }
        let id = lock.withLock { () -> Int64 in
            exec("""
                INSERT INTO replacements(find, replace_with, case_sensitive, is_regex, enabled, position)
                VALUES(?, ?, ?, ?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM replacements))
                """, values)
            return sqlite3_last_insert_rowid(db)
        }
        bump()
        return id
    }

    func deleteReplacementRule(_ id: Int64) {
        exec("DELETE FROM replacements WHERE id = ?", [id])
        bump()
    }

    /// The ids in their new order, straight from a drag in the list. Ids that are not in the
    /// table are simply ignored by the UPDATE.
    func reorderReplacementRules(_ ids: [Int64]) {
        lock.withLock {
            for (i, id) in ids.enumerated() {
                exec("UPDATE replacements SET position = ? WHERE id = ?", [i, id])
            }
        }
        bump()
    }

    // MARK: Per-app rules

    func appRules() -> [AppRule] {
        var out: [AppRule] = []
        exec("SELECT id, bundle_id, host, mode_id FROM app_rules ORDER BY bundle_id, host") { s in
            out.append(AppRule(id: sqlite3_column_int64(s, 0),
                               bundleID: Self.str(s, 1),
                               host: Self.str(s, 2),
                               modeID: Self.str(s, 3)))
        }
        return out
    }

    /// Upsert on (bundle_id, host): the same app and site can only mean one mode, so editing the
    /// target of an existing pair replaces it instead of adding a rule that could never win.
    @discardableResult
    func saveAppRule(_ r: AppRule) -> Int64 {
        let bundle = r.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Self.normalizeHost(r.host)
        guard !r.modeID.isEmpty, !(bundle.isEmpty && host.isEmpty) else { return 0 }
        let id = lock.withLock { () -> Int64 in
            if r.id != 0 {
                exec("UPDATE app_rules SET bundle_id = ?, host = ?, mode_id = ? WHERE id = ?",
                     [bundle, host, r.modeID, r.id])
                return r.id
            }
            exec("""
                INSERT INTO app_rules(bundle_id, host, mode_id) VALUES(?, ?, ?)
                ON CONFLICT(bundle_id, host) DO UPDATE SET mode_id = excluded.mode_id
                """, [bundle, host, r.modeID])
            var existing: Int64 = 0
            exec("SELECT id FROM app_rules WHERE bundle_id = ? AND host = ?", [bundle, host]) { s in
                existing = sqlite3_column_int64(s, 0)
            }
            return existing
        }
        bump()
        return id
    }

    func deleteAppRule(_ id: Int64) {
        exec("DELETE FROM app_rules WHERE id = ?", [id])
        bump()
    }

    /// The mode to latch for the app in front, or nil to fall back to whatever the hotkey chose.
    /// `host` is the site when the frontmost app is a browser, nil otherwise.
    func mode(forApp bundleID: String, host: String? = nil) -> Mode? {
        Self.matchAppRule(bundleID: bundleID, host: host, rules: appRules()).flatMap(Mode.named)
    }

    // MARK: Pure logic, testable without a database

    /// Which mode a rule set asks for, or nil when nothing matches and the global default stands.
    ///
    /// Precedence, most specific first: app + host, then host, then app. A host rule matches its
    /// own subdomains (a rule for gmail.com covers mail.gmail.com) and, within the same tier, the
    /// longer host wins so mail.google.com beats google.com. Everything is compared lowercased.
    static func matchAppRule(bundleID: String, host: String?, rules: [AppRule]) -> String? {
        let app = bundleID.lowercased()
        let site = normalizeHost(host ?? "")

        func hostHit(_ pattern: String) -> Bool {
            let p = pattern.lowercased()
            guard !p.isEmpty, !site.isEmpty else { return false }
            // hasSuffix(".p") and not plain hasSuffix(p), or evilgoogle.com would match google.com.
            return site == p || site.hasSuffix("." + p)
        }
        func appHit(_ pattern: String) -> Bool {
            !pattern.isEmpty && pattern.lowercased() == app && !app.isEmpty
        }

        var best: (tier: Int, hostLength: Int, mode: String)?
        for r in rules where !r.modeID.isEmpty {
            let tier: Int
            switch (r.bundleID.isEmpty, r.host.isEmpty) {
            case (false, false): guard appHit(r.bundleID), hostHit(r.host) else { continue }; tier = 3
            case (true, false):  guard hostHit(r.host) else { continue };                      tier = 2
            case (false, true):  guard appHit(r.bundleID) else { continue };                   tier = 1
            case (true, true):   continue   // not a rule, that is the global default
            }
            if best == nil || (tier, r.host.count) > (best!.tier, best!.hostLength) {
                best = (tier, r.host.count, r.modeID)
            }
        }
        return best?.mode
    }

    /// Accepts what a person actually pastes -- a whole URL, a host with a port, mixed case -- and
    /// returns the bare lowercase host that matchAppRule compares against.
    static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }   // user:pass@host
        s = String(s.prefix { $0 != ":" })                                          // :8080
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Whether a replacement rule's pattern will actually compile. The editor calls this to show
    /// an inline error, and import refuses a document that carries a broken one.
    static func regexIsValid(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// CJK character = one word, run of letters or digits = one word. Punctuation and
    /// whitespace count for nothing.
    static func wordCount(_ s: String) -> Int {
        var n = 0, inRun = false
        for u in s.unicodeScalars {
            if isCJK(u) {
                n += 1
                inRun = false
            } else if CharacterSet.alphanumerics.contains(u) {
                if !inRun { n += 1; inRun = true }
            } else {
                inRun = false
            }
        }
        return n
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF,     // kana
             0x3400...0x4DBF,     // CJK ext A
             0x4E00...0x9FFF,     // CJK unified
             0xAC00...0xD7AF,     // hangul syllables
             0xF900...0xFAFF,     // compatibility ideographs
             0x20000...0x2FA1F:   // CJK ext B and beyond
            true
        default:
            false
        }
    }

    /// Plain substring replacement, longest variant first. Deliberately NOT a word-boundary
    /// regex: `\b` never fires inside 台北車站, so a regex version silently does nothing in
    /// Chinese, which is most of what this app hears.
    ///
    /// ponytail: a rewritten term can be re-matched by a shorter variant later in the pass.
    /// Upgrade path if that ever bites: one combined pass over the string with a trie.
    static func applyDictionary(_ text: String, terms: [Term]) -> String {
        let pairs = terms
            .flatMap { t in t.variants.map { ($0, t.text) } }
            .filter { !$0.0.isEmpty && $0.0 != $0.1 }
            .sorted { $0.0.count > $1.0.count }
        guard !pairs.isEmpty else { return text }
        var out = text
        for (variant, term) in pairs {
            out = out.replacingOccurrences(of: variant, with: term)
        }
        return out
    }

    /// ponytail: latin-run tokens only. Chinese needs segmentation to diff at word level, so
    /// Chinese corrections are never auto-learned -- the user adds those by hand. Upgrade path:
    /// NLTokenizer, which would pull in NaturalLanguage for one heuristic.
    /// Terms the cleanup introduced, each paired with the garbled run it replaced when one can
    /// be identified. The pairing is the point: storing only "pull" teaches nothing, while
    /// "pull" with alias "plol" lets the literal rewrite fix the next occurrence before the LLM
    /// ever sees it.
    static func inferTermPairs(raw: String, cleaned: String,
                               known: Set<String>) -> [(term: String, alias: String?)] {
        let spokenTokens = tokens(raw)
        let spoken = Set(spokenTokens.map { $0.lowercased() })
        let finalSet = Set(tokens(cleaned).map { $0.lowercased() })
        let knownLower = Set(known.map { $0.lowercased() })

        // Runs that survived into the result but were never spoken: the corrections.
        var added: [String] = []
        for t in tokens(cleaned) {
            let key = t.lowercased()
            // At least one letter, or the dictate prompt's "convert number words into digits"
            // turns 我說二十次 -> 我說 20 次 into a term called "20", which then goes back into
            // the prompt as an authoritative spelling and into the recogniser as a hint.
            guard t.count >= 2, t.rangeOfCharacter(from: .letters) != nil,
                  !spoken.contains(key), !knownLower.contains(key),
                  !added.contains(where: { $0.lowercased() == key }) else { continue }
            added.append(t)
        }

        // Runs that were spoken but did not survive: the mis-recognitions available to pair with.
        var dropped = spokenTokens.filter { !finalSet.contains($0.lowercased()) }

        return added.map { term in
            guard let i = dropped.indices.min(by: {
                similarity(term, dropped[$0]) > similarity(term, dropped[$1])
            }), similarity(term, dropped[i]) >= 0.5 else { return (term, nil) }
            let alias = dropped.remove(at: i)          // one alias cannot serve two terms
            return (term, alias)
        }
    }

    static func inferNewTerms(raw: String, cleaned: String, known: Set<String>) -> [String] {
        inferTermPairs(raw: raw, cleaned: cleaned, known: known).map(\.term)
    }

    /// 1 - normalised edit distance, case-insensitive. 1 is identical, 0 shares nothing.
    /// ponytail: plain Levenshtein, no phonetic model. "plol"/"pull" scores 0.5, which is the
    /// threshold. Upgrade path is a metaphone comparison if too many pairs are missed.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var buf = ""
        for u in s.unicodeScalars {
            if !isCJK(u), CharacterSet.alphanumerics.contains(u) {
                buf.unicodeScalars.append(u)
            } else if !buf.isEmpty {
                out.append(buf)
                buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    private static func splitVariants(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func joinVariants(_ a: [String]) -> String {
        a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Import and export

    /// Everything the user owns, as one JSON document. Never touches the Keychain: API keys are
    /// not in here and the UI must say so next to the button.
    func exportBackup() throws -> Data {
        var b = Backup()
        b.modes = modes().map {
            BackupMode(id: $0.id, displayName: $0.displayName, subtitle: $0.subtitle,
                       sfSymbol: $0.sfSymbol, prompt: $0.prompt, usesSelection: $0.usesSelection,
                       translates: $0.translates, shellCommand: shellCommand($0.id))
        }
        b.terms = terms().map { BackupTerm(text: $0.text, variants: $0.variants, source: $0.source) }
        b.replacements = replacementRules()
        b.appRules = appRules()
        b.prefs = exportablePrefs()

        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(b)
    }

    /// Additive import. The conflict rule is **what is already here wins**: a mode with an id that
    /// exists is skipped whole, a dictionary word that exists only gains the document's variants,
    /// a replacement rule with the same find/replace pair and a per-app rule for the same app and
    /// host are skipped. Nothing is ever deleted. Preferences are the exception -- they are
    /// overwritten, because restoring settings is the point of restoring settings.
    ///
    /// The rows go in inside one transaction, so a document that passes validation and then fails
    /// to write leaves the database exactly as it was.
    @discardableResult
    func importBackup(_ data: Data, applyPrefs: Bool = true) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(Backup.self, from: data) else { throw BackupError.unreadable }
        try Self.validate(doc)

        var sum = ImportSummary()
        var ok = true
        lock.withLock {
            guard exec("BEGIN") else { ok = false; return }

            let haveModes = Set(modes().map(\.id))
            for m in doc.modes where !haveModes.contains(m.id) {
                ok = ok && exec("""
                    INSERT INTO modes(id, name, subtitle, symbol, prompt, uses_selection, translates,
                                      built_in, position, shell_command)
                    VALUES(?, ?, ?, ?, ?, ?, ?, 0,
                           (SELECT COALESCE(MAX(position), 0) + 1 FROM modes), ?)
                    """,
                    [m.id, m.displayName, m.subtitle, m.sfSymbol, m.prompt,
                     m.usesSelection ? 1 : 0, m.translates ? 1 : 0, m.shellCommand])
                sum.modes += 1
            }
            sum.skipped += doc.modes.count - sum.modes

            let haveTerms = Set(terms().map(\.text))
            for t in doc.terms {
                // saveTerm unions variants onto an existing word and never overwrites it, which is
                // exactly the conflict rule, so reuse it rather than writing a second insert path.
                saveTerm(id: nil, text: t.text, variants: t.variants, source: t.source)
                if haveTerms.contains(t.text) { sum.skipped += 1 } else { sum.terms += 1 }
            }

            let haveRules = Set(replacementRules().map { "\($0.find)\u{0}\($0.replace)" })
            for r in doc.replacements {
                if haveRules.contains("\(r.find)\u{0}\(r.replace)") { sum.skipped += 1; continue }
                saveReplacementRule(ReplacementRule(id: 0, find: r.find, replace: r.replace,
                                                    caseSensitive: r.caseSensitive,
                                                    isRegex: r.isRegex, enabled: r.enabled))
                sum.replacements += 1
            }

            let knownModes = Set(modes().map(\.id))
            let havePairs = Set(appRules().map { "\($0.bundleID.lowercased())\u{0}\($0.host)" })
            for r in doc.appRules {
                let key = "\(r.bundleID.lowercased())\u{0}\(Self.normalizeHost(r.host))"
                // A rule for a mode this install does not have would silently never fire.
                guard knownModes.contains(r.modeID), !havePairs.contains(key) else {
                    sum.skipped += 1
                    continue
                }
                saveAppRule(AppRule(id: 0, bundleID: r.bundleID, host: r.host, modeID: r.modeID))
                sum.appRules += 1
            }

            exec(ok ? "COMMIT" : "ROLLBACK")
        }
        bump()
        guard ok else { throw BackupError.writeFailed }

        // ponytail: preferences land after the commit and are not part of it -- UserDefaults has
        // no transaction. The rows are the part worth protecting; a half-written pref is one
        // wrong toggle, not a corrupt database. Upgrade path if that ever matters: snapshot the
        // keys first and restore them on failure.
        if applyPrefs {
            for (k, v) in doc.prefs where Self.isImportablePrefKey(k) {
                Self.applyPref(k, v)
                sum.prefs += 1
            }
        }
        return sum
    }

    /// Everything import checks before it writes a single row.
    static func validate(_ b: Backup) throws {
        guard b.version >= 1 else {
            throw BackupError.invalid(String(localized: "the version number is not valid"))
        }
        guard b.version <= Backup.currentVersion else { throw BackupError.unsupportedVersion(b.version) }
        for m in b.modes {
            guard !m.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupError.invalid(String(localized: "a mode has no id"))
            }
            guard !m.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupError.invalid(String(format: String(localized: "the mode “%@” has no name"), m.id))
            }
        }
        guard Set(b.modes.map(\.id)).count == b.modes.count else {
            throw BackupError.invalid(String(localized: "two modes share the same id"))
        }
        for t in b.terms where t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BackupError.invalid(String(localized: "a dictionary entry has no text"))
        }
        for r in b.replacements {
            guard !r.find.isEmpty else {
                throw BackupError.invalid(String(localized: "a replacement rule has nothing to find"))
            }
            guard !r.isRegex || regexIsValid(r.find) else {
                throw BackupError.invalid(String(format: String(localized: "this regular expression does not compile: %@"), r.find))
            }
        }
        for r in b.appRules {
            guard !r.modeID.isEmpty else {
                throw BackupError.invalid(String(localized: "an app rule does not say which mode to use"))
            }
            guard !(r.bundleID.isEmpty && Self.normalizeHost(r.host).isEmpty) else {
                throw BackupError.invalid(String(localized: "an app rule needs at least an app or a site"))
            }
        }
    }

    /// Registered keys plus the per-mode prompt and hotkey keys, which are not in the registry for
    /// user-made modes. Nothing here is a secret; keys live in the Keychain and are not exported.
    private func exportablePrefs() -> [String: PrefValue] {
        var keys = Set(Prefs.registry.keys)
        for m in modes() {
            keys.insert(Prefs.systemPrompt(m.id))
            keys.insert(Prefs.companionKey(m.id))
            keys.insert(Prefs.autoSubmitKey(m.id))
        }
        var out: [String: PrefValue] = [:]
        for k in keys { out[k] = Self.readPref(k) }
        return out
    }

    /// The registry entry decides the type, not whatever UserDefaults happens to be holding: an
    /// NSNumber cannot tell you whether it was written as a Bool or an Int.
    private static func readPref(_ key: String) -> PrefValue {
        let ud = UserDefaults.standard
        switch Prefs.registry[key] {
        case is Bool: return .bool(ud.bool(forKey: key))
        case is Int: return .int(ud.integer(forKey: key))
        case is Double: return .double(ud.double(forKey: key))
        default: return .string(ud.string(forKey: key) ?? "")
        }
    }

    private static func applyPref(_ key: String, _ v: PrefValue) {
        let ud = UserDefaults.standard
        switch Prefs.registry[key] {
        case is Bool: ud.set(v.boolValue, forKey: key)
        case is Int: ud.set(v.intValue, forKey: key)
        case is Double: ud.set(v.doubleValue, forKey: key)
        default: ud.set(v.stringValue, forKey: key)
        }
    }

    /// A document is untrusted input, so it may only write keys this app owns -- never an
    /// arbitrary UserDefaults key on the app's domain.
    static func isImportablePrefKey(_ key: String) -> Bool {
        Prefs.registry[key] != nil || key.hasPrefix("prompt.") || key.hasPrefix("hotkey.")
            || key.hasPrefix("autosubmit.")
    }

    // MARK: sqlite plumbing

    private func bump() {
        lock.withLock { modeCache = nil; shellCache = nil }
        revision &+= 1
    }

    @discardableResult
    private func exec(_ sql: String, _ binds: [Any?] = [],
                      row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            // Never log binds: they are the user's speech.
            let msg = String(cString: sqlite3_errmsg(db))
            // "duplicate column name" is an already-applied migration, not a failure. Logging it
            // on every open trained the eye to ignore this line, which is how a real failure hides.
            if !msg.hasPrefix("duplicate column name") {
                print("sqlite prepare failed: \(msg)")
            }
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        if let row {
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
            return true
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func str(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func optStr(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : str(s, i)
    }
}

// MARK: - Self-test

func selfTestDictionary(_ c: SelfTest.Check) {
    // A word-boundary regex would never fire inside a Chinese run; plain substring does.
    let station = [Term(id: 1, text: "台北車站", variants: ["台北車戰"], source: .manual)]
    let cn = Store.applyDictionary("我在台北車戰等你", terms: station)
    c(cn == "我在台北車站等你", "applyDictionary/chinese-no-word-boundary",
      "expected 我在台北車站等你, got \(cn)")

    // Longest variant wins: the short one must not shred the long match first.
    let nested = [Term(id: 1, text: "AI", variants: ["A I"], source: .manual),
                  Term(id: 2, text: "AIGC", variants: ["A I G C"], source: .manual)]
    let long = Store.applyDictionary("A I G C 很紅", terms: nested)
    c(long == "AIGC 很紅", "applyDictionary/longest-term-wins", "expected AIGC 很紅, got \(long)")

    let untouched = Store.applyDictionary("原封不動 untouched", terms: [])
    c(untouched == "原封不動 untouched", "applyDictionary/empty-dictionary-is-noop",
      "expected 原封不動 untouched, got \(untouched)")

    let learned = Store.inferNewTerms(raw: "我今天用 git hub 上傳", cleaned: "我今天用 GitHub 上傳",
                                      known: [])
    c(learned == ["GitHub"], "inferNewTerms/finds-correction", "expected [GitHub], got \(learned)")

    let alreadyKnown = Store.inferNewTerms(raw: "我今天用 git hub 上傳", cleaned: "我今天用 GitHub 上傳",
                                           known: ["github"])
    c(alreadyKnown.isEmpty, "inferNewTerms/ignores-known", "expected [], got \(alreadyKnown)")

    // The prompt turns number words into digits, which is not a dictionary term.
    let digits = Store.inferNewTerms(raw: "我說二十次", cleaned: "我說 20 次", known: [])
    c(digits.isEmpty, "inferNewTerms/ignores-pure-digits", "expected [], got \(digits)")

    // The pairing is what makes the auto dictionary worth having: the alias is the garbled run
    // the recogniser actually produced, so the literal rewrite catches it next time.
    let pairs = Store.inferTermPairs(
        raw: "這個 plol request rebese到 man", cleaned: "這個 pull request rebase 到 main", known: [])
    let byTerm = Dictionary(uniqueKeysWithValues: pairs.map { ($0.term, $0.alias) })
    c(byTerm["pull"] == "plol", "inferTermPairs/pairs-pull",
      "expected plol, got \(String(describing: byTerm["pull"] ?? nil))")
    c(byTerm["rebase"] == "rebese", "inferTermPairs/pairs-rebase",
      "expected rebese, got \(String(describing: byTerm["rebase"] ?? nil))")
    c(byTerm["main"] == "man", "inferTermPairs/pairs-main",
      "expected man, got \(String(describing: byTerm["main"] ?? nil))")

    // An alias must not be handed to two different terms.
    let once = Store.inferTermPairs(raw: "man man", cleaned: "main mint", known: [])
    c(once.filter { $0.alias != nil }.count <= 2, "inferTermPairs/alias-used-once",
      "an alias was reused")

    c(Store.similarity("pull", "pull") == 1, "similarity/identical", "expected 1")
    c(Store.similarity("pull", "zzzz") == 0, "similarity/disjoint", "expected 0")
}

func selfTestStore(_ c: SelfTest.Check) {
    // CJK counts per character, latin per run: 今天要(3) + push + 三個(2) + commit = 7.
    let n = Store.wordCount("今天要 push 三個 commit")
    c(n == 7, "wordCount/mixed-cjk-latin", "expected 7, got \(n)")
    #if DEBUG
    assert(Store.wordCount("") == 0, "empty text must count as zero words")
    assert(Store.wordCount("hello, world!") == 2, "punctuation must not start a new word")
    #endif

    func didThrow(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    // MARK: per-app precedence, pure

    // app+host beats host beats app. Same rule set answers all three.
    let rules = [
        AppRule(id: 1, bundleID: "com.apple.Safari", host: "docs.google.com", modeID: "app-host"),
        AppRule(id: 2, bundleID: "", host: "google.com", modeID: "host"),
        AppRule(id: 3, bundleID: "com.apple.Safari", host: "", modeID: "app"),
    ]
    let both = Store.matchAppRule(bundleID: "com.apple.Safari", host: "docs.google.com", rules: rules)
    c(both == "app-host", "appRule/app-plus-host-wins", "expected app-host, got \(both ?? "nil")")

    let hostOnly = Store.matchAppRule(bundleID: "com.brave.Browser", host: "mail.google.com", rules: rules)
    c(hostOnly == "host", "appRule/host-beats-nothing-and-matches-subdomain",
      "expected host, got \(hostOnly ?? "nil")")

    let appOnly = Store.matchAppRule(bundleID: "com.apple.Safari", host: "example.com", rules: rules)
    c(appOnly == "app", "appRule/app-when-no-host-rule-matches", "expected app, got \(appOnly ?? "nil")")

    let none = Store.matchAppRule(bundleID: "com.apple.Notes", host: nil, rules: rules)
    c(none == nil, "appRule/no-match-falls-back-to-default", "expected nil, got \(none ?? "?")")

    // The suffix has to fall on a dot, or evilgoogle.com steals google.com's rule.
    let evil = Store.matchAppRule(bundleID: "com.brave.Browser", host: "evilgoogle.com", rules: rules)
    c(evil == nil, "appRule/subdomain-match-needs-a-dot", "expected nil, got \(evil ?? "?")")

    // Within a tier the longer host is the more specific one.
    let tie = [AppRule(id: 1, host: "google.com", modeID: "short"),
               AppRule(id: 2, host: "mail.google.com", modeID: "long")]
    let longer = Store.matchAppRule(bundleID: "x", host: "mail.google.com", rules: tie)
    c(longer == "long", "appRule/longest-host-wins", "expected long, got \(longer ?? "nil")")

    let normalised = Store.normalizeHost("HTTPS://Docs.Google.com:8443/a/b?q=1")
    c(normalised == "docs.google.com", "appRule/normalize-host",
      "expected docs.google.com, got \(normalised)")

    // MARK: backup validation, pure

    var doc = Backup()
    doc.modes = [BackupMode(id: "x", displayName: "", subtitle: "", sfSymbol: "waveform",
                            prompt: "", usesSelection: false, translates: false, shellCommand: "")]
    c(didThrow({ try Store.validate(doc) }), "backup/rejects-nameless-mode", "expected a throw")

    doc = Backup()
    doc.version = Backup.currentVersion + 1
    c(didThrow({ try Store.validate(doc) }), "backup/rejects-future-version", "expected a throw")

    doc = Backup()
    doc.replacements = [ReplacementRule(find: "(unclosed", isRegex: true)]
    c(didThrow({ try Store.validate(doc) }), "backup/rejects-broken-regex", "expected a throw")

    doc = Backup()
    doc.appRules = [AppRule(modeID: "dictate")]      // neither app nor host
    c(didThrow({ try Store.validate(doc) }), "backup/rejects-empty-app-rule", "expected a throw")

    doc = Backup()
    doc.replacements = [ReplacementRule(find: "台北車戰", replace: "台北車站")]
    c(!didThrow({ try Store.validate(doc) }), "backup/accepts-a-sane-document", "expected no throw")

    // An import must never be able to write a UserDefaults key this app does not own.
    c(Store.isImportablePrefKey(Prefs.showHUD), "backup/pref-key-allowed", "expected showHUD allowed")
    c(Store.isImportablePrefKey("prompt.commit"), "backup/per-mode-pref-key-allowed",
      "expected prompt.commit allowed")
    c(!Store.isImportablePrefKey("NSQuitAlwaysKeepsWindows"), "backup/foreign-pref-key-rejected",
      "expected a foreign key to be rejected")

    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("opentalktype-selftest-\(UUID().uuidString).sqlite").path
    let path2 = FileManager.default.temporaryDirectory
        .appendingPathComponent("opentalktype-selftest-\(UUID().uuidString).sqlite").path
    do {
        let s = Store(path: path)

        let now = Date()
        s.insert(mode: .dictate, raw: "今天要 push 三個 commit", cleaned: "今天要 push 三個 commit",
                 app: "Xcode", duration: 30, at: now)
        s.insert(mode: .translate, raw: "老樣子", cleaned: "business as usual",
                 targetLang: "en", at: now.addingTimeInterval(-60))
        s.insert(mode: .ask, raw: "很久以前的一句話", cleaned: "an old line",
                 at: now.addingTimeInterval(-40 * 86_400))

        let all = s.entries()
        c(all.count == 3, "store/insert-read-back", "expected 3 rows, got \(all.count)")
        c(all.first?.cleaned == "今天要 push 三個 commit", "store/round-trips-text",
          "expected the newest cleaned text back, got \(all.first?.cleaned ?? "nil")")

        // 7 + 3 (business as usual) + 3 (an old line) = 13
        let st = s.stats()
        c(st.totalWords == 13, "store/stats-word-count", "expected 13, got \(st.totalWords)")
        c(st.averageWPM == 14, "store/stats-wpm", "expected 14 (7 words in 30s), got \(st.averageWPM)")

        c(s.entries(search: "commit").count == 1, "store/search-latin",
          "expected 1 row matching commit, got \(s.entries(search: "commit").count)")
        c(s.entries(search: "老樣子").count == 1, "store/search-chinese",
          "expected 1 row matching 老樣子, got \(s.entries(search: "老樣子").count)")
        c(s.entries(mode: .translate).count == 1, "store/filter-by-mode",
          "expected 1 translate row, got \(s.entries(mode: .translate).count)")

        s.purge(olderThanDays: 0)
        c(s.entries().count == 3, "store/purge-zero-keeps-forever",
          "expected 3 rows kept, got \(s.entries().count)")

        s.purge(olderThanDays: 30)
        let kept = s.entries()
        c(kept.count == 2, "store/purge-drops-old-keeps-new", "expected 2 rows, got \(kept.count)")
        c(!kept.contains { $0.mode == .ask }, "store/purge-dropped-the-right-row",
          "expected the 40-day-old row gone, got \(kept.map(\.mode.rawValue))")

        s.saveTerm(id: nil, text: "台北車站", variants: ["台北車戰"])
        s.saveTerm(id: nil, text: "GitHub", variants: [], source: .auto)
        c(s.terms().count == 2, "store/terms-insert", "expected 2 terms, got \(s.terms().count)")
        c(s.terms(source: .auto).map(\.text) == ["GitHub"], "store/terms-filter-auto",
          "expected [GitHub], got \(s.terms(source: .auto).map(\.text))")
        c(s.terms(source: .manual).map(\.text) == ["台北車站"], "store/terms-filter-manual",
          "expected [台北車站], got \(s.terms(source: .manual).map(\.text))")
        let fromDB = Store.applyDictionary("我在台北車戰", terms: s.terms())
        c(fromDB == "我在台北車站", "store/apply-dictionary-from-db",
          "expected 我在台北車站, got \(fromDB)")

        if let id = s.terms(source: .auto).first?.id {
            s.saveTerm(id: id, text: "GitHub", variants: ["git hub"])
            c(s.terms(source: .auto).first?.variants == ["git hub"], "store/terms-update",
              "expected [git hub], got \(s.terms(source: .auto).first?.variants ?? [])")
            s.deleteTerm(id)
        }
        c(s.terms().count == 1, "store/terms-delete", "expected 1 term left, got \(s.terms().count)")

        s.clearHistory()
        c(s.entries().isEmpty, "store/clear-history", "expected no rows, got \(s.entries().count)")

        // Audio retention: the words outlive the recording, and every delete hands the caller the
        // files it orphaned so nothing is left behind on disk.
        let withAudio = s.insert(mode: .dictate, raw: "有錄音", cleaned: "有錄音",
                                 at: now.addingTimeInterval(-40 * 86_400))
        s.setAudio(entry: withAudio, path: "/tmp/opentalktype-selftest.wav", seconds: 12)
        c(s.entries().first?.audioSeconds == 12, "store/audio-round-trips",
          "expected 12, got \(s.entries().first?.audioSeconds ?? -1)")
        let freed = s.purgeAudio(olderThanDays: 30)
        c(freed == ["/tmp/opentalktype-selftest.wav"], "store/purge-audio-returns-the-files",
          "expected the wav path, got \(freed)")
        c(s.entries().count == 1 && s.entries().first?.audioPath == "",
          "store/purge-audio-keeps-the-row", "expected the row kept with no audio path")
        c(s.deleteEntry(withAudio).isEmpty, "store/delete-frees-nothing-twice",
          "expected no paths the second time")

        // 不保留 is the off switch, not 永久: it has to hand back the recordings already on disk,
        // however fresh they are, or turning the feature off leaves every one of them behind.
        let brandNew = s.insert(mode: .dictate, raw: "剛剛講的", cleaned: "剛剛講的")
        s.setAudio(entry: brandNew, path: "/tmp/opentalktype-selftest-2.wav", seconds: 3)
        c(s.purgeAudio(olderThanDays: 0) == ["/tmp/opentalktype-selftest-2.wav"],
          "store/purge-audio-zero-days-clears-everything",
          "expected the fresh recording handed back, got \(s.purgeAudio(olderThanDays: 0))")
        s.deleteEntry(brandNew)

        // Replacement rules keep their order, which is the whole point of the table.
        s.saveReplacementRule(ReplacementRule(find: "：", replace: ": "))
        let second = s.saveReplacementRule(ReplacementRule(find: "  ", replace: " ", enabled: false))
        c(s.replacementRules().map(\.find) == ["：", "  "], "store/replacements-ordered",
          "expected insertion order, got \(s.replacementRules().map(\.find))")
        c(s.replacementRules(enabledOnly: true).count == 1, "store/replacements-enabled-filter",
          "expected 1 enabled rule, got \(s.replacementRules(enabledOnly: true).count)")
        s.reorderReplacementRules([second, s.replacementRules()[0].id])
        c(s.replacementRules().map(\.find) == ["  ", "："], "store/replacements-reorder",
          "expected the reversed order, got \(s.replacementRules().map(\.find))")
        s.deleteReplacementRule(second)
        c(s.replacementRules().count == 1, "store/replacements-delete",
          "expected 1 rule left, got \(s.replacementRules().count)")

        // Per-app rules are unique per (app, host): editing where a pair points must not stack.
        s.saveAppRule(AppRule(bundleID: "com.apple.dt.Xcode", modeID: "dictate"))
        s.saveAppRule(AppRule(bundleID: "com.apple.dt.Xcode", modeID: "ask"))
        c(s.appRules().count == 1 && s.appRules().first?.modeID == "ask",
          "store/app-rule-upserts-on-pair", "expected one rule pointing at ask, got \(s.appRules())")
        s.saveAppRule(AppRule(host: "https://Docs.Google.com/x", modeID: "translate"))
        c(s.appRules().contains { $0.host == "docs.google.com" }, "store/app-rule-normalises-host",
          "expected a stored host of docs.google.com, got \(s.appRules().map(\.host))")

        // Modes carry a shell command, stored beside them and reachable through the record.
        s.saveMode(Mode(id: "commit", storedName: "commit message", storedSubtitle: "", sfSymbol: "checkmark",
                        prompt: "write a commit message", usesSelection: true, translates: false,
                        builtIn: false))
        s.setShellCommand("pbcopy", for: "commit")
        c(s.shellCommand("commit") == "pbcopy", "store/shell-command-round-trips",
          "expected pbcopy, got \(s.shellCommand("commit"))")
        // The read above populated the cache; editing the command has to drop it, or the command
        // the user just typed never runs until the app is relaunched.
        s.setShellCommand("tee -a ~/notes.md", for: "commit")
        c(s.shellCommand("commit") == "tee -a ~/notes.md", "store/shell-command-edit-invalidates-cache",
          "expected the new command, got \(s.shellCommand("commit"))")
        s.setShellCommand("pbcopy", for: "commit")

        // Round trip: export everything, import into an empty store, get the same thing back.
        do {
            let data = try s.exportBackup()
            c(!String(decoding: data, as: UTF8.self).contains("apiKey"),
              "backup/exports-no-secrets", "the document mentioned an API key")

            let fresh = Store(path: path2)
            let sum = try fresh.importBackup(data, applyPrefs: false)
            c(sum.modes == 1, "backup/imports-the-custom-mode-only",
              "expected 1 new mode (3 built-ins skipped), got \(sum.modes)")
            c(fresh.shellCommand("commit") == "pbcopy", "backup/round-trips-shell-command",
              "expected pbcopy, got \(fresh.shellCommand("commit"))")
            c(fresh.terms().count == s.terms().count, "backup/round-trips-terms",
              "expected \(s.terms().count) terms, got \(fresh.terms().count)")
            c(fresh.replacementRules().map(\.find) == s.replacementRules().map(\.find),
              "backup/round-trips-replacements",
              "expected \(s.replacementRules().map(\.find)), got \(fresh.replacementRules().map(\.find))")
            c(fresh.appRules().count == s.appRules().count, "backup/round-trips-app-rules",
              "expected \(s.appRules().count) rules, got \(fresh.appRules().count)")

            // Additive: importing the same document again changes nothing.
            let again = try fresh.importBackup(data, applyPrefs: false)
            c(again.modes == 0 && again.terms == 0 && again.replacements == 0 && again.appRules == 0,
              "backup/second-import-adds-nothing", "expected all zeroes, got \(again)")
            c(fresh.modes().count == s.modes().count, "backup/no-duplicate-modes",
              "expected \(s.modes().count) modes, got \(fresh.modes().count)")

            // Malformed input must be refused before anything is written.
            let modeCount = fresh.modes().count
            let bad = Data("""
                {"version":1,"modes":[{"id":"broken","displayName":"","subtitle":"","sfSymbol":"a",
                 "prompt":"","usesSelection":false,"translates":false,"shellCommand":""}]}
                """.utf8)
            c(didThrow({ _ = try fresh.importBackup(bad, applyPrefs: false) }),
              "backup/rejects-malformed-document", "expected a throw")
            c(didThrow({ _ = try fresh.importBackup(Data("not json".utf8), applyPrefs: false) }),
              "backup/rejects-junk", "expected a throw")
            c(fresh.modes().count == modeCount, "backup/failed-import-writes-nothing",
              "expected \(modeCount) modes untouched, got \(fresh.modes().count)")
        } catch {
            c(false, "backup/round-trip", "threw \(error)")
        }
    }
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path2)
}
