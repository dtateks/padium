# Blueprint: Padium Trackpad MVP

**Objective:** Build a private macOS menubar app mapping trackpad gestures → keyboard shortcuts. 12-slot MVP (3/4-finger × tap 1x/2x + swipe 4-dir). Share binary to ~5 friends.

**Repo:** https://github.com/dtateks/padium (private)
**Stack:** Swift 6 + SwiftUI `MenuBarExtra`
**Dependencies (2 only, per search-first):**
- `OpenMultitouchSupport` v3.0.3+ (Kyome22, MIT) — gesture capture
- `KeyboardShortcuts` (sindresorhus, MIT) — ships `Recorder` SwiftUI view, saves ~40% of Step 9
**Reference (study, don't fork):** https://github.com/NullPointerDepressiveDisorder/MiddleDrag — same CGEventTap preemption pattern
**Min macOS:** 14 Sonoma
**Target metrics:** <20MB RAM idle, <50ms p95 latency, <2MB binary
**Timeline:** 2 weeks calendar (Phase 0 = 2 days, Phases 1-8 = ~8-10 working days)

**Context files (read before executing any step):**
- `PRODUCT-BRIEF.md` — product diagnosis, go/no-go rationale
- `.claude/PRPs/prds/padium-trackpad.prd.md` — PRD with council decisions

---

## Dependency Graph

```
         ┌──────────────────────────────┐
         │ Step 1: Scaffold Xcode proj  │
         └──────────────────────────────┘
           │          │        │       │
       ┌───▼──┐   ┌───▼──┐ ┌──▼──┐ ┌──▼──┐
       │ 2:0a │   │ 4:0c │ │ 6:  │ │ 7:  │ │ 8:  │
       │ OMS  │   │preempt│ │short│ │cfg  │ │menu │
       └───┬──┘   └───┬──┘ │cut  │ │store│ │bar  │
           │          │    └──┬──┘ └──┬──┘ └──┬──┘
       ┌───▼──┐       │       │       │       │
       │ 3:0b │       │       │       │   ┌───▼────┐
       │state │       │       │       │   │ 10:    │
       │machin│       │       │       │   │ perm   │
       └──┬───┘       │       │       │   │onboard │
          │           │       │       │   └───┬────┘
          │           │       │     ┌─▼──┐    │
          │           │       │     │ 9: │    │
          │           │       │     │UI  │    │
          │           │       │     └─┬──┘    │
          └──────┬────┘       │       │       │
                 │            │       │       │
            ┌────▼──────┐     │       │       │
            │ 5: Engine │     │       │       │
            └────┬──────┘     │       │       │
                 │            │       │       │
                 └────────────┴───┬───┴───────┘
                                  │
                           ┌──────▼──────┐
                           │ 11: Wire+E2E│
                           └──────┬──────┘
                                  │
                           ┌──────▼──────┐
                           │ 12: Package │
                           └─────────────┘
```

**Parallelism opportunities:**
- After Step 1: **4 parallel tracks** — {2→3}, {4}, {6}, {7, 8}
- After Step 4 (preemption gate): Step 5 unblocked
- After Step 7+8: Step 9 and Step 10 can run in parallel
- Step 11 is integration gate — all previous must land

---

## Global Workflow

- **Branching:** `feat/step-N-<slug>` per step
- **PR size:** one PR per step, reviewed by owner (self-review)
- **CI:** none for v1 — manual verification via Xcode build + launch
- **Merge:** squash to main with commit message matching step name
- **Rollback:** `git revert <commit>` or drop branch; no prod infra to worry about

---

## Step 1: Scaffold Xcode project

**Goal:** Working empty MenuBarExtra app builds và launches, shows a placeholder menu bar icon.

**Cold-start brief:** Repo hiện chỉ có PRD markdown, chưa có Xcode project. Tạo skeleton theo stack đã định: Swift 6, macOS 14, SwiftUI `MenuBarExtra`, `LSUIElement=YES` (no dock icon).

**Tasks:**
1. `cd /Users/dta.teks/dev/padium`
2. Tạo Xcode project: File → New → macOS → App, name=`Padium`, Interface=SwiftUI, Language=Swift, Include Tests=YES, min deployment=14.0
3. Edit `Info.plist`: set `LSUIElement` = `YES` (hoặc `Application is agent (UIElement)` = YES)
4. Edit `PadiumApp.swift` → replace `WindowGroup` với `MenuBarExtra("Padium", systemImage: "hand.tap") { Text("Padium v0.0.1") }`
5. Swift 6 concurrency: set `Swift Language Version = 6.0` in build settings; set `Strict Concurrency Checking = Complete`
6. Set minimum deployment target: 14.0
7. App Sandbox: **disabled** (council decision — private API needs this)
8. Hardened Runtime: enabled, add `com.apple.security.cs.allow-unsigned-executable-memory` = NO, keep default (we'll revisit when signing)
9. Add `README.md` stub với project description + dev setup
10. Commit: `feat: scaffold Padium Xcode project`

**Verification:**
- `xcodebuild -project Padium.xcodeproj -scheme Padium build` succeeds
- Launch app → menu bar icon appears, no dock icon, click shows "Padium v0.0.1"
- Quit cleanly

**Exit criteria:** Builds clean, launches, menu bar only. Pushed to `feat/step-1-scaffold`.

**Model tier:** default — mechanical scaffolding
**Estimated time:** 1h

---

## Step 2: Phase 0a — OMS feasibility spike (2h)

**Goal:** Confirm `OpenMultitouchSupport` wrapper detects 3/4-finger tap globally on current macOS.

**Cold-start brief:** Council đã reject NSEvent fallback (không cover finger count on tap). Trước khi architect cả gesture engine, spike để confirm OMS work trên máy owner.

**Tasks:**
1. Branch `spike/phase-0a-oms`
2. `File → Add Package Dependencies` → `https://github.com/Kyome22/OpenMultitouchSupport` → version 3.0.3+ → add to Padium target
3. Trong `PadiumApp.swift` hoặc `OMSSpikeView.swift` — subscribe OMS event stream, print raw events với finger count và phase
4. Build + run → trackpad 3-finger tap, 4-finger tap, 2-finger tap (control). Observe console output.
5. Ghi lại vào `plans/spike-notes/0a-oms.md`:
   - OMS hoạt động? y/n
   - Finger count chính xác? (3,4 distinguishable?)
   - Event latency cảm thấy có chấp nhận được không?
   - Gotcha gì gặp phải?

**Verification:**
- Console log: `3 fingers detected at (x, y)` khi 3-finger tap
- 4-finger tap phân biệt được với 3
- 2-finger tap (system scroll) không bị intercept sai

**Exit criteria:** Notes file written; OMS confirmed working. **If fails → STOP và council lại (không có fallback plan).**

**Model tier:** default
**Estimated time:** 2h

---

## Step 3: Phase 0b — State machine inspection (4h)

**Goal:** Hiểu OMS raw event stream đủ để design gesture classifier (tap vs swipe-start, 1x vs 2x tap, palm rejection).

**Cold-start brief:** Skeptic flag: state machine là hard problem, không phải API choice. Trước khi code classifier, phải observe data thực tế.

**Tasks:**
1. Branch `spike/phase-0b-state-machine`
2. Extend Step 2's spike → log full event sequence với timestamps: `t=0ms: 3-fingers-down, t=120ms: 3-fingers-up, t=150ms: tap-ended`
3. Thực hiện các gestures và ghi log:
   - 3-finger single tap (5 lần)
   - 3-finger double tap (5 lần, varying speed)
   - 3-finger swipe up/down/left/right
   - 3-finger "slow tap" (hesitant)
   - Palm resting + 3-finger tap
   - 4-finger variants same
4. Analyze logs → determine thresholds:
   - Tap duration: max ms finger-down để count as tap (vs hold)
   - Swipe movement: min px để tính swipe vs tap
   - Double-tap window: max ms giữa 2 taps
   - Palm rejection: nếu có >4 fingers hoặc finger size/pressure signal
5. Viết pseudo-code state machine vào `plans/spike-notes/0b-state-machine.md`:
   ```
   states: idle, fingers-down, tap-ended, swipe-detected, double-tap-pending
   transitions: (events with thresholds)
   ```

**Verification:** State machine pseudo-code cover được 5/5 gesture types đúng trên test data.

**Exit criteria:** `0b-state-machine.md` committed với thresholds + pseudo-code.

**Model tier:** **strongest** — design decision impacts Step 5 correctness
**Estimated time:** 4h

---

## Step 4: Phase 0c — CGEventTap preemption spike (8h, GATE)

**Goal:** Determine if `CGEventTap` có thể suppress macOS native 3-finger Mission Control / 4-finger Spaces trước khi trigger.

**Cold-start brief:** Critic flag: hard problem riêng, không phải OMS. Nếu không suppress được → MVP scope phải re-scope (drop 3-finger swipes hoặc require user tắt System Settings). **Reference implementation:** https://github.com/NullPointerDepressiveDisorder/MiddleDrag — đọc `MultiFingerGestureDetector.swift` + event tap setup trước khi code.

**Tasks:**
1. Branch `spike/phase-0c-preemption`
2. **Read MiddleDrag source first** (30 min) — note approach + any gotchas they documented
3. Set up `CGEventTap` ở `.cghidEventTap` level với mask bao gồm gesture events
3. Experiment — khi nhận được gesture event (3-finger swipe up):
   - Approach A: return `NULL` từ tap callback (attempt suppress)
   - Approach B: return event nhưng modify phase
   - Approach C: race với WindowServer bằng cách tap high priority
4. Test: 3-finger swipe up → Padium fire event NHƯNG Mission Control không mở
5. Nếu fail all → document fallback: README yêu cầu user vào System Settings → Trackpad → More Gestures → set 3/4-finger = "Off"
6. Viết vào `plans/spike-notes/0c-preemption.md`:
   - Approach nào work (nếu có)
   - Side effects (latency, stability)
   - Fallback decision

**Verification:**
- Gesture type nào preempt được, gesture type nào phải fallback manual disable
- Owner xác nhận cách fallback chấp nhận được

**Exit criteria (GATE):**
- **Pass:** preemption works hoặc fallback UX acceptable → proceed Step 5
- **Fail:** không preempt + owner reject fallback → **STOP**, council lại, có thể drop 3-finger swipes khỏi MVP (giảm 4/12 slots)

**Model tier:** **strongest** — architectural gate
**Estimated time:** 8h

---

## Step 5: Gesture engine module

**Goal:** Module `GestureEngine` emit 12 gesture types qua clean delegate API.

**Cold-start brief:** Dựa trên state machine từ Step 3 + preemption strategy từ Step 4, build gesture engine module. Abstract sau `protocol GestureSource` để swap được.

**Tasks:**
1. Branch `feat/step-5-gesture-engine`
2. Tạo `Sources/GestureEngine/`:
   - `GestureSource.swift` — protocol với `var events: AsyncStream<RawTouchEvent>`
   - `OMSGestureSource.swift` — wrap OpenMultitouchSupport implementing protocol
   - `GestureClassifier.swift` — state machine từ Step 3, emit `GestureEvent`
   - `GestureEvent.swift` — enum: `tap1(fingers:3|4)`, `tap2(fingers:3|4)`, `swipe(fingers:3|4, dir:up|down|left|right)`
3. Integrate preemption từ Step 4 (CGEventTap or document-only)
4. Unit tests cho classifier: feed mock raw events, assert correct GestureEvent emitted
5. Integration test: actual trackpad → event stream → console prints 12 gesture types

**Verification:**
- `swift test` passes
- Manual: all 12 gesture types fire đúng event
- No false positives on normal scroll/click

**Exit criteria:** Module isolated, tested, integration-ready. Merged to main.

**Model tier:** **strongest** — core product logic
**Estimated time:** 12h

---

## Step 6: Shortcut emitter module

**Goal:** Module `ShortcutEmitter` nhận `(keyCode, modifiers)` và post event tới foreground app qua CGEvent.

**Cold-start brief:** Output side của pipeline. Independent from gesture side, có thể parallel với Step 5/7.

**Tasks:**
1. Branch `feat/step-6-shortcut-emitter`
2. Tạo `Sources/ShortcutEmitter/`:
   - `Shortcut.swift` — struct `{keyCode: CGKeyCode, modifiers: CGEventFlags}`
   - `ShortcutEmitter.swift` — func `emit(_ shortcut: Shortcut)` → post CGEvent keyDown + keyUp
3. Handle modifier flags đúng: ⌘⇧⌃⌥ combinations
4. Test matrix: manual verify trong Xcode, Chrome, Safari, Raycast, Notes — emit `⌘⇧T`, `⌘Space`, `⌃↑`
5. Unit test: mock CGEventPost, assert keyCode + flags correct
6. Edge case: sandboxed app targets (test với Safari) — if fails, document limitation

**Verification:**
- 5/5 apps respond to emitted shortcut
- No modifier "sticky" state sau emit
- Latency < 10ms (not noticeable)

**Exit criteria:** Module tested, 5 apps verified. Merged.

**Model tier:** default — well-trodden pattern
**Estimated time:** 6h

---

## Step 7: Config store

**Goal:** Export/import config JSON ở `~/.padium/config.json` — KeyboardShortcuts quản primary binding state trong UserDefaults.

**Cold-start brief:** Split responsibility: `KeyboardShortcuts` lib quản runtime bindings (UserDefaults-backed). JSON file là export/import path cho sharing giữa friends. Persistence layer simpler hơn plan cũ.

**Tasks:**
1. Branch `feat/step-7-config-store`
2. Tạo `Sources/Config/`:
   - `GestureSlot.swift` — enum matching 12 MVP slots, map tới `KeyboardShortcuts.Name`
   - `ConfigExporter.swift` — read all 12 `KeyboardShortcuts.getShortcut(for:)` → serialize Codable → atomic write to `~/.padium/config.json`
   - `ConfigImporter.swift` — read JSON → `KeyboardShortcuts.setShortcut(_, for:)` for each slot
3. Path: `~/.padium/config.json` (create dir if missing)
4. Unit tests: round-trip (export → import → export), atomic write semantics

**Verification:**
- Edit JSON trực tiếp → restart app → config giữ nguyên
- Corrupt JSON → app falls back to default (không crash)
- `ls ~/.padium/` shows file

**Exit criteria:** Module tested, config persists. Merged.

**Model tier:** default
**Estimated time:** 4h

---

## Step 8: Menu bar shell

**Goal:** `MenuBarExtra` với icon, toggle on/off, quit, launch-at-login.

**Cold-start brief:** UI shell. Independent — parallel với Step 5/6/7.

**Tasks:**
1. Branch `feat/step-8-menu-bar-shell`
2. Build menu trong `PadiumApp.swift`:
   - Icon: `hand.tap` (or custom)
   - "Enabled" toggle (global on/off state)
   - "Open Settings…" → opens matrix config window (placeholder for Step 9)
   - Divider
   - "Launch at Login" toggle → `SMAppService.mainApp.register()/unregister()`
   - "Quit Padium" → `NSApp.terminate(nil)`
3. Global state via `@Observable` class `AppState`
4. Edge case: first launch → default to enabled=true, launch-at-login=false

**Verification:**
- Click icon → menu shows
- Toggle enabled → gesture processing stops/starts
- Launch-at-login toggle persists across reboots
- Quit clean

**Exit criteria:** Shell functional, state persists. Merged.

**Model tier:** default
**Estimated time:** 4h

---

## Step 9: Matrix config UI

**Goal:** SwiftUI 2×6 grid, mỗi cell dùng `KeyboardShortcuts.Recorder`.

**Cold-start brief:** Owner chọn minimalist UI. Single window, matrix layout. **ADOPT `sindresorhus/KeyboardShortcuts`** — ships `Recorder` view drop-in (per search-first). Depends on Step 7 (config) + Step 8 (window presenter).

**Tasks:**
1. Branch `feat/step-9-matrix-ui`
2. Add SPM dep `KeyboardShortcuts` nếu chưa add
3. Define 12 `KeyboardShortcuts.Name` static properties (one per gesture slot). `KeyboardShortcuts` tự quản persistence trong UserDefaults — **conflict với Step 7 JSON config** → decision: dùng KeyboardShortcuts cho mapping persistence, `~/.padium/config.json` chỉ để export/import (human-editable view). Revisit nếu approach này không fit.
4. Tạo `Sources/UI/MatrixConfigView.swift`:
   - Grid 2 rows (3-finger, 4-finger) × 6 cols (tap1x, tap2x, swipe↑↓←→)
   - Mỗi cell: `KeyboardShortcuts.Recorder("", name: .slot3FingerTap1)`
5. "Export JSON" button → serialize all 12 bindings to `~/.padium/config.json`
6. Window: fixed size ~600×300, resizable off, close button only
7. Light/dark mode support (free from SwiftUI)

**Verification:**
- Gán 1 slot qua UI → config.json updated → restart → setting giữ nguyên
- All 12 cells work
- Visually clean on retina + non-retina

**Exit criteria:** UI functional, config round-trip verified. Merged.

**Model tier:** default — SwiftUI is ergonomic
**Estimated time:** 10h

---

## Step 10: Permission onboarding flow

**Goal:** First-launch flow grants Accessibility + Input Monitoring permissions cleanly.

**Cold-start brief:** Critical UX. Without permission, nothing works. Depends on Step 8 (shell presents onboarding).

**Tasks:**
1. Branch `feat/step-10-onboarding`
2. Tạo `Sources/UI/OnboardingView.swift`:
   - Step 1: Welcome + explain "why permissions"
   - Step 2: "Grant Accessibility" button → open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
   - Step 3: Poll `AXIsProcessTrustedWithOptions` every 1s until granted
   - Step 4: Same for Input Monitoring (`IOHIDCheckAccess`)
   - Step 5: Done, close onboarding, open matrix UI
3. Detect first launch → show onboarding; subsequent launches → skip if granted
4. "Skip for now" option (but warn: app won't work)
5. Handle edge: user revokes permission later → re-trigger onboarding

**Verification:**
- New user (clean macOS account) → 30s onboarding
- Permission revoke → app detects + prompts

**Exit criteria:** Onboarding smooth, 1 bạn thử (or clean user account test). Merged.

**Model tier:** default
**Estimated time:** 6h

---

## Step 11: Wire-up + E2E QA

**Goal:** Tất cả module integrated, 12 slots hoạt động end-to-end, owner dogfoods 1 day.

**Cold-start brief:** Integration gate. All previous modules merged; wire them in `PadiumApp` với dependency injection.

**Tasks:**
1. Branch `feat/step-11-wireup`
2. Trong `PadiumApp`, construct và connect:
   - `ConfigStore` (singleton or @Environment)
   - `GestureEngine` subscribed to OMS
   - `ShortcutEmitter` listens to engine events, looks up shortcut in config, emits
   - `AppState.isEnabled` gates the engine→emitter bridge
3. Full manual QA matrix:
   - 12 gesture slots × 5 apps = 60 cases
   - Toggle on/off works
   - Config UI changes reflect immediately
   - Quit → relaunch → same behavior
4. Owner dogfoods **1 full working day** — log any crash, lag, false trigger, missed gesture
5. Fix P0 bugs before merging; defer P1/P2 to post-ship

**Verification:**
- 60/60 QA cases pass
- Zero crashes in 1-day dogfood
- RAM < 20MB (Activity Monitor)
- Gesture latency p95 < 50ms (measure với `signpost` instrument, sample 100 events)

**Exit criteria:** All metrics met, 1-day dogfood clean. Merged to main.

**Model tier:** default (integration), **strongest** for any bug root-causing
**Estimated time:** 8h + 1 day dogfood (async)

---

## Step 12: Package + share

**Goal:** Binary shareable to friends with minimal friction.

**Cold-start brief:** Last mile. Ad-hoc signing (no paid Apple Developer account), .dmg distribution, README for friends.

**Tasks:**
1. Branch `feat/step-12-package`
2. App icon — simple 1024x1024 SVG → ICNS (use `iconutil`)
3. Build release: `xcodebuild -scheme Padium -configuration Release -derivedDataPath ./build`
4. Ad-hoc sign: `codesign --force --deep --sign - ./build/Build/Products/Release/Padium.app`
5. Create `.dmg`: `hdiutil create -volname Padium -srcfolder ./build/.../Padium.app -ov -format UDZO Padium-v0.1.0.dmg`
6. Write `README.md` (expanded):
   - What it is, screenshot of matrix UI
   - Install: download `.dmg`, drag to Applications
   - **Gatekeeper workaround**: System Settings → Privacy & Security → "Open Anyway"
   - Permission steps with screenshot
   - Uninstall: delete `.app` + `rm -rf ~/.padium` + revoke Accessibility
7. Create git tag `v0.1.0`, GitHub release, attach `.dmg`
8. Share link to 3-5 bạn bè, collect feedback

**Verification:**
- 1 bạn cài thành công không cần owner support
- Binary size < 2MB (acceptable up to 5MB nếu OMS wrapper nặng)

**Exit criteria:** v0.1.0 released, 1 external install verified. Merged.

**Model tier:** default
**Estimated time:** 4h

---

## Invariants (check sau mỗi step)

- [ ] `xcodebuild ... build` succeeds
- [ ] Menu bar icon xuất hiện, no dock icon
- [ ] Không có new warnings (Swift 6 strict concurrency)
- [ ] RAM idle < 20MB (measure after Step 11)
- [ ] App Sandbox disabled (private API requires)
- [ ] `~/.padium/config.json` created on first launch (from Step 7 onward)

---

## Risk Register (live)

| Risk | Phase | Mitigation |
|---|---|---|
| OMS fails on owner's macOS | Step 2 | Spike first; if fail → STOP |
| State machine misclassifies | Step 3, 5 | Empirical thresholds from Step 3 data |
| Preemption impossible | Step 4 | Fallback to manual System Settings disable |
| macOS 27 break during Step 5-11 | any | Pin OMS, abstract behind protocol |
| Gatekeeper blocks friends' install | Step 12 | README workaround doc |
| Owner scope creeps | any | Anti-goals in PRODUCT-BRIEF.md are load-bearing |

---

## Mutation Protocol

- **Split:** if a step exceeds estimated time by 2x, split into N sub-steps with new IDs
- **Insert:** new step inherits dependencies of the step it's inserted before
- **Skip:** document rationale in `plans/skipped.md`, re-run dependency check
- **Abandon:** mark plan `abandoned`, archive to `plans/archive/`

---

*Generated: 2026-04-13 (via /ecc:blueprint)*
*Status: READY — Step 1 unblocked*
