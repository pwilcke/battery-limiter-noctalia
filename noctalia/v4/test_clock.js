// Run with: node --test noctalia/v4/test_clock.js
process.env.TZ = "Europe/Berlin";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "chargelimit", "clock.js"), "utf8").replace(".pragma library", "");
const clock = vm.runInNewContext(source + "\n({ day, parseClock, upcoming, clock })");

// Local Berlin time. 2026-10-26 is a Monday; Berlin leaves daylight saving time at 03:00 on 2026-10-25.
const t = text => new Date(text.replace(" ", "T")).getTime();

test("clocks and local times", () => {
  assert.equal(clock.parseClock("08:00"), 480);
  assert.equal(clock.parseClock(" 7:05 "), 425);
  assert.equal(clock.parseClock("24:00"), null);
  assert.equal(clock.parseClock("8"), null);
  assert.equal(clock.day(t("2026-10-26 00:30")), "2026-10-26");
  assert.equal(clock.clock(t("2026-10-27 10:00"), t("2026-10-26 10:00")), "Tue 10:00");
  assert.equal(clock.clock(t("2026-10-26 13:00"), t("2026-10-26 10:00")), "13:00");
  for (const [now, minute, expected, why] of [
    ["2026-10-26 10:00", 780, "2026-10-26 13:00", "later today"],
    ["2026-10-26 13:00", 600, "2026-10-27 10:00", "earlier, so tomorrow"],
    ["2026-10-26 10:00", 600, "2026-10-27 10:00", "this very minute, so tomorrow"],
    ["2026-03-28 23:30", 420, "2026-03-29 07:00", "the night before the spring change"],
    ["2026-10-25 00:30", 15, "2026-10-26 00:15", "the autumn change's long day"],
    ["2026-03-29 00:30", 150, "2026-03-29 03:30", "02:30 does not exist; the moment after the gap"],
    ["2026-10-25 01:00", 240, "2026-10-25 04:00", "04:00 after the autumn change"]
  ])
    assert.equal(clock.upcoming(t(now), minute), t(expected), why);
  // At the second 02:10 of the autumn change, the second 02:30 is still ahead. The string parser
  // reads a repeated time as its first pass, so the second is an hour later.
  const hour = 3600000;
  assert.equal(clock.upcoming(t("2026-10-25 02:10") + hour, 150), t("2026-10-25 02:30") + hour);
});
