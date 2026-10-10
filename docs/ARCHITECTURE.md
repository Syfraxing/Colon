# Colon architecture

Open-source macOS menu-bar emoji picker. Type `:haha` anywhere → a glass picker appears at the caret → Enter/Tab inserts the emoji, replacing `:haha`. Ranking = instant local fuzzy search + frecency, then reranked by **Jev** (TypeSafe AI decision model) in ~150 ms.

- Swift 6 toolchain, Swift 5 language mode, SwiftPM only (no Xcode project). macOS 14+.
- `swift build`, `swift test`, `scripts/build-app.sh` → `build/Colon.app`.
- Dependencies: `KeyboardShortcuts` (sindresorhus) for the global "open picker" hotkey + recorder UI; `Sparkle` 2 for in-app updates (`App/Updater.swift`). Sparkle stays off unless the bundle is an .app outside `.build` with a real `SUPublicEDKey` (build-app.sh writes it from `SPARKLE_PUBLIC_KEY`); the feed must be EdDSA-signed (`SURequireSignedFeed`) and archives are verified before extraction (`SUVerifyUpdateBeforeExtraction`). Certificate-signed builds use the hardened runtime with only `disable-library-validation` (`Resources/Colon.entitlements`, for Sparkle.framework). Release CI (GitHub Environment `release`) signs with the stable "Colon Release Signing" certificate, refuses to move the feed backwards (`scripts/check-feed-forward.sh`) and publishes `appcast.xml` via `scripts/make-appcast.sh`.

## Layout & ownership

| Path | Owner | Contents |
| --- | --- | --- |
| `Package.swift`, `Sources/ColonCore/Model`, `Sources/ColonCore/Settings`, `Sources/Colon/App` | coordinator | shared types, settings, wiring. Workers MUST NOT change public signatures here; ask the coordinator. |
| `Sources/ColonCore/Data`, `Ranking`, `Jev`, `Resources`, `scripts/build-emoji-data.*`, `Tests/ColonCoreTests/*` (except Trigger) | core | dataset, search, frecency, Jev client, `SuggestionEngine` |
| `Sources/ColonCore/Input`, `Sources/Colon/Input`, `Tests/ColonCoreTests/TriggerEngineTests.swift` | input | event tap, `TriggerEngine`, caret, insertion, exclusions |
| `Sources/Colon/Picker` | picker | glass panel UI, inline + search modes |
| `Sources/Colon/Shell`, `Resources/AppIcon*` | shell | menu bar, settings window, onboarding, icon |
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
- Silent when: `!settings.isEnabled`, frontmost bundle ID excluded, `IsSecureEventInputEnabled()`, focused AX element is `AXSecureTextField`, or Colon itself is frontmost (settings window typing).
- Context for Jev (`PredictionContext`): app name + bundle ID always; `textBeforeTrigger` only if `settings.sendTextContext`, read ON DEMAND via AX from the focused element's value (bounded to the last 300 chars before the trigger), never from captured keystrokes, never from secure fields.
- Insertion default `.typing`: N backspaces then `keyboardSetUnicodeString` in ≤20 UTF-16 unit chunks; `.paste`: save pasteboard, set emoji, ⌘V, restore after ~250 ms.
- Caret: AX `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute`; fallbacks (Electron `AXManualAccessibility`, focused element frame, mouse location). Convert AX top-left coords to Cocoa bottom-left using the primary screen height.
- Never do AX IPC inside the tap callback: caret rect / context are fetched on the main queue after the callback returns (or from a focused-element cache kept by an `AXObserver`). Chromium browsers and Electron apps (bundle contains `Electron Framework.framework`) get `AXManualAccessibility` (+ `AXEnhancedUserInterface` for Chromium browsers) as soon as they activate, because building the tree takes seconds after a fresh launch; any other app gets `AXManualAccessibility` only when its focused-element read comes back empty. An empty read is re-probed for ~4 s while the capture lives (keys are not swallowed meanwhile). Unknown/failed secure-field check fails closed (stay silent).
- Poll tap health (`CGEvent.tapIsEnabled`) every few seconds and re-enable.
- Default `minQueryLength` is 2 (Slack-like).

### Ranking (SuggestionEngine)
- Local score: exact shortcode > shortcode prefix > keyword exact > keyword prefix > name word prefix > fuzzy subsequence; plus frecency boost.
- Jev request: one `choice` question. Candidates (≤ 255, practical target ~60–120): top local matches + frecent + a curated pool of the most commonly used emoji so semantic queries (`:haha`, `:yay`, `:sus`) still find good answers. Option keys = `Emoji.id`, criteria = `"<char> <name>; keywords"`.
- State: `{ "query": ..., "app": ..., "text_before": ... }`.
- Blend: when Jev answers, order by `0.7 * jevProbability + 0.3 * normalizedLocal` (tunable); keep exact shortcode matches pinned first only if Jev agrees within tolerance. Reorder animates in the UI. Once the user has moved the highlight (arrow keys) or pointed at a row with the mouse for the current query, freeze the order (the picker keeps the highlighted emoji selected even if a late Jev answer arrives; it may update probabilities but must not reorder under the user).
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

## Integration contract (binding; supersedes anything above)

Coordinator-owned additions already on main: `AppSettings.isValidTrigger(_:)` (1–3 ASCII punctuation/symbol chars, none of `[A-Za-z0-9_+-]`), expanded `defaultExcludedBundleIDs` (terminals, IDEs, password managers), `InputStatus` enum, `KeychainStore` with `SecItemUpdate` and DEBUG-only `JEV_API_KEY` override.

Show / hide / commit:
1. `picker.hide()` (programmatic) NEVER fires `onDismiss`. `onDismiss` fires only for dismissals the panel starts itself (click outside, Space change, Esc in search mode). `hide`, `engine.reset`, `input.cancelTracking` are idempotent; `cancelTracking` never calls `delegate.inputHide`.
2. Mouse picks: the tap must not turn a mouseDown inside the picker into `.interrupt`. `InputControllerDelegate` gains `func inputIsPointInPicker(_ point: CGPoint) -> Bool` (point in Cocoa screen coords; input flips the CG top-left location). Picker exposes `func contains(screenPoint: CGPoint) -> Bool`.
3. `TriggerEngine.handle(_ input: KeyInput, pickerVisible: Bool) -> TriggerResult`. The coordinator reports visible = `picker.isVisible && picker.selectedSuggestion != nil`. When not visible, Enter/Tab/↑/↓/Esc pass through (not swallowed). The picker hides itself (no panel) when the list is empty.
4. If a commit delegate call returns nil, InputController re-posts the swallowed key (marked with `eventSourceUserData`).
5. `inputShow` is called on every query change; repeat `picker.show(near:)` = update/resize only (no re-animation, anchored). The anchor rect is computed once per capture (trigger char) by InputController; the first `inputShow` may pass a cached/nil anchor and a follow-up `inputShow` with the same query passes the AX anchor + context.
6. `SuggestionEngine.update` with the same query and only a new context skips local recompute and just reschedules Jev.
7. Picker tracks selection by `Suggestion.id`; `selectedSuggestion` returns the highlighted one. After ↑/↓ the order freezes for that query.
8. Esc → hide + stop tracking. ←/→ → hide + reset. Backspace below minQueryLength → hide but keep tracking. Backspace past trigger → reset with boundary restored. IME (non keyboard-layout input source) → silent.
9. Threading: tap source on the main run loop, `.commonModes`, `MainActor.assumeIsolated`. Banned in the callback: AX IPC, Keychain, first `EmojiStore` load, window creation. Coordinator preloads `EmojiStore.shared` at launch.
10. `SuggestionEngine.reloadAPIKey()` reads the key off-main once (launch + after Settings saves). The engine never touches the Keychain per query. Jev only when `query.count >= 2`; never `text_before` unless opted in. `URLSessionConfiguration.ephemeral`. Never surface server error bodies verbatim.
11. Skin tones: never naively append; insert the modifier after the first scalar and drop VS16 (U+FE0F) when present; ZWJ sequences only if the dataset says the tone applies. Tests with 👋, ☝️, 🧑‍💻.
12. Search mode: panel stays `.nonactivatingPanel`, `canBecomeKey` only in search mode, `makeKeyAndOrderFront`, no `NSApp.activate`; target app stays frontmost. Input silence rule: `NSApp.isActive || NSApp.keyWindow != nil` (covers Settings + search panel). Hotkey while search open toggles it closed. While key the panel holds the keyboard, so `hide()` orders a key panel out at once (no fade): key focus is back in the target app synchronously, and the pick is typed straight after.
13. `InputController` is an `ObservableObject` with `@Published private(set) var status: InputStatus`; it polls `AXIsProcessTrusted` + `CGEvent.tapIsEnabled` every ~2 s and starts itself when permission appears (`start()` idempotent). `isEnabled == false` tears the tap down.
14. `StatusItemController` gains `var onOpenPicker: (() -> Void)?` and `func update(inputStatus: InputStatus)`; it shows "Paused — secure input", "Accessibility permission needed" (click opens onboarding via `onOpenSettings`), etc. Settings calls `engine.reloadAPIKey()` after saving a key: `SettingsWindowController.init(settings:engine:)`.
15. Onboarding probes with `AXIsProcessTrusted()` (and `IOHIDCheckAccess` for Input Monitoring), never with `tapCreate`.
16. Menu-bar icon: SF Symbol or drawn in code (executable target has no resources). App icon file: `Resources/AppIcon.icns`.
17. No `print`/`NSLog`/`debugPrint` of keys, queries, or headers in Input/Jev code. `os.Logger` with `.private` interpolation only.

## v0.4 feature contract (recents strip, multi-insert, feedback, compact layout, GIFs)

Coordinator-owned additions already on main: `AppSettings.showRecentsOnTrigger` (default on), `pickerLayout` (`.list`/`.compact`), `playsInsertSound` (default off), `hapticFeedback` (default on), `gifSearchEnabled` (default on); `KeychainStore.key(for:)`/`setKey(_:for:)` with `Account.gif`.

Ownership: **input** = `ColonCore/Input`, `ColonCore/Ranking` (recents), `Colon/Input`, TriggerEngine tests. **picker** = `Colon/Picker/**` (except GIF files), General settings rows for layout/sound/haptics/recents. **gif** = new `Colon/GIF/**`, `ColonCore/GIF/**`, `Colon/Shell/GIFSettingsView.swift` (+ adding its tab in SettingsView), tests for the GIF client. `App/AppCoordinator.swift` may be edited by all three but only additively (new methods/wiring); the coordinator resolves merges.

1. **Recents strip.** With `showRecentsOnTrigger`, typing the trigger at a word boundary immediately shows the picker with the user's most-used emoji (UsageStore frecency; fall back to `PopularEmoji` when there is no history), at most 8. TriggerEngine reports `.show(query: "")`; `SuggestionEngine.update(query: "")` returns recents (no Jev call). Space or any non-query char hides it and the char passes through (people type ":" for real). Enter/Tab/Esc are NOT swallowed while the query is empty unless the user has moved the selection with arrows (or ←/→ in compact) — so `Time:⏎` / `a :⏎` never inserts an emoji. Typing letters continues into a normal query.
2. **Multi-insert.** New `KeyInput.commandEnter` (⌘↩). While the picker is visible with a selection, ⌘↩ inserts the selected emoji and keeps the picker open: the first ⌘↩ deletes trigger+query like a normal commit; later ⌘↩ insert with deleteCount 0. After a ⌘↩, plain Enter/Tab insert one more and close, Esc closes, any other key closes and passes through. TriggerEngine action `.commitSelectionKeepOpen(deleteCount:)`.
3. **Feedback.** `Colon/Picker/Feedback.swift`: `Feedback.inserted(settings)` plays a soft custom click (bundled/synthesized, quiet; `playsInsertSound`), `Feedback.selectionChanged(settings)` does `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` (`hapticFeedback`). Coordinator calls `inserted` after every insert; picker calls `selectionChanged` on keyboard/hover selection changes.
4. **Compact layout.** `pickerLayout == .compact`: single horizontal row of emoji (no shortcodes; the selected emoji's `:shortcode:` shown as a caption), same glass. In compact mode ←/→ move the selection and are swallowed while the picker is visible (↑/↓ also move). `TriggerEngine` gets `var horizontalLayout: Bool`; input keeps it in sync with settings.
5. **GIFs.** Typing `<trigger>gif` followed by a space (e.g. `:gif `) when `gifSearchEnabled`: TriggerEngine action `.openGIFSearch(deleteCount:)` (deletes `:gif` + the space, swallow the space). Delegate `inputOpenGIFSearch(context: PredictionContext)` → coordinator → `GIFPickerController.show(context:target:)`: a key search panel (like emoji search mode: non-activating, `canBecomeKey`, never `NSApp.activate`) with a search field (focused) and an animated GIF grid, ↑↓←→ + ↩ to pick, Esc to cancel. Provider: BYO free API key (stored via `KeychainStore` `.gif`), chosen by the gif worker after checking current provider terms; results reranked by Jev (Choice over result ids with title/tags as criteria + context) when a Jev key exists. Picking inserts the GIF into the frontmost app via pasteboard (GIF data + file URL types) + ⌘V, restoring the previous pasteboard afterwards. No key → the panel explains how to get one and links Settings → GIFs.

### v0.4 amendments (binding, from the v0.4 review)
- GIF trigger deletes `<trigger>gif` only; the space is swallowed. It fires only when this capture's AX focus probe returned usable text (never into unknown/secure/non-text elements); otherwise the space passes through and nothing is deleted. Matching is case-insensitive.
- Printable keys typed right after `:gif ` (before the GIF panel is key) are swallowed by the input layer (max 64 chars / 500 ms) and handed to the GIF search field (`InputController` exposes them via the open call: `inputOpenGIFSearch(context:pendingText:)`). Never logged.
- Opening the GIF panel is always dispatched async from the tap callback (`DispatchQueue.main.async`), never inside it. The GIF controller is created in `AppCoordinator.start()`. Use the typed delegate path; the coordinator calls `gifPicker.show(context:pendingText:)` (no NotificationCenter).
- Empty (bare-trigger) strip: shown after ~100 ms with no further key (cancelled if another key arrives). Until engaged, Enter/Tab/Esc/⌘↩ and ↑/← (and ←/→ in list layout) are not swallowed; only ↓ (list) or → (compact) engage it, and the first engage highlights index 0. Recents only for a raw empty query (`""`), not queries that normalise to empty.
- ⇧/⌥/⌃-modified arrows are `.interrupt` (text selection and word jumps stay native). ⌘↩ is `.commandEnter` only with no other modifier.
- Keep-open insert: `inputCommitSelectionKeepOpen() -> String?` neither hides nor ends the capture; if it returns nil, swallow the ⌘↩ (never re-post it; it would send messages).
- `configureEngine` syncs `showsRecentsOnTrigger`, `horizontalLayout`, `gifSearchEnabled` and resets the capture when layout changes.
- GIF provider: **GIPHY** with a user-supplied free key. `rating` default `pg-13` (Settings picker g/pg/pg-13/r). "Powered by GIPHY" + logo always visible in the panel. Grid uses `fixed_width_small`, insert uses `downsized_medium`. No `random_id`, no analytics pingbacks. Debounce ≥350 ms, min 2 chars, 429 → friendly message. Ephemeral URLSession. No key → explainer and zero network requests. Never log queries.
- GIF pasteboard: one item with `public.file-url` → `~/Library/Caches/so.slayer.Colon/GIFs/giphy-<id>.gif` + `com.compuserve.gif` data + `org.nspasteboard.TransientType` + `org.nspasteboard.AutoGeneratedType`; no plain text. Temp files kept ≥24 h, pruned at launch. Insertion goes through an input-owned API `Inserter.paste(item: NSPasteboardItem, restoreAfter: TimeInterval)` that shares the existing save-once/changeCount restore state (GIFs restore after 1.5 s). GIFs always paste regardless of `insertionMethod`.
- Coordinator edits: each worker adds an `// MARK: v0.4 <worker>` block at the end of AppCoordinator and keeps edits inside existing methods to one line. `Feedback.inserted` is called by the coordinator in every insert path (Enter/Tab, keep-open, shortcode, mouse, search, GIF). Haptics only on real selection index changes. Hotkey search closes the GIF panel first; the GIF panel dismisses on Space change and target deactivation.
- PracticeField belongs to input (handles keep-open; GIF → none).
