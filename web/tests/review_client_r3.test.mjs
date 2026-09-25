// Review round 3, NUI: regressions of the confirmed client findings.
//  * Escape / Back with an active search clears the search first (one navigation level), and Back
//    from a row opened through a search result returns to that result list
//  * a refused slider change does not keep showing the refused value (the draft resyncs when the
//    request settles)
//  * the creator's Review plate shows the identity typed in the Identity stage
// Run: node --test web/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { backAction, openPath, popTarget, reviewItems, searchOrigin } from '../src/treeState.js';

const here = dirname(fileURLToPath(import.meta.url));
const src = name => readFileSync(join(here, '..', 'src', name), 'utf8');

test('Escape with a search clears the search instead of closing or popping', () => {
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: false, search: 'hat' }), 'clearSearch');
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: true, search: 'hat' }), 'clearSearch');
  assert.equal(backAction({ confirm: null, pathLength: 2, dirty: false, search: 'hat' }), 'clearSearch');
  // whitespace only is no search
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: false, search: '  ' }), 'close');
  // an open modal is still dismissed first
  assert.equal(backAction({ confirm: 'save', pathLength: 0, dirty: false, search: 'hat' }), 'dismiss');
  // unchanged without a search
  assert.equal(backAction({ confirm: null, pathLength: 1, dirty: false, search: '' }), 'pop');
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: true }), 'confirmLeave');
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: false }), 'close');
});

test('Back from a search result returns to the result list', () => {
  const result = { id: 'hats', via: ['tax.head'] };
  const next = openPath([], result);
  assert.deepEqual(next, ['tax.head', 'hats']);
  const origin = searchOrigin([], next, 'hat');
  assert.deepEqual(popTarget(next, origin), { path: [], search: 'hat' });
  // one level deeper than the opened row: the normal pop (the origin is only for the row itself)
  assert.deepEqual(popTarget([...next, 'x'], origin), { path: next, search: '' });
  // a row opened without a search has no origin
  assert.equal(searchOrigin(['tax.head'], ['tax.head', 'hats'], ''), null);
  assert.deepEqual(popTarget(['tax.head', 'hats'], null), { path: ['tax.head'], search: '' });
});

test('the editor wires the search level into Back / Escape', () => {
  const editor = src('Editor.jsx');
  // direct: the creator's root Back ("change the sex") keeps the look, so it never asks
  assert.match(editor, /backAction\(\{confirm, pathLength: validPath\.length, dirty, search(, direct: !!payload\.backDirect)?\}\)/);
  assert.match(editor, /next === 'clearSearch'\) setSearch\(''\)/);
  assert.match(editor, /popTarget\(validPath, origin\)/);
  assert.match(editor, /setOrigin\(searchOrigin\(validPath, next, search\)\)/);
});

test('the slider draft resyncs when a request settles (a refused set shows the kept value)', () => {
  const tree = src('TreeView.jsx');
  const slider = tree.slice(tree.indexOf('export function Slider'), tree.indexOf('export function MenuRow'));
  assert.match(slider, /useEffect\(\(\)=>\{if\(!off\)setDraft\(value\);\},\[value,off\]\)/);
  assert.doesNotMatch(slider, /useEffect\(\(\)=>setDraft\(value\),\[value\]\)/);
});

test('the creator review lists the typed identity first', () => {
  const node = { id: 'review', kind: 'review', items: [{ label: 'Sex', value: 'Male' }] };
  const identity = { fields: [
    { key: 'firstname', label: 'First name', type: 'text' },
    { key: 'lastname', label: 'Last name', type: 'text' },
    { key: 'dob', label: 'Date of birth', type: 'date' },
  ] };
  const items = reviewItems(node, identity, { firstname: ' Arthur ', lastname: 'Morgan', dob: '1863-01-01' });
  assert.deepEqual(items, [
    { label: 'First name', value: 'Arthur' },
    { label: 'Last name', value: 'Morgan' },
    { label: 'Date of birth', value: '1863-01-01' },
    { label: 'Sex', value: 'Male' },
  ]);
  // an info field (the repair creator's kept identity) shows its value; nothing typed yet shows empty
  const info = reviewItems(node, { fields: [{ key: 'firstname', label: 'First name', type: 'info', value: 'John' },
    { key: 'lastname', label: 'Last name' }] }, {});
  assert.deepEqual(info.slice(0, 2), [{ label: 'First name', value: 'John' }, { label: 'Last name', value: '' }]);
  // other modes (no identity): the node's rows unchanged
  assert.deepEqual(reviewItems(node, null, {}), node.items);
  assert.match(src('TreeView.jsx'), /items=\{reviewItems\(node,identity,identityForm\)\}/);
});
