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
KiouEditor_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEditor.dylib"
	# INSTALL_TARGET_PROCESSES = KIOU killed the app; relaunch via whichever launcher tool is present.
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# jailed distribution: copy the built dylib into packages/jailed/ for Sideloadly injection.
jailed:: all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouEditor.dylib packages/jailed/KiouEditor.dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/KiouEditor.dylib"
