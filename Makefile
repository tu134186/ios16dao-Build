ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk
SUBPROJECTS += ios16daoSettings

TWEAK_NAME = ios16dao
ios16dao_FILES = Tweak.xm
ios16dao_CFLAGS = -fobjc-arc
ios16dao_FRAMEWORKS = UIKit QuartzCore CoreFoundation CoreGraphics CoreImage ImageIO AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
