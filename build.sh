#!/bin/zsh

# MARK: Help

# Syntax: ./build.sh <platform?> <config?>"
# Valid platforms are: mac, ios & all (Default: all)
# Valid configurations are: debug & release (Default: release)

# MARK: Settings

BINARY_PATH_IOS="Bin/ios"
BUILD_PATH_IOS=".build/arm64-apple-ios"

BINARY_PATH_MACOS="Bin/macos"
BUILD_PATH_MACOS=".build"

# MARK: Inputs

TARGET=$1
CONFIG=$2

if [[ ! $TARGET ]]; then
	TARGET="all"
fi

if [[ ! $CONFIG ]]; then
	CONFIG="release"
fi

# This array is no longer needed here, but kept for structure if you add more commands
COPY_COMMANDS=()

# MARK: Build iOS

build_ios() {
	xcodebuild \
		-scheme "iOS Plugins-Package" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$BUILD_PATH_IOS" \
		-clonedSourcePackagesDirPath ".build" \
		-configuration "$1" \
		-skipPackagePluginValidation \
		-quiet

	if [[ $? -gt 0 ]]; then
		echo "${BOLD}${RED}Failed to build $target iOS library${RESET_FORMATTING}"
		return 1
	fi

	echo "${BOLD}${GREEN}iOS build succeeded${RESET_FORMATTING}"

	# Copy your built plugin frameworks
	product_path="$BUILD_PATH_IOS/Build/Products/$1-iphoneos/PackageFrameworks"
	source_path="Sources"
	for source in $source_path/*; do
		cp -af "$product_path/$source:t:r.framework" "$BINARY_PATH_IOS"
	done
	# --- The line copying SwiftGodot.framework has been removed from here ---

	return 0
}

# MARK: Build macOS

build_macos() {
	swift build \
		--configuration "$1" \
		--scratch-path "$BUILD_PATH_MACOS" \
		--quiet

	if [[ $? -gt 0 ]]; then
		echo "${BOLD}${RED}Failed to build macOS library${RESET_FORMATTING}"
		return 1
	fi

	echo "${BOLD}${GREEN}macOS build succeeded${RESET_FORMATTING}"

	if [[ $(uname -m) == "x86_64" ]]; then
		product_path="$BUILD_PATH_MACOS/x86_64-apple-macosx/$1"
	else
		product_path="$BUILD_PATH_MACOS/arm64-apple-macosx/$1"
	fi

	# Copy your built plugin dylibs
	source_path="Sources"
	for folder in $source_path/*; do
		cp -af "$product_path/lib$folder:t:r.dylib" "$BINARY_PATH_MACOS"
	done

	# --- The line copying libSwiftGodot.dylib has been removed from here ---

	return 0
}

# MARK: Pre & Post process

build_libs() {
	echo "Building libraries..."

	if [[ "$1" == "all" || "$1" == "macos" ]]; then
		echo "${BOLD}${CYAN}Building macOS library ($2)...${RESET_FORMATTING}"
		build_macos "$2"
	fi

	if [[ "$1" == "all" || "$1" == "ios" ]]; then
		echo "${BOLD}${CYAN}Building iOS libraries ($2)...${RESET_FORMATTING}"
		build_ios "$2"
	fi

	# --- NEW SECTION: Copy the pre-compiled SwiftGodot binary ---
	echo "${BOLD}${CYAN}Copying SwiftGodot binary...${RESET_FORMATTING}"
	# Find the downloaded SwiftGodot.xcframework in the package cache
	SWIFTGODOT_PATH=$(find .build -path "*/*/SwiftGodot.xcframework" -print -quit)

	if [[ -z "$SWIFTGODOT_PATH" ]]; then
		echo "${BOLD}${RED}Could not find SwiftGodot.xcframework. Please run 'swift package update' first.${RESET_FORMATTING}"
		exit 1
	fi

	echo "Found SwiftGodot at: $SWIFTGODOT_PATH"

	# Copy it to the iOS bin directory if needed
	if [[ "$1" == "all" || "$1" == "ios" ]]; then
		mkdir -p "$BINARY_PATH_IOS"
		cp -R "$SWIFTGODOT_PATH" "$BINARY_PATH_IOS/"
	fi

	# Copy it to the macOS bin directory if needed
	if [[ "$1" == "all" || "$1" == "macos" ]]; then
		mkdir -p "$BINARY_PATH_MACOS"
		cp -R "$SWIFTGODOT_PATH" "$BINARY_PATH_MACOS/"
	fi
	# --- END NEW SECTION ---

	echo "${BOLD}${GREEN}Finished building $2 libraries for $1 platforms${RESET_FORMATTING}"
}

# MARK: Formatting
BOLD="$(tput bold)"
GREEN="$(tput setaf 2)"
CYAN="$(tput setaf 6)"
RED="$(tput setaf 1)"
RESET_FORMATTING="$(tput sgr0)"

# MARK: Run
build_libs "$TARGET" "$CONFIG"
