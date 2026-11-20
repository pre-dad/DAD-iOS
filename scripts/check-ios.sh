#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
plutil -lint DAD.xcodeproj/project.pbxproj App/Info.plist App/DAD.entitlements App/PrivacyInfo.xcprivacy
node scripts/check-foundation.mjs
node --test scripts/check-foundation.test.mjs scripts/check-foundation-drift.test.mjs
if command -v gitleaks >/dev/null; then
  GITLEAKS_BINARY="$(command -v gitleaks)" node --test scripts/check-secrets-config.test.mjs
fi
node scripts/prepare-client.mjs
swift test --scratch-path "${DAD_SWIFT_BUILD:-/tmp/dad-ios-swift}" --force-resolved-versions
device="${DAD_SIMULATOR_ID:-$(node scripts/simulator.mjs)}"
xcode_build="${DAD_XCODE_BUILD:-/tmp/dad-ios-xcode}"
xcodebuild_args=(-project DAD.xcodeproj -scheme DAD -destination "platform=iOS Simulator,id=$device"
  -derivedDataPath "$xcode_build" -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)")
# Build first so the compile load is over before the simulator is asked to start the first UI test.
xcodebuild "${xcodebuild_args[@]}" -configuration Release build
xcodebuild "${xcodebuild_args[@]}" build-for-testing
# The test runner and every app launch need the simulator to grant background assertions; starting a
# system app here proves that path works, and fails this step loudly rather than the first UI test.
xcrun simctl bootstatus "$device" -b
xcrun simctl launch "$device" com.apple.Preferences
xcrun simctl terminate "$device" com.apple.Preferences
# test-without-building can reuse an older installed runner even after rebuilding its test bundle.
# Install both products explicitly so a warm simulator exercises the binaries just compiled.
xcrun simctl install "$device" "$xcode_build/Build/Products/Debug-iphonesimulator/DAD.app"
xcrun simctl install "$device" "$xcode_build/Build/Products/Debug-iphonesimulator/DADUITests-Runner.app"
xcodebuild "${xcodebuild_args[@]}" test-without-building
