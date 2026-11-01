# DynuclearVolume — Notifications and Siri get louder in loud rooms, quieter in quiet ones.
#
# Device build (CI default):   make package FINALPACKAGE=1        (rootless /var/jb)
# Simulator build (local dev): tools/sim-test.sh DynuclearVolume  (Mac, rootful paths)

TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
LDID ?= ldid

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynuclearVolume
DynuclearVolume_FILES = DynuclearVolume.x
DynuclearVolume_CFLAGS = -fobjc-arc
DynuclearVolume_FRAMEWORKS = AVFoundation AudioToolbox
# logos/substrate + AVSystemController/MediaRemote resolve at RUNTIME
# (dynamic_lookup): never link a concrete substrate, never need private stubs.
DynuclearVolume_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# Settings pane (PreferenceLoader bundle). Private Preferences classes are
# declared minimally in DVRootController.m and resolved at runtime — no SDK
# stubs needed, so iOS version drift can't break the build.
BUNDLE_NAME = DynuclearVolumePrefs
DynuclearVolumePrefs_FILES = DynuclearVolumePrefs/DVRootController.m
DynuclearVolumePrefs_INSTALL_PATH = /Library/PreferenceBundles
DynuclearVolumePrefs_CFLAGS = -fobjc-arc
DynuclearVolumePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
DynuclearVolumePrefs_INFO_PLIST = DynuclearVolumePrefs/Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk

# Sign the FINAL staged bytes (Apple Silicon SIGKILLs stale signatures). Staged
# path is scheme-dependent (rootless=/var/jb/..., sim=rootful) → locate dylibs.
ifneq ($(filter simulator%,$(TARGET)),)
# theos defaults sim signing to `codesign --sign 'Apple Development'` (needs a
# real cert); the JB sim accepts ad-hoc — keep the build cert-free.
TARGET_CODESIGN_FLAGS = --force --sign -
SIGN_CMD = codesign --force --sign -
else
SIGN_CMD = $(shell command -v $(LDID) >/dev/null 2>&1 && echo "$(LDID) -S" || echo "codesign --force --sign -")
endif
after-stage::
	@find "$(THEOS_STAGING_DIR)" -name 'DynuclearVolume*.dylib' -type f | while read -r f; do \
	  $(SIGN_CMD) "$$f" && echo "signed: $$f"; done
