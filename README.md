# KiouEditor

An iOS tweak for **KIOU** (`com.neconome.shogi`, a Unity 6 + il2cpp shogi app)
that edits ownership state in server replies and tweaks the in-game NNUE
evaluator, for **authorized penetration testing only**.

KiouEditor loads as a dylib inside the app process from the start of the launch
sequence and installs inline hooks (`MSHookFunction`) at `UnityFramework`
base + RVA. It rewrites decoded protobuf replies in memory so that
decoration-band supplies, characters, and character skins appear owned,
unlocks cosmetic-only gates (premium kifu view, voice playback, friend menu),
and pins the Beginner Support evaluator to user-chosen depth / hash settings.
It never touches currency, paid items, or the network — local response edits
only.

> Frida spawn-hooking crashes on the app's anti-debug detection. Loading as a
> bundled dylib at launch avoids the `ptrace` trace path, which is why this is
> packaged as a tweak rather than a Frida script.

## Features

Each hook module lives in `Sources/KiouEditor/Hook_*.m` and can be toggled at
runtime from the in-app settings sheet (see [Settings UI](#settings-ui)).
Toggles default to **on** for a fresh install.

| Module / setting label | What it does |
|---|---|
| **Item Unlock** (`Hook_SyncItemList`) | Rewrites the decoded `SyncItemListReply` so decoration-band supplies (`isAcquired = 1`, `acquiredCount ≥ 1`), characters, and character skins appear owned. Currency / character-purchase / skin-currency entries are left alone. |
| Collection observer (`Hook_Collection`) | Pure observation — logs `UpdateCollectionPresetReply` field layout for analysis. No writes. |
| Title version label (`Hook_Version`) | Cosmetic: appends `+(commit)` to the title-screen build label so we can tell which dylib is loaded. |
| **Bypass Character** (`Hook_SelectCharacter`) | Outgoing `SelectCharacterAsync` is rewritten to the safe skin id; the user's chosen skin is kept on-device in `NSUserDefaults` and stitched back into every reply that advertises `is_selected`. Server only ever sees a legal request. |
| Match avatar (`Hook_MatchingPlayer`) | Patches `ShogiMatchingPlayerStatus.InternalMergeFrom` so the local player's match-room avatar matches the persisted Bypass Character skin instead of the server-known safe skin. |
| **Premium User** (`Hook_PremiumUnlock`) | Forces `isPremiumUser = true` across three call sites (`KifuDetailModel.IsPremiumUser`, `GetShogiHistoryDetailListReply.InternalMergeFrom`, kifu-detail popup) so post-match analysis features unlock. |
| **Beginner Support** (`Hook_MatchingPlayer`, `Hook_AssistEnable`) | `ResolvedBeginnerSupport.get_Enabled` is pinned to `true` and `get_Depth` returns the user-set depth, so the hint arrow / best-move overlay shows up in modes where it normally wouldn't (e.g. ranked). |
| **Always Hint Arrow** + engine tuning (`Hook_AssistTune`) | Two hooks on `BeginnerSupportEvaluator`. (a) `..ctor` overwrites `_analysisDepth` and `_engineSkillLevel` with the user-set values. (b) `EnsureInitializedLocked` calls `NativeSyncSession.SetHashSize(MB)` via direct ABI on the live Rshogi session — retail never sets it, so the engine ran on a tiny compiled-in default. Defaults: depth = 16, skill = 20, hash = 128 MB. |
| **Friend Button** (`Hook_FriendUnhide`) | Re-shows the home-screen friend button (retail forces `SetActive(false)`), and clones the menu button onto the home bar as a settings entry point. Tapping the clone presents the KiouEditor settings sheet. |
| **Voice Unlock** (`Hook_VoiceUnlock` + intimacy pin in `Hook_SyncItemList`) | `CharacterVoicePlayer.SatisfiesRule` is forced `true` so locked voice cues play, and per-character intimacy in the sync reply is pinned to the unlock threshold so the UI doesn't grey out the lines. |

### Settings UI

The cloned menu button on the home bar presents a UIKit settings sheet (see
`Hook_SettingsUI.m`). It surfaces:

- **Features** — one switch per module above. Toggling a feature flag takes
  effect on the next hook fire; home-screen UI changes (friend button + clone)
  need a return to the title and back.
- **Engine** — three steppers for the Beginner Support evaluator:
  - `Depth` (1–50, default 16). Higher = stronger but heavier per move.
  - `Skill Level` (1–20, default 20).
  - `Hash` (preset {64, 128, 256, 512, 1024} MB, default 128 MB).
- **About** — repo link, X handle, and the embedded build commit.

All values persist in `NSUserDefaults` under the `kiou_editor.*` namespace.

## Scope (strict)

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
  (`$THEOS` set). KiouEditor itself is pure Objective-C and does not depend on
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

KiouEditor writes to both an app-sandbox temp file and a root-readable path,
and emits `os_log` under the `com.neconome.shogi.kioueditor` subsystem.

- Jailbroken: `/var/tmp/kiou_editor.log`
- Jailed: app sandbox `NSTemporaryDirectory()/kiou_editor.log`, or view the
  `os_log` stream via Console.app / `idevicesyslog`.

Look for `=== KiouEditor loaded ===`, `UnityFramework base=...`, and the
`[UNLOCK]` / `[UNLOCK-CHAR]` summary lines to confirm the hooks fired.

## Notes

RVAs are specific to the analyzed KIOU build and will need to be re-derived
against `UnityFramework` after an app update.
