English · [正體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

# OpenTalkType

Hold the `fn` key, say what you mean, and clean written text appears wherever you were typing.

[![CI](https://github.com/SammyLin/OpenTalkType/actions/workflows/ci.yml/badge.svg)](https://github.com/SammyLin/OpenTalkType/actions/workflows/ci.yml)

Speech recognition runs on the Mac and never leaves it. What does leave is the transcript, sent to
whichever language model you configured so the text comes back punctuated, de-ummed and readable
instead of as raw recogniser output. No account, no server of ours, no telemetry.

It is also the only open-source dictation app for macOS that other software can drive: a URL
scheme, App Intents and an MCP server. That section is first, because it is the reason to pick
this one.

<!-- SCREENSHOTS GO HERE. Two are needed:
     1. The notch HUD mid-dictation — the plate flared out of the display cutout, live partial
        transcript and level meter visible, over a real app such as an editor.
     2. The main window — Home pane, showing the three mode cards and the key caps.
     Drop the files in Design/ and reference them here, then delete this comment. -->

---

## Automation

Dictation is a function other software should be able to call. OpenTalkType exposes the same
pipeline the `fn` key uses through three doors.

### MCP server

`OpenTalkType --mcp` is a headless MCP server over stdio. It opens no port, and it runs the same
code the app does, so a model gets your real modes, your real dictionary and your real history.

Turn it on in **Settings › Automation**, then add this to your MCP client's configuration:

```json
{
  "mcpServers": {
    "opentalktype": {
      "command": "/Applications/OpenTalkType.app/Contents/MacOS/OpenTalkType",
      "args": ["--mcp"]
    }
  }
}
```

Settings › Automation prints the exact path for your copy, with a Copy button. Four tools are
served:

| Tool | What it does |
|---|---|
| `opentalktype_clean_text` | Run the cleanup pipeline over supplied text, in any mode |
| `opentalktype_history_search` | Search dictation history, newest first |
| `opentalktype_add_term` | Add a term and the spellings it gets misheard as |
| `opentalktype_list_modes` | List the modes you have defined, with their ids |

Off by default, deliberately: any local process that can execute the binary could otherwise read
your entire dictation history.

### URL scheme

Also off by default, because any web page can open a link.

```
opentalktype://start?mode=dictate         Start dictating in the given mode
opentalktype://stop                       Finish this session, clean up and paste
opentalktype://cancel                     Cancel it: paste nothing, keep nothing
opentalktype://run?mode=dictate&text=…    Skip the microphone, clean up this text
opentalktype://paste-last                 Paste the previous result again
```

Enough for Raycast, Keyboard Maestro, Stream Deck or one line of `open` in a shell script. Leaving
`mode` out means dictate; naming a mode that does not exist does nothing at all, rather than
quietly dictating into the wrong one. Text passed to `run` is capped at 20,000 characters.

### App Intents

Start Dictation, Stop Dictation, Cancel Dictation, Clean Up Text and Add Dictionary Term appear in
Shortcuts, Spotlight and anything else that reads intents. Clean Up Text returns the cleaned
string, so it composes with the rest of a shortcut. The mode parameter is a picker filled from the
modes you actually have. No opt-in switch here: an intent runs only because you built it into a
shortcut and pressed it.

### Shell action

Any mode can carry a `/bin/sh` command, run once the text is ready with `$OT_TRANSCRIPT`,
`$OT_MODE`, `$OT_APP` and `$OT_RAW` in its environment and the text on stdin. If the command prints
something, that becomes the pasted text. One field turns a mode into a webhook, a note appender or
a call to any API. There is no default command anywhere; a mode does nothing until you type one.

---

## Modes

Three ship. Hold the keys while you speak, release to send.

| Mode | Keys | What it does |
|---|---|---|
| Dictate | Hold `fn` | Cleans up what you said and inserts it at the cursor |
| Translate | Hold `fn` + left `⇧` | Speak in one language, get idiomatic text in another |
| Ask | Hold `fn` + `space` | Give an instruction about the selected text; the result replaces it |

Double-tap `fn` to lock the microphone on and keep your hands free, tap again to finish. `Esc`
abandons a session outright: nothing transcribed, nothing pasted, nothing stored.

Modes are records, not a fixed list. Add one in Settings › Modes with its own name, icon, system
prompt, companion key and shell command, or edit the three that ship, prompts included. Everything
follows from the same table: the hotkeys, the automation doors, the MCP mode list and the per-app
rules.

---

## What leaves your Mac

Recording and recognition use Apple's on-device speech models through macOS 26's `SpeechAnalyzer`.
Audio is never uploaded, and once the language model has downloaded the recogniser needs no
network at all.

What leaves, and the only thing that leaves, is the finished transcript, sent to the provider you
chose so it can be cleaned up.

| Provider | Notes |
|---|---|
| DeepSeek (default) | About one second in testing, native-quality Chinese, very cheap |
| Claude Code (local CLI) | **No API key at all.** Reuses the Claude Code session you are already signed in to. About five seconds, because each request cold-starts the CLI |
| Anthropic, OpenAI, Gemini | Your own API key, held in the macOS Keychain |
| Local | Any OpenAI-compatible server on this Mac, such as Ollama or LM Studio. Nothing leaves the machine at all |

The update check is the one other network call. It asks the release feed whether there is a newer
version and nothing else, it is off until you turn it on, and it is off entirely in a build that
is not running from Applications.

---

## Dictionary

Recognisers mangle names. The dictionary is how a colleague's name, a product, an internal system
or a command stops coming back wrong, and it is what makes mixed Chinese-English speech usable:
you say a Chinese sentence with three English terms in it, and the terms come out spelled the way
you spell them.

Each entry is a term plus the spellings the recogniser produces instead. They are applied three
ways: as a literal substring rewrite before the model sees the text, as an authoritative list
pasted into the system prompt, and as vocabulary hints to the recogniser itself when the
DictationTranscriber engine is selected. Literal, never a word-boundary regex — `\b` matches
nothing between Chinese characters, which would make the whole feature useless for most of this
text.

It fills itself, both ways running after the text is already pasted so neither costs you latency:

- **Pairing.** A word the cleanup introduced that you never said is a correction. It is stored
  against the garbled run it replaced, so the next occurrence is fixed by literal rewrite before
  the model is involved at all.
- **Asking.** The model is shown the finished text and asked which proper nouns and technical
  terms are in it. This is the half that matters: the words a model silently gets wrong every time
  are never corrected, so diffing alone would never learn them.

Automatic entries are labelled and can be edited or deleted like any other. Terms the recogniser
already spelled correctly are not added, so the list stays short. Turn the whole thing off in
Settings › General.

---

## Everything else

- **History** in SQLite, searchable, with a retention window (30 days by default, or forever).
  Recordings are kept only if you ask, and are deleted on their own schedule.
- **Replacements** applied after the model, literal or regex, ordered. The dictionary runs before
  the model and the model can undo it; this is the pass that cannot be argued with.
- **Per-app rules.** "In this app, or on this website, use that mode." Websites are matched from
  the frontmost browser window without any per-browser scripting.
- **HUD** in the display notch, or at the bottom of the screen, or off.
- **Insertion** by paste or by simulated typing, for terminals and game engines that drop a
  synthetic `⌘V`. Optional trailing space, optional Return to submit, per mode. Your clipboard is
  restored afterwards.
- **Audio** input device selection, stop-on-silence, and muting other output while recording.
- **Backup** of modes, dictionary, replacements, app rules and preferences as one JSON file. It
  contains no API keys, which live in the Keychain, and no history.
- Six interface languages, of which one was written by a native speaker. See
  [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Install

Requires **macOS 26 or later on Apple silicon**. There is no fallback for older systems: the
recogniser is `SpeechAnalyzer`, which does not exist before macOS 26.

1. Download the `.dmg` from [Releases](https://github.com/SammyLin/OpenTalkType/releases) and drag
   the app to Applications.
2. Run it from `/Applications`, not from the mounted disk image. The image is read-only, so an
   app launched from there cannot install its own updates.
3. Grant Microphone and Accessibility when asked.
4. System Settings › Keyboard › **Press globe key to** → **Do Nothing**, or holding `fn` opens the
   emoji picker on top of your dictation.

Every release ships `SHA256SUMS.txt` if you want to check what you downloaded.

---

## Rough edges

Stated here rather than discovered later.

**Signed and notarised, so the first launch is ordinary.** Releases are built on a GitHub runner,
signed with a Developer ID certificate, submitted to Apple, and stapled, and the workflow refuses
to publish if `spctl` does not accept the result. Earlier builds were adhoc-signed and told you to
right-click and choose Open — worth knowing that this stopped working in macOS 15, so that advice
was wrong for everybody running an OS this app supports at all.

Updates after that are verified separately. Each release is signed with an EdDSA
key that exists in two places, the author's Keychain and this repository's Actions secrets, and
the app refuses anything that does not match the public key compiled into the bundle. An update
cannot be substituted even by someone who controls the download server. That distinction matters
for an app holding Accessibility permission: the risk is not the download, it is what gets to
replace a program allowed to watch every keystroke. Automatic checking still ships off, because an
app that phones home before anyone agreed to anything is doing it without asking.

**Accessibility permission is the permission to observe every keystroke on the machine.** That is
what a `CGEvent` tap is, and it is how `fn` is detected at all; the same grant is what reads your
selection for Ask mode and pastes the result. You should not take that on trust from a README. The
code that uses it is one file, [`OpenTalkType/Input.swift`](OpenTalkType/Input.swift), the tap
callback does nothing but flip state, and the app has no network code outside `LLM.swift` and the
update check.

**Set the globe key to do nothing.** Until you do, `fn` opens the emoji picker at the same moment
OpenTalkType starts listening. The app deliberately does not swallow the `fn` event: WindowServer
updates modifier state upstream of an event tap, so eating it would leave the whole system
believing `fn` is held.

**Rebuilding silently revokes Accessibility.** A local build is ad-hoc signed and gets a new
identity every time you rebuild, so macOS invalidates the grant without saying so, while the
checkbox in System Settings still looks ticked. The symptom is that pasting simply stops working.
Fix it with **Re-request permissions** in Settings › Permissions, or remove the app from the
Accessibility list and add it back.

**Secure input blocks pasting.** A password field, or Secure Keyboard Entry in Terminal, puts the
whole system into secure input, where nothing synthetic is delivered. The text is left on the
clipboard and the app says so rather than looking broken.

---

## Build from source

No third-party dependencies, no package manager step, nothing to resolve.

```sh
xcodegen generate
open OpenTalkType.xcodeproj
```

`brew install xcodegen` first, if you do not have it. Xcode 26 is required to build. Signing is
ad-hoc, so no Apple Developer account is needed.

### Self-test

The app is its own test harness, because a GUI cannot be verified by reading source:

```sh
OpenTalkType.app/Contents/MacOS/OpenTalkType --selftest
```

173 pure-logic checks: no window, no microphone, no network, no permission prompt. One `PASS` or
`FAIL` per line, exit 0 only if everything passed. CI runs it on `macos-26` on every push, together
with a real MCP handshake against the stdio server, and the release workflow runs it again against
the exact binary inside the `.dmg`.

---

## Licence

MIT. See [LICENSE](LICENSE).

## Acknowledgements

The notch HUD's shape — the way the plate flares out of the display cutout instead of sitting
under it as a slab — was learned from [sk-ruban/notchi](https://github.com/sk-ruban/notchi).
