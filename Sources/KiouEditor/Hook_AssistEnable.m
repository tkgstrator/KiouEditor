#import "Internal.h"

// ===========================================================================
// HOOK 9: ResolvedBeginnerSupport gate overrides.
//
// GameSetup.BeginnerSupport is a ResolvedBeginnerSupport struct whose
// Enabled bool gates whether GameOrchestrator (CreatePresenters /
// SubscribeBeginnerSupportEvaluation paths) wires the in-game
// BeginnerSupportEvaluator + BookHintProvider into BoardPresenter /
// EffectPresenter. In modes where the assist isn't normally offered
// (e.g. ranked) the resolved struct comes back with Enabled = false and
// the evaluator/provider stay unused.
//
//   ResolvedBeginnerSupport.get_Enabled  RVA 0x593E630  -> always true
//   ResolvedBeginnerSupport.get_Depth    RVA 0x593E650  -> always 16
//
// The depth override here is belt-and-braces; the BSE itself is also pinned
// by Hook_AssistTune (depth=16, skillLevel=20). Whichever path the engine
// uses, it lands on the same number.
// ===========================================================================

#define RVA_RESOLVED_BSUPPORT_GET_ENABLED 0x593E630
#define RVA_RESOLVED_BSUPPORT_GET_DEPTH   0x593E650

#define KIOU_ASSIST_GATE_DEPTH 3

typedef bool    (*BSupportGetBool_t)(void *self);
typedef int32_t (*BSupportGetI32_t)(void *self);

static BSupportGetBool_t orig_RBS_get_Enabled = NULL;
static BSupportGetI32_t  orig_RBS_get_Depth   = NULL;

static bool hook_RBS_get_Enabled(void *self) {
    (void)self;
    return true;
}

static int32_t hook_RBS_get_Depth(void *self) {
    (void)self;
    return KIOU_ASSIST_GATE_DEPTH;
}

void install_AssistEnable_hook(uintptr_t unityBase) {
    {
        uintptr_t addr = unityBase + RVA_RESOLVED_BSUPPORT_GET_ENABLED;
        MSHookFunction((void *)addr,
                       (void *)hook_RBS_get_Enabled,
                       (void **)&orig_RBS_get_Enabled);
        file_log([NSString stringWithFormat:
                  @"ResolvedBeginnerSupport.get_Enabled hooked @0x%lx (base+0x%x) - forced true",
                  (unsigned long)addr, RVA_RESOLVED_BSUPPORT_GET_ENABLED]);
    }
    {
        uintptr_t addr = unityBase + RVA_RESOLVED_BSUPPORT_GET_DEPTH;
        MSHookFunction((void *)addr,
                       (void *)hook_RBS_get_Depth,
                       (void **)&orig_RBS_get_Depth);
        file_log([NSString stringWithFormat:
                  @"ResolvedBeginnerSupport.get_Depth hooked @0x%lx (base+0x%x) - forced %d",
                  (unsigned long)addr, RVA_RESOLVED_BSUPPORT_GET_DEPTH,
                  KIOU_ASSIST_GATE_DEPTH]);
    }
}
