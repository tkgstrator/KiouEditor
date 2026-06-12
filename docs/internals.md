# Internals

How Kiou Editor wires itself into the running KIOU process. For per-hook
details (RVAs, field offsets, override values) see
[`hooks.md`](hooks.md); for what to do after a KIOU update see
[`porting.md`](porting.md).

## Why a tweak and not Frida

KIOU bundles an anti-debug `ptrace` probe that fires on attach. Frida
spawn-hooking ends the process before any hook script has a chance to run.
Kiou Editor sidesteps that path entirely by shipping as a dylib that is
either:

- loaded by MobileSubstrate / ElleKit at `dyld` time on a jailbroken device
  (the `.deb` install), or
- injected at sign time by Sideloadly / AltStore on a jailed device.

Either way the dylib lives in the process from `main` onwards; nothing
attaches to a running PID, so the anti-debug detector finds nothing.

## Bootstrap (`Tweak.m`)

Entry is the constructor:

```objc
__attribute__((constructor)) static void init(void) {
    logging_init();
    file_log(@"=== KiouEditor loaded ===");
    installUnityHooks();   // probably bails — UnityFramework not mapped yet

    dispatch_after(1s, ..., ^{ retryInstallHooks(); });
}
```

`UnityFramework` is normally not mapped at the host binary's constructor
time. `installUnityHooks` walks `_dyld_image_count()` for an image whose
name contains `UnityFramework`; if it isn't found, the retry loop
re-attempts on a 2-second cadence until it succeeds.

Once `unityBase` is known, the installers run in a fixed order (see
`Tweak.m`). Every installer takes `unityBase` and calls `MSHookFunction`
on `unityBase + RVA` for each method it owns; the orig pointer is captured
into a static so the hook can chain to it.

After all installers succeed `g_unityHooked` is set so further dyld events
don't re-install. The retry loop noops once that flag is up.

## il2cpp bridge (`Hook_FriendUnhide.m`'s symbols)

For the few hooks that need to **call** il2cpp methods on live objects
(rather than just intercept them), `Hook_FriendUnhide.m` resolves a small
set of libil2cpp symbols once via `dlsym(RTLD_DEFAULT, …)`:

- `il2cpp_runtime_invoke`
- `il2cpp_class_from_name`
- `il2cpp_class_get_method_from_name`
- `il2cpp_object_get_class`
- `il2cpp_class_get_parent`
- `il2cpp_string_new`

These are used to walk class hierarchies, look up methods by name, and box
a UTF-8 `char*` into an il2cpp `String*`. `il2cpp_runtime_invoke` is the
generic invocation path (boxed args, indirect through the invoker thunk).

Some invocations crash inside the invoker thunk (the `GameObject.Instantiate`
generic overloads in particular). The workaround is **direct ABI**: read the
`methodPointer` slot off the `MethodInfo*` returned by
`class_get_method_from_name`, cast it to a typed function pointer with the
trailing `MethodInfo*` argument, and call it directly. The
`Tf.SetSiblingIndex_directABI_t` pattern in `Hook_FriendUnhide.m` is the
canonical example. The trailing `MethodInfo*` slot is NULL for non-generic
methods that don't introspect themselves.

`Hook_AssistTune.m`'s SetHashSize call uses the same pattern, but goes one
step further and casts the **raw RVA** to a function pointer — no
`MethodInfo*` lookup, the il2cpp codegen wrapper is reached purely by
address. That works because `NativeSyncSession.SetHashSize` is non-generic
and never reads its `MethodInfo*` argument.

## Pointer safety helpers (`Internal.h`)

Every read goes through one of the `static inline` helpers:

- `ptrLooksValid(p)` rejects `NULL`, anything < `0x1000`, and anything
  ≥ `0x0001_0000_0000_0000` (above current iOS user-space mappings).
- `readI32 / readU8 / readPtr` are bounds-implicit through `ptrLooksValid`
  on the base before the dereference.
- `readRepeatedField` reads `+0x10` for the array ptr and `+0x18` for the
  count, rejects negative counts or counts > 100,000.
- `readArrayElem(arr, i)` indexes `arr + 0x20 + i * 8`.

Writes (`writeI32 / writeU8`) are volatile-qualified to defeat any compiler
re-ordering against the orig call.

Bridge functions like `il2cppStringToNSString` cap length at `0x10000` UTF-16
code units before reading.

## Reentrancy guard

A few hooks (notably `Hook_SyncItemList` and `Hook_Collection`) deal with
protobuf messages whose `InternalMergeFrom` can recurse — the same orig is
on the call stack twice when a reply embeds another reply. `g_inHook`
(defined in `Tweak.m`) is a global flag the relevant hooks bump on entry
and clear on exit; second-entry sees it non-zero and falls straight through
to `orig()`.

`Hook_AssistTune.m`'s two hooks don't bother — there's no recursion path
through BSE construction.

## Settings persistence (`Persistence.m`)

Everything user-facing lives in `NSUserDefaults` under the
`kiou_editor.*` namespace:

| Key | Type | Default |
|---|---|---|
| `kiou_editor.feature.*` (one per `KiouFeature`) | BOOL | `YES` |
| `kiou_editor.assist_depth` | int | 16 |
| `kiou_editor.assist_skill_level` | int | 20 |
| `kiou_editor.assist_hash_idx` | int (0–4) | 1 (= 128 MB) |
| `kiou_editor.persisted_selection` | int | 0 (use server value) |
| `kiou_editor.self_user_id` | string | "" |

The feature flags use the "absent ⇒ true" convention so the first launch
after install behaves identically to every release before the settings UI
shipped. Numeric tunables clamp through `clampInt(v, lo, hi)` on both the
getter and the setter so corrupted defaults can't push past the documented
ranges.

The hash setting stores an **index**, not raw MB, so the UI stepper can
only emit values from the preset table
`{ 64, 128, 256, 512, 1024 } MB`. `kiou_assistHashMB()` is the convenience
that reads the index and returns the MB integer.

## Logging (`Logging.m`)

Three sinks fire on every `file_log(...)`:

1. `NSLog` — visible via Console.app on a connected Mac, or
   `idevicesyslog`.
2. `os_log` under subsystem `com.neconome.shogi.kioueditor`, category
   `editor`. Same Console destination but searchable by subsystem.
3. Two file destinations, written line-by-line with an `HH:mm:ss.SSS`
   prefix:
   - `g_logFile`  — `NSTemporaryDirectory()/kiou_editor.log` (app sandbox)
   - `g_logFile2` — `/var/tmp/kiou_editor.log` (root-accessible)

The dual file output means a jailbroken device can `cat /var/tmp/...`
directly, while a jailed sideload can ship the sandbox copy out over a
debug Files-app share.

Boot lines worth grepping for:

| Line | Meaning |
|---|---|
| `=== KiouEditor loaded ===` | dylib loaded, constructor ran. |
| `UnityFramework base=0x...` | Unity module mapped, installer about to fire. |
| `=== All UnityFramework hooks installed ===` | every installer succeeded. |
| `[ASSIST] BSE tuned: depth N -> M, skillLevel X -> Y` | the BSE ctor hook fired on first eval. |
| `[ASSIST] EnsureInitializedLocked: SetHashSize(N) ok session=0x...` | hash set on the Rshogi session. |
| `[UNLOCK] supply ...` / `[UNLOCK-CHAR] ...` | per-element item-unlock writes. |
| `[SETTINGS] assist depth -> N` | settings UI persisted a knob. |

If the install line appears but per-hook lines never do, the orig was
probably never invoked (wrong RVA — see [`porting.md`](porting.md)).

## Error policy

Every hook wraps its mutation logic in `@try { ... } @catch (NSException *e) { ... }`
and falls through to logging the exception. The orig call is always invoked
first (or last, for outbound hooks), so even a thrown exception inside the
hook can't drop the original request/response on the floor.

No hook may crash the app. If you find a path that can, it's a bug — file
it.
