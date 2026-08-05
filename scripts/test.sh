#!/bin/bash
# Runs every package's tests.
#
# The extra flags work around two Command Line Tools gaps (not needed once full
# Xcode is selected):
#   -load-plugin-library : swift-testing's macro plugin lives in a `testing/`
#                          subdirectory that the CLT build system doesn't scan,
#                          so @Test/@Suite fail to expand without it.
#   -rpath x2            : Testing.framework and lib_TestingInterop.dylib ship
#                          outside the default runtime search paths.
set -uo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
FLAGS=(
  -Xswiftc -load-plugin-library
  -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks"
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib"
)

status=0
for package in Packages/*/; do
  name=$(basename "$package")
  output=$(cd "$package" && swift test "${FLAGS[@]}" 2>&1)
  summary=$(echo "$output" | grep 'Test run with' | tail -1)
  if [ -n "$summary" ] && [[ "$summary" != *"failed"* ]]; then
    echo "PASS  $name  with ${summary#*Test run with }"
  else
    status=1
    echo "FAIL  $name"
    echo "$output" | grep -E '✘|error:' | head -5 | sed 's/^/      /'
  fi
done
exit $status
