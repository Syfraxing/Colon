# Contributing to Colon

Thanks for helping make emoji on the Mac feel effortless.

## Getting started

```sh
git clone https://github.com/Syfraxing/Colon.git
cd Colon
make test        # swift test
make install     # build, copy to /Applications, launch
```

You need macOS 14+ and Xcode 16+ (Swift 6 toolchain). The project is plain SwiftPM;
open `Package.swift` in Xcode if you prefer an IDE.

Sign builds with a stable identity: your Apple Development certificate, or any
self-signed code-signing certificate (the build script picks it up automatically, or set
`SIGN_IDENTITY`). macOS ties the Accessibility permission to the code signature, so with an
ad-hoc signature you have to re-grant Accessibility after every rebuild
(`tccutil reset Accessibility so.slayer.Colon`).

## Ground rules

- Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first. It describes the data flow and
  the behaviour contract (trigger rules, privacy guarantees, picker spec).
- Keep `swift build` and `swift test` green. Add tests for logic in `ColonCore`
  (trigger parsing, search, ranking); UI and event-tap code lives in the `Colon` target.
- Privacy is a feature: never buffer typed text outside an active `:query`, never read
  secure fields, never log or persist the Jev API key (it lives only in the Keychain).
  Never commit keys or tokens, not even in tests; CI scans every commit and fails if it
  finds one.
- No new dependencies without discussing it in an issue first.
- Swift 5 language mode, standard Swift API design guidelines, small focused commits.

## Testing typing end to end

Scripted typing is not always what a keyboard sends. Run `COLON_DEBUG=1` and read the
`so.slayer.Colon` log before calling a missing picker a bug.

- AppleScript `tell application "System Events" to keystroke ":ema"` posts ⇧ and `;`
  microseconds apart. The tap can then read the `;` without ⇧ (and the next letters with ⇧),
  so `:` arrives as `;`. A real keyboard does not do this, and neither does a VNC client
  typing through the VM's virtual keyboard. `cua do type` attaches the text to each event, so
  it is safe too.
- Colon keeps only one bit about the character before the caret. A new document created by a
  script (`make new document`) gets no click, ⌘ shortcut or app switch, so that bit still
  describes the previous document. If the previous text ended in a letter, the next `:` counts
  as mid-word. Open documents with ⌘N, or end each check with Return, a space or a click.

## Pull requests

1. Fork and branch from `main`.
2. Describe what changed and why; include a screenshot or screen recording for UI changes.
3. Make sure CI passes.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
