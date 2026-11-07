#!/usr/bin/env bash
# Run the MASTER_HANDOVER_BLUEPRINT.md end-to-end suites on an iOS 18+ iPhone simulator.
# Works the same on a Mac and in CI (.github/workflows/e2e.yml).
#
#   scripts/e2e/run-simulator-tests.sh                 # Blueprint suites (default)
#   SUITE=all scripts/e2e/run-simulator-tests.sh       # every test in OpenVisionTests
#   TEST_RUNNER_OPENVISION_LIVE_GEMINI=1 scripts/e2e/run-simulator-tests.sh   # + real Gemini API
#   SIMULATOR_UDID=<udid> ...                          # pick the simulator yourself
#
# The simulator cannot do Bluetooth (glasses) or the on-device MLX models; checklist tests that
# need the real Ray-Ban hardware are in docs/testing/E2E_TEST_PLAN.md (manual protocol).
set -euo pipefail
cd "$(dirname "$0")/../.."

SUITE="${SUITE:-blueprint}"
DERIVED="${DERIVED_DATA:-DerivedData-sim}"
RESULT="${RESULT_BUNDLE:-build/E2E.xcresult}"

[ -f Config.xcconfig ] || cp Config.xcconfig.example Config.xcconfig
[ -f OpenVision/Config/Config.swift ] || cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
BUNDLE_ID="$(awk -F= '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER/ { gsub(/[[:space:]]/, "", $2); print $2 }' Config.xcconfig)"

# Newest iOS 18+ iPhone, preferring a Pro Max (the iPhone 15 Pro Max class this app targets).
UDID="${SIMULATOR_UDID:-}"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or (int(m.group(1)), int(m.group(2))) < (18, 0):
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            score = ((int(m.group(1)), int(m.group(2))), "Pro Max" in d["name"], "Pro" in d["name"])
            candidates.append((score, d["udid"], d["name"]))
candidates.sort()
print(candidates[-1][1] if candidates else "")
')"
fi
if [ -z "$UDID" ]; then
  echo "error: no iOS 18+ iPhone simulator available (xcrun simctl list devices)" >&2
  exit 1
fi
echo "Simulator: $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

pretty() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify "$@"; else cat; fi; }
COMMON=(
  -project OpenVision.xcodeproj
  -scheme OpenVision
  -destination "id=$UDID"
  -derivedDataPath "$DERIVED"
  -clonedSourcePackagesDirPath .spm
  -skipPackagePluginValidation
  -skipMacroValidation
  CODE_SIGNING_ALLOWED=NO
)

xcodebuild build-for-testing "${COMMON[@]}" | pretty ${XCBEAUTIFY_ARGS:-}

# Install once and grant Photos access, so the real-photo-library tests run instead of skipping.
APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -type d -path '*-iphonesimulator/OpenVision.app' | head -n 1)"
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID" || echo "warning: could not grant Photos access; library tests will skip"

ONLY=()
if [ "$SUITE" = "blueprint" ]; then
  for suite in BlueprintSolverTests BlueprintGeminiE2ETests BlueprintPhotoLibraryE2ETests GeminiLiveSmokeTests; do
    ONLY+=("-only-testing:OpenVisionTests/$suite")
  done
fi

rm -rf "$RESULT"
mkdir -p "$(dirname "$RESULT")"
xcodebuild test-without-building "${COMMON[@]}" ${ONLY[@]+"${ONLY[@]}"} -resultBundlePath "$RESULT" | pretty ${XCBEAUTIFY_ARGS:-}
