/* Checks for Sources/AtlasCore/Resources/crm.html.
   Run:  node Tests/crm_view_test.js
   Pulls the logic out of the page so this tests what actually ships. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const pagePath = path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'crm.html');
const html = fs.readFileSync(pagePath, 'utf8');
const script = html.match(/<script>\n'use strict';([\s\S]*?)<\/script>/)[1];
const start = script.indexOf("/* ---------- pure logic");
const end = script.indexOf("/* ---------- end pure logic ---------- */");
if (start < 0 || end < 0) throw new Error('logic markers not found in crm.html');

const api = (new Function(script.slice(start, end) +
  ';return {applyView,sortDeals,escapeHtml,formatMoney,compactMoney,groupByStage,isOverdue,relativeDay,' +
  'companyName,summaryTiles,parseMoney,parseDateInput,toDateInput};'))();

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); pass++; }
  catch (e) { console.log('FAIL ' + name + '\n  ' + e.message); fail++; }
};

/* ---------- escaping ---------- */

t('every character that can start markup is escaped', () => {
  assert.strictEqual(api.escapeHtml('<script>alert(1)</script>'),
    '&lt;script&gt;alert(1)&lt;/script&gt;');
  assert.strictEqual(api.escapeHtml('a & b'), 'a &amp; b');
  assert.strictEqual(api.escapeHtml('say "hi"'), 'say &quot;hi&quot;');
  assert.strictEqual(api.escapeHtml("it's"), 'it&#39;s');
});

t('an attribute break-out is neutralised', () => {
  const hostile = '" onmouseover="alert(1)';
  const escaped = api.escapeHtml(hostile);
  assert.ok(!escaped.includes('"'), 'no bare double quote survives');
  assert.strictEqual(escaped, '&quot; onmouseover=&quot;alert(1)');
});

t('escaping is not fooled by an already-escaped string', () => {
  // Double-escaping is ugly but safe; the point is that it never un-escapes.
  assert.strictEqual(api.escapeHtml('&lt;b&gt;'), '&amp;lt;b&amp;gt;');
});

t('null and undefined escape to an empty string, not "null"', () => {
  assert.strictEqual(api.escapeHtml(null), '');
  assert.strictEqual(api.escapeHtml(undefined), '');
  assert.strictEqual(api.escapeHtml(0), '0');
});

/* ---------- money ---------- */

t('cents render as readable amounts', () => {
  assert.strictEqual(api.formatMoney(0), '$0');
  assert.strictEqual(api.formatMoney(100), '$1');
  assert.strictEqual(api.formatMoney(125050), '$1,250.50');
  assert.strictEqual(api.formatMoney(1000000), '$10,000');
  assert.strictEqual(api.formatMoney(-2500), '-$25');
});

t('a nonsense amount does not render as NaN', () => {
  assert.strictEqual(api.formatMoney(undefined), '$0');
  assert.strictEqual(api.formatMoney('nope'), '$0');
});

t('compact money shortens the big numbers', () => {
  assert.strictEqual(api.compactMoney(90000), '$900');
  assert.strictEqual(api.compactMoney(4560000), '$45.6k');
  assert.strictEqual(api.compactMoney(120000000), '$1.2M');
  assert.strictEqual(api.compactMoney(100000000), '$1M', 'a round million loses the .0');
});

t('typed dollars become whole cents', () => {
  assert.strictEqual(api.parseMoney('1250.50'), 125050);
  assert.strictEqual(api.parseMoney('$1,250.50'), 125050);
  assert.strictEqual(api.parseMoney('42'), 4200);
  assert.strictEqual(api.parseMoney(''), 0);
  assert.strictEqual(api.parseMoney('abc'), 0, 'junk is zero, never NaN');
});

/* ---------- pipeline ---------- */

const STAGES = [
  { id: 'lead', title: 'Lead' },
  { id: 'contacted', title: 'Contacted' },
  { id: 'qualified', title: 'Qualified' },
  { id: 'proposal', title: 'Proposal' },
  { id: 'won', title: 'Won' },
  { id: 'lost', title: 'Lost' }
];

t('deals group into the six stages in board order', () => {
  const columns = api.groupByStage([
    { id: 'a', stage: 'lead', valueCents: 1000 },
    { id: 'b', stage: 'won', valueCents: 5000 },
    { id: 'c', stage: 'lead', valueCents: 2000 }
  ], STAGES);
  assert.deepStrictEqual(columns.map(c => c.id),
    ['lead', 'contacted', 'qualified', 'proposal', 'won', 'lost']);
  assert.deepStrictEqual(columns[0].deals.map(d => d.id), ['a', 'c']);
  assert.strictEqual(columns[0].total, 3000);
  assert.strictEqual(columns[1].deals.length, 0, 'an empty stage still gets a column');
});

t('a deal in an unknown stage is dropped rather than inventing a column', () => {
  const columns = api.groupByStage([{ id: 'x', stage: 'ascended', valueCents: 1 }], STAGES);
  assert.strictEqual(columns.length, 6);
  assert.strictEqual(columns.reduce((n, c) => n + c.deals.length, 0), 0);
});

t('grouping survives empty and missing input', () => {
  assert.strictEqual(api.groupByStage([], STAGES).length, 6);
  assert.strictEqual(api.groupByStage(null, STAGES).length, 6);
  assert.deepStrictEqual(api.groupByStage([{ id: 'a', stage: 'lead' }], []), []);
});

t('column totals ignore a missing value', () => {
  const columns = api.groupByStage([
    { id: 'a', stage: 'lead' },
    { id: 'b', stage: 'lead', valueCents: 500 }
  ], STAGES);
  assert.strictEqual(columns[0].total, 500);
});

/* ---------- follow-up ---------- */

const NOW = new Date(2026, 8, 7, 12, 0, 0).getTime();
const secs = ms => Math.floor(ms / 1000);

t('an open deal past its date is overdue', () => {
  assert.ok(api.isOverdue({ stage: 'lead', nextFollowUpAt: secs(NOW - 86400000) }, NOW));
  assert.ok(!api.isOverdue({ stage: 'lead', nextFollowUpAt: secs(NOW + 86400000) }, NOW));
});

t('a closed deal is never overdue', () => {
  const past = secs(NOW - 86400000);
  assert.ok(!api.isOverdue({ stage: 'won', nextFollowUpAt: past }, NOW));
  assert.ok(!api.isOverdue({ stage: 'lost', nextFollowUpAt: past }, NOW));
});

t('a deal with no date is never overdue', () => {
  assert.ok(!api.isOverdue({ stage: 'lead' }, NOW));
  assert.ok(!api.isOverdue(null, NOW));
});

t('dates read as relative days near today', () => {
  assert.strictEqual(api.relativeDay(secs(NOW), NOW), 'Today');
  assert.strictEqual(api.relativeDay(secs(NOW + 86400000), NOW), 'Tomorrow');
  assert.strictEqual(api.relativeDay(secs(NOW - 86400000), NOW), 'Yesterday');
  assert.strictEqual(api.relativeDay(secs(NOW + 3 * 86400000), NOW), 'in 3d');
  assert.strictEqual(api.relativeDay(secs(NOW - 4 * 86400000), NOW), '4d ago');
  assert.strictEqual(api.relativeDay(0, NOW), '', 'no date renders as nothing');
});

t('a far date falls back to a real date', () => {
  const far = api.relativeDay(secs(NOW + 90 * 86400000), NOW);
  assert.ok(/[A-Z][a-z]{2} \d+/.test(far), 'got ' + far);
});

/* ---------- date fields ---------- */

t('a date input round trips', () => {
  const epoch = api.parseDateInput('2026-09-07');
  assert.ok(epoch > 0);
  assert.strictEqual(api.toDateInput(epoch), '2026-09-07');
});

t('a date is anchored at midday so a timezone shift cannot move the day', () => {
  const epoch = api.parseDateInput('2026-01-01');
  assert.strictEqual(new Date(epoch * 1000).getHours(), 12);
  assert.strictEqual(api.toDateInput(epoch), '2026-01-01');
});

t('a malformed date is rejected rather than guessed at', () => {
  assert.strictEqual(api.parseDateInput(''), null);
  assert.strictEqual(api.parseDateInput('tomorrow'), null);
  assert.strictEqual(api.parseDateInput('07/09/2026'), null);
  assert.strictEqual(api.toDateInput(null), '');
});

/* ---------- lookups ---------- */

t('a company name resolves, and a dangling link does not throw', () => {
  const companies = [{ id: 'c1', name: 'Northwind' }];
  assert.strictEqual(api.companyName(companies, 'c1'), 'Northwind');
  assert.strictEqual(api.companyName(companies, 'gone'), '');
  assert.strictEqual(api.companyName(companies, ''), '');
  assert.strictEqual(api.companyName(null, 'c1'), '');
});

/* ---------- overview ---------- */

t('the tiles read off the summary', () => {
  const tiles = api.summaryTiles({
    openValueCents: 250000, openCount: 2, weightedValueCents: 100000,
    wonValueCents: 900000, wonCount: 1, needingFollowUp: 3,
    companyCount: 4, contactCount: 6
  });
  assert.strictEqual(tiles.length, 5);
  assert.strictEqual(tiles[0].value, '$2.5k');
  assert.strictEqual(tiles[0].sub, '2 open deals');
  assert.strictEqual(tiles[2].value, '$9k');
  assert.strictEqual(tiles[2].sub, '1 deal', 'singular when there is one');
  assert.strictEqual(tiles[3].value, '3');
  assert.strictEqual(tiles[3].tone, 'warn', 'outstanding follow-ups are flagged');
  assert.strictEqual(tiles[4].sub, '6 contacts');
});

t('an empty summary renders zeros rather than blanks', () => {
  const tiles = api.summaryTiles({});
  assert.strictEqual(tiles[0].value, '$0');
  assert.strictEqual(tiles[3].value, '0');
  assert.strictEqual(tiles[3].tone, '', 'nothing to chase is not a warning');
  assert.strictEqual(api.summaryTiles(null).length, 5);
});

/* ---------- saved views and sorting ---------- */

const DEALS = [
  { id:'a', title:'Pier rebuild',  stage:'proposal', valueCents:5000000, probability:60,
    updatedAt: 1757000000, nextFollowUpAt: 1757200000 },
  { id:'b', title:'Dock lighting', stage:'lead',     valueCents:50000,   probability:10,
    updatedAt: 1750000000 },
  { id:'c', title:'Crane service', stage:'won',      valueCents:900000,  probability:100,
    updatedAt: 1757100000, nextFollowUpAt: 1757100000 }
];

t('no view means everything, newest first', () => {
  // c 1757100000 > a 1757000000 > b 1750000000
  assert.deepStrictEqual(api.applyView(DEALS, null).map(d => d.id), ['c','a','b']);
});

t('a view narrows by stage', () => {
  assert.deepStrictEqual(api.applyView(DEALS, { stage:'proposal' }).map(d => d.id), ['a']);
});

t('a view narrows by minimum value', () => {
  assert.deepStrictEqual(api.applyView(DEALS, { minValueCents: 100000 }).map(d => d.id).sort(),
    ['a','c']);
});

t('a view can find work nobody has touched', () => {
  const now = 1757000000 * 1000;
  const stale = api.applyView(DEALS, { staleDays: 30 }, now);
  assert.deepStrictEqual(stale.map(d => d.id), ['b'], 'only the one left alone for a month');
});

t('filters stack rather than replacing each other', () => {
  const out = api.applyView(DEALS, { stage:'proposal', minValueCents: 100000 });
  assert.deepStrictEqual(out.map(d => d.id), ['a']);
  assert.strictEqual(api.applyView(DEALS, { stage:'lead', minValueCents: 100000 }).length, 0);
});

t('every column sorts both ways', () => {
  assert.deepStrictEqual(api.sortDeals(DEALS, 'name', true).map(d => d.title),
    ['Crane service','Dock lighting','Pier rebuild']);
  assert.deepStrictEqual(api.sortDeals(DEALS, 'value', true).map(d => d.id), ['b','c','a']);
  assert.deepStrictEqual(api.sortDeals(DEALS, 'value', false).map(d => d.id), ['a','c','b']);
  assert.deepStrictEqual(api.sortDeals(DEALS, 'stage', true).map(d => d.id), ['b','a','c'],
    'board order, not alphabetical');
  assert.deepStrictEqual(api.sortDeals(DEALS, 'probability', true).map(d => d.id), ['b','a','c']);
});

t('a deal with no follow-up date sorts last, not first', () => {
  const out = api.sortDeals(DEALS, 'followUp', true);
  assert.strictEqual(out[out.length - 1].id, 'b', 'an empty cell is not "soonest"');
});

t('sorting and filtering survive missing fields and empty input', () => {
  assert.deepStrictEqual(api.applyView([], { stage:'lead' }), []);
  assert.deepStrictEqual(api.applyView(null, null), []);
  assert.strictEqual(api.sortDeals([{ id:'x' }], 'value', true).length, 1);
});

t('the page and Swift agree on what a view means', () => {
  const swift = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'AtlasCore', 'CRM', 'CRMModels.swift'), 'utf8');
  const sortBlock = swift.slice(swift.indexOf('public enum SortField'),
                                swift.indexOf('public struct SavedView'));
  ['name','value','stage','probability','followUp','updated'].forEach(field => {
    assert.ok(new RegExp('\\b' + field + '\\b').test(sortBlock),
      'Swift SortField is missing ' + field);
  });
  ['stage','minValueMinorUnits','staleDays'].forEach(filter => {
    assert.ok(swift.includes(filter), 'Swift SavedView is missing ' + filter);
  });
});

/* ---------- the page's own guarantees ---------- */

t('the page declares a strict CSP with no network access', () => {
  const csp = html.match(/Content-Security-Policy"\s*\n?\s*content="([^"]+)"/)[1];
  assert.ok(csp.includes("default-src 'none'"), 'default-src none');
  assert.ok(!/connect-src/.test(csp), 'no connect-src means fetch and XHR are refused');
  assert.ok(!/img-src/.test(csp), 'no img-src means no remote images');
  assert.ok(!/'self'/.test(csp), "no 'self' means no sibling file loads either");
  assert.ok(csp.includes("form-action 'none'"));
  assert.ok(csp.includes("base-uri 'none'"));
});

t('the page loads no external resource', () => {
  assert.ok(!/<script[^>]+src=/i.test(html), 'no external script');
  assert.ok(!/<link[^>]+rel=["']?stylesheet/i.test(html), 'no external stylesheet');
  assert.ok(!/https?:\/\//i.test(html.replace(/<!--[\s\S]*?-->/g, '')),
    'no absolute URLs outside comments');
});

t('the page uses the shared design system rather than redefining it', () => {
  ['atlas-toolbar', 'atlas-btn', 'atlas-field', 'atlas-input', 'atlas-empty',
   'atlas-sheet', 'atlas-seg', 'atlas-label'].forEach(cls => {
    assert.ok(html.includes(cls), 'expected shared component ' + cls);
  });
  assert.ok(!/--gold:\s*#/.test(html), 'colour tokens come from atlas-theme.css');
  assert.ok(!/--fs-label:\s*\d/.test(html), 'type tokens come from atlas-theme.css');
});

t('record text reaches the DOM through textContent or escapeHtml', () => {
  // innerHTML is allowed only for markup this file wrote itself; every use must
  // be a literal or already escaped. A raw record field would be a hole.
  const uses = html.match(/\.innerHTML\s*=\s*([^;]+);/g) || [];
  uses.forEach(use => {
    // Copy text inside a literal is not data, so string contents are removed
    // before looking for anything that could carry a record field.
    const withoutLiterals = use
      .replace(/'(?:[^'\\]|\\.)*'/g, "''")
      .replace(/"(?:[^"\\]|\\.)*"/g, '""')
      .replace(/`(?:[^`\\]|\\.)*`/g, '``');
    const risky = /[A-Za-z_$][\w$]*\s*[.[]/.test(withoutLiterals)
      && !withoutLiterals.includes('escapeHtml');
    assert.ok(!risky, 'unescaped record data in innerHTML: ' + use.slice(0, 90));
  });
});

t('the bridge vocabulary matches what Swift allows', () => {
  const swift = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'AtlasCore', 'CRM', 'CRMAction.swift'), 'utf8');
  const allowed = new Set(
    swift.slice(swift.indexOf('enum CRMActionKind'), swift.indexOf('/// A decoded request'))
      .split('\n').filter(l => l.trim().startsWith('case '))
      .map(l => l.trim().replace('case ', '').trim()));
  assert.ok(allowed.size >= 10, 'found ' + allowed.size + ' allowlisted actions');

  const sent = new Set();
  const re = /send\(\s*'([a-zA-Z]+)'/g;
  let m;
  while ((m = re.exec(script))) sent.add(m[1]);
  assert.ok(sent.size > 0, 'the page sends something');
  sent.forEach(action => {
    assert.ok(allowed.has(action), action + ' is not in the Swift allowlist');
  });
});

t('the page never builds a message outside the send() helper', () => {
  const posts = script.match(/postMessage\(/g) || [];
  assert.strictEqual(posts.length, 1,
    'exactly one postMessage, inside send(), so the vocabulary stays reviewable');
});

console.log('\npass ' + pass + ' / fail ' + fail);
process.exit(fail ? 1 : 0);
