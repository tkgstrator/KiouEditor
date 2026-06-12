#import "Internal.h"

// ===========================================================================
// Persistence layer for runtime-toggleable features + engine tuning.
//
// Keys live under the "kiou_editor.*" namespace in NSUserDefaults. Feature
// flags default to YES (the tweak is "all-on" out of the box) so a fresh
// install behaves exactly like every release before the settings UI shipped.
// ===========================================================================

static NSString *featureKey(KiouFeature f) {
    switch (f) {
        case KIOU_FEATURE_ITEM_UNLOCK:     return @"kiou_editor.feature.item_unlock";
        case KIOU_FEATURE_CHAR_BYPASS:     return @"kiou_editor.feature.char_bypass";
        case KIOU_FEATURE_FRIEND_UNHIDE:   return @"kiou_editor.feature.friend_unhide";
        case KIOU_FEATURE_PREMIUM_UNLOCK:  return @"kiou_editor.feature.premium_unlock";
        case KIOU_FEATURE_MATCH_ASSIST:    return @"kiou_editor.feature.match_assist";
        case KIOU_FEATURE_VOICE_UNLOCK:    return @"kiou_editor.feature.voice_unlock";
        case KIOU_FEATURE_ASSIST_ENABLE:   return @"kiou_editor.feature.assist_enable";
        default:                           return nil;
    }
}

NSString *kiou_featureLabel(KiouFeature f) {
    switch (f) {
        case KIOU_FEATURE_ITEM_UNLOCK:    return @"Item Unlock";
        case KIOU_FEATURE_CHAR_BYPASS:    return @"Bypass Character";
        case KIOU_FEATURE_FRIEND_UNHIDE:  return @"Friend Button";
        case KIOU_FEATURE_PREMIUM_UNLOCK: return @"Premium User";
        case KIOU_FEATURE_MATCH_ASSIST:   return @"Beginner Support";
        case KIOU_FEATURE_VOICE_UNLOCK:   return @"Voice Unlock";
        case KIOU_FEATURE_ASSIST_ENABLE:  return @"Always Hint Arrow";
        default:                          return @"";
    }
}

bool kiou_featureEnabled(KiouFeature f) {
    NSString *key = featureKey(f);
    if (!key) return false;
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    id obj = [defs objectForKey:key];
    if (obj == nil) return true;
    return [defs boolForKey:key];
}

void kiou_setFeatureEnabled(KiouFeature f, bool enabled) {
    NSString *key = featureKey(f);
    if (!key) return;
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setBool:enabled forKey:key];
    [defs synchronize];
}

static NSString *const kAssistDepthKey      = @"kiou_editor.assist_depth";
static NSString *const kAssistSkillLevelKey = @"kiou_editor.assist_skill_level";

static int32_t clampInt(int32_t v, int32_t lo, int32_t hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

int32_t kiou_assistDepth(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:kAssistDepthKey] == nil) return 3;
    return clampInt((int32_t)[defs integerForKey:kAssistDepthKey], 1, 30);
}

void kiou_setAssistDepth(int32_t v) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setInteger:clampInt(v, 1, 30) forKey:kAssistDepthKey];
    [defs synchronize];
}

int32_t kiou_assistSkillLevel(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:kAssistSkillLevelKey] == nil) return 20;
    return clampInt((int32_t)[defs integerForKey:kAssistSkillLevelKey], 1, 20);
}

void kiou_setAssistSkillLevel(int32_t v) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setInteger:clampInt(v, 1, 20) forKey:kAssistSkillLevelKey];
    [defs synchronize];
}
