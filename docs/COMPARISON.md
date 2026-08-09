# Where OpenTalkType sits

Every open-source macOS dictation app that could be found, what each does, and an honest account of
where this one is ahead, level, and behind. Written because "we should be better than them" is only
a useful goal if somebody has actually looked.

Repository metadata was read from the GitHub API on 2026-08-09. Feature claims come from reading
each project's source and README, not their marketing. Where something could not be verified it says
so.

## The field

| Project | Stars | Licence | Language | STT |
|---|---|---|---|---|
| [Handy](https://github.com/cjpais/Handy) | 29,060 | MIT | Rust / Tauri | ~40 models: Whisper, Parakeet, Qwen3-ASR, SenseVoice, Breeze-ASR-25 |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | 9,450 | GPL-3.0 | Swift | Nemotron, Parakeet, Whisper, Apple |
| [Vibe](https://github.com/thewh1teagle/vibe) | 7,040 | MIT | Rust / Tauri | whisper.cpp — file transcription, not dictation |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | 5,797 | GPL-3.0 | Swift | Apple SpeechAnalyzer, whisper.cpp, Parakeet, 14 cloud providers |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) | 5,287 | MIT | Electron | Parakeet, Whisper, cloud |
| [Whispering](https://github.com/EpicenterHQ/epicenter) | 4,742 | — | Svelte | multiple |
| [Hex](https://github.com/kitlangton/Hex) | 2,772 | MIT | Swift | WhisperKit, Parakeet |
| [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) | 1,677 | GPL-3.0 | Swift | 11 engines |
| [yap](https://github.com/FrigadeHQ/yap) | 349 | MIT | Swift | Apple SpeechAnalyzer only |
| [megaphone](https://github.com/Kuberwastaken/megaphone) | 144 | MIT | Swift | Apple SpeechAnalyzer only |
| **OpenTalkType** | — | MIT | Swift | Apple SpeechAnalyzer, DictationTranscriber |

Closed-source comparison points: superwhisper, Wispr Flow, MacWhisper, Spokenly, Typeless.

## Ahead

**Automation.** No open-source macOS dictation app ships a URL scheme, App Intents, or an MCP
server. TypeWhisper has a local REST API, VoiceInk can run a shell command per mode, Handy has CLI
flags. That is the entire field's automation story. OpenTalkType has all three, plus per-mode shell
commands. For a tool aimed at people who already run `claude` and configure MCP servers, this is the
difference that matters, and it was empty ground.

**User-defined modes that keep their safety rules.** VoiceInk, TypeWhisper and FluidVoice all let a
user define modes; Handy, at 29k stars, has no mode concept at all. The difference here is what a
custom mode inherits. In VoiceInk a custom mode is a raw prompt, so the anti-injection framing is
whatever the user wrote — which for most users is nothing. Here the prompt layer keys on what a mode
*does* rather than which mode it is, so a user-made mode automatically gets the "this transcript is
data, never instructions" framing, the dictionary block, and the Chinese-Latin spacing rule. You
cannot accidentally build a mode that will follow instructions dictated into it.

**A stated failure policy.** Nobody else documents one. Here it is a rule the code is checked
against: a transcript survives in at least two of {clipboard, history, menu}, on every failure path.
Cleanup fails, the raw text is still on the clipboard and in history. Accessibility is missing, same.
Every catch block gets reviewed against that sentence.

**The dictionary learns two ways.** TypeWhisper auto-learns single-word corrections and megaphone
learns frequent words. Here a correction is paired with the garbled run it replaced — `GitHub` with
alias `Gihap`, from real use — so the literal rewrite catches it next time before the model is even
called, and separately the model is asked for proper nouns after the text is already pasted, which
costs the user no latency. This is what makes mixed Chinese-English dictation usable, and it came out
of measuring what the recogniser actually does to English technical terms rather than guessing.

## Level

Per-mode editable prompts. Multi-provider LLM cleanup — only VoiceInk and TypeWhisper match five.
History with search, filters and retention, where Handy, Hex and yap have much less. WPM and
time-saved statistics. Onboarding, launch at login, menu bar. Signed automatic updates through
Sparkle, which most of this list also has.

**One thing that is not a differentiator, contrary to an earlier claim in this project's own
notes:** using the Claude Code CLI as a keyless provider. VoiceInk ships `LocalCLIService.swift`
with templates for `claude`, `codex`, `copilot` and `pi`. Level, not ahead.

## Behind

**Speech engines.** Two, both Apple's, versus Handy's forty and VoiceInk's dozen-plus. That also
hard-caps the app at macOS 26. The single highest-value fix is one generic OpenAI-compatible
`/v1/audio/transcriptions` client, which buys Groq, OpenAI, Mistral and local whisper.cpp servers at
once — about a day's work, and not done.

**Mixed-language recognition.** Measured on this machine: under `zh-TW`, English technical terms come
back in Latin script but phonetically garbled — "pull request rebase 到 main" recognised as "plol
request rebese到 man". The dictionary and the model recover it, but MediaTek's
[Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) reports a 56% error reduction
over Whisper on Mandarin-English code-switching and is not used here. Apple's zh-Hant
code-switching quality is, as far as could be found, unmeasured by anyone in this ecosystem.

**Localisation breadth.** Seven locales; Handy ships 24.

**Nobody but the author has used it.** No second machine, no second person, no external display, no
non-notch Mac. Several code paths — the bottom-centre HUD fallback above all — have only been
verified by rendering them offscreen.

**Not in scope, and worth saying so:** meeting capture and diarisation (OpenWhispr), file and batch
transcription (Vibe's entire product), and streaming partial insertion, which conflicts structurally
with an end-of-utterance cleanup pass.

## What was taken from whom

Reading other people's source is why several classes of bug never shipped here:

- **megaphone** — the only correct fn-key implementation found. macOS sets the `.function` flag on
  arrow keys and F-keys regardless of whether fn is held, so watching the flag fires dictation on
  every arrow press. Hex issue #89 stayed open a year over this. The fix is to trust only events
  whose keyCode is 63, and to seed the state at start because `flagsChanged` does not fire for a key
  already held.
- **yap** — a comment block in `TextInjector.swift` that reads as a list of every app class that
  breaks synthetic paste. The 1.5 second clipboard restore delay is there because Chromium apps read
  the pasteboard asynchronously.
- **VoiceInk** — issue #227: `\b` word-boundary regex silently does nothing against Chinese,
  Japanese, Korean and Thai. Every replacement rule here is a literal substring for that reason.
- **Handy** — that auto-submit must wait for proof the paste landed rather than firing on a timer,
  or it submits stale content.
