#import "Internal.h"

// ===========================================================================
// HOOK 4 + HOOK 5: SelectCharacter bypass (server stays clean).
//
// Strategy (mirrors hook_kiou_selectchar_bypass.js):
//   - HOOK 4 sits on GameServiceClient.SelectCharacterAsync. If the user
//     asked for a skin other than KIOU_SAFE_SKIN_ID, we remember that intent
//     in NSUserDefaults and rewrite the outgoing Args.mstCharacterSkinId_ to
//     KIOU_SAFE_SKIN_ID. The server sees only a legal request and never
//     returns -40302.
//   - HOOK 5 sits on SelectCharacterReply.InternalMergeFrom. After the
//     original decode, it walks updatedCharacterList_ + updatedCharacterSkinList_
//     and rewrites every is_selected entry to advertise the persisted skin id.
//
// Persistence: NSUserDefaults under the standard suite (per-bundle plist).
// 0 means "no override" -> let the server's value through. This survives
// process restart but lives inside KIOU's sandbox, so an app reinstall wipes
// it (acceptable for this tool).
//
//   GameServiceClient.SelectCharacterAsync(req, opts)        RVA 0x5CA7C90
//     x1 = SelectCharacterArgs*
//     SelectCharacterArgs.mstCharacterSkinId_ @0x18
//
//   SelectCharacterReply.InternalMergeFrom(ref ParseContext) RVA 0x5C26DCC
//     SelectCharacterReply.updatedCharacterList_     @0x18 (RF<CharacterStatus>)
//     SelectCharacterReply.updatedCharacterSkinList_ @0x20 (RF<CharacterSkinStatus>)
//     CharacterStatus:     mstCharacterId @0x18, isSelected @0x45
//     CharacterSkinStatus: mstSkinId @0x18, mstCharacterId @0x1C,
//                          isAcquired @0x20, isSelected @0x21
// ===========================================================================

#define RVA_SELECT_CHARACTER_ASYNC      0x5CA7C90
#define RVA_SELECT_CHARACTER_REPLY_MERGE 0x5C26DCC

#define OFF_ARGS_SKIN_ID                0x18
#define OFF_REPLY_CHAR_LIST             0x18
#define OFF_REPLY_SKIN_LIST             0x20

#define OFF_CHAR_MST_ID                 0x18
#define OFF_CHAR_IS_ACQUIRED            0x30
#define OFF_CHAR_IS_SELECTED            0x45

#define OFF_SKIN_MST_SKIN_ID            0x18
#define OFF_SKIN_MST_CHAR_ID            0x1C
#define OFF_SKIN_IS_ACQUIRED            0x20
#define OFF_SKIN_IS_SELECTED            0x21

static NSString *const kPersistedSelectionKey = @"kiou_editor.persisted_skin_id";

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

int32_t kiou_persistedSelection(void) {
    NSInteger v = [[NSUserDefaults standardUserDefaults]
                   integerForKey:kPersistedSelectionKey];
    if (v <= 0 || v > 100000) return 0;
    return (int32_t)v;
}

void kiou_setPersistedSelection(int32_t skinId) {
    if (skinId <= 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPersistedSelectionKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setInteger:skinId
                                                   forKey:kPersistedSelectionKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ---------------------------------------------------------------------------
// List rewrite helper shared with Hook_SyncItemList.
// ---------------------------------------------------------------------------

void kiou_applyPersistedSelectionToLists(void *charArr, int32_t charCount,
                                        void *skinArr, int32_t skinCount) {
    int32_t target = kiou_persistedSelection();
    if (target == 0) return;  // no override active

    // Hybrid strategy:
    //  - If the target id already exists in the list (e.g. SyncItemList full
    //    inventory): MOVE the is_selected flag onto that entry. Avoids
    //    duplicate ids which broke client-side validation (the "tap to start"
    //    generic error).
    //  - Else (e.g. SelectCharacterReply partial list that only carries the
    //    SAFE_ID swap result): REWRITE the currently-selected entry's id to
    //    target. Best-effort UI override when no target entry is in the list.
    int32_t flagMoves = 0;
    int32_t idRewrites = 0;

    {
        int32_t curIdx = -1, tgtIdx = -1;
        for (int32_t i = 0; i < skinCount; i++) {
            void *elem = readArrayElem(skinArr, i);
            if (!elem) continue;
            if (readU8(elem, OFF_SKIN_IS_SELECTED) == 1) curIdx = i;
            if (readI32(elem, OFF_SKIN_MST_SKIN_ID) == target) tgtIdx = i;
        }
        if (tgtIdx >= 0) {
            if (curIdx != tgtIdx) {
                if (curIdx >= 0) {
                    writeU8(readArrayElem(skinArr, curIdx),
                            OFF_SKIN_IS_SELECTED, 0);
                }
                void *tgt = readArrayElem(skinArr, tgtIdx);
                writeU8(tgt, OFF_SKIN_IS_SELECTED, 1);
                if (readU8(tgt, OFF_SKIN_IS_ACQUIRED) == 0) {
                    writeU8(tgt, OFF_SKIN_IS_ACQUIRED, 1);
                }
                flagMoves++;
            }
        } else if (curIdx >= 0) {
            void *cur = readArrayElem(skinArr, curIdx);
            writeI32(cur, OFF_SKIN_MST_SKIN_ID, target);
            writeI32(cur, OFF_SKIN_MST_CHAR_ID, target);
            if (readU8(cur, OFF_SKIN_IS_ACQUIRED) == 0) {
                writeU8(cur, OFF_SKIN_IS_ACQUIRED, 1);
            }
            idRewrites++;
        }
    }

    {
        int32_t curIdx = -1, tgtIdx = -1;
        for (int32_t i = 0; i < charCount; i++) {
            void *elem = readArrayElem(charArr, i);
            if (!elem) continue;
            if (readU8(elem, OFF_CHAR_IS_SELECTED) == 1) curIdx = i;
            if (readI32(elem, OFF_CHAR_MST_ID) == target) tgtIdx = i;
        }
        if (tgtIdx >= 0) {
            if (curIdx != tgtIdx) {
                if (curIdx >= 0) {
                    writeU8(readArrayElem(charArr, curIdx),
                            OFF_CHAR_IS_SELECTED, 0);
                }
                void *tgt = readArrayElem(charArr, tgtIdx);
                writeU8(tgt, OFF_CHAR_IS_SELECTED, 1);
                if (readU8(tgt, OFF_CHAR_IS_ACQUIRED) == 0) {
                    writeU8(tgt, OFF_CHAR_IS_ACQUIRED, 1);
                }
                flagMoves++;
            }
        } else if (curIdx >= 0) {
            void *cur = readArrayElem(charArr, curIdx);
            writeI32(cur, OFF_CHAR_MST_ID, target);
            if (readU8(cur, OFF_CHAR_IS_ACQUIRED) == 0) {
                writeU8(cur, OFF_CHAR_IS_ACQUIRED, 1);
            }
            idRewrites++;
        }
    }

    if (flagMoves > 0 || idRewrites > 0) {
        file_log([NSString stringWithFormat:
                  @"[SELECT] applied persisted skinId=%d (flag_moves=%d id_rewrites=%d)",
                  target, flagMoves, idRewrites]);
    }
}

// ---------------------------------------------------------------------------
// HOOK 4: SelectCharacterAsync request swap.
//
// Convention: arm64 calling convention, x0 = self (client), x1 = args.
// We rewrite args->mstCharacterSkinId_ in place before forwarding, so the
// server only ever receives KIOU_SAFE_SKIN_ID.
// ---------------------------------------------------------------------------

typedef void *(*SelectCharacterAsync_t)(void *self, void *args, void *opts,
                                        void *a3, void *a4, void *a5);

static SelectCharacterAsync_t orig_SelectCharacterAsync = NULL;

static void *hook_SelectCharacterAsync(void *self, void *args, void *opts,
                                       void *a3, void *a4, void *a5) {
    if (ptrLooksValid(args)) {
        int32_t requested = readI32(args, OFF_ARGS_SKIN_ID);
        if (requested > 0 && requested != KIOU_SAFE_SKIN_ID) {
            kiou_setPersistedSelection(requested);
            writeI32(args, OFF_ARGS_SKIN_ID, KIOU_SAFE_SKIN_ID);
            file_log([NSString stringWithFormat:
                      @"[SELECT][REQ] user=%d -> server=%d (persisted)",
                      requested, KIOU_SAFE_SKIN_ID]);
        } else if (requested == KIOU_SAFE_SKIN_ID) {
            // The user explicitly picked the safe skin. Drop any override.
            if (kiou_persistedSelection() != 0) {
                kiou_setPersistedSelection(0);
                file_log(@"[SELECT][REQ] user picked SAFE_ID; cleared persisted override");
            } else {
                file_log([NSString stringWithFormat:
                          @"[SELECT][REQ] passthrough skinId=%d", requested]);
            }
        }
    }
    return orig_SelectCharacterAsync(self, args, opts, a3, a4, a5);
}

// ---------------------------------------------------------------------------
// HOOK 5: SelectCharacterReply.InternalMergeFrom.
//
// Let the original decode complete, then rewrite is_selected entries in both
// returned lists using the same helper Hook_SyncItemList uses on launch.
// ---------------------------------------------------------------------------

typedef void (*ReplyMergeFrom_t)(void *self, void *parseContext);

static ReplyMergeFrom_t orig_SelectCharacterReply_merge = NULL;

static void hook_SelectCharacterReply_merge(void *self, void *parseContext) {
    if (orig_SelectCharacterReply_merge) {
        orig_SelectCharacterReply_merge(self, parseContext);
    }
    if (!ptrLooksValid(self)) return;

    @try {
        void *charArr = NULL;
        int32_t charCount = 0;
        readRepeatedField(self, OFF_REPLY_CHAR_LIST, &charArr, &charCount);

        void *skinArr = NULL;
        int32_t skinCount = 0;
        readRepeatedField(self, OFF_REPLY_SKIN_LIST, &skinArr, &skinCount);

        file_log([NSString stringWithFormat:
                  @"[SELECT][RESP] charCount=%d skinCount=%d persisted=%d",
                  charCount, skinCount, kiou_persistedSelection()]);

        kiou_applyPersistedSelectionToLists(charArr, charCount, skinArr, skinCount);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[SELECT][RESP] exception: %@", e]);
    }
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------

void install_SelectCharacter_hook(uintptr_t unityBase) {
    {
        uintptr_t addr = unityBase + RVA_SELECT_CHARACTER_ASYNC;
        MSHookFunction((void *)addr,
                       (void *)hook_SelectCharacterAsync,
                       (void **)&orig_SelectCharacterAsync);
        file_log([NSString stringWithFormat:
                  @"SelectCharacterAsync hooked @0x%lx (base+0x%x) SAFE_ID=%d persisted=%d",
                  (unsigned long)addr, RVA_SELECT_CHARACTER_ASYNC,
                  KIOU_SAFE_SKIN_ID, kiou_persistedSelection()]);
    }
    {
        uintptr_t addr = unityBase + RVA_SELECT_CHARACTER_REPLY_MERGE;
        MSHookFunction((void *)addr,
                       (void *)hook_SelectCharacterReply_merge,
                       (void **)&orig_SelectCharacterReply_merge);
        file_log([NSString stringWithFormat:
                  @"SelectCharacterReply.InternalMergeFrom hooked @0x%lx (base+0x%x)",
                  (unsigned long)addr, RVA_SELECT_CHARACTER_REPLY_MERGE]);
    }
}
