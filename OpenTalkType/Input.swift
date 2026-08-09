import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled, and nothing else

// The input layer: one CGEvent tap driving all three fn triggers, pasteboard insertion,
// selection reading, and the two permissions everything here depends on.
//
// Everything below is main-thread work. The tap callback runs on the main run loop, so it
// only flips state and hands off -- no awaits, no disk, no network in there, because a slow
// callback is exactly what gets the tap disabled by timeout.

// MARK: - Physical key codes

private enum Key {
    static let fn: Int64 = 63          // kVK_Function -- the only event whose fn bit is trustworthy
    static let space: Int64 = 49
    static let v: CGKeyCode = 9        // physical V: "X - QWERTY Command" remaps the character under ⌘
    static let c: CGKeyCode = 8
    static let escape: Int64 = 53      // cancel a session already in progress
    static let command: CGKeyCode = 55
    static let ret: CGKeyCode = 36     // auto-submit
}

/// Device-dependent modifier bits. macOS reports left and right separately here; the plain
/// .maskShift can not tell them apart, and the whole point of fn + LEFT shift is that right
/// shift stays a normal shift.
private enum DeviceBit {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let leftCommand: UInt64 = 0x0000_0008
    static let leftOption: UInt64 = 0x0000_0020
}

/// Which bound-able companion keys are physically down, left side only.
private func companionsDown(_ flags: CGEventFlags) -> Set<Companion> {
    var s: Set<Companion> = []
    let raw = flags.rawValue
    if raw & DeviceBit.leftShift != 0 { s.insert(.leftShift) }
    if raw & DeviceBit.leftControl != 0 { s.insert(.leftControl) }
    if raw & DeviceBit.leftOption != 0 { s.insert(.leftOption) }
    if raw & DeviceBit.leftCommand != 0 { s.insert(.leftCommand) }
    return s
}

// MARK: - Mode latching

/// The trigger decision, pulled out of the tap so it can be driven by a synthetic sequence.
/// Holds no AppKit and reads no preferences: the bindings are handed in.
struct ModeLatch {
    /// A companion key pressed within this long after fn-down still upgrades the mode.
    /// Humans do not hit two keys on the same millisecond; after it, the mode is latched.
    static let grace: TimeInterval = 0.25

    /// Two fn-downs inside this window are a double tap, which locks the session hands-free.
    /// It is also how long a short release stays undecided: the release cannot know yet whether
    /// a second press is coming, so it parks in .pending and waits for expire().
    static let doubleTap: TimeInterval = 0.4

    enum Action: Equatable { case start(Mode), upgrade(Mode), lock, stop }

    /// .pending is the only non-obvious one: fn was released quickly, the microphone is still on,
    /// and the next fn-down within doubleTap locks instead of starting a new session.
    /// .ending is the fn-down that stops a locked session, held until its own release.
    private enum State { case idle, holding, pending, locked, ending }

    /// Ordered, and the ONLY thing resolve consults. It used to read Mode.allCases directly,
    /// which made the latch depend on whatever modes happened to be in the database -- a user
    /// adding one changed what bare fn did, and the self-test read live user data.
    var bindings: [(mode: Mode, companion: Companion)] = []

    /// Off restores the pre-double-tap behaviour exactly: every release stops, nothing parks.
    var handsFree = true

    private(set) var mode: Mode = .dictate
    private var state: State = .idle
    private var fnAt: TimeInterval = 0
    /// Running union of every companion seen since fn went down. Latching has to be monotonic:
    /// lifting left Shift a moment after fn -- the natural way to use a mode-selecting modifier --
    /// must not silently demote a translate session back to dictate.
    private var seen: Set<Companion> = []

    /// Recording with nothing held. The HUD reads this to say so, and the next fn-down ends it.
    var isLocked: Bool { state == .locked }

    /// A short release is not a stop yet. Whoever drove that release MUST arrange for expire() to
    /// be called once doubleTap has passed, or the microphone stays on with no event coming.
    var awaitingSecondTap: Bool { state == .pending }

    /// fn itself went down or up. `keys` is what was already held at that instant.
    mutating func fn(_ down: Bool, keys: Set<Companion> = [], at t: TimeInterval) -> Action? {
        if down {
            switch state {
            case .holding, .ending:
                return nil                      // key repeat, or a re-armed tap replaying state
            case .locked:
                state = .ending                 // stop now; swallow the release that follows
                seen = []
                return .stop
            case .pending:
                // Anything outside the window has already been turned into a .stop by expire(),
                // which the caller runs before this, so reaching here means a real double tap.
                state = .locked
                return .lock
            case .idle:
                state = .holding
                fnAt = t
                seen = keys
                mode = resolve(seen)
                return .start(mode)
            }
        }
        switch state {
        case .holding:
            // A long hold is push-to-talk and ends here. A short one might be half a double tap.
            if handsFree, t - fnAt <= Self.doubleTap { state = .pending; return nil }
            state = .idle
            seen = []
            return .stop
        case .ending:
            state = .idle
            return nil
        default:
            return nil                          // release with no press, or the lock's own release
        }
    }

    /// The double-tap window closed with no second press, so the short tap was an ordinary
    /// session after all. Safe to call at any time; it only ever fires from .pending.
    mutating func expire(at t: TimeInterval) -> Action? {
        guard state == .pending, t - fnAt > Self.doubleTap else { return nil }
        state = .idle
        seen = []
        return .stop
    }

    /// Escape, or anything else that abandons the session outright. Deliberately not an Action:
    /// the caller is already telling AppState to cancel, this just stops the latch arguing.
    mutating func cancel() {
        state = .idle
        seen = []
    }

    /// A companion key changed while fn is held. Only counts inside the grace window, and only
    /// ever adds: see `seen`.
    mutating func companions(_ keys: Set<Companion>, at t: TimeInterval) -> Action? {
        guard state == .holding, t - fnAt <= Self.grace else { return nil }
        seen.formUnion(keys)
        let m = resolve(seen)
        guard m != mode else { return nil }
        mode = m
        return .upgrade(m)
    }

    /// Is this key bound to anything? The tap swallows a bound space so it never reaches the app.
    func binds(_ c: Companion) -> Bool { bindings.contains { $0.companion == c } }

    /// First mode whose companion is held wins; otherwise the mode bound to bare fn.
    private func resolve(_ keys: Set<Companion>) -> Mode {
        bindings.first { $0.companion != .none && keys.contains($0.companion) }?.mode
            ?? bindings.first { $0.companion == .none }?.mode
            ?? bindings.first?.mode
            ?? .dictate
    }
}

// MARK: - HotkeyWatcher

/// One session event tap for all three triggers. AppState owns it strongly -- the tap holds it
/// unretained through refcon, so dropping this reference is a use-after-free in the callback.
///
/// @unchecked Sendable, and the invariant behind it: every line of this class runs on the main
/// thread. The tap's run loop source is added to the main run loop, and the double-tap timer is
/// a main-queue asyncAfter. Nothing here may ever be touched from the audio thread or a C callback
/// on another thread.
final class HotkeyWatcher: @unchecked Sendable {
    private let state: AppState
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var latch = ModeLatch()
    private var fnDown = false
    private var spaceDown = false

    init(_ state: AppState) { self.state = state }

    deinit { stop() }

    /// Recording hands-free after a double tap. Read by the HUD, which redraws on every partial
    /// transcript anyway, so it does not need to be observable.
    var isLocked: Bool { latch.isLocked }

    /// False means no Accessibility permission: with a keys-only mask the tap comes back nil
    /// exactly when the grant is missing, which makes this a reliable permission probe.
    @discardableResult
    func start() -> Bool {
        if let t = tap, CGEvent.tapIsEnabled(tap: t) { return true }
        stop()

        // Keys only. Adding any other event type still yields a non-nil tap that is deaf forever,
        // and without the grant the key bits are silently cleared rather than failing loudly.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // .cgSessionEventTap, not .cgHidEventTap: the HID level returns nil for any non-root process.
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let w = Unmanaged<HotkeyWatcher>.fromOpaque(refcon).takeUnretainedValue()
                // Re-arm first, before any keycode logic: these arrive after a slow callback,
                // display sleep or a screen lock, and an unhandled one kills the hotkey for good.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    w.rearm()
                    return nil
                }
                return w.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = s
        // .commonModes, not .defaultMode, or the hotkey dies while a menu is open or a window is dragged.
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)

        // Seed: flagsChanged never fires for a key that was already held when we started.
        fnDown = NSEvent.modifierFlags.contains(.function)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        source = nil
        tap = nil
    }

    /// The tap was disabled underneath us. Re-enable, then synthesize a release for whatever was
    /// held, or the app sits in "recording" forever with no event coming to end it.
    fileprivate func rearm() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        spaceDown = false
        // Re-seed rather than assume: the user may well still be mid-hold, and killing that
        // session would also throw away the fn-down that armed it -- no event is coming to redo it.
        fnDown = NSEvent.modifierFlags.contains(.function)
        guard !fnDown else { return }
        releaseFn(at: now())
    }

    /// fn came up, for real or synthetically. Split out because a release that parks in .pending
    /// owes the latch an expire() call, and forgetting it anywhere leaves the microphone on.
    private func releaseFn(at t: TimeInterval) {
        apply(latch.fn(false, at: t))
        guard latch.awaitingSecondTap else { return }
        // The window is measured from fn-down, so firing a full doubleTap after the release is
        // always late enough for expire()'s own check to pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + ModeLatch.doubleTap) { [weak self] in
            guard let self else { return }
            apply(latch.expire(at: now()))
        }
    }

    /// Returns true to swallow the event. Runs on the main run loop; keep it arithmetic only.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let t = now()

        if type == .flagsChanged {
            if code == Key.fn {
                // The fn bit is set on arrow keys, F-keys and Home/End/PgUp/PgDn whether or not fn
                // is physically held. Only keyCode 63 tells the truth, so only trust it here.
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != fnDown else { return false }
                fnDown = down
                if down {
                    // Settle any half-finished double tap first: a timer that has not fired yet
                    // would otherwise let a press well outside the window look like the second tap.
                    apply(latch.expire(at: t))
                    // Re-read the bindings each press so a rebind takes effect without a restart.
                    latch.bindings = Mode.allCases.map { ($0, Prefs.companion($0)) }
                    latch.handsFree = Prefs.handsFreeLockEnabled
                    apply(latch.fn(true, keys: held(event.flags), at: t))
                } else {
                    spaceDown = false
                    releaseFn(at: t)
                }
            } else if fnDown {
                apply(latch.companions(held(event.flags), at: t))
            }
            // Never swallow a modifier. WindowServer updates modifier state upstream of a session
            // tap, so suppressing one leaves a stuck fn flag system-wide.
            return false
        }

        // Escape abandons a session in flight. Only swallowed while actually recording, so it
        // keeps working normally everywhere else.
        if type == .keyDown, code == Key.escape, fnDown || isRecording() {
            spaceDown = false
            latch.cancel()                      // also drops a hands-free lock, which has no key to release
            let state = state
            MainActor.assumeIsolated { state.cancelDictation() }
            return true
        }

        guard code == Key.space, latch.binds(.space) else { return false }
        if type == .keyDown {
            guard fnDown else { return false }
            spaceDown = true
            apply(latch.companions(held(event.flags), at: t))
            return true   // swallowed, so the space never leaks into the frontmost app
        }
        // Only swallow the keyUp of a keyDown we actually ate. Otherwise a space held from before
        // fn went down loses its keyUp, and the target app autorepeats spaces forever.
        let ours = spaceDown
        spaceDown = false
        return ours
    }

    private func held(_ flags: CGEventFlags) -> Set<Companion> {
        var s = companionsDown(flags)
        if spaceDown { s.insert(.space) }
        return s
    }

    private func apply(_ action: ModeLatch.Action?) {
        guard let action else { return }
        // Capture the state locally: AppState is @MainActor, hence Sendable, while the watcher
        // is not. Reaching through `self` inside the closure would send a non-Sendable value.
        let state = state
        MainActor.assumeIsolated {
            switch action {
            case .start(let m): state.startDictation(m)
            case .upgrade(let m): state.mode = m   // recording already runs; only the prompt changes
            case .lock: break                      // already recording; the HUD reads isLocked
            case .stop: state.stopDictation()
            }
        }
    }

    /// Asked of AppState rather than tracked here: fn can be released before the engine has
    /// actually stopped, and Escape should still cancel during that window.
    private func isRecording() -> Bool {
        let state = state
        return MainActor.assumeIsolated { state.phase != .idle }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - Pasteboard insertion

private let stampType = NSPasteboard.PasteboardType("ai.3mi.opentalktype.session")

/// Clipboard-manager opt-outs, so dictated text does not pollute clipboard history.
private var concealmentTypes: [NSPasteboard.PasteboardType] {
    ["org.nspasteboard.TransientType",
     "org.nspasteboard.ConcealedType",
     "org.nspasteboard.AutoGeneratedType"].map(NSPasteboard.PasteboardType.init(rawValue:))
}

/// Put text in front of the cursor: pasteboard plus ⌘V by default, or synthesized unicode
/// keystrokes for the apps that ignore a synthetic paste. Then, optionally, Return.
///
/// False means Accessibility is missing, in which case the text is left on the clipboard so the
/// user can paste it by hand. Secure input also leaves the text on the clipboard, but returns
/// true: it is not a permission problem and it gets its own, accurate notification.
///
/// Async because the waits below must not block: this runs on the main actor, whose run loop is
/// also the event tap's, and a stalled run loop is exactly what earns a .tapDisabledByTimeout.
@discardableResult
func insertText(_ text: String) async -> Bool {
    guard !text.isEmpty else { return true }
    let body = text + (Prefs.appendsTrailingSpace ? " " : "")

    guard Permissions.axTrusted else {
        _ = writePasteboard(body, token: nil)
        return false
    }

    // Nothing synthetic reaches a secure field, so posting ⌘V would silently do nothing at all.
    if SecureInput.enabled {
        _ = writePasteboard(body, token: nil)
        await MainActor.run {
            AppState.shared.notify(String(localized: "Cannot paste while secure input is on"),
                                   SecureInput.advice)
        }
        return true
    }

    // A still-held fn or shift is ORed into the synthesized keystroke by the receiving app and
    // corrupts the paste, so let the user's fingers come off first.
    await waitForModifiersToClear()

    // The session's mode, not a parameter: every caller inserts the text of the session AppState
    // is still holding, and threading a mode through three call sites buys nothing.
    let submit = await MainActor.run { Prefs.autoSubmits(AppState.shared.mode) }

    if Prefs.pasteMethodValue == .type {
        await typeText(body)
        // No read receipt needed: the Return is posted into the same HID event stream behind the
        // characters, so the app cannot process it before them.
        if submit { postKey(Key.ret) }
        return true
    }

    let backup = snapshotPasteboard()
    let token = UUID().uuidString
    // Only auto-submit pays for the promise. A promised .string means the app has to ask us for
    // the text, and that request is the one honest signal that the paste landed -- posting Return
    // on a timer instead submits whatever was in the field when the paste had not arrived yet.
    let receipt = submit ? PasteReceipt(body) : nil
    var count = writePasteboard(body, token: token, promise: receipt)
    postCommandKey(Key.v)

    if let receipt {
        let deadline = Date().addingTimeInterval(2)
        while !receipt.read, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if receipt.read {
            // The read means the app has the text; give it a beat to finish putting it in the
            // field before Return commits whatever is there.
            try? await Task.sleep(for: .milliseconds(60))
            postKey(Key.ret)
        }
        // Retire the promise whether or not it fired: AppKit does not retain a pasteboard owner,
        // and a later read of a dead one is a crash. This also leaves the plain string behind for
        // a manual ⌘V when the app never asked.
        // ponytail: a clipboard manager that reads .string despite the org.nspasteboard opt-out
        // types below would forge the receipt and submit early. Upgrade path if anyone hits it:
        // also require the frontmost app to still be the session's app before posting Return.
        count = writePasteboard(body, token: token)
    }

    // ponytail: fixed 1.5 s restore delay. Chromium apps read the pasteboard asynchronously, so
    // restoring quickly hands the renderer stale data and the paste silently produces nothing.
    // Not built: yap's AppleScript System Events fallback, which costs an extra Automation prompt.
    let final = count
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let pb = NSPasteboard.general
        // changeCount alone races: another app can copy and land on the same count. The stamp is
        // the proof that what is on the clipboard is still ours to overwrite.
        guard pb.changeCount == final, pb.string(forType: stampType) == token else { return }
        restorePasteboard(backup)
    }
    return true
}

/// Proof that the receiving app actually pulled the text off the pasteboard, by leaving .string
/// promised rather than written: nobody gets the text without asking us for it.
///
/// @unchecked Sendable on the same terms as HotkeyWatcher: pasteboard data requests are delivered
/// on the main run loop, and `read` is only ever polled from insertText's main-actor caller.
private final class PasteReceipt: NSObject, NSPasteboardTypeOwner, @unchecked Sendable {
    private let text: String
    private(set) var read = false

    init(_ text: String) { self.text = text }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        sender.setString(text, forType: type)
        read = true
    }
}

/// Synthesized unicode, for terminals and game engines that drop a synthetic ⌘V. Slower and
/// visible for long text, which is why it is not the default.
///
/// ponytail: the text is not left on the clipboard on this path, because there would be nothing
/// to restore it from afterwards. History and 重新貼上 still hold it.
private func typeText(_ text: String) async {
    guard let src = CGEventSource(stateID: .privateState) else { return }
    for chunk in utf16Chunks(text) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        else { return }
        // Both halves carry the string: apps split roughly evenly over which one they read.
        for e in [down, up] {
            e.flags = []
            var units = chunk
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e.post(tap: .cghidEventTap)
        }
        // Electron and terminals drop characters from an unbroken burst. Yields rather than
        // sleeps the thread, so the event tap's run loop keeps turning.
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Split into runs short enough for one event, never between the halves of a surrogate pair --
/// cutting there hands the app two invalid code units instead of one emoji or rare CJK character.
func utf16Chunks(_ text: String, limit: Int = 20) -> [[UniChar]] {
    let units = Array(text.utf16)
    var out: [[UniChar]] = []
    var i = 0
    while i < units.count {
        var end = min(i + limit, units.count)
        if end < units.count, end - 1 > i, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        out.append(Array(units[i..<end]))
        i = end
    }
    return out
}

// MARK: - Reading the selection, for Ask mode

/// The selected text in the frontmost app, or nil when there is no selection.
func readSelection() async -> String? {
    if let s = axSelectedText() { return s }

    let pb = NSPasteboard.general
    let before = pb.changeCount
    let backup = snapshotPasteboard()
    await waitForModifiersToClear()
    postCommandKey(Key.c)

    // No advance means no selection: ⌘C is a no-op with nothing selected. A slow app still
    // advances the count, it just takes longer, hence polling rather than one sleep. 1.2 s
    // because Electron, Java and Office apps routinely answer past half a second.
    let deadline = Date().addingTimeInterval(1.2)
    while pb.changeCount == before, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    guard pb.changeCount != before else {
        // The ⌘C is still in flight and may yet land. Undo it when it does, rather than leaving
        // the user's clipboard replaced by their selection with nothing to restore it.
        //
        // ponytail: a deliberate copy inside this window would be reverted too. The alternative,
        // dropping the backup, destroys the clipboard for good. Upgrade path if it ever bites:
        // a promised-pasteboard read receipt via declareTypes:owner:.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard NSPasteboard.general.changeCount != before else { return }
            restorePasteboard(backup)
        }
        return nil
    }

    let text = pb.string(forType: .string)
    restorePasteboard(backup)
    return (text?.isEmpty ?? true) ? nil : text
}

/// The site the frontmost window is showing, for the per-app rules, or nil when it is not a
/// browser. Browsers publish the current URL as the window's AXDocument; nothing else does, which
/// is exactly the discrimination the rules need and costs one Accessibility call to get.
///
/// ponytail: AXDocument only, no per-browser AppleScript. Safari, Chrome, Edge, Brave, Arc and
/// Orion all answer it. Upgrade path if a browser that does not shows up: ask that one by name.
func frontmostHost(pid: pid_t?) -> String? {
    guard let pid, Permissions.axTrusted else { return nil }
    let app = AXUIElementCreateApplication(pid)
    // Bounded, because the default is six seconds of waiting on another app's run loop and the
    // answer is only ever "which mode to latch". No rule is a better outcome than a stall.
    AXUIElementSetMessagingTimeout(app, 0.3)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                        &window) == .success,
          let window else { return nil }
    var document: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString,
                                        &document) == .success,
          let url = document as? String else { return nil }
    let host = Store.normalizeHost(url)
    return host.isEmpty ? nil : host
}

/// Instant and side-effect free, but Electron and web apps report no focused element at all,
/// so this is a fast path and never the only path.
private func axSelectedText() -> String? {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                        kAXFocusedUIElementAttribute as CFString,
                                        &focused) == .success,
          let focused else { return nil }
    var selected: CFTypeRef?
    guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                        kAXSelectedTextAttribute as CFString,
                                        &selected) == .success,
          let text = selected as? String, !text.isEmpty else { return nil }
    return text
}

// MARK: - Pasteboard and keystroke plumbing

private func snapshotPasteboard() -> [[String: Data]] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        var out: [String: Data] = [:]
        for type in item.types { out[type.rawValue] = item.data(forType: type) }
        return out
    }
}

private func restorePasteboard(_ backup: [[String: Data]]) {
    let pb = NSPasteboard.general
    pb.clearContents()
    guard !backup.isEmpty else { return }
    pb.writeObjects(backup.map { entry in
        let item = NSPasteboardItem()
        for (type, data) in entry { item.setData(data, forType: .init(rawValue: type)) }
        return item
    })
}

/// Writes the text plus the concealment types, and the session stamp when we intend to restore.
/// Returns the resulting changeCount.
///
/// With a promise, .string is declared but left unwritten, so the first app to ask for it calls
/// back into the receipt. Everything else is still written eagerly -- declareTypes has to name
/// every type up front or setData for an undeclared one is dropped.
private func writePasteboard(_ text: String, token: String?, promise: PasteReceipt? = nil) -> Int {
    let pb = NSPasteboard.general
    var types: [NSPasteboard.PasteboardType] = [.string] + concealmentTypes
    if token != nil { types.append(stampType) }
    pb.declareTypes(types, owner: promise)
    if promise == nil { pb.setString(text, forType: .string) }
    for type in concealmentTypes { pb.setData(Data(), forType: type) }
    if let token { pb.setString(token, forType: stampType) }
    return pb.changeCount
}

/// One plain keystroke, no modifiers. Auto-submit's Return.
private func postKey(_ code: CGKeyCode) {
    guard let src = CGEventSource(stateID: .privateState) else { return }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }
}

/// A full four-event ⌘-chord. A lone V with .maskCommand works for native apps, but
/// Chromium and Electron rebuild modifier state from the raw event stream and drop it.
private func postCommandKey(_ code: CGKeyCode) {
    // .privateState so the user's physically held modifiers are not ORed into these events.
    guard let src = CGEventSource(stateID: .privateState) else { return }
    // Plain .maskCommand plus the device-dependent left-command bit: Qt and Java apps read the
    // device bits and ignore a command flag without them.
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceBit.leftCommand)

    let events = [
        (Key.command, true, flags),
        (code, true, flags),
        (code, false, flags),
        (Key.command, false, CGEventFlags(rawValue: 0)),
    ]
    for (key, down, f) in events {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
}

/// Waits at most 600 ms, and only in the rare case where the user is still holding keys.
/// Yields rather than sleeps, so the run loop -- and the event tap on it -- keeps turning.
private func waitForModifiersToClear(timeout: TimeInterval = 0.6) async {
    let watched = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if CGEventSource.flagsState(.combinedSessionState).rawValue & watched == 0 { return }
        try? await Task.sleep(for: .milliseconds(15))
    }
}

// MARK: - Secure input

/// A password field, or a terminal with Secure Keyboard Entry, puts the whole system into secure
/// input. While it is on, our tap stops receiving keyDown and keyUp -- so Escape and a bound space
/// go dead, while fn keeps working because flagsChanged still flows -- and every synthetic
/// keystroke we post, paste included, is discarded. The app looks broken; this is so the UI can
/// say what is actually happening instead.
///
/// ponytail: no culprit lookup. Naming the offending process needs either a private
/// SecureInputAudit call or an ioreg scrape, and the two causes are a password field or a terminal
/// setting, both of which the advice below covers. Upgrade path if support requests pile up.
/// Deliberately NOT built: Handy's Carbon shadow hotkey registration, which only buys back keyed
/// shortcuts. Our trigger is a bare modifier and never had that half of the problem.
enum SecureInput {
    static var enabled: Bool { IsSecureEventInputEnabled() }

    static let advice = String(localized: "An app is using secure input, either a password field or Secure Keyboard Entry in Terminal. The text is on the clipboard, so press ⌘V.")
}

// MARK: - Permissions

enum Permissions {
    /// Reflects live TCC state in-process, so a grant is visible without relaunching.
    static var axTrusted: Bool { AXIsProcessTrusted() }

    static var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// The system sheet, which macOS shows at most once per app identity -- hence the deep links.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        // The imported kAXTrustedCheckOptionPrompt is a mutable global, which makes
        // .takeUnretainedValue() a hard Swift 6 error. The literal is the same string.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func requestMic() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    static func openAccessibilitySettings() { open("Privacy_Accessibility") }
    static func openMicrophoneSettings() { open("Privacy_Microphone") }

    private static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// A CFMachPort that came back nil does not heal itself, so the tap has to be started again
    /// the moment the grant lands. Polls once a second and invalidates itself on success.
    @MainActor
    static func pollUntilTrusted(_ onGrant: @escaping @MainActor () -> Void) {
        guard !polling, !axTrusted else { return }
        polling = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                polling = false
                onGrant()
            }
        }
    }

    @MainActor private static var polling = false
}

// MARK: - Insertion preferences

/// How the text gets in front of the cursor.
enum PasteMethod: String, CaseIterable, Identifiable, Sendable {
    case paste, type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: String(localized: "Paste (⌘V)")
        case .type: String(localized: "Simulated typing")
        }
    }

    var detail: String {
        switch self {
        case .paste: String(localized: "Puts the text on the clipboard, sends ⌘V, then restores the clipboard. Fast, and right for almost every app.")
        case .type: String(localized: "Sends one key event per character and never touches the clipboard. Long text is visibly typed out, but terminals and some game engines accept nothing else.")
        }
    }
}

/// Per-mode auto-submit. Three-valued on purpose: a plain Bool cannot say "follow the global
/// setting", and a mode that has never been touched must not silently mean "off".
enum AutoSubmit: String, CaseIterable, Identifiable, Sendable {
    case inherit, on, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inherit: String(localized: "Follow the general setting")
        case .on: String(localized: "Always send")
        case .off: String(localized: "Never send")
        }
    }

    static func resolve(global: Bool, override: String) -> Bool {
        switch AutoSubmit(rawValue: override) ?? .inherit {
        case .on: true
        case .off: false
        case .inherit: global
        }
    }
}

/// Keys owned by the input layer. Read through UserDefaults.standard directly, with the default
/// spelled out at each read: the event tap reads them before any view has touched @AppStorage,
/// and an unregistered Bool reads false rather than its intended default.
extension Prefs {
    static let handsFreeLock = "handsFreeLock"                 // Bool, default TRUE
    static let pasteMethod = "pasteMethod"                     // PasteMethod.rawValue
    static let appendTrailingSpace = "appendTrailingSpace"     // Bool
    static let autoSubmit = "autoSubmit"                       // Bool, default FALSE

    /// Per-mode auto-submit override, an AutoSubmit.rawValue. Absent means .inherit.
    static func autoSubmitKey(_ id: String) -> String { "autosubmit.\(id)" }
    static func autoSubmitKey(_ mode: Mode) -> String { autoSubmitKey(mode.id) }

    static var handsFreeLockEnabled: Bool {
        UserDefaults.standard.object(forKey: handsFreeLock) as? Bool ?? true
    }

    static var pasteMethodValue: PasteMethod {
        PasteMethod(rawValue: UserDefaults.standard.string(forKey: pasteMethod) ?? "") ?? .paste
    }

    static var appendsTrailingSpace: Bool {
        UserDefaults.standard.bool(forKey: appendTrailingSpace)
    }

    static func autoSubmits(_ mode: Mode) -> Bool {
        AutoSubmit.resolve(global: UserDefaults.standard.bool(forKey: autoSubmit),
                           override: UserDefaults.standard.string(forKey: autoSubmitKey(mode)) ?? "")
    }
}

// MARK: - Self-test

func selfTestHotkey(_ c: SelfTest.Check) {
    // Built here, not read from the database: the latch must behave the same whatever modes the
    // user has defined, and a self-test that reads live user data is not a self-test.
    func mk(_ id: String) -> Mode {
        Mode(id: id, storedName: id, storedSubtitle: "", sfSymbol: "waveform",
             prompt: "", usesSelection: false, translates: false, builtIn: true)
    }
    let dictate = mk("dictate"), translate = mk("translate"), ask = mk("ask")
    let defaults: [(mode: Mode, companion: Companion)] =
        [(dictate, .none), (translate, .leftShift), (ask, .space)]
    func fresh() -> ModeLatch { var l = ModeLatch(); l.bindings = defaults; return l }

    var l = fresh()
    c(l.fn(true, at: 0) == .start(dictate), "latch/fn alone starts dictate",
      "expected .start(dictate), got \(String(describing: l.mode))")

    l = fresh()
    _ = l.fn(true, at: 0)
    let upgraded = l.companions([.leftShift], at: 0.1)
    c(upgraded == .upgrade(translate), "latch/fn then left shift within grace",
      "expected .upgrade(translate), got \(String(describing: upgraded))")
    c(l.fn(false, at: 0.9) == .stop, "latch/fn release stops", "expected .stop")

    // Releasing the companion inside the grace window must NOT demote the session: holding
    // shift only to pick the mode, then letting go while fn stays down, is the normal gesture.
    l = fresh()
    _ = l.fn(true, keys: [.leftShift], at: 0)
    c(l.companions([], at: 0.1) == nil && l.mode == translate,
      "latch/companion release does not downgrade",
      "expected no action and .translate, got \(l.mode)")

    l = fresh()
    _ = l.fn(true, at: 0)
    c(l.companions([.leftShift], at: 0.4) == nil && l.mode == dictate,
      "latch/companion after grace is ignored",
      "expected no upgrade and .dictate, got \(l.mode)")

    l = fresh()
    c(l.fn(true, keys: [.leftShift], at: 0) == .start(translate),
      "latch/shift already held at fn down", "expected .start(translate)")

    l = fresh()
    _ = l.fn(true, at: 0)
    c(l.companions([.space], at: 0.05) == .upgrade(ask), "latch/fn plus space asks",
      "expected .upgrade(ask)")

    l = fresh()
    _ = l.fn(true, at: 0)
    c(l.fn(true, at: 0.01) == nil, "latch/key repeat does not restart", "expected nil")

    l = fresh()
    c(l.fn(false, at: 0) == nil, "latch/release without press is a no-op", "expected nil")

    c(fresh().binds(.space) && !fresh().binds(.leftOption), "latch/binds reports bound keys",
      "expected space bound and left option unbound")

    // MARK: hands-free lock

    // Down, quick up, down again: the second press inside the window locks, and the release that
    // follows it must not stop what was just locked.
    l = fresh()
    _ = l.fn(true, at: 0)
    let parked = l.fn(false, at: 0.1)
    c(parked == nil && l.awaitingSecondTap, "latch/short release parks instead of stopping",
      "expected nil and awaitingSecondTap, got \(String(describing: parked))")
    c(l.fn(true, at: 0.3) == .lock, "latch/double tap locks", "expected .lock")
    c(l.fn(false, at: 0.35) == nil && l.isLocked, "latch/release after locking keeps recording",
      "expected nil and isLocked")

    // A locked session ends on the next press, and its own release is a no-op.
    c(l.fn(true, at: 5) == .stop, "latch/press stops a locked session", "expected .stop")
    c(l.fn(false, at: 5.1) == nil && !l.isLocked, "latch/lock release is a no-op",
      "expected nil and not locked")

    // A hold longer than the double-tap window is push-to-talk and is untouched by any of this.
    l = fresh()
    _ = l.fn(true, at: 0)
    c(l.fn(false, at: 0.9) == .stop && !l.awaitingSecondTap, "latch/long hold still stops on release",
      "expected .stop and nothing parked")

    // Two taps far apart are two sessions. expire turns the first into a stop, so the second
    // press starts rather than locks.
    l = fresh()
    _ = l.fn(true, at: 0)
    _ = l.fn(false, at: 0.1)
    c(l.expire(at: 0.2) == nil, "latch/expire inside the window does nothing", "expected nil")
    c(l.expire(at: 0.5) == .stop, "latch/expire ends an unrepeated tap", "expected .stop")
    c(l.fn(true, at: 0.6) == .start(dictate) && !l.isLocked,
      "latch/two separate taps do not lock", "expected .start(dictate) and not locked")

    // Escape during a locked session leaves nothing behind: no lock, and the latch idle enough
    // that the next press is a clean start.
    l = fresh()
    _ = l.fn(true, at: 0)
    _ = l.fn(false, at: 0.1)
    _ = l.fn(true, at: 0.2)
    l.cancel()
    c(!l.isLocked && l.fn(false, at: 0.3) == nil, "latch/escape drops the lock",
      "expected not locked and no action")
    c(l.fn(true, at: 1) == .start(dictate), "latch/press after escape starts fresh",
      "expected .start(dictate)")

    // The pref is the off switch: with it off a short release stops on the spot, as before.
    l = fresh()
    l.handsFree = false
    _ = l.fn(true, at: 0)
    c(l.fn(false, at: 0.1) == .stop && !l.awaitingSecondTap,
      "latch/hands-free off stops immediately", "expected .stop and nothing parked")

    // MARK: insertion

    c(AutoSubmit.resolve(global: true, override: "off") == false
        && AutoSubmit.resolve(global: false, override: "on") == true
        && AutoSubmit.resolve(global: true, override: "") == true
        && AutoSubmit.resolve(global: false, override: "inherit") == false,
      "autosubmit/per-mode override beats the global, absent inherits",
      "expected off<false, on<true, absent and inherit follow the global")

    // A surrogate pair split across two events reaches the app as two invalid halves.
    let emoji = String(repeating: "a", count: 19) + "\u{1F600}b"
    let chunks = utf16Chunks(emoji)
    c(chunks.first?.count == 19, "typing/chunk backs off a surrogate boundary",
      "expected a 19-unit first chunk, got \(String(describing: chunks.first?.count))")
    c(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == emoji,
      "typing/chunks round-trip", "expected the chunks to rejoin into the original text")
    c(utf16Chunks("").isEmpty && utf16Chunks("abc", limit: 1).count == 3,
      "typing/chunk handles empty and a one-unit limit", "expected [] and three chunks")
}
