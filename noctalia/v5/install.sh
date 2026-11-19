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
configs=${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/noctalia
config=$configs/chargelimit.toml
if [[ -e $config ]] && ! cmp --silent battery-action.toml "$config"; then
    printf '%s\n' "Battery action configuration already exists at $config." >&2
    exit 1
fi
noctalia plugins lint chargelimit

../../install.sh

# The plugin this one replaces: its source registration and its battery action.
noctalia msg plugins source remove framework-charge >/dev/null 2>&1 || true
rm -f -- "$configs/framework-charge.toml"

noctalia msg plugins source add chargelimit path "$project"
noctalia msg plugins enable pwilcke/chargelimit
install -D -m 644 battery-action.toml "$config"
noctalia msg config-reload
noctalia config validate
