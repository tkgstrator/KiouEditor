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
static void *g_method_get_transform      = NULL;  // Component.get_transform (cached off Component-derived obj)
static void *g_method_GO_get_transform   = NULL;  // GameObject.get_transform
static void *g_method_SetActive          = NULL;  // GameObject.SetActive
static void *g_method_Instantiate2       = NULL;  // UnityEngine.Object.Instantiate(Object, Transform)
static void *g_method_Instantiate1NonGen = NULL;  // UnityEngine.Object.Instantiate(Object) non-generic
static void *g_method_Tf_get_parent      = NULL;  // Transform.get_parent
static void *g_method_Tf_SetParent       = NULL;  // Transform.SetParent(Transform,bool)
static void *g_method_Tf_GetSiblingIndex = NULL;  // Transform.GetSiblingIndex
static void *g_method_Tf_SetSiblingIndex = NULL;  // Transform.SetSiblingIndex(int)
static void *g_method_Tf_get_childCount  = NULL;  // Transform.get_childCount
static void *g_method_Tf_GetChild        = NULL;  // Transform.GetChild(int)
static void *g_method_Obj_get_name       = NULL;  // UnityEngine.Object.get_name

// Once-per-app-session guard so a HomeUtilityPresenter re-creation does not
// pile up duplicate clones on the home screen.
static bool g_cloneCreated = false;

// GameObject pointer of the menu-button clone. The clone's own UIButtonBase
// component is not tracked directly - instead the OnPointerClick hook calls
// Component.get_gameObject(self) and compares against this pointer. Set
// once Phase 2a's Instantiate succeeds, read by hook_UIBtn_OnPointerClick.
static void *g_cloneGo = NULL;

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

// GameObject.get_transform - returns the GameObject's transform. Separate
// from the Component.get_transform cache because they live on different
// klasses and the il2cpp method handles are not interchangeable.
static void *goTransformOf(void *gameObject) {
    if (!ptrLooksValid(gameObject)) return NULL;
    if (!g_method_GO_get_transform) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return NULL;
        void *klass = p_il2cpp_object_get_class(gameObject);
        if (!klass) return NULL;
        g_method_GO_get_transform = p_il2cpp_class_get_method_from_name(klass, "get_transform", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached GameObject.get_transform method=%p (klass=%p)",
                  g_method_GO_get_transform, klass]);
    }
    return invoke0(g_method_GO_get_transform, gameObject);
}

// Transform.get_parent - the Transform parent in the scene hierarchy.
static void *transformParentOf(void *transformObj) {
    if (!ptrLooksValid(transformObj)) return NULL;
    if (!g_method_Tf_get_parent) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return NULL;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return NULL;
        g_method_Tf_get_parent = p_il2cpp_class_get_method_from_name(klass, "get_parent", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Transform.get_parent method=%p (klass=%p)",
                  g_method_Tf_get_parent, klass]);
    }
    return invoke0(g_method_Tf_get_parent, transformObj);
}

// Transform.SetParent(Transform parent, bool worldPositionStays).
// runtime_invoke hung the main thread on this method (same invoker_method
// problem the static Instantiate hit), so we go through methodPointer.
// IL2CPP instance-method ABI for this signature:
//   void (Transform* this, Transform* parent, bool wps, MethodInfo* method)
typedef void (*Tf_SetParent_directABI_t)(void *thisTf, void *parent, bool wps, void *methodInfo);

static void transformSetParent(void *transformObj, void *newParent, bool worldPositionStays) {
    if (!ptrLooksValid(transformObj)) return;
    if (!g_method_Tf_SetParent) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return;
        g_method_Tf_SetParent = p_il2cpp_class_get_method_from_name(klass, "SetParent", 2);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Transform.SetParent(Tf,bool) method=%p (klass=%p)",
                  g_method_Tf_SetParent, klass]);
    }
    if (!g_method_Tf_SetParent) return;
    void *methodPtr = *(void **)g_method_Tf_SetParent;
    if (!methodPtr) {
        file_log(@"[HOME] Tf.SetParent direct: methodPointer NULL");
        return;
    }
    file_log([NSString stringWithFormat:
              @"[HOME] Tf.SetParent direct: methodPtr=%p this=%p parent=%p wps=%d",
              methodPtr, transformObj, newParent, (int)worldPositionStays]);
    ((Tf_SetParent_directABI_t)methodPtr)(transformObj, newParent, worldPositionStays, g_method_Tf_SetParent);
}

// Transform.GetSiblingIndex -> Int32. Direct call instead of runtime_invoke
// for the same reason as above; this also dodges the boxed value-type
// return path entirely (the direct ABI just returns int32 by value).
typedef int32_t (*Tf_GetSiblingIndex_directABI_t)(void *thisTf, void *methodInfo);

static int32_t transformGetSiblingIndex(void *transformObj) {
    if (!ptrLooksValid(transformObj)) return -1;
    if (!g_method_Tf_GetSiblingIndex) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return -1;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return -1;
        g_method_Tf_GetSiblingIndex = p_il2cpp_class_get_method_from_name(klass, "GetSiblingIndex", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Transform.GetSiblingIndex method=%p (klass=%p)",
                  g_method_Tf_GetSiblingIndex, klass]);
    }
    if (!g_method_Tf_GetSiblingIndex) return -1;
    void *methodPtr = *(void **)g_method_Tf_GetSiblingIndex;
    if (!methodPtr) {
        file_log(@"[HOME] Tf.GetSiblingIndex direct: methodPointer NULL");
        return -1;
    }
    return ((Tf_GetSiblingIndex_directABI_t)methodPtr)(transformObj, g_method_Tf_GetSiblingIndex);
}

typedef int32_t (*Tf_get_childCount_directABI_t)(void *thisTf, void *methodInfo);
typedef void *(*Tf_GetChild_directABI_t)(void *thisTf, int32_t idx, void *methodInfo);
typedef void *(*Obj_get_name_directABI_t)(void *thisObj, void *methodInfo);

static int32_t transformChildCount(void *transformObj) {
    if (!ptrLooksValid(transformObj)) return 0;
    if (!g_method_Tf_get_childCount) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return 0;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return 0;
        g_method_Tf_get_childCount = p_il2cpp_class_get_method_from_name(klass, "get_childCount", 0);
    }
    if (!g_method_Tf_get_childCount) return 0;
    void *methodPtr = *(void **)g_method_Tf_get_childCount;
    if (!methodPtr) return 0;
    return ((Tf_get_childCount_directABI_t)methodPtr)(transformObj, g_method_Tf_get_childCount);
}

static void *transformGetChild(void *transformObj, int32_t idx) {
    if (!ptrLooksValid(transformObj)) return NULL;
    if (!g_method_Tf_GetChild) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return NULL;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return NULL;
        g_method_Tf_GetChild = p_il2cpp_class_get_method_from_name(klass, "GetChild", 1);
    }
    if (!g_method_Tf_GetChild) return NULL;
    void *methodPtr = *(void **)g_method_Tf_GetChild;
    if (!methodPtr) return NULL;
    return ((Tf_GetChild_directABI_t)methodPtr)(transformObj, idx, g_method_Tf_GetChild);
}

// UnityEngine.Object.get_name -> System.String. Walks up the klass chain
// once on first hit since Transform's klass redeclares get_name only if
// overridden - but get_method_from_name searches parents too in IL2CPP.
static NSString *objectName(void *unityObj) {
    if (!ptrLooksValid(unityObj)) return nil;
    if (!g_method_Obj_get_name) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return nil;
        void *klass = p_il2cpp_object_get_class(unityObj);
        if (!klass) return nil;
        g_method_Obj_get_name = p_il2cpp_class_get_method_from_name(klass, "get_name", 0);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Object.get_name method=%p (klass=%p)",
                  g_method_Obj_get_name, klass]);
    }
    if (!g_method_Obj_get_name) return nil;
    void *methodPtr = *(void **)g_method_Obj_get_name;
    if (!methodPtr) return nil;
    void *strObj = ((Obj_get_name_directABI_t)methodPtr)(unityObj, g_method_Obj_get_name);
    return il2cppStringToNSString(strObj);
}

// Walk the Transform tree under `tfObj`, log each node's name with
// indentation. The clone is brand new so we cap depth to keep the log
// readable. Used purely as a recon pass for Phase 2c (label rewrite).
static void dumpHierarchy(void *tfObj, int depth, int maxDepth) {
    if (!ptrLooksValid(tfObj)) return;
    if (depth > maxDepth) return;
    NSString *name = objectName(tfObj);
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];
    file_log([NSString stringWithFormat:
              @"[HOME] hier %@tf=%p name=%@",
              indent, tfObj, name ?: @"<null>"]);
    int32_t cc = transformChildCount(tfObj);
    for (int32_t i = 0; i < cc; i++) {
        void *child = transformGetChild(tfObj, i);
        dumpHierarchy(child, depth + 1, maxDepth);
    }
}

typedef void (*Tf_SetSiblingIndex_directABI_t)(void *thisTf, int32_t idx, void *methodInfo);

static void transformSetSiblingIndex(void *transformObj, int32_t idx) {
    if (!ptrLooksValid(transformObj)) return;
    if (!g_method_Tf_SetSiblingIndex) {
        if (!p_il2cpp_object_get_class || !p_il2cpp_class_get_method_from_name) return;
        void *klass = p_il2cpp_object_get_class(transformObj);
        if (!klass) return;
        g_method_Tf_SetSiblingIndex = p_il2cpp_class_get_method_from_name(klass, "SetSiblingIndex", 1);
        file_log([NSString stringWithFormat:
                  @"[HOME] cached Transform.SetSiblingIndex method=%p (klass=%p)",
                  g_method_Tf_SetSiblingIndex, klass]);
    }
    if (!g_method_Tf_SetSiblingIndex) return;
    void *methodPtr = *(void **)g_method_Tf_SetSiblingIndex;
    if (!methodPtr) {
        file_log(@"[HOME] Tf.SetSiblingIndex direct: methodPointer NULL");
        return;
    }
    ((Tf_SetSiblingIndex_directABI_t)methodPtr)(transformObj, idx, g_method_Tf_SetSiblingIndex);
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
// Settings UI bridge - implemented in Hook_SettingsUI.m (Phase 2e). Called
// from the OnPointerClick hook when the clone is tapped.
// ---------------------------------------------------------------------------
extern void kioueditor_presentSettings(void);

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

#define RVA_UIBUTTONBASE_ONPOINTERCLICK 0x5DD1E08

typedef void (*HUP_ctor_t)(void *self, void *view);
typedef void (*UIBtn_OnPointerClick_t)(void *self, void *eventData, void *methodInfo);

static HUP_ctor_t orig_HUP_ctor = NULL;
static UIBtn_OnPointerClick_t orig_UIBtn_OnPointerClick = NULL;

// UIButtonBase.IPointerClickHandler.OnPointerClick - fires for every
// UIButtonBase-derived button (including UIButton, since UIButton does not
// override slot 17). We compare each call's `this.gameObject` against the
// menu-button clone we created in Phase 2a; on match, dispatch to the
// KiouEditor settings UI and skip orig (the clone's _onClick Subject has
// no subscribers anyway, so calling orig would be a no-op, but skipping it
// also avoids any future hidden subscribers).
static void hook_UIBtn_OnPointerClick(void *self, void *eventData, void *methodInfo) {
    @try {
        if (g_cloneGo && ptrLooksValid(self)) {
            void *thisGo = gameObjectOf(self);
            if (thisGo == g_cloneGo) {
                file_log([NSString stringWithFormat:
                          @"[HOME] click on clone! self=%p go=%p", self, thisGo]);
                kioueditor_presentSettings();
                return;
            }
        }
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[HOME] OnPointerClick exc: %@", e]);
    }
    if (orig_UIBtn_OnPointerClick) {
        orig_UIBtn_OnPointerClick(self, eventData, methodInfo);
    }
}

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

        if (!kiou_featureEnabled(KIOU_FEATURE_FRIEND_UNHIDE)) {
            return;
        }
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
        if (!g_cloneCreated && ptrLooksValid(menuBtn) && ptrLooksValid(friendBtn)) {
            file_log([NSString stringWithFormat:
                      @"[HOME] presenter.ctor on main thread=%d",
                      (int)[NSThread isMainThread]]);
            void *menuGo = gameObjectOf(menuBtn);
            if (ptrLooksValid(menuGo)) {
                void *cloneGo = instantiateCloneDirect(menuGo);
                if (ptrLooksValid(cloneGo)) {
                    g_cloneCreated = true;
                    g_cloneGo = cloneGo;
                    file_log([NSString stringWithFormat:
                              @"[HOME] direct: clone gameObject=%p", cloneGo]);

                    // Phase 2b: slot the clone into the friend button's parent
                    // container, one position below the friend button.
                    void *friendTf = transformOf(friendBtn);
                    void *cloneTf  = goTransformOf(cloneGo);
                    file_log([NSString stringWithFormat:
                              @"[HOME] phase2b: friendTf=%p cloneTf=%p",
                              friendTf, cloneTf]);
                    if (ptrLooksValid(friendTf) && ptrLooksValid(cloneTf)) {
                        void *parentTf = transformParentOf(friendTf);
                        file_log([NSString stringWithFormat:
                                  @"[HOME] phase2b: parentTf=%p", parentTf]);
                        if (ptrLooksValid(parentTf)) {
                            transformSetParent(cloneTf, parentTf, false);
                            int32_t friendIdx = transformGetSiblingIndex(friendTf);
                            file_log([NSString stringWithFormat:
                                      @"[HOME] phase2b: friend siblingIndex=%d", friendIdx]);
                            if (friendIdx >= 0) {
                                transformSetSiblingIndex(cloneTf, friendIdx + 1);
                                file_log([NSString stringWithFormat:
                                          @"[HOME] phase2b: clone -> siblingIndex=%d",
                                          friendIdx + 1]);
                            }
                        }
                    }

                    // Phase 2c recon: dump the clone's transform subtree so
                    // we can spot the label node (TMP / Text) to overwrite.
                    file_log(@"[HOME] phase2c recon: dump clone hierarchy");
                    dumpHierarchy(cloneTf, 0, 6);

                    // Compare against the live menu / friend buttons - if
                    // the clone tree looks too shallow it might be because
                    // children spawn lazily after ctor; the live buttons
                    // are fully populated by now.
                    file_log(@"[HOME] phase2c recon: dump menu (original) hierarchy");
                    void *menuTf = transformOf(menuBtn);
                    dumpHierarchy(menuTf, 0, 6);
                    file_log(@"[HOME] phase2c recon: dump friend (live) hierarchy");
                    dumpHierarchy(friendTf, 0, 6);
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

    {
        uintptr_t addr = unityBase + RVA_HOME_UTILITY_PRESENTER_CTOR;
        MSHookFunction((void *)addr,
                       (void *)hook_HUP_ctor,
                       (void **)&orig_HUP_ctor);
        file_log([NSString stringWithFormat:
                  @"HomeUtilityPresenter.ctor hooked @0x%lx (base+0x%x)",
                  (unsigned long)addr, RVA_HOME_UTILITY_PRESENTER_CTOR]);
    }
    {
        uintptr_t addr = unityBase + RVA_UIBUTTONBASE_ONPOINTERCLICK;
        MSHookFunction((void *)addr,
                       (void *)hook_UIBtn_OnPointerClick,
                       (void **)&orig_UIBtn_OnPointerClick);
        file_log([NSString stringWithFormat:
                  @"UIButtonBase.OnPointerClick hooked @0x%lx (base+0x%x)",
                  (unsigned long)addr, RVA_UIBUTTONBASE_ONPOINTERCLICK]);
    }
}
