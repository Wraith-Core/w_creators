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

// What Back / Escape does: dismiss the open modal, clear an active search (the search is one
// navigation level), go up one level, ask to save/discard (root, dirty) or close (root, clean).
// `direct` (payload.backDirect: the creator's "change the sex", which keeps the look as a draft)
// closes from the root without the question: nothing is lost.
export function backAction({ confirm, pathLength, dirty, search, direct }) {
  if (confirm) return 'dismiss';
  if (String(search || '').trim() !== '') return 'clearSearch';
  if (pathLength > 0) return 'pop';
  if (direct) return 'close';
  return dirty ? 'confirmLeave' : 'close';
}

// A row opened from a search result remembers where the search was: { from, path, search }.
export const searchOrigin = (path, next, search) =>
  String(search || '').trim() !== '' ? { from: list(path), path: list(next), search: String(search) } : null;

// Where Back goes from `path`: the result list the row was opened from (same path as the origin
// recorded) or one level up. Returns { path, search }.
export function popTarget(path, origin) {
  const here = list(path).join('/');
  if (origin && list(origin.path).join('/') === here) return { path: list(origin.from), search: origin.search || '' };
  return { path: popPath(path), search: '' };
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

// Numbers: storage value <-> displayed value (display = {scale, decimals, format?}).
export function toDisplay(value, display) {
  const scale = Number(display?.scale) || 1;
  return Number(value || 0) * scale;
}
// display.format ('%s m', from the payload's own words) wraps the number in its unit: the creator's
// height reads as metres or feet. No unit text is written here.
export function formatDisplay(value, display) {
  const decimals = Number.isInteger(display?.decimals) ? display.decimals : 2;
  const shown = toDisplay(value, display);
  const text = shown.toFixed(decimals);
  const out = text === '-0' || /^-0\.0*$/.test(text) ? text.slice(1) : text;
  const format = typeof display?.format === 'string' && display.format.includes('%s') ? display.format : null;
  return format ? format.replace('%s', out) : out;
}
export function fromDisplay(text, display, min = -Infinity, max = Infinity) {
  const scale = Number(display?.scale) || 1;
  const n = Number(text);
  if (!Number.isFinite(n)) return null;
  return Math.max(min, Math.min(max, n / scale));
}

const pad2 = n => String(n).padStart(2, '0');

// A colour chip value from Lua: a #rgb / #rrggbb string, anything else is dropped (it ends up in a
// CSS custom property, so only a plain hex colour is let through).
export const swatchOf = v => (typeof v === 'string' && /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(v) ? v : null);

// The options of a choice node: explicit options (badge labels appended, colour chip kept) or a
// generated range.
export function choiceOptions(node, strings = {}) {
  if (Array.isArray(node?.options)) {
    return node.options.map(o => {
      const badge = o.badgeLabel || (o.badge ? strings[o.badge] : '');
      const out = { value: o.value, label: badge ? `${o.label} · ${badge}` : String(o.label ?? '') };
      const swatch = swatchOf(o.swatch);
      if (swatch) out.swatch = swatch;
      return out;
    });
  }
  const range = node?.range;
  if (!range) return [];
  const out = [];
  if (range.none) out.push({ value: 0, label: strings.none || '' });
  for (let v = Number(range.min); v <= Number(range.max); v++) out.push({ value: v, label: pad2(v) });
  return out;
}

// An amount in its currency: '$12.50' in cash; in gold the payload's own words
// (strings.goldAmount, e.g. '%s ذهب' / '%s gold'), so no currency text is written here.
export const formatMoney = (n, currency, strings) => {
  const amount = (Number(n) || 0).toFixed(2);
  if (currency === 'gold') return String(strings?.goldAmount || '%s').replace('%s', amount);
  return `$${amount}`;
};

// The rows of a price breakdown (payload.price.lines = [{label, amount}], §8.1) as {label, value}.
// Shown only when the lines add up to the total: a capped barber visit has no line for the cap, and
// amounts that do not add up would misstate what is charged (the total alone is shown then).
export function priceLines(price, strings) {
  const lines = list(price?.lines).filter(l => l && Number.isFinite(Number(l.amount)));
  if (!lines.length) return [];
  const cents = n => Math.round(Number(n) * 100);
  if (lines.reduce((sum, l) => sum + cents(l.amount), 0) !== cents(price.total)) return [];
  return lines.map(l => ({ label: String(l.label ?? ''), value: formatMoney(l.amount, price?.currency, strings) }));
}

// A slider value that avoids the indices a palette disables (node.skip): the nearest allowed value
// in the direction the hand moved (from `prev`), else the nearest the other way, within min..max.
export function skipValue(value, prev, skip, min, max) {
  const blocked = new Set(list(skip).map(Number));
  let v = Math.max(min, Math.min(max, Math.round(Number(value))));
  if (!blocked.has(v)) return v;
  const step = Number(value) >= Number(prev) ? 1 : -1;
  for (const dir of [step, -step]) {
    for (let x = v + dir; x >= min && x <= max; x += dir) if (!blocked.has(x)) return x;
  }
  return Number.isFinite(Number(prev)) ? Number(prev) : v;
}

// Where an index sits on a palette strip (0..1, the middle of its cell): the strip spans min..max.
export const stripFraction = (index, min, max) => {
  const cells = Math.max(1, Number(max) - Number(min) + 1);
  return Math.max(0, Math.min(1, (Number(index) - Number(min) + 0.5) / cells));
};

// A palette strip always holds the whole palette, tint 0 .. TINT_MAX left to right (docs/CLOTHING.md
// §5.2), whatever bounds a palette's limits give the slider: the chip reads the tint's own cell.
export const TINT_MAX = 254;

// The part of a whole-palette strip a slider of min..max shows, as CSS background size and
// position-x percentages: the strip is scaled so the min..max cells fill the track, then shifted so
// cell `min` sits at its left edge (a background-position percentage p places the image at
// p × (track − image), so p = min / (cells − shown)).
export function stripWindow(min, max) {
  const cells = TINT_MAX + 1;
  const lo = Math.max(0, Math.min(TINT_MAX, Math.round(Number(min) || 0)));
  const hi = Math.max(lo, Math.min(TINT_MAX, Math.round(Number.isFinite(Number(max)) ? Number(max) : TINT_MAX)));
  const shown = hi - lo + 1;
  if (shown >= cells) return { size: 100, position: 0 };
  return { size: cells / shown * 100, position: lo / (cells - shown) * 100 };
}

// A palette strip path from Lua (node.track, 'tex/palettes/<name>.png'): only that plain shape is
// let through (it ends up in a CSS url()).
export const trackPath = v => (typeof v === 'string' && /^tex\/palettes\/[A-Za-z0-9_]+\.png$/.test(v) ? v : null);

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

// ── The notebook lines: the head sentence (what the screen does and costs) and the readiness line
// above the buttons. A part is plain text or {text, value}: the text holds one '%s' where the value
// goes; an amount is written as its own run (left to right in cash), a list of field names (plain)
// in the page's direction.

// The money the player carries in the visit's currency (payload.wallet, read by the client from the
// framework); null when unknown (then only the price is said, never "you have").
export function walletAmount(wallet, currency) {
  if (!wallet || typeof wallet !== 'object') return null;
  const raw = currency === 'gold' ? wallet.gold : wallet.cash;
  if (raw === null || raw === undefined || raw === '') return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value : null;
}

// «قصة وتسريحة · المجموع $12.00 · معك $85.00»: the mode's sentence, the total when there is one to
// pay, the player's money when known.
export function leadParts({mode, strings: S = {}, price, wallet, money}) {
  const out = [];
  if (S['lead.' + mode]) out.push(S['lead.' + mode]);
  if (price && Number(price.total) > 0 && S.sumTotal) out.push({text: S.sumTotal, value: money(price.total)});
  const have = price ? walletAmount(wallet, price.currency) : null;
  if (have !== null && S.youHave) out.push({text: S.youHave, value: money(have)});
  return out;
}

// The readiness line: {tone: 'miss' | 'warn' | 'ok' | 'idle', text, value?, plain?, fix?} or null.
// The creator says which identity fields are empty or refused (fix: «أصلحه» opens the identity);
// a paid visit says how much is missing, or that it is ready and what it costs. A currency the
// pieces are not sold in is already said by payload.saveBlocked, so it adds nothing then.
export function readiness({mode, strings: S = {}, payload = {}, identity, identityErrors, money, rtl}) {
  const sep = rtl ? '، ' : ', ';
  if (mode === 'creator' && payload.identity) {
    const fields = list(payload.identity.fields).filter(f => f.type !== 'info');
    const empty = fields.filter(f => !String(identity?.[f.key] || '').trim()).map(f => f.label);
    if (empty.length) return {tone: 'miss', text: S.missingFor, value: empty.join(sep), plain: true, fix: true};
    const wrong = fields.filter(f => identityErrors && identityErrors[f.key]).map(f => f.label);
    if (wrong.length) return {tone: 'miss', text: S.needsFix, value: wrong.join(sep), plain: true, fix: true};
    return payload.canSave ? {tone: 'ok', text: S.ready} : null;
  }
  if (payload.saveBlocked) return null;
  if (!payload.dirty) return {tone: 'idle', text: S.noChange};
  if (!payload.canSave) return null;
  const price = payload.price;
  if (!price) return {tone: 'ok', text: S.ready};
  const total = Number(price.total) || 0;
  if (total <= 0) return {tone: 'ok', text: S.readyFree};
  const have = walletAmount(payload.wallet, price.currency);
  if (have !== null && have < total) return {tone: 'miss', text: S.shortBy, value: money(total - have)};
  if (have !== null) return {tone: 'ok', text: S.readyPay, value: money(total)};
  return {tone: 'warn', text: S.willPay, value: money(total)};
}

let opCounter = 0;
export function nextOpId(sessionId) {
  opCounter = (opCounter + 1) % 1e6;
  return `${sessionId}-${Date.now().toString(36)}-${opCounter}`;
}

// The creator's Review plate: the identity typed in the Identity stage (held here, not in Lua)
// first, one row per identity field, then the appearance rows Lua built. Without an identity
// (every other mode) the node's rows unchanged.
export function reviewItems(node, identity, form) {
  const rows = list(node?.items);
  const fields = list(identity?.fields);
  if (!fields.length) return rows;
  const typed = fields.map(f => ({
    label: f?.label || '',
    value: String((f?.type === 'info' ? f?.value : form?.[f?.key]) ?? '').trim(),
  }));
  // a row Lua also lists (the sex, an info field) is shown once, with the identity rows
  const own = new Set(typed.map(t => t.label).filter(Boolean));
  return [...typed, ...rows.filter(r => !own.has(r?.label))];
}

// The full name on the creator's Review card (its handwritten signature line): the typed names, or
// the kept ones of a locked identity. '' without an identity or before anything is typed.
export function identityName(identity, form) {
  const value = key => {
    const f = list(identity?.fields).find(x => x?.key === key);
    if (!f) return '';
    return String((f.type === 'info' ? f.value : form?.[key]) ?? '').trim();
  };
  return [value('firstname'), value('lastname')].filter(Boolean).join(' ');
}

// Text that holds Arabic letters (a name from the server on an English screen, or the other way
// round): it is marked so the Latin letter-spacing, capitals and slant never reach Arabic letters.
export const hasArabic = s => /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/.test(String(s ?? ''));

// A balance on the selection card, as the pause menu writes it: Western digits, two decimals below
// 100,000 and none above (a fortune never pushes the name out of the bar), a dash when unknown.
export function cardMoney(v, dollar) {
  const n = typeof v === 'number' ? v : (typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);
  if (!Number.isFinite(n)) return '—';
  const digits = Math.abs(n) >= 100000 ? 0 : 2;
  const s = Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return `${n < 0 ? '-' : ''}${dollar ? '$' : ''}${s}`;
}

// ---- The date of birth as day · month · year (DateField.jsx) -------------------------------------
// The browser's <input type="date"> draws mm/dd/yyyy in its own language whatever the page says, so
// the creator picks the three parts itself. The value it sends is still 'YYYY-MM-DD' (the Lua check
// and dobBounds are unchanged), and only a complete date inside the field's min..max: anything else
// is '' (missing), which keeps the save closed.
export const isLeapYear = y => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

// Days in a month; February has 29 until the year is known.
export function daysInMonth(y, m) {
  if (m === 2) return Number.isInteger(y) && !isLeapYear(y) ? 28 : 29;
  return [4, 6, 9, 11].includes(m) ? 30 : 31;
}

// 'YYYY-MM-DD' -> { y, m, d }, or null for anything that is not a real calendar date.
export function parseIsoDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s ?? '').trim());
  if (!m) return null;
  const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null;
  return { y, m: mo, d };
}

// The field's min / max (ISO strings from Lua dobBounds) as parts; without them (no server date)
// a wide window, the server validates the age anyway.
export const DATE_FALLBACK = { min: { y: 1800, m: 1, d: 1 }, max: { y: 2100, m: 12, d: 31 } };
export function dateBounds(min, max) {
  return { min: parseIsoDate(min) || DATE_FALLBACK.min, max: parseIsoDate(max) || DATE_FALLBACK.max };
}

const dateKey = p => p.y * 10000 + p.m * 100 + p.d;

// The ISO value of the parts when they are a complete date inside the bounds, else ''.
export function composeIsoDate(parts, bounds) {
  const { y, m, d } = parts || {};
  if (![y, m, d].every(Number.isInteger)) return '';
  if (m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) return '';
  const b = bounds || DATE_FALLBACK;
  const k = dateKey({ y, m, d });
  if (k < dateKey(b.min) || k > dateKey(b.max)) return '';
  return `${String(y).padStart(4, '0')}-${pad2(m)}-${pad2(d)}`;
}

// A month or year change that leaves the day past the month's end (31 -> February) takes the last day.
export function clampDateParts(parts) {
  const out = { ...(parts || {}) };
  if (Number.isInteger(out.d) && Number.isInteger(out.m)) out.d = Math.min(out.d, daysInMonth(out.y, out.m));
  return out;
}

// Whether one choice of a part ('d' | 'm' | 'y') can still give a date inside the bounds with the
// other parts as they are (the chooser disables the rest).
export function dateOptionAllowed(kind, value, parts, bounds) {
  const b = bounds || DATE_FALLBACK;
  const p = parts || {};
  const lo = dateKey(b.min), hi = dateKey(b.max);
  const v = Number(value);
  if (!Number.isInteger(v)) return false;
  if (kind === 'y') return v >= b.min.y && v <= b.max.y;
  if (kind === 'm') {
    if (v < 1 || v > 12) return false;
    if (!Number.isInteger(p.y)) return true;
    return dateKey({ y: p.y, m: v, d: daysInMonth(p.y, v) }) >= lo && dateKey({ y: p.y, m: v, d: 1 }) <= hi;
  }
  if (v < 1 || v > (Number.isInteger(p.m) ? daysInMonth(p.y, p.m) : 31)) return false;
  if (!Number.isInteger(p.y) || !Number.isInteger(p.m)) return true;
  const k = dateKey({ y: p.y, m: p.m, d: v });
  return k >= lo && k <= hi;
}

// The keyboard on a part: Up / Down step it (a day or month wraps round, a year stops at the
// bounds; an empty part starts from its first or last value).
export function stepDatePart(kind, parts, delta, bounds) {
  const b = bounds || DATE_FALLBACK;
  const p = { ...(parts || {}) };
  if (kind === 'y') {
    const start = Number.isInteger(p.y) ? p.y + delta : (delta > 0 ? b.min.y : b.max.y);
    p.y = Math.max(b.min.y, Math.min(b.max.y, start));
  } else {
    const n = kind === 'm' ? 12 : daysInMonth(p.y, p.m);
    const cur = p[kind];
    const v = Number.isInteger(cur) ? cur + delta : (delta > 0 ? 1 : n);
    p[kind] = ((v - 1) % n + n) % n + 1;
  }
  return clampDateParts(p);
}
