Framework Charge adds 50%, 60%, 70%, 80%, and 100% charge presets to the existing
battery icon in native Noctalia v5. Left-click opens the charge panel.
Right-click opens Noctalia's normal Power tab.

The panel draws the battery from 50% to 100%. Solid is the current charge,
the tint is the room up to the limit, and the white line is the limit.
Hover previews a preset under the gauge and a click sets it. Charge that a
lower limit would drain shows in red. A spinner runs while the controller
applies the limit; the line and the number change only after it confirms.
Arrow keys select the adjacent preset; Home and End select the endpoints.
Opening the panel never selects a new maximum. The firmware's query command
can reapply its saved policy.

Lowering the limit can drain the battery while plugged in. BIOS settings can
replace the limit at boot. There is no automatic restore or charge/discharge
loop. Closing Noctalia does not undo a setting already sent to the EC.

This version targets the Framework Laptop 13 Pro with Intel Core Ultra
Series 3 and Noctalia 5.3 or newer. It uses native Luau plugins, not v4 QML.
The Framework source is cloned at `~/projects-online/framework-system`, at
the v0.6.6 release. The matching binary is downloaded from the official
release and checked against its published SHA-256 digest.

Install from this directory:

```sh
./prepare-tool.sh
sudo ./install-system.sh
./install-user.sh
```

The system step installs a root-owned helper, vendor binary, and Polkit
action. Active local sessions may only read the limit or select one of the
five presets through this helper. The plugin receives no general EC access.

Open the panel directly:

```sh
noctalia msg panel-toggle paul/framework-charge:panel
```

Disable the plugin and restore the battery's default gestures:

```sh
noctalia msg plugins disable paul/framework-charge
rm ~/.config/noctalia/framework-charge.toml
noctalia msg config-reload
```

This does not change the current firmware charge limit. Removing the system
helper and policy is optional:

```sh
sudo rm /usr/local/libexec/framework-charge-limit /usr/local/libexec/framework-charge-tool \
    /usr/share/polkit-1/actions/dev.noctalia.framework-charge-limit.policy
```

Implementation details are in [ARCHITECTURE.md](ARCHITECTURE.md).

Check the helper and panel flows with the Luau CLI:

```sh
python3 -m unittest test_helper.py
python3 test_panel.py /path/to/luau
noctalia plugins lint framework-charge
```
