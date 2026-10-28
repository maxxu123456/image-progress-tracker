#!/bin/zsh
# Verifies the .ptcollection codec (Image Progress Tracker/Utility/CollectionArchiveFormat.swift)
# against docs/ptcollection-format.md. macOS command-line harness; no simulator or Xcode target needed.
#
#   ./run.sh           test suite (release, debug, ASan), fuzzing, cross-check, SwiftData dates, iOS typecheck
#   ./run.sh --quick   test suite (release) + 200k fuzz iterations only
#
#  1. test suite: release (-O), debug (-Onone -D DEBUG: bounds-checked buffers + writer self-check), ASan
#  2. seeded fuzz campaigns: 10M mixed (release), 1M raw, 1M structure-aware, 300k debug, 300k ASan
#  3. agreement with the independent Python reference model (reference/ref.py), 10,000 + 100,000 cases
#  4. SwiftData on-disk date persistence with the app's own models
#  5. iOS 27.1 simulator typecheck of the codec file
set -e
export PYTHONDONTWRITEBYTECODE=1
HERE=${0:A:h}
APP="${HERE:h:h}/Image Progress Tracker"
CODEC="$APP/Utility/CollectionArchiveFormat.swift"
B=$HERE/.build
mkdir -p $B/tmp $B/xcheck
SW=(xcrun swiftc -swift-version 5)
cd $HERE

echo "### build"
$SW -O "$CODEC" support/support.swift tests/main.swift -o $B/tests
$SW -O "$CODEC" support/support.swift fuzz/main.swift -o $B/fuzz
if [[ "$1" == "--quick" ]]; then
  $B/tests $B/tmp | grep -E "^(FAIL|TOTAL)"
  $B/fuzz 200000 1 $B/tmp mixed | grep -E "^(FUZZ|violations)"
  echo "QUICK DONE"; exit 0
fi
$SW -strict-concurrency=complete -warnings-as-errors -parse-as-library -typecheck "$CODEC"
$SW -Onone -D DEBUG -g "$CODEC" support/support.swift tests/main.swift -o $B/tests-debug
$SW -O -sanitize=address "$CODEC" support/support.swift tests/main.swift -o $B/tests-asan
$SW -Onone -D DEBUG "$CODEC" support/support.swift fuzz/main.swift -o $B/fuzz-debug
$SW -O -sanitize=address "$CODEC" support/support.swift fuzz/main.swift -o $B/fuzz-asan
$SW -O "$CODEC" support/support.swift xcheck/main.swift -o $B/xcheck-bin
$SW -O "$CODEC" "$APP/Models/TrackerGroup.swift" "$APP/Models/TrackerItem.swift" support/support.swift swiftdata/main.swift -o $B/swiftdata

for t in tests tests-debug tests-asan; do echo "### $t"; $B/$t $B/tmp | grep -E "^(FAIL|GROUP|TOTAL)"; done
for spec in "fuzz 10000000 20261027 mixed" "fuzz 1000000 11 raw" "fuzz 1000000 12 struct" "fuzz-debug 300000 13 mixed" "fuzz-asan 300000 14 mixed"; do
  set -- ${=spec}; echo "### $1 $2 seed=$3 $4"; $B/$1 $2 $3 $B/tmp $4 | grep -E "^(FUZZ|outcomes|raw acc|slowest|violations)"
done
for n in "10000 271828" "100000 31415"; do
  set -- ${=n}; echo "### cross-check $1 cases seed $2"
  python3 -I xcheck/gen.py $HERE/reference $B/xcheck $1 $2 >/dev/null; $B/xcheck-bin $B/xcheck
  python3 -I -c "import sys; e=open(sys.argv[1]).read().splitlines(); a=open(sys.argv[2]).read().splitlines(); d=sum(x!=y for x,y in zip(e,a)); print('cases', len(e), 'disagreements', d + abs(len(e)-len(a))); raise SystemExit(1 if d or len(e)!=len(a) else 0)" $B/xcheck/expected.txt $B/xcheck/actual.txt
done
echo "### swiftdata"; $B/swiftdata $B/tmp
echo "### iOS typecheck"; xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios27.1-simulator "$CODEC" && echo "iOS 27.1 simulator typecheck: OK"
echo "ALL DONE"
