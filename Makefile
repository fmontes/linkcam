# Builds the native LinkCam CLI and the two low-level diagnostic helpers.
#
# Requires only the macOS Command Line Tools (clang) — no full Xcode.
# The uvc-util sources are MRC-era Objective-C, so -fno-objc-arc is required.

CC      := clang
CODESIGN := codesign
# Build universal (arm64 + x86_64) so the binaries run on both Apple Silicon
# and Intel Macs. Override on the command line, e.g. `make ARCHS="-arch arm64"`.
ARCHS   := -arch arm64 -arch x86_64
CFLAGS  := $(ARCHS) -fno-objc-arc -Wno-deprecated-declarations -O2
FRAMEWORKS := -framework Foundation -framework IOKit -framework CoreFoundation
CORE_FRAMEWORKS := $(FRAMEWORKS) -framework CoreMediaIO
APP_FRAMEWORKS := $(CORE_FRAMEWORKS) -framework AppKit -framework AVFoundation -framework QuartzCore

SRC     := src
VENDOR  := $(SRC)/vendor
CORE    := $(SRC)/core
CLI     := $(SRC)/cli
APP_SRC := $(SRC)/app
APP_DIR := dist/LinkCam.app
APP_CONTENTS := $(APP_DIR)/Contents
APP_EXEC := $(APP_CONTENTS)/MacOS/LinkCam
BIN     := bin
BUILD   := .build

VENDOR_OBJS := $(VENDOR)/UVCController.m $(VENDOR)/UVCType.m $(VENDOR)/UVCValue.m
CORE_SRCS := $(CORE)/LinkCamCore.m $(CORE)/LinkCamMath.c
CORE_HEADERS := $(CORE)/LinkCamCore.h $(CORE)/LinkCamMath.h
APP_SRCS := $(APP_SRC)/main.m $(APP_SRC)/AppDelegate.m $(APP_SRC)/LinkCamPopoverViewController.m $(APP_SRC)/CameraPreviewView.m
APP_HEADERS := $(APP_SRC)/AppDelegate.h $(APP_SRC)/LinkCamPopoverViewController.h $(APP_SRC)/CameraPreviewView.h

.PHONY: all app test clean

all: $(BIN)/linkcam-cli $(BIN)/uvc-util $(BIN)/xu-probe

app: $(APP_EXEC)

$(APP_EXEC): $(APP_SRCS) $(APP_HEADERS) $(CORE_SRCS) $(CORE_HEADERS) $(VENDOR_OBJS) app/Info.plist app/LinkCam.entitlements
	mkdir -p $(APP_CONTENTS)/MacOS $(APP_CONTENTS)/Resources
	$(CC) -o $@ $(APP_SRCS) $(CORE_SRCS) $(VENDOR_OBJS) -I$(APP_SRC) -I$(CORE) -I$(VENDOR) $(APP_FRAMEWORKS) $(CFLAGS) -mmacosx-version-min=13.0
	cp app/Info.plist $(APP_CONTENTS)/Info.plist
	$(CODESIGN) --force --sign - --identifier com.fmontes.linkcam --entitlements app/LinkCam.entitlements --timestamp=none $(APP_DIR)

# User-facing CLI. Camera control is linked directly rather than parsed through
# subprocess output, and the same LinkCamCore sources are reused by the GUI.
$(BIN)/linkcam-cli: $(CLI)/main.m $(CORE_SRCS) $(CORE_HEADERS) $(VENDOR_OBJS) | $(BIN)
	$(CC) -o $@ $(CLI)/main.m $(CORE_SRCS) $(VENDOR_OBJS) -I$(CORE) -I$(VENDOR) $(CORE_FRAMEWORKS) $(CFLAGS)

# Standard UVC controls (pan/tilt/zoom/focus/etc.)
$(BIN)/uvc-util: $(VENDOR)/uvc-util.m $(VENDOR_OBJS) | $(BIN)
	$(CC) -o $@ $(VENDOR)/uvc-util.m $(VENDOR_OBJS) $(FRAMEWORKS) $(CFLAGS)

# Raw vendor Extension Unit access (powers `linkcam ai`)
$(BIN)/xu-probe: $(SRC)/xu-probe.m $(VENDOR_OBJS) | $(BIN)
	$(CC) -o $@ $(SRC)/xu-probe.m $(VENDOR_OBJS) -I$(VENDOR) $(FRAMEWORKS) $(CFLAGS)

$(BIN):
	mkdir -p $(BIN)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/test-math: tests/test_math.c $(CORE)/LinkCamMath.c $(CORE)/LinkCamMath.h | $(BUILD)
	$(CC) -o $@ tests/test_math.c $(CORE)/LinkCamMath.c -I$(CORE) -O2

test: all $(BUILD)/test-math
	$(BUILD)/test-math
	bash tests/test_cli.sh ./linkcam

clean:
	rm -f $(BIN)/linkcam-cli $(BIN)/uvc-util $(BIN)/xu-probe $(BUILD)/test-math
	rm -rf $(APP_DIR)
