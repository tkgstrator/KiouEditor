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

Kiou Editor is the most complete client-side customization suite shipped for
**KIOU**, built for **authorized penetration testing only**. Every restriction
the retail client politely declines to lift — cosmetic ownership, premium-only
kifu analysis, locked voice lines, the in-match Beginner Support engine's
training wheels — falls under a single in-app settings sheet you can flip on
or off without restarting the app. No replacement binary, no jailbreak required
for sideload, no compromise on stability.

### Client-side only

Every modification Kiou Editor makes happens **inside the app on your device,
after the server has already replied**. The tweak never:

- crafts or sends a request to the KIOU backend,
- replays a captured request, with or without edits,
- proxies, MITMs, or otherwise sits on the network path,
- writes to currency, paid items, or any monetised entity.

What the server stores about your account is untouched — flipping every
toggle off and relaunching returns the app to a fully vanilla state.

## Features

Each row below is its own switch in the settings sheet. Toggles default to
**on** for a fresh install; flipping one off restores the retail behaviour
for that feature on the next match / launch.

| Toggle | What it does |
|---|---|
| **Item Unlock** | Decoration supplies, characters, and character skins all show as owned. Currency and paid items stay vanilla. |
| **Bypass Character** | Equip any character or skin you want without owning it. The server only ever sees a legal "safe" skin being equipped; your real choice is remembered on-device and shown everywhere the UI displays "currently equipped". |
| **Premium User** | Unlocks the full post-match kifu analysis flow without a premium subscription. |
| **Beginner Support** | Turns on the in-match hint arrow / best-move overlay in every mode, including ones where retail hides it (ranked, etc.). |
| **Always Hint Arrow** | Keeps the hint arrow visible at all times during a match, and routes the in-game engine through the [Engine tuning](#engine-tuning) sliders. Pair with **Beginner Support** for the strongest assist. |
| **Voice Unlock** | Every character voice line plays regardless of intimacy gating. |

## Engine tuning

The in-match hint arrow and best-move suggestions come from a built-in NNUE
engine that ships configured very conservatively. Kiou Editor exposes three
sliders to make it actually strong:

| Knob | Range | Default | Effect |
|---|---|---|---|
| `Depth` | 1 – 36 | **16** | How many plies the engine searches. Retail uses 5 (visibly weak). Higher = stronger but each evaluation takes longer. 36 is the practical ceiling — beyond that the engine never returns in time. |
| `Skill Level` | 1 – 20 | **20** | Engine personality strength. 20 is "no handicap, play the best move". Lower values intentionally weaken it. |
| `Hash` | 64 / 128 / 256 / 512 / 1024 MB | **128 MB** | Transposition-table size for the engine. Retail never configures this and runs on a tiny internal default. More hash = stronger play, but uses that much device RAM. 1024 MB is comfortable on iPhone 12 and newer; drop to 64–256 MB on older devices. |

The depth / skill / hash values only take effect while **Always Hint Arrow**
is on. Turn that switch off and the engine falls back to retail defaults
without restarting the app.

### Settings UI

A floating gear button is drawn on the home screen once the app finishes
launching. Tap it to open the settings sheet, which surfaces:

- **Features** — one switch per row in the [Features](#features) table.
- **Engine** — the three sliders from [Engine tuning](#engine-tuning).
- **About** — repo link, X handle, and the embedded build commit.

All values persist between launches.

## Compatibility

This build targets:

| | |
|---|---|
| **KIOU app version** | `1.0.1` (`CFBundleVersion` 11) |
| **iOS** | 15.0 – 16.5, arm64, rootless |

All hooks are pinned to RVAs from this exact KIOU build's `UnityFramework`
binary. After a KIOU update the RVAs will drift and the tweak will silently
no-op (or, worst case, crash on a method whose signature changed).
**Don't install this dylib against a KIOU version other than the one above
without re-deriving every RVA first** — the procedure is documented in
[`docs/porting.md`](docs/porting.md).

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

## Documentation

Developer-facing notes live under [`docs/`](docs/):

- [`docs/hooks.md`](docs/hooks.md) — per-toggle implementation notes: RVAs,
  decoded protobuf field offsets, override values, gating logic.
- [`docs/internals.md`](docs/internals.md) — bootstrap, il2cpp bridging,
  settings persistence, logging, anti-debug context.
- [`docs/porting.md`](docs/porting.md) — what to do when a new KIOU build
  ships: re-dumping `UnityFramework`, finding each RVA by anchor, validating
  field offsets, and the sanity-check log lines to read on first boot.
