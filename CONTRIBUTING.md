# Contributing

## Localisation

The interface is written in English. English is the base language: a `Text("Start
dictation")` literal in the source *is* the English string, and every other language
comes from the String Catalog at `OpenTalkType/Localizable.xcstrings`. Permission
prompts live in `OpenTalkType/InfoPlist.xcstrings`.

Six languages ship. Only one of them was written by a native speaker:

| Locale | How it was made |
|---|---|
| `en` | Base language, written in the source. |
| `zh-Hant` | Hand-written. This is the language the app originally shipped in. |
| `ja`, `ko`, `es`, `fr`, `de` | **Machine-translated, never reviewed by a native speaker.** |

So the five machine-translated locales are very likely to contain wording that is
merely correct rather than natural, and in places may be plain wrong — particularly
where the text names a macOS control the reader is being told to go and click
("System Settings → Keyboard → Press Globe key to → Do Nothing"), which should match
whatever that localised macOS actually calls it.

Corrections are welcome and do not need to be complete. A pull request that fixes one
awkward sentence is worth more than a silent wince. If you would rather not open a PR,
an issue quoting the English key and your suggested replacement is just as useful.

### Editing a translation

Open `OpenTalkType/Localizable.xcstrings` in Xcode, which shows it as a table of keys
against languages. The English column is not editable there: the key is the English
string, so changing English means changing the literal in the Swift source. Set the
state of anything you touch to **translated**.

Two things must survive translation intact:

- **Format specifiers.** `%@`, `%d`, `%lld` and `%.1f` have to appear the same number of
  times as in English. Where a string has more than one and your language needs a
  different order, use the positional forms `%1$@`, `%2$d`.
- **Anything that is not prose.** URLs and their query parameters, `$OT_TRANSCRIPT` and
  the other environment variables, `{{TARGET}}`, `--mcp`, `/bin/sh`, key names such as
  `fn`, `Esc` and `⌘V`, and the example domains. If a string is code, copy it through.

Prompts are not translated at all. The text sent to the language model is behaviour,
not interface, and it lives in `Settings.swift` outside the catalog.

### Adding a language

Add the locale in Xcode's String Catalog editor and translate the keys; `xcodegen
generate` picks the new language up on the next run, and the built app gains its
`.lproj` automatically. Please say in the pull request whether you wrote it yourself or
machine-translated it, so this table stays honest.
