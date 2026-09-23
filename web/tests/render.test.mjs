// Server-side renders of the NUI (Editor for every mode, Panel, CharacterCard) from payloads the Lua
// tree builder produced (fixtures/payloads.json: client/editor/*.lua with the test catalogue).
// The components are bundled with esbuild (web/node_modules) and rendered with react-dom/server.
// Run: node --test web/tests/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..');
const require = createRequire(join(web, 'package.json'));
const esbuild = require('esbuild');
const payloads = JSON.parse(readFileSync(join(here, 'fixtures', 'payloads.json'), 'utf8'));

const out = mkdtempSync(join(tmpdir(), 'wc-nui-'));
const bundle = join(out, 'entry.cjs');
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react';
      import { renderToStaticMarkup } from 'react-dom/server';
      import Editor, { editorMemory } from './src/Editor.jsx';
      import Panel, { panelMemory } from './src/Panel.jsx';
      import CharacterCard from './src/CharacterCard.jsx';
      import { GroupBody, MenuRow } from './src/TreeView.jsx';
      import { remember } from './src/treeState.js';
      export { GroupBody, MenuRow };
      export function editor(payload, path, extra) {
        if (path || extra) remember(editorMemory, payload.session.id, { path: path || [], ...(extra || {}) });
        return renderToStaticMarkup(React.createElement(Editor, { payload, onPayload() {}, onClose() {} }));
      }
      export function panel(payload, path) {
        if (path) remember(panelMemory, payload.session.id, { path });
        return renderToStaticMarkup(React.createElement(Panel, { payload, onPayload() {}, onClose() {} }));
      }
      export function card(data) {
        return renderToStaticMarkup(React.createElement(CharacterCard, { data, strings: data.strings || {} }));
      }`,
    resolveDir: web, loader: 'jsx',
  },
  bundle: true, platform: 'node', format: 'cjs', outfile: bundle, jsx: 'transform', logLevel: 'silent',
  loader: { '.js': 'jsx' }, define: { 'process.env.NODE_ENV': '"production"' },
});
const R = require(bundle);
test.after(() => rmSync(out, { recursive: true, force: true }));

let fresh = 1000;
// A copy with a new session id so every render starts from its own memory entry.
const copy = p => { const c = JSON.parse(JSON.stringify(p)); c.session.id = ++fresh; return c; };
const count = (html, needle) => html.split(needle).length - 1;
const decode = s => s.replace(/&amp;/g, '&').replace(/&#x27;/g, "'").replace(/&quot;/g, '"');
const h2 = html => decode((html.match(/<h2>(.*?)<\/h2>/) || [])[1] || '');

// Every navigable path of a tree: [[id], [id, id], ...]
function paths(node, prefix = []) {
  const out = [];
  for (const c of node.children || []) {
    if (['group', 'identity', 'review'].includes(c.kind)) {
      out.push([...prefix, c.id]);
      if (c.kind === 'group') out.push(...paths(c, [...prefix, c.id]));
    }
  }
  return out;
}
const find = (node, id) => node.id === id ? node : (node.children || []).map(c => find(c, id)).find(Boolean);

for (const mode of ['creatorMale', 'creatorFemale', 'surgery', 'surgeryHair', 'barber', 'store', 'wardrobe']) {
  test(`${mode}: root renders the atelier chrome from payload strings`, () => {
    const p = copy(payloads[mode]);
    const html = R.editor(p);
    assert.match(html, /class="wst-panel atelier"/);
    assert.ok(html.includes(`<h1>${p.session.title}</h1>`));
    // the wordmark is the fixed Latin brand mark in both languages, never a translated string
    assert.ok(html.includes('WRAITH · CHARACTER STUDIO'));
    assert.ok(!html.includes('رايث'));
    const rows = p.tree.children.filter(c => ['group', 'identity', 'review', 'action'].includes(c.kind)).length + (p.canRandom ? 1 : 0);
    assert.equal(count(html, 'class="wst-card menu-row"'), rows);
    if (p.stages) assert.equal(count(html, 'wst-tab'), p.stages.length);
    else assert.equal(count(html, 'atelier-sections'), 0);
    assert.ok(html.includes(p.saveLabel));
    assert.equal(count(html, 'modal-shade'), 0);
  });

  test(`${mode}: every branch renders with a Parent › Child heading`, () => {
    const p = payloads[mode];
    for (const path of paths(p.tree)) {
      const html = R.editor(copy(p), path);
      const nodes = path.map(id => find(p.tree, id));
      const expected = nodes.length === 1 ? nodes[0].label : `${nodes.at(-2).label} › ${nodes.at(-1).label}`;
      assert.equal(h2(html), expected, path.join('/'));
      assert.match(html, /menu-back/, path.join('/'));
    }
  });
}

test('creator: stages, identity form, pads and advanced sliders', () => {
  const p = payloads.creatorMale;
  assert.deepEqual(p.stages.map(s => s.id), ['identity', 'body', 'face', 'skin', 'hair', 'facialHair', 'makeup', 'clothing', 'review']);
  assert.ok(!payloads.creatorFemale.stages.some(s => s.id === 'facialHair'));
  const id = R.editor(copy(p), ['identity']);
  assert.match(id, /type="date"/);
  assert.match(id, /value="John"/);
  assert.match(id, /class="wst-tab selected"/);
  const nose = R.editor(copy(p), ['face', 'face.nose']);
  assert.equal(count(nose, 'class="feature-pad"'), 3);
  // pads pair fields of the same node (jaw depth/offset), only fine-tune leftovers are extras
  const jaw = R.editor(copy(p), ['face', 'face.jaw']);
  assert.equal(count(jaw, 'class="feature-pad"'), 2);
  assert.doesNotMatch(jaw, /class="feature-extra"/);
  const chin = R.editor(copy(p), ['face', 'face.chin']);
  assert.equal(count(chin, 'class="feature-pad"'), 1);
  assert.match(chin, /class="feature-extra"/);
  const build = R.editor(copy(p), ['body', 'body.build']);
  assert.match(build, /class="component"/);
  assert.match(build, /class="slider-field"/);
  assert.match(build, /class="choice"/);
  const review = R.editor(copy(p), ['review']);
  assert.match(review, /wst-plate growth/);
  // the identity dot marks a missing name on the tab
  assert.match(R.editor(copy(p)), /<i><\/i>/);
});

test('store: search box, badges/price in the value slot and the item card', () => {
  const p = payloads.store;
  const root = R.editor(copy(p));
  assert.match(root, /search-plate/);
  const hats = R.editor(copy(p), ['tax.head']);
  assert.match(hats, /<span class="row-value">\$3\.50<\/span>/);
  const item = R.editor(copy(p), ['tax.head', 'item.hats']);
  assert.match(item, /item-card/);
  assert.ok(item.includes(p.strings.price));
  assert.ok(root.includes('dir="ltr">$3.50</span>'));
});

test('wardrobe: outfit actions and text node', () => {
  const p = payloads.wardrobe;
  const outfit = R.editor(copy(p), ['outfits', 'outfit.7']);
  assert.equal(count(outfit, 'class="wst-card menu-row"'), 3);
  assert.match(outfit, /class="identity"/);
  // the new outfit: one name field whose own button is Save (round 2): no separate Save row that
  // stays disabled while a typed name is on screen, no 'type the name first' help line
  const fresh = R.editor(copy(p), ['outfits', 'outfit.new']);
  assert.equal(count(fresh, 'class="wst-card menu-row"'), 0);
  assert.equal(count(fresh, '<input class="wst-input"'), 1);
  const node = p.tree.children.find(n => n.id === 'outfits').children.find(n => n.id === 'outfit.new').children[0];
  assert.equal(node.control, 'outfit.new.name');
  assert.ok(fresh.includes(`>${node.actionLabel}</button>`));
  assert.doesNotMatch(fresh, /menu-help/);
  assert.match(fresh, /<button type="button" class="wst-button" disabled="">/); // nothing typed yet
});

test('barber: growth info plate', () => {
  const html = R.editor(copy(payloads.barber));
  assert.match(html, /wst-plate growth/);
});

test('no hardcoded copy: an empty strings table renders no English fallback', () => {
  const p = copy(payloads.store);
  p.strings = {};
  const html = R.editor(p, ['tax.head', 'item.hats']);
  for (const word of ['Back', 'Undo', 'Search', 'Restore', 'Purchase', 'Owned', 'Price', 'None', 'Camera', 'Applying']) {
    assert.ok(!html.includes(`>${word}`), word);
  }
});

test('panel: tree, heading and Close button', () => {
  const p = payloads.panel;
  const html = R.panel(copy(p));
  assert.match(html, /class="wst-panel atelier"/);
  assert.ok(html.includes(p.strings.close));
  assert.ok(html.includes('WRAITH · CHARACTER STUDIO'));
  assert.equal(count(html, 'scene-touch'), 0);
  const first = p.tree.children[0];
  const inner = R.panel(copy(p), [first.id, first.children[0].id]);
  assert.equal(h2(inner), `${first.label} › ${first.children[0].label}`);
  assert.ok(count(inner, 'class="wst-card menu-row"') >= 1);
});

test('character card: identity rows in the chip style', () => {
  const c = payloads.charCard;
  const html = R.card(c);
  for (const key of ['name', 'age', 'dob', 'gender', 'lastLocation', 'job', 'cash', 'bank', 'gold']) {
    assert.match(html, new RegExp(`cc-row ${key}"`), key);
  }
  const bare = R.card({ ...c, age: null, dob: '', gender: undefined, lastLocation: null });
  assert.equal(count(bare, 'cc-chip'), 5);
});

test('shipped sources have no console output', () => {
  const src = join(web, 'src');
  for (const f of readdirSync(src)) {
    if (!/\.(jsx?|ts)$/.test(f)) continue;
    assert.ok(!/console\.(log|debug|info)/.test(readFileSync(join(src, f), 'utf8')), f);
  }
});

// The MenuRow elements of a rendered GroupBody (walks the element tree, no DOM needed).
function menuRows(el, out = []) {
  if (Array.isArray(el)) { el.forEach(e => menuRows(e, out)); return out; }
  if (!el || typeof el !== 'object') return out;
  if (el.type === R.MenuRow) out.push(el);
  menuRows(el.props?.children, out);
  return out;
}

test('store: searching from the root finds a subcategory under the taxonomy groups', () => {
  const p = payloads.store;
  const hats = find(p.tree, 'item.hats');
  const html = R.editor(copy(p), [], { search: hats.label });
  assert.ok(!html.includes('empty-search'));
  assert.ok(decode(html).includes(`${find(p.tree, 'tax.head').label} › ${hats.label}`));
  assert.match(html, /data-navkey="item.hats"/);
  // the creator clothing stage searches its subcategories too
  const c = payloads.creatorMale;
  const stage = find(c.tree, 'clothing');
  const sub = stage.children.flatMap(g => g.children || []).find(n => n.kind === 'group');
  const staged = R.editor(copy(c), ['clothing'], { search: sub.label });
  assert.match(staged, new RegExp(`data-navkey="${sub.id.replace('.', '\\.')}"`));
  // nothing matching -> the empty state
  assert.match(R.editor(copy(p), [], { search: 'zzzz-no-such-item' }), /empty-search/);
});

test('wardrobe: deleting an outfit asks for confirmation first', () => {
  const p = payloads.wardrobe;
  const outfit = find(p.tree, 'outfit.7');
  const del = find(outfit, 'outfit.7.delete');
  assert.equal(del.danger, true);
  assert.ok(del.confirmBody);
  const calls = [];
  const handlers = { open() {}, set() {}, setMany() {}, invoke: c => calls.push(['invoke', c]), confirm: n => calls.push(['confirm', n.control]) };
  const rows = menuRows(R.GroupBody({ nodes: outfit.children, strings: p.strings, disabled: false, handlers }));
  const row = rows.find(r => r.props.id === 'outfit.7.delete');
  row.props.onClick();
  assert.deepEqual(calls, [['confirm', 'outfit.7.delete']]);
  rows.find(r => r.props.id === 'outfit.7.update').props.onClick();
  assert.deepEqual(calls.at(-1), ['invoke', 'outfit.7.update']);
});

test('surgery: sections beyond body/face/skin (hair, facial hair) get their stages', () => {
  const p = payloads.surgeryHair;
  assert.deepEqual(p.stages.map(s => s.id), ['hair', 'facialHair', 'review']);
  const html = R.editor(copy(p), ['hair']);
  assert.match(html, /class="choice"/);
});

// ---- review round 1 (nui) ----

test('body: chest/arms and waist/hip are visible pads, only shoulder blades is an extra', () => {
  const p = payloads.creatorMale;
  const upper = R.editor(copy(p), ['body', 'body.upper']);
  assert.equal(count(upper, 'class="feature-pad"'), 2);
  const extra = upper.slice(upper.indexOf('class="feature-extra"'));
  assert.equal(count(extra, 'class="slider-field"'), 1);
  const torso = R.editor(copy(p), ['body', 'body.torso']);
  assert.equal(count(torso, 'class="feature-pad"'), 1);
  assert.doesNotMatch(torso, /class="feature-extra"/);
});

test('store: a category with nothing worn shows its price before any try-on', () => {
  const p = payloads.store;
  const head = R.editor(copy(p), ['tax.head']);
  const masks = find(p.tree, 'item.masks');
  assert.ok(masks.summary && /^\$\d+\.\d\d$/.test(masks.summary));
  assert.ok(head.includes(`<span class="row-value">${masks.summary}</span>`));
});

test('wardrobe: clothing actions are group › worn item › action', () => {
  const p = payloads.wardrobe;
  const upper = find(p.tree, 'states.upper');
  assert.ok(upper);
  for (const item of upper.children) {
    assert.equal(item.kind, 'group');
    assert.equal(item.summary, undefined);
    for (const a of item.children) assert.equal(a.kind, 'action');
  }
  const shirt = R.editor(copy(p), ['actions', 'states.upper', 'states.upper.shirts_full']);
  assert.ok(shirt.includes('state.sleeves.rolled'));
});
