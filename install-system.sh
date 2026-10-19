#!/usr/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $EUID != 0 ]]; then
    printf '%s\n' 'System installation requires root.' >&2
    exit 1
fi
printf '%s  %s\n' ebc2f3ca300dac6f484c02d058833372ff8dd3c23f2a74b63c774f8dc2f86171 .vendor/framework_tool | sha256sum --check
python3 - <<'PY'
import ast
from pathlib import Path
import xml.etree.ElementTree as xml
ast.parse(Path("framework-charge-limit").read_text())
xml.parse("dev.noctalia.framework-charge-limit.policy")
PY
install -d -o root -g root -m 755 /usr/local/libexec
install -o root -g root -m 755 .vendor/framework_tool /usr/local/libexec/framework-charge-tool
install -o root -g root -m 755 framework-charge-limit /usr/local/libexec/framework-charge-limit
install -o root -g root -m 644 dev.noctalia.framework-charge-limit.policy /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
command -v restorecon >/dev/null && restorecon /usr/local/libexec/framework-charge-tool /usr/local/libexec/framework-charge-limit /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
printf '%s\n' 'Installed the charge-limit helper and policy.'
