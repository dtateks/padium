# PRODUCT BRIEF — Padium Trackpad (working name)

**Date:** 2026-04-13
**Mode:** Product Diagnostic (Product Lens Mode 1)
**Status:** ✅ GO — as personal + friends OSS project

---

## 1. Who

**Primary:** Chính bạn + bạn bè (macOS power user, dùng MacBook / Magic Trackpad hàng ngày).
**Secondary:** Người mới chưa từng custom gesture — muốn entry-point dễ hơn BetterTouchTool (BTT).

**Không phải:** BTT power user (họ đã quen 100+ options, không phải target).

## 2. Pain

BTT **quá phức tạp** (overwhelming UI, 100+ settings) và **không free** ($22).
→ Rào cản để "chỉ muốn gán 1 gesture → 1 shortcut rồi xong."

## 3. Why now

Scratch-your-own-itch + share cho bạn bè. **Không phải startup, không commercial.** Free & open source.

## 4. 10-star version

- Native Swift, menu bar app, **<15MB RAM idle**, **<50ms** gesture→action latency
- Gesture matrix: **30 slots**
  - Fingers: **2, 3, 4** (bỏ 1-finger vì conflict với click thường)
  - Actions: **tap** (1x/2x/3x), **click** (1x/2x/3x), **swipe** (↑↓←→)
  - = (3 + 3 + 4) × 3 fingers = **30 gesture slots**
- Mỗi slot → 1 keyboard shortcut (e.g. `⌘⇧T`, `⌃Space`)
- Config UI đơn giản: bảng matrix 1 màn hình
- Export/import config JSON (share cho bạn bè)

## 5. MVP (ship trong 1-2 tuần)

**Chỉ làm 1 việc:** gesture trackpad → phát keyboard shortcut.

- Gesture matrix rút gọn: **3-finger & 4-finger only**, **swipe 4 hướng + tap single/double**
  - = (2 + 4) × 2 fingers = **12 slots** — đủ prove thesis
- Config UI: list đơn giản (gesture → shortcut picker)
- Config lưu JSON tại `~/.padium/config.json`
- Menu bar icon, toggle on/off, quit
- Permission onboarding flow (Accessibility + Input Monitoring)

**Bỏ khỏi MVP:**
- ❌ Per-app context
- ❌ Shell script / AppleScript actions (chỉ keyboard shortcut)
- ❌ Pinch & rotate
- ❌ 1-finger & 2-finger gestures (conflict rủi ro cao với system)
- ❌ Triple tap/click (để sau)
- ❌ Cloud sync, account, telemetry

## 6. Anti-goals (explicit)

- Không làm window management (Rectangle đã có)
- Không Touch Bar, không keyboard remap (Karabiner territory)
- Không UI visual gesture recorder — dùng matrix picker
- Không kiếm tiền, không pricing page
- Không cố thay thế BTT full-feature — đây là "BTT lite for 80% use case"

## 7. Success metric

- ✅ Bạn tự dùng hàng ngày **>4 tuần liên tục** không gỡ → thesis validated
- ✅ 3-5 bạn bè cài và giữ > 2 tuần
- ✅ RAM idle đo được < 20MB
- ✅ Latency p95 < 50ms (đo bằng instrument)
- ⭐ Bonus: 50+ GitHub stars = có signal public interest

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Private API (`MultitouchSupport.framework`) bị Apple break | High | Fallback dùng `NSEvent` public gesture API; version-gate |
| Gesture conflict với system (3-finger swipe = Mission Control) | High | MVP **tránh** các gesture system reserved; document rõ |
| Accessibility permission onboarding churn | Medium | Onboarding flow có video 10s, 1-click open System Settings |
| Scope creep → thành BTT-clone | High | Giữ chặt anti-goals; nếu bạn bè xin feature ngoài scope → từ chối v1 |

---

## Tech stack (đề xuất)

- **Swift 6** + **SwiftUI** (menubar via `MenuBarExtra`)
- **MultitouchSupport** (private, wrapped) cho raw finger count
- **CGEvent** để post keyboard shortcut
- **Codable + JSON** cho config
- No dependencies, no SPM packages nếu tránh được
- **Xcode 16**, min target **macOS 14 Sonoma**

Binary target: **< 2MB**, RAM idle **< 20MB**.

---

## Go/No-Go: ✅ GO

Vì:
1. Personal project, không cần market-fit
2. Scope đủ nhỏ để ship 2 tuần
3. Pain của bạn (BTT phức tạp + tốn tiền) là real và common
4. Tech feasible, không có unknown lớn

---

## Next Step

Handoff sang **`product-capability`** để ra implementation plan:
- Module breakdown (GestureEngine, ShortcutEmitter, ConfigStore, MenuBarUI, Onboarding)
- Data model cho config
- Sprint breakdown tuần 1 / tuần 2
- Permission flow diagram

Gõ `/ecc:product-capability` khi sẵn sàng, hoặc bảo tôi tiếp tục.
