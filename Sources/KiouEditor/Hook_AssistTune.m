#import "Internal.h"

// ===========================================================================
// HOOK 8: BeginnerSupportEvaluator parameter override.
//   RVA 0x597A448 from UnityFramework base.
//   public void .ctor(string evalPath, BeginnerSupportSettings settings)
//
// BeginnerSupportEvaluator is the in-game NNUE evaluator that drives the
// hint-arrow / best-move-suggestion overlays. Its tuning fields are baked in
// from BeginnerSupportSettings (a ScriptableObject set on GameOrchestrator).
// Defaults at retail:
//   _analysisDepth     = 5    (visibly weak, misses tactical lines)
//   _engineSkillLevel  = 20   (already max)
//
// We let the original ctor run (it allocates caches, captures eval path,
// reads the ScriptableObject), then over-write the two ints we care about:
//   +0x18 _analysisDepth     -> 16 (visibly stronger; 9 if responsiveness drops)
//   +0x28 _engineSkillLevel  -> 20 (max; redundant today but pins it)
//
// All other fields (eval path, thresholds, verboseLog, session, caches) are
// left untouched. Read-only override; no allocation; no outbound traffic.
// ===========================================================================

#define RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR 0x597A448

#define OFF_BSE_ANALYSIS_DEPTH       0x18
#define OFF_BSE_ENGINE_SKILL_LEVEL   0x28

typedef void (*BSECtor_t)(void *self, void *evalPath, void *settings);

static BSECtor_t orig_BSE_ctor = NULL;

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

void install_AssistTune_hook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR;
    MSHookFunction((void *)addr,
                   (void *)hook_BSE_ctor,
                   (void **)&orig_BSE_ctor);
    file_log([NSString stringWithFormat:
              @"BeginnerSupportEvaluator.ctor hooked @0x%lx (base+0x%x) depth=%d skill=%d",
              (unsigned long)addr, RVA_BEGINNER_SUPPORT_EVALUATOR_CTOR,
              (int)kiou_assistDepth(), (int)kiou_assistSkillLevel()]);
}
