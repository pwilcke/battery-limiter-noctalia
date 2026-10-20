`helper/` is the privileged backend that every Noctalia version shares. Each
version directory (`v4/`, `v5/`) holds only the panel for that Noctalia version
and its install script. Both panels draw the same gauge and call the helper the
same way.

## Helper

Panels run `pkexec /usr/local/libexec/framework-charge-limit`.
The root-owned Python helper accepts only `read` and `set 50|60|70|80|100`.
It invokes Framework's `framework_tool` (pinned to v0.6.6) through
`/dev/cros_ec` and returns the verified maximum as JSON. The Polkit action
permits this narrow operation for the active local session. The controller
device stays root-only.

`helper/install.sh` downloads framework_tool as the user and checks its digest.
It then uses sudo to copy the tool, the helper, and the policy into root-owned
paths. There is no background service or automatic target restoration.

## v5 panel

The native Noctalia v5 panel lives in `v5/framework-charge/panel.luau`.
It reads the EC when opened, and the battery level from sysfs every second
while open. Noctalia has no stacking layout, so the gauge stacks layers with
near-zero-width rows: the outline, the bar (one row of colour spans painted from
the charge, the limit, and the hovered preset), the open end, and five
invisible hit zones on top. Hover previews a preset and the limit line glides
there; a click applies it. Handlers are closures on keyed nodes, so they keep
their identity across renders.
Frame ticks animate the spinner and the confirmation check without writing to
the EC. A write result is held until the spinner has turned for 0.7 s, so a
fast write does not flash; closing the panel releases it at once.
Failed writes trigger a controller read before controls become available again.
The existing battery widget opens it through `v5/battery-action.toml`.

`v5/install.sh` lints the plugin, runs `helper/install.sh`, and registers the
plugin and battery actions.

## v4 panel

The Noctalia v4 plugin in `v4/framework-charge/` is QML.
`Main.qml` owns the helper requests and the state. It lives as long as the
shell, while v4 destroys `Panel.qml` on close, so a write never dies with the
panel. `Main.qml` also holds a write result until the spinner has turned for
0.7 s. `Panel.qml` draws the gauge with plain stacked rectangles; the limit
line glides through a `Behavior` on its x. One mouse area covers the gauge and
the labels and maps the pointer to a preset. v4 cannot hook the built-in
battery widget, so `BarWidget.qml` draws that Battery widget itself and
takes its left click to toggle the panel. It passes the plugin's settings to
the Battery widget as its options. This couples the plugin to Noctalia's
internal `Battery` widget, so a Noctalia update may break it.

`v4/install.sh` runs `helper/install.sh` and links the plugin into Noctalia's
plugin folder. The user enables it in Settings, which adds the bar icon.

Start with the panel, then read `helper/framework-charge-limit` for the
privileged boundary. Changing the framework_tool version requires checking its
output format.
