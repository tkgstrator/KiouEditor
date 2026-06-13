#import "Internal.h"
#import <dlfcn.h>

// ===========================================================================
// HOOK 3: TitleScene.<OnActivateAsync>d__10.MoveNext
//   RVA 0x5DCC728 from UnityFramework base.
//
//   Title-screen version label is rendered as:
//     _appVersionText.SetTextFormat(_appVersionFormat, Application.version)
//   We tamper _appVersionFormat (TitleScene+0x40, il2cpp String*) before the
//   original MoveNext runs the SetTextFormat call. Appending "+ (commit)" to
//   the format string is rendered verbatim by string.Format (no positional
//   placeholder), so the displayed text becomes e.g. "v1.0.1+ (b5544ef)".
//
//   sm + 0x20 = TitleScene*
//
//   The patch is guarded by a hasSuffix check on the current format string
//   instead of a process-wide once-flag. This makes it idempotent within an
//   async state machine (MoveNext is invoked on every await resumption) AND
//   automatically re-patches when TitleScene is regenerated (e.g. on a
//   back-to-title navigation), which a global flag would skip.
// ===========================================================================

#define RVA_TITLESCENE_MOVENEXT 0x5DCC728

typedef void (*TitleSceneMoveNext_t)(void *sm);
typedef void *(*il2cpp_string_new_t)(const char *s);

static TitleSceneMoveNext_t orig_TitleScene_MoveNext = NULL;
static il2cpp_string_new_t  p_il2cpp_string_new = NULL;

static bool g_titleSpriteReconDone = false;

static void hook_TitleScene_MoveNext(void *sm) {
    if (ptrLooksValid(sm) && p_il2cpp_string_new) {
        @try {
            void *titleScene = readPtr(sm, 0x20);
            if (titleScene) {
                if (!g_titleSpriteReconDone) {
                    void *titleMenuBtn = readPtr(titleScene, 0x30);
                    kioueditor_reconButtonImage(titleMenuBtn, "title-menu");
                    g_titleSpriteReconDone = true;
                }
                void *origFormatStr = readPtr(titleScene, 0x40);
                NSString *origFormat = il2cppStringToNSString(origFormatStr);
                if (origFormat.length > 0) {
                    NSString *suffix = [NSString stringWithFormat:
                                        @"+ (%s)", KIOU_EDITOR_COMMIT];
                    if (![origFormat hasSuffix:suffix]) {
                        NSString *newFormat = [origFormat stringByAppendingString:suffix];
                        void *newStr = p_il2cpp_string_new(newFormat.UTF8String);
                        if (ptrLooksValid(newStr)) {
                            *(void *volatile *)((uint8_t *)titleScene + 0x40) = newStr;
                            file_log([NSString stringWithFormat:
                                      @"[VERSION] _appVersionFormat: \"%@\" -> \"%@\"",
                                      origFormat, newFormat]);
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            file_log([NSString stringWithFormat:
                      @"[VERSION] format patch exception: %@", e]);
        }
    }

    if (orig_TitleScene_MoveNext) {
        orig_TitleScene_MoveNext(sm);
    }
}

// Diagnostic: dump the first 16 bytes at `addr` as a hex string. The caller
// uses this to compare pre-/post-MSHookFunction state so we can tell whether
// the inline patch actually landed in memory (a true patch typically replaces
// the prologue with an `LDR x16, ...; BR x16` trampoline shape).
static NSString *kiou_hexAt(uintptr_t addr) {
    const uint8_t *p = (const uint8_t *)addr;
    NSMutableString *s = [NSMutableString stringWithCapacity:48];
    @try {
        for (int i = 0; i < 16; i++) {
            [s appendFormat:@"%02x%@", p[i], (i == 15 ? @"" : @" ")];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"(read failed: %@)", e];
    }
    return s;
}

void install_Version_hook(uintptr_t unityBase) {
    p_il2cpp_string_new =
        (il2cpp_string_new_t)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
    if (!p_il2cpp_string_new) {
        file_log(@"[VERSION] dlsym(il2cpp_string_new) failed - version hook skipped");
        return;
    }
    uintptr_t addr = unityBase + RVA_TITLESCENE_MOVENEXT;

    NSString *before = kiou_hexAt(addr);
    file_log([NSString stringWithFormat:
              @"[VERSION-DIAG] before MSHookFunction @0x%lx: %@", addr, before]);

    MSHookFunction((void *)addr,
                   (void *)hook_TitleScene_MoveNext,
                   (void **)&orig_TitleScene_MoveNext);

    NSString *after = kiou_hexAt(addr);
    file_log([NSString stringWithFormat:
              @"[VERSION-DIAG] after  MSHookFunction @0x%lx: %@", addr, after]);
    file_log([NSString stringWithFormat:
              @"[VERSION-DIAG] orig_TitleScene_MoveNext=%p (NULL means MSHookFunction silently failed)",
              orig_TitleScene_MoveNext]);

    file_log([NSString stringWithFormat:
              @"TitleScene.MoveNext hooked @0x%lx (base+0x%x), commit=%s",
              (unsigned long)addr, RVA_TITLESCENE_MOVENEXT,
              KIOU_EDITOR_COMMIT]);
}
