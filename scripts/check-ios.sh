#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/check-foundation.mjs
node --test scripts/check-foundation.test.mjs
node scripts/prepare-client.mjs
swift test --scratch-path "${DAD_SWIFT_BUILD:-/tmp/dad-ios-swift}" --force-resolved-versions
device="${DAD_SIMULATOR_ID:-$(node scripts/simulator.mjs)}"
xcodebuild_args=(-project DAD.xcodeproj -scheme DAD -destination "platform=iOS Simulator,id=$device"
  -derivedDataPath "${DAD_XCODE_BUILD:-/tmp/dad-ios-xcode}" -skipPackagePluginValidation
  CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)")
# Build first so the compile load is over before the simulator is asked to start the first UI test.
xcodebuild "${xcodebuild_args[@]}" build-for-testing
# The test runner and every app launch need the simulator to grant background assertions; starting a
# system app here proves that path works, and fails this step loudly rather than the first UI test.
xcrun simctl bootstatus "$device" -b
xcrun simctl launch "$device" com.apple.Preferences
xcrun simctl terminate "$device" com.apple.Preferences
xcodebuild "${xcodebuild_args[@]}" test-without-building
