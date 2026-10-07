APP := StarlinkViz.app
BIN_DEBUG := .build/debug/StarlinkViz
BIN_RELEASE := .build/release/StarlinkViz
EXEC := $(APP)/Contents/MacOS/StarlinkViz

# Dist packaging (universal Intel + Apple silicon).
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
DIST := dist
STAGE := $(DIST)/stage
DMG := $(DIST)/StarlinkViz-$(VERSION)-macOS-universal.dmg

.PHONY: all build release app app-release run open clean check help \
	build-x86_64 build-arm64 universal app-universal dmg

all: app

build:
	swift build

release:
	swift build -c release

# (Re)build the .app wrapper around the debug binary.
# The raw SwiftPM binary has no Info.plist/bundle, so it runs
# headless — the wrapper is what makes the window + Dock icon appear.
app: build
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN_DEBUG)" "$(EXEC)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --deep --sign - "$(APP)"

app-release: release
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN_RELEASE)" "$(EXEC)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --deep --sign - "$(APP)"

run: app
	open "$(APP)"

open:
	open "$(APP)"

# Dish preflight (same checks as the in-app Settings tab).
check:
	./Tools/check_dish.sh 192.168.100.1

# Universal (Intel + Apple silicon) release binary via lipo.
# Separate --build-path dirs so `make -j2` can compile both archs in parallel.
.build-x86_64/release/StarlinkViz:
	swift build -c release --arch x86_64 --build-path .build-x86_64

.build-arm64/release/StarlinkViz:
	swift build -c release --arch arm64 --build-path .build-arm64

build-x86_64: .build-x86_64/release/StarlinkViz
build-arm64: .build-arm64/release/StarlinkViz

.build-universal/StarlinkViz: .build-x86_64/release/StarlinkViz .build-arm64/release/StarlinkViz
	mkdir -p .build-universal
	lipo -create -output .build-universal/StarlinkViz .build-x86_64/release/StarlinkViz .build-arm64/release/StarlinkViz
	lipo -info .build-universal/StarlinkViz

universal: .build-universal/StarlinkViz

# Dist .app wrapper (under dist/, keeps the dev ./StarlinkViz.app untouched).
app-universal: .build-universal/StarlinkViz
	rm -rf "$(STAGE)/$(APP)"
	mkdir -p "$(STAGE)/$(APP)/Contents/MacOS"
	cp .build-universal/StarlinkViz "$(STAGE)/$(APP)/Contents/MacOS/StarlinkViz"
	cp Resources/Info.plist "$(STAGE)/$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(STAGE)/$(APP)/Contents/PkgInfo"
	codesign --force --deep --sign - "$(STAGE)/$(APP)"

# Drag-to-install DMG: StarlinkViz.app + /Applications alias.
dmg: app-universal
	mkdir -p "$(DIST)"
	ln -sfn /Applications "$(STAGE)/Applications"
	rm -f "$(DMG)"
	hdiutil create -volname "StarlinkViz" -srcfolder "$(STAGE)" -ov -format UDZO "$(DMG)"
	ls -la "$(DMG)"

clean:
	swift package clean

help:
	@echo "Targets:"
	@echo "  make         Build + (re)wrap $(APP) (debug)"
	@echo "  make run     Build + wrap + open the app"
	@echo "  make open    Open $(APP) without rebuilding"
	@echo "  make release / app-release  Optimized build + wrap (native arch)"
	@echo "  make universal            Universal binary (Intel + ARM, via lipo)"
	@echo "  make dmg                  Drag-to-install universal DMG in dist/"
	@echo "  make check   Run Tools/check_dish.sh against 192.168.100.1"
	@echo "  make clean   swift package clean"
