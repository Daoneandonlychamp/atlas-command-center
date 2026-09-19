/* Renderer checks for Sources/AtlasCore/Resources/chat.html.
   Run:  node Tests/chat_render_test.js
   Extracts the markdown renderer straight out of chat.html, so this always
   tests the code that actually ships rather than a drifting copy. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'chat.html'), 'utf8');
// The renderer is shared with the canvas page, so it is tested where it lives.
const script = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'AtlasCore', 'Resources', 'markdown.js'), 'utf8');
// The file wraps itself in an IIFE and publishes onto window; give it one.
const shim = { };
(new Function('window', script))(shim);
const { renderMarkdown } = shim.atlasMarkdown;

let pass = 0, fail = 0;
const t = (name, md, check) => {
  let out;
  try { out = renderMarkdown(md); }
  catch (e) { console.log('FAIL(threw) ' + name + ': ' + e.message); fail++; return; }
  try { check(out); pass++; }
  catch (e) { console.log('FAIL ' + name + '\n  got: ' + out + '\n  ' + e.message); fail++; }
};
const has = (s, sub) => assert.ok(s.includes(sub), 'expected to contain: ' + sub);
const not = (s, sub) => assert.ok(!s.includes(sub), 'expected NOT to contain: ' + sub);

// --- bugs this renderer was written to fix ---
t('link with underscore keeps href intact', '[docs](https://example.com/a_b/c_d)', o => {
  // The bug this guards: the underscore-emphasis pass used to run over already
  // generated tags and rewrite the href. No target= here on purpose — in a web
  // view, Swift intercepts navigation and opens links in the real browser.
  has(o, 'href="https://example.com/a_b/c_d"'); not(o, '<em>');
});
t('link plus other underscores on same line', 'see _emph_ and [docs](https://e.com/a_b)', o => {
  has(o, 'href="https://e.com/a_b"'); has(o, '<em>emph</em>');
});
t('snake_case untouched', 'snake_case_name stays', o => { not(o, '<em>'); has(o, 'snake_case_name'); });
t('h5 and h6', '##### Five\n\n###### Six', o => { has(o, '<h5>Five</h5>'); has(o, '<h6>Six</h6>'); });
t('ordered list keeps start number', '3. three\n4. four', o => has(o, '<ol start="3">'));
t('nested list actually nests', '- outer\n  - inner\n- back', o =>
  has(o, '<ul><li>outer</li><ul><li>inner</li></ul><li>back</li></ul>'));
t('table renders', '| A | B |\n|---|---|\n| 1 | 2 |', o => {
  has(o, '<table>'); has(o, '<th>A</th>'); has(o, '<td>1</td>'); not(o, '<p>|');
});
t('table alignment', '| A | B |\n|:--|--:|\n| 1 | 2 |', o => has(o, 'text-align:right'));

// --- injection safety: model output is never trusted as HTML ---
t('script tag escaped', '<script>alert(1)</script>', o => { not(o, '<script'); has(o, '&lt;script&gt;'); });
t('img onerror escaped', '<img src=x onerror=alert(1)>', o => { not(o, '<img'); has(o, '&lt;img'); });
t('javascript: link rejected', '[x](javascript:alert(1))', o => { not(o, '<a '); not(o, 'href='); });
t('data: link rejected', '[x](data:text/html,<script>alert(1)</script>)', o => not(o, '<a href="data:'));
t('html inside inline code escaped', 'use `<b>x</b>` here', o => { has(o, '&lt;b&gt;'); not(o, '<b>x</b>'); });
t('html inside fence escaped', '```\n<script>alert(1)</script>\n```', o => { not(o, '<script'); has(o, '&lt;script&gt;'); });
t('attribute breakout blocked', '[x](https://e.com/") onmouseover="alert(1))', o => not(o, 'onmouseover="alert'));
t('code label escaped', '```<img src=x>\nbody\n```', o => not(o, '<img src=x>'));
t('table cell escapes html', '| A |\n|---|\n| <script>x</script> |', o => { not(o, '<script'); has(o, '&lt;script&gt;'); });

// --- behaviour that must keep working ---
t('bold and italic', '**b** and *i*', o => { has(o, '<strong>b</strong>'); has(o, '<em>i</em>'); });
t('fence with language label', '```python\nprint(1)\n```', o => { has(o, 'code-label">python'); has(o, 'print(1)'); });
t('blockquote', '> one\n> two', o => has(o, '<blockquote>'));
t('horizontal rule', 'a\n\n---\n\nb', o => has(o, '<hr>'));
t('unterminated fence does not hang', '```js\nlet a=1;', o => has(o, '<pre>'));
t('empty input', '', o => assert.strictEqual(o, ''));
t('plain paragraph', 'hello world', o => has(o, '<p>hello world</p>'));

// --- shapes these models actually emit ---
t('heading then bullets with bold labels', '### 1. Buy the parts\n\n- **Frame**: 5-inch carbon fiber\n- **Motors**: 4 x 2207', o => {
  has(o, '<h3>1. Buy the parts</h3>');
  has(o, '<li><strong>Frame</strong>: 5-inch carbon fiber</li>');
  not(o, '###'); not(o, '**');
});
t('numbered steps after a heading', '### 3. Assemble\n\n1. Mount the motors.\n2. Mount the stack.', o => {
  has(o, '<ol'); has(o, '<li>Mount the motors.</li>');
});
t('bold inside a numbered item', '1. Install **Betaflight Configurator**.', o =>
  has(o, '<li>Install <strong>Betaflight Configurator</strong>.</li>'));
t('paragraph after a heading is not swallowed', '### Simplest route\n\nIf this is your first build, buy a **kit**.', o => {
  has(o, '<h3>Simplest route</h3>'); has(o, '<strong>kit</strong>');
});

// --- the streaming bug this file exists to stop coming back ---
// update() used to compare className to 'md'. The streaming cursor appends a
// second class, so after the first token the comparison failed and raw markdown
// was written into the transcript with textContent for the rest of the reply.
(() => {
  const name = 'streaming update keeps using the markdown path';
  // Checked against chat.html itself: update() lives there, not in the renderer.
  if (/_body\.className\s*===\s*'md'/.test(html)) {
    console.log('FAIL ' + name + '\n  className equality breaks once the cursor class is added');
    fail++;
  } else if (!html.includes("_body.classList.contains('md')")) {
    console.log('FAIL ' + name + '\n  expected a classList.contains check in update()');
    fail++;
  } else pass++;
})();

console.log('\npass ' + pass + ' / fail ' + fail);
process.exit(fail ? 1 : 0);
