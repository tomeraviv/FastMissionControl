PROJECT := FastMissionControl.xcodeproj
SCHEME := FastMissionControl
CONFIGURATION := Release
DERIVED_DATA := build
APP_NAME := FastMissionControl.app
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME)
INSTALL_PATH := /Applications/$(APP_NAME)
TEST_CONFIGURATION := Debug
ARCHIVE_BASENAME ?= $(SCHEME)-macOS
ARCHIVE_PATH := $(DERIVED_DATA)/$(ARCHIVE_BASENAME).zip
XCODEBUILD_FLAGS ?=
RELEASE_ARCHS ?= arm64 x86_64

.PHONY: help build test clean install app-path release-zip release-path

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make build     Build $(APP_NAME) into $(APP_PATH)' \
		'  make test      Run FastMissionControlTests on macOS' \
		'  make install   Build and copy $(APP_NAME) into $(INSTALL_PATH)' \
		'  make release-zip  Build a universal $(APP_NAME) zip into $(ARCHIVE_PATH)' \
		'  make clean     Remove the local build directory ($(DERIVED_DATA))' \
		'  make app-path  Print the expected built app path' \
		'  make release-path  Print the expected packaged zip path'

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_FLAGS)

test:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(TEST_CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:FastMissionControlTests \
		$(XCODEBUILD_FLAGS)

clean:
	rm -rf $(DERIVED_DATA)

install: build
	sudo rm -rf $(INSTALL_PATH)
	sudo ditto $(APP_PATH) $(INSTALL_PATH)

release-zip:
	$(MAKE) build XCODEBUILD_FLAGS='$(strip $(XCODEBUILD_FLAGS) ONLY_ACTIVE_ARCH=NO ARCHS="$(RELEASE_ARCHS)")'
	rm -f $(ARCHIVE_PATH)
	ditto -c -k --sequesterRsrc --keepParent $(APP_PATH) $(ARCHIVE_PATH)

app-path:
	@printf '%s\n' './$(APP_PATH)'

release-path:
	@printf '%s\n' './$(ARCHIVE_PATH)'
