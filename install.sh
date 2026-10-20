#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $EUID == 0 ]]; then
    printf '%s\n' 'Run install.sh as your user; it asks for sudo when it needs root.' >&2
    exit 1
fi
project=$(pwd -P)
if [[ $project == *[[:space:]]* ]]; then
    printf '%s\n' "Noctalia cannot register a plugin path that contains spaces: $project." >&2
    exit 1
fi
config=${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/noctalia/framework-charge.toml
if [[ -e $config ]] && ! cmp --silent battery-action.toml "$config"; then
    printf '%s\n' "Battery action configuration already exists at $config." >&2
    exit 1
fi
noctalia plugins lint framework-charge

# framework_tool is downloaded as the user and checked against the pinned release digest
# before anything runs as root.
tool=$(mktemp)
trap 'rm -f -- "$tool"' EXIT
curl --fail --location --silent --show-error --output "$tool" \
    https://github.com/FrameworkComputer/framework-system/releases/download/v0.6.6/framework_tool
printf '%s  %s\n' ebc2f3ca300dac6f484c02d058833372ff8dd3c23f2a74b63c774f8dc2f86171 "$tool" | sha256sum --check --quiet
sudo install -D -o root -g root -m 755 "$tool" /usr/local/libexec/framework-charge-tool
sudo install -D -o root -g root -m 755 framework-charge-limit /usr/local/libexec/framework-charge-limit
sudo install -D -o root -g root -m 644 dev.noctalia.framework-charge-limit.policy \
    /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
if command -v restorecon >/dev/null; then
    sudo restorecon /usr/local/libexec/framework-charge-tool /usr/local/libexec/framework-charge-limit \
        /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
fi

noctalia msg plugins source add framework-charge path "$project"
noctalia msg plugins enable paul/framework-charge
install -D -m 644 battery-action.toml "$config"
noctalia msg config-reload
noctalia config validate
