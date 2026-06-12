#import "Internal.h"

// ===========================================================================
// HOOK 6: ShogiMatchingPlayerStatus.InternalMergeFrom
//   RVA 0x5B4CAEC from UnityFramework base.
//
// The match-room server sends this DTO once per player (blackPlayer +
// whitePlayer) when a match starts. It's the source of truth for the avatar
// shown on the match screen, which is a DIFFERENT path from the title-screen
// "current character" Sync. The SelectCharacter swap is invisible here, so
// without this hook the avatar reverts to KIOU_SAFE_SKIN_ID during matches.
//
// Strategy: only rewrite the SELF player's character. Identify self via:
//   - NSUserDefaults "kiou_editor.self_user_id" (exact UUID match) - reliable.
//   - Fallback heuristic when self_user_id is unset: skip userId == "cpu" or
//     empty, then treat any remaining entry whose skin id equals
//     KIOU_SAFE_SKIN_ID as self (we forced ourselves to SAFE_ID via HOOK 4,
//     so the match-room reflects that for us). Works for CPU matches and
//     PvP where the opponent picked something other than SAFE_ID. Logs the
//     userId we acted on so the user can lock it in via kiou_setSelfUserId
//     for stricter PvP behavior later.
//
// Fields (ShogiMatchingPlayerStatus):
//   +0x18 userId            (il2cpp String*)
//   +0x30 mstIconId         (int32)
//   +0x38 mstCharacterId    (int32)        <- rewritten
//   +0x40 mstCharacterSkinId(int32)        <- rewritten
//   +0x44 mstAchievementId  (int32)
//   +0x48 mstShogiPieceId   (int32)
//   +0x4C mstShogiBoardId   (int32)
//   +0x50 mstShogiIngameBgmId (int32)
//
// We rewrite ONLY mstCharacterId + mstCharacterSkinId. Icon / frame / title /
// piece / board / BGM are decorations the user actually owns server-side
// (UpdateCollectionPreset persists them legitimately), so touching them here
// would diverge from the server's real state.
// ===========================================================================

#define RVA_MATCHING_PLAYER_MERGE 0x5B4CAEC

#define OFF_MP_USER_ID                 0x18
#define OFF_MP_MST_CHAR_ID             0x38
#define OFF_MP_MST_SKIN_ID             0x40
// ShogiMatchingPlayerStatus.enableBeginnerSupport_ (field 17). When the user
// toggles "指し手ガイド" off in the CPU-match setup screen, this comes back
// as 0 and the in-game UI suppresses the hint arrow regardless of the
// ResolvedBeginnerSupport.Enabled gate. Forcing self's copy to 1 re-enables
// the on-board guide. Opponent's copy is left alone so we don't reveal
// anything about other players' state to ourselves spuriously.
#define OFF_MP_ENABLE_BEGINNER_SUPPORT 0x68

static NSString *const kSelfUserIdKey = @"kiou_editor.self_user_id";
static NSString *const kCpuUserIdSentinel = @"cpu";

NSString *kiou_selfUserId(void) {
    NSString *uid = [[NSUserDefaults standardUserDefaults] stringForKey:kSelfUserIdKey];
    return uid.length > 0 ? uid : nil;
}

void kiou_setSelfUserId(NSString *uid) {
    if (uid.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelfUserIdKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kSelfUserIdKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

typedef void (*ReplyMergeFrom_t)(void *self, void *parseContext);

static ReplyMergeFrom_t orig_MatchingPlayer_merge = NULL;

static void hook_MatchingPlayer_merge(void *self, void *parseContext) {
    if (orig_MatchingPlayer_merge) {
        orig_MatchingPlayer_merge(self, parseContext);
    }
    if (!ptrLooksValid(self)) return;

    @try {
        void *userIdStr = readPtr(self, OFF_MP_USER_ID);
        NSString *userId = il2cppStringToNSString(userIdStr);
        if (userId.length == 0) return;
        if ([userId isEqualToString:kCpuUserIdSentinel]) return;

        int32_t curSkinId = readI32(self, OFF_MP_MST_SKIN_ID);
        int32_t curCharId = readI32(self, OFF_MP_MST_CHAR_ID);

        NSString *configuredSelf = kiou_selfUserId();
        BOOL isSelf;
        if (configuredSelf) {
            isSelf = [userId isEqualToString:configuredSelf];
        } else {
            // No locked-in self: assume the player carrying SAFE_ID is us
            // (HOOK 4 forces every outgoing select to SAFE_ID).
            isSelf = (curSkinId == KIOU_SAFE_SKIN_ID);
        }

        if (!isSelf) {
            file_log([NSString stringWithFormat:
                      @"[MATCH] skip non-self userId=%@ skin=%d char=%d",
                      userId, curSkinId, curCharId]);
            return;
        }

        // First-ever heuristic hit: lock the UUID in so subsequent matches
        // (including PvP where both players might wear SAFE_ID) use a strict
        // userId comparison instead of the skin-based guess.
        if (!configuredSelf) {
            kiou_setSelfUserId(userId);
            file_log([NSString stringWithFormat:
                      @"[MATCH] self_user_id captured: %@ (heuristic -> strict)",
                      userId]);
        }

        // Force assist-on for self, even when the CPU-match toggle is off.
        // Done regardless of whether a persisted skin override is active.
        uint8_t curBSE = readU8(self, OFF_MP_ENABLE_BEGINNER_SUPPORT);
        if (curBSE != 1) {
            writeU8(self, OFF_MP_ENABLE_BEGINNER_SUPPORT, 1);
            file_log([NSString stringWithFormat:
                      @"[MATCH] enableBeginnerSupport %d -> 1 (self)",
                      (int)curBSE]);
        }

        // Skin / character rewrite gated on a persisted SelectCharacter pick.
        int32_t target = kiou_persistedSelection();
        if (target == 0) return;
        if (curSkinId == target && curCharId == target) return;

        writeI32(self, OFF_MP_MST_SKIN_ID, target);
        writeI32(self, OFF_MP_MST_CHAR_ID, target);  // 1:1 mapping skin <-> char

        file_log([NSString stringWithFormat:
                  @"[MATCH] self=%@ skin %d->%d char %d->%d (self_locked=%@)",
                  userId, curSkinId, target, curCharId, target,
                  configuredSelf ? @"YES" : @"NO->YES"]);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[MATCH] exception: %@", e]);
    }
}

void install_MatchingPlayer_hook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_MATCHING_PLAYER_MERGE;
    MSHookFunction((void *)addr,
                   (void *)hook_MatchingPlayer_merge,
                   (void **)&orig_MatchingPlayer_merge);
    NSString *configured = kiou_selfUserId();
    file_log([NSString stringWithFormat:
              @"ShogiMatchingPlayerStatus.InternalMergeFrom hooked @0x%lx (base+0x%x) self_user_id=%@",
              (unsigned long)addr, RVA_MATCHING_PLAYER_MERGE,
              configured ?: @"(unset, using heuristic)"]);
}
