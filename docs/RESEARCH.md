# Colon — macOS emoji-picker research

Research date: 2026-10-10. Everything below was read from primary sources (GitHub source, vendor docs) unless tagged **[INFERENCE]** (my reading, not observed) or **[SECONDARY]** (blog/forum/search summary, not verified against source).

**License hygiene.** Mojito is **AGPL-3.0**, Espanso is **GPL-3.0**, Swiftmoji ships no license file (treat as all-rights-reserved). Their code is quoted/condensed here as *research evidence of technique*. Colon's implementation MUST be written independently; do not paste from them. MIT sources (FujiMoji, CursorBounds, gemoji, emojibase, emojilib, Emoogle) are safe to learn from and adapt with attribution.

Contents: 1 Landscape · 2 Per-product findings · 3 Implementation techniques (tap, keys, caret, insert, panel, secure input, permissions) · 4 Datasets · 5 Ranking · 6 Distribution · 7 Pitfall checklist · 8 Recommendations · 9 UX spec.

---

## 1. Landscape (what exists)

| Product | Kind | Trigger | Open source | Inline at caret | Notes |
| --- | --- | --- | --- | --- | --- |
| **Rocket** (Matthew Palmer) | menu-bar app | `:` (configurable single punct; `:` `(` `+` recommended) | no (free; Pro $10) | yes | The original. Needs Accessibility; AppleScript to read browser URL for per-site disable. https://matthewpalmer.net/rocket/ , https://matthewpalmer.net/rocket/help.html |
| **Macmoji** (warpling) | *not an app* — 1741 macOS Text-Replacement entries (`:boom:`→💥) as a `.plist` (+ Alfred/Keyboard Maestro outputs) | `:name:` + Space | MIT | no | https://github.com/warpling/Macmoji |
| **Mojito** (wr) | menu-bar app, Swift | `:` emoji, `::` symbols, `:::` GIF, `:?` favorites | **AGPL-3.0** | yes | Best-engineered reference. https://github.com/wr/mojito |
| **Swiftmoji** (amitskr) | menu-bar app, Swift | `\\` (double backslash) default | unlicensed | yes | Small, readable, naive in places. https://github.com/amitskr/Swiftmoji |
| **FujiMoji** (RickLiu1203) | menu-bar app, Swift | `/name/` (start/end keys configurable), popup after 2+ chars | **MIT** | yes | Uses paste-with-restore. https://github.com/RickLiu1203/FujiMoji |
| **Comoji** | menu-bar app | `:` (swappable: `; / \ @ # ~ \|`) | closed (free) | yes | Tab inserts. Per-app/site disable. https://www.comoji.io/ |
| **Emoji Picker for macOS** (inndevs) | menu-bar app | `;` default | closed (free; Pro $5) **[SECONDARY]** | yes | https://inndevs.com/emoji-picker-macos/ |
| **Raycast** Emoji & Symbols | launcher command | global hotkey; `:` inline **only inside Raycast's own text fields** | closed | no (paste into app) | Frecency + pinned + name match; AI results. https://manual.raycast.com/emoji-symbols |
| **Mojibar** (muan) | Electron menu-bar | ⌃⇧Space | MIT, archived 2023-01 | no | Search → Enter copies. https://github.com/muan/mojibar **[SECONDARY via search summary]** |
| **macOS Emoji & Symbols** | system | ⌃⌘Space / 🌐 | — | near caret, steals focus | Grid, mouse-driven, no autocomplete. https://www.comoji.io/blog/emoji-picker-for-mac **[SECONDARY]** |
| **TextExpander / Espanso / BetterTouchTool** | expanders | typed abbreviations | Espanso GPL-3 | no popup | Keystroke logging + inject; relevant for plumbing only. |

Takeaway: the *experience* is "Slack-style `:query` → ranked popup at caret → Tab/Enter". All implementations in the table that work inline use the same plumbing (global key tap → AX caret → synthesized keystrokes). The differentiators are reliability in odd apps, speed, and ranking.

---

## 2. Per-product findings

### 2.1 Rocket
Sources: https://matthewpalmer.net/rocket/ · https://matthewpalmer.net/rocket/help.html · https://www.theverge.com/2016/12/16/13980094/mac-emoji-app-rocket · https://lifehacker.com/rocket-easily-adds-slack-style-emoji-search-to-your-mac-1790193445

UX (documented):
- Type `:` then the start of a name (`:thu`), popup appears, **Return** inserts (Verge: "Enter a colon … type its name, and hit enter again to insert"; Lifehacker: "tap the Return key when you have the emoji you want").
- Trigger key is a single punctuation char, user-configurable; author: "`:`, `(`, and `+` work best". The help page mentions a **"double key" trigger** setting (exact semantics not documented; Mojito's later `::`/`:::` and Swiftmoji's `\\` double-trigger suggest "type the trigger twice") **[INFERENCE]**.
- Free: skin-tone pick, light/dark themes, "access to every emoji through the shortcut window". Pro: browse/search window, gifs/images, custom shortcuts, snippets with `{{ date_short }}`-style variables, usage stats.
- **Per-app disable list** (matches by process name — VS Code appears as "Electron", IntelliJ as "idea", must be hand-renamed) and **per-website disable** (Trello/GitHub/Slack) by asking the active browser for its URL **via AppleScript** (needs Automation + Finder + System Events consent on Mojave+). Hidden "chrome-devtools" disabled-site hack.
- Failure mode the author documents: "macOS will stop delivering messages to Rocket" (tap silently dead) → fix is remove from Accessibility, reboot, re-add. Other-cause list: apps holding **secure input** (Keybase, LastPass, Bitwarden), wrong keyboard layout vs trigger key, VMs, SMC/NVRAM reset. This is the real-world cost of a CGEventTap app; Colon must detect and surface it (see §3.1, §3.6).

Implementation: closed source. Behavior implies a global key tap + AX (Accessibility permission only is requested in 2016 reviews).

### 2.2 Macmoji (warpling/Macmoji) — source read
Repo: https://github.com/warpling/Macmoji (README, `emojiSubstitutions.plist`, `scripts/update-output.py`, templates).

- It is **data, not code**. `emojiSubstitutions.plist` is an array of `{phrase: "💥", shortcut: ":boom:"}` dicts (1741 entries) you drag into System Settings › Keyboard › Text. A Python 2 script renders the same list into Alfred/Keyboard Maestro templates.
- UX it inherits from macOS Text Replacement: must type the full `:name:` then Space; no popup; no ranking.
- README lessons worth stealing: (1) **colons exist to prevent over-eager expansion** of ordinary words ("ghost bananas are cool"); (2) **skin tones** as a suffix token `:skin-tone-3:` typed after the emoji and combined; (3) **known failure: Chrome bypasses system text replacement** (so a system-substitution approach cannot be "anywhere"); (4) iCloud syncs substitutions to iOS where colons are ignored (a hazard of using the system mechanism).
- There's an unrelated, similarly named 2-star repo `mattbergland/macmoji` ("Slack-style emoji autocomplete, everywhere on your Mac", made with Devin): https://github.com/mattbergland/macmoji — not analyzed; avoid the name collision.

### 2.3 Mojito (wr/mojito) — source read (AGPL; ~213 Swift files)
Primary refs (all `raw.githubusercontent.com/wr/mojito/main/…`): `CLAUDE.md`, `CHANGELOG.md`, `Sources/Mojito/KeyMonitor/{KeyMonitor,TriggerStateMachine}.swift`, `Inserter/TextInserter.swift`, `Picker/{CaretLocator,PickerWindow}.swift`, `Util/PanelPositioner.swift`, `Context/{FocusedElementCache,AppContext}.swift`, `Permissions/PermissionsCoordinator.swift`, `Exclusions/DefaultExclusions.swift`, `EmojiDB/{FuzzyMatcher,FzyScorer}.swift`, `scripts/setup-dev-signing.sh`.

Architecture (from its CLAUDE.md): `KeyMonitor (CGEventTap) → TriggerInput → TriggerStateMachine(.idle/.capturing) → TriggerAction(+consumesKey) → Engine → TextInserter`. The tap is installed **on the main run loop** and the delegate is called synchronously (`MainActor.assumeIsolated`) because the callback's return value (consume vs pass-through) depends on state-machine output; they explicitly warn against `Task { @MainActor }` there.

UX facts:
- `:` + name opens picker **after 2 chars** (`pickerThreshold` = 2; 1 if query has non-ASCII or is a `::` symbol query). A sub-threshold capture stays silent so `:D ` / `:)` emoticons can still convert.
- `:` only fires after a **non-word char** (`lastWasWordChar` gate so `5:35`, `foo:bar` don't fire); gate is deliberately false after backspace/arrows/focus change so the picker still opens after caret moves.
- Name chars: a–z 0–9 `_ - +`. Anything else (space/punct) ends capture and passes through. `:name:` typed fully with the closing `:` → exact match inserts without ever showing the picker; if no exact match the text stays literal.
- Keys while open: ↑/↓ move, **Return/Tab insert** (swallowed), Esc closes (swallowed), ←/→ swallowed so the caret can't drift out of `:query`, Backspace passes through and edits query, **Shift+Return/Tab = insert and keep open** (sticky multi-pick). `:?` = horizontal "pill" of favorites where digits 1–8 pick directly. Return/Tab are **not** swallowed if the picker never surfaced / has no rows (`topResult == nil` guard) — otherwise the host app needs a second press.
- Layout: width 280, rows 30 pt, max 6 visible rows, 26 pt footer with hints, corner radius 13, selection inset 5. Native-looking: `NSGlassEffectView` on macOS 26+, `NSVisualEffectView(.menu)` earlier.
- Placement: below caret with 6 pt gap, flip above if no room, clamp to screen `visibleFrame` (8 pt side margin), screen chosen by anchor centre.
- Learns favourites (frequency boost), default skin tone, emoticon conversion (`:D`,`<3`,`->`), custom aliases, 19 UI languages / 14 localized shortcode sets, per-app/URL exclusions with an **allow-list mode**, default-excluded apps with native shortcodes (Slack, Discord, Notion, Linear, Teams, Telegram…) and dev tools/terminals (Xcode, VS Code, JetBrains, iTerm, Ghostty…) because `:q` (Vim) and `->` collide with code.
- Real bugs they fixed (CHANGELOG — free pitfall list): keystrokes dropped when frontmost app hangs, esp. Arc (v1.8.1) → AX IPC must never run in the tap callback; Slack needs `AXManualAccessibility` (v1.9.1); picker opened one line too high at end of document in TextEdit (v1.10.0); emoji at the start of an empty Slack message "flashes and disappears" (v1.9.1); pickers covered by app pop-ups (v1.8.0, fixed by window level); translucent/cut-off panel on macOS 27.2 light mode (v1.10.1).

### 2.4 Swiftmoji (amitskr) — source read
https://github.com/amitskr/Swiftmoji · `Source/KeyboardManager.swift`, `Source/FloatingPanel.swift`.
- Tap: `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, **keyDown only**; callback re-enables on `.tapDisabledByTimeout/.tapDisabledByUserInput`; swallows by `return nil`.
- State machine inline in the tap callback: trigger char → `isTracking`; query chars appended, `Esc/Enter/Tab/↑/↓` swallowed; any non-`[A-Za-z0-9_+-]` cancels; closing trigger char with matches inserts (swallowed).
- Insert: N × `CGEvent(keyboardEventSource: .hidSystemState, virtualKey: 51)` posted to `.cgSessionEventTap` with `Thread.sleep(0.002)` between, then ONE key-down/up pair carrying the whole emoji via `keyboardSetUnicodeString` (no chunking). Re-entrancy guard is a `isAutoCompleting` bool (racy — events are delivered asynchronously; Mojito and Espanso instead *mark* their own events, §3.4).
- Caret: `AXFocusedUIElement → AXSelectedTextRange → AXBoundsForRange`, flipped with `NSScreen.screens.first.frame.height`; runs on a global queue so the tap callback never blocks (good), seeded by `NSEvent.mouseLocation` (good).
- Panel: borderless `.nonactivatingPanel`, `level = .statusBar`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `canBecomeKey = false`, `.hudWindow` blur. Weak spots: placement uses `NSScreen.main` not the caret's screen; rebuilds an `NSHostingView` on every keystroke; no secure-input/password check; reads `UserDefaults` in the hot path; skin tone via hard-coded emoji list. Good as a minimal reference, not as a design.

### 2.5 FujiMoji (RickLiu1203) — MIT, source read
https://github.com/RickLiu1203/FujiMoji · `Models/KeyDetection.swift`, `Models/TextReplacement.swift`.
- Both a `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, keyDown)` **and** `NSEvent.addGlobalMonitorForEvents(.keyDown)` plus a global mouse-down monitor that cancels capture on click. Uses `asyncAfter(0.05)` to let the trigger key land before finishing capture.
- Insertion: `deleteCharacters` = N× virtual key 51 down/up via `.cghidEventTap`; replacement via **clipboard**: save `pasteboard.string`, write emoji, after 10 ms post ⌘↓ V↓ V↑ ⌘↑ with `.maskCommand`, restore the old string after **250 ms**. (Only restores plain string — images/rich clipboard contents are lost; see §3.4.)
- UX: popup after 2+ chars, ↑/↓ + Tab/Enter, `3/heart/` multiplier prefix (insert ×3).

### 2.6 Comoji (closed) — vendor docs
https://www.comoji.io/blog/slack-emoji-shortcuts-on-mac · https://www.comoji.io/blog/emoji-picker-for-mac
- Two permissions: **Input Monitoring** (notice `:fire`) + **Accessibility** (read field, insert). Setup window shows live grant status and links to the panes.
- UX: type `:fire` → popover at cursor ranked with **recents** → arrows → **Tab or Return**. `::` opens a grid browser at the caret. Trigger swappable to `; / \ @ # ~ |`.
- Statements about behavior that are good design rules: "only intercepts Tab/Return while the popover is visible, resets aggressively on clicks and app switches, never fires on a partial match unless you ask"; ignores secure fields; per-app and per-website disable; "dead everywhere with a padlock = macOS secure input, not a permission problem"; **"don't move the app after granting"**; web editors that fully take over input (Google Docs) are hit-or-miss.
- Notes custom Slack-workspace emoji can't work outside Slack (images, not Unicode).

### 2.7 Raycast (Emoji & Symbols)
https://manual.raycast.com/emoji-symbols
- Results "ordered by **pinned emojis, frecency, and name matches**". Enter pastes into the active app; ⌘↵ copy; ⇧⌘↵ paste and keep window open; ⌥⌘V paste-with-skin-tone submenu (6 previews, only for tone-capable emoji); ⌘. pin; ⌘E custom keywords; AI results on no-match or Tab ("find by meaning"); default skin tone setting also applies to inline suggestions. Can hijack the 🌐 key if "Press Globe key to" = Nothing.
- Inline `:` autocomplete works **only inside Raycast's own UI** ("does not type into third-party apps") — i.e. Raycast deliberately does not do the global-tap thing.
- Lessons: frecency + pinned + custom keywords learned from AI queries ("save AI-generated custom keywords") is a template for Colon's Jev blend: persist query→emoji picks as keywords.

### 2.8 Mojibar, Emoji Picker for macOS, Mowji, TextPal
- Mojibar: Electron + `menubar` + `emojilib 2.2.3`; ⌃⇧Space; Enter copies Unicode, ⇧Enter copies `:code:`; archived 2023. Pure copy-to-clipboard model, no caret integration (https://github.com/muan/mojibar, summary via search). **[SECONDARY]**
- Emoji Picker for macOS (inndevs): `;` trigger, custom shortcodes + saved replies; macOS 13+; Pro $5. Mowji "announced"; TextPal discontinued (points users to Raycast). All from Comoji's comparison page **[SECONDARY]**.

### 2.9 TextExpander / BetterTouchTool / Espanso
- **TextExpander** (https://textexpander.com/secure-input , https://textexpander.com/learn/accounts/security/how-textexpander-handles-your-keystrokes-keylogging-and-snippet-security): keeps a ring of last 30 keystrokes (300 with suggestions), **clears it on shortcut, arrow key, or app switch**; disables capture when **Secure Input** is on and polls `IsSecureEventInputEnabled()` on a timer; uses private `kCGSSessionSecureInputPID` to name the offending process (openradar 48953777); snippet-suggestions ignore strings < 20 chars so passwords aren't proposed. Good model for Colon's privacy rules: *tiny* buffer, cleared on any non-typing event.
- **BetterTouchTool**: typed key sequences / text triggers + "paste/type custom text" action, with "only trigger if no other key for N ms" for prefix-ambiguous sequences. Explicitly no predictive emoji ("BTT doesn't have the same access to entered text as the system touch bar") — https://folivora.ai/features/keyboard-shortcuts/ , https://community.folivora.ai/t/predictive-text-touch-bar-widget/1363 **[SECONDARY]**.
- **Espanso** (GPL-3; `espanso-detect/src/mac/native.mm`, `espanso-inject/src/mac/native.mm`): detection = **`NSEvent addGlobalMonitorForEventsMatchingMask:`** (passive; can't swallow keys; needs Input Monitoring only) + Carbon `RegisterEventHotKey` for hotkeys; injection = `CGEventPost(kCGHIDEventTap)`. Config exposes `backend: inject | clipboard | auto`, `clipboard_threshold`, `preserve_clipboard`, `force_mode` per match (https://espanso.org/docs/configuration/options/). Their native code documents several hard-won facts (quoted in §3.4).

---

## 3. Implementation techniques

### 3.1 Keystroke capture

**Options and what the shipping apps chose**

| Mechanism | Can swallow keys? | Permission (per search-summary sources) | Used by |
| --- | --- | --- | --- |
| `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap)` | **yes** (return `nil`) | Accessibility (+ Input Monitoring in practice; Mojito and Comoji request both) | Mojito, Swiftmoji, FujiMoji, (Rocket presumably) |
| same with `.listenOnly` | no | Input Monitoring only | — |
| `NSEvent.addGlobalMonitorForEvents(.keyDown)` | no (read-only copy) | Input Monitoring | Espanso, FujiMoji (secondary) |
| InputMethodKit input method | yes, and gets *composition-aware* text | none, but user must add the input source in System Settings; major UX/onboarding cost | none of the surveyed emoji apps |

Evidence for the permission split: "`defaultTap` triggers Accessibility, `listenOnly` triggers Input Monitoring" (https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/ , https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html **[SECONDARY]**). Because Colon must swallow ↑ ↓ Tab Enter Esc only while the popup is open, it needs `.defaultTap`. A hybrid (listen-only tap normally, switch to an active tap only while open) is possible **[INFERENCE]** but the extra tap-creation latency on `:` would hurt the "instant" feel; every surveyed app keeps one active tap alive.

**Swallowing only while open.** The tap callback returns `Unmanaged<CGEvent>?`: `nil` = swallow, `passUnretained(event)` = pass. All state lives in a pure state machine; the callback translates event → input, asks the machine "consume?", returns accordingly. Mojito's rule list is the best-documented:

```swift
// Technique from Mojito KeyMonitor.swift / TriggerStateMachine.swift (re-expressed; do not paste).
let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                      | (1 << CGEventType.flagsChanged.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, type, event, refcon in
        let me = Unmanaged<InputController>.fromOpaque(refcon!).takeUnretainedValue()
        return me.handle(type: type, event: event)   // runs on the thread of the run loop it's added to
    }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)   // main loop => synchronous state machine, no locks
CGEvent.tapEnable(tap: tap, enable: true)

func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) } // our own synth keys
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CGEvent.tapEnable(tap: tap, enable: true); resetState(); return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let input = translate(event) else { return Unmanaged.passUnretained(event) }
    return machine.consume(input) ? nil : Unmanaged.passUnretained(event)
}
```
Source for each element: `CGEvent.tapCreate(... .cgSessionEventTap, .headInsertEventTap, .defaultTap ...)`, main-run-loop install, marker check, and re-enable on `tapDisabledByTimeout/UserInput` are all in `KeyMonitor.swift` (https://raw.githubusercontent.com/wr/mojito/main/Sources/Mojito/KeyMonitor/KeyMonitor.swift); Swiftmoji does the same re-enable (https://raw.githubusercontent.com/amitskr/Swiftmoji/main/Source/KeyboardManager.swift).

**Things the surveyed code teaches**
1. **Tap disabled by timeout/user input**: handle both types by `tapEnable(true)` *and reset the state machine and hide the picker* (Mojito also notifies a delegate). A non-nil tap is not a healthy tap — poll `CGEvent.tapIsEnabled(tap:)` every few seconds and reinstall if it won't re-enable (Raffel article above; after re-signing, launching via Launch Services produced a silent inert tap; he reinstalls ~1 s after launch).
2. **Never do synchronous cross-process work in the callback.** Mojito's `AppContext.swift` states it: "all reads must be cache-hits — no synchronous cross-process IPC; a hung app stalls past the ~1 s timeout and macOS drops the keystroke". Their fix for Arc keystroke loss (CHANGELOG v1.8.1) was to cache the focused `AXUIElement` via an `AXObserver` and do seeding on a background queue (§3.3).
3. **Keep the callback tiny.** Swiftmoji's `NSEvent(cgEvent:)` allocation per keystroke and `UserDefaults` reads work but are avoidable; read settings into plain properties.
4. **Ignore modifier combos.** Mojito's `translate` returns `nil` for anything with ⌘/⌃/⌥ (and treats ⌘Z specially) so shortcuts never interrupt or trigger capture; *and* such combos cancel capture **[INFERENCE: they are not translated to inputs, so the state machine never sees them — Colon's architecture already lists them as `.interrupt`]**.
5. **Own-event filtering by marker**, not by flag: `event.setIntegerValueField(.eventSourceUserData, value: marker)` on posted events and compare in the tap (Mojito; without it, synth backspaces round-trip and `:)` became `::)`). Espanso marks with a magic location `CGPoint(-27469, 0)` instead (`inject.mm`: `ESPANSO_POINT_MARKER`), and its NSEvent monitor checks `locationInWindow.x`.
6. **Key repeat / held keys** pass through the same path; Mojito consumes Backspace on an *empty* sticky query so a held Backspace can't leak into the host document.
7. **Tap thread stalls under secure input**: while any process holds `EnableSecureEventInput`, "WindowServer hides keyDown/keyUp from every event tap" (TN2150 https://developer.apple.com/library/archive/technotes/tn2150/_index.html ; behavior description from https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585 **[SECONDARY]**). Detect with `IsSecureEventInputEnabled()` and tell the user (§3.6).

### 3.2 Keycode → character (layout awareness)

Preferred (what Mojito does): read the translated string off the event, no layout code at all.

```swift
var len = 0
var buf = [UniChar](repeating: 0, count: 4)
event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
guard len > 0, let scalar = Unicode.Scalar(buf[0]) else { return nil }   // `:` on any layout arrives as ":" (Shift+; on US)
```
Control keys by virtual keycode (layout independent): Esc 53, Return 36, keypad Enter 76, Tab 48, Delete(backspace) 51, ForwardDelete 117, ← 123, → 124, ↓ 125, ↑ 126 (Mojito uses `kVK_*` constants; Swiftmoji hard-codes 53/36/76/48/51/125/126). Check the string, not the keycode, for printable keys — then AZERTY/Dvorak/Colemak "just work" (Rocket's help page blames mismatched layout vs trigger key for failures when matching by keycode).

Reverse mapping (only needed if you ever must *synthesize* a printable key, or detect "which physical key produces `:`"): `UCKeyTranslate` over the layout data. Use `TISCopyCurrentKeyboardLayoutInputSource` (not the current *input source*, so CJK IMEs still yield a layout) with an ASCII-capable fallback:

```swift
func character(for keyCode: CGKeyCode, modifiers: UInt32 = 0) -> String? {
    var src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    var data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
    if data == nil {                                   // e.g. Japanese romaji source
        src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
    }
    guard let data else { return nil }
    let layout = unsafeBitCast(data, to: CFData.self)
    let ptr = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
    var dead: UInt32 = 0, n = 0, out = [UniChar](repeating: 0, count: 8)
    let st = UCKeyTranslate(ptr, UInt16(keyCode), UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF,
                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                            &dead, out.count, &n, &out)
    return st == noErr ? String(utf16CodeUnits: out, count: n) : nil
}
```
Pattern reference: the `TISCopyCurrentKeyboardLayoutInputSource` + ASCII fallback guidance is from https://github.com/joaodavidsilva/brightboi/issues/65 and https://github.com/hartra344/pincer/issues/81 **[SECONDARY]**; the `UCKeyTranslate` call shape is the standard Carbon one. I did not run this snippet.

IME/dead-key caveat **[INFERENCE]**: with a CJK IME composing or a dead key pending, the tap sees raw keyDowns that may not equal the final inserted text; none of the surveyed apps handle it. Cheap mitigation: if the current input source is not a plain keyboard layout (`kTISPropertyInputSourceType != kTISTypeKeyboardLayout`), stay silent.

### 3.3 Caret position via Accessibility

**The ladder used in practice (Mojito `CaretLocator.swift`, condensed):**
1. Focused element: cached `AXUIElement` (observer-maintained) else `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute`.
2. `kAXSelectedTextRangeAttribute` → `CFRange` (loc, len).
3. Bounds via `kAXBoundsForRangeParameterizedAttribute`, **in this order** (their comment explains each): next glyph `(loc, max(len,1))`; else *previous* glyph's trailing edge `(loc-1, 1)` unless that char is a newline; else zero-length `(loc, 0)` (NSTextView answers that one line too high at end-of-document — the v1.10.0 bug).
4. Convert AX → Cocoa, validate the rect is on a screen **and within the focused element's frame (±8 pt)**; apps return junk bounds otherwise.
5. Else element top-left (`kAXPosition`/`kAXSize`) **only if element height ≤ 160 pt** (a one-line field); for big editors/terminals/web areas return nil.
6. Else mouse location (`NSEvent.mouseLocation`) as a 1×16 rect.

```swift
// AX is top-left-origin, rooted at the *primary* display; AppKit is bottom-left. Same flip works across multiple screens.
func flipFromAX(_ r: CGRect) -> CGRect {
    let primaryH = NSScreen.screens[0].frame.height          // screens[0] is the menu-bar display
    return CGRect(x: r.origin.x, y: primaryH - r.origin.y - r.height, width: r.width, height: r.height)
}

func bounds(_ el: AXUIElement, _ loc: Int, _ len: Int) -> CGRect? {
    var range = CFRange(location: loc, length: len)
    guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
          let v = out else { return nil }
    var r = CGRect.zero
    guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0 else { return nil }
    return r
}
```
Sources: `CaretLocator.swift` (https://raw.githubusercontent.com/wr/mojito/main/Sources/Mojito/Picker/CaretLocator.swift), Swiftmoji `getCaretScreenPosition` (flip with `NSScreen.screens.first`), Hammerspoon notes https://balatero.com/writings/hammerspoon/retrieving-input-field-values-and-cursor-position-with-hammerspoon/ (AX reads ≈ 0.07 ms in-process native fields).

**Do not copy CursorBounds' coordinate handling.** `Aeastr/CursorBounds` (MIT, https://github.com/Aeastr/CursorBounds) has a clean `caret → textField → mouse` source-priority design and `smartPosition` helper, but its docs/implementation treat AX values as bottom-left ("`adjustForYAxis` … `screen.frame.maxY - y`"); Mojito and Swiftmoji both flip *from top-left* with the primary screen height. Verify empirically on a secondary screen before trusting any package.

**Timing: ask AX one run-loop tick after the key.** The tap callback runs *before* the app receives the keystroke, so the caret hasn't moved: "AX returns stale coordinates if we ask now" (Mojito `Engine.scheduleRepositionAndShow`: `DispatchQueue.main.async { … CaretLocator.caretRect() … }`). Also re-check the focus snapshot (PID + `CFEqual(element)`) in that deferred block and cancel if focus moved.

**Don't block on AX.** Mojito `FocusedElementCache`: an `AXObserver` on the app element for `kAXFocusedUIElementChangedNotification`, **registered before** reading the focused element (so a move between read and register isn't lost); all IPC on a serial background queue with `AXUIElementSetMessagingTimeout(…, 0.25)`; generation counters to drop stale seeds; debounce app activations by 100 ms; empty seeds retried with backoff `[0.25, 0.5, 1, 2×12]` s (cold-launching Slack and Chromium answer `kAXErrorCannotComplete` for seconds). Swiftmoji's simpler variant: mouse-location first, AX on a global queue, then re-show.

**Electron / Chromium / web**
- Chromium & Electron build their AX tree lazily when they detect an assistive client. Unlocks: set `AXManualAccessibility = true` on the **application** element (Electron's switch) and `AXEnhancedUserInterface = true` for Chromium browsers (Chrome/Edge/Brave/Arc…). The latter has side effects in non-browsers (window animations, window managers) so don't send it to everything; neither can be set back (`AXManualAccessibility=false` → -25205, `AXEnhancedUserInterface=false` → -25208). Sources: https://github.com/trycua/cua/pull/4640 , https://github.com/screenpipe/screenpipe/issues/3884 , Balatero article **[SECONDARY]**.
- Mojito only flips `AXManualAccessibility` when the focused-element read came back empty ("native apps … never reach here, so we never touch them"), then retries because "Chromium builds the tree asynchronously and doesn't announce the already-focused field once it's up":
```swift
let axApp = AXUIElementCreateApplication(pid)
// … read kAXFocusedUIElement; if nil:
AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
```
- Caveat (2020 article): Electron fields may report selection `{0,0}` regardless → caret rect unavailable. Then fall to the element-top-left rule or the mouse. Anchor policy for web content: if `AXRole == AXWebArea` or element taller than 160 pt, use the mouse location once at `:` time (the mouse is usually near the text) **[INFERENCE]**.
- Apps with no usable AX at all (Google Docs canvas, some games) → mouse anchor; Comoji lists them as "hit or miss".

**Multi-screen placement.** Pick the screen by anchor centre → any intersecting screen → `NSScreen.main` (`PanelPositioner.screen(for:)`), use that screen's `visibleFrame`.

### 3.4 Text replacement

| Strategy | Used by | Pros | Cons |
| --- | --- | --- | --- |
| **N × Backspace + one Unicode key event** (`CGEventKeyboardSetUnicodeString`) | Mojito, Swiftmoji, Espanso (inject), FujiMoji (backspaces) | no clipboard disturbance; works in most native + web fields; undo-friendly | needs per-key delays in slow apps; apps that drop synthetic events; ≤20-unit limit |
| **Clipboard + ⌘V + restore** | FujiMoji, Espanso (clipboard backend), Raycast | immune to key-drop and Unicode length | trashes rich clipboard unless fully saved/restored; race with clipboard managers; ⌘V remapped/disabled apps; adds ~10–250 ms |
| **Select-over (⇧← × N) then type** | Mojito (only when the typed text *is the entire field*) | field never passes through empty (Slack composer wipes next input when it goes empty) | extra path to test |
| AX write (`kAXSelectedTextAttribute` / `kAXValueAttribute` set) | none of the pickers | atomic | unreliable in Chromium/Electron/web, breaks undo **[INFERENCE]** |

**Mojito's insert, condensed** (https://raw.githubusercontent.com/wr/mojito/main/Sources/Mojito/Inserter/TextInserter.swift):
```swift
// 1. delete: N backspaces (or ⇧← if the field would become empty), each stamped with a marker, posted at HID level
func postKey(_ vk: CGKeyCode, flags: CGEventFlags = []) {
    guard let d = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
          let u = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else { return }
    d.flags = flags; u.flags = flags
    d.setIntegerValueField(.eventSourceUserData, value: marker)
    u.setIntegerValueField(.eventSourceUserData, value: marker)
    d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
}
// 2. type: one down/up pair carrying the emoji as UTF-16
let utf16 = Array(emoji.utf16)
let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
utf16.withUnsafeBufferPointer { b in
    d.keyboardSetUnicodeString(stringLength: b.count, unicodeString: b.baseAddress)
    u.keyboardSetUnicodeString(stringLength: b.count, unicodeString: b.baseAddress)
}
d.setIntegerValueField(.eventSourceUserData, value: marker); u.setIntegerValueField(.eventSourceUserData, value: marker)
d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
```
Counts: from-picker (Tab/Enter swallowed): delete `trigger.count + query.count`. Exact-match via closing `:` (the `:` was *not* swallowed): **wait one run-loop tick** so the passed-through colon lands first, then delete `trigger + query + 1` (Mojito `Engine.apply(.insertEmoji)` `.exactMatch` branch; ARCHITECTURE.md's variant swallows the closing `:` and deletes one fewer). Skin tone: insert the modifier after the **first scalar**, not at the end, so ZWJ sequences stay valid (`🧔‍♀️` + 🏿 → `🧔🏿‍♀️`; Mojito `SkinTone.swift`; emojibase supplies per-tone `skins[]` so you can simply pick the right pre-composed string instead).

**Espanso's hard-won facts** (`espanso-inject/src/mac/native.mm`, GPL, quoted as evidence):
- `CGEventKeyboardSetUnicodeString` "gets truncated after 20 characters" → they chunk by 20 and use virtual key 0x31 (space) as the carrier, with an explicit key-up ("some applications require an explicit release", issue #159).
- If **Shift is physically held** when injecting, release it first (issue #279) — relevant because `:` itself is Shift+; on US layouts and the user may still be holding Shift when pressing Enter/Tab.
- Events are posted from the main queue with `usleep(delay)` between events; delay is user-tunable per app (`inject_delay`, `backspace_delay`) because "no replacements, missing characters, or just 'v' appearing" occurs in some apps (https://espanso.org/docs/matches/basics/).
- Marks own events with a magic location (§3.1).

**Surrogate-pair / length pitfalls.**
- `keyboardSetUnicodeString` has an undocumented ~20 UTF-16 unit cap (https://github.com/enigo-rs/enigo/issues/68 ; https://forum.qt.io/topic/46579/cgeventkeyboardsetunicodestring-will-only-process-up-to-20-characters). Slicing `Array(text.utf16)` into raw 20-unit chunks can split a surrogate pair into two lone surrogates (U+FFFD or nothing) — documented in https://github.com/T0mSIlver/localvoxtral/issues/1092 and https://github.com/Shugar03/dexter/pull/24 **[SECONDARY]**. Espanso's loop slices by raw offset, so the same bug is reachable there **[INFERENCE]**.
- I measured Emoji 17 data (emojibase-data 17.0.0, base + toned variants = 3,979 strings): longest single emoji is **15 UTF-16 units** (`🧑🏻‍❤️‍💋‍🧑🏼`; 95 strings are 15 units); 1,237 are 2 units. So **one emoji always fits one event**; chunking only matters for multi-emoji strings (`3/heart/` style repeat). If you chunk, split on grapheme boundaries:
```swift
func chunks(_ s: String, maxUnits: Int = 20) -> [[UniChar]] {
    var out: [[UniChar]] = [], cur: [UniChar] = []
    for ch in s {                                  // Character == extended grapheme cluster, never splits a ZWJ sequence
        let u = Array(String(ch).utf16)
        if cur.count + u.count > maxUnits { out.append(cur); cur = [] }
        cur += u
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}
```
- Backspace count must be in **characters the app deleted**, and `trigger+query` is ASCII so 1 backspace = 1 char. Do **not** use Backspace to delete a *previous emoji*; one backspace deletes a whole grapheme in most apps but not all.
- **Timing:** Mojito waits **80 ms** after a passed-through terminator before deleting (emoticon path: "one tick wasn't enough — terminator could end up stranded after the emoji, `:)` → `🙂)`"); FujiMoji waits 50 ms; Swiftmoji sleeps 2 ms between backspaces; Espanso configurable. Budget: from-picker (key swallowed, nothing in flight) can run immediately; exact-match path needs ≥1 tick (and 80 ms for slow fields).
- **Clipboard restore** (if offering `.paste`): save *all* pasteboard items/types (`pasteboard.pasteboardItems` → copy each type's data), write emoji, post ⌘V, restore after ≥250 ms (FujiMoji restores only `.string` after 250 ms; Espanso has `preserve_clipboard`). Mark the temporary write with `org.nspasteboard.TransientType` so clipboard managers skip it **[INFERENCE — convention from nspasteboard.org, not verified here]**.
- Apps that drop synthetic events: anything reading raw HID (games, VMs, Remote Desktop), and apps with secure input; fallback = clipboard path or copy-to-clipboard + toast (Mojito: when the focused element isn't editable it copies and shows `CopyToast`).

### 3.5 Non-activating floating panel

Mojito (`PickerWindow.swift`, most careful) vs Swiftmoji:

```swift
let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 280, height: 100),
                    styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                    backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.level = .popUpMenu            // Mojito: NOT .floating — app pop-ups sit at .floating and, belonging to the active app, would cover us. Same band as NSMenu / native emoji candidate window.
panel.isOpaque = false; panel.backgroundColor = .clear
panel.hasShadow = true              // system menu shadow
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true // (Swiftmoji instead overrides canBecomeKey -> false)
panel.collectionBehavior = [.fullScreenAuxiliary, .transient]   // NOT .canJoinAllSpaces: flashes onto the destination Space during a swipe
panel.ignoresMouseEvents = false    // rows clickable; non-key panels still get clicks because of .nonactivatingPanel
// show: panel.setFrame(frame, display: true); panel.orderFrontRegardless()   — never makeKey…
```
- Keyboard never goes to the panel; keys come from the tap, so the target app keeps first responder/caret blink. Don't call `NSApp.activate`. Clicking a row works without activating thanks to `.nonactivatingPanel`.
- **Spaces/fullscreen:** `.fullScreenAuxiliary` lets it overlay a fullscreen app's Space; dismiss on `NSWorkspace.activeSpaceDidChangeNotification`; Swiftmoji's `.canJoinAllSpaces` + `.statusBar` is the alternative (shows on every Space).
- **Dismiss on click-away:** local + global `NSEvent` monitors for left/right/other mouseDown that never consume the click (`ClickAwayMonitor`).
- Tooltips: a non-key panel suppresses `.help` tooltips; Mojito hand-rolls a second tooltip panel.
- Material: macOS 26+ `NSGlassEffectView` (via `#available(macOS 26.0, *)`), else `NSVisualEffectView(material: .menu | .hudWindow, blendingMode: .behindWindow, state: .active)`; round via mask + `panel.invalidateShadow()`.
- Re-use one panel + one hosting view; update the view model instead of recreating `NSHostingView` per key (Swiftmoji recreates, which flickers/costs).
- Match the *target* appearance? Mojito uses `matchSystemAppearance()` before show.

### 3.6 Secure input, password fields, exclusions

- **Password fields:** AX *role* `AXTextField` + **subrole** `AXSecureTextField` (there is no role constant; Mojito `AppContext.isSecure` checks both, and **fails closed**: missing role ⇒ treat as secure). Works for native `NSSecureTextField`, Chromium/WebKit `<input type=password>`.
```swift
func isSecure(_ el: AXUIElement) -> Bool {
    guard let role = copy(el, kAXRoleAttribute) as? String else { return true }   // AX broken => fail closed
    return role == "AXSecureTextField" || (copy(el, kAXSubroleAttribute) as? String) == "AXSecureTextField"
}
```
- **System secure input:** `IsSecureEventInputEnabled()` (Carbon HIToolbox). While true the tap receives nothing — "WindowServer hides keyDown/keyUp from every event tap" (TN2150). A buggy holder (Cursor IDE leak, password managers, terminals' "Secure Keyboard Entry") kills *all* tap apps until quit/lock. TextExpander polls it on a timer. Surface it in the menu bar ("Paused — another app is using Secure Input") instead of silently failing; Comoji says "dead everywhere with a padlock on the icon … is secure input, not a permission problem".
- **Fail closed / classify off-thread:** Mojito caches `(secure, editable, role)` per focused element, computed off the tap thread; until classified, `secure = true`, so capture can't start in a password box that hasn't been classified yet. `editable` is biased **true** for unknown roles (browsers often hand back `AXWebArea`); positively non-text roles (`AXButton`, `AXStaticText`, `AXList`, …) disable the trigger.
- **Per-app exclusions:** match **bundle ID** (Mojito) not process name (Rocket's "Electron"/"idea" renaming pain). Default list = apps with native `:` pickers + terminals/IDEs (Mojito's `DefaultExclusions.swift`: `com.tinyspeck.slackmacgap`, `com.hnc.Discord`, `notion.id`, `com.linear`, `com.microsoft.teams2`, `ru.keepcoder.Telegram`, `com.tdesktop.Telegram`, `com.apple.dt.Xcode`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor), `dev.zed.Zed`, `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, JetBrains `com.jetbrains.*`…). Per-site exclusions need the page URL: Mojito reads `AXURL` (and Arc specially); Rocket used AppleScript. Excluded apps must **not swallow anything** — Mojito fixed a Vim `:q<Enter>` double-Enter bug by returning `false` from the tap for excluded captures.
- **Own windows:** don't act when Colon itself is frontmost (settings fields).
- **Privacy rules worth copying:** TextExpander's tiny cleared ring; Mojito "keystrokes are never logged or uploaded, password fields ignored"; Colon's ARCHITECTURE.md rule of *no* typed-text buffer beyond the active query is stricter and good.

### 3.7 Permissions UX and TCC

- Needs: **Accessibility** (active tap + AX reads + trust) and **Input Monitoring** (Mojito/Comoji request both). Don't create a tap to probe permissions — `CGEvent.tapCreate` triggers the Input-Monitoring alert before your onboarding can explain it. Mojito's coordinator:
```swift
let ax = AXIsProcessTrusted()                                            // no prompt
let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted   // no prompt (import IOKit.hid)
// prompt:
AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue!] as CFDictionary)
IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
// deep links:
// x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
// x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent
```
  Source: https://raw.githubusercontent.com/wr/mojito/main/Sources/Mojito/Permissions/PermissionsCoordinator.swift
- **Detect changes live:** observe `DistributedNotificationCenter` name `com.apple.accessibility.api` (refresh now **and** +0.5 s because it fires slightly before the state flips), refresh on `NSApplication.didBecomeActiveNotification` (user returns from System Settings), and poll every ~2 s **for the whole app lifetime** (revocation must tear the tap down promptly; a revoked-while-running active tap can freeze input **[SECONDARY]** https://github.com/jwu02/jwoo-cli/issues/3).
- **Ad-hoc signed builds lose TCC grants every rebuild.** TCC keys a grant to the code's *designated requirement*; ad-hoc (`codesign -s -`) DR is the **cdhash**, which changes each build, so `AXIsProcessTrusted()` returns false again while System Settings still shows a checked row. Sources: Mojito CLAUDE.md ("Do not switch to ad-hoc signing (`-`) … fresh cdhash and TCC treats it as a different app"), https://docs.mumbli.app/for-developers/accessibility-permissions , https://github.com/sennett-lau/typelite/pull/44 **[SECONDARY]**. Fix: sign with a **stable identity** — Apple Development/Developer ID, or a self-signed code-signing cert created once. Mojito's `scripts/setup-dev-signing.sh` (condensed):
```bash
openssl req -newkey rsa:2048 -nodes -keyout key.pem -x509 -days 3650 -out cert.pem \
  -subj "/CN=Colon Dev" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out bundle.p12 -name "Colon Dev" -password "pass:$PW" -legacy
security import bundle.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
security add-trusted-cert -r trustAsRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
codesign --force --options runtime --sign "Colon Dev" build/Colon.app
codesign -d -r- build/Colon.app    # want: designated => identifier "…" and certificate leaf = H"…"  (NOT cdhash H"…")
```
  Reset when stuck: `tccutil reset Accessibility <bundle-id>` (Swiftmoji README documents this form); the Input Monitoring service name is `ListenEvent` (`tccutil reset ListenEvent <bundle-id>`) **[not run here]**.
- Keep a separate bundle ID for dev builds (Mojito: `ee.wells.Mojito.dev`) so dev grants don't collide with a released copy.
- Moving the app after granting = new path → re-grant (Comoji's "don't move the app after granting"; install to `/Applications` first).
- After re-signing, launch via Launch Services can yield an inert tap; add the health check from §3.1.

---

## 4. Emoji datasets (shortcodes + keywords + licensing)

Measured today by downloading each (Oct 2026):

| Dataset | License | Size/shape (measured) | Shortcodes | Keywords | Skin tones | Freshness |
| --- | --- | --- | --- | --- | --- | --- |
| **github/gemoji** `db/emoji.json` — https://github.com/github/gemoji | MIT | 1870 entries; `{emoji, description, category, aliases[], tags[], unicode_version, ios_version, skin_tones?}`; 305 flagged tone-capable | GitHub names (`+1`,`thumbsup`) | `tags` (2–3 words each, thin) | boolean flag only | repo active; entries lag newest Unicode |
| **milesj/emojibase** (`emojibase-data@17.0.0`, CDN `cdn.jsdelivr.net/npm/emojibase-data@latest/en/…`) — https://emojibase.dev/docs/shortcodes | MIT (data derived from Unicode CLDR) | `en/data.json` 775 KB, **1949** base emoji (Emoji **17**), `{label, hexcode, tags[], emoji, text, type, order, group, subgroup, version, skins[]}`; 1923 have tags; 330 have `skins[]` with each toned variant | presets `github` (1870), `iamcal` (=Slack, 1911), `joypixels` (=Discord-ish), `emojibase` (3979 hexcodes incl. skin variants; adds `lmao`, `yes`…), `cldr` (slugified labels), 25+ locales | CLDR `tags` (e.g. 👍 → `+1, good, hand, like, thumb, up, yes`) | full `skins[]` | tracks Unicode releases |
| **iamcal/emoji-data** — https://github.com/iamcal/emoji-data | MIT (images separately licensed) | JSON w/ `short_names`, sheet coords | **Slack's actual shortcodes** (emojibase calls them `slack` preset, alias of `iamcal`) | none | yes | active |
| **muan/unicode-emoji-json**, **muan/emojilib** — https://github.com/muan/emojilib | MIT | emojilib = keyword lists per emoji (Mojibar uses 2.2.3) | none | decent | no | emojilib last push 2026-05 |
| **Emoogle Emoji Search Engine** — https://github.com/xitanggg/emoogle-emoji-search-engine | MIT | 5,400+ keywords for 1,872 emoji (Emoji 15.1), curated "most relevant emoji" per keyword, 10+ ranking rules | none | **best concept coverage** (CLDR + top-1000 words); Mojito merges it in (+~8,300 concept keywords incl. `deploy`→🚀, `ghosting`→👻) | no | last push 2024-11 |
| **Unicode CLDR annotations** | Unicode License V3 (permissive; keep copyright + notice; verified at https://www.unicode.org/license.txt) | `annotations.json` per locale: name + keywords | no | authoritative multilingual | — | tracks Unicode |

Findings:
- **Best quality/effort:** emojibase `en/data.json` (labels + CLDR tags + skins + group/order) **plus** shortcode presets `github` ∪ `iamcal` ∪ `emojibase` merged as aliases, **plus** Emoogle/emojilib keywords as extra tags. This is exactly Mojito's pipeline (`scripts/build_emoji_db.py` pins SHA-256 of upstream files, merges emojibase + Emoogle; Mojito README credits "emojibase, Emoogle, … a Swift port of fzy").
- gemoji alone is weaker (fewer emoji, thin tags, no skin data) but is the canonical Slack/GitHub *names*; emojibase's `github`/`iamcal` presets already contain them, so don't ship gemoji separately.
- Shortcode collisions across presets exist (emojibase docs "Caveats"); keep an ordered alias list, `primaryShortcode` = first, and show the **shortcode that matched** in the row (Mojito shows the primary shortcode for tag matches to avoid ten identical `:happy:` rows).
- Slack custom workspace emoji are images; can't be inserted as text (Comoji FAQ).
- Attribution: ship a `THIRD_PARTY_LICENSES` with MIT (emojibase, Emoogle/emojilib) and Unicode License V3 text.

---

## 5. Ranking

- **Tiered, not just fuzzy.** Mojito: `FzyScorer` (Swift port of John Hawthorn's fzy) over precomputed lowercased `[Character]` haystacks (shortcodes + labels + tags; ~24k haystacks; measured ~1.3 ms/keystroke on M-series), **prefix tier always first**, then score, then shortcode-over-tag, then canonical order. Tags only searched once the needle ≥ 2 chars (a 1-char needle matches everything). `relevanceFloor` = 0.60 per needle char (needle ≥ 3) so `:yeet:` doesn't return 🐞 via a scattered subsequence in "lady beetle"; floor is measured on the *un-bonused* score so aliases/frecency can't smuggle junk past it; permissive enough to keep typos (`roket` → 🚀 scores 0.78, `sml` → 😄 0.62). Alias bonus +6.0; **frecency boost `min(5.0, count × 0.2)`** added after the floor.
- **Inflection**: `QueryStemmer` (`:ghosted:`, `:launching:`, `:parties:`). Emoogle documents a 7-rule order: exact > prefix; curated "default most relevant" emoji per keyword; user-preferred; keyword in emoji *name*; single-word before phrase; common-word frequency (prefix only); recently searched (prefix only) — https://github.com/xitanggg/emoogle-emoji-search-engine .
- **Frecency**: Raycast orders "pinned, frecency, name match" (https://manual.raycast.com/emoji-symbols). Mojito stores `hexcode → count` in UserDefaults (no decay). Colon should store `(count, lastUsed)` and decay (e.g. half-life ~14–30 days) **[design suggestion]**; query-conditional counts (`"haha" → 😂 ×7`) beat global counts and double as personalized keywords (Raycast "save AI-generated custom keywords").
- **Empty/short query:** Mojito `:?` shows favorites/most-used pill; Rocket/Comoji show recents on a bare trigger.
- Fit with the Jev plan in ARCHITECTURE.md: local list renders synchronously (<1 ms), Jev rerank arrives ~150 ms later. Reorder must not fight the user's cursor (see UX spec §9.4).

---

## 6. Distribution of an unsigned open-source mac app

Facts (dated, with sources):
- **macOS 15 Sequoia removed Control-click → Open** as the Gatekeeper bypass. Flow now: double-click → warning (only *Done* / *Move to Trash*) → System Settings › Privacy & Security › "*was blocked*" → **Open Anyway** → authenticate. (https://www.macworld.com/article/2457844/what-to-do-when-you-cant-open-an-app-you-just-installed-in-macos-sequoia.html ; https://appleinsider.com/articles/24/08/06/apple-removes-control-click-option-for-skipping-gatekeeper-in-macos-sequoia ; Workbrew summary of Homebrew 5.0.0 https://workbrew.com/blog/homebrew-5-0-0.)
- Gatekeeper only evaluates files with the `com.apple.quarantine` xattr (set by browsers/AirDrop etc.). The manual bypass for users: `xattr -dr com.apple.quarantine /Applications/Colon.app`. Building from source locally (`swift build` + `scripts/build-app.sh`) never gets quarantined **[INFERENCE: standard behavior of local builds, not tested here]**.
- **Homebrew official cask no longer accepts unsigned/un-notarized apps:** Homebrew 5.0.0 (2025-11) deprecated them; "casks that fail Gatekeeper checks" were **disabled 2026-09-01** (users now see "Cask 'X' has been disabled because it does not pass the macOS Gatekeeper check"); `--no-quarantine` flag is also being deprecated. Sources: Workbrew blog above; https://github.com/ahrm/sioyek/issues/1666 ; https://github.com/sveinbjornt/Platypus/issues/299 **[SECONDARY for the disable-date confirmation]**. **A personal tap is still possible** (`brew install --cask <user>/tap/colon`, as Mojito does with `wr/tap`) but the cask will still hit Gatekeeper without notarization.
- **Notarization needs Apple Developer Program ($99/yr)**: Developer ID signing → `xcrun notarytool submit … --wait` → `xcrun stapler staple`. Mojito's `release.sh` does Developer ID sign → notarize → staple → Sparkle-sign DMG → `gh release` → appcast → Homebrew cask bump (CLAUDE.md). Notarized + stable Developer ID also *fixes TCC persistence across updates*.
- **Sparkle 2** works for unsigned/self-signed apps too: EdDSA (ed25519) signature on the update archive is the authenticity root (`generate_keys` → `SUPublicEDKey`; `generate_appcast`; `SUFeedURL`; `CFBundleVersion` must increase — Mojito lost a release cycle by confusing marketing vs build number). "Notarize and code sign … (if possible)". Library validation caveat: ad-hoc-signed dev builds can't load Sparkle unless library validation is disabled for Debug only (https://sparkle-project.org/documentation/). Sparkle's helper XPCs/Updater.app must be re-signed with your identity + hardened runtime for notarization (Mojito `release.sh` note). Distribute as a DMG with an `/Applications` symlink; if ZIP, put only the app in it (app-translocation).
- GitHub Releases + `SHA256SUMS.txt` (Swiftmoji's `package_dist.sh` pattern) for integrity; README must contain the Sequoia "Open Anyway" steps and the `xattr` one-liner for the unsigned path.

---

## 7. Pitfall checklist (condensed, each backed above)

1. Tap callback must never block (AX IPC, network, Jev). Cache AX; async everything. (§3.1, §3.3)
2. Handle `tapDisabledByTimeout/UserInput`; poll `tapIsEnabled`; reset state on re-enable. (§3.1)
3. Mark synthetic events (`eventSourceUserData`); don't use a boolean guard. (§3.1)
4. Query AX one tick *after* the key; verify focus unchanged before showing. (§3.3)
5. AX y-flip uses **primary** screen height; validate rect inside the focused element ±8 pt; element-top-left fallback only for fields ≤160 pt tall. (§3.3)
6. Electron/Chromium need `AXManualAccessibility` (and `AXEnhancedUserInterface` for Chromium browsers); tree appears asynchronously → retry/backoff. (§3.3)
7. Swallow Return/Tab only if a row exists; excluded/secure contexts swallow nothing. (§2.3, §3.6)
8. Insert: delete count = trigger+query chars actually in the field; closing-colon path needs a tick (or swallow the colon); ≥80 ms for slow fields; release held Shift; keep each Unicode event ≤20 UTF-16 units and never split a grapheme. (§3.4)
9. Empty-field case: Slack composer wipes next input; select-over instead of backspace. (§3.4)
10. Panel level `.popUpMenu`; `.nonactivatingPanel`; no `.canJoinAllSpaces` flash; dismiss on Space change/click-away/focus change. (§3.5)
11. Secure input stalls *all* taps; show state in menu bar. Password fields: subrole `AXSecureTextField`, fail closed. (§3.6)
12. Ad-hoc signing breaks TCC every build — use a stable cert; poll permissions and re-check on activation; don't move the app. (§3.7)
13. Colon false positives: require non-word char before trigger (`12:30`, `http://`, `foo:bar`), ignore emoticons below min-length, default-exclude terminals/IDEs (`:q`, `->`). (§2.3)

---

## 8. Recommendations for Colon

Decisions (✔ = consistent with `docs/ARCHITECTURE.md`; ✱ = proposes a change/addition):

**Input & plumbing**
- ✔ One active `.cgSessionEventTap` / `.headInsertEventTap` / `.defaultTap`, mask `keyDown | flagsChanged | mouseDown(L/R/other)`, installed on the **main run loop**; state machine is pure and synchronous; callback does no IPC.
- ✱ Add tap health: on `tapDisabledBy*` re-enable + reset + hide; 5 s timer verifies `CGEvent.tapIsEnabled`, reinstalls if stuck; re-verify ~1 s after launch (Raffel). Menu-bar status line reflects `running / permission missing / secure input active / paused`.
- ✔ Translate with `keyboardGetUnicodeString` (maxStringLength 4) — do not ship `UCKeyTranslate`; use virtual keycodes only for Esc/Return/KeypadEnter/Tab/Delete/ForwardDelete/arrows. ✱ Ignore events with ⌘/⌃/⌥ (treated as `.interrupt`), and stay silent if the current input source is not a keyboard layout (IME).
- ✔ Mark own events with `.eventSourceUserData` (choose a non-trivial constant) and drop them first thing in the callback.
- ✱ Never use `NSEvent(cgEvent:)` in the callback; read settings into plain struct fields updated on change.

**Caret**
- ✱ Implement `CaretLocator` with the six-step ladder (§3.3), `FocusedElementCache` with `AXObserver(kAXFocusedUIElementChanged)`, background seed queue, `AXUIElementSetMessagingTimeout(0.25)`, generation counters, retry backoff; set `AXManualAccessibility` only if the focused-element read is empty; never send `AXEnhancedUserInterface` to non-browsers.
- ✱ Anchor the panel to the **trigger character's** rect (range `(triggerLoc,1)`), computed once per capture and re-validated, not to the moving caret → no horizontal jitter while typing; re-anchor only on wrap/scroll detection **[design choice]**.
- ✔ Flip with `NSScreen.screens[0].frame.height`; pick the screen by anchor centre; clamp to `visibleFrame`; fall back element-top-left (≤160 pt) → mouse.

**Insertion**
- ✔ Default `.typing`: backspaces + one Unicode event (≤20 units; chunk on grapheme boundaries); `.paste` as per-app/failure fallback with *full* pasteboard save/restore (all items/types), restore ≥250 ms. ✱ Auto-fallback: if AX shows the element isn't editable → copy + toast.
- ✱ Add select-over (⇧← × N) when `kAXNumberOfCharactersAttribute ≤ deleteCount` (empty-field Slack/Electron composer issue).
- ✱ Release held Shift before injecting if `CGEventSource.keyState(.hidSystemState, key: 0x38)`.
- ✔ Closing `:` after an exact shortcode: swallow it (ARCHITECTURE choice) — simpler and avoids the 80 ms race; the `deleteCount` math in ARCHITECTURE.md is right. Keep Mojito's rule: if no exact match, leave `:name:` literal and let the colon through.
- ✱ Skin tone: pick the pre-composed string from emojibase `skins[]` (no scalar surgery); support the Slack suffix `:+1::skin-tone-3:`-style typed token as a bonus (Macmoji README).

**Panel**
- ✔ `NSPanel` `[.borderless, .nonactivatingPanel, .fullSizeContentView]`, `isFloatingPanel`, `level = .popUpMenu`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `canBecomeKey = false` in inline mode. ✱ `collectionBehavior = [.fullScreenAuxiliary, .transient]` (drop `.canJoinAllSpaces`, which ARCHITECTURE.md currently lists, to avoid the Space-swipe flash) and dismiss on `activeSpaceDidChangeNotification`; click-away via local+global mouse monitors.
- ✱ One reusable panel + `NSHostingView` bound to an observable model; `NSGlassEffectView` on 26+, `NSVisualEffectView` otherwise.

**Safety / privacy**
- ✔ Silent when: disabled, excluded bundle ID, `IsSecureEventInputEnabled()`, `AXSecureTextField` (role or subrole; **fail closed** until classified), Colon frontmost. ✱ Classification off-thread and cached per focused element.
- ✱ Default exclusions = Mojito's lists as *data* (bundle IDs): native-shortcode apps (Slack, Discord, Notion, Linear, Teams, Telegram, GitHub Desktop) and dev tools/terminals — ship **on by default with a first-run prompt**, plus allow-list mode and a "disable in this app" item in the menu-bar menu. Match on bundle ID. Per-site exclusions are v2 (needs `AXURL`).

**Data & ranking**
- ✔ Dataset: `emojibase-data` v17 `en/data.json` + shortcode presets `github` ∪ `iamcal` ∪ `emojibase` as ordered aliases + `emojilib`/Emoogle keywords as extra tags; pin upstream SHA-256 in `scripts/build-emoji-data.*` (Mojito pattern). Ship `THIRD_PARTY_LICENSES` (MIT + Unicode License V3). Don't ship gemoji separately.
- ✔ Local ranking tiers = exact shortcode > shortcode prefix > keyword exact > keyword prefix > word prefix > fuzzy; ✱ add a relevance floor for fuzzy (≈0.6/char for needles ≥3, checked before frecency/Jev blend), tags searched only for needle ≥2, stemming for `-ed/-ing/-s`.
- ✱ Frecency = `(count, lastUsed)` with exponential decay + per-query pick memory; boost capped (Mojito caps at +5.0 vs ~25 fzy points) so history can't beat a clear match.
- ✔ Jev rerank 0.7/0.3 blend, ~60 ms debounce. ✱ Freeze reordering once the user presses ↑/↓ (keep their highlighted emoji under the highlight); apply late Jev results only to rows below the highlight or on the next keystroke.

**Permissions & distribution**
- ✔ Onboarding: Accessibility prompt (`AXIsProcessTrustedWithOptions`) + Input Monitoring (`IOHIDRequestAccess`), probing with `AXIsProcessTrusted` / `IOHIDCheckAccess` only (never `tapCreate`), deep links to the two panes, live status via `com.apple.accessibility.api` + `didBecomeActive` + 2 s poll for app lifetime; tear down tap when AX is revoked.
- ✱ Dev signing: `scripts/setup-dev-signing.sh` creating a stable self-signed "Colon Dev" identity; `scripts/build-app.sh` signs with it (never `-`); dev build gets bundle ID `…Colon.dev`; README documents `tccutil reset Accessibility|ListenEvent <bundle id>`.
- ✱ Release: preferably Developer ID + notarize + staple (fixes Gatekeeper, TCC persistence, and Homebrew official cask eligibility). Without it: GitHub Releases DMG + `SHA256SUMS.txt`, README steps for Sequoia **Open Anyway** and `xattr -dr com.apple.quarantine`, personal tap (`brew install --cask <user>/tap/colon`) with the Gatekeeper caveat, Sparkle 2 with EdDSA for updates (stable self-signed cert still keeps TCC grants across updates).
- ✔ Never log or transmit typed text; Jev context (`textBeforeTrigger`) opt-in, read on demand via AX, never from secure fields.

---

## 9. UX spec — "as seamless as Rocket"

### 9.1 Trigger rules
- **Open** when `:` is typed and the previous character is not a letter/digit (start of field, whitespace, or punctuation other than query chars). `12:30`, `http://`, `foo:bar`, `ratio 3:1` never open. After backspace/arrow/focus-change, assume boundary.
- **Query chars:** letters, digits, `_`, `+`, `-` (so `:+1`, `:100`, `:8ball`, `:t-rex`). Max 32. Anything else ends the capture **and passes through** (text stays literal).
- **Show** when `query.count >= minQueryLength`. Default **2** (Mojito and FujiMoji both use 2; avoids flashing for `:D`, `:)`, `:P`, Vim `:w`; 1 for non-ASCII queries). Setting range 1–3. *(ARCHITECTURE.md says default 1 — recommend changing to 2.)*
- **Bare `:`** does nothing visible (optional later: recents strip after 300 ms idle).
- **Closing colon** after a complete shortcode (`:joy:`) inserts 😂 immediately without showing the picker, only if the shortcode is an exact alias; otherwise leave `:xyz:` untouched.
- **No result** → picker hidden (not an empty box); Enter/Tab pass through untouched.
- Never track outside an active `:query`; no key buffer.

### 9.2 Keys (only while the picker is visible)
| Key | Action |
| --- | --- |
| ↓ / ↑ | next / previous (wraps), swallowed |
| **Tab** or **Return/Enter** | insert highlighted, swallowed; **⇧Return/⇧Tab** = insert and keep typing a new query (optional, Mojito's "sticky") |
| Esc | close, keep typed `:query` text, swallowed |
| Backspace | edit query (passes through); below min length → hide; past the `:` → stop |
| Space / punctuation / ← / → | hide, key passes through |
| ⌘/⌃/⌥ combos, mouse click, app switch, Space switch, focus change | silent reset |
| Click a row | insert (panel is non-activating, so no focus change) |
| Number keys | **not** bound (digits are query characters); optional ⌘1–9 later |
| Skin tone | default tone setting applies; `⌥←/⌥→` on the highlighted row cycles tone for that insert **[proposal]**; typed `:+1::skin-tone-3:` supported |
Nothing is swallowed when the picker isn't visible, in excluded apps, or in secure fields.

### 9.3 Timing budget
- Key → state machine → decision: < 1 ms in the tap. Local search: < 1–2 ms (precomputed haystacks).
- First paint: next run-loop tick after the keystroke (so AX sees the moved caret); target ≤ 16 ms perceived.
- Caret lookup: cached element; AX bounds ≈ sub-ms for native fields; if AX isn't answered within ~30 ms, show at mouse/element anchor and *don't move later* unless the delta is large.
- Jev rerank: debounced 60 ms, timeout 1.5 s; never blocks UI.
- Insert: hide panel first (same tick), then deleteCount backspaces (no sleep; add 1–2 ms spacing only for per-app slow list), then one Unicode event; total < 20 ms; closing-colon-not-swallowed path adds ≥1 tick (80 ms for slow fields).

### 9.4 Ranking presentation
- Up to 6 rows × 30 pt (scroll beyond), 280 pt wide, 26 pt footer hints (`↑↓ select  ↵ insert  esc dismiss`). Row = glyph (22 pt) · `:shortcode:` (matched part bold) · faint name. Top row highlighted by default.
- Highlight tracks **emoji identity**, not index: when Jev reorders after the user has moved the highlight, the highlighted emoji stays highlighted and visible; if the user hasn't touched ↑/↓, the top row may animate into place (120 ms) once.
- Show the matched alias, not a repeated tag (no ten rows of `:happy:`).
- Local-first: the instant list is already good; Jev only improves ordering ("jevStatus" shown in the menu, not the picker).

### 9.5 Positioning
- Anchor = trigger-character rect (fallback: caret rect → field top-left if field ≤160 pt tall → mouse 1×16 rect).
- Below the anchor, left edge aligned to the `:`, 6 pt gap; flip above if `anchor.minY - height - gap < visibleFrame.minY`; clamp to `visibleFrame` with 8 pt side margin; choose screen by anchor centre; never overlap the caret line.
- Level `.popUpMenu`; visible over fullscreen apps; hidden on Space switch.
- Keep the window frame stable while the query grows (don't re-center on every keystroke); only height changes (top stays fixed when below, bottom stays fixed when flipped above).

### 9.6 Animation & visuals
- Appear: 140 ms, opacity 0→1 and scale 0.97→1 with 4 pt upward travel from the anchor, curve `cubic-bezier(0.22, 1, 0.36, 1)`. Dismiss: 80 ms fade, no scale. Keystroke refresh: **no** animation except height (100 ms ease-out) and one-time rerank slide.
- Selection moves instantly (no slide), fill 10–20% content color, corner radius ≈ 13–14 with concentric inner radius (`outer − inset`), system menu shadow, Liquid Glass on macOS 26+, `.hudWindow`/`.menu` material earlier; follow system appearance (not the target app's).
- Insert feedback: none by default (no sound); the emoji appearing in the text is the confirmation. Optional soft pop sound/haptic setting off by default.
- Reduce Motion → fade only.

### 9.7 Failure & edge behavior
- Permission missing / tap dead / secure input held → menu-bar icon shows a badge; menu line says why; picker never half-works.
- If focus changes during a capture (PID or `AXFocusedUIElement` differs) → cancel silently, hide.
- If insertion target isn't editable (read-only, non-text role) → copy to clipboard and show a 1.5 s "Copied 😂" toast.
- Secure fields, terminals, IDEs, apps with native `:` pickers → inactive by default; one-click "Disable in <App>" in the menu.
- Idle timeout: if no keystroke for 10 s while capturing → hide and reset (the pointer resting on the picker counts as activity).
- First-run: onboarding ends in a live text field so the user tries `:haha` immediately.

---

*Primary URLs index:* https://github.com/wr/mojito · https://github.com/amitskr/Swiftmoji · https://github.com/RickLiu1203/FujiMoji · https://github.com/warpling/Macmoji · https://github.com/Aeastr/CursorBounds · https://github.com/espanso/espanso (`espanso-detect/src/mac/native.mm`, `espanso-inject/src/mac/native.mm`) · https://matthewpalmer.net/rocket/ · https://manual.raycast.com/emoji-symbols · https://www.comoji.io/blog/slack-emoji-shortcuts-on-mac · https://textexpander.com/secure-input · https://developer.apple.com/library/archive/technotes/tn2150/_index.html · https://emojibase.dev/docs/shortcodes · https://github.com/github/gemoji · https://github.com/xitanggg/emoogle-emoji-search-engine · https://sparkle-project.org/documentation/ · https://workbrew.com/blog/homebrew-5-0-0 · https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/
