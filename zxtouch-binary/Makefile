#export THEOS_DEVICE_IP = 192.168.101.245

include $(THEOS)/makefiles/common.mk

TOOL_NAME = zxtouchb zxtouchd

zxtouchb_ARCH = arm64e arm64
zxtouchb_FILES = main.mm
zxtouchb_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchb_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG

zxtouchd_ARCH = arm64e arm64
zxtouchd_FILES = main_daemon.mm DaemonSocketServer.mm DaemonTask.mm
zxtouchd_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchd_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG
zxtouchd_CODESIGN_FLAGS = -Szxtouchd.entitlements
zxtouchd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
