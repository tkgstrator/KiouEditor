#import "Internal.h"

// ===========================================================================
// HOOK 1: SyncItemListReply.InternalMergeFrom(ref ParseContext)
//   RVA 0x5C37034 from UnityFramework base.
//   void InternalMergeFrom(void *self /*x0*/, void *parseContext /*x1*/)
//   Call orig first (decode completes), then read self.
//
//   self + 0x20 = updatedSupplyList_ (RepeatedField<SupplyStatus>)
//   SupplyStatus: +0x20 mstSupplyId_(i32), +0x30 isAcquired_(bool), +0x34 acquiredCount_(i32)
//
//   self + 0x28 = updatedCharacterList_ (RepeatedField<CharacterStatus>)
//   CharacterStatus: +0x18 mstCharacterId_(i32), +0x1C intimacyLevel_(i32),
//      +0x20 isContract_(bool), +0x30 isAcquired_(bool),
//      +0x40 acquiredCount_(i32), +0x46 isContractAvailable_(bool),
//      +0x47 isIntimacyAtMax_(bool)
//      (NEVER touch: +0x44 isFavorite_, +0x45 isSelected_,
//       intimacy{Total,NextLevel,PointInLevel,PointToNextLevel,ProgressRate})
//
//   self + 0x30 = updatedCharacterSkinList_ (RepeatedField<CharacterSkinStatus>)
//   CharacterSkinStatus: +0x18 mstCharacterSkinId_(i32), +0x1C mstCharacterId_(i32),
//      +0x20 isAcquired_(bool), +0x30 acquiredCount_(i32)
//      (NEVER touch: +0x21 isSelected_)
// ===========================================================================

#define RVA_SYNC_ITEM_LIST_REPLY_MERGE 0x5C37034

typedef void (*InternalMergeFrom_t)(void *self, void *parseContext);

static InternalMergeFrom_t orig_SyncItemListReply_merge = NULL;

// MstSupplyId band classification for readability.
static const char *supplyBand(int32_t id) {
    if (id >= 500001 && id <= 500012) return "icon";
    if (id == 600001)                 return "frame";
    if (id >= 900001 && id <= 900015) return "title";
    if (id >= 200001 && id <= 200013) return "piece";
    if (id >= 400001 && id <= 400013) return "board";
    if (id >= 300001 && id <= 300008) return "bgm";
    return "other";
}

// Decoration band check for the ownership tamper. Currency / character / skin
// Supplies must NEVER be touched, so we strictly restrict writes to these bands
// (mirrors hook_kiou_supply_unlock.js DECORATION_BANDS exactly):
//   icon 500001-500012 / frame 600001 / title 900001-900015 /
//   piece 200001-200013 / board 400001-400013 / bgm 300001-300008
static inline BOOL isDecorationSupply(int32_t sid) {
    return (sid > 500000 && sid < 501000) ||
           (sid > 600000 && sid < 601000) ||
           (sid > 900000 && sid < 901000) ||
           (sid > 200000 && sid < 201000) ||
           (sid > 400000 && sid < 401000) ||
           (sid > 300000 && sid < 301000);
}

// Plausible master id for a character / character-skin element. Used as a
// light sanity gate so we never tamper a half-decoded intermediate element.
static inline BOOL isPlausibleMstId(int32_t id) {
    return id >= 1 && id <= 100000;
}

static void hook_SyncItemListReply_merge(void *self, void *parseContext) {
    // Let the original decode complete first.
    if (orig_SyncItemListReply_merge) {
        orig_SyncItemListReply_merge(self, parseContext);
    }

    if (g_inHook) return;
    g_inHook = 1;
    @try {
        if (!ptrLooksValid(self)) goto done;
        bool itemUnlock  = kiou_featureEnabled(KIOU_FEATURE_ITEM_UNLOCK);
        // Intimacy-pin is part of Voice Unlock: maxing intimacyLevel makes the
        // CharacterVoicePlayer rule lookups match Level1..Level5 + Complete
        // out of the box, so the two are toggled together.
        bool intimacyMax = kiou_featureEnabled(KIOU_FEATURE_VOICE_UNLOCK);
        bool charBypass  = kiou_featureEnabled(KIOU_FEATURE_CHAR_BYPASS);

        // Supplies block. Pure observation when itemUnlock is off.
        if (itemUnlock) {
            void *arr = NULL;
            int32_t count = 0;
            if (readRepeatedField(self, 0x20, &arr, &count)) {
                file_log([NSString stringWithFormat:
                          @"[SyncItemListReply] updatedSupplyList count=%d", count]);
                int32_t decoTotal    = 0;
                int32_t flipped      = 0;
                int32_t alreadyOwned = 0;
                for (int32_t i = 0; i < count; i++) {
                    void *elem = readArrayElem(arr, i);
                    if (!elem) continue;
                    int32_t mstSupplyId   = readI32(elem, 0x20);
                    uint8_t isAcquired    = readU8(elem, 0x30);
                    int32_t acquiredCount = readI32(elem, 0x34);
                    file_log([NSString stringWithFormat:
                              @"[SyncItemListReply]   [%d] mstSupplyId=%d (%s) isAcquired=%d acquiredCount=%d",
                              i, mstSupplyId, supplyBand(mstSupplyId),
                              (int)isAcquired, acquiredCount]);

                    if (!isDecorationSupply(mstSupplyId)) continue;
                    decoTotal++;
                    if (isAcquired) {
                        alreadyOwned++;
                    } else {
                        writeU8(elem, 0x30, 1);
                        if (acquiredCount <= 0) writeI32(elem, 0x34, 1);
                        flipped++;
                    }
                }
                file_log([NSString stringWithFormat:
                          @"[UNLOCK] decoration total=%d already_owned=%d unlocked=%d owned_after=%d",
                          decoTotal, alreadyOwned, flipped, alreadyOwned + flipped]);
            } else {
                file_log(@"[SyncItemListReply] updatedSupplyList unreadable/empty");
            }
        }

        // Characters (updatedCharacterList_ @0x28). Walks the list when any
        // of itemUnlock / intimacyMax is on; flips only the fields the
        // active flags own.
        if (itemUnlock || intimacyMax) {
            void *charArr = NULL;
            int32_t charCount = 0;
            if (readRepeatedField(self, 0x28, &charArr, &charCount)) {
                file_log([NSString stringWithFormat:
                          @"[UNLOCK-CHAR] updatedCharacterList count=%d", charCount]);
                int32_t charTotal    = 0;
                int32_t contractFlip = 0;
                int32_t acquiredFlip = 0;
                int32_t intimacyFlip = 0;
                for (int32_t i = 0; i < charCount; i++) {
                    void *elem = readArrayElem(charArr, i);
                    if (!elem) continue;
                    int32_t mstCharacterId = readI32(elem, 0x18);
                    int32_t intimacyLevel  = readI32(elem, 0x1C);
                    uint8_t isContract     = readU8(elem, 0x20);
                    uint8_t isAcquired     = readU8(elem, 0x30);
                    file_log([NSString stringWithFormat:
                              @"[UNLOCK-CHAR]   [%d] mstCharacterId=%d intimacyLevel=%d isContract=%d isAcquired=%d",
                              i, mstCharacterId, intimacyLevel,
                              (int)isContract, (int)isAcquired]);

                    if (!isPlausibleMstId(mstCharacterId)) continue;
                    charTotal++;

                    if (itemUnlock) {
                        if (!isContract) { writeU8(elem, 0x20, 1); contractFlip++; }
                        if (!isAcquired) { writeU8(elem, 0x30, 1); acquiredFlip++; }
                        writeU8(elem, 0x46, 1);
                        if (readI32(elem, 0x40) <= 0) writeI32(elem, 0x40, 1);
                    }
                    if (intimacyMax) {
                        // CharacterVoicePlayer is built off intimacyLevel; max
                        // it to 5 so every cue rule passes.
                        if (intimacyLevel < 5) { writeI32(elem, 0x1C, 5); intimacyFlip++; }
                        writeU8(elem, 0x47, 1);
                    }
                }
                file_log([NSString stringWithFormat:
                          @"[UNLOCK-CHAR] characters total=%d contract_unlocked=%d acquired_unlocked=%d intimacy_maxed=%d",
                          charTotal, contractFlip, acquiredFlip, intimacyFlip]);
            } else {
                file_log(@"[UNLOCK-CHAR] updatedCharacterList unreadable/empty");
            }
        }

        // Character skins (updatedCharacterSkinList_ @0x30) - itemUnlock only.
        if (itemUnlock) {
            void *skinArr = NULL;
            int32_t skinCount = 0;
            if (readRepeatedField(self, 0x30, &skinArr, &skinCount)) {
                file_log([NSString stringWithFormat:
                          @"[UNLOCK-CHAR] updatedCharacterSkinList count=%d", skinCount]);
                int32_t skinTotal = 0;
                int32_t skinFlip  = 0;
                for (int32_t i = 0; i < skinCount; i++) {
                    void *elem = readArrayElem(skinArr, i);
                    if (!elem) continue;
                    int32_t mstSkinId = readI32(elem, 0x18);
                    int32_t mstCharId = readI32(elem, 0x1C);
                    uint8_t isAcquired = readU8(elem, 0x20);
                    file_log([NSString stringWithFormat:
                              @"[UNLOCK-CHAR]   skin[%d] mstSkinId=%d mstCharId=%d isAcquired=%d",
                              i, mstSkinId, mstCharId, (int)isAcquired]);

                    if (!isPlausibleMstId(mstSkinId)) continue;
                    skinTotal++;

                    if (!isAcquired) { writeU8(elem, 0x20, 1); skinFlip++; }
                    if (readI32(elem, 0x30) <= 0) writeI32(elem, 0x30, 1);
                }
                file_log([NSString stringWithFormat:
                          @"[UNLOCK-CHAR] skins total=%d unlocked=%d",
                          skinTotal, skinFlip]);
            } else {
                file_log(@"[UNLOCK-CHAR] updatedCharacterSkinList unreadable/empty");
            }
        }

        // Persisted SelectCharacter stitch - flag-move path.
        if (charBypass) {
            void *charArr = NULL;
            int32_t charCount = 0;
            readRepeatedField(self, 0x28, &charArr, &charCount);
            void *skinArr = NULL;
            int32_t skinCount = 0;
            readRepeatedField(self, 0x30, &skinArr, &skinCount);
            kiou_applyPersistedSelectionToLists(charArr, charCount,
                                                skinArr, skinCount);
        }
    done:;
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[SyncItemListReply] exception: %@", e]);
    }
    g_inHook = 0;
}

void install_SyncItemList_hook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_SYNC_ITEM_LIST_REPLY_MERGE;
    MSHookFunction((void *)addr,
                   (void *)hook_SyncItemListReply_merge,
                   (void **)&orig_SyncItemListReply_merge);
    file_log([NSString stringWithFormat:
              @"SyncItemListReply.InternalMergeFrom hooked @0x%lx (base+0x%x)",
              (unsigned long)addr, RVA_SYNC_ITEM_LIST_REPLY_MERGE]);
}
