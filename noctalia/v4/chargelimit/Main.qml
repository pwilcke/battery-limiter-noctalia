import QtQuick
import Quickshell.Io
import qs.Services.UI

// A front-end for the chargelimit daemon, which owns the limit and the charge plan. Reads come
// from its status file; changes run its CLI, which answers with the new status. The panel is
// destroyed when it closes, and a running change must not die with it, so the Process lives here.
Item {
  id: root

  required property var pluginApi

  readonly property string program: "/usr/local/bin/chargelimit"
  readonly property var presets: [50, 60, 70, 80, 90, 100]
  readonly property int minimumSpinMs: 700
  readonly property int staleSeconds: 3 * 60 // the daemon rewrites its status every minute
  readonly property var emptyPlan: ({ note: null, scheduling: false, overridden: false, target: null })
  readonly property var cliWorkDays: ({
      "weekdays": "weekdays",
      "monSat": "mon-sat",
      "everyDay": "every-day"
    })

  // One of:
  //   { kind: "idle" }
  //   { kind: "ready", limit, drains }
  //   { kind: "applying", limit, drains, target }   target: the limit a `set` asks for, else null
  //   { kind: "failed", message }
  // drains says whether the laptop drains charge above the limit, even on AC. applying is the
  // lock: one CLI run at a time. Reads are synchronous and need none.
  property var status: ({ kind: "idle" })
  readonly property bool busy: status.kind === "applying"
  signal confirmed

  property var charge: null
  property var plugged: null
  // "charging", "draining", "holding", or "on battery"; null while unknown.
  property var activity: null
  // For the panel's footer. target: { limit, deadline } with the deadline in milliseconds.
  property var plan: emptyPlan

  property bool settingsDirty: false
  property bool settingsChecked: false // compared with the daemon's once, at the first usable status
  property string lastNotified: ""

  function sense() {
    capacity.reload();
    charger.reload();
    batteryStatus.reload();
    const percent = parseInt(capacity.text());
    charge = percent >= 0 && percent <= 100 ? percent : null;
    const online = charger.text().trim();
    plugged = online === "" ? null : online !== "0";
    const state = batteryStatus.text().trim();
    if (plugged === null || state === "")
      activity = null;
    else if (!plugged)
      activity = "on battery";
    else if (state === "Charging")
      activity = "charging";
    else if (state === "Discharging")
      activity = "draining";
    else if (state === "Not charging" || state === "Full")
      activity = "holding";
    else
      activity = null;
  }

  function fail(message) {
    status = { kind: "failed", message: message };
    plan = emptyPlan;
    if (message !== lastNotified)
      ToastService.showError("Charge limit", message);
    lastNotified = message;
  }

  // Takes a status JSON from the file or the CLI. Returns "" once taken, else what is wrong.
  function take(text) {
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch (error) {}
    if (parsed === null || typeof parsed.at !== "number" || Date.now() / 1000 - parsed.at > staleSeconds)
      return "The chargelimit service is not running.";
    if (typeof parsed.error === "string")
      return parsed.error;
    if (!Number.isInteger(parsed.limit) || typeof parsed.drains !== "boolean" || typeof parsed.plan !== "object" || parsed.plan === null)
      return "The chargelimit status is invalid.";
    const target = parsed.plan.target;
    plan = {
      note: parsed.plan.note,
      scheduling: parsed.plan.scheduling,
      overridden: parsed.plan.overridden,
      target: target ? { limit: target.limit, deadline: target.deadline * 1000 } : null
    };
    status = { kind: "ready", limit: parsed.limit, drains: parsed.drains };
    lastNotified = "";
    if (!settingsChecked && typeof parsed.settings === "object" && parsed.settings !== null) {
      settingsChecked = true;
      const wanted = cliSettings();
      settingsDirty = settingsDirty || Object.keys(wanted).some(key => wanted[key] !== parsed.settings[key]);
    }
    return "";
  }

  function read() {
    if (busy)
      throw new Error("A read must wait for the running chargelimit run.");
    statusFile.reload();
    const message = take(statusFile.text());
    if (message !== "")
      fail(message);
    else
      sendSettings();
  }

  function run(args, target) {
    if (busy)
      throw new Error("A chargelimit run must wait for the one already running.");
    const ready = status.kind === "ready";
    status = { kind: "applying", limit: ready ? status.limit : null, drains: ready && status.drains, target: target };
    cli.startedAtMs = Date.now();
    cli.command = [program].concat(args);
    cli.running = true;
  }

  function complete(exitCode, stdout, stderr) {
    const target = status.target;
    let message = exitCode === 0 ? take(stdout) : stderr.trim() || "chargelimit failed with exit code " + exitCode + ".";
    if (message === "" && target !== null && status.limit !== target)
      message = "chargelimit set " + status.limit + "% instead of " + target + "%.";
    if (message === "") {
      confirmed();
    } else {
      fail(message);
      // The status file still tells the limit.
      read();
    }
    sendSettings();
  }

  // With a schedule or a target running, choosing the current limit still counts.
  function choose(limit) {
    if (status.kind !== "ready" || (limit === status.limit && !plan.scheduling && plan.target === null))
      return;
    if (!presets.includes(limit))
      throw new Error("A charge limit must be one of the presets, got " + limit + ".");
    run(["set", String(limit)], limit);
  }

  function chargeBy(limit, deadline) {
    if (status.kind !== "ready" || !presets.includes(limit) || deadline <= Date.now())
      throw new Error("A charge-by target needs a known limit, a preset, and a future deadline, got " + limit + " by " + deadline + ".");
    run(["charge-by", String(limit), "@" + Math.floor(deadline / 1000)], null);
  }

  function cancelTarget() {
    if (status.kind === "ready")
      run(["charge-by", "off"], null);
  }

  function backOnSchedule() {
    if (status.kind === "ready")
      run(["resume"], null);
  }

  // The plugin's settings own the schedule, as the CLI's config keys.
  function cliSettings() {
    const settings = pluginApi.pluginSettings;
    return {
      "work-hours": settings.workHours ? "on" : "off",
      "work-days": cliWorkDays[settings.workDays] ?? String(settings.workDays),
      "work-start": String(settings.workStart),
      "work-end": String(settings.workEnd),
      "work-limit": String(settings.workLimit),
      "after-work-limit": String(settings.afterWorkLimit),
      "tolerance": String(settings.tolerance),
      "learn-rates": settings.learnRates ? "on" : "off"
    };
  }

  // A change that arrives during a run waits for complete().
  function sendSettings() {
    if (!settingsDirty || busy)
      return;
    settingsDirty = false;
    const wanted = cliSettings();
    run(["config"].concat(Object.keys(wanted).map(key => key + "=" + wanted[key])), null);
  }

  Component.onCompleted: {
    sense();
    read();
  }

  Connections {
    target: root.pluginApi
    function onPluginSettingsChanged() {
      root.settingsDirty = true;
      root.sendSettings();
    }
  }

  // The daemon replaces the file by rename, which a file watch may miss, so the timer reads it
  // too. It also turns a status that stopped updating into a failure.
  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: {
      if (!root.busy)
        root.read();
    }
  }

  // The bar shows where the charge is heading, so the battery is read while the panel is closed too.
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: root.sense()
  }

  FileView {
    id: statusFile
    path: "/run/chargelimit/status.json"
    blockAllReads: true
    printErrors: false
    watchChanges: true
    onFileChanged: {
      if (!root.busy)
        root.read();
    }
  }

  FileView {
    id: capacity
    // Most laptops call their battery BAT0; some have only BAT1.
    path: "/sys/class/power_supply/BAT0/capacity"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/BAT1/capacity"
  }

  FileView {
    id: batteryStatus
    path: "/sys/class/power_supply/BAT0/status"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/BAT1/status"
  }

  FileView {
    id: charger
    // The charger is called AC on most laptops and ACAD on some.
    path: "/sys/class/power_supply/AC/online"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/ACAD/online"
  }

  Process {
    id: cli

    property double startedAtMs: 0

    stdout: StdioCollector {}
    stderr: StdioCollector {}

    onExited: exitCode => {
      const result = [exitCode, stdout.text, stderr.text];
      // A run returns in about 0.1 s; holding the result lets the spinner turn instead of
      // flashing.
      const remainingMs = root.minimumSpinMs - (Date.now() - startedAtMs);
      if (remainingMs <= 0) {
        root.complete(...result);
        return;
      }
      hold.result = result;
      hold.interval = remainingMs;
      hold.start();
    }
  }

  Timer {
    id: hold

    property var result: null

    onTriggered: root.complete(...result)
  }
}
