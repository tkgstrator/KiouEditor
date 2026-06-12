# Porting to a new KIOU build

When the KIOU team ships a new version, **every RVA in the source tree
needs to be re-derived** before the dylib can run safely against it. This
doc walks through that procedure end to end. The current build's pinned
version is recorded in the [Compatibility](../README.md#compatibility)
section of the README.

The pattern is the same for every hook:

1. dump the new `UnityFramework`
2. find each target method by **anchor** (class name + method name + signature
   shape), not by guessing the address from the previous version
3. record the new RVA, verify the field offsets it operates on are unchanged
4. update the `#define RVA_…` line(s) in the hook's `.m` file, rebuild,
   smoke-test from the log

Doing this with discipline is the difference between a clean port and a
process that crashes on launch.

## 0. What can break across versions

- **RVAs drift on every build.** Even a patch build that only touches
  Unity asset compilation moves `UnityFramework` symbol addresses. Assume
  every `#define RVA_*` in `Sources/KiouEditor/Hook_*.m` is wrong until
  proven otherwise.
- **Field offsets drift when the il2cpp metadata changes.** Adding a field
  to a class above the one we read shifts everything below it. Re-read
  every offset listed in [`hooks.md`](hooks.md) against the new dump.
- **Method signatures can change.** A new parameter on an outbound
  request, a new repeated field on a reply, a return type swap — any of
  these means the `typedef ... (*foo_t)(...)` in the hook file no longer
  matches the calling convention. Update the typedef before touching the
  RVA.
- **Class names rarely change.** Project namespaces (`Project.Network`,
  `Project.Game.Logic`, etc.) and the generated protobuf classes (`*Reply`,
  `*Status`) are stable. Use them as anchors.
- **Anti-debug shape can change.** If the ptrace probe moves to a different
  init phase the bootstrap retry loop may fire too late. Watch the boot log.

## 1. Get the new `UnityFramework` decrypted

You need a decrypted copy of the new IPA — App Store delivers it encrypted.
On a jailbroken device with frida-tools installed:

```sh
frida-ios-dump -H <device-ip> com.neconome.shogi
```

…or the offline equivalent of your choice. The encrypted `.ipa` from the
App Store will not produce a usable `UnityFramework` for static analysis.

Drop the resulting `.ipa` at `targets/Kiou/Kiou-<new-version>.ipa`.

## 2. Re-dump with Il2CppDumper

```sh
# from the .ipa root after `unzip`
Il2CppDumper \
  Payload/KIOU.app/Frameworks/UnityFramework.framework/UnityFramework \
  Payload/KIOU.app/Data/Managed/Metadata/global-metadata.dat \
  targets/Kiou/il2cpp_out_<new-version>
```

You want at minimum `dump.cs` (signatures, field offsets) and
`script.json` (native ABI tables with the addresses you'll resolve into
RVAs).

Verify the dump succeeded by spot-checking a known-stable class:

```sh
grep -n "internal sealed class SyncItemListReply" .../dump.cs
```

If that grep finds nothing, the dumper failed (most often: stripped image
or metadata mismatch). Don't proceed until the dump produces signatures.

## 3. Re-derive each RVA

For every `#define RVA_…` in `Sources/KiouEditor/Hook_*.m`:

### a. Find the method by anchor in `dump.cs`

The current hooks anchor on these qualified names:

| Hook file | Anchor name(s) in `dump.cs` |
|---|---|
| `Hook_SyncItemList.m`     | `Project.Network.SyncItemListReply.InternalMergeFrom` |
| `Hook_Collection.m`       | `Project.Network.UpdateCollectionPresetReply.InternalMergeFrom` |
| `Hook_Version.m`          | `TitleScene.<OnActivateAsync>d__10.MoveNext` |
| `Hook_SelectCharacter.m`  | `Project.Network.GameServiceClient.SelectCharacterAsync`, `Project.Network.SelectCharacterReply.InternalMergeFrom` |
| `Hook_MatchingPlayer.m`   | `Project.Network.ShogiMatchingPlayerStatus.InternalMergeFrom` |
| `Hook_PremiumUnlock.m`    | `KifuDetailModel.IsPremiumUser`, `Project.Network.GetShogiHistoryDetailListReply.InternalMergeFrom`, `Project.Network.GetShogiHistoryDetailListReply.get_IsPremiumUser` |
| `Hook_AssistTune.m`       | `Project.Game.Presentation.BeginnerSupportEvaluator..ctor`, `Project.Game.Presentation.BeginnerSupportEvaluator.EnsureInitializedLocked`, `Rshogi.NativeSyncSession.SetHashSize` |
| `Hook_AssistEnable.m`     | `ResolvedBeginnerSupport.get_Enabled`, `ResolvedBeginnerSupport.get_Depth` |
| `Hook_VoiceUnlock.m`      | `CharacterVoicePlayer.SatisfiesRule`, `VoiceCellModel.get_IsLocked` |

Grep `dump.cs` for the qualified name. You'll see something like:

```cs
// RVA: 0x597A448 Offset: 0x597A448 VA: 0x597A448
public void .ctor(string evalPath, BeginnerSupportSettings settings) { }
```

The address right after `RVA:` is the value to plug into the corresponding
`#define`.

### b. Verify the signature

Compare the dumped signature to the `typedef` in the hook file. For BSE
ctor:

```objc
typedef void (*BSECtor_t)(void *self, void *evalPath, void *settings);
```

This says "non-static method, returns void, takes self + two reference
parameters". If the new dump says
`public void .ctor(string evalPath, BeginnerSupportSettings settings, int extra)`
the typedef needs a third `void *`. **Update the typedef before installing
the hook.** Calling through a wrong-shape typedef silently corrupts the
stack frame.

### c. Cross-check `script.json`

For direct-ABI calls (like `NativeSyncSession.SetHashSize`), `script.json`
records both the method name and the address:

```json
{
  "Name": "Rshogi.NativeSyncSession$$SetHashSize",
  "Signature": "void Rshogi_NativeSyncSession__SetHashSize (Rshogi_NativeSyncSession_o* __this, int32_t mb, const MethodInfo* method);",
  "Address": 97722592
}
```

Address is decimal; `printf "%x\n" 97722592` ⇒ `0x5D320E0`. That should match
the `dump.cs` RVA exactly. If they disagree, trust `script.json` — `dump.cs`
RVAs can lag for inlined wrappers.

## 4. Re-verify field offsets

For every offset referenced in [`hooks.md`](hooks.md), find the class
declaration in the new `dump.cs` and confirm the field lives at the same
`+0xNN`. Example:

```cs
internal sealed class CharacterStatus // TypeDefIndex: ...
{
    private int mstCharacterId_;     // 0x18   <— must still be 0x18
    private int intimacy_;           // 0x40   <— must still be 0x40
    private bool isAcquired_;        // 0x44
    private bool isSelected_;        // 0x45
}
```

If even one offset moved, **find every site that reads it** (grep the
hook source for the `OFF_*` macro or the literal offset) and update each
one. A shifted offset on a write path is how you turn `isAcquired = 1`
into "stomp a vtable pointer".

For `RepeatedField<T>` reads via `readRepeatedField(...)`, the `0x10` /
`0x18` layout has been stable across Unity versions. If you ever see a
mismatch there, suspect the dumper rather than the layout.

## 5. Rebuild and validate from the boot log

```sh
make clean && make jailed
```

Install the rebuilt dylib and read the log (`/var/tmp/kiou_editor.log` on
jailbroken, sandbox `kiou_editor.log` on jailed — see
[`internals.md`](internals.md#logging-loggingm)). Verify in order:

1. `=== KiouEditor loaded ===` — dylib loaded.
2. `UnityFramework base=0x...` — Unity mapped, installer fires.
3. One `... hooked @0x...` line per installer. If a hook line doesn't
   appear, the installer threw or `MSHookFunction` returned early.
4. `=== All UnityFramework hooks installed ===` — bootstrap complete.

Then trigger each feature once and look for its runtime line (the table
in [`internals.md`](internals.md#logging-loggingm) lists what to expect).
If a feature's install line is present but no runtime line ever fires, the
RVA points at a near-miss — usually an adjacent inlined overload that
isn't on the live call path.

## 6. Bump the pinned compatibility

When all RVAs land and the runtime lines look right, update
[README.md](../README.md#compatibility) to name the new version, and bump
the `Version:` field in `control` so the `.deb` carries the version
forward.

## Common failure modes

| Symptom in log | Likely cause |
|---|---|
| `UnityFramework base=...` then nothing | Constructor ran but the `dyld_image_count` loop didn't find the new framework name (renamed bundle?). Adjust the `strstr(name, "UnityFramework")` filter in `Tweak.m`. |
| Install lines present, runtime lines absent | Wrong RVA — the hook is installed on a dead method. Re-grep `dump.cs` for the anchor. |
| Install lines present, app crashes on launch in a hooked method | Signature drift. The typedef doesn't match the live calling convention. Compare arg-by-arg against the new `dump.cs`. |
| Per-element write line fires but the UI still shows the field as gated | Field offset drifted. Re-verify `+0xNN`. |
| `EnsureInitializedLocked: SetHashSize(...)` never logs | The lazy-init path doesn't run until the first match's first BSE eval. Trigger a match before declaring this missing. |

When in doubt, stage the rebuild on a test account before pointing it at
anything important.
