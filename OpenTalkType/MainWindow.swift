import AppKit
import SwiftUI

// The main window: a fixed sidebar plus one of three panes.
//
// Reads Store and AppState, writes Prefs through @AppStorage. It owns the settings sheet
// presentation (the sheet's contents live in the settings file) and nothing else.

// MARK: - Shell

struct MainWindowView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                switch state.pane {
                case .home: HomePane(state: state)
                case .history: HistoryPane(state: state)
                case .dictionary: DictionaryPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: $state.showSettings) { SettingsSheet(state: state) }
        .task {
            // ponytail: onboarding is opened from here because this is the only view that
            // reliably exists at launch; move it into AppState.start() if a second window
            // ever needs to trigger it.
            if state.needsOnboarding { openWindow(id: "onboarding") }
        }
    }
}

private struct Sidebar: View {
    @Bindable var state: AppState

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenTalkType")
                    .font(Theme.heading)
                    .foregroundStyle(Theme.textPrimary)
                Text("版本 \(version)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xl)

            ForEach(Pane.allCases) { pane in
                SidebarRow(symbol: pane.sfSymbol, title: pane.displayName,
                           selected: state.pane == pane) { state.pane = pane }
            }

            Spacer(minLength: Theme.Space.xl)

            SidebarRow(symbol: SettingsTab.general.sfSymbol, title: "設定", selected: false) {
                state.settingsTab = .general
                state.showSettings = true
            }
            // ponytail: 說明 lands on the 關於 tab, which already carries the version, licence
            // and repository link. A dedicated help pane can replace this action later.
            SidebarRow(symbol: "questionmark.circle", title: "說明", selected: false) {
                state.settingsTab = .about
                state.showSettings = true
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

private struct SidebarRow: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title).font(Theme.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 7)
            .background(selected ? Theme.accentSoft : (hovering ? Theme.cardHover : .clear),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Home

private struct HomePane: View {
    @Bindable var state: AppState
    @State private var stats: Stats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("說出來，直接變成寫好的字")
                        .font(Theme.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("按住快捷鍵開始說話，放開就整理好貼進游標位置。")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                }

                ModesCard()
                StatsRail(stats: stats)
                StatusLine(state: state)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.xxl)
        }
        // Store.shared.revision is read here, in body, which is what makes the stats rail
        // refresh after a dictation, a 刪除 or a 清空全部.
        .task(id: Store.shared.revision) { stats = Store.shared.stats() }
    }
}

/// The cheat sheet. Every mode the user has, not the seeded three, with whatever key each one is
/// actually bound to right now.
private struct ModesCard: View {
    @AppStorage(Prefs.handsFreeLock) private var handsFree = true
    @State private var modes: [Mode] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    if index > 0 {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                            .padding(.vertical, Theme.Space.m)
                    }
                    HStack(alignment: .center, spacing: Theme.Space.l) {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(mode.subtitle)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: Theme.Space.l)
                        KeyCaps(mode.keyCaps)
                    }
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                TriggerHint(caps: ["fn"], text: "按住說話，放開就整理並貼上。")
                if handsFree {
                    TriggerHint(caps: ["fn ×2"], text: "連按兩下鎖住麥克風，手可以放開；說完再按一下 fn 結束。")
                }
                TriggerHint(caps: ["esc"], text: "取消這一次，不貼上也不留紀錄。")
            }
        }
        .card(padding: Theme.Space.xl)
        // Modes come from the database; the key caps come from UserDefaults, which SwiftUI has
        // no way to observe key by key once a user can invent their own modes. One reload on
        // any defaults change covers every binding, present and future.
        .task(id: Store.shared.revision) { modes = Mode.allCases }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) {
            _ in modes = Mode.allCases
        }
    }
}

private struct TriggerHint: View {
    let caps: [String]
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            KeyCaps(caps).frame(width: 90, alignment: .leading)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

private struct StatsRail: View {
    let stats: Stats?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            StatCard(title: "累積字數", value: number(stats?.totalWords), unit: "字")
            StatCard(title: "本週字數", value: number(stats?.weekWords), unit: "字")
            StatCard(title: "平均語速", value: stats.map { String(Int($0.averageWPM.rounded())) } ?? "--",
                     unit: "WPM")
            StatCard(title: "省下時間", value: stats.map { Self.saved($0.savedSeconds) } ?? "--",
                     unit: "以每分鐘 40 字打字計")
        }
    }

    private func number(_ v: Int?) -> String { v.map { $0.formatted() } ?? "--" }

    /// Negative means speaking was slower than typing would have been; show zero, not "-3 分鐘".
    static func saved(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 60 { return "\(minutes / 60) 小時 \(minutes % 60) 分" }
        return "\(minutes) 分鐘"
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct StatusLine: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            StatusPill(title: "麥克風", ok: state.micGranted,
                       detail: state.micGranted ? "已授權" : "未授權") {
                state.settingsTab = .permissions
                state.showSettings = true
            }
            StatusPill(title: "輔助使用", ok: state.axTrusted,
                       detail: state.axTrusted ? "已授權" : "未授權") {
                state.settingsTab = .permissions
                state.showSettings = true
            }
            StatusPill(title: "語音模型", ok: state.modelReady,
                       detail: state.modelStatus.isEmpty
                           ? (state.modelReady ? "就緒" : "尚未準備") : state.modelStatus) {
                state.settingsTab = .ai
                state.showSettings = true
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusPill: View {
    let title: String
    let ok: Bool
    let detail: String
    let fix: () -> Void

    var body: some View {
        Button(action: { if !ok { fix() } }) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(ok ? Theme.success : Theme.warning).frame(width: 7, height: 7)
                Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if !ok {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.card, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(ok ? detail : "點一下前往修正")
    }
}

// MARK: - History

private struct HistoryPane: View {
    @Bindable var state: AppState

    @AppStorage(Prefs.historyRetentionDays) private var retention = 30
    @State private var filter: Mode?
    @State private var query = ""
    @State private var entries: [Entry] = []
    @State private var expanded: Int64?
    @State private var confirmingClear = false

    private var groups: [(day: Date, items: [Entry])] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("紀錄").font(Theme.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("保留", selection: $retention) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永久").tag(0)
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: retention) {
                    Store.shared.purge(olderThanDays: retention)
                    reload()
                }
                Menu {
                    Button("清空全部", role: .destructive) { confirmingClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }

            Text("所有錄音與文字都留在這台 Mac，不會上傳。只有要整理的逐字稿會送到你自己設定的 AI 供應商。")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.s) {
                Chip(title: "全部", selected: filter == nil) { filter = nil }
                ForEach(Mode.allCases) { mode in
                    Chip(title: mode.displayName, symbol: mode.sfSymbol, selected: filter == mode) {
                        filter = mode
                    }
                }
                Spacer(minLength: Theme.Space.l)
                SearchField(text: $query, prompt: "搜尋紀錄").frame(width: 200)
            }

            if entries.isEmpty {
                EmptyState(
                    symbol: query.isEmpty && filter == nil ? "waveform" : "magnifyingglass",
                    title: query.isEmpty && filter == nil ? "還沒有任何紀錄" : "沒有符合的紀錄",
                    detail: query.isEmpty && filter == nil
                        ? "按住 fn 說一句話試試。每次聽寫、翻譯和問問題都會記在這裡，方便重新複製或重貼。"
                        : "換個關鍵字，或把篩選切回「全部」。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.l, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.day) { group in
                            Section {
                                VStack(spacing: Theme.Space.s) {
                                    ForEach(group.items) { entry in
                                        EntryRow(entry: entry,
                                                 expanded: expanded == entry.id,
                                                 toggle: { expanded = expanded == entry.id ? nil : entry.id },
                                                 repaste: { repaste(entry) },
                                                 remove: { remove(entry) })
                                    }
                                }
                            } header: {
                                Text(Self.dayLabel(group.day))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.vertical, Theme.Space.xs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.background)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .task(id: "\(filter?.rawValue ?? "-")|\(query)|\(Store.shared.revision)") { reload() }
        .confirmationDialog("要刪除全部紀錄嗎？", isPresented: $confirmingClear) {
            Button("刪除全部", role: .destructive) {
                Store.shared.clearHistory()
                reload()
            }
        } message: {
            Text("這會清掉所有聽寫、翻譯和問問題的紀錄，無法復原。字典不受影響。")
        }
    }

    private func reload() {
        entries = Store.shared.entries(mode: filter, search: query)
        if let id = expanded, !entries.contains(where: { $0.id == id }) { expanded = nil }
    }

    private func remove(_ entry: Entry) {
        Store.shared.deleteEntry(entry.id)
        reload()
    }

    /// ponytail: reuses the one insertion path in AppState by priming lastResult first, so
    /// history never grows its own copy of the paste logic.
    private func repaste(_ entry: Entry) {
        state.lastResult = entry.cleaned
        state.lastRaw = entry.raw
        Task { await state.repasteLast() }
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day().weekday(.wide))
    }
}

private struct EntryRow: View {
    let entry: Entry
    let expanded: Bool
    let toggle: () -> Void
    let repaste: () -> Void
    let remove: () -> Void

    @State private var hovering = false
    @State private var sound: NSSound?
    @State private var playing = false

    /// The row can outlive its recording: 保留錄音 purges files without touching history.
    private var hasAudio: Bool {
        !entry.audioPath.isEmpty && FileManager.default.fileExists(atPath: entry.audioPath)
    }

    /// ponytail: NSSound, no scrubber and no progress. Playing back a 20-second dictation to
    /// check what was actually said needs a play button and nothing else.
    private func togglePlayback() {
        sound?.stop()
        if playing { sound = nil; playing = false; return }
        sound = NSSound(contentsOfFile: entry.audioPath, byReference: true)
        playing = sound?.play() ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 62, alignment: .leading)
                    Image(systemName: entry.mode.sfSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(entry.cleaned.isEmpty ? entry.raw : entry.cleaned)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(expanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    detailColumn("原始逐字稿", entry.raw.isEmpty ? "（沒有留下逐字稿）" : entry.raw)
                    detailColumn("整理後", entry.cleaned.isEmpty ? "（整理失敗）" : entry.cleaned)
                }
                HStack(spacing: Theme.Space.s) {
                    Label(entry.mode.displayName, systemImage: entry.mode.sfSymbol)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if !entry.app.isEmpty {
                        Label(entry.app, systemImage: "app.dashed")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if !entry.model.isEmpty {
                        Label(entry.model, systemImage: "brain")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if hasAudio { Button(playing ? "停止" : "播放錄音", action: togglePlayback) }
                    Button("複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            entry.cleaned.isEmpty ? entry.raw : entry.cleaned, forType: .string)
                    }
                    Button("重新貼上", action: repaste)
                    Button("刪除", role: .destructive, action: remove)
                }
                .buttonStyle(.borderless)
                .font(Theme.body)
            }
        }
        .padding(Theme.Space.m)
        .background(hovering || expanded ? Theme.cardHover : Theme.card,
                    in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.stroke))
        .onHover { hovering = $0 }
        // NSSound has no completion without a delegate object; polling its own isPlaying is
        // shorter and also catches the user stopping it from somewhere else.
        .task(id: playing) {
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if sound?.isPlaying != true { playing = false }
            }
        }
    }

    private func detailColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    @AppStorage(Prefs.autoAddDictionaryTerms) private var autoAdd = true
    @State private var source: TermSource?
    @State private var query = ""
    @State private var terms: [Term] = []
    @State private var editing: Term?
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("字典").font(Theme.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    editing = nil
                    showingEditor = true
                } label: {
                    Label("新增詞彙", systemImage: "plus")
                }
            }

            Text("這些詞會在送進 AI 之前先做一次字面取代，也會附在提示裡，讓模型認得辨識不出來的專有名詞。要做整段改寫（含正規表示式）請用「設定 → 取代規則」，那是在 AI 整理完之後才跑的。")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("整理完自動把新出現的專有名詞加進字典", isOn: $autoAdd)
                .font(Theme.body)

            HStack(spacing: Theme.Space.s) {
                Chip(title: "全部", selected: source == nil) { source = nil }
                Chip(title: "自動加入", symbol: TermSource.auto.sfSymbol, selected: source == .auto) {
                    source = .auto
                }
                Chip(title: "手動加入", symbol: TermSource.manual.sfSymbol, selected: source == .manual) {
                    source = .manual
                }
                Spacer(minLength: Theme.Space.l)
                SearchField(text: $query, prompt: "搜尋詞彙").frame(width: 200)
            }

            if terms.isEmpty {
                EmptyState(
                    symbol: query.isEmpty && source == nil ? "character.book.closed" : "magnifyingglass",
                    title: query.isEmpty && source == nil ? "字典還是空的" : "沒有符合的詞彙",
                    detail: query.isEmpty && source == nil
                        ? "把名字、產品名或常被聽錯的專有名詞加進來。整理過程中發現的修正也會自動加入。"
                        : "換個關鍵字，或把篩選切回「全部」。")
            } else {
                ScrollView {
                    FlowLayout {
                        ForEach(terms) { term in
                            TermChip(term: term) {
                                editing = term
                                showingEditor = true
                            } remove: {
                                Store.shared.deleteTerm(term.id)
                                reload()
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .task(id: "\(source?.rawValue ?? "-")|\(query)|\(Store.shared.revision)") { reload() }
        .sheet(isPresented: $showingEditor) {
            TermEditor(term: editing) { text, variants in
                Store.shared.saveTerm(id: editing?.id, text: text, variants: variants)
                reload()
            }
        }
    }

    private func reload() { terms = Store.shared.terms(source: source, search: query) }
}

private struct TermChip: View {
    let term: Term
    let edit: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: edit) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: term.source.sfSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(term.source == .auto ? Theme.accent : Theme.textTertiary)
                Text(term.text).font(Theme.body).foregroundStyle(Theme.textPrimary)
                if !term.variants.isEmpty {
                    Text("\(term.variants.count)")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(hovering ? Theme.cardHover : Theme.card,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(term.variants.isEmpty ? term.text : "常被聽成：" + term.variants.joined(separator: "、"))
        .contextMenu {
            Button("編輯…", action: edit)
            Button("刪除", role: .destructive, action: remove)
        }
    }
}

private struct TermEditor: View {
    let term: Term?
    let save: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var variants = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(term == nil ? "新增詞彙" : "編輯詞彙")
                .font(Theme.heading)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("正確寫法").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                TextField("例如：Cloudflare", text: $text)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("常被聽成（選填）").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                TextField("用逗號分隔，例如：cloud fair, 克勞福", text: $variants, axis: .vertical)
                    .lineLimit(2...4)
                Text("辨識結果出現這些字時，會先換成上面的正確寫法。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("儲存") {
                    save(text.trimmingCharacters(in: .whitespacesAndNewlines), Self.split(variants))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 400)
        .background(Theme.background)
        .onAppear {
            text = term?.text ?? ""
            variants = term?.variants.joined(separator: ", ") ?? ""
        }
    }

    /// ponytail: comma separated instead of a row-per-variant editor. Splits on ASCII and
    /// full-width commas plus the Chinese enumeration comma, which covers real typing.
    static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { ",，、\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Shared bits

private struct Chip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(title).font(Theme.body)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentSoft : Theme.card,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 5)
        .background(Theme.card, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.heading).foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Left-to-right wrapping row of chips. SwiftUI ships no flow layout and an adaptive
/// LazyVGrid stretches every chip to the same width, which is not what the design wants.
private struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
