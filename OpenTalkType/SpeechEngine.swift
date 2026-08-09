@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Observation
import Speech

// Microphone capture and on-device recognition.
//
// One class, main-actor isolated, publishing straight into AppState (partialText, micLevel,
// micGranted, modelReady, modelStatus) -- there is exactly one consumer, so a callback layer
// would only be indirection. AppState owns it strongly via `state.speech`.
//
// The pipeline is fixed by the framework: mic (48k Float32) -> AVAudioConverter -> the analyzer's
// format (16k Int16 mono) -> AnalyzerInput stream -> SpeechAnalyzer -> a results pump.

// MARK: - Errors

enum SpeechError: LocalizedError {
    case micDenied
    case noInput
    case localeUnsupported(String)
    case modelUnavailable
    case converter
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .micDenied:
            "沒有麥克風權限。請到「系統設定 → 隱私權與安全性 → 麥克風」勾選 OpenTalkType。"
        case .noInput:
            "找不到可用的輸入裝置。請確認麥克風已連接並在系統設定中選為輸入來源。"
        case .localeUnsupported(let id):
            "系統語音辨識不支援「\(id)」。請到「設定 → AI」換一個辨識語言。"
        case .modelUnavailable:
            "語言模型尚未下載完成，或這個語言沒有可用的模型。請連上網路後重試。"
        case .converter:
            "無法建立音訊轉換器，麥克風格式與辨識引擎不相容。"
        case .engine(let why):
            "無法啟動錄音：\(why)"
        }
    }
}

// MARK: - Audio preferences

/// Declared here rather than in Settings.swift so the audio feature is readable in one file.
/// Every read carries its own default, so these work whether or not they are in Prefs.registry.
extension Prefs {
    /// CoreAudio device UID, same string as AVCaptureDevice.uniqueID. Empty = system default.
    static let inputDeviceUID = "inputDeviceUID"
    /// End the session after `silenceSeconds` below `silenceLevel` (0...1, the micLevel scale).
    static let silenceStop = "silenceStop"
    static let silenceLevel = "silenceLevel"
    static let silenceSeconds = "silenceSeconds"
    /// Silence the default output device for the duration of a session.
    static let muteWhileRecording = "muteWhileRecording"
    /// Keep session audio for N days. 0 = keep nothing, and delete whatever is already there.
    static let audioRetentionDays = "audioRetentionDays"
    /// Not user facing: the output volume to put back if we are killed mid-session.
    static let duckedVolume = "duckedVolume"

    static var inputDeviceUIDValue: String {
        UserDefaults.standard.string(forKey: inputDeviceUID) ?? ""
    }

    static var silenceStopEnabled: Bool { UserDefaults.standard.bool(forKey: silenceStop) }

    /// Clamped: a threshold of 1 would end every session on the first buffer.
    static var silenceLevelValue: Float {
        Float(min(max(UserDefaults.standard.object(forKey: silenceLevel) as? Double ?? 0.12, 0.01), 0.9))
    }

    static var silenceSecondsValue: Double {
        min(max(UserDefaults.standard.object(forKey: silenceSeconds) as? Double ?? 1.5, 0.5), 30)
    }

    static var muteWhileRecordingValue: Bool {
        UserDefaults.standard.bool(forKey: muteWhileRecording)
    }

    static var audioRetentionDaysValue: Int { UserDefaults.standard.integer(forKey: audioRetentionDays) }
}

// MARK: - Session recorder

/// Writes the session's audio to disk from the tap thread, for 保留音檔.
///
/// The tap thread is not the main actor and AVAudioFile is not thread safe, so it gets a lock --
/// the same shape Store uses. `close()` just drops the file; AVAudioFile finalises on dealloc.
///
/// ponytail: writes straight from the audio thread. At the analyzer's format that is 32 kB/s and
/// has not glitched in practice; upgrade path is a ring buffer drained by a writer thread.
final class SessionRecorder: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    /// Length of what was written, read off the file just before it is closed. The history row
    /// wants it and AVAudioFile forgets once it is gone.
    private(set) var seconds: Double = 0

    /// `format` is the analyzer's (16 kHz mono Int16), not the microphone's: a twelfth of the size
    /// and literally what the recogniser heard, which is the point of keeping it at all.
    init?(format: AVAudioFormat) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        url = SpeechEngine.audioDir.appendingPathComponent("\(stamp.string(from: Date())).caf")
        guard let opened = try? AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: format.commonFormat,
                                            interleaved: format.isInterleaved) else { return nil }
        file = opened
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        if let file, file.fileFormat.sampleRate > 0 {
            seconds = Double(file.length) / file.fileFormat.sampleRate
        }
        file = nil
        lock.unlock()
    }

    /// Cancelled session: no history row, so no file either.
    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}

/// One microphone the system can see. `id` is the CoreAudio UID, stable across reboots and
/// re-plugging, which is why it is what gets stored rather than a name or an index.
struct InputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

// MARK: - Engine

@MainActor
@Observable
final class SpeechEngine {
    private unowned let state: AppState

    init(_ state: AppState) {
        self.state = state
        state.micGranted = Permissions.micGranted
    }

    /// Both concrete transcribers. A protocol over two types with one call site each would be
    /// more code than the switch.
    private enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let t): t
            case .dictation(let t): t
            }
        }
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var pump: Task<String, Never>?
    private var tapped = false
    private var recorder: SessionRecorder?
    private var configObserver: NSObjectProtocol?
    /// The output volume 靜音其他聲音 took away, so teardown can put it back.
    private var duckedFrom: Float?
    /// Silence auto-stop state, reset with every session.
    private var speechSeen = false
    private var quietSince: Date?

    /// Where the last completed session's audio was written, when 保留音檔 is on. Read it after
    /// stop() and hand it to Store; nil when retention is off or the session was cancelled.
    private(set) var lastAudioPath: String?
    /// Length of that file. Not the same as the session duration: capture starts before the
    /// first word and the recogniser runs on its own clock.
    private(set) var lastAudioSeconds: Double = 0

    /// Bumped by stop() and cancel(). start() has several awaits before it touches audio, and
    /// releasing fn during one of them used to leave a live microphone behind with the app back
    /// at .idle: the token lets a suspended start() notice its session already ended.
    private var generation = 0

    // The mic is the only permission this file needs, and it lives in Permissions (Input.swift).
    // SFSpeechRecognizer authorization is NOT required: SpeechAnalyzer transcribes at .notDetermined.

    // MARK: Locale

    /// Three-step widening. A Mac whose language and region disagree serialises Locale.current
    /// as e.g. "en-US-u-rg-eszzzz", which matches nothing in supportedLocales and makes dictation
    /// silently return an empty string. Read language.region, never locale.region -- the -u-rg-
    /// extension rewrites the latter.
    nonisolated static func resolveLocale(_ identifier: String, supported: [Locale]) -> Locale? {
        let want = Locale(identifier: identifier)
        let tag = want.identifier(.bcp47)
        if let hit = supported.first(where: { $0.identifier(.bcp47) == tag }) { return hit }

        guard let lang = want.language.languageCode?.identifier else { return nil }
        if let region = want.language.region?.identifier,
           let hit = supported.first(where: {
               $0.language.languageCode?.identifier == lang && $0.language.region?.identifier == region
           }) { return hit }

        return supported.first { $0.language.languageCode?.identifier == lang }
    }

    private func supportedLocales() async -> [Locale] {
        switch Prefs.engineValue {
        case .speechTranscriber: await SpeechTranscriber.supportedLocales
        case .dictationTranscriber: await DictationTranscriber.supportedLocales
        }
    }

    private func currentLocale() async throws -> Locale {
        let want = Prefs.localeValue
        guard let loc = Self.resolveLocale(want, supported: await supportedLocales()) else {
            throw SpeechError.localeUnsupported(want)
        }
        return loc
    }

    private func makeModule(_ loc: Locale) -> Module {
        switch Prefs.engineValue {
        case .speechTranscriber: .speech(SpeechTranscriber(locale: loc, preset: .progressiveTranscription))
        case .dictationTranscriber: .dictation(DictationTranscriber(locale: loc, preset: .progressiveLongDictation))
        }
    }

    // MARK: Assets

    /// Download the locale's model if needed, publishing progress as 下載語言模型中 nn%.
    /// Gate on status, never on assetInstallationRequest != nil -- that stays non-nil after a
    /// successful install and would re-download every launch.
    func prepareModel() async {
        // Put back a volume an abnormal exit took away. Recording retention is AppState's
        // launch housekeeping, next to the transcript retention it has to run with.
        restoreDuckIfCrashed()
        do {
            let loc = try await currentLocale()
            try await ensureAssets(makeModule(loc), locale: loc)
        } catch {
            state.modelReady = false
            state.modelStatus = (error as? SpeechError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ensureAssets(_ mod: Module, locale: Locale) async throws {
        await reserve(locale)

        if await AssetInventory.status(forModules: [mod.module]) == .installed {
            state.modelReady = true
            state.modelStatus = ""
            return
        }

        state.modelReady = false
        state.modelStatus = "下載語言模型中"
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [mod.module]) else {
            state.modelStatus = "語言模型無法下載"
            throw SpeechError.modelUnavailable
        }

        // ponytail: polling Progress every 300ms instead of KVO -- one label, nobody sees the
        // difference; swap to an observation if the HUD ever needs a smooth bar.
        let progress = request.progress
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.state.modelStatus = "下載語言模型中 \(Int(progress.fractionCompleted * 100))%"
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { ticker.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch {
            state.modelStatus = "語言模型下載失敗"
            throw SpeechError.modelUnavailable
        }
        state.modelReady = true
        state.modelStatus = ""
    }

    /// At most five locales may be reserved. Evict the oldest rather than failing the user's
    /// current language.
    private func reserve(_ loc: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(loc) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: loc)
    }

    // MARK: Session

    /// Begin capture. `phrases` are dictionary terms; they only reach DictationTranscriber --
    /// AnalysisContext.contextualStrings are provably ignored by SpeechTranscriber (Apple DTS,
    /// and byte-identical output here with and without them).
    func start(phrases: [String] = []) async throws {
        guard Permissions.micGranted else {
            state.micGranted = false
            throw SpeechError.micDenied
        }
        // Full teardown, not just the audio half: a leftover continuation never finishes, so its
        // analyzer never ends its results sequence and its pump keeps writing state.partialText.
        await cancel()
        let gen = generation

        let loc = try await currentLocale()
        guard gen == generation else { return }
        let mod = makeModule(loc)
        try await ensureAssets(mod, locale: loc)   // can be a several-hundred-MB download
        guard gen == generation else { return }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [mod.module]) else {
            throw SpeechError.modelUnavailable
        }
        guard gen == generation else { return }

        // Pin the microphone BEFORE any format is read: the format belongs to whichever device
        // the AUHAL is currently on, and a stale one gives the converter the wrong sample rate.
        // Re-applied every session on purpose -- that is what makes "AirPods connected while the
        // app was idle" pick up the right device instead of the one from the last session.
        Self.applyInputDevice(engine, uid: Prefs.inputDeviceUIDValue)

        // Both of these can fail, so probe them before anything exists that would need unwinding.
        let mic = engine.inputNode.outputFormat(forBus: 0)
        guard mic.sampleRate > 0, mic.channelCount > 0 else { throw SpeechError.noInput }
        guard let converter = AVAudioConverter(from: mic, to: format) else { throw SpeechError.converter }

        let context = AnalysisContext()
        if case .dictation = mod {
            context.contextualStrings[.general] = Self.contextPhrases(phrases)
        }

        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        // This init starts analysis itself; calling start(inputSequence:) afterwards is wrong.
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [mod.module], analysisContext: context)

        switch mod {
        case .speech(let t): startPump(t.results) { $0.text }
        case .dictation(let t): startPump(t.results) { $0.text }
        }

        lastAudioPath = nil
        recorder = Prefs.audioRetentionDaysValue > 0 ? SessionRecorder(format: format) : nil

        Self.installTap(on: engine, mic: mic, format: format, converter: converter,
                        feed: feed, recorder: recorder) { [weak self] level in
            Task { @MainActor in self?.onLevel(level) }
        }
        tapped = true

        if Prefs.muteWhileRecordingValue { duck() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            await cancel()
            throw SpeechError.engine(error.localizedDescription)
        }
        watchConfigChanges(gen)
    }

    /// The input device disappearing mid-sentence -- AirPods pulled out, dock unplugged, the
    /// system default switching under us -- stops the engine underneath the tap. AVAudioEngine
    /// reports it as a configuration change; end the session through the ordinary release path so
    /// the words already transcribed are cleaned up, pasted and stored as usual.
    ///
    /// ponytail: ends the session rather than re-plumbing the tap onto the new device mid-sentence
    /// -- a hot swap loses the buffers in flight anyway. Upgrade path if anyone asks for it: pause
    /// the feed, rebuild converter and tap for the new format, resume.
    private func watchConfigChanges(_ gen: Int) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation, self.state.phase == .listening else { return }
                self.state.stopDictation()
            }
        }
    }

    /// Finish the session and return the whole transcript.
    func stop() async -> String {
        generation &+= 1
        teardownAudio()                       // closes the file, which is what fills in `seconds`
        lastAudioPath = recorder?.url.path
        lastAudioSeconds = recorder?.seconds ?? 0
        recorder = nil
        feed?.finish()
        feed = nil
        // finalize throws a contentless Foundation._GenericObjCError when the input stream has
        // already finished -- and when it throws it has NOT closed the modules, so the results
        // sequence never ends and the pump below would await forever. Observed as the HUD stuck
        // on 整理中… with no way out. Force the streams shut on that path.
        // Bounded, and this is the important part: finalize is an unbounded await on the
        // analyzer actor, it sat here for 30+ seconds in practice, and every other guard in this
        // path -- the pump timeout below, the 90s cleanup deadline in finish() -- is DOWNSTREAM
        // of it, so none of them could fire. The HUD just counted upward forever.
        //
        // When it does not come back, walk away: the analyzer is detached and left to collapse on
        // its own, and the partial text already on screen is the answer.
        if let analyzer {
            let finished = await Self.withDeadline(seconds: 3) {
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                catch { await analyzer.cancelAndFinishNow() }
            }
            if !finished { Task.detached { await analyzer.cancelAndFinishNow() } }
        }
        analyzer = nil

        // Belt and braces: never let a framework stall wedge the UI. Whatever was already shown
        // as the live partial is the answer if the pump does not land in time -- the one thing
        // that must never happen is losing what the user said.
        let shown = state.partialText
        let text = await Self.firstOrTimeout(seconds: 5, task: pump) ?? shown
        pump?.cancel()
        pump = nil
        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `work`, returning false if it outlived `seconds`. The work is abandoned, not
    /// cancelled: SpeechAnalyzer does not answer cancellation once it is wedged, and waiting to
    /// find that out is the thing being fixed.
    /// Kept as a thin name over the shared racer; see firstOf in App.swift for why a task group
    /// cannot express this.
    private static func withDeadline(seconds: Double,
                                     _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await firstOf(seconds: seconds, timeout: false) { await work(); return true }
    }

    /// The task's value, or nil if it takes longer than `seconds`.
    private static func firstOrTimeout(seconds: Double, task: Task<String, Never>?) async -> String? {
        guard let task else { return nil }
        return await firstOf(seconds: seconds, timeout: nil) { await task.value }
    }

    /// Abort without waiting for a final result. Also the full teardown start() runs first.
    func cancel() async {
        generation &+= 1
        teardownAudio()
        lastAudioPath = nil
        lastAudioSeconds = 0
        recorder?.discard()
        recorder = nil
        feed?.finish()
        feed = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        pump?.cancel()
        pump = nil
        reset()
    }

    private func reset() {
        state.partialText = ""
        state.micLevel = 0
        speechSeen = false
        quietSince = nil
    }

    private func teardownAudio() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
        // After removeTap, no more buffers arrive, so the file can be closed from here.
        recorder?.close()
        unduck()
    }

    /// Accumulate final chunks, show accumulated + volatile chunk as the live partial.
    private func startPump<S: AsyncSequence & Sendable>(
        _ results: S,
        _ text: @escaping @Sendable (S.Element) -> AttributedString
    ) where S.Element: SpeechModuleResult {
        pump = Task {
            var done = ""
            do {
                for try await result in results {
                    let chunk = String(text(result).characters)
                    if result.isFinal {
                        done += chunk
                        self.state.partialText = done
                    } else {
                        self.state.partialText = done + chunk
                    }
                }
            } catch {
                // A cancelled or finished analyzer ends the sequence with an error; whatever was
                // finalised before that is still the right answer.
            }
            return done
        }
    }

    // MARK: Level

    /// RMS mapped through dB so quiet speech still moves the meter. -50 dBFS reads as silence.
    /// Install the mic tap from a NONISOLATED context. This is load-bearing, not style: written
    /// inline inside a method of this @MainActor class, the tap closure gets inferred as
    /// main-actor-isolated, and AVFAudio calls it on its realtime audio thread. Swift 6 then emits
    /// an executor check that fails -- dispatch_assert_queue -> EXC_BREAKPOINT, the app dies the
    /// instant fn is pressed. Observed and fixed; do not inline this again.
    nonisolated private static func installTap(
        on engine: AVAudioEngine,
        mic: AVAudioFormat,
        format: AVAudioFormat,
        converter: AVAudioConverter,
        feed: AsyncStream<AnalyzerInput>.Continuation,
        recorder: SessionRecorder?,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: mic) { buffer, _ in
            onLevel(level(of: buffer))

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / mic.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var error: NSError?
            nonisolated(unsafe) var supplied = false
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            feed.yield(AnalyzerInput(buffer: out))
            // Same buffer the recogniser gets, which is the whole point of keeping it.
            recorder?.write(out)
        }
    }

    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let db = 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    private func onLevel(_ level: Float) {
        state.micLevel += (level - state.micLevel) * 0.3
        guard Prefs.silenceStopEnabled, state.phase == .listening else { return }
        let step = Self.silenceStep(level: state.micLevel,
                                    threshold: Prefs.silenceLevelValue,
                                    seconds: Prefs.silenceSecondsValue,
                                    now: Date(), speechSeen: speechSeen, quietSince: quietSince)
        speechSeen = step.speechSeen
        quietSince = step.quietSince
        // The same path releasing the key takes: stop, clean up, paste, store.
        if step.stop { state.stopDictation() }
    }

    /// One buffer of the silence auto-stop decision, pure so the self-test can drive it.
    ///
    /// Three things keep this from cutting people off mid-pause:
    /// 1. The countdown does not arm until speech has actually been heard, so thinking for five
    ///    seconds before the first word never ends the session.
    /// 2. It runs on the SMOOTHED level, which only moves 30% of the way per buffer (~85 ms), so a
    ///    single quiet buffer inside a word cannot start the countdown from zero -- the level has
    ///    to stay down for several buffers before it even crosses the threshold.
    /// 3. Any buffer back above the threshold clears the countdown outright, and the default
    ///    window is 1.5 s, well past the 0.2-0.6 s pauses that fall between clauses.
    nonisolated static func silenceStep(
        level: Float, threshold: Float, seconds: Double, now: Date,
        speechSeen: Bool, quietSince: Date?
    ) -> (speechSeen: Bool, quietSince: Date?, stop: Bool) {
        if level >= threshold { return (true, nil, false) }
        guard speechSeen else { return (false, nil, false) }
        let since = quietSince ?? now
        return (true, since, now.timeIntervalSince(since) >= seconds)
    }

    /// DictationTranscriber takes at most 100 short phrases; longer ones are ignored anyway and
    /// crowd out the useful terms. Chinese terms carry no spaces, so they always survive.
    nonisolated static func contextPhrases(_ terms: [String]) -> [String] {
        let short = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 2 }
        return Array(short.prefix(100))
    }

    // MARK: Input devices

    /// Every microphone the system can see, for the picker in 設定. "System default" is not in
    /// this list -- it is the empty selection.
    nonisolated static var inputDevices: [InputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified)
            .devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Point the engine's input AudioUnit at `uid`, falling back to the system default when the
    /// pinned device is empty or has been unplugged since it was chosen. Always sets something,
    /// because the AUHAL remembers the last session's device otherwise.
    /// Engine must be stopped, and this must run before any format is read off the node.
    nonisolated static func applyInputDevice(_ engine: AVAudioEngine, uid: String) {
        guard let unit = engine.inputNode.audioUnit,
              var dev = (uid.isEmpty ? nil : deviceID(uid: uid)) ?? defaultDevice(input: true)
        else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                             0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// nil when the UID names nothing the system currently has.
    nonisolated static func deviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let ok = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return ok == noErr && dev != AudioDeviceID(kAudioObjectUnknown) ? dev : nil
    }

    nonisolated private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &dev) == noErr,
              dev != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return dev
    }

    // MARK: Ducking

    /// 靜音其他聲音: take the default output device's volume to zero for the session and put it
    /// back afterwards.
    ///
    /// ponytail: macOS has no per-application ducking outside AVAudioSession (iOS only), so this
    /// is the honest subset and here is what it does NOT do. It silences the output rather than
    /// pausing anything, so a video keeps playing with no sound and you come back mid-scene. It
    /// only touches the *default* output device, so audio routed elsewhere is untouched. It also
    /// silences our own Tink/Pop feedback, and the app's volume restore clobbers a volume change
    /// the user makes during the session. Upgrade path if any of that matters: send the media key
    /// (NX_KEYTYPE_PLAY) to genuinely pause the frontmost player, which brings its own problem --
    /// no way to know whether it was playing to begin with.
    private func duck() {
        guard duckedFrom == nil, let dev = Self.defaultDevice(input: false),
              let level = Self.outputVolume(dev), level > 0 else { return }
        duckedFrom = level
        // Stashed so a crash or a force quit mid-session cannot leave the speakers at zero.
        UserDefaults.standard.set(Double(level), forKey: Prefs.duckedVolume)
        Self.setOutputVolume(dev, 0)
    }

    private func unduck() {
        guard let level = duckedFrom else { return }
        duckedFrom = nil
        UserDefaults.standard.removeObject(forKey: Prefs.duckedVolume)
        if let dev = Self.defaultDevice(input: false) { Self.setOutputVolume(dev, level) }
    }

    private func restoreDuckIfCrashed() {
        guard let level = UserDefaults.standard.object(forKey: Prefs.duckedVolume) as? Double else { return }
        UserDefaults.standard.removeObject(forKey: Prefs.duckedVolume)
        if let dev = Self.defaultDevice(input: false) { Self.setOutputVolume(dev, Float(level)) }
    }

    nonisolated private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// nil on a device with no master volume control (digital out, some aggregates); ducking then
    /// does nothing rather than pretending.
    nonisolated private static func outputVolume(_ dev: AudioDeviceID) -> Float? {
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &level) == noErr else { return nil }
        return level
    }

    nonisolated private static func setOutputVolume(_ dev: AudioDeviceID, _ level: Float) {
        var addr = volumeAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return }
        var v = Float32(level)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    // MARK: Audio retention

    /// ~/Library/Application Support/OpenTalkType/Audio, alongside store.sqlite.
    nonisolated static var audioDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTalkType", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 0 days means the feature is off, which has to mean "and take the old recordings with it" --
    /// otherwise turning it off leaves every recording ever made sitting on disk.
    nonisolated static func audioExpired(modified: Date, now: Date, days: Int) -> Bool {
        days <= 0 || now.timeIntervalSince(modified) > Double(days) * 86_400
    }

    nonisolated static func purgeAudio(days: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let now = Date()
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if audioExpired(modified: modified, now: now, days: days) { try? fm.removeItem(at: file) }
        }
    }
}

// MARK: - Self-test

func selfTestSpeech(_ c: SelfTest.Check) {
    let supported = [Locale(identifier: "zh_TW"), Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

    let exact = SpeechEngine.resolveLocale("zh-TW", supported: supported)
    c(exact?.identifier(.bcp47) == "zh-TW", "locale exact match",
      "expected zh-TW, got \(exact?.identifier ?? "nil")")

    // The shipped bug: system language en, region ES.
    let widened = SpeechEngine.resolveLocale("en-US-u-rg-eszzzz", supported: supported)
    c(widened?.identifier(.bcp47) == "en-US", "locale widening drops -u-rg- extension",
      "expected en-US, got \(widened?.identifier ?? "nil")")

    let anyRegion = SpeechEngine.resolveLocale("en-GB", supported: supported)
    c(anyRegion?.identifier(.bcp47) == "en-US", "locale falls back to any region of the language",
      "expected en-US, got \(anyRegion?.identifier ?? "nil")")

    c(SpeechEngine.resolveLocale("ja-JP", supported: supported) == nil, "locale unsupported is nil",
      "expected nil for ja-JP, got a match")

    let phrases = SpeechEngine.contextPhrases(["台鐵", "pull request", "a three word phrase", "  "]
        + (0..<120).map { "term\($0)" })
    c(phrases.count == 100, "contextPhrases caps at 100", "expected 100, got \(phrases.count)")
    c(phrases.contains("台鐵") && phrases.contains("pull request")
        && !phrases.contains("a three word phrase") && !phrases.contains(""),
      "contextPhrases keeps one and two word terms only",
      "expected 台鐵 and pull request kept, three-word and blank dropped, got \(phrases.prefix(4))")

    // Silence auto-stop. The failure this guards against is cutting someone off mid-sentence.
    let t0 = Date()
    func step(_ level: Float, _ at: Double, seen: Bool, since: Date?)
        -> (speechSeen: Bool, quietSince: Date?, stop: Bool) {
        SpeechEngine.silenceStep(level: level, threshold: 0.1, seconds: 1.5,
                                 now: t0.addingTimeInterval(at), speechSeen: seen, quietSince: since)
    }

    let beforeSpeaking = step(0.02, 30, seen: false, since: nil)
    c(!beforeSpeaking.stop && beforeSpeaking.quietSince == nil,
      "silence before the first word never ends the session",
      "expected no stop and no countdown, got stop=\(beforeSpeaking.stop)")

    let armed = step(0.5, 0, seen: false, since: nil)
    c(armed.speechSeen && armed.quietSince == nil, "a loud buffer arms the countdown and clears it",
      "expected speechSeen with no quietSince, got \(armed)")

    let pauseBegan = step(0.02, 0.1, seen: true, since: nil)
    let midPause = step(0.02, 0.7, seen: true, since: pauseBegan.quietSince)
    c(!midPause.stop, "a 0.6s pause inside a sentence does not end the session",
      "expected no stop 0.6s into the pause, got stop=true")

    let resumed = step(0.4, 0.8, seen: true, since: pauseBegan.quietSince)
    c(resumed.quietSince == nil, "speaking again clears the countdown",
      "expected quietSince nil after a loud buffer, got \(String(describing: resumed.quietSince))")

    let ended = step(0.02, 1.7, seen: true, since: pauseBegan.quietSince)
    c(ended.stop, "1.6s under the threshold ends the session",
      "expected stop after the 1.5s window, got stop=false")

    c(SpeechEngine.audioExpired(modified: t0, now: t0, days: 0),
      "audio retention off deletes even a fresh recording", "expected expired at 0 days")
    c(!SpeechEngine.audioExpired(modified: t0.addingTimeInterval(-86_400), now: t0, days: 7),
      "a day-old recording survives 7-day retention", "expected kept, got expired")
    c(SpeechEngine.audioExpired(modified: t0.addingTimeInterval(-8 * 86_400), now: t0, days: 7),
      "an eight-day-old recording is deleted at 7 days", "expected expired, got kept")
}
