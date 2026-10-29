import QtQuick
import Quickshell.Io
import qs.Services.UI
import "planner.js" as Planner

// Owns the controller and the charge plan, like v5's service.luau. The panel is destroyed when it
// closes, and neither a write nor the plan may die with it, so the Process and the minute tick
// live here. Every minute it asks the planner which limit should apply and writes it when that
// differs from the last confirmed one. With working hours off and no target, it never runs the
// helper on its own.
Item {
  id: root

  required property var pluginApi

  readonly property string helper: "/usr/local/libexec/framework-charge-limit"
  readonly property var presets: [50, 60, 70, 80, 100]
  readonly property int minimumSpinMs: 700
  readonly property int verifyMs: 15 * 60000 // how often an active plan rereads the controller
  readonly property int gapMs: 3 * 60000 // a longer pause between ticks means sleep or a stopped shell
  readonly property int retryMs: 5 * 60000 // a limit that failed to apply waits this long before another try
  readonly property var daySets: ({
      "weekdays": [1, 2, 3, 4, 5],
      "monSat": [1, 2, 3, 4, 5, 6],
      "everyDay": [0, 1, 2, 3, 4, 5, 6]
    })

  // One of:
  //   { kind: "idle" }
  //   { kind: "reading" }
  //   { kind: "ready", limit, drains }
  //   { kind: "applying", limit, drains, target }
  // drains says whether the laptop drains charge above the limit, even on AC.
  //   { kind: "failed", message }
  // reading and applying also mean busy: one helper request runs at a time.
  property var status: ({ kind: "idle" })
  signal confirmed

  property var charge: null
  property var plugged: null
  // See planner.js. Always in the shape planner.plan returns, with the same key order, so two
  // intents compare as JSON.
  property var intents: ({ override: null, target: null, workCharging: null, restore: null })
  // For the panel's footer.
  property var plan: ({ note: null, scheduling: false, overridden: false, target: null })

  property double verifiedAtMs: 0
  property double lastTickMs: Date.now()
  property var rates: Planner.defaultRates
  property double ratesAtMs: -Infinity
  property var failedLimit: null
  property double failedAtMs: 0
  property string lastNotified: ""

  function sense() {
    capacity.reload();
    charger.reload();
    const percent = parseInt(capacity.text());
    charge = percent >= 0 && percent <= 100 ? percent : null;
    const online = charger.text().trim();
    plugged = online === "" ? null : online !== "0";
  }

  function read() {
    if (status.kind === "reading" || status.kind === "applying")
      throw new Error("A read must wait for the running " + status.kind + " request.");
    status = { kind: "reading" };
    request.target = 0;
    request.command = ["pkexec", helper, "read"];
    request.running = true;
  }

  function write(limit) {
    if (status.kind !== "ready")
      throw new Error("A write needs a known limit, but the controller is " + status.kind + ".");
    if (!presets.includes(limit))
      throw new Error("A charge limit must be one of the presets, got " + limit + ".");
    status = { kind: "applying", limit: status.limit, drains: status.drains, target: limit };
    request.target = limit;
    request.startedAtMs = Date.now();
    request.command = ["pkexec", helper, "set", String(limit)];
    request.running = true;
  }

  function fail(message) {
    status = { kind: "failed", message: message };
    if (message !== lastNotified)
      ToastService.showError("Charge limit", message);
    lastNotified = message;
  }

  function complete(exitCode, stdout, stderr, target) {
    let message = "";
    let limit = 0;
    let drains = null;
    if (exitCode !== 0) {
      message = stderr.trim() || "The charge-limit request failed with exit code " + exitCode + ".";
    } else {
      try {
        ({ limit, drains } = JSON.parse(stdout));
      } catch (error) {}
      if (!Number.isInteger(limit) || limit < 25 || limit > 100 || typeof drains !== "boolean")
        message = "The charge-limit helper returned an invalid response.";
      else if (target !== 0 && limit !== target)
        message = "The controller returned a different charge limit.";
    }
    if (message !== "") {
      fail(message);
      // A failed write leaves the limit unknown.
      if (target !== 0) {
        failedLimit = target;
        failedAtMs = Date.now();
        read();
      }
      return;
    }
    lastNotified = "";
    verifiedAtMs = Date.now();
    status = { kind: "ready", limit: limit, drains: drains };
    if (target !== 0)
      confirmed();
    reconcile();
  }

  function saveIntents(next) {
    intents = next;
    intentsFile.setText(JSON.stringify(next));
  }

  // A manual choice ends any target, and with working hours on it holds until midnight. With a
  // schedule or a target running, choosing the current limit still counts.
  function choose(limit) {
    if (status.kind !== "ready" || (limit === status.limit && !plan.scheduling && plan.target === null))
      return;
    const override = readRules().work ? { limit: limit, date: Planner.day(Date.now()) } : null;
    saveIntents({ override: override, target: null, workCharging: intents.workCharging, restore: null });
    write(limit);
  }

  function chargeBy(limit, deadline) {
    if (status.kind !== "ready" || !presets.includes(limit) || deadline <= Date.now())
      throw new Error("A charge-by target needs a known limit, a preset, and a future deadline, got " + limit + " by " + deadline + ".");
    saveIntents(Object.assign({}, intents, { target: { limit: limit, deadline: deadline, waitLimit: status.limit, started: false } }));
    reconcile();
  }

  function cancelTarget() {
    const ended = intents.target;
    // Without a schedule, the limit returns to where the target started.
    const restore = ended && !readRules().work ? ended.waitLimit : intents.restore;
    saveIntents(Object.assign({}, intents, { target: null, restore: restore }));
    reconcile();
  }

  function backOnSchedule() {
    saveIntents(Object.assign({}, intents, { override: null }));
    reconcile();
  }

  function readRules() {
    const settings = pluginApi.pluginSettings;
    const tolerance = settings.tolerance;
    if (settings.workHours !== true)
      return { work: null, workProblem: null, tolerance: tolerance };
    const startMinute = Planner.parseClock(settings.workStart ?? "");
    const endMinute = Planner.parseClock(settings.workEnd ?? "");
    const days = daySets[settings.workDays];
    const during = settings.workLimit;
    const after = settings.afterWorkLimit;
    if (startMinute === null || endMinute === null || !days || !presets.includes(during) || !presets.includes(after) || startMinute >= endMinute || after < during)
      return { work: null, workProblem: "Working hours: check Settings", tolerance: tolerance };
    return { work: { days: days, startMinute: startMinute, endMinute: endMinute, during: during, after: after }, workProblem: null, tolerance: tolerance };
  }

  function reconcile() {
    const now = Date.now();
    sense();
    const rules = readRules();
    if (pluginApi.pluginSettings.learnRates !== true) {
      rates = Planner.defaultRates;
    } else if (now - ratesAtMs >= 10 * 60000 && !history.running) {
      // The history answers in a moment and plans again.
      ratesAtMs = now;
      history.running = true;
      return;
    }
    if (charge === null || plugged === null) {
      plan = { note: "The battery cannot be read.", scheduling: rules.work !== null, overridden: false, target: null };
      return;
    }
    const result = Planner.plan(now, charge, plugged, rules, intents, rates);
    if (JSON.stringify(result.intents) !== JSON.stringify(intents))
      saveIntents(result.intents);
    plan = { note: result.note, scheduling: rules.work !== null, overridden: intents.override !== null, target: intents.target };

    // The last confirmed limit goes stale after a while or a sleep, since the BIOS or another tool
    // may have changed it; a stale one is read first, and the read plans again.
    if (now - lastTickMs > gapMs)
      verifiedAtMs = 0;
    lastTickMs = now;
    const fresh = status.kind === "ready" && now - verifiedAtMs < verifyMs;
    if (intents.restore !== null && fresh && status.limit === intents.restore) {
      saveIntents(Object.assign({}, intents, { restore: null }));
      return;
    }
    const wanted = result.limit;
    if (wanted === null || status.kind === "reading" || status.kind === "applying")
      return;
    if (!fresh)
      read();
    else if (wanted !== status.limit && !(wanted === failedLimit && now - failedAtMs < retryMs))
      write(wanted);
  }

  function loadIntents() {
    let saved = null;
    try {
      saved = JSON.parse(intentsFile.text());
    } catch (error) {}
    if (typeof saved !== "object" || saved === null)
      return;
    const override = saved.override;
    const target = saved.target;
    intents = {
      override: override && Number.isInteger(override.limit) && typeof override.date === "string" ? { limit: override.limit, date: override.date } : null,
      target: target && Number.isInteger(target.limit) && typeof target.deadline === "number" && Number.isInteger(target.waitLimit) ? { limit: target.limit, deadline: target.deadline, waitLimit: target.waitLimit, started: target.started === true } : null,
      workCharging: typeof saved.workCharging === "string" ? saved.workCharging : null,
      restore: presets.includes(saved.restore) ? saved.restore : null
    };
  }

  Component.onCompleted: {
    loadIntents();
    reconcile();
  }

  Connections {
    target: root.pluginApi
    function onPluginSettingsChanged() {
      root.reconcile();
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.reconcile()
  }

  FileView {
    id: intentsFile
    path: root.pluginApi.pluginDir + "/intents.json"
    blockLoading: true
    printErrors: false
    // Not through fail(): a helper request may be running, and status is its lock.
    onSaveFailed: ToastService.showError("Charge limit", "The charge plan could not be saved.")
  }

  FileView {
    id: capacity
    // A Framework has only BAT1; a ThinkPad has BAT0.
    path: "/sys/class/power_supply/BAT0/capacity"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/BAT1/capacity"
  }

  FileView {
    id: charger
    // A Framework calls its charger ACAD; a ThinkPad calls it AC.
    path: "/sys/class/power_supply/AC/online"
    blockAllReads: true
    printErrors: false
    onLoadFailed: path = "/sys/class/power_supply/ACAD/online"
  }

  // upower names its history after the battery's model and serial number. `read` trims the
  // serial's padding, and the first matching file wins.
  Process {
    id: history
    command: ["sh", "-c", "b=/sys/class/power_supply/BAT0; [ -e $b ] || b=/sys/class/power_supply/BAT1; read -r model < $b/model_name; read -r serial < $b/serial_number; set -- /var/lib/upower/history-charge-\"$model\"-*-\"$serial\".dat; cat \"$1\""]
    stdout: StdioCollector {}
    onExited: exitCode => {
      root.rates = exitCode === 0 ? Planner.parseHistory(stdout.text) : Planner.defaultRates;
      root.reconcile();
    }
  }

  Process {
    id: request

    // 0 for a read, the requested limit for a write.
    property int target: 0
    property double startedAtMs: 0

    stdout: StdioCollector {}
    stderr: StdioCollector {}

    onExited: exitCode => {
      const result = [exitCode, stdout.text, stderr.text, target];
      // Writes return in about 0.1 s; holding the result lets the spinner turn
      // instead of flashing.
      const remainingMs = target === 0 ? 0 : root.minimumSpinMs - (Date.now() - startedAtMs);
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
