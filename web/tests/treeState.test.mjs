// Unit tests of the pure navigation / request-state helpers (web/src/treeState.js).
// Run: node --test web/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  backAction, cameraFor, childById, confirmRequest, LEAVE_SAVE_NEXT, modalFor, openPath, choiceOptions, createMemory, filterChildren, formatDisplay, formatMoney,
  fromDisplay, headingFor, idleRequest, initialIdentity, isNavigable, isPending, missingIdentity, nextOpId,
  identityDirty, priceLines, popPath, textBlocked, pushPath, recall, remember, requestReducer, resolvePath, rowValue, segments, selectedStage, toDisplay,
} from '../src/treeState.js';

const tree = {
  id: 'root', kind: 'group', label: 'Root', camera: 'fullBody', children: [
    { id: 'face', kind: 'group', label: 'Face', camera: 'face', children: [
      { id: 'face.nose', kind: 'group', label: 'Nose', children: [
        { id: 'morph.noseSize', kind: 'slider', label: 'Size', control: 'morph.noseSize' } ] },
      { id: 'face.head', kind: 'choice', label: 'Head', control: 'face.head', options: [] } ] },
    { id: 'identity', kind: 'identity', label: 'Identity' },
    { id: 'review', kind: 'review', label: 'Review' },
  ],
};

test('resolvePath walks navigable children and truncates stale ids', () => {
  assert.deepEqual(resolvePath(tree, ['face', 'face.nose']).nodes.map(n => n.id), ['root', 'face', 'face.nose']);
  assert.deepEqual(resolvePath(tree, ['face', 'gone', 'x']).path, ['face']);
  assert.deepEqual(resolvePath(tree, ['face', 'face.head']).path, ['face']); // a leaf is not a view
  assert.deepEqual(resolvePath(tree, ['identity']).path, ['identity']);
  assert.deepEqual(resolvePath(null, ['a']).nodes, []);
  assert.equal(childById(tree, 'review').kind, 'review');
});

test('Back returns exactly one level', () => {
  const path = pushPath(pushPath([], 'face'), 'face.nose');
  assert.deepEqual(path, ['face', 'face.nose']);
  assert.deepEqual(popPath(path), ['face']);
  assert.deepEqual(popPath(popPath(path)), []);
  assert.deepEqual(popPath([]), []);
});

test('backAction: modal, pop, dirty confirmation, clean close', () => {
  assert.equal(backAction({ confirm: 'save', pathLength: 2, dirty: true }), 'dismiss');
  assert.equal(backAction({ confirm: null, pathLength: 1, dirty: true }), 'pop');
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: true }), 'confirmLeave');
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty: false }), 'close');
});

test('heading shows Parent › Child', () => {
  assert.equal(headingFor(resolvePath(tree, []).nodes), 'Root');
  assert.equal(headingFor(resolvePath(tree, ['face']).nodes), 'Face');
  assert.equal(headingFor(resolvePath(tree, ['face', 'face.nose']).nodes), 'Face › Nose');
});

test('camera: nearest preset from the deepest node', () => {
  assert.equal(cameraFor(resolvePath(tree, ['face', 'face.nose']).nodes), 'face');
  assert.equal(cameraFor(resolvePath(tree, []).nodes), 'fullBody');
  assert.equal(cameraFor([]), null);
});

test('stage selection follows the first path id', () => {
  const stages = [{ id: 'face' }, { id: 'identity' }];
  assert.equal(selectedStage(['face', 'face.nose'], stages), 'face');
  assert.equal(selectedStage([], stages), null);
  assert.equal(selectedStage(['x'], stages), null);
});

test('search filters only searchable groups', () => {
  const g = { searchable: true, children: [{ label: 'Hats' }, { label: 'Boots' }] };
  assert.deepEqual(filterChildren(g, 'bo').map(c => c.label), ['Boots']);
  assert.equal(filterChildren(g, '').length, 2);
  assert.equal(filterChildren({ children: g.children }, 'bo').length, 2);
});

test('memory keeps state per session id', () => {
  const m = createMemory();
  remember(m, 3, { path: ['face'] });
  remember(m, 3, { search: 'x' });
  assert.deepEqual(recall(m, 3), { path: ['face'], search: 'x' });
  assert.equal(recall(m, 4), null);
  for (let i = 0; i < 30; i++) remember(m, 100 + i, { path: [] });
  assert.ok(m.size <= 20);
});

test('request state machine', () => {
  let s = requestReducer(undefined, { type: 'noop' });
  assert.deepEqual(s, idleRequest);
  s = requestReducer(s, { type: 'start' });
  assert.ok(isPending(s));
  assert.deepEqual(requestReducer(s, { type: 'error', error: 'boom' }), { status: 'error', error: 'boom' });
  assert.deepEqual(requestReducer(s, { type: 'success' }), { status: 'success', error: '' });
  assert.deepEqual(requestReducer(s, { type: 'reset' }), idleRequest);
});

test('display scaling', () => {
  const d = { scale: 100, decimals: 0 };
  assert.equal(toDisplay(0.25, d), 25);
  assert.equal(formatDisplay(-0.004, d), '0');
  assert.equal(formatDisplay(-0.5, d), '-50');
  assert.equal(formatDisplay(1.005, { scale: 100, decimals: 1 }), '100.5');
  assert.equal(fromDisplay('50', d, -1, 1), 0.5);
  assert.equal(fromDisplay('500', d, -1, 1), 1);
  assert.equal(fromDisplay('abc', d), null);
  assert.equal(formatMoney(3.5), '$3.50');
});

test('choice options: explicit with badges, generated range with none', () => {
  const strings = { none: 'None', owned: 'Owned' };
  assert.deepEqual(choiceOptions({ options: [{ value: 1, label: 'A', badge: 'owned' }] }, strings), [{ value: 1, label: 'A · Owned' }]);
  assert.deepEqual(choiceOptions({ options: [{ value: 1, label: 'A', badge: 'owned', badgeLabel: 'Mine' }] }, strings)[0].label, 'A · Mine');
  assert.deepEqual(choiceOptions({ range: { min: 1, max: 3, none: true } }, strings).map(o => o.label), ['None', '01', '02', '03']);
  assert.deepEqual(choiceOptions({ range: { min: 1, max: 2 } }, {}).map(o => o.value), [1, 2]);
  assert.deepEqual(choiceOptions({}, {}), []);
});

test('segments keep order and group pads with advanced sliders', () => {
  const kinds = segments([
    { kind: 'group', id: 'a' }, { kind: 'action', id: 'b' }, { kind: 'choice', id: 'c' }, { kind: 'slider', id: 'd' },
    { kind: 'text', id: 'e' }, { kind: 'info', id: 'f' },
  ]).map(s => s.type);
  assert.deepEqual(kinds, ['rows', 'controls', 'node', 'node']);
  const withPads = segments([{ kind: 'pad', id: 'p' }, { kind: 'slider', id: 's' }, { kind: 'choice', id: 'c' }]);
  assert.deepEqual(withPads.map(s => s.type), ['pads', 'controls', 'extra']);
  assert.equal(withPads[2].nodes[0].id, 's');
});

test('row value prefers badges over summaries', () => {
  assert.equal(rowValue({ badge: 'owned', summary: '$1' }, { owned: 'Owned' }), 'Owned');
  assert.equal(rowValue({ badgeLabel: 'Mine', badge: 'owned' }, { owned: 'Owned' }), 'Mine');
  assert.equal(rowValue({ summary: '$1' }), '$1');
  assert.equal(rowValue({}), null);
});

test('identity form helpers', () => {
  const identity = { fields: [
    { key: 'firstname', type: 'text', value: 'John' }, { key: 'lastname', type: 'text' },
    { key: 'dob', type: 'date' }, { key: 'sex', type: 'info', value: 'Male' } ] };
  const form = initialIdentity(identity);
  assert.deepEqual(form, { firstname: 'John', lastname: '', dob: '' });
  assert.ok(missingIdentity(identity, form));
  assert.ok(!missingIdentity(identity, { firstname: 'John', lastname: 'M', dob: '1880-01-01' }));
  assert.ok(!missingIdentity(null, {}));
});

test('op ids are unique and Lua-safe', () => {
  const a = nextOpId(4), b = nextOpId(4);
  assert.notEqual(a, b);
  assert.match(a, /^[\w\-:.]{1,64}$/);
  assert.ok(isNavigable({ kind: 'review' }) && !isNavigable({ kind: 'choice' }));
});

test('search reaches navigable descendants and opens them through their path', () => {
  const store = { id: 'root', searchable: true, label: 'Clothing', children: [
    { id: 'tax.head', kind: 'group', label: 'Head', children: [
      { id: 'item.hats', kind: 'group', label: 'Hats', children: [
        { id: 'clothing.hats.style', kind: 'choice', label: 'Style', control: 'clothing.hats.style' } ] },
      { id: 'item.masks', kind: 'group', label: 'Masks', children: [] } ] },
    { id: 'tax.feet', kind: 'group', label: 'Feet', children: [
      { id: 'item.boots', kind: 'group', label: 'Boots', children: [] } ] } ] };
  const hits = filterChildren(store, 'hat');
  assert.deepEqual(hits.map(h => h.id), ['item.hats']);
  assert.equal(hits[0].label, 'Head › Hats');
  assert.deepEqual(hits[0].via, ['tax.head']);
  assert.deepEqual(openPath([], hits[0]), ['tax.head', 'item.hats']);
  assert.deepEqual(resolvePath(store, openPath([], hits[0])).path, ['tax.head', 'item.hats']);
  // leaves (controls) deep inside are not offered as rows; a direct child still matches as itself
  assert.deepEqual(filterChildren(store, 'style'), []);
  assert.deepEqual(filterChildren(store, 'feet').map(h => [h.id, h.label]), [['tax.feet', 'Feet']]);
  assert.deepEqual(filterChildren(store, 'BOOTS').map(h => h.id), ['item.boots']);
  assert.deepEqual(openPath(['a'], { id: 'b' }), ['a', 'b']);
});

test('confirmation modals: danger actions, leave, save and reset', () => {
  const S = { reset: 'R', resetBody: 'RB', leaveTitle: 'L', leave: 'LB', dangerBody: 'D' };
  const node = { id: 'outfit.1.delete', control: 'outfit.1.delete', label: 'Delete', danger: true, confirmBody: 'Gone' };
  assert.deepEqual(modalFor({ kind: 'invoke', node, where: 'Work' }, { strings: S }), { title: 'Work › Delete', body: 'Gone' });
  assert.deepEqual(modalFor({ kind: 'invoke', node: { ...node, confirmBody: undefined } }, { strings: S }), { title: 'Delete', body: 'D' });
  assert.deepEqual(confirmRequest({ kind: 'invoke', node }), { op: 'invoke', control: 'outfit.1.delete' });
  assert.deepEqual(modalFor('leave', { strings: S }), { title: 'L', body: 'LB' });
  assert.equal(confirmRequest('leave'), null);
  assert.deepEqual(modalFor('save', { copy: { title: 'T' }, saveBody: 'B — Total · $10.00' }), { title: 'T', body: 'B — Total · $10.00' });
  assert.deepEqual(confirmRequest('save'), { op: 'save' });
  assert.deepEqual(confirmRequest('reset'), { op: 'reset' });
  assert.equal(modalFor(null), null);
  // the leave modal's Save opens the save confirmation (label + total) instead of committing
  assert.equal(LEAVE_SAVE_NEXT, 'save');
  assert.ok(modalFor(LEAVE_SAVE_NEXT, { copy: { title: 'T' }, saveBody: 'x' }));
});

// ---- review round 1 (nui) ----

test('identityDirty: a typed creator identity is unsaved input; a locked or absent one is not', () => {
  const fresh = { fields: [{ key: 'firstname', value: '' }, { key: 'lastname', value: '' }, { key: 'dob', type: 'date', value: '' }] };
  assert.equal(identityDirty(fresh, initialIdentity(fresh)), false);
  assert.equal(identityDirty(fresh, { firstname: 'John', lastname: '', dob: '' }), true);
  assert.equal(identityDirty(fresh, { firstname: 'John', lastname: 'Marston', dob: '1873-01-01' }), true);
  const locked = { locked: true, fields: [{ key: 'firstname', type: 'info', value: 'Arthur' }, { key: 'lastname', type: 'info', value: 'Morgan' }] };
  assert.equal(identityDirty(locked, initialIdentity(locked)), false);
  assert.equal(identityDirty(null, { firstname: 'x' }), false);
  assert.equal(identityDirty(undefined, undefined), false);
  // Back at the root with only a typed name asks before leaving instead of cancelling
  const dirty = false || identityDirty(fresh, { firstname: 'John', lastname: '', dob: '' });
  assert.equal(backAction({ confirm: null, pathLength: 0, dirty }), 'confirmLeave');
});

test('priceLines: the breakdown rows when they add up to the total', () => {
  const store = { total: 6, lines: [{ label: 'Hat', amount: 3.5 }, { label: 'Color · Boots', amount: 2.5 }] };
  assert.deepEqual(priceLines(store), [{ label: 'Hat', value: '$3.50' }, { label: 'Color · Boots', value: '$2.50' }]);
  assert.deepEqual(priceLines({ total: 0.3, lines: [{ label: 'a', amount: 0.1 }, { label: 'b', amount: 0.2 }] }).length, 2);
  // a capped barber visit (lines above the cap) shows the total alone
  assert.deepEqual(priceLines({ total: 10, lines: [{ label: 'Hair', amount: 8 }, { label: 'Beard', amount: 6 }] }), []);
  assert.deepEqual(priceLines({ total: 0, lines: [] }), []);
  assert.deepEqual(priceLines(null), []);
  assert.deepEqual(priceLines({ total: 1, lines: [{ label: 'x', amount: 'NaN' }] }), []);
  // the save modal carries them; without lines the modal shape is unchanged
  const S = {};
  assert.deepEqual(modalFor('save', { strings: S, copy: { title: 'T' }, saveBody: 'B', lines: priceLines(store), total: '$6.00' }),
    { title: 'T', body: 'B', lines: priceLines(store), total: '$6.00' });
  assert.deepEqual(modalFor('save', { copy: { title: 'T' }, saveBody: 'B', lines: [] }), { title: 'T', body: 'B' });
});

test('textBlocked: a required text action needs a non-blank value (the new outfit name)', () => {
  const node = { kind: 'text', control: 'outfit.new.name', required: true };
  assert.equal(textBlocked(node, ''), true);
  assert.equal(textBlocked(node, '   '), true);
  assert.equal(textBlocked(node, 'Work'), false);
  assert.equal(textBlocked({ kind: 'text', control: 'outfit.7.rename' }, ''), false); // not required
  assert.equal(textBlocked(null, ''), false);
});
