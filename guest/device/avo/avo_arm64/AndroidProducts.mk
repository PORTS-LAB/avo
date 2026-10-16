# Avo Android image products. Build in an AOSP 16 checkout with this
# directory at device/avo/avo_arm64 (see ../README.md):
#
#   source build/envsetup.sh
#   lunch avo_arm64-trunk_staging-userdebug   # development
#   lunch avo_arm64-trunk_staging-user        # release
#   m

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/avo_arm64.mk

COMMON_LUNCH_CHOICES := \
    avo_arm64-trunk_staging-userdebug \
    avo_arm64-trunk_staging-user
