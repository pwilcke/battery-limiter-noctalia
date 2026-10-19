The native Noctalia v5 panel lives in `framework-charge/panel.luau`.
It reads the EC when opened. Dragging previews a preset; release or an anchor
click applies it. Slider positions 0–4 map to the five percentage presets.
Frame ticks animate feedback without writing to the EC.
Failed writes trigger a controller read before controls become available again.
The existing battery widget opens it through `battery-action.toml`.

The panel runs `pkexec /usr/local/libexec/framework-charge-limit`.
The root-owned Python helper accepts only `read` and `set 50|60|70|80|100`.
It invokes the pinned official Framework tool through `/dev/cros_ec` and
returns the verified maximum as JSON. The Polkit action permits this narrow
operation for the active local session. The controller device stays root-only.

`prepare-tool.sh` downloads and checks the official v0.6.6 binary.
`install-system.sh` copies that binary, the helper, and its policy into
root-owned paths. `install-user.sh` registers the local plugin and battery
actions. There is no background service or automatic target restoration.

Start with the panel, then read `framework-charge-limit` for the privileged
boundary. Changing the CLI version requires checking its output format.
