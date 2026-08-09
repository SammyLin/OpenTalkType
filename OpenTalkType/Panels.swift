import AppKit
import SwiftUI

// The two windows that are not the main window: the dictation HUD and first-run onboarding.

// MARK: - HUD

/// Where the HUD lives. `notch` grows a black plate out of the display's notch (VoiceInk style),
/// falling back to a pill under the menu bar on a screen without one; `bottom` is the original
/// floating pill above the Dock, kept for people on external displays.
enum HUDStyle: String {
    case notch, bottom

    /// The raw key must stay equal to `Prefs.hudStyle`. Read defensively: an unregistered default
    /// still lands on the notch, which is what this app ships with.
    static var current: HUDStyle {
        HUDStyle(rawValue: UserDefaults.standard.string(forKey: "hudStyle") ?? "") ?? .notch
    }
}

/// (centreX, width) of the notch, derived from the two menu-bar areas either side of the camera
/// housing. nil when the screen has no notch, which is also how a nil auxiliary area reads.
/// Pure, so the self-test can drive it without a display.
func notchCutout(leftMaxX: CGFloat?, rightMinX: CGFloat?) -> (centreX: CGFloat, width: CGFloat)? {
    guard let l = leftMaxX, let r = rightMinX, r - l > 1 else { return nil }
    return ((l + r) / 2, r - l)
}

/// The plate's measurements. `cutout` is the physical notch width, 0 on a screen without one,
/// in which case the same view renders as a plain pill.
struct HUDGeometry {
    /// One content column each side of the cutout. The plate has to stay symmetric about the
    /// notch centre, so both columns are this wide even though the meter needs less than the text.
    /// Sized to its contents, not to a guess. Rendered offscreen and compared: at 108 the two
    /// clusters are stranded at the far ends of a wide black bar; at 48 the meter clips.
    static let wing: CGFloat = 62
    static let grow: CGFloat = 6       // menu-bar height plus a lip, like VoiceInk
    /// The shoulders. A plain rounded rect with a flat top reads as a black slab stuck under the
    /// menu bar; the top corners have to curve INWARD so the plate flares out of the notch the way
    /// the hardware does. Radii follow sk-ruban/notchi, which solved this first.
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 10
    static let openBottomRadius: CGFloat = 12
    static let radius: CGFloat = 12

    let cutout: CGFloat
    let barHeight: CGFloat

    var plateWidth: CGFloat { cutout + Self.wing * 2 }
    /// Thinking drops the meter, so the wings have almost nothing in them. Narrow the plate to
    /// match rather than leaving a wide black bar with two small things at its ends.
    /// Only while a cleanup is dragging: the seconds need room the meter did not. Normally
    /// thinking is a spinner in the same footprint as listening.
    var waitingWidth: CGFloat { cutout + Self.wing * 2 + 84 }
    var plateHeight: CGFloat { barHeight + Self.grow }
    /// Collapsed, the plate is exactly the notch: black on black, so idle shows nothing at all.
    var collapsedWidth: CGFloat { cutout }
    var collapsedHeight: CGFloat { cutout > 0 ? barHeight : 0 }
    /// Flush with the top of the screen, so the plate reads as one piece with the notch.
    var topRadius: CGFloat { cutout > 0 ? 0 : Self.radius }
    var wing: CGFloat { Self.wing }
}

/// Top-flush placement: the panel hangs from `screenTop`, centred on the notch centre.
func hudFrame(screenTop: CGFloat, centreX: CGFloat, size: CGSize) -> NSRect {
    NSRect(x: centreX - size.width / 2, y: screenTop - size.height,
           width: size.width, height: size.height)
}

/// Drives the grow / shrink. Separate from AppState because the panel outlives the phase by the
/// length of the collapse animation.
@MainActor
@Observable
final class HUDModel {
    var open = false
}

/// Borderless, non-activating. It must never take key focus, or every keystroke after a dictation
/// lands here instead of in the app the user was typing into.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?

    private static let grow = Animation.easeOut(duration: 0.2)
    private static let shrink = Animation.easeIn(duration: 0.16)

    func show(_ state: AppState) {
        hideTask?.cancel()
        hideTask = nil
        let panel = self.panel ?? make()
        self.panel = panel
        // Collapsed first, then one forced layout pass, so the grow animates even on the very
        // first dictation when the hosting view is built from scratch.
        model.open = false
        place(panel, state)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        withAnimation(Self.grow) { model.open = true }
    }

    func hide() {
        withAnimation(Self.shrink) { model.open = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }   // a new dictation started mid-collapse
            self?.panel?.orderOut(nil)
        }
    }

    private func make() -> NSPanel {
        let panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// The screen under the pointer, which is where the user is looking and typing.
    private var activeScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    /// Rebuilds the content for the current screen and style on every show. Cheaper than tracking
    /// which display the pointer moved to since last time.
    private func place(_ panel: NSPanel, _ state: AppState) {
        guard let screen = activeScreen else { return }

        guard HUDStyle.current == .notch else {
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: HUDView(state: state, model: model))
            let area = screen.visibleFrame
            panel.setFrame(NSRect(x: area.midX - 160, y: area.minY + 96, width: 320, height: 56),
                           display: false)
            return
        }

        let cut = notchCutout(leftMaxX: screen.auxiliaryTopLeftArea?.maxX,
                              rightMinX: screen.auxiliaryTopRightArea?.minX)
        // safeAreaInsets.top is the notch height; the auxiliary area's own height is the backstop.
        // ponytail: a screen that reports an inset but no auxiliary areas gets the pill, because
        // the cutout WIDTH is unknowable there. Upgrade path: read the display's camera housing
        // size from CoreGraphics if such a Mac ever shows up.
        let inset = screen.safeAreaInsets.top
        let bar = inset > 0 ? inset : (screen.auxiliaryTopLeftArea?.height ?? 0)
        let geo = HUDGeometry(cutout: cut?.width ?? 0, barHeight: cut == nil ? 24 : max(bar, 24))
        let centreX = cut?.centreX ?? screen.frame.midX
        // With a notch the plate must touch the very top of the screen; without one it hangs just
        // under the menu bar instead.
        let top = cut == nil ? screen.visibleFrame.maxY - 8 : screen.frame.maxY

        panel.hasShadow = cut == nil   // a flush-top plate with a shadow ring looks detached
        panel.contentView = NSHostingView(rootView: NotchHUDView(state: state, model: model, geo: geo))
        panel.setFrame(hudFrame(screenTop: top, centreX: centreX,
                                size: CGSize(width: geo.plateWidth, height: geo.plateHeight)),
                       display: false)
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The notch silhouette: top corners curving INWARD so the plate grows out of the notch's
/// shoulders, bottom corners rounded normally. A flat-topped rounded rect is what made this look
/// like a black bar taped under the menu bar.
///
/// Adapted from sk-ruban/notchi (MIT), which worked this out first.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    /// Animatable so growing and shrinking sweeps the corners instead of snapping them.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topCornerRadius, rect.width / 2)
        let b = min(bottomCornerRadius, max(0, rect.width / 2 - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return p
    }
}

/// The notch plate. Content sits in two columns either side of the cutout rather than below it:
/// the physical notch is opaque hardware, so anything under it is simply gone, and stacking the
/// content below would double the plate's height for every dictation.
private struct NotchHUDView: View {
    let state: AppState
    let model: HUDModel
    let geo: HUDGeometry
    /// A cleanup that runs long enough to worry about earns the seconds counter and the room to
    /// show it. Below that it is a spinner, because widening the plate on every dictation is the
    /// kind of motion that makes a menu bar feel busy.
    @State private var slow = false

    private var showSeconds: Bool { state.phase == .thinking && slow }

    var body: some View {
        let open = model.open
        let width = open ? (showSeconds ? geo.waitingWidth : geo.plateWidth) : geo.collapsedWidth
        let top = open ? HUDGeometry.openTopRadius : HUDGeometry.closedTopRadius
        let bottom = open ? HUDGeometry.openBottomRadius : HUDGeometry.closedBottomRadius

        return ZStack(alignment: .top) {
            columns
                // Inset by the shoulder radius on both sides: the top corners curve INWARD, so
                // content laid out to the full width is clipped by the flare. This is what was
                // overflowing.
                .padding(.horizontal, top)
                .frame(width: width, height: geo.plateHeight)
                .opacity(open ? 1 : 0)
        }
        .frame(width: width,
               height: open ? geo.plateHeight : geo.collapsedHeight,
               alignment: .top)
        .background(.black)
        .clipShape(NotchShape(topCornerRadius: geo.cutout > 0 ? top : 0, bottomCornerRadius: bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: state.phase) {
            slow = false
            guard state.phase == .thinking else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { slow = true }
        }
    }

    /// Deliberately wordless, the way VoiceInk's notch recorder is. A line of live transcript in
    /// the menu bar is a lot of motion in the corner of the eye for information nobody reads
    /// while speaking, and it is what made this look like a black bar rather than part of the
    /// hardware. Status left of the cutout, level right of it, nothing else.
    private var columns: some View {
        HStack(spacing: 0) {
            // Just the dot. The mode icon that used to sit here said the same thing as the meter
            // opposite it, in a plate with barely any room to say anything twice.
            Circle()
                .fill(state.phase == .listening ? Color.red : Theme.accent)
                .frame(width: 8, height: 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Theme.Space.s)
            .frame(width: geo.wing)

            Color.clear.frame(width: geo.cutout)

            HStack(spacing: 6) {
                if state.phase == .thinking {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.8))
                    if showSeconds {
                        ThinkingLabel(color: .white.opacity(0.75))
                            .font(.system(size: 11))
                            .fixedSize()
                    }
                } else {
                    Meter(level: state.micLevel, dim: .white.opacity(0.18))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Space.s)
            .frame(width: showSeconds ? geo.wing + 84 : geo.wing)
        }
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }
}

/// The original bottom-centre pill, unchanged apart from fading with the shared open/close.
private struct HUDView: View {
    let state: AppState
    let model: HUDModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: state.mode.sfSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)

            if state.phase == .thinking {
                // The elapsed count is the whole point: the Claude Code CLI cold-starts for ten
                // seconds or more, and a motionless "整理中…" reads as a frozen app.
                ThinkingLabel()
                Spacer(minLength: 0)
            } else {
                Meter(level: state.micLevel)
                Text(state.partialText.isEmpty ? "請開始說話…" : state.partialText)
                    .font(Theme.caption)
                    .foregroundStyle(state.partialText.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(width: 320, height: 56)
        .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.stroke))
        .opacity(model.open ? 1 : 0)
        .scaleEffect(model.open ? 1 : 0.96)
    }
}

private struct ThinkingLabel: View {
    var color: Color = Theme.textSecondary

    @State private var seconds = 0

    var body: some View {
        Text(seconds < 2 ? "整理中…" : "整理中… \(seconds) 秒")
            .font(Theme.caption)
            .foregroundStyle(color)
            .monospacedDigit()
            .task {
                seconds = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    seconds += 1
                }
            }
    }
}

private struct Meter: View {
    let level: Float
    var dim: Color = Theme.stroke

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / 10 < level ? Theme.accent : dim)
                    .frame(width: 2, height: 4 + 10 * sin(.pi * Double(i) / 9))
            }
        }
        .frame(width: 38)
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - Onboarding

/// Five steps, in the order they can actually fail: microphone, Accessibility, the fn key,
/// the provider, then one real end-to-end sentence that says which stage broke.
struct OnboardingView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0

    private static let titles = ["麥克風", "輔助使用", "fn 鍵", "AI 供應商", "試講一句"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("第 \(step + 1) / 5 步")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(Self.titles[step])
                    .font(Theme.title)
                    .foregroundStyle(Theme.textPrimary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch step {
                    case 0: MicStep(state: state)
                    case 1: AXStep(state: state)
                    case 2: FnStep()
                    case 3: ProviderStep()
                    default: TestStep(state: state)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Theme.accent : Theme.stroke)
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 } }
                if step < 4 {
                    Button("下一步") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") {
                        UserDefaults.standard.set(true, forKey: Prefs.hasOnboarded)
                        state.needsOnboarding = false
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .task { state.refreshPermissions() }
    }
}

private struct MicStep: View {
    @Bindable var state: AppState

    var body: some View {
        StepBody(text: "OpenTalkType 需要麥克風才能聽你說話。辨識全部在這台 Mac 上完成，聲音不會離開電腦。") {
            HStack(spacing: Theme.Space.m) {
                Button("允許使用麥克風") {
                    Task {
                        _ = await Permissions.requestMic()
                        state.refreshPermissions()
                        // The language model is a few hundred MB; start it now so the first
                        // sentence is not spent waiting.
                        await state.speech?.prepareModel()
                    }
                }
                .disabled(state.micGranted)
                StatusDot(ok: state.micGranted, text: state.micGranted ? "已授權" : "尚未授權")
            }
            if !state.modelStatus.isEmpty {
                Text(state.modelStatus).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct AXStep: View {
    @Bindable var state: AppState

    var body: some View {
        StepBody(text: "「輔助使用」權限讓 OpenTalkType 可以偵測 fn 鍵，並把整理好的文字貼到你正在打字的位置。沒有它，文字只會留在剪貼簿。") {
            HStack(spacing: Theme.Space.m) {
                Button("開啟輔助使用設定") {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                    state.armHotkeys()
                }
                Button("重新檢查") { state.refreshPermissions() }
                StatusDot(ok: state.axTrusted, text: state.axTrusted ? "已授權" : "尚未授權")
            }
            Text("勾選之後回到這裡，狀態會自動變成已授權。")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct FnStep: View {
    var body: some View {
        StepBody(text: "三種模式都按住 fn（有些鍵盤標成 🌐）開始，放開就送出。") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Mode.allCases) { mode in
                    HStack(spacing: Theme.Space.m) {
                        KeyCaps(mode.keyCaps)
                        Text(mode.displayName).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        Text(mode.subtitle).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text("如果按 fn 會跳出輸入法或表情符號面板，請到「系統設定 → 鍵盤 → 按下 🌐 鍵時」改成「不執行任何動作」。")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderStep: View {
    var body: some View {
        StepBody(text: "整理文字需要一個大型語言模型。金鑰存在 macOS 鑰匙圈，只會送到你選的供應商。") {
            ProviderFields()
        }
    }
}

/// The real pipeline, end to end, reporting the stage that failed rather than a single
/// "something went wrong".
private struct TestStep: View {
    @Bindable var state: AppState

    private struct Stage: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    @State private var stages: [Stage] = []
    @State private var recording = false
    @State private var pasted = ""
    @FocusState private var pasteFocused: Bool

    var body: some View {
        StepBody(text: "按下「開始說話」，說一句話，再按「停止」。這會真的跑一次完整流程：麥克風、辨識、AI 整理、自動貼上。") {
            HStack(spacing: Theme.Space.m) {
                if recording {
                    Button("停止") { Task { await end() } }.keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("開始說話") { Task { await begin() } }
                }
                if recording {
                    Text(state.partialText.isEmpty ? "聆聽中…" : state.partialText)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }

            TextField("整理好的文字會貼進這裡", text: $pasted)
                .focused($pasteFocused)
                .frame(width: 380)

            ForEach(stages) { stage in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: stage.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(stage.ok ? Theme.success : Theme.danger)
                    Text(stage.name).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .frame(width: 80, alignment: .leading)
                    Text(stage.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func add(_ name: String, _ ok: Bool, _ detail: String) {
        stages.append(Stage(name: name, ok: ok, detail: detail))
    }

    private func begin() async {
        stages = []
        pasted = ""
        state.refreshPermissions()
        add("麥克風", state.micGranted, state.micGranted ? "已授權" : "尚未授權，請回到第 1 步")
        guard state.micGranted, let speech = state.speech else { return }
        // AppState.phase is the app's only mutual exclusion over the one SpeechEngine. Drive it
        // from here too, or an fn press mid-test starts a second session on the same engine.
        guard state.phase == .idle else {
            add("錄音", false, "正在進行另一次聽寫，放開 fn 之後再試一次")
            return
        }
        state.phase = .listening
        do {
            try await speech.start(phrases: Store.shared.terms().map(\.text))
            recording = true
        } catch {
            state.phase = .idle
            add("錄音", false, error.localizedDescription)
        }
    }

    private func end() async {
        guard let speech = state.speech else { return }
        recording = false
        state.phase = .thinking
        defer { state.phase = .idle }
        let raw = await speech.stop()
        add("語音辨識", !raw.isEmpty, raw.isEmpty ? "沒有聽到任何內容，換個麥克風或說大聲一點" : raw)
        guard !raw.isEmpty else { return }
        do {
            let cleaned = try await state.process(raw, mode: .dictate, selection: nil)
            add("AI 整理", true, cleaned)
            pasteFocused = true
            let ok = await insertText(cleaned)
            add("自動貼上", ok, ok ? "已貼進上面的欄位" : "沒有輔助使用權限，文字留在剪貼簿")
        } catch {
            add("AI 整理", false, error.localizedDescription)
        }
    }
}

// MARK: - Step chrome

private struct StepBody<Content: View>: View {
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusDot: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(ok ? Theme.success : Theme.warning).frame(width: 7, height: 7)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Self-test

/// The notch maths, which nothing else can check: it only runs on hardware that has a notch.
func selfTestPanels(_ c: SelfTest.Check) {
    // Measured on this machine's built-in display: 1728x1117, auxiliary areas meeting the notch
    // at x = 771 and x = 956, safeAreaInsets.top = 32.
    let n = notchCutout(leftMaxX: 771, rightMinX: 956)
    c(n?.width == 185, "notch/width", "expected 185, got \(n.map { "\($0.width)" } ?? "nil")")
    c(n?.centreX == 863.5, "notch/centre", "expected 863.5, got \(n.map { "\($0.centreX)" } ?? "nil")")
    c(notchCutout(leftMaxX: nil, rightMinX: 956) == nil,
      "notch/absent-when-no-camera-housing", "expected nil for a screen with no auxiliary areas")
    c(notchCutout(leftMaxX: 800, rightMinX: 800) == nil,
      "notch/absent-when-areas-touch", "expected nil when the two areas meet")

    let g = HUDGeometry(cutout: 185, barHeight: 32)
    // Invariants, not the constants restated: restating them makes the check fail on every
    // deliberate design tweak while catching no actual defect.
    c(g.plateWidth > g.cutout && (g.plateWidth - g.cutout).truncatingRemainder(dividingBy: 2) == 0,
      "hud/plate-symmetric-about-notch",
      "the wings must be equal, got plate \(g.plateWidth) around cutout \(g.cutout)")
    c(g.plateHeight > g.barHeight, "hud/plate-hangs-below-notch",
      "expected the plate to drop below the notch, got \(g.plateHeight) vs bar \(g.barHeight)")
    c(g.waitingWidth > g.plateWidth, "hud/waiting-widens-for-seconds",
      "a slow cleanup needs room the meter did not, got \(g.waitingWidth) vs \(g.plateWidth)")
    c(g.plateWidth - g.cutout < g.cutout, "hud/wings-narrower-than-notch",
      "the wings hold a dot and a meter; wider than the notch itself reads as a black bar")
    c(g.collapsedWidth == 185 && g.collapsedHeight == 32, "hud/collapsed-matches-notch",
      "expected 185x32, got \(g.collapsedWidth)x\(g.collapsedHeight)")
    c(g.topRadius == 0, "hud/top-flush", "expected square top corners, got radius \(g.topRadius)")

    let pill = HUDGeometry(cutout: 0, barHeight: 24)
    c(pill.topRadius > 0 && pill.collapsedWidth == 0 && pill.collapsedHeight == 0,
      "hud/pill-fallback-without-notch",
      "expected a fully rounded pill collapsing to nothing, got radius \(pill.topRadius), "
      + "collapsed \(pill.collapsedWidth)x\(pill.collapsedHeight)")

    let f = hudFrame(screenTop: 1117, centreX: 863.5,
                     size: CGSize(width: g.plateWidth, height: g.plateHeight))
    c(f.maxY == 1117, "hud/placement-flush-with-screen-top", "expected maxY 1117, got \(f.maxY)")
    c(f.midX == 863.5, "hud/placement-centred-on-notch", "expected midX 863.5, got \(f.midX)")
}
