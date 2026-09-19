/* Checks for Sources/AtlasCore/Resources/canvas.html.
   Run:  node Tests/canvas_test.js
   Pulls the geometry out of the page so this tests what actually ships. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'canvas.html'), 'utf8');
const script = html.match(/<script>\n'use strict';([\s\S]*?)<\/script>/)[1];
const start = script.indexOf('/* Shared with the Assistant transcript');
const end = script.indexOf('/* ---------- end pure logic ---------- */');
if (start < 0 || end < 0) throw new Error('logic markers not found in canvas.html');

// The page takes escapeHtml and renderMarkdown from the shared markdown.js, so
// the harness provides the same global the browser would.
const shared = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'markdown.js'), 'utf8');
const sharedShim = {};
(new Function('window', shared))(sharedShim);
const markdown = sharedShim.atlasMarkdown;

const api = (new Function('window', script.slice(start, end) +
  ';return {escapeHtml,newId,toWorld,toScreen,zoomAt,fitView,portPoint,inferSides,wirePath,placeNew,nodesInRect,nodesInGroup,canvasVault,isUntitledCanvas,rankCanvases,filterCanvases,groupCanvases};'))(
  { atlasMarkdown: markdown });

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); pass++; }
  catch (e) { console.log('FAIL ' + name + '\n  ' + e.message); fail++; }
};
const near = (a, b, tol, why) => assert.ok(Math.abs(a - b) <= (tol || 0.01), (why || '') + ' got ' + a + ' want ~' + b);

// --- ids must look like the ones Obsidian writes ---
t('ids are 16 lowercase hex characters', () => {
  for (let i = 0; i < 40; i++) assert.match(api.newId(), /^[0-9a-f]{16}$/);
});
t('ids differ', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) seen.add(api.newId());
  assert.ok(seen.size > 190, 'ids should not collide in a small sample');
});

// --- coordinate transforms: every drag depends on these ---
t('world and screen round-trip', () => {
  const view = { x: 120, y: -40, scale: 1.75 };
  const point = { x: 933, y: 210 };
  const back = api.toScreen(api.toWorld(point, view), view);
  near(back.x, point.x, 0.001, 'x');
  near(back.y, point.y, 0.001, 'y');
});
t('at identity, world equals screen', () => {
  const w = api.toWorld({ x: 10, y: 20 }, { x: 0, y: 0, scale: 1 });
  assert.deepStrictEqual(w, { x: 10, y: 20 });
});

// --- zoom must keep the point under the cursor fixed ---
t('zooming holds the cursor point still', () => {
  const view = { x: 30, y: 60, scale: 1 };
  const cursor = { x: 400, y: 300 };
  const before = api.toWorld(cursor, view);
  const after = api.toWorld(cursor, api.zoomAt(view, cursor, 1.6));
  near(after.x, before.x, 0.001, 'x drifted');
  near(after.y, before.y, 0.001, 'y drifted');
});
t('zoom is clamped', () => {
  let view = { x: 0, y: 0, scale: 1 };
  for (let i = 0; i < 50; i++) view = api.zoomAt(view, { x: 0, y: 0 }, 2);
  assert.ok(view.scale <= 4, 'must not zoom past the ceiling');
  for (let i = 0; i < 100; i++) view = api.zoomAt(view, { x: 0, y: 0 }, 0.5);
  assert.ok(view.scale >= 0.1, 'must not zoom past the floor');
});

// --- fit ---
t('fit brings every node inside the viewport', () => {
  const nodes = [
    { x: 0, y: 0, width: 200, height: 100 },
    { x: 1400, y: 900, width: 200, height: 100 }
  ];
  const viewport = { width: 800, height: 600 };
  const view = api.fitView(nodes, viewport);
  nodes.forEach(n => {
    const tl = api.toScreen({ x: n.x, y: n.y }, view);
    const br = api.toScreen({ x: n.x + n.width, y: n.y + n.height }, view);
    assert.ok(tl.x >= -1 && tl.y >= -1, 'top-left inside');
    assert.ok(br.x <= viewport.width + 1 && br.y <= viewport.height + 1, 'bottom-right inside');
  });
});
t('fit on an empty canvas is the identity', () => {
  assert.deepStrictEqual(api.fitView([], { width: 800, height: 600 }), { x: 0, y: 0, scale: 1 });
});
t('fit on a single node does not zoom past the ceiling', () => {
  const view = api.fitView([{ x: 0, y: 0, width: 10, height: 10 }], { width: 800, height: 600 });
  assert.ok(view.scale <= 4);
});

// --- ports and edges ---
t('ports sit on the right edges', () => {
  const node = { x: 100, y: 200, width: 200, height: 100 };
  assert.deepStrictEqual(api.portPoint(node, 'top'), { x: 200, y: 200 });
  assert.deepStrictEqual(api.portPoint(node, 'bottom'), { x: 200, y: 300 });
  assert.deepStrictEqual(api.portPoint(node, 'left'), { x: 100, y: 250 });
  assert.deepStrictEqual(api.portPoint(node, 'right'), { x: 300, y: 250 });
});
t('sides are inferred along the dominant axis', () => {
  const origin = { x: 0, y: 0, width: 100, height: 100 };
  assert.deepStrictEqual(api.inferSides(origin, { x: 400, y: 0, width: 100, height: 100 }),
    { fromSide: 'right', toSide: 'left' });
  assert.deepStrictEqual(api.inferSides(origin, { x: -400, y: 0, width: 100, height: 100 }),
    { fromSide: 'left', toSide: 'right' });
  assert.deepStrictEqual(api.inferSides(origin, { x: 0, y: 400, width: 100, height: 100 }),
    { fromSide: 'bottom', toSide: 'top' });
  assert.deepStrictEqual(api.inferSides(origin, { x: 0, y: -400, width: 100, height: 100 }),
    { fromSide: 'top', toSide: 'bottom' });
});
t('wire path starts and ends where it should', () => {
  const d = api.wirePath({ x: 0, y: 0 }, 'right', { x: 200, y: 100 }, 'left');
  assert.ok(d.startsWith('M 0 0 C'), 'starts at the source: ' + d);
  assert.ok(d.trim().endsWith('200 100'), 'ends at the target: ' + d);
});

// --- placement ---
t('the first note lands in the middle of the view', () => {
  const at = api.placeNew([], { x: 0, y: 0, scale: 1 }, { width: 800, height: 600 },
                          { width: 200, height: 100 });
  assert.deepStrictEqual(at, { x: 300, y: 250 });
});
t('later notes land clear of existing ones', () => {
  const nodes = [{ x: 0, y: 0, width: 300, height: 100 }];
  const at = api.placeNew(nodes, { x: 0, y: 0, scale: 1 }, { width: 800, height: 600 },
                          { width: 200, height: 100 });
  assert.ok(at.x >= 300, 'must not overlap what is already there');
});

// --- a canvas can come from anywhere ---
t('node text is escaped', () => {
  assert.ok(!api.escapeHtml('<img src=x onerror=alert(1)>').includes('<img'));
});

// --- marquee selection ---
t('marquee selects anything it touches', () => {
  const nodes = [
    { id: 'a', x: 0, y: 0, width: 100, height: 100 },
    { id: 'b', x: 300, y: 300, width: 100, height: 100 }
  ];
  // Intersection, not containment: catching a corner is enough, which is far
  // less fussy to use than requiring a box drawn fully around a card.
  const hit = api.nodesInRect(nodes, { x1: 50, y1: 50, x2: 150, y2: 150 });
  assert.deepStrictEqual(hit.map(n => n.id), ['a']);
});
t('a marquee drawn backwards still works', () => {
  const nodes = [{ id: 'a', x: 0, y: 0, width: 100, height: 100 }];
  assert.strictEqual(api.nodesInRect(nodes, { x1: 200, y1: 200, x2: -50, y2: -50 }).length, 1);
});
t('an empty marquee selects nothing', () => {
  const nodes = [{ id: 'a', x: 0, y: 0, width: 100, height: 100 }];
  assert.strictEqual(api.nodesInRect(nodes, { x1: 500, y1: 500, x2: 600, y2: 600 }).length, 0);
});

// --- group membership ---
t('a group carries the nodes fully inside it', () => {
  const group = { id: 'g', type: 'group', x: 0, y: 0, width: 400, height: 400 };
  const nodes = [
    group,
    { id: 'inside', x: 50, y: 50, width: 100, height: 100 },
    { id: 'straddling', x: 350, y: 50, width: 200, height: 100 },
    { id: 'outside', x: 900, y: 900, width: 100, height: 100 }
  ];
  assert.deepStrictEqual(api.nodesInGroup(nodes, group).map(n => n.id), ['inside'],
    'a card half outside the group is not carried by it');
});
t('a group does not contain itself', () => {
  const group = { id: 'g', type: 'group', x: 0, y: 0, width: 400, height: 400 };
  assert.strictEqual(api.nodesInGroup([group], group).length, 0);
});

/* ---------- canvas picker ---------- */

t('a vault name is read out of an Obsidian path', () => {
  assert.strictEqual(api.canvasVault('~/Documents/Obsidian/MYTHOS Context/Canvases'),
    'MYTHOS Context');
  assert.strictEqual(api.canvasVault('~/Documents/Obsidian/SovereignOS'), 'SovereignOS');
});
t('a path outside an Obsidian tree falls back to its deepest folder', () => {
  assert.strictEqual(api.canvasVault('~/Desktop/scratch'), 'scratch');
  assert.strictEqual(api.canvasVault(''), 'Elsewhere');
  assert.strictEqual(api.canvasVault(null), 'Elsewhere');
});
t('Obsidian default names count as untitled', () => {
  assert.ok(api.isUntitledCanvas('Untitled'));
  assert.ok(api.isUntitledCanvas('untitled 12'));
  assert.ok(!api.isUntitledCanvas('Untitled Symphony'));
  assert.ok(!api.isUntitledCanvas('Roadmap'));
});
t('named canvases sort ahead of untitled ones, recency kept inside each', () => {
  const files = [
    { name: 'Untitled', where: '/v' },
    { name: 'Roadmap', where: '/v' },
    { name: 'Untitled 2', where: '/v' },
    { name: 'Ledger', where: '/v' }
  ];
  assert.deepStrictEqual(api.rankCanvases(files).map(f => f.name),
    ['Roadmap', 'Ledger', 'Untitled', 'Untitled 2']);
});
t('filtering matches the name or the location', () => {
  const files = [
    { name: 'Roadmap', where: '~/Documents/Obsidian/MYTHOS Context' },
    { name: 'Ledger', where: '~/Documents/Obsidian/SovereignOS' }
  ];
  assert.deepStrictEqual(api.filterCanvases(files, 'road').map(f => f.name), ['Roadmap']);
  assert.deepStrictEqual(api.filterCanvases(files, 'sovereign').map(f => f.name), ['Ledger']);
  assert.strictEqual(api.filterCanvases(files, '').length, 2);
  assert.strictEqual(api.filterCanvases(files, 'nothing').length, 0);
});
t('grouping keeps vault order and puts named files first inside a vault', () => {
  const files = [
    { name: 'Untitled', where: '~/Documents/Obsidian/MYTHOS Context' },
    { name: 'Ledger', where: '~/Documents/Obsidian/SovereignOS' },
    { name: 'Roadmap', where: '~/Documents/Obsidian/MYTHOS Context' }
  ];
  const groups = api.groupCanvases(files, '');
  assert.deepStrictEqual(groups.map(g => g.vault), ['MYTHOS Context', 'SovereignOS']);
  assert.deepStrictEqual(groups[0].files.map(f => f.name), ['Roadmap', 'Untitled']);
});
t('grouping survives a list with nothing in it', () => {
  assert.deepStrictEqual(api.groupCanvases([], ''), []);
  assert.deepStrictEqual(api.groupCanvases(null, 'x'), []);
});


console.log('\npass ' + pass + ' / fail ' + fail);
process.exit(fail ? 1 : 0);
