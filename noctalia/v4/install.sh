#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $EUID == 0 ]]; then
    printf '%s\n' 'Run install.sh as your user; it asks for sudo when it needs root.' >&2
    exit 1
fi
plugin=$(pwd -P)/chargelimit
plugins=${NOCTALIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/noctalia}/plugins
link=$plugins/chargelimit
if [[ -e $link || -L $link ]] && [[ $(readlink -f -- "$link") != "$plugin" ]]; then
    printf '%s\n' "Another plugin already exists at $link." >&2
    exit 1
fi

../../install.sh

mkdir -p -- "$plugins"
ln -sfn -- "$plugin" "$link"

# The plugin before the rename, linked from the old repo layout. Only its settings move over.
old=$plugins/framework-charge
if [[ -L $old && $(readlink -- "$old") == */v4/framework-charge ]]; then
    if [[ -f $old/settings.json && ! -e $plugin/settings.json ]]; then
        cp -- "$old/settings.json" "$plugin/settings.json"
    fi
    rm -- "$old"
fi

printf '%s\n' 'Restart Noctalia, enable Charge Limit in Settings > Plugins, and replace the Framework Charge bar widget with the Charge Limit one.'
