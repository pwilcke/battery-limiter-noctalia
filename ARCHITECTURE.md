`helper/` is the privileged backend that every Noctalia version shares. Each
version directory (`v4/`, `v5/`) holds only the panel for that Noctalia version
and its install script. Both panels call the helper the same way.

## Helper

Panels run `pkexec /usr/local/libexec/framework-charge-limit`.
The root-owned Python helper accepts only `read`, `set 50|60|70|80|100`, and
`restore`.
It picks a backend from the DMI vendor. On the Framework Laptop 13 Pro it
invokes Framework's `framework_tool` (pinned to v0.6.6) through `/dev/cros_ec`.
On a ThinkPad it writes `charge_control_start_threshold` and
`charge_control_end_threshold` of every battery, in the order thinkpad_acpi
accepts. Either way it returns the verified maximum as JSON, with `drains`
saying whether charge above the limit gets drained, even on AC. Only the
Framework EC does that, and the panels only draw it red then. The Polkit action
permits this narrow operation for the active local session. The controller
device stays root-only.

Every confirmed `set` also saves the limit to
`/var/lib/framework-charge-limit/limit`, replaced atomically under the same
lock. The Framework BIOS resets the EC's limit at every boot, so
`framework-charge-limit.service` runs `restore` once at boot, which applies the
saved limit through the same `set` path. The controller device appears while
kernel modules load, so the oneshot gets ten attempts. Without a saved limit,
`restore` saves the current one if it is a preset; the installer starts the
service once for that.

On a Framework, `helper/install.sh` downloads framework_tool as the user and
checks its digest. It then uses sudo to copy the tool, the helper, the policy,
and the boot service into root-owned paths, and enables and starts the service.

## v5 plugin

Four files in `v5/framework-charge/`:

- `service.luau` is the only part that runs the helper. The panel sends it requests
  through `noctalia.state` (`read`, `set`, `target`, `cancel`, `schedule`), one at a
  time, and it answers by publishing `controller` (the limit, its status, and the id
  of the request it handled) and `plan` (the footer's line). Every minute it asks the
  planner which limit should apply and writes it when that differs from the last
  confirmed one; a confirmation older than 15 minutes or from before a sleep is read
  again first. With working hours off and no target it never runs the helper on its
  own. Its intents (a manual choice, a target, and the end-of-work latch) live in
  `intents.json` in the plugin's data folder, written to a new file and renamed.
- `planner.luau` is pure: the time, the charge, whether it is plugged in, the
  settings, and the intents in; the limit and a note out. A "charge by" target beats a
  manual choice, which beats working hours. Starts are the deadline minus the minutes
  needed to come within the tolerance, from two speed bands (below 80 % and from
  80 %); once charging has begun, a latch keeps it going. When a target ends without
  a schedule, a saved restore keeps asking for the old limit until it is confirmed. The speeds come from
  upower's own history of the last five charges, else fixed defaults. Luau's
  `os.time(table)` reads the table as UTC, so local times are built from `now`.
- `power.luau` reads the battery level, status, and charger from sysfs, and finds
  upower's history file by the battery's model and serial number.
- `panel.luau` draws the panel. Noctalia has no stacking layout, so the gauge stacks
  layers with near-zero-width rows: the outline, the bar (one row of colour spans
  painted from the charge, the limit, and the hovered preset), the open end, and five
  invisible hit zones on top. The presets sit at even steps; 80 to 100 is one step
  too, so above 80 a point is half as wide. Hover previews a preset and the limit line
  glides there; a click sends a `set`. The spinner holds an answer until it has turned
  for 0.7 s. The footer shows the plan, or the "charge by" editor. The gear beside the title
  opens the plugin's settings. If the service does not answer within 5 seconds, the
  panel says so.

The existing battery widget opens the panel through `v5/battery-action.toml`.

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
