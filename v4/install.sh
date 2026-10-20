#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $EUID == 0 ]]; then
    printf '%s\n' 'Run install.sh as your user; it asks for sudo when it needs root.' >&2
    exit 1
fi
plugin=$(pwd -P)/framework-charge
link=${NOCTALIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/noctalia}/plugins/framework-charge
if [[ -e $link || -L $link ]] && [[ $(readlink -f -- "$link") != "$plugin" ]]; then
    printf '%s\n' "Another plugin already exists at $link." >&2
    exit 1
fi

../helper/install.sh

mkdir -p -- "$(dirname -- "$link")"
ln -sfn -- "$plugin" "$link"
printf '%s\n' 'Restart Noctalia, then enable Framework Charge in Settings > Plugins.'
