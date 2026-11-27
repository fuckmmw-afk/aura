TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE ?= 1
# Symbols kept: a crash in the log names Aura's own frames.
STRIP ?= 0
AURA_VERSION ?= 0.2.0
# The model server's base URL comes from the build environment (a GitHub secret in CI), never from the repository.
AURA_MODELS_URL ?=

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Aura
Aura_FILES := $(shell find Sources -name '*.m' -o -name '*.x' -o -name '*.c')
Aura_CFLAGS := -fobjc-arc -fvisibility=hidden -ISources -DAURA_VERSION='"$(AURA_VERSION)"' -DAURA_MODELS_URL='"$(AURA_MODELS_URL)"' \
	-Wno-deprecated-declarations -Wno-unused-function
Aura_FRAMEWORKS := Foundation UIKit QuartzCore CoreGraphics CoreText CoreImage CoreML Vision Metal CoreMotion Accelerate ImageIO CoreVideo AVFoundation CoreMedia MediaPlayer
# The long Substrate install name: signers like ESign rewrite it in place and need the room.
Aura_LDFLAGS := -Wl,-headerpad_max_install_names
# No Substrate: plain Objective-C runtime swaps, which work on a sideloaded app without a jailbreak.
Aura_LOGOS_DEFAULT_GENERATOR := internal
Aura_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
