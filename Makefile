# AlipayFullscreenFix — Theos Makefile
#
# 云编译（GitHub Actions）默认产出 rootless 包（/var/jb，适配 Dopamine / palera1n 等 iOS 15+）。
# 本地有 Mac 想出包：
#   rootless: make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
#   rootful : make package FINALPACKAGE=1
#
# rootless 强制 iOS 14 arm64e 新 ABI，部署目标按 scheme 自动切换。

ARCHS := arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET := iphone:clang:latest:15.0
else
	TARGET := iphone:clang:latest:13.0
endif

INSTALL_TARGET_PROCESSES = AlipayWallet

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AlipayFullscreenFix

AlipayFullscreenFix_FILES = Tweak.xm
AlipayFullscreenFix_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-deprecated-declarations
AlipayFullscreenFix_FRAMEWORKS = UIKit Foundation CoreGraphics
AlipayFullscreenFix_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
