#pragma once

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <stdint.h>

// ===========================================================================
// Internal.h — KiouEditor shared declarations.
//
// Pointer / il2cpp helpers are static inline so each translation unit gets
// its own copy with no linker plumbing. Shared mutable state (g_inHook) and
// per-module hook installers are extern-declared here and defined exactly
// once across the .m files.
// ===========================================================================

#ifndef KIOU_EDITOR_COMMIT
#define KIOU_EDITOR_COMMIT "unknown"
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void file_log(NSString *msg);
void logging_init(void);

// ---------------------------------------------------------------------------
// Reentrancy guard shared between SyncItemList and Collection hooks.
// Defined once in Tweak.m.
// ---------------------------------------------------------------------------

extern volatile int g_inHook;

// ---------------------------------------------------------------------------
// Pointer safety + il2cpp object layout helpers
//
//   RepeatedField<T>: +0x10 array ptr, +0x18 count
//   il2cpp array:     element[0] at arrayPtr + 0x20, refs 8-byte spaced
//   il2cpp string:    +0x10 length (UTF-16 code units), +0x14 char[]
// ---------------------------------------------------------------------------

static inline BOOL ptrLooksValid(const void *p) {
    uintptr_t v = (uintptr_t)p;
    if (v == 0) return NO;
    if (v < 0x1000) return NO;
    if (v >= 0x0001000000000000ULL) return NO;
    return YES;
}

static inline int32_t readI32(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return 0;
    return *(const int32_t *)((const uint8_t *)base + off);
}

static inline uint8_t readU8(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return 0;
    return *(const uint8_t *)((const uint8_t *)base + off);
}

static inline void *readPtr(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return NULL;
    void *p = *(void *const *)((const uint8_t *)base + off);
    return ptrLooksValid(p) ? p : NULL;
}

static inline void writeU8(void *base, uintptr_t off, uint8_t val) {
    if (!ptrLooksValid(base)) return;
    *(volatile uint8_t *)((uint8_t *)base + off) = val;
}

static inline void writeI32(void *base, uintptr_t off, int32_t val) {
    if (!ptrLooksValid(base)) return;
    *(volatile int32_t *)((uint8_t *)base + off) = val;
}

static inline BOOL readRepeatedField(const void *obj, uintptr_t fieldOff,
                                     void **outArrayPtr, int32_t *outCount) {
    *outArrayPtr = NULL;
    *outCount = 0;
    void *rf = readPtr(obj, fieldOff);
    if (!rf) return NO;
    void *arr = readPtr(rf, 0x10);
    int32_t count = readI32(rf, 0x18);
    if (count < 0 || count > 100000) return NO;
    if (count > 0 && !arr) return NO;
    *outArrayPtr = arr;
    *outCount = count;
    return YES;
}

static inline void *readArrayElem(const void *arrayPtr, int32_t index) {
    if (!ptrLooksValid(arrayPtr)) return NULL;
    if (index < 0) return NULL;
    return readPtr(arrayPtr, 0x20 + (uintptr_t)index * 8);
}

static inline NSString *il2cppStringToNSString(const void *s) {
    if (!ptrLooksValid(s)) return nil;
    int32_t len = *(const int32_t *)((const uint8_t *)s + 0x10);
    if (len < 0 || len > 0x10000) return nil;
    const unichar *chars = (const unichar *)((const uint8_t *)s + 0x14);
    return [NSString stringWithCharacters:chars length:(NSUInteger)len];
}

// ---------------------------------------------------------------------------
// Per-module hook installers. Each takes the UnityFramework base address and
// installs its RVA hooks via MSHookFunction. Safe to call multiple times only
// if the module guards itself.
// ---------------------------------------------------------------------------

void install_SyncItemList_hook(uintptr_t unityBase);
void install_Collection_hook(uintptr_t unityBase);
void install_Version_hook(uintptr_t unityBase);
void install_SelectCharacter_hook(uintptr_t unityBase);
void install_MatchingPlayer_hook(uintptr_t unityBase);
void install_PremiumUnlock_hook(uintptr_t unityBase);
void install_AssistTune_hook(uintptr_t unityBase);
void install_AssistEnable_hook(uintptr_t unityBase);
void install_FriendUnhide_hook(uintptr_t unityBase);
void install_VoiceUnlock_hook(uintptr_t unityBase);

// Sprite recon: walks uiButton -> gameObject.transform -> "Content" -> "Image"
// child, calls GameObject.GetComponent("UnityEngine.UI.Image") on the leaf
// GameObject, and logs the m_Sprite (field +0xD8) pointer. Tag distinguishes
// title vs home callsites in the log. Implementation lives in
// Hook_FriendUnhide.m next to the il2cpp bridge.
void kioueditor_reconButtonImage(void *uiButton, const char *tag);

// Once the title screen has captured its menu button's sprite, this swaps
// it onto a freshly cloned home utility button's Image leaf. No-op if the
// title sprite has not been captured yet.
void kioueditor_applyTitleSpriteToClone(void *cloneGo);

// ---------------------------------------------------------------------------
// Select-character persistence shared with Hook_SyncItemList.
//
// The server only ever sees SAFE_ID (a known-owned skin) being equipped.
// The user's intended skin id is kept on-device in NSUserDefaults and
// stitched back into is_selected entries in every relevant reply.
//
// Returns 0 when nothing is persisted (use the server's value as-is).
// ---------------------------------------------------------------------------

#define KIOU_SAFE_SKIN_ID 1

int32_t kiou_persistedSelection(void);
void    kiou_setPersistedSelection(int32_t skinId);

// Rewrite is_selected entries in the given character + character-skin
// RepeatedField arrays so they advertise the persisted user choice instead
// of whatever the server returned. Both arrays may be NULL/empty.
//
//   charArr / charCount  - updatedCharacterList     (CharacterStatus[],
//                          mstCharacterId @0x18, isSelected @0x45)
//   skinArr / skinCount  - updatedCharacterSkinList (CharacterSkinStatus[],
//                          mstSkinId @0x18, mstCharacterId @0x1C,
//                          isSelected @0x21)
void kiou_applyPersistedSelectionToLists(void *charArr, int32_t charCount,
                                        void *skinArr, int32_t skinCount);

// Self user UUID (matching ShogiMatchingPlayerStatus.userId). Empty when
// unset - callers should fall back to a heuristic. Caller owns no NSString
// memory beyond standard ARC.
NSString *kiou_selfUserId(void);
void      kiou_setSelfUserId(NSString *uid);

// ---------------------------------------------------------------------------
// Runtime feature toggles. Each hook gates its tamper logic on its own
// flag - flipping a flag off causes the hook to fall through to orig() and
// behave like vanilla. Defaults to YES for every feature.
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, KiouFeature) {
    KIOU_FEATURE_ITEM_UNLOCK = 0,    // Hook_SyncItemList ownership writes
    KIOU_FEATURE_CHAR_BYPASS,        // Hook_SelectCharacter SAFE_ID swap
    KIOU_FEATURE_PREMIUM_UNLOCK,     // Hook_PremiumUnlock forced true
    KIOU_FEATURE_MATCH_ASSIST,       // Hook_MatchingPlayer enable beginner support
    KIOU_FEATURE_VOICE_UNLOCK,       // Hook_VoiceUnlock + Hook_SyncItemList intimacy pin
    KIOU_FEATURE_ASSIST_ENABLE,      // Hook_AssistEnable force enabled + depth
    KIOU_FEATURE_COUNT,
};

bool kiou_featureEnabled(KiouFeature f);
void kiou_setFeatureEnabled(KiouFeature f, bool enabled);
NSString *kiou_featureLabel(KiouFeature f);

// ---------------------------------------------------------------------------
// Engine tuning (BeginnerSupportEvaluator). Getters clamp before returning.
//   depth      1 .. 50  (default 16; retail BSE default is 5, the 50 cap is
//                        only there to keep the UI stepper sane)
//   skillLevel 1 .. 20  (default 20)
//   hashIndex  0 .. 4   (default 1 = 128 MB; index into the preset table
//                        {64, 128, 256, 512, 1024} MB)
//
// The hash size feeds NativeSyncSession.SetHashSize(int mb) — see
// Hook_AssistTune.m for the call site. Rshogi's compiled-in default is small
// (~16 MB) and no engine path sets it; the user-picked preset is applied
// inside EnsureInitializedLocked once the native session is alive.
// ---------------------------------------------------------------------------
int32_t kiou_assistDepth(void);
void    kiou_setAssistDepth(int32_t v);
int32_t kiou_assistSkillLevel(void);
void    kiou_setAssistSkillLevel(int32_t v);
int32_t kiou_assistHashIndex(void);
void    kiou_setAssistHashIndex(int32_t idx);
int32_t kiou_assistHashMB(void);
