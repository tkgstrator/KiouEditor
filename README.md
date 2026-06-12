# KiouEditor

An iOS tweak for **KIOU** (`com.neconome.shogi`, a Unity 6 + il2cpp shogi app)
that edits ownership state in server replies, for **authorized penetration
testing only**.

KiouEditor loads as a dylib inside the app process from the start of the launch
sequence and installs inline hooks (`MSHookFunction`) at `UnityFramework`
base + RVA. It rewrites the decoded `SyncItemListReply` in memory so that
decoration-band supplies, characters, and character skins appear owned. It never
touches currency, paid items, or the network — local response edits only.

> Frida spawn-hooking crashes on the app's anti-debug detection. Loading as a
> bundled dylib at launch avoids the `ptrace` trace path, which is why this is
> packaged as a tweak rather than a Frida script.

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
