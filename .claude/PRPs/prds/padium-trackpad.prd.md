# Padium Trackpad

## Problem Statement

Power macOS users muốn gán gesture trackpad → keyboard shortcut mà không phải học BetterTouchTool (BTT). BTT có 100+ options quá phức tạp cho use case đơn giản, chiếm ~120-150MB RAM, và tốn $22. Người mới chỉ muốn "3-finger swipe up → ⌘⇧T" thì phải đào qua 20 menu và mở ví.

## Evidence

- BTT pricing page: $22 standard / $45 lifetime (barrier cho casual user)
- Hoạt động quan sát: BTT idle RAM ~120MB trên M-series Mac
- Multitouch.app ($5) thành công trên App Store chính vì "simpler than BTT"
- User (owner) đã thử BTT và thấy overwhelming — đây là assumption cần thêm 3-5 bạn bè validate

## Proposed Solution

Native Swift menubar app, chỉ làm **1 việc**: gán gesture trackpad → phát keyboard shortcut. UI minimalist 1-màn-hình (matrix picker). Không per-app, không script, không window management. Target < 20MB RAM, < 50ms latency, <2MB binary. Free + private repo, share binary cho bạn bè qua Dropbox/iCloud.

## Key Hypothesis

We believe **một gesture-to-shortcut mapper native Swift với UI 1-màn-hình** sẽ **giải quyết pain "BTT quá phức tạp + không free"** cho **macOS power user + bạn bè của owner**.
We'll know we're right when **owner tự dùng >4 tuần liên tục và 3+ bạn bè giữ app > 2 tuần**.

## What We're NOT Building

- **Per-app context** — tăng complexity 3x, BTT territory
- **Shell script / AppleScript actions** — v1 chỉ keyboard shortcut
- **Pinch & rotate gestures** — edge case, conflict với system zoom
- **1-finger & 2-finger gestures** — conflict nặng với click thường + 2-finger scroll
- **Triple tap/click** — chroniclly unreliable, defer v2
- **Window management** — Rectangle/Magnet đã xuất sắc
- **Cloud sync / accounts / telemetry** — private project, không cần
- **Visual gesture recorder** — matrix picker đủ

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| Owner daily active | ≥4 tuần liên tục | Tự observation |
| Friend retention | 3+ bạn bè giữ > 2 tuần | Hỏi trực tiếp |
| RAM idle | < 20MB | Activity Monitor |
| Gesture latency p95 | < 50ms | `signpost` instrument |
| Binary size | < 2MB | `du -h Padium.app` |
| Crash-free sessions | > 99% | Manual over 4 tuần |

## Open Questions

- [ ] macOS 15 có siết `MultitouchSupport.framework` thêm không? (cần spike test)
- [ ] Có fallback nào public-API-only nếu private API bị break? (`NSEvent.gestureEvent` cover được bao nhiêu %?)
- [ ] Permission UX: user có willing grant cả Accessibility + Input Monitoring không? (cần thử với 1-2 bạn)
- [ ] 3-finger swipe up/down bị macOS Mission Control chiếm — user có phải disable trackpad setting system? (bad UX)

---

## Users & Context

**Primary User**
- **Who**: macOS power user (dev/designer), dùng MacBook hoặc Magic Trackpad ≥6h/ngày, đã có muscle memory trackpad, chưa từng hoặc đã bỏ BTT
- **Current behavior**: Dùng keyboard shortcut truyền thống + system gesture mặc định; bực khi phải rời home row để click menu
- **Trigger**: "Ước gì 3-finger tap mở Raycast luôn" — moment nhận ra muốn custom
- **Success state**: Gán xong 3-5 gesture yêu thích, dùng reflex hàng ngày, quên rằng đã cài

**Job to Be Done**
When **tôi đang code/design full-focus và cần trigger action thường xuyên (Raycast, screenshot, switch space)**, I want to **gán action đó vào gesture trackpad 1 lần**, so I can **trigger bằng muscle memory không rời home row và không nhớ shortcut**.

**Non-Users**
- BTT power users hài lòng với 50+ rules phức tạp — họ sẽ thấy Padium thiếu
- Non-trackpad users (chỉ dùng chuột)
- Windows/Linux — macOS only

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| Must | Detect 3/4-finger tap (1x, 2x) | Core thesis |
| Must | Detect 3/4-finger swipe (↑↓←→) | Core thesis |
| Must | Emit keyboard shortcut via CGEvent | Core action |
| Must | Matrix config UI (SwiftUI, 1 màn hình) | Owner chọn minimalist UI |
| Must | Config persistence (JSON at `~/.padium/config.json`) | Shareable với bạn bè |
| Must | Menu bar toggle on/off + quit | Basic control |
| Must | Permission onboarding (Accessibility + Input Monitoring) | Không có permission = app dead |
| Should | Export/import config JSON | Share preset cho bạn bè |
| Should | Visual feedback khi gesture triggered (HUD/sound toggle) | Learning aid |
| Should | Launch at login toggle | Daily-use necessity |
| Could | Enable/disable per-gesture-slot | Granular control |
| Could | Conflict warning khi chọn gesture macOS reserved | Better UX |
| Won't (v1) | Per-app context, shell scripts, pinch/rotate, 1/2-finger gestures, triple-tap, window mgmt, cloud sync | Out of scope, see above |

### MVP Scope

**12 gesture slots** = 2 fingers × 6 actions
- Fingers: **3, 4**
- Actions: **tap 1x, tap 2x, swipe ↑, swipe ↓, swipe ←, swipe →**
- Mỗi slot → optional keyboard shortcut (e.g., `⌘⇧T`)

MVP bao gồm: gesture engine + shortcut emitter + matrix UI + JSON config + menubar + permission onboarding. Ship 1-2 tuần.

### User Flow

1. Download `.app` → drag vào Applications
2. Launch → permission prompt (Accessibility + Input Monitoring) với "Open System Settings" button
3. Sau grant → menu bar icon xuất hiện, auto-mở config window
4. Matrix UI: bảng 2×6, mỗi cell click vào để record keyboard shortcut
5. Save → config.json written, gesture engine reload → sẵn sàng dùng
6. Next launches: im lặng ở menu bar, click icon để mở config hoặc toggle off

---

## Technical Approach

**Feasibility**: **HIGH** — BTT và Multitouch.app đã chứng minh stack khả thi ≥10 năm trên `MultitouchSupport.framework` private.

**Architecture Notes**

- **Language/UI**: Swift 6 + SwiftUI (`MenuBarExtra`, macOS 14+)
- **Gesture capture**: `OpenMultitouchSupport` v3.0.3+ (SwiftPM, MIT, Swift 6) — wrap private `MultitouchSupport.framework`. **Council consensus: commit day 1, không fallback public API** (NSEvent không cover finger count on tap).
- **Event preemption**: `CGEventTap @ kCGHIDEventTap` riêng để **suppress macOS native 3-finger Mission Control / 4-finger Spaces** trước khi fire. Đây là hard problem Critic flag — phải validate ở Phase 0.
- **Abstraction**: `protocol GestureSource` wrap OMS → swap/fork được khi Apple break
- **Action emission**: `CGEvent` keyDown/keyUp với modifier flags → post vào `.cghidEventTap`
- **Config**: `Codable` struct → JSON at `~/.padium/config.json`; hot-reload qua `FileWatcher` (optional)
- **Permissions**: `AXIsProcessTrustedWithOptions` check + deeplink `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- **Deps**: OpenMultitouchSupport (pinned version). App Sandbox **off** — không target MAS.

**Technical Risks**

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| **Event preemption** — gesture fire ĐỒNG THỜI với macOS Mission Control/Spaces (Critic) | **H** | Phase 0 spike `CGEventTap` suppression; nếu không suppress được → doc yêu cầu user disable System Settings > Trackpad gestures |
| **Gesture disambiguation state machine** — tap vs swipe-start race (Skeptic) | **H** | Phase 0 spike 2h inspect OMS raw events; design 150ms timeout window + palm-rejection trước khi viết UI |
| `MultitouchSupport` bị Apple break ở macOS 27 (WWDC 2026, ~8 tuần nữa) | M | Pin OMS version; abstract sau `protocol GestureSource`; community patch nhanh (BTT/MiddleDrag free-ride) |
| OMS maintainer ngừng update → phải tự reverse-engineer `MTDeviceCreateList` | L-M | Fork OMS vào repo, keep patch-ready |
| Unsigned `.dmg` + Gatekeeper nag khi share cho bạn bè (Critic) | H | Ad-hoc sign + notarize-free workflow doc; "System Settings > Privacy > Open Anyway" guide |
| `CGEvent` keyboard post không đi đến app target (sandboxed apps) | M | Test với Xcode, Chrome, Safari, Raycast, Notes |
| Permission UX churn — bạn bè bỏ ngang onboarding | M | Video 10s + 1-click deeplink; copywriting rõ "Tại sao cần permission" |
| SwiftUI `MenuBarExtra` quirks trên macOS 14 | L | Fallback `NSStatusItem` nếu gặp bug critical |
| Uninstall leaves orphan Accessibility grant — bạn bè không biết clean up | L | README uninstall section + `rm` script |

---

## Implementation Phases

| # | Phase | Description | Status | Parallel | Depends | PRP Plan |
|---|-------|-------------|--------|----------|---------|----------|
| 0 | Feasibility spike | **2-day** spike (post-council rescope): (a) OMS finger-count detection, (b) raw event inspection cho state-machine design, (c) `CGEventTap` preemption của macOS system gestures | pending | - | - | - |
| 1 | Gesture engine | Detect 3/4-finger tap (1x/2x) + swipe 4 hướng, emit events qua delegate | pending | with 2 | 0 | - |
| 2 | Shortcut emitter | CGEvent keyDown/Up với modifier flags; test với 5+ app | pending | with 1 | 0 | - |
| 3 | Config store | Codable model + JSON persistence + load/save + default config | pending | with 4 | - | - |
| 4 | Menu bar shell | `MenuBarExtra` icon, toggle on/off, quit, launch at login | pending | with 3 | - | - |
| 5 | Matrix config UI | SwiftUI 2×6 grid, shortcut recorder per cell, save button | pending | - | 3 | - |
| 6 | Permission onboarding | First-launch flow, deeplink to System Settings, retry loop | pending | - | 4 | - |
| 7 | Wire-up + E2E | Connect engine + emitter + config + UI + menu; manual E2E all 12 slots | pending | - | 1, 2, 5, 6 | - |
| 8 | Polish + ship | Icon, app signing (ad-hoc), `.dmg` packaging, README share cho bạn bè | pending | - | 7 | - |

### Phase Details

**Phase 0: Feasibility spike (2 ngày, post-council rescope)**
- **Goal**: De-risk 3 hard problems council surfaced — không chỉ API check
- **Scope**:
  - **0a. API check** (2h): SwiftPM add OMS, print finger count khi 3/4-finger tap trên macOS 14/15
  - **0b. State-machine inspection** (Skeptic, 4h): log raw OMS event stream (finger down/move/up timestamps) khi user tap + swipe — hiểu debounce window, palm rejection, resting-finger filter TRƯỚC KHI viết classifier
  - **0c. Preemption spike** (Critic, 8h): dùng `CGEventTap @ kCGHIDEventTap` + `NSEvent.addGlobalMonitor` để **suppress** 3-finger Mission Control + 4-finger Spaces. Test: gesture fire NHƯNG macOS không open Mission Control. Nếu fail → fallback plan: doc yêu cầu user disable trong System Settings.
- **Success signal**:
  - 0a: Console log "3 fingers tapped" ✅
  - 0b: Viết được state-machine pseudo-code từ observed data
  - 0c: Gesture intercepted, macOS system gesture KHÔNG trigger (hoặc: xác nhận cần user disable thủ công)
- **Gate**: nếu 0c fail hoàn toàn (không suppress được + user không chịu disable) → **re-evaluate MVP scope** (có thể drop 3-finger swipe khỏi 12 slots)

**Phase 1: Gesture engine**
- **Goal**: Gesture detection module với delegate API
- **Scope**: Debouncing tap (separate 1x vs 2x), swipe direction classifier (threshold 30px)
- **Success signal**: 12 gesture types fire đúng event trong test harness

**Phase 2: Shortcut emitter**
- **Goal**: Given `(keyCode, modifiers)` → trigger trong foreground app
- **Scope**: CGEvent tap, support ⌘⇧⌃⌥ combos, test Xcode + Chrome + Safari + Raycast + Notes
- **Success signal**: `⌘⇧T` emit mở tab Chrome vừa đóng

**Phase 3: Config store**
- **Goal**: Load/save config, default empty state
- **Scope**: JSON schema, migration-safe, atomic write
- **Success signal**: Edit JSON → restart app → setting giữ nguyên

**Phase 4: Menu bar shell**
- **Goal**: App chạy được ở menu bar, không dock
- **Scope**: `MenuBarExtra`, on/off toggle, quit, `LSUIElement=YES`
- **Success signal**: Menu bar icon xuất hiện, không dock, quit clean

**Phase 5: Matrix config UI**
- **Goal**: User edit 12 slots không cần touch JSON
- **Scope**: 2-row × 6-col grid, mỗi cell có `ShortcutRecorder`-style capture field
- **Success signal**: Gán 1 slot qua UI → config.json update → gesture hoạt động

**Phase 6: Permission onboarding**
- **Goal**: First launch flow grant permission smooth
- **Scope**: Detect permission state, prompt view với deeplink button, re-check loop
- **Success signal**: User mới grant xong trong < 30s

**Phase 7: Wire-up + E2E**
- **Goal**: Tất cả module nói chuyện được, 12 slots hoạt động end-to-end
- **Scope**: Dependency injection, app lifecycle, manual QA checklist
- **Success signal**: Owner dùng 1 ngày không crash, không lag

**Phase 8: Polish + ship**
- **Goal**: Build share được cho bạn bè
- **Scope**: App icon, ad-hoc code sign, `.dmg`, README với screenshot + permission guide
- **Success signal**: 1 bạn cài được không cần owner support

### Parallelism Notes

- **Phase 1 & 2** parallel: gesture detection độc lập với event emission
- **Phase 3 & 4** parallel: data layer độc lập với menu bar shell
- **Phase 5** chờ Phase 3 (cần config model), **Phase 6** chờ Phase 4 (cần app shell)
- **Phase 7** là integration gate — tất cả parallel tracks merge ở đây

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| Language | Swift 6 | Objective-C, Rust via Cocoa | Native perf, concurrency safety, modern tooling |
| UI framework | SwiftUI (`MenuBarExtra`) | AppKit `NSStatusItem` | Simpler, owner chọn minimalist, macOS 14+ stable |
| Gesture API | `OpenMultitouchSupport` v3.0.3 (SwiftPM, MIT) — no fallback | Chỉ `NSEvent` public; tự wrap `MTDeviceCreateList` | Public không cover finger count on tap (killer constraint). Council 4/4 consensus. OMS active Jan 2026, MiddleDrag precedent macOS 26 beta. |
| Event preemption | `CGEventTap @ kCGHIDEventTap` (to validate Phase 0c) | Doc yêu cầu user tắt system gestures thủ công | Critic flagged: preemption là hard problem riêng, OMS không giải quyết. Phase 0c sẽ xác nhận feasibility |
| Min macOS | 14 Sonoma | 13 Ventura | `MenuBarExtra` stable từ 14 |
| MVP slots | 12 (3/4 fingers × tap 1x/2x + swipe 4 dir) | 30 full matrix | Avoid 1/2-finger conflict + triple-tap unreliability |
| Action type | Keyboard shortcut only | +shell script, +AppleScript | Scope discipline, cover 80% use case |
| Config storage | JSON file | plist, SQLite, Core Data | Human-editable, shareable, no deps |
| Distribution | Private repo + share binary | App Store, public GitHub | Owner preference (private project) |
| License | N/A (private) | MIT, GPL | Skipped per owner |

---

## Research Summary

**Market Context**
- **BetterTouchTool** ($22/$45): feature-complete, ~120MB RAM, steep learning curve — direct "too complex" target
- **Multitouch.app** ($5, Mac App Store): closest competitor, simpler UI, ~30MB RAM, proves private API approach viable long-term
- **Swish** ($16): window management focus, không phải general gesture mapper
- **Hammerspoon** (free, Lua): power-user scripting, không gesture-first UX
- **Gap**: free + native + minimalist + gesture-only → Padium fits here

**Technical Context**
- `MultitouchSupport.framework` đã được reverse-engineered nhiều năm (Hanaasagi/multitouch, macOS community). Vẫn work trên macOS 14/15.
- `CGEvent` post keyboard shortcut là pattern standard cho accessibility apps (Rectangle, Raycast, Alfred đều dùng).
- `MenuBarExtra` (SwiftUI) ổn định macOS 14+. Edge case: keyboard focus trong popup window có thể cần workaround.
- macOS system-reserved gestures: 3-finger swipe up = Mission Control, swipe ↓ = App Exposé, 4-finger swipe ←→ = Spaces. User phải tắt trong System Settings > Trackpad > More Gestures HOẶC Padium phải warn conflict.

---

*Generated: 2026-04-13*
*Updated: 2026-04-13 (post-council on gesture API strategy)*
*Status: DRAFT — Phase 0 rescoped to 2 days covering 3 hard problems (API, state machine, preemption)*

## Council Decision Log

**2026-04-13 — Gesture API strategy (skill: ecc:council)**
- Question: private `MultitouchSupport` vs public `NSEvent`?
- Verdict: **4/4 consensus** — commit OMS day 1. Public path infeasible (no finger-count on tap).
- Surfaced 2 harder problems than API choice itself:
  1. Gesture disambiguation state machine (Skeptic)
  2. Event preemption of macOS system gestures (Critic)
- Action: Phase 0 expanded from 1→2 days, split 0a/0b/0c.
