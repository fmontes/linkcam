# Builds the two IOKit helper binaries from source into bin/.
#
# Requires only the macOS Command Line Tools (clang) — no full Xcode.
# The uvc-util sources are MRC-era Objective-C, so -fno-objc-arc is required.

CC      := clang
# Build universal (arm64 + x86_64) so the binaries run on both Apple Silicon
# and Intel Macs. Override on the command line, e.g. `make ARCHS="-arch arm64"`.
ARCHS   := -arch arm64 -arch x86_64
CFLAGS  := $(ARCHS) -fno-objc-arc -Wno-deprecated-declarations -O2
FRAMEWORKS := -framework Foundation -framework IOKit -framework CoreFoundation

SRC     := src
VENDOR  := $(SRC)/vendor
BIN     := bin

VENDOR_OBJS := $(VENDOR)/UVCController.m $(VENDOR)/UVCType.m $(VENDOR)/UVCValue.m

.PHONY: all clean

all: $(BIN)/uvc-util $(BIN)/xu-probe

# Standard UVC controls (pan/tilt/zoom/focus/etc.)
$(BIN)/uvc-util: $(VENDOR)/uvc-util.m $(VENDOR_OBJS) | $(BIN)
	$(CC) -o $@ $(VENDOR)/uvc-util.m $(VENDOR_OBJS) $(FRAMEWORKS) $(CFLAGS)

# Raw vendor Extension Unit access (powers `linkcam ai`)
$(BIN)/xu-probe: $(SRC)/xu-probe.m $(VENDOR_OBJS) | $(BIN)
	$(CC) -o $@ $(SRC)/xu-probe.m $(VENDOR_OBJS) -I$(VENDOR) $(FRAMEWORKS) $(CFLAGS)

$(BIN):
	mkdir -p $(BIN)

clean:
	rm -f $(BIN)/uvc-util $(BIN)/xu-probe
