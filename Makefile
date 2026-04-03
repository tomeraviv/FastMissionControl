PROJECT := FastMissionControl.xcodeproj
SCHEME := FastMissionControl
CONFIGURATION := Release
DERIVED_DATA := build
APP_NAME := FastMissionControl.app
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME)
INSTALL_PATH := /Applications/$(APP_NAME)

.PHONY: help build clean install app-path

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make build     Build $(APP_NAME) into $(APP_PATH)' \
		'  make install   Build and copy $(APP_NAME) into $(INSTALL_PATH)' \
		'  make clean     Remove the local build directory ($(DERIVED_DATA))' \
		'  make app-path  Print the expected built app path'

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA)

clean:
	rm -rf $(DERIVED_DATA)

install: build
	sudo rm -rf $(INSTALL_PATH)
	sudo ditto $(APP_PATH) $(INSTALL_PATH)

app-path:
	@printf '%s\n' './$(APP_PATH)'
