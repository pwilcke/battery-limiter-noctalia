#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p .vendor
temporary=$(mktemp .vendor/framework_tool.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
curl --fail --location --silent --show-error \
    https://github.com/FrameworkComputer/framework-system/releases/download/v0.6.6/framework_tool \
    --output "$temporary"
printf '%s  %s\n' ebc2f3ca300dac6f484c02d058833372ff8dd3c23f2a74b63c774f8dc2f86171 "$temporary" | sha256sum --check
chmod 755 "$temporary"
mv -- "$temporary" .vendor/framework_tool
