TARGET := iphone:10.3:6.1.3
ARCHS := armv7

ADDITIONAL_CFLAGS = -fno-modules -Wno-deprecated-declarations
ADDITIONAL_OBJCFLAGS = -fno-modules -Wno-deprecated-declarations
ADDITIONAL_OBJCXXFLAGS = -fno-modules -Wno-deprecated-declarations

include $(THEOS)/makefiles/common.mk

TOOL_NAME = quietriotd

quietriotd_FILES = src/main.mm src/CaptureEngine.mm src/FifoWriter.mm src/FfmpegProc.mm src/HttpServer.mm

quietriotd_INSTALL_PATH = /usr/local/bin
quietriotd_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo CoreAudio AudioToolbox
quietriotd_LIBRARIES = gcc_s.1

include $(THEOS_MAKE_PATH)/tool.mk
