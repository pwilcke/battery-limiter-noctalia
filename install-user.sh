#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
project=$(pwd -P)
config_directory=${XDG_CONFIG_HOME:-$HOME/.config}/noctalia
mkdir -p "$config_directory"
destination=$config_directory/framework-charge.toml
if [[ -e $destination ]] && ! cmp --silent battery-action.toml "$destination"; then
    printf '%s\n' "Battery action configuration already exists at $destination." >&2
    exit 1
fi
noctalia plugins lint framework-charge
noctalia msg plugins source add framework-charge-dev path "$project"
noctalia msg plugins enable paul/framework-charge
install -m 644 battery-action.toml "$destination"
noctalia msg config-reload
noctalia config validate
