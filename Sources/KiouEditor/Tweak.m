#import "Internal.h"
#import <mach-o/dyld.h>
#import <string.h>

// ===========================================================================
// KiouEditor — entry point.
//
// Each hook module owns its own RVA, orig pointer, and replacement function,
// and exposes one install_*_hook(unityBase) entry. This file scans dyld for
// UnityFramework and dispatches to each installer once UnityFramework is up.
//
// CONSTRAINTS (strict, project-wide):
//   - Observation + ownership tamper. No network (local response edit only).
//   - SyncItemListReply tampers only decoration-band Supplies and characters.
//   - UpdateCollectionPresetReply is OBSERVATION ONLY.
//   - TitleScene format string patch is purely cosmetic.
//   - Every pointer read is NULL/range-checked.
// ===========================================================================

volatile int g_inHook = 0;

static BOOL g_unityHooked = NO;

static void installUnityHooks(void) {
    if (g_unityHooked) return;

    uint32_t imgCount = _dyld_image_count();
    uintptr_t unityBase = 0;
    const char *unityName = NULL;
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            unityBase = (uintptr_t)_dyld_get_image_header(i);
            unityName = name;
            break;
        }
    }

    if (unityBase == 0) {
        // Not loaded yet - retry will call us again.
        return;
    }

    file_log([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

    install_SyncItemList_hook(unityBase);
    install_Collection_hook(unityBase);
    install_Version_hook(unityBase);
    install_SelectCharacter_hook(unityBase);
    install_MatchingPlayer_hook(unityBase);
    install_PremiumUnlock_hook(unityBase);
    install_AssistTune_hook(unityBase);
    install_AssistEnable_hook(unityBase);
    install_FriendUnhide_hook(unityBase);

    g_unityHooked = YES;
    file_log(@"=== All UnityFramework hooks installed ===");
}

static void retryInstallHooks(void) {
    if (!g_unityHooked) installUnityHooks();

    if (!g_unityHooked) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            retryInstallHooks();
        });
    }
}

__attribute__((constructor)) static void init(void) {
    logging_init();
    file_log(@"=== KiouEditor loaded ===");

    // UnityFramework is almost certainly not mapped yet at constructor time.
    installUnityHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });

    file_log(@"=== KiouEditor constructor done ===");
}
