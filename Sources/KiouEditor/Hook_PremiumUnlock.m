#import "Internal.h"

// ===========================================================================
// HOOK 7a-c: force isPremiumUser = true across the kifu-detail flow.
//
// Three call sites observed in dump.cs:
//   a) KifuDetailModel.IsPremiumUser()                       RVA 0x585B25C
//      Final getter on the model. Hooked first; alone proved insufficient,
//      so we also patch the upstream sources.
//   b) GetShogiHistoryDetailListReply.InternalMergeFrom      RVA 0x5C01328
//      The protobuf reply carrying the server's premium flag at +0x20.
//      Writing 1 there right after decode means every later reader (getter,
//      direct field access, InitializeAsync parameter) sees true.
//   c) GetShogiHistoryDetailListReply.get_IsPremiumUser      RVA 0x5C00D88
//      Belt-and-braces: even if (b) misses (e.g. a reply path that doesn't
//      hit InternalMergeFrom), the getter still reports premium.
//
// Net effect on the match-history detail popup:
//   - the bottom "_analysisPassBuyButton" purchase banner disappears
//   - tapping the analyse button runs RunAnalysisFlowAsync (local NNUE)
//     instead of RunPassPurchaseFlowAsync
// All client-side; no outbound request changes.
// ===========================================================================

#define RVA_KIFU_DETAIL_MODEL_IS_PREMIUM_USER            0x585B25C
#define RVA_SHOGI_HISTORY_DETAIL_REPLY_MERGE             0x5C01328
#define RVA_SHOGI_HISTORY_DETAIL_REPLY_GET_PREMIUM       0x5C00D88

#define OFF_SHOGI_HISTORY_DETAIL_REPLY_IS_PREMIUM_USER   0x20

typedef bool (*IsPremiumUser_t)(void *self);
typedef void (*ReplyMergeFrom_t)(void *self, void *parseContext);

static IsPremiumUser_t  orig_KifuDetailModel_IsPremiumUser = NULL;
static IsPremiumUser_t  orig_HistoryDetailReply_IsPremiumUser = NULL;
static ReplyMergeFrom_t orig_HistoryDetailReply_merge = NULL;

static bool hook_KifuDetailModel_IsPremiumUser(void *self) {
    if (!kiou_featureEnabled(KIOU_FEATURE_PREMIUM_UNLOCK)) {
        return orig_KifuDetailModel_IsPremiumUser
            ? orig_KifuDetailModel_IsPremiumUser(self) : false;
    }
    (void)self;
    return true;
}

static bool hook_HistoryDetailReply_IsPremiumUser(void *self) {
    if (!kiou_featureEnabled(KIOU_FEATURE_PREMIUM_UNLOCK)) {
        return orig_HistoryDetailReply_IsPremiumUser
            ? orig_HistoryDetailReply_IsPremiumUser(self) : false;
    }
    (void)self;
    return true;
}

static void hook_HistoryDetailReply_merge(void *self, void *parseContext) {
    if (orig_HistoryDetailReply_merge) {
        orig_HistoryDetailReply_merge(self, parseContext);
    }
    if (!kiou_featureEnabled(KIOU_FEATURE_PREMIUM_UNLOCK)) return;
    if (!ptrLooksValid(self)) return;
    @try {
        uint8_t before = readU8(self, OFF_SHOGI_HISTORY_DETAIL_REPLY_IS_PREMIUM_USER);
        if (before != 1) {
            writeU8(self, OFF_SHOGI_HISTORY_DETAIL_REPLY_IS_PREMIUM_USER, 1);
            file_log([NSString stringWithFormat:
                      @"[PREMIUM] HistoryDetailReply.isPremiumUser %d -> 1",
                      (int)before]);
        }
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[PREMIUM] HistoryDetailReply merge exception: %@", e]);
    }
}

void install_PremiumUnlock_hook(uintptr_t unityBase) {
    {
        uintptr_t addr = unityBase + RVA_KIFU_DETAIL_MODEL_IS_PREMIUM_USER;
        MSHookFunction((void *)addr,
                       (void *)hook_KifuDetailModel_IsPremiumUser,
                       (void **)&orig_KifuDetailModel_IsPremiumUser);
        file_log([NSString stringWithFormat:
                  @"KifuDetailModel.IsPremiumUser hooked @0x%lx (base+0x%x) - forced true",
                  (unsigned long)addr, RVA_KIFU_DETAIL_MODEL_IS_PREMIUM_USER]);
    }
    {
        uintptr_t addr = unityBase + RVA_SHOGI_HISTORY_DETAIL_REPLY_MERGE;
        MSHookFunction((void *)addr,
                       (void *)hook_HistoryDetailReply_merge,
                       (void **)&orig_HistoryDetailReply_merge);
        file_log([NSString stringWithFormat:
                  @"GetShogiHistoryDetailListReply.InternalMergeFrom hooked @0x%lx (base+0x%x)",
                  (unsigned long)addr, RVA_SHOGI_HISTORY_DETAIL_REPLY_MERGE]);
    }
    {
        uintptr_t addr = unityBase + RVA_SHOGI_HISTORY_DETAIL_REPLY_GET_PREMIUM;
        MSHookFunction((void *)addr,
                       (void *)hook_HistoryDetailReply_IsPremiumUser,
                       (void **)&orig_HistoryDetailReply_IsPremiumUser);
        file_log([NSString stringWithFormat:
                  @"GetShogiHistoryDetailListReply.get_IsPremiumUser hooked @0x%lx (base+0x%x) - forced true",
                  (unsigned long)addr, RVA_SHOGI_HISTORY_DETAIL_REPLY_GET_PREMIUM]);
    }
}
