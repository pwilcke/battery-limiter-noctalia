.pragma library
// Decides which charge limit should apply at a given moment: a port of v5's planner.luau. It uses
// no Qt, so node can test it alone; Main.qml feeds it and carries out the result. Times are
// milliseconds since the epoch.
//
// rules:   { work: Work | null, workProblem: string | null, tolerance }
//   Work:  { days: [Date.getDay() numbers, 0 is Sunday], startMinute, endMinute, during, after }
//          minutes count from local midnight; `after` is reached by the end of work and kept outside it.
// intents: { override: { limit, date } | null,   a manual choice, for that local date
//            target: { limit, deadline, waitLimit, started } | null,
//            workCharging: "<local date> <end minute>" | null,   set once that day's end-of-work
//                          charge has begun; the end minute makes an edited end time start over
//            restore: limit | null }   after a target ends without a schedule: the limit it
//                                      started from, kept until Main has confirmed it
// rates:   { below80, from80 } in minutes per percent

const defaultRates = { below80: 1.0, from80: 1.6 };
const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function minutesNeeded(from, to, rates) {
  const below = Math.max(0, Math.min(to, 80) - from);
  const above = Math.max(0, to - Math.max(from, 80));
  return below * rates.below80 + above * rates.from80;
}

function pad(number) {
  return String(number).padStart(2, "0");
}

function day(time) {
  const date = new Date(time);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

// The Date constructor reads its fields as local time. A time the spring change skips becomes the
// moment after the gap; a time the autumn change repeats is its first pass (v5: the pass with the
// UTC offset `now` has). Only upcoming() corrects for that.
function at(now, minuteOfDay, days = 0) {
  const date = new Date(now);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, Math.floor(minuteOfDay / 60), minuteOfDay % 60).getTime();
}

// The next moment the clock shows minuteOfDay: today if that is still ahead, else tomorrow. The
// Date constructor picks the first pass of a time the autumn change repeats, so when that has
// passed, the second pass an hour later may still be ahead.
function upcoming(now, minuteOfDay) {
  const today = at(now, minuteOfDay);
  const repeat = new Date(today + 3600000);
  if (today > now)
    return today;
  if (repeat.getTime() > now && repeat.getHours() * 60 + repeat.getMinutes() === minuteOfDay)
    return repeat.getTime();
  return at(now, minuteOfDay, 1);
}

function parseClock(text) {
  const match = /^\s*(\d\d?):(\d\d)\s*$/.exec(text);
  if (!match || Number(match[1]) >= 24 || Number(match[2]) >= 60)
    return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

// Another day shows its short weekday, like "Tue 07:00": "tomorrow" crowds the panel's footer.
function clock(time, now) {
  const date = new Date(time);
  const hhmm = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  return day(time) === day(now) ? hhmm : `${weekdays[date.getDay()]} ${hhmm}`;
}

// upower writes one "unix<TAB>percent<TAB>state" row per percent change. A charging session is a
// run of "charging" rows with rising percent and gaps under 10 minutes. Each step's minutes are
// split between the bands by the percent it gained in each. A band's rate is the median over the
// last five sessions with at least three percent in it, the slower middle value for an even count.
function parseHistory(text) {
  const sessions = [];
  let current = null;
  let lastTime = 0, lastPercent = 0;
  for (const line of text.split("\n")) {
    const match = /^(\d+)\t([\d.]+)\t(\S+)/.exec(line);
    const time = match ? Number(match[1]) : NaN;
    const percent = match ? Number(match[2]) : NaN;
    const charging = match !== null && !isNaN(time) && !isNaN(percent) && match[3] === "charging";
    if (charging && current && time > lastTime && time - lastTime < 600 && percent > lastPercent) {
      const minutesPerPercent = (time - lastTime) / 60 / (percent - lastPercent);
      const below = Math.max(0, Math.min(percent, 80) - lastPercent);
      const above = Math.max(0, percent - Math.max(lastPercent, 80));
      current.minutes.below80 += below * minutesPerPercent;
      current.minutes.from80 += above * minutesPerPercent;
      current.percent.below80 += below;
      current.percent.from80 += above;
      lastTime = time;
      lastPercent = percent;
    } else if (charging) {
      current = { minutes: { below80: 0, from80: 0 }, percent: { below80: 0, from80: 0 } };
      sessions.push(current);
      lastTime = time;
      lastPercent = percent;
    } else if (line !== "") {
      current = null;
    }
  }
  function median(band) {
    const rates = [];
    for (let index = sessions.length - 1; index >= 0 && rates.length < 5; index--) {
      const session = sessions[index];
      if (session.percent[band] >= 3)
        rates.push(session.minutes[band] / session.percent[band]);
    }
    if (rates.length === 0)
      return defaultRates[band];
    rates.sort((a, b) => a - b);
    return rates[Math.floor(rates.length / 2)];
  }
  return { below80: median("below80"), from80: median("from80") };
}

// Returns { limit: number | null (null leaves the controller alone), note: string | null,
// intents: with expired entries dropped and latches set }.
function plan(now, charge, plugged, rules, intents, rates) {
  const today = day(now);
  let override = intents.override ?? null;
  if (override && (override.date !== today || !rules.work))
    override = null;
  let target = intents.target ? Object.assign({}, intents.target) : null;
  // A manual choice keeps today's end-of-work latch, so going back on schedule does not drain.
  let workCharging = intents.workCharging?.startsWith(today) ? intents.workCharging : null;

  // What the schedule wants now: a manual choice, else working hours.
  let scheduleLimit = null;
  let scheduleNote = rules.workProblem ?? null;
  const work = rules.work;
  if (override) {
    scheduleLimit = override.limit;
    scheduleNote = `Your ${override.limit}% until midnight`;
  } else if (work) {
    const wall = new Date(now);
    const minute = wall.getHours() * 60 + wall.getMinutes();
    if (work.days.includes(wall.getDay()) && minute >= work.startMinute && minute < work.endMinute) {
      const latch = `${today} ${work.endMinute}`;
      const finish = at(now, work.endMinute);
      const start = finish - minutesNeeded(charge, work.after - rules.tolerance, rates) * 60000;
      if (intents.workCharging === latch || now >= start) {
        workCharging = latch;
        scheduleLimit = work.after;
        scheduleNote = `Charging to ${work.after}% by ${clock(finish, now)}`;
      } else {
        scheduleLimit = work.during;
        scheduleNote = `Holding ${work.during}% · ${work.after}% from ${clock(start, now)}`;
      }
    } else {
      scheduleLimit = work.after;
      scheduleNote = `${work.after}% outside work hours`;
    }
  }

  let limit = scheduleLimit, note = scheduleNote;
  let restore = intents.restore ?? null;
  if (target) {
    // A target only ever raises the schedule's limit. It ends once its deadline has passed and
    // the laptop is unplugged: ending while plugged in would drain it right at the desk.
    const base = scheduleLimit ?? target.waitLimit;
    const deadline = clock(target.deadline, now);
    const start = target.deadline - minutesNeeded(charge, target.limit - rules.tolerance, rates) * 60000;
    if (now >= target.deadline && !plugged) {
      restore = target.waitLimit;
      target = null;
      limit = base;
    } else if (now >= target.deadline) {
      limit = Math.max(base, target.limit);
      note = `Holding ${target.limit}% until unplugged`;
    } else if (target.started || now >= start) {
      target.started = true;
      limit = Math.max(base, target.limit);
      note = `Charging to ${target.limit}% by ${deadline}`;
    } else if (base < target.limit) {
      limit = base;
      note = `${target.limit}% by ${deadline} · from ${clock(start, now)}`;
    }
  }
  // A schedule or a running target decides the limit instead of a restore.
  if (scheduleLimit !== null || target !== null)
    restore = null;
  return {
    limit: limit ?? restore,
    note: note,
    intents: { override: override, target: target, workCharging: workCharging, restore: restore }
  };
}
