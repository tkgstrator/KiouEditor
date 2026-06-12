#import "Internal.h"

// ===========================================================================
// HOOK 8: BeginnerSupportEvaluator parameter override.
//
// Two hooks live in this file:
//
//   A) BSE..ctor                       RVA 0x597A448
//      public void .ctor(string evalPath, BeginnerSupportSettings settings)
//
//      Rewrites the two tuning ints baked in from BeginnerSupportSettings
//      (a ScriptableObject set on GameOrchestrator). Retail defaults:
//        _analysisDepth     = 5    (visibly weak, misses tactical lines)
//        _engineSkillLevel  = 20   (already max)
//
//      We let the original ctor run (it allocates caches, captures eval
//      path, reads the ScriptableObject), then over-write:
//        +0x18 _analysisDepth     -> kiou_assistDepth()    (default 16)
//        +0x28 _engineSkillLevel  -> kiou_assistSkillLevel() (default 20)
//
//   B) BSE.EnsureInitializedLocked()   RVA 0x597BAFC
//      private void EnsureInitializedLocked()
//
//      The lazy bring-up that allocates the Rshogi NativeSyncSession into
//      _session (+0x38) on the first EvaluateAsync. nothing in the retail
//      code path calls NativeSyncSession.SetHashSize, so Rshogi runs on its
//      tiny compiled-in default. We piggy-back here: once orig finishes and
//      the session pointer is live, we invoke SetHashSize(MB) via direct
//      ABI to give the NNUE engine real working memory.
//
//      NativeSyncSession.SetHashSize is reached via the function pointer at
//      unityBase + RVA_NATIVESYNCSESSION_SETHASHSIZE. The trailing MethodInfo*
//      slot is NULL — same shape Hook_FriendUnhide.m:402 uses for direct
//      non-generic invocations.
//
// All other BSE fields (eval path, thresholds, verboseLog, session, caches)
// are left untouched. Read-only override; no allocation; no outbound traffic.
// ===========================================================================

#define RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR     0x597A448
#define RVA_BSE_ENSURE_INITIALIZED_LOCKED       0x597BAFC
#define RVA_NATIVESYNCSESSION_SETHASHSIZE       0x5D320E0

#define OFF_BSE_ANALYSIS_DEPTH       0x18
#define OFF_BSE_ENGINE_SKILL_LEVEL   0x28
#define OFF_BSE_SESSION              0x38

typedef void (*BSECtor_t)(void *self, void *evalPath, void *settings);
typedef void (*BSEEnsureInit_t)(void *self);
typedef void (*NSS_SetHashSize_directABI_t)(void *thisSession, int32_t mb, void *methodInfo);

static BSECtor_t       orig_BSE_ctor          = NULL;
static BSEEnsureInit_t orig_BSE_ensure_init   = NULL;
static uintptr_t       g_unityBaseForAssist   = 0;

static void hook_BSE_ctor(void *self, void *evalPath, void *settings) {
    if (orig_BSE_ctor) {
        orig_BSE_ctor(self, evalPath, settings);
    }
    // Tune evaluator parameters regardless of ASSIST_ENABLE; the user
    // controls the engaged hint arrow via that flag in Hook_AssistEnable.
    if (!ptrLooksValid(self)) return;
    @try {
        int32_t targetDepth = kiou_assistDepth();
        int32_t targetSkill = kiou_assistSkillLevel();
        int32_t origDepth = readI32(self, OFF_BSE_ANALYSIS_DEPTH);
        int32_t origSkill = readI32(self, OFF_BSE_ENGINE_SKILL_LEVEL);
        if (origDepth != targetDepth) {
            writeI32(self, OFF_BSE_ANALYSIS_DEPTH, targetDepth);
        }
        if (origSkill != targetSkill) {
            writeI32(self, OFF_BSE_ENGINE_SKILL_LEVEL, targetSkill);
        }
        file_log([NSString stringWithFormat:
                  @"[ASSIST] BSE tuned: depth %d -> %d, skillLevel %d -> %d",
                  origDepth, targetDepth, origSkill, targetSkill]);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[ASSIST] BSE ctor override exception: %@", e]);
    }
}

static void hook_BSE_ensure_init(void *self) {
    if (orig_BSE_ensure_init) {
        orig_BSE_ensure_init(self);
    }
    if (!ptrLooksValid(self) || g_unityBaseForAssist == 0) return;
    @try {
        void *session = readPtr(self, OFF_BSE_SESSION);
        if (!session) {
            // Orig didn't bring the session up (eval path missing, etc.).
            // Nothing to size; let the next EvaluateAsync retry.
            return;
        }
        int32_t mb = kiou_assistHashMB();
        NSS_SetHashSize_directABI_t setHash =
            (NSS_SetHashSize_directABI_t)(g_unityBaseForAssist
                                          + RVA_NATIVESYNCSESSION_SETHASHSIZE);
        setHash(session, mb, NULL);
        file_log([NSString stringWithFormat:
                  @"[ASSIST] EnsureInitializedLocked: SetHashSize(%d) ok session=%p",
                  mb, session]);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[ASSIST] EnsureInitializedLocked SetHashSize exception: %@", e]);
    }
}

void install_AssistTune_hook(uintptr_t unityBase) {
    g_unityBaseForAssist = unityBase;
    {
        uintptr_t addr = unityBase + RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR;
        MSHookFunction((void *)addr,
                       (void *)hook_BSE_ctor,
                       (void **)&orig_BSE_ctor);
        file_log([NSString stringWithFormat:
                  @"BeginnerSupportEvaluator.ctor hooked @0x%lx (base+0x%x) depth=%d skill=%d",
                  (unsigned long)addr, RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR,
                  (int)kiou_assistDepth(), (int)kiou_assistSkillLevel()]);
    }
    {
        uintptr_t addr = unityBase + RVA_BSE_ENSURE_INITIALIZED_LOCKED;
        MSHookFunction((void *)addr,
                       (void *)hook_BSE_ensure_init,
                       (void **)&orig_BSE_ensure_init);
        file_log([NSString stringWithFormat:
                  @"BeginnerSupportEvaluator.EnsureInitializedLocked hooked @0x%lx (base+0x%x) hash=%d MB",
                  (unsigned long)addr, RVA_BSE_ENSURE_INITIALIZED_LOCKED,
                  (int)kiou_assistHashMB()]);
    }
}
