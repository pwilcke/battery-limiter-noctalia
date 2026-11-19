#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $EUID == 0 ]]; then
    printf '%s\n' 'Run install.sh as your user; it asks for sudo when it needs root.' >&2
    exit 1
fi

# Copies a file into a root-owned path, with the SELinux label that path expects.
put() {
    sudo install -D -o root -g root -m "$1" "$2" "$3"
    if command -v restorecon >/dev/null; then
        sudo restorecon "$3"
    fi
}

# Only a Framework needs framework_tool; other laptops use the kernel's sysfs thresholds.
# framework_tool is downloaded as the user and checked against the pinned release digest
# before anything runs as root.
if [[ $(</sys/class/dmi/id/sys_vendor) == Framework ]]; then
    tool=$(mktemp)
    trap 'rm -f -- "$tool"' EXIT
    curl --fail --location --silent --show-error --output "$tool" \
        https://github.com/FrameworkComputer/framework-system/releases/download/v0.6.6/framework_tool
    printf '%s  %s\n' ebc2f3ca300dac6f484c02d058833372ff8dd3c23f2a74b63c774f8dc2f86171 "$tool" | sha256sum --check --quiet
    put 755 "$tool" /usr/local/libexec/chargelimit-framework-tool
fi

# The helper from before the rename from battery-limiter-noctalia. The daemon adopts the
# limit it left in the hardware, so only its files go.
if [[ -e /etc/systemd/system/framework-charge-limit.service ]]; then
    sudo systemctl disable --now framework-charge-limit.service
    sudo rm -rf /etc/systemd/system/framework-charge-limit.service \
        /usr/local/libexec/framework-charge-limit /usr/local/libexec/framework-charge-tool \
        /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy \
        /var/lib/framework-charge-limit /run/framework-charge-limit.lock
fi

put 755 chargelimit /usr/local/bin/chargelimit
put 644 chargelimit.policy /usr/share/polkit-1/actions/dev.chargelimit.write.policy
put 644 chargelimit.service /etc/systemd/system/chargelimit.service
sudo systemctl daemon-reload
sudo systemctl enable chargelimit.service
sudo systemctl restart chargelimit.service
