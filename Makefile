TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = KIOU
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP = 192.168.0.49

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KiouEditor

KiouEditor_FILES = $(shell find Sources/KiouEditor -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
KIOU_EDITOR_COMMIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

KiouEditor_CFLAGS = -fobjc-arc -Wno-unused-function -DKIOU_EDITOR_COMMIT=\"$(KIOU_EDITOR_COMMIT)\"
KiouEditor_FRAMEWORKS = Foundation UIKit

# ---------------------------------------------------------------------------
# Hook engine selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction live in libsubstrate)
#   JAILED=1                : Dobby, statically linked from vendor/dobby/lib/
#                             libdobby.a so the resulting dylib has no external
#                             hook-engine dependency and can be injected with
#                             Sideloadly into a stock IPA.
#
# Internal.h's MSHookFunction shim picks the matching API via -DKIOU_JAILED=1.
# ---------------------------------------------------------------------------
ifeq ($(JAILED),1)
    KiouEditor_CFLAGS  += -DKIOU_JAILED=1 -Ivendor/dobby/include
    # Dobby is C++; pull in libc++ for __cxa_guard_*, __cxa_pure_virtual, etc.
    KiouEditor_LDFLAGS  = -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
else
    KiouEditor_LDFLAGS  = -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEditor.dylib"
	# INSTALL_TARGET_PROCESSES = KIOU killed the app; relaunch via whichever launcher tool is present.
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# jailed distribution: rebuild with Dobby statically linked, then copy the
# resulting .dylib into packages/jailed/ for Sideloadly injection.
# Verifies the final binary has no libsubstrate/libdobby external dep.
jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouEditor.dylib packages/jailed/KiouEditor.dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/KiouEditor.dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/KiouEditor.dylib 2>/dev/null \
	  || otool -L packages/jailed/KiouEditor.dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# ---------------------------------------------------------------------------
# patched-ipa: rebuild packages/jailed/KIOU-patched.ipa from scratch each time.
#
# The pristine source IPA at targets/Kiou/Kiou-1.0.1.ipa is left untouched;
# we extract it into a staging dir, run tools/patch_unity.py on the embedded
# UnityFramework, then re-zip the result as KIOU-patched.ipa. The output IPA
# is overwritten unconditionally — never patch-on-top, so we don't accumulate
# state from previous runs and `patch_unity.py` always sees vanilla bytes.
#
# Sideloadly is still responsible for injecting packages/jailed/KiouEditor.dylib
# into the IPA and re-signing it; this target only delivers the
# UnityFramework-patched IPA for Sideloadly to consume.
# ---------------------------------------------------------------------------
KIOU_ORIG_IPA       ?= $(CURDIR)/../../../targets/Kiou/Kiou-1.0.1.ipa
KIOU_PATCHED_IPA    ?= $(CURDIR)/packages/jailed/KIOU-patched.ipa
KIOU_IPA_STAGEDIR    = $(THEOS_OBJ_DIR)/ipa-staging
KIOU_UNITY_REL_PATH  = Payload/KIOU.app/Frameworks/UnityFramework.framework/UnityFramework

patched-ipa::
	@test -f "$(KIOU_ORIG_IPA)" || { echo "error: source IPA not found at $(KIOU_ORIG_IPA)"; exit 2; }
	@echo "==> staging $(KIOU_ORIG_IPA) -> $(KIOU_IPA_STAGEDIR)"
	$(ECHO_NOTHING)rm -rf "$(KIOU_IPA_STAGEDIR)"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(KIOU_IPA_STAGEDIR)"$(ECHO_END)
	$(ECHO_NOTHING)cd "$(KIOU_IPA_STAGEDIR)" && unzip -q "$(KIOU_ORIG_IPA)"$(ECHO_END)
	@echo "==> patching UnityFramework via tools/patch_unity.py"
	$(ECHO_NOTHING)python3 tools/patch_unity.py "$(KIOU_IPA_STAGEDIR)/$(KIOU_UNITY_REL_PATH)"$(ECHO_END)
	@echo "==> stamping Info.plist version via tools/stamp_version.py"
	$(ECHO_NOTHING)python3 tools/stamp_version.py \
	    --tag-from tools/patch_unity.py \
	    "$(KIOU_IPA_STAGEDIR)/Payload/KIOU.app/Info.plist"$(ECHO_END)
	@echo "==> repackaging -> $(KIOU_PATCHED_IPA)"
	$(ECHO_NOTHING)mkdir -p "$(dir $(KIOU_PATCHED_IPA))"$(ECHO_END)
	$(ECHO_NOTHING)rm -f "$(KIOU_PATCHED_IPA)"$(ECHO_END)
	$(ECHO_NOTHING)cd "$(KIOU_IPA_STAGEDIR)" && zip -qr1 "$(KIOU_PATCHED_IPA)" Payload$(ECHO_END)
	@echo "$(KIOU_PATCHED_IPA) ready ($$(stat -c%s "$(KIOU_PATCHED_IPA)") bytes)"
