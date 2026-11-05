#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_kind=device
signing=(CODE_SIGNING_ALLOWED=NO)

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    build_kind=signed
    signing=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" -allowProvisioningUpdates)
fi

xcodebuild \
    -project "$project_root/LogitCamera.xcodeproj" \
    -scheme LogitCamera \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$project_root/build/$build_kind" \
    "${signing[@]}" \
    build
