/* Checks for Sources/AtlasCore/Resources/kanban.html.
   Run:  node Tests/kanban_test.js
   Pulls the logic out of the page so this tests what actually ships. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'kanban.html'), 'utf8');
// The vendored Sortable is loaded with src=; the page's own logic is the inline block.
const inline = html.match(/<script>\n'use strict';([\s\S]*?)<\/script>/);
if (!inline) throw new Error('inline script block not found in kanban.html');
const script = inline[1];
const start = script.indexOf('const DAY_MS');
const end = script.indexOf('/* ---------- end pure logic ---------- */');
if (start < 0 || end < 0) throw new Error('logic markers not found in kanban.html');
const api = (new Function(script.slice(start, end) +
  ';return {escapeHtml,parseQuickAdd,parseWhen,ageOf,dueLabel,DAY_MS};'))();

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); pass++; }
  catch (e) { console.log('FAIL ' + name + '\n  ' + e.message); fail++; }
};

// A Wednesday, so weekday maths is checkable.
const NOW = new Date(2026, 8, 9, 14, 30);

// --- quick add: the syntax people actually type ---
t('plain text is just a title', () => {
  const r = api.parseQuickAdd('Ship the build', NOW);
  assert.strictEqual(r.title, 'Ship the build');
  assert.strictEqual(r.priority, 0);
  assert.strictEqual(r.list, null);
  assert.strictEqual(r.due, null);
});
t('priority, list and date are stripped from the title', () => {
  const r = api.parseQuickAdd('Ship the build !1 @Work ^tomorrow', NOW);
  assert.strictEqual(r.title, 'Ship the build');
  assert.strictEqual(r.priority, 1);
  assert.strictEqual(r.list, 'Work');
  assert.strictEqual(r.due.getDate(), 10);
  assert.strictEqual(r.due.getHours(), 9, 'a bare date means 9am, not midnight');
});
t('tokens work in any position', () => {
  const r = api.parseQuickAdd('@Home !2 Fix the sink', NOW);
  assert.strictEqual(r.title, 'Fix the sink');
  assert.strictEqual(r.list, 'Home');
  assert.strictEqual(r.priority, 2);
});
t('an email address is not a list', () => {
  // "@" only counts at a word boundary, so this must survive intact.
  const r = api.parseQuickAdd('Email dave@example.com about the invoice', NOW);
  assert.ok(r.title.includes('dave@example.com'), 'got: ' + r.title);
  assert.strictEqual(r.list, null);
});
t('an exclamation in prose is not a priority', () => {
  const r = api.parseQuickAdd('Ship it! today', NOW);
  assert.strictEqual(r.priority, 0);
  assert.ok(r.title.includes('Ship it!'));
});
t('a priority out of range stays in the title', () => {
  const r = api.parseQuickAdd('Do it !9', NOW);
  assert.strictEqual(r.priority, 0);
  assert.ok(r.title.includes('!9'));
});
t('an unparseable date is left in the title rather than dropped', () => {
  const r = api.parseQuickAdd('Call mum ^someday', NOW);
  assert.strictEqual(r.due, null);
  assert.ok(r.title.includes('^someday'), 'got: ' + r.title);
});
t('title-only after stripping everything is empty, not whitespace', () => {
  const r = api.parseQuickAdd('!1 @Work', NOW);
  assert.strictEqual(r.title, '');
});

// --- dates ---
t('today and tomorrow', () => {
  assert.strictEqual(api.parseWhen('today', NOW).getDate(), 9);
  assert.strictEqual(api.parseWhen('tomorrow', NOW).getDate(), 10);
});
t('relative offsets', () => {
  assert.strictEqual(api.parseWhen('+3d', NOW).getDate(), 12);
  assert.strictEqual(api.parseWhen('+1w', NOW).getDate(), 16);
});
t('an ISO date', () => {
  const d = api.parseWhen('2026-12-25', NOW);
  assert.strictEqual(d.getMonth(), 11);
  assert.strictEqual(d.getDate(), 25);
});
t('a weekday means the next one', () => {
  // NOW is a Wednesday.
  assert.strictEqual(api.parseWhen('friday', NOW).getDate(), 11);
  assert.strictEqual(api.parseWhen('mon', NOW).getDate(), 14);
});
t('today\'s weekday means next week, not five minutes ago', () => {
  const d = api.parseWhen('wednesday', NOW);
  assert.strictEqual(d.getDate(), 16, 'must jump a week rather than land in the past');
});
t('nonsense is rejected', () => {
  assert.strictEqual(api.parseWhen('banana', NOW), null);
  assert.strictEqual(api.parseWhen('mo', NOW), null, 'too short to be unambiguous');
});

// --- card aging (Kanboard's idea) ---
t('a fresh card does not age', () => {
  const now = NOW.getTime();
  const age = api.ageOf({ modified: new Date(now - 2 * api.DAY_MS).toISOString() }, now);
  assert.strictEqual(age.level, 0);
});
t('a week untouched is level 1, a fortnight is level 2', () => {
  const now = NOW.getTime();
  assert.strictEqual(api.ageOf({ modified: new Date(now - 8 * api.DAY_MS).toISOString() }, now).level, 1);
  assert.strictEqual(api.ageOf({ modified: new Date(now - 20 * api.DAY_MS).toISOString() }, now).level, 2);
});
t('a completed card never ages', () => {
  const now = NOW.getTime();
  const age = api.ageOf({ completed: true, modified: new Date(now - 90 * api.DAY_MS).toISOString() }, now);
  assert.strictEqual(age.level, 0, 'finished work sitting in Done is not rot');
});
t('a card with no timestamps does not crash or age', () => {
  assert.strictEqual(api.ageOf({}, NOW.getTime()).level, 0);
});
t('creation date is used when nothing has modified it', () => {
  const now = NOW.getTime();
  const age = api.ageOf({ created: new Date(now - 30 * api.DAY_MS).toISOString() }, now);
  assert.strictEqual(age.level, 2);
});

// --- due labels ---
t('due labels read like a person wrote them', () => {
  const now = NOW.getTime();
  assert.strictEqual(api.dueLabel(new Date(now + 2 * 3600000), now).text, 'today');
  assert.strictEqual(api.dueLabel(new Date(now + api.DAY_MS), now).text, 'tomorrow');
  assert.strictEqual(api.dueLabel(new Date(now - api.DAY_MS), now).overdue, true);
  assert.strictEqual(api.dueLabel(null, now), null);
});

// --- injection: a shared list is written to by other people ---
t('card titles are escaped', () => {
  assert.ok(!api.escapeHtml('<script>x</script>').includes('<script'));
});

console.log('\npass ' + pass + ' / fail ' + fail);
process.exit(fail ? 1 : 0);
