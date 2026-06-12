#import "Internal.h"
#import <dlfcn.h>

// ===========================================================================
// HOOK 10: HomeUtilityPresenter.ctor - unhide the friend button.
//   RVA 0x5A9F298 from UnityFramework base.
//   public void .ctor(IHomeUtilityView view)  - x0=self, x1=view
//
// HomeUtilityView (Project.Menu) layout from dump.cs:
//   +0x20 _menuButton    (UIButtonBase)
//   +0x28 _giftButton    (UIButtonBase)
//   +0x30 _giftBadgeView (BadgeWithCountView)
//   +0x38 _friendButton  (UIButtonBase) - hidden in the retail layout
//
// Phase 1a (recon) confirmed all three button pointers populate at ctor
// time. Phase 1b calls UnityEngine.Component.get_gameObject() on the friend
// button and then UnityEngine.GameObject.SetActive(true) on the result via
// il2cpp_runtime_invoke. Methods are resolved off the runtime object's own
// klass (get_gameObject is inherited from Component) and the resulting
// GameObject's klass, then cached for subsequent ctor fires.
// ===========================================================================

#define RVA_HOME_UTILITY_PRESENTER_CTOR 0x5A9F298

#define OFF_HUV_MENU_BUTTON   0x20
#define OFF_HUV_GIFT_BUTTON   0x28
#define OFF_HUV_FRIEND_BUTTON 0x38

// ---------------------------------------------------------------------------
// il2cpp runtime bridge (Phase 1a: resolved but unused; Phase 1b will call
// invoke + class_from_name + class_get_method_from_name for SetActive).
// ---------------------------------------------------------------------------

typedef void *(*il2cpp_runtime_invoke_t)(void *method, void *obj, void **params, void **exc);
typedef void *(*il2cpp_class_from_name_t)(void *image, const char *ns, const char *name);
typedef void *(*il2cpp_class_get_method_from_name_t)(void *klass, const char *name, int argc);
typedef void *(*il2cpp_object_get_class_t)(void *obj);

static il2cpp_runtime_invoke_t            p_il2cpp_runtime_invoke = NULL;
static il2cpp_class_from_name_t           p_il2cpp_class_from_name = NULL;
static il2cpp_class_get_method_from_name_t p_il2cpp_class_get_method_from_name = NULL;
static il2cpp_object_get_class_t          p_il2cpp_object_get_class = NULL;

static void resolveIl2cppBridge(void) {
    if (p_il2cpp_runtime_invoke) return;
    p_il2cpp_runtime_invoke = (il2cpp_runtime_invoke_t)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    p_il2cpp_class_from_name = (il2cpp_class_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_il2cpp_class_get_method_from_name = (il2cpp_class_get_method_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    p_il2cpp_object_get_class = (il2cpp_object_get_class_t)dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    file_log([NSString stringWithFormat:
              @"[HOME] il2cpp bridge: runtime_invoke=%p class_from_name=%p class_get_method_from_name=%p object_get_class=%p",
              p_il2cpp_runtime_invoke,
              p_il2cpp_class_from_name,
              p_il2cpp_class_get_method_from_name,
              p_il2cpp_object_get_class]);
}

// ---------------------------------------------------------------------------
// Cached method pointers - resolved from the live objects' klasses on the
// first ctor fire, then reused. The il2cpp method pointers are stable for
// the lifetime of the dylib so caching is safe.
// ---------------------------------------------------------------------------

static void *g_method_get_gameObject = NULL;  // Component.get_gameObject
static void *g_method_SetActive      = NULL;  // GameObject.SetActive

// Invoke instance method 0-arg returning a managed object pointer.
static void *invoke0(void *method, void *obj) {
    if (!p_il2cpp_runtime_invoke || !method) return NULL;
    return p_il2cpp_runtime_invoke(method, obj, NULL, NULL);
}

// Invoke instance method that takes a single bool argument.
static void invokeSetActive(void *method, void *obj, bool value) {
    if (!p_il2cpp_runtime_invoke || !method) return;
    bool v = value;
    void *params[1] = { &v };
    p_il2cpp_runtime_invoke(method, obj, params, NULL);
}

static void *gameObjectOf(void *componentObj) {
    if (!ptrLooksValid(componentObj)) return NULL;
    if (!g_method_get_gameObject) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return NULL;
        void *klass = p_il2cpp_object_get_class(componentObj);
        if (!klass) return NULL;
        g_method_get_gameObject = p_il2cpp_class_get_method_from_name(klass, "get_gameObject", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached get_gameObject method=%p (klass=%p)",
                  g_method_get_gameObject, klass]);
    }
    return invoke0(g_method_get_gameObject, componentObj);
}

static void setActive(void *gameObject, bool value) {
    if (!ptrLooksValid(gameObject)) return;
    if (!g_method_SetActive) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return;
        void *klass = p_il2cpp_object_get_class(gameObject);
        if (!klass) return;
        g_method_SetActive = p_il2cpp_class_get_method_from_name(klass, "SetActive", 1);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached SetActive method=%p (klass=%p)",
                  g_method_SetActive, klass]);
    }
    invokeSetActive(g_method_SetActive, gameObject, value);
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

typedef void (*HUP_ctor_t)(void *self, void *view);

static HUP_ctor_t orig_HUP_ctor = NULL;

static void hook_HUP_ctor(void *self, void *view) {
    if (orig_HUP_ctor) {
        orig_HUP_ctor(self, view);
    }
    @try {
        if (!ptrLooksValid(view)) {
            file_log(@"[HOME] presenter.ctor: view ptr invalid");
            return;
        }
        void *menuBtn   = readPtr(view, OFF_HUV_MENU_BUTTON);
        void *giftBtn   = readPtr(view, OFF_HUV_GIFT_BUTTON);
        void *friendBtn = readPtr(view, OFF_HUV_FRIEND_BUTTON);
        file_log([NSString stringWithFormat:
                  @"[HOME] HomeUtilityView@%p buttons: menu=%p gift=%p friend=%p",
                  view, menuBtn, giftBtn, friendBtn]);

        if (!ptrLooksValid(friendBtn)) return;
        void *friendGo = gameObjectOf(friendBtn);
        if (!ptrLooksValid(friendGo)) {
            file_log(@"[HOME] friend gameObject lookup failed");
            return;
        }
        file_log([NSString stringWithFormat:
                  @"[HOME] friend gameObject=%p -> SetActive(true)", friendGo]);
        setActive(friendGo, true);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:@"[HOME] hook exception: %@", e]);
    }
}

void install_FriendUnhide_hook(uintptr_t unityBase) {
    resolveIl2cppBridge();

    uintptr_t addr = unityBase + RVA_HOME_UTILITY_PRESENTER_CTOR;
    MSHookFunction((void *)addr,
                   (void *)hook_HUP_ctor,
                   (void **)&orig_HUP_ctor);
    file_log([NSString stringWithFormat:
              @"HomeUtilityPresenter.ctor hooked @0x%lx (base+0x%x)",
              (unsigned long)addr, RVA_HOME_UTILITY_PRESENTER_CTOR]);
}
