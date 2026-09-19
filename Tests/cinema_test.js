/* Checks for Sources/AtlasCore/Resources/cinema.html.
   Run:  node Tests/cinema_test.js
   Pulls the logic out of the page so this tests what actually ships. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'cinema.html'), 'utf8');
const inline = html.match(/<script>\n'use strict';([\s\S]*?)<\/script>/);
if (!inline) throw new Error('inline script block not found in cinema.html');
const script = inline[1];

function slice(from, to) {
  const start = script.indexOf(from);
  const end = script.indexOf(to);
  if (start < 0 || end < 0) throw new Error(`logic markers not found: ${from}`);
  return script.slice(start, end);
}

// The source list ships with the page, so the test picks it up rather than
// restating it — a source added or removed there is covered here for free.
const sources = slice('const SOURCES = [', '/* Each tab is');
const helpers = slice('function escapeHtml(value)', 'const LIBRARY_KEY');
const libraryLogic = slice('const LIBRARY_KEY', 'async function tmdb');
const memory = slice('let sourceMemory = readSourceMemory();', 'function renderSources()');

/* The page reads and writes through `cinemaStore`, which is the bridge-backed
   store, not `localStorage` — WebKit partitions localStorage by bundle id, so
   page state was moved off it. Both names are injected and share one object:
   the shape is identical and some helpers still take the localStorage seam. */
function makeStorage(initial) {
  const data = Object.assign({}, initial);
  return {
    getItem: key => (key in data ? data[key] : null),
    setItem: (key, value) => { data[key] = String(value); },
    removeItem: key => { delete data[key]; },
    _data: data
  };
}

function build(stored, currentSource) {
  const factory = new Function('localStorage', 'cinemaStore', 'currentSource',
    sources + helpers + memory +
    ';return { escapeHtml, titleOf, yearOf, isSeries, pickSource, memoryFor, memoryKey, saveMemory, SOURCES };');
  const storage = makeStorage(stored);
  return factory(storage, storage, currentSource || 'archive');
}

function buildLibrary(stored) {
  const storage = makeStorage(stored);
  const factory = new Function('localStorage', 'cinemaStore',
    helpers + libraryLogic +
    ';return { itemKey, readLibrary, saveLibrary, inCollection, toggleCollection, createPlaylist, inPlaylist, togglePlaylist, reorderCollection, personalHeroItems, personalRails, getLibrary: () => library };');
  return { ...factory(storage, storage), storage };
}

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); pass++; console.log('  ok   ' + name); }
  catch (err) { fail++; console.log('  FAIL ' + name + '\n       ' + err.message); }
};

const FILM = { id: 1175942, title: 'Spider-Man: Brand New Day', release_date: '2026-07-31' };
const SHOW = { id: 1175942, name: 'Silo', first_air_date: '2023-05-05' };

// --- media kind ---
t('a series is told from a film by the field only a series carries', () => {
  assert.strictEqual(build({}).isSeries(SHOW), true);
  assert.strictEqual(build({}).isSeries(FILM), false);
  // /trending stamps media_type; the per-kind endpoints do not.
  assert.strictEqual(build({}).isSeries({ id: 1, media_type: 'tv' }), true);
});

// --- memory keys ---
t('a film and a series with the same id do not share a memory slot', () => {
  const api = build({});
  assert.notStrictEqual(api.memoryKey(FILM), api.memoryKey(SHOW));
});

// --- picking ---
t('a source that worked for this title wins over the global default', () => {
  const api = build({
    atlas_cinema_sources: JSON.stringify({ 'movie:1175942': { good: 'jellyfin', bad: [] } })
  }, 'archive');
  assert.strictEqual(api.pickSource(FILM), 'jellyfin');
});

t('the global default is used when the title has no history', () => {
  assert.strictEqual(build({}, 'jellyfin').pickSource(FILM), 'jellyfin');
});

t('a source marked broken for this title is skipped', () => {
  const api = build({
    atlas_cinema_sources: JSON.stringify({ 'movie:1175942': { good: null, bad: ['archive'] } })
  }, 'archive');
  assert.notStrictEqual(api.pickSource(FILM), 'archive');
});

t('the first source still alive is chosen when several are broken', () => {
  // Derived from the shipped list rather than named: these hosts lose their
  // domains regularly, and a test that hardcodes ids fails on the cleanup
  // rather than on a real regression.
  const ids = build({}).SOURCES.map(s => s.id);
  const dead = ids.slice(0, ids.length - 1);
  const api = build({
    atlas_cinema_sources: JSON.stringify({ 'movie:1175942': { good: null, bad: dead } })
  }, dead[0]);
  assert.strictEqual(api.pickSource(FILM), ids[ids.length - 1]);
});

t('picking still returns a source when every one is marked broken', () => {
  const api = build({
    atlas_cinema_sources: JSON.stringify({
      'movie:1175942': { good: null, bad: build({}).SOURCES.map(s => s.id) }
    })
  }, 'archive');
  // Nothing is playable, but the player must not be handed undefined.
  assert.ok(build({}).SOURCES.some(s => s.id === api.pickSource(FILM)));
});

// --- persistence ---
t('marking a source merges into the title rather than replacing it', () => {
  const api = build({
    atlas_cinema_sources: JSON.stringify({ 'movie:1175942': { good: null, bad: ['archive'] } })
  });
  api.saveMemory(FILM, { good: 'jellyfin' });
  const after = api.memoryFor(FILM);
  assert.strictEqual(after.good, 'jellyfin');
  assert.deepStrictEqual(after.bad, ['archive']);
});

t('unreadable stored memory does not take the page down', () => {
  assert.deepStrictEqual(build({ atlas_cinema_sources: 'not json' }).memoryFor(FILM), { good: null, bad: [] });
});

// --- injection: titles and synopses come from a third-party API ---
t('titles are escaped', () => {
  assert.ok(!build({}).escapeHtml('<script>x</script>').includes('<script'));
  assert.ok(!build({}).escapeHtml('" onerror="alert(1)').includes('"'));
});

t('a missing release date does not become a broken year', () => {
  assert.strictEqual(build({}).yearOf({ id: 1, title: 'Untitled' }), '');
});

// --- personal library ---
t('the old watchlist migrates into Watch Later exactly once', () => {
  const api = buildLibrary({ atlas_watchlist: JSON.stringify([FILM]) });
  assert.deepStrictEqual(api.getLibrary().watchLater, [FILM]);
  assert.ok(api.storage._data.atlas_cinema_library_v1);
  assert.ok(!('atlas_watchlist' in api.storage._data));
});

t('Favorites and Watch Later are independent collections', () => {
  const api = buildLibrary({});
  assert.strictEqual(api.toggleCollection('favorites', FILM), true);
  assert.strictEqual(api.inCollection('favorites', FILM), true);
  assert.strictEqual(api.inCollection('watchLater', FILM), false);
  assert.strictEqual(api.toggleCollection('favorites', FILM), false);
  assert.strictEqual(api.inCollection('favorites', FILM), false);
});

t('movie and series ids cannot collide in a collection', () => {
  const api = buildLibrary({});
  api.toggleCollection('favorites', FILM);
  api.toggleCollection('favorites', SHOW);
  assert.strictEqual(api.getLibrary().favorites.length, 2);
});

t('library changes survive a fresh page load', () => {
  const first = buildLibrary({});
  first.toggleCollection('watchLater', FILM);
  const second = buildLibrary(first.storage._data);
  assert.strictEqual(second.inCollection('watchLater', FILM), true);
});

t('a custom playlist can be created and toggled', () => {
  const api = buildLibrary({});
  const list = api.createPlaylist('Date Night');
  assert.ok(list);
  assert.strictEqual(api.togglePlaylist(list.id, FILM), true);
  assert.strictEqual(api.inPlaylist(api.getLibrary().playlists[0], FILM), true);
  assert.strictEqual(api.togglePlaylist(list.id, FILM), false);
  assert.strictEqual(api.inPlaylist(api.getLibrary().playlists[0], FILM), false);
});

t('playlist names are trimmed and deduplicated', () => {
  const api = buildLibrary({});
  const first = api.createPlaylist('  Mind-Benders  ');
  const second = api.createPlaylist('mind-benders');
  assert.strictEqual(first.id, second.id);
  assert.strictEqual(api.getLibrary().playlists.length, 1);
  assert.strictEqual(first.name, 'Mind-Benders');
});

t('unreadable library data falls back safely', () => {
  const api = buildLibrary({ atlas_cinema_library_v1: 'not json' });
  assert.deepStrictEqual(api.getLibrary(), { version: 1, favorites: [], watchLater: [], playlists: [] });
});

t('Favorites provide the personal hero in saved order', () => {
  const first = { ...FILM, backdrop_path: '/first.jpg' };
  const second = { id: 2, title: 'Second', poster_path: '/second.jpg' };
  const noArt = { id: 3, title: 'No Artwork' };
  const stored = { version: 1, favorites: [first, second, noArt], watchLater: [], playlists: [] };
  const api = buildLibrary({ atlas_cinema_library_v1: JSON.stringify(stored) });
  assert.deepStrictEqual(api.personalHeroItems(), [first, second]);
});

t('Gold Medals is the first personal playlist rail', () => {
  const title = { ...FILM, poster_path: '/poster.jpg' };
  const stored = {
    version: 1,
    favorites: [],
    watchLater: [],
    playlists: [
      { id: 'later', name: 'Sunday Shows', items: [title] },
      { id: 'gold', name: 'Gold Medals', items: [title] },
      { id: 'empty', name: 'Empty', items: [] }
    ]
  };
  const api = buildLibrary({ atlas_cinema_library_v1: JSON.stringify(stored) });
  assert.deepStrictEqual(api.personalRails().map(rail => rail.title), ['Gold Medals', 'Sunday Shows']);
});

t('reordering Favorites persists the Home hero order', () => {
  const first = { ...FILM, backdrop_path: '/first.jpg' };
  const second = { id: 2, title: 'Second', poster_path: '/second.jpg' };
  const third = { id: 3, title: 'Third', poster_path: '/third.jpg' };
  const stored = { version: 1, favorites: [first, second, third], watchLater: [], playlists: [] };
  const api = buildLibrary({ atlas_cinema_library_v1: JSON.stringify(stored) });
  assert.strictEqual(api.reorderCollection('favorites', api.itemKey(third), api.itemKey(first), false), true);
  assert.deepStrictEqual(api.personalHeroItems().map(item => item.title), ['Third', FILM.title, 'Second']);
  const reloaded = buildLibrary(api.storage._data);
  assert.deepStrictEqual(reloaded.personalHeroItems().map(item => item.title), ['Third', FILM.title, 'Second']);
});

t('the selected-title experience ships Details, Extras, Cast, Related, and episode metadata', () => {
  assert.ok(html.includes('Trailers &amp; Extras') || html.includes('Trailers & Extras'));
  assert.ok(script.includes('function renderExtras(videos)'));
  assert.ok(script.includes('function renderCast(credits)'));
  assert.ok(script.includes('function renderRelated(data)'));
  assert.ok(script.includes("append_to_response: 'combined_credits'"));
  assert.ok(script.includes('https://www.youtube.com/watch?v='));
  assert.ok(script.includes("ep.runtime ? ep.runtime + ' min'"));
});

console.log('\npass ' + pass + ' / fail ' + fail);
process.exit(fail ? 1 : 0);
