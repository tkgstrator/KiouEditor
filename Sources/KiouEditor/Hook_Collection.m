#import "Internal.h"

// ===========================================================================
// HOOK 2: UpdateCollectionPresetReply.InternalMergeFrom(ref ParseContext)
//   RVA 0x5C4065C from UnityFramework base.
//
//   self + 0x18 = updatedUserCollectionList_ (RepeatedField<UserCollectionStatus>)
//   UserCollectionStatus + 0x20 = presetList_ (RepeatedField<UserCollectionPresetStatus>)
//   UserCollectionPresetStatus: +0x18 presetNumber, +0x1C mstIconId, +0x20 mstIconFrameId,
//      +0x24 mstAchievementId, +0x28 mstShogiPieceId, +0x2C mstShogiBoardId,
//      +0x30 mstShogiIngameBgmId (all int32)
//
// OBSERVATION ONLY. No writes.
// ===========================================================================

#define RVA_UPDATE_COLLECTION_PRESET_REPLY_MERGE 0x5C4065C

typedef void (*InternalMergeFrom_t)(void *self, void *parseContext);

static InternalMergeFrom_t orig_UpdateCollectionPresetReply_merge = NULL;

static void hook_UpdateCollectionPresetReply_merge(void *self, void *parseContext) {
    if (orig_UpdateCollectionPresetReply_merge) {
        orig_UpdateCollectionPresetReply_merge(self, parseContext);
    }

    if (g_inHook) return;
    g_inHook = 1;
    @try {
        if (ptrLooksValid(self)) {
            void *collArr = NULL;
            int32_t collCount = 0;
            if (readRepeatedField(self, 0x18, &collArr, &collCount)) {
                file_log([NSString stringWithFormat:
                          @"[UpdateCollectionPresetReply] updatedUserCollectionList count=%d", collCount]);
                for (int32_t i = 0; i < collCount; i++) {
                    void *coll = readArrayElem(collArr, i);
                    if (!coll) continue;
                    void *presetArr = NULL;
                    int32_t presetCount = 0;
                    if (!readRepeatedField(coll, 0x20, &presetArr, &presetCount)) {
                        file_log([NSString stringWithFormat:
                                  @"[UpdateCollectionPresetReply]   [%d] presetList unreadable/empty", i]);
                        continue;
                    }
                    file_log([NSString stringWithFormat:
                              @"[UpdateCollectionPresetReply]   [%d] presetList count=%d", i, presetCount]);
                    for (int32_t j = 0; j < presetCount; j++) {
                        void *preset = readArrayElem(presetArr, j);
                        if (!preset) continue;
                        int32_t presetNumber        = readI32(preset, 0x18);
                        int32_t mstIconId           = readI32(preset, 0x1C);
                        int32_t mstIconFrameId      = readI32(preset, 0x20);
                        int32_t mstAchievementId    = readI32(preset, 0x24);
                        int32_t mstShogiPieceId     = readI32(preset, 0x28);
                        int32_t mstShogiBoardId     = readI32(preset, 0x2C);
                        int32_t mstShogiIngameBgmId = readI32(preset, 0x30);
                        file_log([NSString stringWithFormat:
                                  @"[UpdateCollectionPresetReply]     preset[%d] num=%d icon=%d frame=%d "
                                  @"achievement=%d piece=%d board=%d bgm=%d",
                                  j, presetNumber, mstIconId, mstIconFrameId,
                                  mstAchievementId, mstShogiPieceId, mstShogiBoardId,
                                  mstShogiIngameBgmId]);
                    }
                }
            } else {
                file_log(@"[UpdateCollectionPresetReply] updatedUserCollectionList unreadable/empty");
            }
        }
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[UpdateCollectionPresetReply] exception: %@", e]);
    }
    g_inHook = 0;
}

void install_Collection_hook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_UPDATE_COLLECTION_PRESET_REPLY_MERGE;
    MSHookFunction((void *)addr,
                   (void *)hook_UpdateCollectionPresetReply_merge,
                   (void **)&orig_UpdateCollectionPresetReply_merge);
    file_log([NSString stringWithFormat:
              @"UpdateCollectionPresetReply.InternalMergeFrom hooked @0x%lx (base+0x%x)",
              (unsigned long)addr, RVA_UPDATE_COLLECTION_PRESET_REPLY_MERGE]);
}
