CC       ?= clang
CFLAGS   ?= -std=c11 -Wall -Wextra -Wno-unused-parameter -O2 -fvisibility=hidden
ARCHS    ?= -arch arm64 -arch x86_64
FRAMEWORKS = -framework CoreFoundation

LIB = lib/libtimeshift.dylib
BIN = bin/timeshift-probe bin/timeshift-ctl

.PHONY: all clean test check

all: $(LIB) $(BIN)

lib bin:
	@mkdir -p $@

$(LIB): src/timeshift.c | lib
	$(CC) $(CFLAGS) $(ARCHS) -dynamiclib -install_name @rpath/libtimeshift.dylib \
	    -o $@ $<
	codesign -f -s - $@

bin/timeshift-probe: src/probe.c | bin
	$(CC) $(CFLAGS) $(ARCHS) $(FRAMEWORKS) -o $@ $<
	codesign -f -s - $@

bin/timeshift-ctl: src/tsctl.c | bin
	$(CC) $(CFLAGS) $(ARCHS) -o $@ $<
	codesign -f -s - $@

# End-to-end: unshifted, shifted by -90 minutes, and a rate change.
test: all
	@echo "=== baseline (no shim) ==="
	@bin/timeshift-probe
	@echo
	@echo "=== offset -90m ==="
	@bin/timeshift --offset -90m -- bin/timeshift-probe
	@echo
	@echo "=== offset +250ms, monotonic shifted, rate 2x ==="
	@bin/timeshift --offset 250ms --rate 2 --monotonic -- bin/timeshift-probe

check: all
	@bin/timeshift-check bin/timeshift-probe

clean:
	rm -rf lib bin/timeshift-probe bin/timeshift-ctl

# ---------------------------------------------------------------------
# ab6a-timeShift — menubar controller
# ---------------------------------------------------------------------

MENUAPP  = ab6a-timeShift.app
MENUBIN  = $(MENUAPP)/Contents/MacOS/ab6a-timeShift

.PHONY: menubar run-menubar clean-menubar

menubar: $(MENUBIN)

$(MENUBIN): menubar/main.swift
	@mkdir -p $(MENUAPP)/Contents/MacOS $(MENUAPP)/Contents/Resources
	swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
	    -framework AppKit -o $@ $<
	@/usr/libexec/PlistBuddy -c 'Clear dict' \
	    -c 'Add :CFBundleName string ab6a-timeShift' \
	    -c 'Add :CFBundleDisplayName string ab6a-timeShift' \
	    -c 'Add :CFBundleIdentifier string com.ab6a.timeshift' \
	    -c 'Add :CFBundleExecutable string ab6a-timeShift' \
	    -c 'Add :CFBundlePackageType string APPL' \
	    -c 'Add :CFBundleShortVersionString string 1.0' \
	    -c 'Add :CFBundleVersion string 1' \
	    -c 'Add :LSMinimumSystemVersion string 13.0' \
	    -c 'Add :LSUIElement bool true' \
	    -c 'Add :NSMicrophoneUsageDescription string "WSJT-X instances launched by ab6a-timeShift receive radio audio through your sound card." ' \
	    -c 'Add :NSHighResolutionCapable bool true' \
	    $(MENUAPP)/Contents/Info.plist >/dev/null
	codesign -f -s - $(MENUAPP)
	@echo "built $(MENUAPP)"

run-menubar: menubar
	open $(MENUAPP)

clean-menubar:
	rm -rf $(MENUAPP)
