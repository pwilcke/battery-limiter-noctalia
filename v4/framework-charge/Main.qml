import QtQuick
import Quickshell.Io
import qs.Services.UI

// Owns the helper requests. The panel is destroyed when it closes, and a write
// must not die with it, so the Process lives here.
Item {
  id: root

  required property var pluginApi

  readonly property string helper: "/usr/local/libexec/framework-charge-limit"
  readonly property var presets: [50, 60, 70, 80, 100]
  readonly property int minimumSpinMs: 700

  // One of:
  //   { kind: "idle" }
  //   { kind: "reading" }
  //   { kind: "ready", limit, drains }
  //   { kind: "applying", limit, drains, target }
  // drains says whether the laptop drains charge above the limit, even on AC.
  //   { kind: "failed", message }
  property var status: ({ kind: "idle" })
  signal confirmed

  function read() {
    if (status.kind === "reading" || status.kind === "applying")
      return;
    status = { kind: "reading" };
    request.target = 0;
    request.command = ["pkexec", helper, "read"];
    request.running = true;
  }

  function choose(limit) {
    if (status.kind !== "ready" || limit === status.limit)
      return;
    if (!presets.includes(limit))
      throw new Error("A charge limit must be one of the presets, got " + limit + ".");
    status = { kind: "applying", limit: status.limit, drains: status.drains, target: limit };
    request.target = limit;
    request.startedAtMs = Date.now();
    request.command = ["pkexec", helper, "set", String(limit)];
    request.running = true;
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
      status = { kind: "failed", message: message };
      ToastService.showError("Charge limit", message);
      // A failed write leaves the limit unknown.
      if (target !== 0)
        read();
      return;
    }
    status = { kind: "ready", limit: limit, drains: drains };
    if (target !== 0)
      confirmed();
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
