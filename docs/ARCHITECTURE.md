# Emojify architecture

Open-source macOS menu-bar emoji picker. Type `:haha` anywhere → a glass picker appears at the caret → Enter/Tab inserts the emoji, replacing `:haha`. Ranking = instant local fuzzy search + frecency, then reranked by **Jev** (TypeSafe AI decision model) in ~150 ms.

- Swift 6 toolchain, Swift 5 language mode, SwiftPM only (no Xcode project). macOS 14+.
- `swift build`, `swift test`, `scripts/build-app.sh` → `build/Emojify.app`.
- Dependency: `KeyboardShortcuts` (sindresorhus) for the global "open picker" hotkey + recorder UI.

## Layout & ownership

| Path | Owner | Contents |
| --- | --- | --- |
| `Package.swift`, `Sources/EmojifyCore/Model`, `Sources/EmojifyCore/Settings`, `Sources/Emojify/App` | coordinator | shared types, settings, wiring. Workers MUST NOT change public signatures here; ask the coordinator. |
| `Sources/EmojifyCore/Data`, `Ranking`, `Jev`, `Resources`, `scripts/build-emoji-data.*`, `Tests/EmojifyCoreTests/*` (except Trigger) | core | dataset, search, frecency, Jev client, `SuggestionEngine` |
| `Sources/EmojifyCore/Input`, `Sources/Emojify/Input`, `Tests/EmojifyCoreTests/TriggerEngineTests.swift` | input | event tap, `TriggerEngine`, caret, insertion, exclusions |
| `Sources/Emojify/Picker` | picker | glass panel UI, inline + search modes |
| `Sources/Emojify/Shell`, `Resources/AppIcon*` | shell | menu bar, settings window, onboarding, icon |
| `scripts/` (except emoji data), `Resources/Info.plist`, `.github/`, `README.md`, `LICENSE`, `CONTRIBUTING.md` | packaging | .app bundle, signing, DMG, CI, docs |

Every scaffold body is marked `// SCAFFOLD`; the owner replaces all of them. No `SCAFFOLD` may remain at integration.

## Data flow

```
CGEventTap (InputController) ──KeyInput──▶ TriggerEngine ──Action──▶ InputController
   │ show(query) ─▶ AppCoordinator.inputShow ─▶ SuggestionEngine.update + PickerPanelController.show(near: caret)
   │ moveSelection ─▶ picker.moveSelection
   │ commitSelection(deleteCount) ─▶ coordinator.inputCommitSelection() → String ─▶ Inserter.replace(deleteCount, text)
SuggestionEngine: local EmojiSearch (sync, <1 ms) → publish → debounce ~60 ms → JevClient.rank → blend → publish
```

## Behaviour spec

### Trigger (TriggerEngine, pure + unit tested)
- Trigger string from settings (default `:`; may be multi-char like `::` or `;`).
- Trigger counts only at a word boundary: start of tracking, after whitespace, or after punctuation other than query chars. `http://x` and `12:30` must NOT trigger (the char before `:` is a letter/digit).
- **Privacy:** the engine must not keep a buffer of typed text. It keeps only a boolean "last char was a boundary", the in-progress trigger prefix, and the active query. Nothing typed outside an active `:query` is retained.
- Query chars: letters, digits, `_`, `+`, `-`. Max 32 chars.
- Picker shows once `query.count >= minQueryLength` (default 1). Backspace edits the query; backspacing past the trigger stops tracking.
- While showing, swallow: ↑ ↓ (and ← → move selection only in a horizontal layout? NO — keep ←/→ passing through and hide the picker), Tab, Enter, Esc. Esc hides and keeps the typed text. Enter/Tab → `commitSelection(deleteCount: trigger.count + query.count)`.
- Whitespace or any non-query char → hide (text stays).
- Closing trigger after an exact shortcode (`:joy:`) with autoReplace on → `commitShortcode("joy", deleteCount: trigger.count*2 + query.count - 1)` — the final `:` is swallowed so it is never typed, so deleteCount covers only what reached the app: opening trigger + query.
- `.interrupt` (⌘/⌃ combos, clicks, app switch, focus change) → reset silently.
- Not tracking → never swallow anything.

### Input layer (InputController)
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown | flagsChanged | left/right mouseDown)`; re-enable on `tapDisabledByTimeout/UserInput`. Callback must be fast; never block on network.
- Translate keys with the event's unicode string (`keyboardGetUnicodeString`), honour current layout.
- Ignore events we synthesize ourselves (mark them with `eventSourceUserData`).
- Silent when: `!settings.isEnabled`, frontmost bundle ID excluded, `IsSecureEventInputEnabled()`, focused AX element is `AXSecureTextField`, or Emojify itself is frontmost (settings window typing).
- Context for Jev (`PredictionContext`): app name + bundle ID always; `textBeforeTrigger` only if `settings.sendTextContext`, read ON DEMAND via AX from the focused element's value (bounded to the last 300 chars before the trigger), never from captured keystrokes, never from secure fields.
- Insertion default `.typing`: N backspaces then `keyboardSetUnicodeString` in ≤20 UTF-16 unit chunks; `.paste`: save pasteboard, set emoji, ⌘V, restore after ~250 ms.
- Caret: AX `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute`; fallbacks (Electron `AXManualAccessibility`, focused element frame, mouse location). Convert AX top-left coords to Cocoa bottom-left using the primary screen height.
- Never do AX IPC inside the tap callback: caret rect / context are fetched on the main queue after the callback returns (or from a focused-element cache kept by an `AXObserver`). Set `AXManualAccessibility` only when the focused-element read comes back empty (Electron). Unknown/failed secure-field check fails closed (stay silent).
- Poll tap health (`CGEvent.tapIsEnabled`) every few seconds and re-enable.
- Default `minQueryLength` is 2 (Slack-like).

### Ranking (SuggestionEngine)
- Local score: exact shortcode > shortcode prefix > keyword exact > keyword prefix > name word prefix > fuzzy subsequence; plus frecency boost.
- Jev request: one `choice` question. Candidates (≤ 255, practical target ~60–120): top local matches + frecent + a curated pool of the most commonly used emoji so semantic queries (`:haha`, `:yay`, `:sus`) still find good answers. Option keys = `Emoji.id`, criteria = `"<char> <name>; keywords"`.
- State: `{ "query": ..., "app": ..., "text_before": ... }`.
- Blend: when Jev answers, order by `0.7 * jevProbability + 0.3 * normalizedLocal` (tunable); keep exact shortcode matches pinned first only if Jev agrees within tolerance. Reorder animates in the UI. Once the user has moved the highlight (arrow keys) for the current query, freeze the order (the picker keeps the highlighted emoji selected even if a late Jev answer arrives; it may update probabilities but must not reorder under the user).
- Debounce ~60 ms, cancel stale tasks, LRU cache by (query, app). Timeouts 1.5 s. On error, keep local results and set `jevStatus`.
- No key or `useJev == false` → local only, still great.

### Picker UI
- Non-activating `NSPanel` (`.nonactivatingPanel`, `.borderless`, `level = .popUpMenu`, `collectionBehavior = [.fullScreenAuxiliary, .transient]` — no `.canJoinAllSpaces`, it flashes on Space swipes; dismiss on `NSWorkspace.activeSpaceDidChangeNotification`), `hidesOnDeactivate = false`, never becomes key in inline mode.
- Glass: monocode-inspired. Neutral grey hsl(240 0% 9%) at ~40% over `NSVisualEffectView` `.hudWindow`/behind-window blur (Liquid Glass `NSGlassEffectView` on macOS 26+), 1px stroke = content 7%, selection fill = content 10–20%, accent `hsl(211 92% 62%)`, text hsl(240 0% 92%). Corner radius ~14. Ease `cubic-bezier(0.22, 1, 0.36, 1)`, 120–200 ms. Light mode: background 97%, content 18%.
- Shows below the caret (above if no room), clamped to the screen's visibleFrame. Anchor x to where the picker first opened (the trigger character) and keep it fixed while the query grows.

### Shell
- Menu bar item (template icon), menu: Enabled toggle, Open Picker (shows shortcut), Jev status line, Settings…, Quit.
- Settings tabs: General (enable, trigger string, min chars, results count, skin tone, insertion method, auto replace, launch at login via `SMAppService.mainApp`), Jev (secure key field → `KeychainStore`, test button via `JevClient.ping`, use Jev toggle, send context toggle with privacy note), Shortcuts (`KeyboardShortcuts.Recorder` for `.openPicker`), Excluded Apps (list with icons, add from running apps or `NSOpenPanel` on /Applications, remove, restore defaults), About.
- Onboarding on first run / missing Accessibility: explains + button opening System Settings (`AXIsProcessTrustedWithOptions` prompt), polls until granted then calls `onAccessibilityGranted`, then optional Jev key step.

## Secrets
- The Jev key lives only in the Keychain (`KeychainStore`), or `JEV_API_KEY` env for development/tests. Never log it, never commit it, never write it to UserDefaults.
