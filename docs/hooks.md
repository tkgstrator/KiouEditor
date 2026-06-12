# Hooks reference

Per-toggle implementation notes. Every RVA is relative to the
`UnityFramework` load address captured at `MSHookFunction` install time
(see [`internals.md`](internals.md) for the bootstrap). RVAs are specific to
the analyzed KIOU build and need to be re-derived against `UnityFramework`
after any app update.

Field offsets come from `il2cpp_out/dump.cs`. Layout conventions:

- `RepeatedField<T>`: `+0x10` array pointer, `+0x18` count
- il2cpp object array: element[0] at `arrayPtr + 0x20`, refs 8-byte spaced
- il2cpp `string`: `+0x10` length (UTF-16 code units), `+0x14` `char[]`

All writes are NULL/range-checked, band-restricted, and reentrancy-guarded
through `g_inHook` so a single in-flight hook can't recurse.

---

## Item Unlock (`Hook_SyncItemList.m`)

Hook on `Project.Network.SyncItemListReply.InternalMergeFrom(ref ParseContext)`
at **RVA `0x5C37034`**. Lets the orig finish decoding, then walks the three
repeated fields on the reply:

| Field on `self` | Offset | Element layout (key offsets) |
|---|---|---|
| `updatedSupplyList_` | `+0x20` | `SupplyStatus`: `+0x20` mstSupplyId (i32), `+0x30` isAcquired (bool), `+0x34` acquiredCount (i32) |
| `updatedCharacterList_` | `+0x30` | `CharacterStatus`: `+0x18` mstCharacterId (i32), `+0x40` intimacy (i32), `+0x44` isAcquired (bool), `+0x45` isSelected (bool) |
| `updatedCharacterSkinList_` | `+0x38` | `CharacterSkinStatus`: `+0x18` mstSkinId (i32), `+0x1C` mstCharacterId (i32), `+0x20` isAcquired (bool), `+0x21` isSelected (bool) |

Writes per element:

- Supply: only the **decoration band** is touched (the band check is by mstSupplyId
  range). For matching ids, `isAcquired := 1` and `acquiredCount := max(1, current)`.
- Character: `isAcquired := 1`. **Voice Unlock** also pins `intimacy` here to the
  unlock threshold so the voice cell UI doesn't grey out.
- Skin: `isAcquired := 1`.

After the write phase, `kiou_applyPersistedSelectionToLists(...)` (declared in
`Internal.h`) re-asserts the user's persisted skin/character choice on the
`isSelected` flags — this is the read path of the Bypass Character flow.

Currency, character-purchase, and skin-currency repeated fields are never
visited. The gate is `kiou_featureEnabled(KIOU_FEATURE_ITEM_UNLOCK)`.

---

## Bypass Character (`Hook_SelectCharacter.m`)

Two hooks coupled by an `NSUserDefaults` cache (`kiou_persistedSelection`).

### A) Outbound rewrite — `GameServiceClient.SelectCharacterAsync(req, opts)`

**RVA `0x5CA7C90`**. Right before the call hits the wire:

1. Read `req.mstCharacterSkinId_` (`+0x18` on the request object).
2. If it isn't `KIOU_SAFE_SKIN_ID` (defined as `1` in `Internal.h`), remember
   it via `kiou_setPersistedSelection(real)`, then overwrite the field with
   `KIOU_SAFE_SKIN_ID` so the server only ever sees a legal request.

### B) Reply re-skin — `SelectCharacterReply.InternalMergeFrom`

**RVA `0x5C26DCC`**. After decode, the same
`kiou_applyPersistedSelectionToLists(...)` helper runs on the reply's
`updatedCharacterList` / `updatedCharacterSkinList`, flipping `isSelected` so
the UI shows the user's intended skin everywhere it reads "currently
equipped".

The persisted id also gets stitched back in by the **Item Unlock** hook
(every `SyncItemListReply`) and the **Match avatar** hook below, so the swap
is consistent across the title screen, the match room, and the home utility
strip.

Gate: `kiou_featureEnabled(KIOU_FEATURE_CHAR_BYPASS)`.

---

## Match avatar (`Hook_MatchingPlayer.m`)

Hook on `ShogiMatchingPlayerStatus.InternalMergeFrom` at **RVA `0x5B4CAEC`**.

The match-room server sends one of these per side (`blackPlayer`,
`whitePlayer`). Avatar fields on the decoded message:

| Offset | Field |
|---|---|
| `+0x18` | `userId` (il2cpp `string`) |
| `+0x40` | `mstCharacterId` (i32) |
| `+0x44` | `mstCharacterSkinId` (i32) |

Identifying the local player is by `userId` match against
`kiou_selfUserId()`. The id is captured upstream (see Hook_SyncItemList's
self-id sniff) and persisted in `NSUserDefaults`. If the cached self-id is
empty (fresh install before the first sync) we fall back to a positional
heuristic that prefers the first row.

When the row is the local player, `mstCharacterSkinId` is overwritten with
`kiou_persistedSelection()`, and **also** `KIOU_FEATURE_MATCH_ASSIST` toggles
on `_useBeginnerSupport` if applicable — this is how the Beginner Support
flag fans out to the match-room player status.

Gates: `kiou_featureEnabled(KIOU_FEATURE_CHAR_BYPASS)` for the skin write,
`KIOU_FEATURE_MATCH_ASSIST` for the assist write.

---

## Premium User (`Hook_PremiumUnlock.m`)

Three patches because retail consults the premium flag through different
paths depending on which kifu surface you're on. Setting one alone proved
insufficient during analysis; we set all three.

| Site | Class.method | RVA | Override |
|---|---|---|---|
| a | `KifuDetailModel.IsPremiumUser()` | `0x585B25C` | returns `true` |
| b | `GetShogiHistoryDetailListReply.InternalMergeFrom` | `0x5C01328` | sets `isPremiumUser_` field on `self` after decode |
| c | `GetShogiHistoryDetailListReply.get_IsPremiumUser` | `0x5C00D88` | returns `true` |

Gate: `kiou_featureEnabled(KIOU_FEATURE_PREMIUM_UNLOCK)`.

---

## Beginner Support (`Hook_AssistEnable.m` + match-room write in `Hook_MatchingPlayer.m`)

Hook_AssistEnable hooks the two ResolvedBeginnerSupport getters:

| Site | RVA | Override |
|---|---|---|
| `ResolvedBeginnerSupport.get_Enabled` | `0x593E630` | returns `true` |
| `ResolvedBeginnerSupport.get_Depth` | `0x593E650` | returns `kiou_assistDepth()` |

`get_Enabled` is the gate the rest of the GameOrchestrator pipeline reads when
deciding whether to wire the in-game `BeginnerSupportEvaluator` and
`BookHintProvider` into `BoardPresenter` / `EffectPresenter`. Pinning it true
in non-assist modes (ranked, etc.) is what surfaces the hint arrow there.

The depth override is belt-and-braces alongside the BSE ctor write in
`Hook_AssistTune.m`; whichever path the engine ends up reading from, it
lands on the same number.

The match-room toggle write lives in `Hook_MatchingPlayer.m` (see above).

Gate: `kiou_featureEnabled(KIOU_FEATURE_ASSIST_ENABLE)`.

---

## Always Hint Arrow + Engine tuning (`Hook_AssistTune.m`)

Two hooks on `Project.Game.Presentation.BeginnerSupportEvaluator`. Field
layout from `dump.cs:1213329`:

```
+0x18 _analysisDepth     (i32, retail default 5)
+0x1C _warningThresholdCp
+0x20 _hintMoveThresholdCp
+0x24 _greatMoveThresholdCp
+0x28 _engineSkillLevel  (i32, retail default 20)
+0x2C _verboseLog
+0x30 _sessionGate
+0x38 _session           (NativeSyncSession reference, lazy)
…
```

### A) ctor — `BSE..ctor(string evalPath, BeginnerSupportSettings settings)`

**RVA `0x597A448`**. Let the orig run (it allocates caches, captures the
eval path, reads the ScriptableObject), then overwrite:

- `+0x18 _analysisDepth   := kiou_assistDepth()`        (default 16)
- `+0x28 _engineSkillLevel := kiou_assistSkillLevel()`  (default 20)

All other fields are untouched.

### B) lazy session init — `BSE.EnsureInitializedLocked()`

**RVA `0x597BAFC`**. Retail brings the underlying Rshogi
`NativeSyncSession` up here on first eval, but never calls `SetHashSize`. We
piggy-back: after orig finishes, if `self+0x38` is non-NULL, invoke
`NativeSyncSession.SetHashSize(int mb)` via direct ABI at
**RVA `0x5D320E0`** with `(session, kiou_assistHashMB(), NULL)`. The trailing
`MethodInfo*` slot is NULL — that signature only marshals through the il2cpp
codegen wrapper, no MethodInfo parameter access. Same shape as the
`Tf.SetSiblingIndex` direct call in `Hook_FriendUnhide.m`.

Hash preset table (in `Persistence.m`):

```
{ 64, 128, 256, 512, 1024 } MB
```

`kiou_assistHashIndex()` stores the **index** (default 1 = 128 MB), so the UI
stepper can only emit sanctioned values; `kiou_assistHashMB()` reads it back
through the table.

Gate: `kiou_featureEnabled(KIOU_FEATURE_ASSIST_ENABLE)` for the depth and
skill writes. The hash hook always runs while the toggle is on; with the
toggle off, the evaluator falls back to its ScriptableObject defaults and
the native session keeps Rshogi's compiled-in (~16 MB) hash.

### Investigation note: no node / time cap

`NativeSyncSession.SearchFull/Multi*` and the underlying `NativeUsi.SyncSearch*`
externs only take `depth` — no `nodes`, no `movetime`. No caller anywhere in
`dump.cs` invokes `SetOption(string, string)` either. The
`TsumeSolver.MaxNodes = 10000000` is unrelated (mate-search ceiling, not the
NNUE eval engine). So depth is the only relevant knob and raising it can't
get silently capped by the native side.

---

## Voice Unlock (`Hook_VoiceUnlock.m` + intimacy pin in `Hook_SyncItemList.m`)

Two prongs.

### Playback gate

`CharacterVoicePlayer.SatisfiesRule(VoiceRuleType) -> bool` at
**RVA `0x582B88C`**. Forced to return `true`. This is the playback
chokepoint called from `TryPlay` / `PlayInternal` and from `FindRule`, so
locked cues actually fire instead of being skipped.

### UI lock indicator

`VoiceCellModel.get_IsLocked() -> bool` at **RVA `0x584ADC0`**. Forced to
return `false` so the cells render unlocked.

### Intimacy floor (in Hook_SyncItemList)

Inside the Item Unlock loop over characters, when Voice Unlock is on, each
`CharacterStatus.intimacy` (`+0x40`) is pinned to at least the unlock
threshold. Without this the cells render unlocked but the underlying voice
list still hides lines gated by intimacy level.

Gate: `kiou_featureEnabled(KIOU_FEATURE_VOICE_UNLOCK)`.

---

## Collection observer (`Hook_Collection.m`)

Hook on `UpdateCollectionPresetReply.InternalMergeFrom` at
**RVA `0x5C4065C`**. Pure observation: walks the
`updatedUserCollectionList_` (`+0x18`) repeated field, and for each
`UserCollectionStatus.presetList_` (`+0x20`) logs the preset payload
(`presetNumber`, `mstIconId`, `mstIconFrameId`, `mstAchievementId`,
`mstShogiPieceId`, `mstShogiBoardId`). No writes.

This exists so we can map preset state changes in the log when other hooks
look like they should have flipped one and didn't.

---

## Title version label (`Hook_Version.m`)

Hook on `TitleScene.<OnActivateAsync>d__10.MoveNext` at
**RVA `0x5DCC728`**. Reads `_appVersionFormat` (`TitleScene + 0x40`, il2cpp
`String*`), appends `+ (commit)` using the build-time
`KIOU_EDITOR_COMMIT` macro, and writes it back **before** the orig calls
`SetTextFormat`. Cosmetic: lets us tell at a glance which dylib build is
running on the device.
