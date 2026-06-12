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
typedef void *(*il2cpp_class_get_parent_t)(void *klass);
typedef void *(*il2cpp_class_get_methods_t)(void *klass, void **iter);
typedef const char *(*il2cpp_method_get_name_t)(void *method);
typedef uint32_t (*il2cpp_method_get_param_count_t)(void *method);
typedef bool (*il2cpp_method_is_generic_t)(void *method);

static il2cpp_runtime_invoke_t             p_il2cpp_runtime_invoke = NULL;
static il2cpp_class_from_name_t            p_il2cpp_class_from_name = NULL;
static il2cpp_class_get_method_from_name_t p_il2cpp_class_get_method_from_name = NULL;
static il2cpp_object_get_class_t           p_il2cpp_object_get_class = NULL;
static il2cpp_class_get_parent_t           p_il2cpp_class_get_parent = NULL;
static il2cpp_class_get_methods_t          p_il2cpp_class_get_methods = NULL;
static il2cpp_method_get_name_t            p_il2cpp_method_get_name = NULL;
static il2cpp_method_get_param_count_t     p_il2cpp_method_get_param_count = NULL;
static il2cpp_method_is_generic_t          p_il2cpp_method_is_generic = NULL;

static void resolveIl2cppBridge(void) {
    if (p_il2cpp_runtime_invoke) return;
    p_il2cpp_runtime_invoke = (il2cpp_runtime_invoke_t)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    p_il2cpp_class_from_name = (il2cpp_class_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_il2cpp_class_get_method_from_name = (il2cpp_class_get_method_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    p_il2cpp_object_get_class = (il2cpp_object_get_class_t)dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    p_il2cpp_class_get_parent = (il2cpp_class_get_parent_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
    p_il2cpp_class_get_methods = (il2cpp_class_get_methods_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
    p_il2cpp_method_get_name = (il2cpp_method_get_name_t)dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
    p_il2cpp_method_get_param_count = (il2cpp_method_get_param_count_t)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
    p_il2cpp_method_is_generic = (il2cpp_method_is_generic_t)dlsym(RTLD_DEFAULT, "il2cpp_method_is_generic");
    file_log([NSString stringWithFormat:
              @"[HOME] il2cpp bridge: runtime_invoke=%p class_from_name=%p class_get_method_from_name=%p object_get_class=%p class_get_parent=%p class_get_methods=%p method_get_name=%p method_get_param_count=%p method_is_generic=%p",
              p_il2cpp_runtime_invoke,
              p_il2cpp_class_from_name,
              p_il2cpp_class_get_method_from_name,
              p_il2cpp_object_get_class,
              p_il2cpp_class_get_parent,
              p_il2cpp_class_get_methods,
              p_il2cpp_method_get_name,
              p_il2cpp_method_get_param_count,
              p_il2cpp_method_is_generic]);
}

// ---------------------------------------------------------------------------
// Cached method pointers - resolved from the live objects' klasses on the
// first ctor fire, then reused. The il2cpp method pointers are stable for
// the lifetime of the dylib so caching is safe.
// ---------------------------------------------------------------------------

static void *g_method_get_gameObject     = NULL;  // Component.get_gameObject
static void *g_method_get_transform      = NULL;  // Component.get_transform
static void *g_method_SetActive          = NULL;  // GameObject.SetActive
static void *g_method_Instantiate2       = NULL;  // UnityEngine.Object.Instantiate(Object, Transform)
static void *g_method_Instantiate1NonGen = NULL;  // UnityEngine.Object.Instantiate(Object) non-generic

// Once-per-app-session guard so a HomeUtilityPresenter re-creation does not
// pile up duplicate clones on the home screen.
static bool g_cloneCreated = false;

// One-time guard for the Instantiate-method enumeration recon (Phase 2a
// debug). After the first fire we know which method handle is the
// non-generic Object.Instantiate so we do not need to re-walk every time.
static bool g_reconLogged = false;

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

// Component.get_transform - returns this.transform.
static void *transformOf(void *componentObj) {
    if (!ptrLooksValid(componentObj)) return NULL;
    if (!g_method_get_transform) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return NULL;
        void *klass = p_il2cpp_object_get_class(componentObj);
        if (!klass) return NULL;
        g_method_get_transform = p_il2cpp_class_get_method_from_name(klass, "get_transform", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached get_transform method=%p (klass=%p)",
                  g_method_get_transform, klass]);
    }
    return invoke0(g_method_get_transform, componentObj);
}

// Recon: walk every method on UnityEngine.Object (resolved via parent klass
// of any GameObject we already hold) and log each "Instantiate" variant
// with (name, argc, is_generic, method_ptr). From the log we can pick the
// non-generic method handle directly and invoke it later without racing
// the generic ones via get_method_from_name. Pure logging - no invoke.
static void logInstantiateMethods(void *anyGo) {
    if (!p_il2cpp_object_get_class
        || !p_il2cpp_class_get_parent
        || !p_il2cpp_class_get_methods
        || !p_il2cpp_method_get_name
        || !p_il2cpp_method_get_param_count) {
        file_log(@"[HOME] enum recon: bridge incomplete, skipping");
        return;
    }
    void *goKlass = p_il2cpp_object_get_class(anyGo);
    if (!goKlass) return;
    void *objKlass = p_il2cpp_class_get_parent(goKlass);
    if (!objKlass) return;
    file_log([NSString stringWithFormat:
              @"[HOME] enum: walking Object klass=%p", objKlass]);
    void *iter = NULL;
    void *method = NULL;
    int hits = 0;
    while ((method = p_il2cpp_class_get_methods(objKlass, &iter)) != NULL) {
        const char *name = p_il2cpp_method_get_name(method);
        if (!name) continue;
        if (strstr(name, "nstantiate") == NULL) continue;
        uint32_t argc = p_il2cpp_method_get_param_count(method);
        int isGeneric = -1;
        if (p_il2cpp_method_is_generic) {
            isGeneric = (int)p_il2cpp_method_is_generic(method);
        }
        file_log([NSString stringWithFormat:
                  @"[HOME] enum:   %s argc=%u generic=%d method=%p",
                  name, argc, isGeneric, method]);
        hits++;
    }
    file_log([NSString stringWithFormat:
              @"[HOME] enum: %d Instantiate variants found", hits]);
}

// Walk a klass's methods and return the first one matching name + argc that
// is NOT generic. Hand-rolled because il2cpp_class_get_method_from_name has
// no generic filter and races the generic Instantiate descriptors first.
static void *findNonGenericMethod(void *klass, const char *targetName, uint32_t targetArgc) {
    if (!klass) return NULL;
    if (!p_il2cpp_class_get_methods
        || !p_il2cpp_method_get_name
        || !p_il2cpp_method_get_param_count
        || !p_il2cpp_method_is_generic) return NULL;
    void *iter = NULL;
    void *method = NULL;
    while ((method = p_il2cpp_class_get_methods(klass, &iter)) != NULL) {
        const char *name = p_il2cpp_method_get_name(method);
        if (!name) continue;
        if (strcmp(name, targetName) != 0) continue;
        if (p_il2cpp_method_get_param_count(method) != targetArgc) continue;
        if (p_il2cpp_method_is_generic(method)) continue;
        return method;
    }
    return NULL;
}

// Object.Instantiate(Object original) - explicit non-generic match.
// Clone goes to root scene with null parent. Use SetParent in a later phase
// to slot it into the home layout.
static void *instantiateCloneNonGeneric(void *originalGo) {
    if (!ptrLooksValid(originalGo)) return NULL;
    if (!p_il2cpp_runtime_invoke
        || !p_il2cpp_object_get_class
        || !p_il2cpp_class_get_parent) return NULL;
    if (!g_method_Instantiate1NonGen) {
        void *goKlass = p_il2cpp_object_get_class(originalGo);
        if (!goKlass) return NULL;
        void *objKlass = p_il2cpp_class_get_parent(goKlass);
        if (!objKlass) return NULL;
        g_method_Instantiate1NonGen = findNonGenericMethod(objKlass, "Instantiate", 1);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached non-generic Instantiate(Object) method=%p (objKlass=%p)",
                  g_method_Instantiate1NonGen, objKlass]);
    }
    if (!g_method_Instantiate1NonGen) return NULL;
    void *originalRef = originalGo;
    void *params[1] = { &originalRef };
    return p_il2cpp_runtime_invoke(g_method_Instantiate1NonGen, NULL, params, NULL);
}

// Direct call into MethodInfo->methodPointer (offset 0 on Unity 6 IL2CPP),
// bypassing runtime_invoke entirely. IL2CPP appends a MethodInfo* slot to
// every method's native signature; the C ABI for the static one-arg
// Object.Instantiate(Object) is:
//   Object* (Object* original, const MethodInfo* method)
// Tried because the runtime_invoke path crashes inside the invoker even
// after the recon confirmed we hold the non-generic method handle. The
// methodPointer is the actually-generated native function, no invoker
// trampoline involved.
typedef void *(*Instantiate1_directABI_t)(void *original, void *methodInfo);

static void *instantiateCloneDirect(void *originalGo) {
    if (!ptrLooksValid(originalGo)) return NULL;
    if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_parent) return NULL;
    if (!g_method_Instantiate1NonGen) {
        void *goKlass = p_il2cpp_object_get_class(originalGo);
        if (!goKlass) return NULL;
        void *objKlass = p_il2cpp_class_get_parent(goKlass);
        if (!objKlass) return NULL;
        g_method_Instantiate1NonGen = findNonGenericMethod(objKlass, "Instantiate", 1);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached non-generic Instantiate(Object) method=%p (objKlass=%p)",
                  g_method_Instantiate1NonGen, objKlass]);
    }
    if (!g_method_Instantiate1NonGen) return NULL;
    void *methodPtr = *(void **)g_method_Instantiate1NonGen;
    if (!methodPtr) {
        file_log(@"[HOME] direct: methodPointer at offset 0 is NULL");
        return NULL;
    }
    file_log([NSString stringWithFormat:
              @"[HOME] direct call: methodPtr=%p methodInfo=%p original=%p",
              methodPtr, g_method_Instantiate1NonGen, originalGo]);
    return ((Instantiate1_directABI_t)methodPtr)(originalGo, g_method_Instantiate1NonGen);
}

// UnityEngine.Object.Instantiate(Object original, Transform parent) - static.
// 2-arg overload picked over the argc=1 version because the argc=1 path
// matched the generic Instantiate<T>(T) descriptor and runtime_invoke
// crashed inside the un-inflated generic call. The 2-arg non-generic
// overload coexists with a generic counterpart too, so we still race the
// lookup; if this also crashes we will need to enumerate methods and
// filter by il2cpp_method_is_generic.
static void *instantiateCloneWithParent(void *originalGo, void *parentTransform) {
    if (!ptrLooksValid(originalGo)) return NULL;
    if (!p_il2cpp_runtime_invoke
        || !p_il2cpp_object_get_class
        || !p_il2cpp_class_get_parent
        || !p_il2cpp_class_get_method_from_name) return NULL;
    if (!g_method_Instantiate2) {
        void *goKlass = p_il2cpp_object_get_class(originalGo);
        if (!goKlass) return NULL;
        void *objKlass = p_il2cpp_class_get_parent(goKlass);
        if (!objKlass) {
            file_log(@"[HOME] Instantiate lookup: parent klass NULL");
            return NULL;
        }
        g_method_Instantiate2 = p_il2cpp_class_get_method_from_name(objKlass, "Instantiate", 2);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Instantiate(Obj,Tf) method=%p (goKlass=%p objKlass=%p)",
                  g_method_Instantiate2, goKlass, objKlass]);
    }
    if (!g_method_Instantiate2) return NULL;
    void *originalRef = originalGo;
    void *parentRef = parentTransform;
    void *params[2] = { &originalRef, &parentRef };
    return p_il2cpp_runtime_invoke(g_method_Instantiate2, NULL, params, NULL);
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

        if (ptrLooksValid(friendBtn)) {
            void *friendGo = gameObjectOf(friendBtn);
            if (ptrLooksValid(friendGo)) {
                file_log([NSString stringWithFormat:
                          @"[HOME] friend gameObject=%p -> SetActive(true)", friendGo]);
                setActive(friendGo, true);
            } else {
                file_log(@"[HOME] friend gameObject lookup failed");
            }
        }

        // Phase 2a attempt 4: bypass runtime_invoke and call methodPointer
        // directly. Thread diagnostic already confirmed main thread = 1, so
        // the runtime_invoke crashes are from something inside the invoker
        // trampoline rather than threading. methodPointer is the actual
        // codegen'd function with the static IL2CPP ABI
        // (Object* (Object* original, MethodInfo* method)).
        (void)giftBtn;
        (void)g_reconLogged;
        (void)logInstantiateMethods;
        (void)instantiateCloneNonGeneric;
        (void)instantiateCloneWithParent;
        (void)transformOf;
        if (!g_cloneCreated && ptrLooksValid(menuBtn)) {
            file_log([NSString stringWithFormat:
                      @"[HOME] presenter.ctor on main thread=%d",
                      (int)[NSThread isMainThread]]);
            void *menuGo = gameObjectOf(menuBtn);
            if (ptrLooksValid(menuGo)) {
                void *cloneGo = instantiateCloneDirect(menuGo);
                if (ptrLooksValid(cloneGo)) {
                    g_cloneCreated = true;
                    file_log([NSString stringWithFormat:
                              @"[HOME] direct: clone gameObject=%p", cloneGo]);
                } else {
                    file_log(@"[HOME] direct: Instantiate returned NULL/invalid");
                }
            }
        }
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
