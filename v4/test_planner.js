// Run with: node --test v4/test_planner.js
process.env.TZ = "Europe/Berlin";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "framework-charge", "planner.js"), "utf8").replace(".pragma library", "");
const planner = vm.runInNewContext(source + "\n({ defaultRates, minutesNeeded, parseClock, upcoming, clock, parseHistory, plan })");

// Local Berlin time. 2026-10-26 is a Monday; Berlin leaves daylight saving time at 03:00 on 2026-10-25.
const t = text => new Date(text.replace(" ", "T")).getTime();
const rates = { below80: 1.0, from80: 1.6 };
const work = { days: [1, 2, 3, 4, 5], startMinute: 480, endMinute: 960, during: 50, after: 80 };
const scheduled = { work: work, tolerance: 3 };
const plain = { work: null, tolerance: 3 };
const target = (limit, deadline, started = false) => ({ limit, deadline, waitLimit: 50, started });

test("minutes, clocks, and local times", () => {
  assert.equal(planner.minutesNeeded(70, 90, rates), 26);
  assert.equal(planner.minutesNeeded(90, 80, rates), 0);
  assert.equal(planner.parseClock("08:00"), 480);
  assert.equal(planner.parseClock(" 7:05 "), 425);
  assert.equal(planner.parseClock("24:00"), null);
  assert.equal(planner.parseClock("8"), null);
  assert.equal(planner.clock(t("2026-10-27 10:00"), t("2026-10-26 10:00")), "Tue 10:00");
  assert.equal(planner.clock(t("2026-10-26 13:00"), t("2026-10-26 10:00")), "13:00");
  for (const [now, minute, expected, why] of [
    ["2026-10-26 10:00", 780, "2026-10-26 13:00", "later today"],
    ["2026-10-26 13:00", 600, "2026-10-27 10:00", "earlier, so tomorrow"],
    ["2026-10-26 10:00", 600, "2026-10-27 10:00", "this very minute, so tomorrow"],
    ["2026-03-28 23:30", 420, "2026-03-29 07:00", "the night before the spring change"],
    ["2026-10-25 00:30", 15, "2026-10-26 00:15", "the autumn change's long day"],
    ["2026-03-29 00:30", 150, "2026-03-29 03:30", "02:30 does not exist; the moment after the gap"],
    ["2026-10-25 01:00", 240, "2026-10-25 04:00", "04:00 after the autumn change"]
  ])
    assert.equal(planner.upcoming(t(now), minute), t(expected), why);
  // At the second 02:10 of the autumn change, the second 02:30 is still ahead. The string parser
  // reads a repeated time as its first pass, so the second is an hour later.
  const hour = 3600000;
  assert.equal(planner.upcoming(t("2026-10-25 02:10") + hour, 150), t("2026-10-25 02:30") + hour);
});

test("plan: limit and note", () => {
  const override60 = { override: { limit: 60, date: "2026-10-26" } };
  // now, charge, plugged, rules, intents -> limit, note
  const cases = [
    ["2026-10-26 07:00", 70, true, scheduled, {}, 80, "80% outside work hours"],
    ["2026-10-31 10:00", 70, true, scheduled, {}, 80, "80% outside work hours"],
    ["2026-10-26 10:00", 50, true, scheduled, {}, 50, "Holding 50% · 80% from 15:33"],
    ["2026-10-26 15:40", 50, true, scheduled, {}, 80, "Charging to 80% by 16:00"],
    // once the end-of-work charge has begun it stays on, though at 53 % the start would be 15:36
    ["2026-10-26 15:34", 53, true, scheduled, { workCharging: "2026-10-26 960" }, 80, "Charging to 80% by 16:00"],
    // a latch for another end time does not hold: the end time was edited
    ["2026-10-26 15:34", 53, true, scheduled, { workCharging: "2026-10-26 900" }, 50, "Holding 50% · 80% from 15:36"],
    ["2026-10-26 10:00", 50, true, scheduled, override60, 60, "Your 60% until midnight"],
    ["2026-10-27 10:00", 50, true, scheduled, override60, 50, "Holding 50% · 80% from 15:33"],
    ["2026-10-26 10:00", 50, true, plain, override60, null, null],
    ["2026-10-26 10:00", 50, true, { work: null, workProblem: "Working hours: check Settings", tolerance: 3 }, {}, null, "Working hours: check Settings"],
    ["2026-10-26 10:30", 50, true, plain, { target: target(80, t("2026-10-26 13:00")) }, 50, "80% by 13:00 · from 12:33"],
    ["2026-10-26 10:30", 50, true, { work: null, tolerance: 10 }, { target: target(80, t("2026-10-26 13:00")) }, 50, "80% by 13:00 · from 12:40"],
    ["2026-10-26 12:40", 50, true, plain, { target: target(80, t("2026-10-26 13:00")) }, 80, "Charging to 80% by 13:00"],
    ["2026-10-26 10:30", 55, true, plain, { target: target(80, t("2026-10-26 13:00"), true) }, 80, "Charging to 80% by 13:00"],
    ["2026-10-26 13:10", 78, true, plain, { target: target(80, t("2026-10-26 13:00"), true) }, 80, "Holding 80% until unplugged"],
    ["2026-10-26 13:10", 78, false, plain, { target: target(80, t("2026-10-26 13:00"), true) }, 50, null],
    ["2026-10-26 10:00", 50, true, scheduled, { target: target(100, t("2026-10-26 13:00")) }, 50, "100% by 13:00 · from 12:02"],
    // the schedule already holds more than the target, which waits for tomorrow's drop instead of ending
    ["2026-10-26 20:00", 80, true, scheduled, { target: target(80, t("2026-10-27 13:00")) }, 80, "80% outside work hours"],
    ["2026-10-27 10:00", 50, true, scheduled, { target: target(80, t("2026-10-27 13:00")) }, 50, "80% by 13:00 · from 12:33"]
  ];
  for (const [index, [now, charge, plugged, rules, intents, limit, note]] of cases.entries()) {
    const result = planner.plan(t(now), charge, plugged, rules, intents, rates);
    assert.deepEqual([result.limit, result.note], [limit, note], `case ${index + 1}`);
  }
});

test("plan: latches, restores, and expiry", () => {
  const latched = planner.plan(t("2026-10-26 12:40"), 50, true, plain, { target: target(80, t("2026-10-26 13:00")) }, rates);
  assert.equal(latched.intents.target.started, true);
  const ended = planner.plan(t("2026-10-26 13:10"), 78, false, plain, { target: target(80, t("2026-10-26 13:00"), true) }, rates);
  assert.equal(ended.intents.target, null);
  assert.equal(ended.intents.restore, 50);
  assert.equal(ended.limit, 50);
  // The restore keeps asking for the old limit until Main confirms it, unless a schedule decides.
  assert.equal(planner.plan(t("2026-10-26 13:10"), 78, false, plain, { restore: 50 }, rates).limit, 50);
  const scheduledRestore = planner.plan(t("2026-10-26 10:00"), 78, true, scheduled, { restore: 70 }, rates);
  assert.equal(scheduledRestore.limit, 50);
  assert.equal(scheduledRestore.intents.restore, null);
  // A manual choice keeps the latch, so going back on schedule keeps charging.
  const held = planner.plan(t("2026-10-26 15:34"), 53, true, scheduled, { override: { limit: 80, date: "2026-10-26" }, workCharging: "2026-10-26 960" }, rates);
  assert.equal(held.limit, 80);
  assert.equal(held.intents.workCharging, "2026-10-26 960");
  const resumed = planner.plan(t("2026-10-26 15:34"), 53, true, scheduled, { workCharging: held.intents.workCharging }, rates);
  assert.equal(resumed.limit, 80, "back on schedule after the latch: still charging");
  const expired = planner.plan(t("2026-10-27 10:00"), 50, true, scheduled, { override: { limit: 60, date: "2026-10-26" }, workCharging: "2026-10-26 960" }, rates);
  assert.equal(expired.intents.override, null);
  assert.equal(expired.intents.workCharging, null);
});

test("learned rates from upower's history", () => {
  // Two sessions: below 80 one at 1 and one at 0.5 minutes per percent, the median takes the
  // slower; from 80 only one with three steps at 2. An "unknown" row ends a session.
  const history = [
    "1000\t50.000\tcharging", "1060\t51.000\tcharging", "1120\t52.000\tcharging", "1180\t53.000\tcharging",
    "1200\t0.000\tunknown",
    "5000\t60.000\tcharging", "5030\t61.000\tcharging", "5060\t62.000\tcharging", "5090\t63.000\tcharging",
    "9000\t79.000\tcharging", "9120\t80.000\tcharging", "9240\t81.000\tcharging", "9360\t82.000\tcharging",
    "9480\t83.000\tcharging", "not a row"
  ].join("\n");
  assert.deepEqual({ ...planner.parseHistory(history) }, { below80: 1, from80: 2 });
  // A step from 78 to 82 % gains two percent in each band, so its minutes split evenly.
  const split = ["100\t75.000\tcharging", "160\t76.000\tcharging", "220\t77.000\tcharging", "280\t78.000\tcharging", "520\t82.000\tcharging", "580\t83.000\tcharging"].join("\n");
  assert.deepEqual({ ...planner.parseHistory(split) }, { below80: 1, from80: 1 });
  assert.deepEqual({ ...planner.parseHistory("") }, { below80: 1.0, from80: 1.6 });
});
