.pragma library
// Local wall-clock times for the panel's "charge by" editor. It uses no Qt, so node can test it
// alone. Times are milliseconds since the epoch.

const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function pad(number) {
  return String(number).padStart(2, "0");
}

function day(time) {
  const date = new Date(time);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

// The Date constructor reads its fields as local time. A time the spring change skips becomes the
// moment after the gap; a time the autumn change repeats is its first pass. Only upcoming()
// corrects for that.
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
