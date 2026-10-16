# Common tasks. Run `make help` for the list.

DERIVED ?= build/DerivedData

.PHONY: help test project build agent proto icons clean

help:
	@echo "make test     run the host core tests (swift test)"
	@echo "make project  generate host/Avo.xcodeproj (XcodeGen)"
	@echo "make build    build Avo.app (Debug) into $(DERIVED)"
	@echo "make agent    build the Bridge Agent APK (Android SDK + NDK)"
	@echo "make proto    regenerate protocol bindings"
	@echo "make icons    regenerate brand assets"

test:
	cd host/AvoKit && swift test

project:
	cd host && xcodegen generate

build: project
	xcodebuild -project host/Avo.xcodeproj -scheme Avo -configuration Debug -derivedDataPath $(DERIVED) build

agent:
	guest/bridge-agent/build.sh

proto:
	scripts/gen-proto.sh

icons:
	python3 -I branding/tools/generate.py

clean:
	rm -rf $(DERIVED) host/AvoKit/.build guest/bridge-agent/build
