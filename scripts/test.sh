#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_sdk="$(xcrun --show-sdk-path)"
task_flags=(--build-system native --disable-xctest)
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
        task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
    fi
    # CLT places Swift Testing outside SwiftPM's conventional Xcode framework search path.
    task_frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    task_flags+=(-Xswiftc -F -Xswiftc "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks")
fi
swift test "${task_flags[@]}" --sdk "$task_sdk" "$@"
