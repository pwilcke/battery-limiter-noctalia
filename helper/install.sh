#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

# Copies a file into a root-owned path, with the SELinux label that path expects.
put() {
    sudo install -D -o root -g root -m "$1" "$2" "$3"
    if command -v restorecon >/dev/null; then
        sudo restorecon "$3"
    fi
}

# Only a Framework needs framework_tool; a ThinkPad uses the kernel's sysfs thresholds.
# framework_tool is downloaded as the user and checked against the pinned release digest
# before anything runs as root.
if [[ $(</sys/class/dmi/id/sys_vendor) == Framework ]]; then
    tool=$(mktemp)
    trap 'rm -f -- "$tool"' EXIT
    curl --fail --location --silent --show-error --output "$tool" \
        https://github.com/FrameworkComputer/framework-system/releases/download/v0.6.6/framework_tool
    printf '%s  %s\n' ebc2f3ca300dac6f484c02d058833372ff8dd3c23f2a74b63c774f8dc2f86171 "$tool" | sha256sum --check --quiet
    put 755 "$tool" /usr/local/libexec/framework-charge-tool
fi
put 755 framework-charge-limit /usr/local/libexec/framework-charge-limit
put 644 dev.noctalia.framework-charge-limit.policy /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
put 644 framework-charge-limit.service /etc/systemd/system/framework-charge-limit.service
sudo systemctl daemon-reload
# Starting it now saves the current limit, if nothing is saved yet.
sudo systemctl enable --now framework-charge-limit.service
