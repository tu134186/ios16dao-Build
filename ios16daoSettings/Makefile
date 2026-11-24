include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = ios16daoSettings
ios16daoSettings_FILES = DAOListController.m DAOAdjustCell.m DAOAppListController.m
ios16daoSettings_INSTALL_PATH = /Library/PreferenceBundles
ios16daoSettings_RESOURCE_DIRS = Resources
ios16daoSettings_FRAMEWORKS = UIKit CoreFoundation
ios16daoSettings_PRIVATE_FRAMEWORKS = Preferences
ios16daoSettings_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/bundle.mk

ADDITIONAL_LDFLAGS += -Wl,-undefined,dynamic_lookup
