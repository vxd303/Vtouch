#export THEOS_DEVICE_IP = 192.168.0.6

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = pccontrol

pccontrol_FILES = Tweak.xm SocketServer.xm Touch.xm Screen.xm Task.xm Process.xm AlertBox.xm Common.xm Record.xm Play.xm Window.xm Popup.xm TemplateMatch.xm ScreenMatch.xm Toast.xm Image.xm ColorPicker.xm UIKeyboard.xm DeviceInfo.xm HardwareKey.xm Scheduler.xm RuntimeUtils.xm H264Stream.xm TouchIndicator/TouchIndicatorWindow.xm TouchIndicator/TouchIndicatorView.xm TouchIndicator/TouchIndicatorCoordinateView.xm TouchIndicator/TouchIndicatorViewList.xm ScriptPlayer.xm Activator/ActivatorListener.xm TextRecognization/VKOcrManager.xm TextRecognization/TextRecognizer.xm UpdateCache.xm
pccontrol_CFLAGS = -Wno-error -Wno-module-import-in-extern-c -fobjc-arc
pccontrol_FRAMEWORKS = UIKit AssetsLibrary AVFoundation CoreMedia CoreVideo IOSurface Photos VideoToolbox
pccontrol_ARCHS =  arm64 arm64e
pccontrol_CCFLAGS = -std=c++11

pccontrol_CFLAGS += -F$(THEOS_PROJECT_DIR)/frameworks
pccontrol_LDFLAGS += -F$(THEOS_PROJECT_DIR)/frameworks
pccontrol_CFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers
pccontrol_CCFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers

pccontrol_PRIVATE_FRAMEWORKS = IOKit MobileCoreServices
pccontrol_EXTRA_FRAMEWORKS = opencv2
pccontrol_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chown -R mobile:mobile /var/mobile/Library/ZXTouch && killall -9 SpringBoard;"
