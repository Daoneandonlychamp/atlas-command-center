/* Checks for Sources/AtlasCore/Resources/calendar.html.
   Run:  node Tests/calendar_view_test.js
   Pulls the logic straight out of the page so this tests what actually ships. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'calendar.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const start = script.indexOf('const MIN =');
const end = script.indexOf('/* ---------- end pure logic ---------- */');
if (start < 0 || end < 0) throw new Error('logic markers not found in calendar.html');
const api = (new Function(script.slice(start, end) +
  ';return {escapeHtml,startOfDay,addDays,startOfWeek,sameDay,rangeFor,dashboardRange,monthGrid,' +
  'eventsOn,upcomingDays,isBill,splitAmount,totalOf,dueLabel,freeText,clockLabel,localInput,' +
  'MIN,DAY,BILL_LIST};'))();

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); pass++; }
  catch (e) { console.log('FAIL ' + name + '\n  ' + e.message); fail++; }
};

const ev = (y, m, d, h, endH, extra) => Object.assign({
  id: String(Math.random()), title: 'Event', allDay: false, calendar: 'Personal',
  start: new Date(y, m, d, h).getTime(),
  end: new Date(y, m, d, endH).getTime()
}, extra || {});

// --- date maths ---
t('week starts on Sunday', () => {
  const wed = new Date(2026, 8, 9); // Wed 9 Sep 2026
  assert.strictEqual(api.startOfWeek(wed).getDay(), 0);
  assert.strictEqual(api.startOfWeek(wed).getDate(), 6);
});
t('month range covers the whole 6-week grid', () => {
  const r = api.rangeFor(new Date(2026, 8, 15));
  assert.strictEqual(r.start.getDay(), 0, 'grid starts on a Sunday');
  assert.ok(r.start <= new Date(2026, 8, 1), 'includes the leading days');
  assert.strictEqual(Math.round((r.end - r.start) / api.DAY), 42, 'exactly six weeks');
});
t('month range crossing a year boundary still works', () => {
  const r = api.rangeFor(new Date(2026, 11, 20));
  assert.ok(r.end > r.start);
  assert.strictEqual(Math.round((r.end - r.start) / api.DAY), 42);
});
t('the mini month is 42 cells starting on a Sunday', () => {
  const grid = api.monthGrid(new Date(2026, 8, 15));
  assert.strictEqual(grid.length, 42);
  assert.strictEqual(grid[0].getDay(), 0);
  assert.ok(grid.some(d => d.getMonth() === 8 && d.getDate() === 1));
  assert.ok(grid.some(d => d.getMonth() === 8 && d.getDate() === 30));
});

// --- the fetch window ---
// The bug this prevents: paging the mini month to December leaves the "next 7
// days" card asking for December and rendering an empty week.
t('range covers the month on screen', () => {
  const r = api.dashboardRange(new Date(2026, 8, 15), new Date(2026, 8, 10));
  const grid = api.rangeFor(new Date(2026, 8, 15));
  assert.ok(r.start <= grid.start && r.end >= grid.end);
});
t('range still covers the week ahead when the month is paged away', () => {
  const now = new Date(2026, 8, 10);
  const r = api.dashboardRange(new Date(2026, 11, 1), now);
  assert.ok(r.start <= api.startOfDay(now), 'starts on or before today');
  assert.ok(r.end >= api.addDays(api.startOfDay(now), 8), 'reaches a week out');
});
t('range reaches backwards when the month is paged into the past', () => {
  const now = new Date(2026, 8, 10);
  const r = api.dashboardRange(new Date(2026, 0, 1), now);
  assert.ok(r.end >= api.addDays(api.startOfDay(now), 8));
  assert.ok(r.start <= new Date(2026, 0, 1), 'reaches the January grid');
});

// --- which events land on which day ---
t('an event lands on its own day', () => {
  const list = api.eventsOn([ev(2026, 8, 10, 13, 14)], new Date(2026, 8, 10));
  assert.strictEqual(list.length, 1);
  assert.strictEqual(api.eventsOn([ev(2026, 8, 10, 13, 14)], new Date(2026, 8, 11)).length, 0);
});
t('a multi-day event shows on every day it touches', () => {
  const trip = { id: 't', title: 'Trip', allDay: true,
    start: new Date(2026, 8, 10, 0).getTime(), end: new Date(2026, 8, 13, 0).getTime() };
  [10, 11, 12].forEach(d =>
    assert.strictEqual(api.eventsOn([trip], new Date(2026, 8, d)).length, 1, 'day ' + d));
  assert.strictEqual(api.eventsOn([trip], new Date(2026, 8, 14)).length, 0, 'not after it ends');
});
t('an event ending exactly at midnight does not bleed into the next day', () => {
  const late = { id: 'l', title: 'Late', allDay: false,
    start: new Date(2026, 8, 10, 22).getTime(), end: new Date(2026, 8, 11, 0).getTime() };
  assert.strictEqual(api.eventsOn([late], new Date(2026, 8, 10)).length, 1);
  assert.strictEqual(api.eventsOn([late], new Date(2026, 8, 11)).length, 0);
});
t('all-day entries sort above timed ones, then by start', () => {
  const list = api.eventsOn([
    ev(2026, 8, 10, 15, 16, { title: 'Late' }),
    ev(2026, 8, 10, 9, 10, { title: 'Early' }),
    ev(2026, 8, 10, 0, 23, { title: 'Holiday', allDay: true })
  ], new Date(2026, 8, 10));
  assert.deepStrictEqual(list.map(e => e.title), ['Holiday', 'Early', 'Late']);
});

// --- the upcoming card ---
t('upcoming starts tomorrow and runs seven days', () => {
  const days = api.upcomingDays([], new Date(2026, 8, 10, 15), 7);
  assert.strictEqual(days.length, 7);
  assert.strictEqual(days[0].date.getDate(), 11, 'tomorrow, not today');
  assert.strictEqual(days[6].date.getDate(), 17);
  assert.strictEqual(days[0].date.getHours(), 0, 'each day starts at midnight');
});
t('upcoming buckets events onto the right day', () => {
  const days = api.upcomingDays([ev(2026, 8, 12, 9, 10)], new Date(2026, 8, 10), 7);
  assert.strictEqual(days[1].events.length, 1, 'the 12th');
  assert.strictEqual(days[0].events.length, 0);
});
t('upcoming crosses a month boundary', () => {
  const days = api.upcomingDays([ev(2026, 9, 2, 9, 10)], new Date(2026, 8, 29), 7);
  const hit = days.find(d => d.events.length);
  assert.ok(hit, 'the October event was found');
  assert.strictEqual(hit.date.getMonth(), 9);
});

// --- bills ---
t('bills are the ones in the ATLAS Bills list', () => {
  assert.ok(api.isBill({ list: api.BILL_LIST }));
  assert.ok(api.isBill({ calendar: api.BILL_LIST }));
  assert.ok(!api.isBill({ list: 'Reminders' }));
  assert.ok(!api.isBill({}));
});
t('an amount is split off the title', () => {
  const parts = api.splitAmount('Chat GPT Plus — $21.28');
  assert.strictEqual(parts.name, 'Chat GPT Plus');
  assert.strictEqual(parts.amount, '$21.28');
});
t('a plain hyphen and a thousands separator both work', () => {
  assert.strictEqual(api.splitAmount('railway - $7.64').amount, '$7.64');
  assert.strictEqual(api.splitAmount('Server — $1,240.00').amount, '$1,240.00');
});
t('a title with no amount comes back whole', () => {
  const parts = api.splitAmount('Revoke premium from sam@example.com');
  assert.strictEqual(parts.name, 'Revoke premium from sam@example.com');
  assert.strictEqual(parts.amount, '');
});
t('a title with an inner dash keeps it', () => {
  assert.strictEqual(api.splitAmount('Confirmed - Calendly').name, 'Confirmed - Calendly');
});
t('the total adds only what has an amount', () => {
  assert.strictEqual(api.totalOf([
    { title: 'A — $21.28' }, { title: 'B — $106.60' }, { title: 'C' }
  ]), '$127.88');
  assert.strictEqual(api.totalOf([]), '');
});

// --- due labels ---
const now = new Date(2026, 8, 10, 12, 0);
t('an overdue task says so', () => {
  const label = api.dueLabel(new Date(2026, 8, 8, 9), now);
  assert.ok(label.over);
  assert.strictEqual(label.text, '2d overdue');
});
t('overdue earlier today reads as overdue, not as today', () => {
  const label = api.dueLabel(new Date(2026, 8, 10, 9), now);
  assert.ok(label.over);
  assert.ok(label.text.startsWith('Overdue'));
});
t('today and tomorrow are named', () => {
  assert.ok(api.dueLabel(new Date(2026, 8, 10, 18), now).text.startsWith('Today'));
  assert.ok(api.dueLabel(new Date(2026, 8, 11, 9), now).text.startsWith('Tomorrow'));
  assert.ok(!api.dueLabel(new Date(2026, 8, 11, 9), now).over);
});
t('further out becomes a date', () => {
  const label = api.dueLabel(new Date(2026, 9, 1, 9), now);
  assert.ok(/Oct/.test(label.text), label.text);
  assert.ok(!label.over);
});
t('no due date is no label', () => {
  assert.strictEqual(api.dueLabel(null, now).text, '');
});

// --- the shape of a day ---
t('an empty day reads as available, not as a hole', () => {
  assert.strictEqual(api.freeText([], new Date(2026, 8, 10), now.getTime()), 'Nothing scheduled');
});
t('a day of meetings says when it clears', () => {
  const list = [ev(2026, 8, 10, 13, 14), ev(2026, 8, 10, 15, 17)];
  assert.strictEqual(api.freeText(list, new Date(2026, 8, 10), now.getTime()), 'Free after 5pm');
});
t('a finished day says so instead of promising time that has gone', () => {
  const list = [ev(2026, 8, 10, 9, 10)];
  assert.strictEqual(api.freeText(list, new Date(2026, 8, 10), now.getTime()),
    'Clear for the rest of the day');
});
t('an all-day-only day is counted, not given a time', () => {
  const holiday = ev(2026, 8, 10, 0, 23, { allDay: true });
  assert.strictEqual(api.freeText([holiday], new Date(2026, 8, 10), now.getTime()),
    '1 all-day entry');
});
t('an event running past midnight is clipped to the day', () => {
  const overnight = { id: 'o', title: 'Overnight', allDay: false,
    start: new Date(2026, 8, 10, 22).getTime(), end: new Date(2026, 8, 11, 3).getTime() };
  assert.strictEqual(api.freeText([overnight], new Date(2026, 8, 10), now.getTime()), 'Free after 12am');
});

// --- formatting ---
t('clock labels drop :00 and keep minutes', () => {
  assert.strictEqual(api.clockLabel(new Date(2026, 8, 9, 13, 0)), '1pm');
  assert.strictEqual(api.clockLabel(new Date(2026, 8, 9, 13, 5)), '1:05pm');
  assert.strictEqual(api.clockLabel(new Date(2026, 8, 9, 0, 0)), '12am');
});
t('datetime-local values are local, not UTC', () => {
  assert.strictEqual(api.localInput(new Date(2026, 8, 9, 8, 5)), '2026-09-09T08:05');
});
t('escapeHtml neutralises a calendar invite from a stranger', () => {
  assert.strictEqual(api.escapeHtml('<img src=x onerror=alert(1)>'),
    '&lt;img src=x onerror=alert(1)&gt;');
  assert.strictEqual(api.escapeHtml(`"'&`), '&quot;&#39;&amp;');
});

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
