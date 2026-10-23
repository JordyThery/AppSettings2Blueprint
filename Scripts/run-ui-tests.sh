#!/bin/zsh
# Runs the UI tests (AppSettings2BlueprintUITests) against the Debug build.
# They need no Jamf connection: they drive the rule builder, the lookups and
# local files only. Pass test names to run a subset, for example:
#   Scripts/run-ui-tests.sh RuleBuilderUITests/testIOSAppList
# The first run asks macOS to allow UI automation for Xcode's test runner.
set -e
cd "$(dirname "$0")/.."
WORK="$(mktemp -d /tmp/as2b-uitests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

xcodebuild build-for-testing -project AppSettings2Blueprint.xcodeproj -scheme AppSettings2BlueprintUITests \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$WORK/DerivedData" -quiet

ONLY=()
for test in "$@"; do ONLY+=("-only-testing:AppSettings2BlueprintUITests/$test"); done

set +e
xcodebuild test-without-building -project AppSettings2Blueprint.xcodeproj -scheme AppSettings2BlueprintUITests \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$WORK/DerivedData" "${ONLY[@]}" > "$WORK/test.log" 2>&1
STATUS=$?
set -e
grep -E "error:|Test Case .*(passed|failed)|Executed [0-9]+ test" "$WORK/test.log" || tail -40 "$WORK/test.log"
if (( STATUS != 0 )); then
    # The failing test's accessibility tree, printed by the test case's tearDown.
    sed -n '/UIDUMP-BEGIN/,/UIDUMP-END/p' "$WORK/test.log" | head -400 > "$WORK/uidump.txt"
    if [[ -s "$WORK/uidump.txt" ]]; then cp "$WORK/uidump.txt" /tmp/as2b-uidump.txt; echo "UI tree of the failure: /tmp/as2b-uidump.txt"; fi
fi
# Screenshots (failures, and the ones tests keep on purpose) are attachments in the result bundle.
RESULT="$(ls -td "$WORK"/DerivedData/Logs/Test/*.xcresult 2>/dev/null | head -1)"
rm -rf /tmp/as2b-uitest-attachments
if [[ -n "$RESULT" ]] && xcrun xcresulttool export attachments --path "$RESULT" --output-path /tmp/as2b-uitest-attachments >/dev/null 2>&1 \
    && [[ -n "$(ls -A /tmp/as2b-uitest-attachments 2>/dev/null)" ]]; then
    echo "Screenshots: /tmp/as2b-uitest-attachments"
fi
exit $STATUS
