#import "Internal.h"

// ===========================================================================
// HOOK 11: voice unlock - two-pronged.
//
// (a) CharacterVoicePlayer.SatisfiesRule(VoiceRuleType) -> bool
//     RVA 0x582B88C. The playback-side chokepoint - called from TryPlay /
//     PlayInternal and from FindRule. Forcing it true lets the underlying
//     cue actually fire when we hand the button event through.
//
// (b) CharacterVoiceScrollerCellModel.get_IsLocked() -> bool
//     RVA 0x584ADC0. The UI-side chokepoint - the cell model is constructed
//     by <BuildCellModels>b__2 with `isLocked` baked in from the player's
//     SatisfiesRule check at the moment the list was built. That snapshot
//     is what drives the lock badge ("親密度Xで解放") and disables the
//     _playVoiceButton via _isLockedSwitcher in UpdateView. SatisfiesRule
//     alone is not enough here, because the cell can be built with the
//     player created against a stale _intimacyLevel snapshot (and the
//     button-enabled state is wired from get_IsLocked, not from a live
//     re-check). Pinning the getter to false re-enables the button and
//     hides the condition badge.
//
// VoiceRuleType (TDI 22258):
//   Invalid=0 Unspecified=1 Default=2 Level1=3..Level5=7 Complete=8 Unused=9
// Rule 9 (Unused) is forwarded to orig SatisfiesRule because it means
// "no cue mapped" - flipping it would let TryPlay walk into a NULL handle.
// IsLocked has no such trap; the cue lookup still goes through SatisfiesRule.
//
// All client-side; no outbound request changes.
// ===========================================================================

#define RVA_CHARACTER_VOICE_PLAYER_SATISFIES_RULE 0x582B88C
#define RVA_VOICE_CELL_MODEL_GET_IS_LOCKED        0x584ADC0

typedef bool (*SatisfiesRule_t)(void *self, int32_t rule);
typedef bool (*GetIsLocked_t)(void *self);

static SatisfiesRule_t orig_CharacterVoicePlayer_SatisfiesRule = NULL;
static GetIsLocked_t   orig_VoiceCellModel_get_IsLocked         = NULL;

static bool hook_CharacterVoicePlayer_SatisfiesRule(void *self, int32_t rule) {
    if (!kiou_featureEnabled(KIOU_FEATURE_VOICE_UNLOCK)) {
        return orig_CharacterVoicePlayer_SatisfiesRule
            ? orig_CharacterVoicePlayer_SatisfiesRule(self, rule) : false;
    }
    (void)self;
    // Unused (9) means "no cue exists" - flipping it would let TryPlay walk
    // into a NULL cue handle. Forward to the original so it returns false.
    if (rule == 9) {
        if (orig_CharacterVoicePlayer_SatisfiesRule) {
            return orig_CharacterVoicePlayer_SatisfiesRule(self, rule);
        }
        return false;
    }
    return true;
}

static bool hook_VoiceCellModel_get_IsLocked(void *self) {
    if (!kiou_featureEnabled(KIOU_FEATURE_VOICE_UNLOCK)) {
        return orig_VoiceCellModel_get_IsLocked
            ? orig_VoiceCellModel_get_IsLocked(self) : false;
    }
    (void)self;
    return false;
}

void install_VoiceUnlock_hook(uintptr_t unityBase) {
    {
        uintptr_t addr = unityBase + RVA_CHARACTER_VOICE_PLAYER_SATISFIES_RULE;
        MSHookFunction((void *)addr,
                       (void *)hook_CharacterVoicePlayer_SatisfiesRule,
                       (void **)&orig_CharacterVoicePlayer_SatisfiesRule);
        file_log([NSString stringWithFormat:
                  @"CharacterVoicePlayer.SatisfiesRule hooked @0x%lx (base+0x%x) - forced true",
                  (unsigned long)addr, RVA_CHARACTER_VOICE_PLAYER_SATISFIES_RULE]);
    }
    {
        uintptr_t addr = unityBase + RVA_VOICE_CELL_MODEL_GET_IS_LOCKED;
        MSHookFunction((void *)addr,
                       (void *)hook_VoiceCellModel_get_IsLocked,
                       (void **)&orig_VoiceCellModel_get_IsLocked);
        file_log([NSString stringWithFormat:
                  @"CharacterVoiceScrollerCellModel.get_IsLocked hooked @0x%lx (base+0x%x) - forced false",
                  (unsigned long)addr, RVA_VOICE_CELL_MODEL_GET_IS_LOCKED]);
    }
}
