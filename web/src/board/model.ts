/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/model.ts - the board's data (ops/local/plans/creators-board-contract.md «Board»), read
 * defensively: Lua's JSON writes an empty table as {} or [], a nil field is simply absent, and a number may
 * arrive as text. asBoard() gives the page one clean shape, or null when the payload is not a board.
 * ════════════════════════════════════════════════════════════════════════════ */

export type PlaceType = 'clothing' | 'barber' | 'surgery' | 'wardrobe';
/** the rail's order */
export const TYPES: PlaceType[] = ['surgery'];

/** a place's spots in the world: what `place` / `clear` take as `what` */
export type SpotKind = 'npc' | 'preview' | 'book' | 'chair';
/** which spots each type has (the book is the clothing store's, the chair the barber's) */
export const SPOTS: Record<PlaceType, SpotKind[]> = {
  clothing: ['npc', 'preview', 'book'],
  barber: ['npc', 'preview', 'chair'],
  surgery: ['npc', 'preview'],
  wardrobe: ['npc', 'preview'],
};

export interface Spot { x: number; y: number; z: number; h?: number }
export interface NpcSpot extends Spot { model: string }
export interface ChairSpot extends Spot { kind: 'world' | 'prop'; model: string }

export interface Place {
  id: string;
  type: PlaceType;
  enabled: boolean;
  label: string;
  town: string;
  blip: boolean;
  radius: number;
  coords: Spot | null;
  npc: NpcSpot | null;
  preview: Spot | null;
  book: Spot | null;
  chair: ChairSpot | null;
  storeProfile: string;
  pricingProfile: string;
  /** the model the NPC uses, or will use once it is placed */
  npcModel: string;
  usable: boolean;
}

export interface BoardData {
  places: Place[];
  counts: Record<PlaceType, number>;
  npcModels: Record<PlaceType, string[]>;
  chairModels: string[];
  profiles: { store: string[]; pricing: string[] };
  /** the place an answer points at (create: the new place's id), or '' */
  selected: string;
}

/** what the card edits (op `save`) */
export interface Form {
  label: string;
  town: string;
  enabled: boolean;
  blip: boolean;
  /** null while the box holds no number */
  radius: number | null;
  npcModel: string;
  storeProfile: string;
  pricingProfile: string;
}

/* ── reading ── */
type Obj = Record<string, unknown>;
export const obj = (v: unknown): Obj | null => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : null);
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : obj(v) ? Object.values(v as Obj) : []);
const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');
const num = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};
const bool = (v: unknown): boolean => v === true || v === 1 || v === 'true';
const strings = (v: unknown): string[] => {
  const out: string[] = [];
  for (const x of list(v)) { const s = str(x).trim(); if (s !== '' && !out.includes(s)) out.push(s); }
  return out;
};
const isType = (v: unknown): v is PlaceType => typeof v === 'string' && (TYPES as string[]).includes(v);

function spot(v: unknown): Spot | null {
  const o = obj(v);
  if (!o) return null;
  const x = num(o.x), y = num(o.y), z = num(o.z);
  if (x === null || y === null || z === null) return null;
  const h = num(o.h ?? o.w ?? o.heading);
  return h === null ? { x, y, z } : { x, y, z, h };
}

function asPlace(v: unknown): Place | null {
  const o = obj(v);
  if (!o) return null;
  const id = str(o.id);
  if (id === '' || !isType(o.type)) return null;
  const npcAt = spot(o.npc);
  const chairAt = spot(o.chair);
  const npcObj = obj(o.npc);
  const chairObj = obj(o.chair);
  return {
    id,
    type: o.type,
    enabled: bool(o.enabled),
    label: str(o.label),
    town: str(o.town),
    blip: bool(o.blip),
    radius: num(o.radius) ?? 0,
    coords: spot(o.coords),
    npc: npcAt ? { ...npcAt, model: str(npcObj?.model) } : null,
    preview: spot(o.preview),
    book: spot(o.book),
    // a chair picked from the map may carry its model as a number (a hash): kept as text, shown only for a prop
    chair: chairAt ? { ...chairAt, kind: chairObj?.kind === 'prop' ? 'prop' : 'world', model: str(chairObj?.model) } : null,
    storeProfile: str(o.storeProfile),
    pricingProfile: str(o.pricingProfile),
    npcModel: str(o.npcModel),
    usable: bool(o.usable),
  };
}

/** the payload of a `board` message or of an answer's `data`, or null when it is not a board */
export function asBoard(raw: unknown): BoardData | null {
  const o = obj(raw);
  if (!o || o.ok === false) return null;
  if (o.places === undefined && o.types === undefined) return null;
  const places = list(o.places).map(asPlace).filter((p): p is Place => p !== null);
  const counts = { clothing: 0, barber: 0, surgery: 0, wardrobe: 0 } as Record<PlaceType, number>;
  for (const p of places) counts[p.type] += 1;
  for (const t of list(o.types)) {
    const r = obj(t);
    const n = r ? num(r.count) : null;
    if (r && isType(r.id) && n !== null) counts[r.id] = Math.max(0, Math.floor(n));
  }
  const models = obj(o.npcModels);
  const npcModels = {} as Record<PlaceType, string[]>;
  for (const t of TYPES) npcModels[t] = strings(models?.[t]);
  const prof = obj(o.profiles);
  return {
    places,
    counts,
    npcModels,
    chairModels: strings(o.chairModels),
    profiles: { store: strings(prof?.store), pricing: strings(prof?.pricing) },
    selected: str(o.selected),
  };
}

/* ── the card's form ── */
export function formOf(p: Place, b: BoardData): Form {
  return {
    label: p.label,
    town: p.town,
    enabled: p.enabled,
    blip: p.blip,
    radius: p.radius,
    npcModel: p.npcModel || p.npc?.model || b.npcModels[p.type][0] || '',
    storeProfile: p.storeProfile,
    pricingProfile: p.pricingProfile,
  };
}

export const sameForm = (a: Form, b: Form): boolean =>
  a.label === b.label && a.town === b.town && a.enabled === b.enabled && a.blip === b.blip && a.radius === b.radius
  && a.npcModel === b.npcModel && a.storeProfile === b.storeProfile && a.pricingProfile === b.pricingProfile;

export const LABEL_MAX = 60;
export const TOWN_MAX = 60;
export const MODEL_MAX = 64;
const letters = (s: string) => [...s].length;

export const labelOk = (s: string) => { const n = letters(s.trim()); return n >= 1 && n <= LABEL_MAX; };
export const townOk = (s: string) => letters(s.trim()) <= TOWN_MAX;
export const radiusOk = (n: number | null): n is number => n !== null && Number.isFinite(n) && n > 0 && n <= 1000;
/** a ped model's name: letters, digits and _ (the game's own names), or empty for the store's default */
export const modelOk = (s: string) => s.trim() === '' || /^[A-Za-z0-9_]{1,64}$/.test(s.trim());
export const formOk = (f: Form) => labelOk(f.label) && townOk(f.town) && radiusOk(f.radius) && modelOk(f.npcModel);

/** op `save`'s args (the profiles only for a clothing store) */
export function saveArgs(p: Place, f: Form): Record<string, unknown> {
  const args: Record<string, unknown> = {
    id: p.id,
    label: f.label.trim(),
    town: f.town.trim(),
    enabled: f.enabled,
    blip: f.blip,
    radius: f.radius,
    npcModel: f.npcModel.trim(),
  };
  if (p.type === 'clothing') {
    args.storeProfile = f.storeProfile;
    args.pricingProfile = f.pricingProfile;
  }
  return args;
}

export function hasSpot(p: Place, w: SpotKind): boolean {
  return p[w] !== null;
}

/** «x, y, z» with one decimal */
export const fmtSpot = (s: Spot) => [s.x, s.y, s.z].map((v) => v.toFixed(1)).join(', ');

/** A number typed by a person: Arabic-Indic digits and a comma for the decimal point are accepted */
export function parseNumber(value: string): number | null {
  const western = value
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .replace(/[,٫]/g, '.')
    .trim();
  if (western === '') return null;
  const n = Number(western);
  return Number.isFinite(n) ? n : null;
}

/** one suggestion list with the current value in it (a value typed by hand is kept at its end) */
export function withValue(options: string[], value: string): string[] {
  const v = value.trim();
  return v === '' || options.includes(v) ? options : [...options, v];
}

/* ── 2026-11-12: the notebook (the builders' look) ── */

/** a spot in words, from Lua's lib.place (boardWhere): «فالنتاين · 12 م منك» and the metres */
export interface Where { t: string; m: number }
export type WhereMap = Record<string, Partial<Record<'coords' | SpotKind, Where>>>

export function asWhere(raw: unknown): WhereMap {
  const out: WhereMap = {};
  const o = obj(raw);
  if (!o) return out;
  for (const [id, v] of Object.entries(o)) {
    const row = obj(v);
    if (!row) continue;
    const r: Partial<Record<'coords' | SpotKind, Where>> = {};
    for (const k of ['coords', 'npc', 'preview', 'book', 'chair'] as const) {
      const w = obj(row[k]);
      const t = w ? str(w.t) : '';
      if (t !== '') r[k] = { t, m: num(w?.m) ?? 0 };
    }
    out[id] = r;
  }
  return out;
}

/** the spots each type has, in the order the story tells them (the service point first) */
export type StoryKind = 'coords' | SpotKind;
export const STORY: Record<PlaceType, StoryKind[]> = {
  clothing: ['coords', 'npc', 'preview', 'book'],
  barber: ['coords', 'npc', 'preview', 'chair'],
  surgery: ['coords', 'npc', 'preview'],
  wardrobe: ['coords', 'npc', 'preview'],
};

/** the interaction radius as three plain choices (any other saved value stays, as «مخصصة») */
export const REACH = [1, 2, 4];

/** what the place still needs to work well (the spots a player meets), in the story's order */
export function missingSpots(p: Place): SpotKind[] {
  return SPOTS[p.type].filter((w) => p[w] === null);
}

/** what blocks «حفظ» (the server's own checks: name, town, radius, model), as field ids */
export function formProblems(f: Form): string[] {
  const out: string[] = [];
  if (!labelOk(f.label)) out.push('label');
  if (!townOk(f.town)) out.push('town');
  if (!radiusOk(f.radius)) out.push('radius');
  if (!modelOk(f.npcModel)) out.push('npcModel');
  return out;
}
