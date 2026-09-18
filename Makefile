# Sign with a Developer ID when one exists, otherwise ad-hoc. This matters
# beyond tidiness: library validation admits a dylib signed by the SAME team as
# the host executable, so a Developer ID-signed shim loads into a Developer
# ID-signed app with the hardened runtime intact and no entitlement waiver.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
             | awk -F'"' '/Developer ID Application/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

CC       ?= clang
CFLAGS   ?= -std=c11 -Wall -Wextra -Wno-unused-parameter -O2 -fvisibility=hidden
ARCHS    ?= -arch arm64 -arch x86_64
FRAMEWORKS = -framework CoreFoundation

LIB = lib/libtimeshift.dylib
BIN = bin/timeshift-probe bin/timeshift-ctl

.PHONY: all clean test check signing-id

all: $(LIB) $(BIN)

signing-id:
	@echo "signing as: $(CODESIGN_ID)"

lib bin:
	@mkdir -p $@

$(LIB): src/timeshift.c | lib
	$(CC) $(CFLAGS) $(ARCHS) -dynamiclib -install_name @rpath/libtimeshift.dylib \
	    -o $@ $<
	codesign -f -s "$(CODESIGN_ID)" $@

bin/timeshift-probe: src/probe.c | bin
	$(CC) $(CFLAGS) $(ARCHS) $(FRAMEWORKS) -o $@ $<
	codesign -f -s "$(CODESIGN_ID)" $@

bin/timeshift-ctl: src/tsctl.c | bin
	$(CC) $(CFLAGS) $(ARCHS) -o $@ $<
	codesign -f -s "$(CODESIGN_ID)" $@

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

MENUAPP = build/AB6A TimeShift.app

.PHONY: menubar run-menubar clean-menubar install

# The bundle name contains a space, which make handles badly in targets, so the
# assembly lives in build-app.sh.
menubar:
	@bash build-app.sh

run-menubar: menubar
	@open "$(MENUAPP)"

# Install where Finder and Spotlight expect it.
install: menubar
	@pkill -f 'AB6A TimeShift.app/Contents/MacOS' 2>/dev/null || true
	@rm -rf "/Applications/AB6A TimeShift.app"
	@ditto "$(MENUAPP)" "/Applications/AB6A TimeShift.app"
	@echo "installed /Applications/AB6A TimeShift.app"

clean-menubar:
	rm -rf build
