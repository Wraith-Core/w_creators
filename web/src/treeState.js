// Pure navigation / request-state helpers of the node-tree UI (ARCHITECTURE.md §8).
// No React and no DOM here: web/tests/treeState.test.mjs exercises every function directly.

// Nodes that open a view of their own (a MenuRow navigates into them).
export const NAVIGABLE = new Set(['group', 'identity', 'review']);

export const isNavigable = node => !!node && NAVIGABLE.has(node.kind);

const list = v => (Array.isArray(v) ? v : []);

export function childById(node, id) {
  return list(node?.children).find(c => c && c.id === id) || null;
}

// Resolve a path (array of node ids below the root) against a tree. Ids that no longer exist
// (the tree changed after an update) truncate the path to its deepest valid prefix.
export function resolvePath(root, path) {
  const nodes = root ? [root] : [];
  const valid = [];
  let node = root;
  for (const id of list(path)) {
    const next = childById(node, id);
    if (!next || !isNavigable(next)) break;
    nodes.push(next);
    valid.push(id);
    node = next;
  }
  return { nodes, path: valid };
}

export const pushPath = (path, id) => [...list(path), id];
export const popPath = path => list(path).slice(0, -1);

// "Parent › Child" for the current branch (the root label at the root).
export function headingFor(nodes) {
  const below = list(nodes).slice(1);
  if (below.length === 0) return nodes?.[0]?.label || '';
  if (below.length === 1) return below[0].label || '';
  const [parent, child] = below.slice(-2);
  return `${parent.label || ''} › ${child.label || ''}`;
}

// The camera preset of the current branch: the nearest node with one, from the deepest.
export function cameraFor(nodes) {
  for (let i = list(nodes).length - 1; i >= 0; i--) if (nodes[i]?.camera) return nodes[i].camera;
  return null;
}

// The creator / surgery tab that owns the current path.
export const selectedStage = (path, stages) =>
  list(stages).some(s => s.id === list(path)[0]) ? list(path)[0] : null;

// The rows of a searchable group for a query: its direct children whose label matches, plus the
// navigable descendants (e.g. the subcategories under the taxonomy groups) that match at any depth.
// A deep match carries `via` (the ids between the group and it) and a "Parent › Child" label.
export const SEARCH_LIMIT = 60;
export const SEARCH_DEPTH = 4;
export function filterChildren(node, search) {
  const children = list(node?.children);
  const q = String(search || '').trim().toLowerCase();
  if (!node?.searchable || !q) return children;
  const out = [];
  const matches = n => String(n?.label || '').toLowerCase().includes(q);
  const visit = (parent, via, depth) => {
    for (const c of list(parent.children)) {
      if (!c || out.length >= SEARCH_LIMIT) continue;
      if (depth === 0) {
        if (matches(c)) out.push(c);
      } else if (isNavigable(c) && matches(c)) {
        out.push({ ...c, via, label: `${parent.label || ''} › ${c.label || ''}` });
      }
      if (c.kind === 'group' && depth + 1 < SEARCH_DEPTH) visit(c, [...via, c.id], depth + 1);
    }
  };
  visit(node, [], 0);
  return out;
}

// The path that opens a row (a search result opens through its `via` ids).
export const openPath = (path, node) => [...list(path), ...list(node?.via), node?.id];

// The confirmation modal of a pending confirm state:
//  'save' (the commit, with its total), 'reset', 'leave' (unsaved changes at the root) or
//  { kind: 'invoke', node, where } (a destructive action, node.danger). null = no modal.
//  A save modal carries the price breakdown (`lines`, from priceLines) and its `total` when there is one.
export function modalFor(confirm, { strings = {}, copy = {}, saveBody = '', lines = [], total = '' } = {}) {
  if (confirm === 'save') return list(lines).length ? { title: copy.title || '', body: saveBody, lines, total } : { title: copy.title || '', body: saveBody };
  if (confirm === 'reset') return { title: strings.reset || '', body: strings.resetBody || '' };
  if (confirm === 'leave') return { title: strings.leaveTitle || '', body: strings.leave || '' };
  if (confirm?.kind === 'invoke' && confirm.node) {
    return {
      title: [confirm.where, confirm.node.label].filter(Boolean).join(' › '),
      body: confirm.node.confirmBody || strings.dangerBody || '',
    };
  }
  return null;
}

// The request the confirm button of a modal sends (the leave modal has its own buttons: null).
export function confirmRequest(confirm) {
  if (confirm === 'save' || confirm === 'reset') return { op: confirm };
  if (confirm?.kind === 'invoke' && confirm.node?.control) return { op: 'invoke', control: confirm.node.control };
  return null;
}

// The Save button of the leave modal never commits directly: it opens the save confirmation,
// which shows the save label and the total that will be charged.
export const LEAVE_SAVE_NEXT = 'save';

// The creator's identity form differs from the values it opened with: typed names / date of birth
// are unsaved input even while the appearance is untouched (Lua's `dirty` is working ≠ saved only).
export function identityDirty(identity, form) {
  if (!identity) return false;
  const start = initialIdentity(identity);
  return Object.keys(start).some(key => String(form?.[key] ?? '') !== start[key]);
}

// What Back / Escape does: dismiss the open modal, go up one level, ask to save/discard (root,
// dirty) or close (root, clean).
export function backAction({ confirm, pathLength, dirty }) {
  if (confirm) return 'dismiss';
  if (pathLength > 0) return 'pop';
  return dirty ? 'confirmLeave' : 'close';
}

// UI memory per session id: the same id keeps its path/search, a new id starts fresh.
export const createMemory = () => new Map();
export function remember(memory, id, state) {
  if (id === undefined || id === null) return memory;
  memory.set(String(id), { ...(memory.get(String(id)) || {}), ...state });
  if (memory.size > 20) memory.delete(memory.keys().next().value);
  return memory;
}
export const recall = (memory, id) => memory.get(String(id)) || null;

// Request state machine: idle -> loading -> success | error.
export const idleRequest = { status: 'idle', error: '' };
export function requestReducer(state, event) {
  switch (event?.type) {
    case 'start':
      return { status: 'loading', error: '' };
    case 'success':
      return { status: 'success', error: '' };
    case 'error':
      return { status: 'error', error: String(event.error || '') };
    case 'reset':
      return idleRequest;
    default:
      return state || idleRequest;
  }
}
export const isPending = state => state?.status === 'loading';

// Numbers: storage value <-> displayed value (display = {scale, decimals}).
export function toDisplay(value, display) {
  const scale = Number(display?.scale) || 1;
  return Number(value || 0) * scale;
}
export function formatDisplay(value, display) {
  const decimals = Number.isInteger(display?.decimals) ? display.decimals : 2;
  const shown = toDisplay(value, display);
  const text = shown.toFixed(decimals);
  return text === '-0' || /^-0\.0*$/.test(text) ? text.slice(1) : text;
}
export function fromDisplay(text, display, min = -Infinity, max = Infinity) {
  const scale = Number(display?.scale) || 1;
  const n = Number(text);
  if (!Number.isFinite(n)) return null;
  return Math.max(min, Math.min(max, n / scale));
}

const pad2 = n => String(n).padStart(2, '0');

// The options of a choice node: explicit options (badge labels appended) or a generated range.
export function choiceOptions(node, strings = {}) {
  if (Array.isArray(node?.options)) {
    return node.options.map(o => {
      const badge = o.badgeLabel || (o.badge ? strings[o.badge] : '');
      return { value: o.value, label: badge ? `${o.label} · ${badge}` : String(o.label ?? '') };
    });
  }
  const range = node?.range;
  if (!range) return [];
  const out = [];
  if (range.none) out.push({ value: 0, label: strings.none || '' });
  for (let v = Number(range.min); v <= Number(range.max); v++) out.push({ value: v, label: pad2(v) });
  return out;
}

export const formatMoney = n => `$${(Number(n) || 0).toFixed(2)}`;

// The rows of a price breakdown (payload.price.lines = [{label, amount}], §8.1) as {label, value}.
// Shown only when the lines add up to the total: a capped barber visit has no line for the cap, and
// amounts that do not add up would misstate what is charged (the total alone is shown then).
export function priceLines(price) {
  const lines = list(price?.lines).filter(l => l && Number.isFinite(Number(l.amount)));
  if (!lines.length) return [];
  const cents = n => Math.round(Number(n) * 100);
  if (lines.reduce((sum, l) => sum + cents(l.amount), 0) !== cents(price.total)) return [];
  return lines.map(l => ({ label: String(l.label ?? ''), value: formatMoney(l.amount) }));
}

// Split the children of a group into render segments, keeping their order:
//  rows      navigable children and actions (MenuRow)
//  controls  consecutive choice/slider leaves (one .component article)
//  pads      pad nodes (FeaturePad); `extra` = the sliders of a group that has pads
//  node      any other leaf (text, info, itemcard) on its own
export function segments(children) {
  const items = list(children);
  const hasPads = items.some(c => c.kind === 'pad');
  const out = [];
  const extra = [];
  const last = () => out[out.length - 1];
  for (const node of items) {
    if (isNavigable(node) || node.kind === 'action') {
      if (last()?.type === 'rows') last().nodes.push(node);
      else out.push({ type: 'rows', nodes: [node] });
    } else if (node.kind === 'pad') {
      if (last()?.type === 'pads') last().nodes.push(node);
      else out.push({ type: 'pads', nodes: [node] });
    } else if (hasPads && node.kind === 'slider') {
      extra.push(node);
    } else if (node.kind === 'choice' || node.kind === 'slider') {
      if (last()?.type === 'controls') last().nodes.push(node);
      else out.push({ type: 'controls', nodes: [node] });
    } else {
      out.push({ type: 'node', nodes: [node] });
    }
  }
  if (extra.length) out.push({ type: 'extra', nodes: extra });
  return out;
}

// The value shown in a MenuRow's value slot: a badge first, then a summary.
export const rowValue = (node, strings = {}) =>
  node?.badgeLabel || (node?.badge ? strings[node.badge] : '') || node?.summary || null;

// Identity form (creator): initial values from the payload fields; missing = a required field empty.
// A text node (§8.2 kind 'text') whose action cannot run with this typed value: a required field
// (node.required, e.g. the new outfit's name) that is empty once trimmed.
export function textBlocked(node, draft) {
  return !!node?.required && String(draft ?? '').trim() === '';
}

export function initialIdentity(identity) {
  const out = { firstname: '', lastname: '', dob: '' };
  for (const f of list(identity?.fields)) if (f.key in out && typeof f.value === 'string') out[f.key] = f.value;
  return out;
}
export function missingIdentity(identity, form) {
  if (!identity) return false;
  return list(identity.fields)
    .filter(f => f.type !== 'info')
    .some(f => !String(form?.[f.key] || '').trim());
}

let opCounter = 0;
export function nextOpId(sessionId) {
  opCounter = (opCounter + 1) % 1e6;
  return `${sessionId}-${Date.now().toString(36)}-${opCounter}`;
}
