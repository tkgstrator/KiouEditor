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
