<h1 align="center">Kiou Editor</h1>

<p align="center">
  <img src="icon.webp" alt="Kiou Editor icon" width="180" />
</p>

<p align="center">
  <em>The definitive client-side customization tweak for <strong>KIOU</strong>.<br/>
  Reshape every gated corner of the app — instantly, reversibly, without ever
  touching the network.</em>
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9316.5-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="target" src="https://img.shields.io/badge/target-com.neconome.shogi-ff66a3?style=flat-square" />
  <img alt="engine" src="https://img.shields.io/badge/engine-Unity%206%20%2B%20il2cpp-black?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-client--side%20only-1f9d55?style=flat-square" />
  <img alt="status" src="https://img.shields.io/badge/scope-authorized%20testing%20only-c69214?style=flat-square" />
</p>

---

Kiou Editor is the most complete client-side modification suite shipped for
**KIOU** (`com.neconome.shogi`, a Unity 6 + il2cpp shogi app), built for
**authorized penetration testing only**. Every restriction the retail client
politely declines to lift — cosmetic ownership, premium-only kifu analysis,
locked voice lines, the in-match Beginner Support evaluator's training
wheels — falls under a single in-app settings sheet you can flip on or off
without restarting the app, all powered by inline `MSHookFunction` patches
at `UnityFramework` base + RVA. No replacement binary, no jailbreak required
for sideload, no compromise on stability: just a dylib that loads with the
app and rewrites decoded protobuf objects on their way to the UI.

### Client-side only

Every modification Kiou Editor makes happens **inside the app process, after
the reply has already arrived from the server**. The tweak never:

- crafts or sends a request to the KIOU backend,
- replays or replays-with-edits a captured request,
- proxies, MITMs, or otherwise sits on the network path,
- writes to currency, paid items, or any monetised entity.

What the server stores about your account is untouched — flipping every
toggle off and relaunching returns the app to a fully vanilla state. Tampered
fields (item ownership, premium flag, hint-arrow depth, …) only live in this
client's RAM for the lifetime of the process.

> Frida spawn-hooking crashes on the app's anti-debug detection. Loading as a
> bundled dylib at launch avoids the `ptrace` trace path, which is why this is
> packaged as a tweak rather than a Frida script.

## Features

Each row below is its own switch in the settings sheet. Toggles default to
**on** for a fresh install; flipping one off makes that hook fall through to
the original method on the next call.

| Toggle | What it does |
|---|---|
| **Item Unlock** | Rewrites the decoded `SyncItemListReply` so decoration-band supplies (`isAcquired = 1`, `acquiredCount ≥ 1`), characters, and character skins appear owned. Currency / character-purchase / skin-currency entries are left alone. |
| **Bypass Character** | Outgoing `SelectCharacterAsync` is rewritten to the safe skin id; the user's chosen skin is kept on-device in `NSUserDefaults` and stitched back into every reply that advertises `is_selected`. Server only ever sees a legal request. |
| **Premium User** | Forces `isPremiumUser = true` across the kifu-detail flow (`KifuDetailModel.IsPremiumUser`, `GetShogiHistoryDetailListReply.InternalMergeFrom`, kifu-detail popup) so post-match analysis features unlock. |
| **Beginner Support** | `ResolvedBeginnerSupport.get_Enabled` is pinned to `true` (and `get_Depth` returns the user-set depth) so the hint arrow / best-move overlay shows up in modes where retail hides it. Also fans out into the match-room player status so the assist is honored end-to-end. |
| **Always Hint Arrow** | Pins the in-match hint arrow on regardless of retail's mode-by-mode gating, and routes the in-game `BeginnerSupportEvaluator` through the tunables below. |
| **Voice Unlock** | `CharacterVoicePlayer.SatisfiesRule` is forced `true` so locked voice cues play, and per-character intimacy in the sync reply is pinned to the unlock threshold so the UI doesn't grey out the lines. |

## Engine tuning

`BeginnerSupportEvaluator` is the NNUE-backed engine that drives the in-match
hint arrow, best-move suggestions and formation evaluation. Retail ships it
with `_analysisDepth = 5` and never calls `NativeSyncSession.SetHashSize`, so
the engine runs on Rshogi's compiled-in default hash (~16 MB) — visibly weak,
misses tactical lines. Kiou Editor exposes three knobs that override the
ScriptableObject defaults and pin the live Rshogi session:

| Knob | Range | Default | How it lands |
|---|---|---|---|
| `Depth` | 1 – 36 | **16** | Hook on `BeginnerSupportEvaluator..ctor` overwrites `+0x18 _analysisDepth` after the orig runs. 36 is the practical NNUE ceiling that returns in a reasonable wall-clock; depth 5 was the retail value. |
| `Skill Level` | 1 – 20 | **20** | Same ctor hook overwrites `+0x28 _engineSkillLevel`. Retail is already 20; we just pin it. |
| `Hash` | {64, 128, 256, 512, 1024} MB | **128 MB** | Hook on `BeginnerSupportEvaluator.EnsureInitializedLocked` calls `NativeSyncSession.SetHashSize(MB)` via direct ABI on the live Rshogi session — no retail path does. Pick whatever fits your device's free RAM; 1024 MB is realistic on iPhone 12+. |

The depth / skill writes ride on the **Always Hint Arrow** toggle: turn the
toggle off and the evaluator falls back to its ScriptableObject defaults on
the next match.

### Settings UI

A UIKit gear button (`Hook_CloneOverlay.m`) is drawn above the Unity surface
once the home screen is up; tapping it presents the settings sheet from
`Hook_SettingsUI.m`. The sheet surfaces:

- **Features** — one switch per row in the [Features](#features) table.
- **Engine** — the three steppers from [Engine tuning](#engine-tuning).
- **About** — repo link, X handle, and the embedded build commit.

All values persist in `NSUserDefaults` under the `kiou_editor.*` namespace.

## Scope (strict)

- **Client-side only.** The tweak hooks methods on decoded protobuf objects
  *after* they arrive from the server. No request is ever crafted, replayed,
  proxied, or otherwise sent — outbound traffic is byte-for-byte identical
  to a vanilla install.
- **Observation + ownership tamper only.** No network traffic is altered.
- `SyncItemListReply`: decoration-band supplies are unlocked in place
  (`isAcquired -> 1`, `acquiredCount >= 1`). Characters and character skins are
  flagged owned. Currency / character-purchase / skin currency are **never**
  written.
- `UpdateCollectionPresetReply`: observation logging only (no writes).
- Every pointer read is NULL/range-checked; writes are band-restricted and
  reentrancy-guarded. The hooks must never crash the app.

## Requirements

- [Theos](https://theos.dev/) with the Swift/Orion toolchain installed
  (`$THEOS` set). Kiou Editor itself is pure Objective-C and does not depend on
  the Orion runtime.
- iOS 15.0–16.5, arm64, rootless layout.
- A decrypted copy of the KIOU `.ipa` for the jailed (sideload) path.

## Build

### Jailbroken device (rootless)

Produces a `.deb` that installs to
`/var/jb/Library/MobileSubstrate/DynamicLibraries/`.

```sh
make package
# install over SSH (password: alpine on first run, then key-based)
make package install THEOS_DEVICE_IP=<device-ip>
```

### Jailed device (sideload)

Produces a bare dylib for injection via Sideloadly / AltStore.

```sh
make jailed
# -> packages/jailed/KiouEditor.dylib
```

The dylib only depends on `CydiaSubstrate` (besides system frameworks), which
Sideloadly bundles automatically as ElleKit. To install:

1. Build with `make jailed`.
2. In Sideloadly, load the decrypted KIOU `.ipa`.
3. Add `packages/jailed/KiouEditor.dylib` under **Inject dylib**.
4. Sign with your Apple ID / certificate and install.

## Logs

Kiou Editor writes to both an app-sandbox temp file and a root-readable path,
and emits `os_log` under the `com.neconome.shogi.kioueditor` subsystem.

- Jailbroken: `/var/tmp/kiou_editor.log`
- Jailed: app sandbox `NSTemporaryDirectory()/kiou_editor.log`, or view the
  `os_log` stream via Console.app / `idevicesyslog`.

Look for `=== KiouEditor loaded ===`, `UnityFramework base=...`, and the
`[UNLOCK]` / `[UNLOCK-CHAR]` summary lines to confirm the hooks fired.

## Notes

RVAs are specific to the analyzed KIOU build and will need to be re-derived
against `UnityFramework` after an app update.
