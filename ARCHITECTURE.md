One Python program, `chargelimit`, owns everything below the UI. The Noctalia
plugins in `noctalia/v4/` and `noctalia/v5/` are thin front-ends: they read its status
file and run its CLI.

## chargelimit

One file, stdlib only, in sections read top to bottom:

- **Data**: `State` is everything saved in `/var/lib/chargelimit/state.json`. That is
  `chosen` (the last manual limit), the `Settings`, and the intents: an `Override`
  for today, a "charge by" `Target`, and the end-of-work latch. `Backend` is
  `FrameworkEc | Thresholds`.
- **Settings as text**: the CLI, the state file, and the status file all spell
  settings as the same `key=value` strings. `with_setting` is the only parser.
- **Planner**: `plan()` is pure. The time, charge, charger, state, and charging
  speed go in; the limit, a note for the panel, and the updated state come out. A
  target beats a manual choice, which beats working hours, which beat `chosen`.
  `parse_history` learns the speed from upower's history.
- **Hardware**: on a Framework with `framework_tool` installed, the EC holds the
  limit and drains by itself. Everywhere else it writes the kernel's
  `charge_control_{start,end}_threshold`. With one battery that offers
  `force-discharge`, it drains by switching `charge_behaviour`.
- **Reconcile**: the one path that touches the hardware, under `/run/chargelimit/lock`.
  It loads the state, applies a CLI change, plans, saves the state, writes the
  limit and checks the readback, sets draining, and writes
  `/run/chargelimit/status.json`. Any error turns draining off.
- **CLI**: `chargelimit daemon` runs reconcile every minute, and at once on SIGUSR1.
  A writing command (`set`, `charge-by`, `resume`, `config`) re-runs itself through
  `pkexec`, reconciles with its change, prints the status, and sends the daemon
  SIGUSR1. `status` only reads the status file.

Only the daemon may turn draining on. The daemon turns it off at the limit, and its
unit's `ExecStopPost` turns it off when the daemon stops. So a CLI run can never
leave the battery draining with nothing to stop it.

`install.sh` installs the program, the Polkit action, and the unit. On a Framework
it downloads `framework_tool` and checks its digest. It also removes the helper of
`battery-limiter-noctalia`, the project this was forked from.

## Noctalia v5

`noctalia/v5/chargelimit/service.luau` is the only part that runs the CLI. The panel
sends it requests through `noctalia.state`, one at a time. The service answers by
publishing `controller` (the limit, its status, and the id of the request it handled)
and `plan` (the footer's line). Every minute it rereads the status file. The plugin's
settings are pushed with `chargelimit config` at start-up when they differ, and on
every change.

`panel.luau` draws the gauge. Noctalia has no stacking layout, so the gauge stacks
layers with near-zero-width rows. `clock.luau` parses the "charge by" time, and
`power.luau` reads the charge for the status line. `battery-action.toml` hooks
the built-in battery widget's left click.

## Noctalia v4

`noctalia/v4/chargelimit/Main.qml` lives as long as the shell, while v4 destroys
`Panel.qml` on close, so the CLI process lives there. It does what v5's service
does, without the request protocol: the panel calls `choose`, `chargeBy`,
`cancelTarget`, and `backOnSchedule`, and `status` being `applying` is the lock.
v4 cannot hook the built-in battery widget, so `BarWidget.qml` draws that widget
itself. This couples the plugin to Noctalia's internal `Battery` widget.

Start with `plan()` and `reconcile()` in `chargelimit`. Changing the
`framework_tool` version requires checking its output format.
