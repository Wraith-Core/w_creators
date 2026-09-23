# w_creators — Architecture (v3)

This document is the **authoritative contract** for the w_creators re-architecture. Every module,
callback, event, NUI message and data shape described here is binding: code that deviates from it
is a bug in the code, not in this document. If you must change a contract, change this file in the
same commit and say why.

w_creators is the single authority for the character lifecycle on the server: account → characters →
selection → identity → persistent appearance → clothing ownership → outfits → runtime clothing states →
barber → cosmetic surgery → spawn → respawn.

---

## 0. Ground rules (apply to every file)

1. **Server authority.** Prices, ownership, slot counts, identity validation, allowed sections, spawn
   coordinates, service availability and every persisted value are decided on the server. The client
   and the NUI only *request* actions. A value that arrives from a client is treated as hostile until
   validated against the catalog, the config, the database and the player's session.
2. **Semantic UI.** The NUI never sees a component hash, a native, a price formula or a category hash.
   It renders a tree of nodes and sends back `control` ids and values (§8).
3. **One of each.** One appearance model (`AppearanceSchema`), one render pipeline
   (`Appearance.RestoreCharacter`), one catalog (`WCCatalog`), one camera service (`WCCamera`), one
   preview transaction architecture (`WCEditor` client + `WCSessions` server), one spawn service,
   one respawn service, one result contract (`WCResult`).
4. **Natives live in `client/natives/`.** No `Citizen.InvokeNative` / `N_0x…` outside
   `client/natives/*.lua` (the w_lib wrappers such as `w.component.*` and plain named natives like
   `SetEntityCoords` are fine). Every wrapper is documented (§10).
5. **No backtick hashes** (`` `foo` ``): use `GetHashKey`/`joaat`. Plain Lua 5.4 must be able to load
   every file (tests load them with lupa).
6. **Hierarchy everywhere.** Every option sits under its parent: Category → Subcategory → Option →
   Variation/Color/State. No flat lists of unrelated options, in the NUI or in config.
7. **Locale.** Every player-visible string is a dictionary key. Keys are the Arabic source text
   (existing convention); `locales/en.json` translates, `locales/ar.json` maps key → key. Lua calls
   `locale(key, ...)`. The NUI receives already-translated strings. No hardcoded UI copy in JSX.
8. **No `Wait(n)` as synchronisation.** Wait for a condition with a timeout (`w.waitFor`,
   `WCUtil.waitUntil`), never a blind sleep between native calls.
9. **Debug output** goes through `WCDebug.log(domain, fmt, ...)` (silent unless `Config.Debug`).
   `print` only for startup/fatal diagnostics. No `console.log` in shipped JS.
10. **Globals.** Lua files in a resource share one environment. Use the global names listed in §3;
    keep file-local helpers `local`.

---

## 1. Audit summary (pre-v3 state)

| # | Finding | Severity | Resolution |
|---|---|---|---|
| A1 | `/starting` client command opens the creator mid-game; server `saveCharacter` registers a new framework character without any server-granted creation session | High | REMOVE command; creation requires a server grant (`characters:beginCreate`) |
| A2 | `w_creators:server:isolate`, `PersonaCreatorHandler.setPlayerRoutingBucket` let any client move itself into a private routing bucket at any time (invisibility / combat-log exploit) | High | Isolation only while a server-tracked scene/fitting session exists |
| A3 | `w_creators:server:rejoinWorld` lets any client reset its routing bucket to 0 (escapes buckets set by other resources: jail, housing instances) | High | Only restores buckets w_creators itself set (tracked per player) |
| A4 | `PersonaCreatorHandler.reloadCharacterAppearance` / `w_creators:server:requestAppearances` unthrottled DB/broadcast amplification | Medium | Rate limited |
| A5 | `selectCharacter`: blind `Wait(300)`; no per-player lock (double select → double login); `json.decode` on DB columns unprotected | Medium | Locked, awaited with timeout, decoded safely |
| A6 | Identity validation: only non-empty + ≤100 bytes; no charset, no DOB | Medium | Server identity validator (§6.3) |
| A7 | Face morphology stored twice (`faceFeatures` list and `components.__expressions`) — both drive `SET_CHAR_EXPRESSION` | Medium | Single `morph` map (v3) |
| A8 | `data/features.lua` hardcodes raw expression ids that w_lib already names | Low | `shared/morphology.lua` uses w_lib names |
| A9 | Clothing is one flat list of ~35 categories; creator `base` tab mixes head/eyes/teeth/body; overlays mix skin & makeup | High (UX rule) | Hierarchical taxonomy (§5) + tree NUI (§8) |
| A10 | Editor JSX hardcodes ar/en strings | Medium | Strings from locale via Lua |
| A11 | `NativeSetPedFaceFeature` refreshes the ped after every single feature (60+ refreshes per apply) | Medium | Batched refresh in the pipeline |
| A12 | Clothing applied in alphabetical order (not dependency order) | Medium | `Config.Clothing.applyOrder` |
| A13 | Remote appearance applied once (20 s window); lost when a player leaves and re-enters OneSync scope | High | Scope-aware sync (§9.4) |
| A14 | Grooming thread reads + writes every player's appearance row every 30 s | Medium | In-memory accumulation, write on stage change / interval / drop |
| A15 | Tints configured (`StoreData.palettes`, `colorPrice`, clothes table tint columns) but never implemented | Low | Implemented (§5.4) |
| A16 | No cosmetic surgery, outfits, clothing states, per-location enable flags, service toggles, spawn point enable/order | — | Implemented |
| A17 | Last location not bounds-checked (only all-zero check) | Medium | World-bounds validation (§11) |
| A18 | Death respawn owned by w_ambulancejob (3 raw resurrect call sites) with no appearance restore | Medium | Respawn service + export used by w_ambulancejob (§12) |
| A19 | w_lib's w_core bridge calls `exports.w_creators:GetAppearance/SetClothes/SetSkin` and listens for `w_creators:server:characterCreated` — none exist | Medium | Implemented (§13) |
| A20 | Raw natives scattered across 6 files | Medium | `client/natives/` |
| A21 | Wardrobe export opens anywhere with no toggle | Low | `Config.Wardrobe.allowRemote` + service toggle |
| A22 | `/spawnprop` admin prop spawner inside the character resource | Low | Moved to restricted dev tools, off by default |
| A23 | Deleting a character leaves `w_creators_clothes` rows orphaned | Low | Deletion removes appearance, owned clothes and outfits in one transaction |

Subsystem classification: see §15.

---

## 2. File layout

```
w_creators/
  fxmanifest.lua
  config/        main.lua  locations.lua  clothing.lua  barber.lua  surgery.lua
                 wardrobe.lua  spawn.lua  outfits.lua
  shared/        util.lua  result.lua  debug.lua  services.lua  locations.lua  morphology.lua
                 overlays.lua  catalog.lua  rules.lua  appearance.lua  grooming.lua
                 clothing_states.lua  identity.lua
  client/
    natives/     metaped.lua  ped.lua  clothing.lua  camera.lua  respawn.lua  scene.lua  ui.lua
    core/        locale.lua  ui.lua  state.lua
    appearance/  pipeline.lua  overlays.lua  sync.lua
    camera/      camera.lua
    scene/       scene.lua  environment.lua
    editor/      editor.lua  tree.lua  panel.lua
    characters/  selector.lua
    creator/     creator.lua  cutscene.lua
    services/    locations.lua
    clothing/    store.lua  states.lua
    wardrobe/    wardrobe.lua
    barber/      barber.lua
    surgery/     surgery.lua
    spawn/       selector.lua  spawn.lua
    respawn/     respawn.lua
    dev/         tools.lua
    api.lua
  server/
    bridge/      logging.lua  framework.lua
    core/        migrations.lua  security.lua  economy.lua  sessions.lua
    appearance/  repository.lua  sync.lua
    characters/  characters.lua
    scene.lua
    clothing/    ownership.lua  store.lua  states.lua
    wardrobe/    outfits.lua  wardrobe.lua
    barber/      barber.lua  grooming.lua
    surgery/     surgery.lua
    spawn/       spawn.lua
    respawn/     respawn.lua
    dev/         tools.lua
    api.lua
  locales/       ar.json  en.json
  web/           React NUI (src/) → build/index.html
  sql/           install.sql (reference; the resource migrates itself)
  docs/          ARCHITECTURE.md APPEARANCE.md CLOTHING.md CLOTHING_STATES.md BARBER.md
                 SURGERY.md SPAWN_RESPAWN.md NATIVES.md API.md TESTING.md
  tests/         python + lupa unit tests; web/tests for the NUI
```

Load order (fxmanifest): shared = `@w_lib/init.lua`, `config/*.lua` (main first), then `shared/`
in the order listed above. Client = natives → core → appearance → camera → scene → editor →
domains → api. Server = `@oxmysql/lib/MySQL.lua` → bridge → core → appearance → characters →
scene → domains → api.

---

## 3. Global modules and their APIs

All functions return plain values unless stated; "Result" means a `WCResult` table (§4).

### 3.1 Shared

**`WCUtil`**: `copy(v)`, `deepEqual(a,b)`, `isFinite(n)`, `number(v, lo, hi, fallback)` (NaN/inf →
fallback, clamps), `int(v, lo, hi, fallback)`, `decode(v)` (JSON string|table → table, never throws),
`encode(v)`, `sortedKeys(t, cmp?)`, `trim(s)`, `utf8len(s)`, `round2(n)` (cents),
`u32(h)` (`h & 0xffffffff`, accepts signed), `waitUntil(fn, timeoutMs, stepMs?) -> value|nil`,
`clampString(s, maxChars)` (UTF-8 aware), `jsonSize(v)` (bytes of the encoded value).

**`WCResult` / `WCCodes`**: `WCResult.ok(data?)` → `{ok=true, code='OK', data=data}`;
`WCResult.fail(code, data?)` → `{ok=false, code=code, message=WCResult.messageKey(code), data=data}`;
`WCResult.messageKey(code)` → locale key; `WCResult.is(r)`. Codes are listed in §4.

**`WCDebug`**: `log(domain, fmt, ...)`, `warn(domain, fmt, ...)`, `enabled(domain?)`.

**`WCServices`**: `enabled(name) -> boolean` for names in `Config.Services` (§7.1). Unknown name → false.

**`WCLocations`**: `all()`, `byId(id)`, `byType(type)` (enabled + disabled), `active(type)` (only
enabled locations of an enabled service type), `isUsable(loc)` (location enabled AND its service
enabled), `anchor(loc)` → vector3 used for proximity checks. Locations are resolved once from
`Config.Locations` merged with `Config.LocationDefaults[type]` and validated (duplicate ids, missing
coords → warning + skipped).

**`WCMorph`**: `fields` (array `{id, expression, group, label, min=-1, max=1}` where `id` is the
w_lib expression name and `expression` the numeric id from `w.component.data.expressions`),
`groups` (ordered hierarchy §5.2), `byId[id]`, `byExpression[number]`, `sectionOf(id)` → `'face'|'body'`.

**`WCOverlays`**: `layers` (array `{id, library, ids, section, palette, sexes}`; `id` is the legacy
compType, e.g. `'blush'`), `byId[id]`, `sectionOf(id)` → `'skin'|'makeup'|'eyebrows'|'hair'|'facialHair'`.

**`WCCatalog`** (built lazily, cached per sex, never rebuilt per click):
- `forSex(sex)` → `{ [category] = { models = { [m] = { {hash, name}, ... } }, hashes = { [hash] = {model, variant, name} } } }`
- `resolve(sex, category, value)` → u32 hash or nil. Accepts a hash, `{hash=}`, or legacy `{model, variant}`.
- `item(sex, hash)` → `{category, model, variant, name}` or nil.
- `isClothing(category)`, `ESSENTIAL` (`heads, eyes, teeth, BODIES_UPPER, BODIES_LOWER`).
- `groupOf(category)` → `{group=<groupId>, sub=<subId>}` from `Config.Clothing.taxonomy`.
- `price(category, hash, pricingProfileId)` → number (server authoritative; base × profile multiplier, rounded to cents; `nil` = not for sale).
- `available(storeProfileId, sex, category, hash)` → boolean (store catalog filtering, §5.3).
- `tintable(category)` → palette list or nil; `validTint(category, tint)` → boolean.
- `colorKey(hashname)` → locale key for hair/beard colour names (e.g. `_BLONDE`).
- `styleLabel(category, model)` → translated `"<category label> <nn>"`.

**`WCRules`** (clothing compatibility engine): `conflicts[category]` → list, `requires[category]` →
list; `equip(equipped, category, hash)` → `newEquipped, removedCategories`;
`normalize(equipped)` → `equipped, violations` (drops conflicting/unsatisfied items deterministically);
`canRemove(category)`.

**`AppearanceSchema`** (§5.1 is the data shape):
- `VERSION = 3`
- `default(sex)` → complete valid v3 appearance.
- `normalize(raw)` → v3. Accepts a v3 table, a JSON string, or a legacy row
  `{isMale, components, faceFeatures, overlays}` (v1 `{model,variant}` arrays, v2 hashes). Never throws.
- `fromLegacy(row)` → `app, meta` where `meta = {defaultsUsed = {section,...}, version = <source version>}`.
- `toLegacy(app)` → `{isMale=0|1, components=<json>, faceFeatures=<json>, overlays=<json>}` (derived
  compatibility projection written alongside v3; see §6.1).
- `sanitize(app, opts)` → `app, violations` — validates every hash against `WCCatalog` for the sex,
  clamps numbers, drops unknown keys, enforces essentials and `WCRules`.
- `SECTIONS` = `identity, body, face, eyebrows, skin, eyes, hair, facialHair, makeup, clothing, states`.
- `mergeSections(saved, submitted, allowed)` → merged v3 (only `allowed` sections copied from
  `submitted`; everything else from `saved`), sanitized.
- `changedSections(a, b)` → set of section names that differ.
- `equal(a, b)`, `skinTone(app)`, `setSkinTone(app, tone)`, `setBodyType(app, model)`,
  `setHead(app, model)` (keeps tone), `equip(app, category, hash)` (uses `WCRules`).

**`WCGrooming`**: `state(app)`, `info(app)`, `advance(app, seconds) -> changed`, `cut(app, previous)`.

**`WCClothingStates`**: `groups` (ordered definitions, §5.5), `byId[id]`, `applicable(app, groupId)`,
`current(app, groupId)`, `actions(app)` → ordered `{group, parent, label, current, targets={...}}`,
`isValid(groupId, value)`.

**`WCIdentity`**: `validateName(s)` → `ok, cleaned|code`, `validateDob(s)` → `ok, dob|code, age`,
`validate(identity)` → `ok, cleanedIdentity|code`.

### 3.2 Client

**`WCNative`** (only place with raw invokes; §10): sub-tables `metaped`, `ped`, `clothing`, `camera`,
`respawn`, `scene`, `ui`.

**`WCState`**: `character` (`{charid, sex}` or nil), `appearance` (saved v3 of the local character),
`set(app)`, `get()`, `busy(name, value?)` (named client locks: `editor`, `selection`, `spawn`, `respawn`,
`clothingAction`), `inEditor()`.

**Locale helpers** (kept as globals for compatibility): `UiLocale()`, `UiDir()`, `OnLanguageChange(fn)`,
`TranslateTree(node)`.

**UI helpers** (kept globals): `WCurtain.show/hide`, `StartFade(ms, key)`, `EndFade(ms)`,
`DismissLoadingScreen()`, `SuppressGameHud()`, `SetCustomHudVisible(b)`, `SetWorldUiVisible(b)`.

**`Appearance`** (the one pipeline):
- `RestoreCharacter(ped, app, opts?)` → `ok, err`. Order: validate ped/model → preset → body →
  head/eyes/teeth → hair → facial hair → waist/height → morph → overlays → clothing (`applyOrder`, tints) →
  clothing states → one refresh → wait ready. `opts.skipStates`, `opts.skipOverlays`.
- `ApplyDiff(ped, before, after)` → incremental preview; falls back to `RestoreCharacter` when body,
  head or sex changes.
- `ApplyComponent(ped, category, hash, tint?)`, `RemoveCategory(ped, category)`, `Refresh(ped)`.
- `SetPlayerModel(sex)` → `ok, err` (timeout, never applies to a stale handle).
- `RestorePlayer(app?)` → sets model if needed and restores the local player's ped (default
  `WCState.appearance`).

**`WCCamera`**: `open(ped, preset?)`, `focus(preset, force?)`, `rotate(deg)`, `zoom(delta)`,
`reset()`, `pick(x, y, aspect)` → preset|nil, `current()`, `close()`. Presets (§8.6).

**`CreatorScene`** (preview peds): `isolate()`, `create(model, coords, app)`, `position(ped, coords)`,
`ready(ped)`, `show(ped)`, `destroy(ped)`, `cleanup()`.

**`WCPreviewEnv`**: `enter(opts)` / `exit()` — controls, HUD, weapon holstering, time/weather,
freezing; `exit` restores everything `enter` changed. Idempotent.

**`WCEditor`** — the one appearance editor session (creator, surgery, barber, store, wardrobe):
- `open(ped, mode, app, opts)` → `ok, err`. `opts`:
  `title` (locale key), `subtitle?`, `sections` (set of allowed `AppearanceSchema` sections),
  `context` (mode data: `owned`, `ownedTints`, `storeProfile`, `pricing` (server-sent price table),
  `location`, `growth`, `outfits`, `maxOutfits`, `startingClothing`), `identity?` (creator only),
  `onCommit(working, extra) -> Result` (called on Save; must be synchronous-yielding; on `ok` the
  editor closes), `onCancel()`, `camera` (initial preset).
- `close()`, `session()`, `refresh()` (rebuild tree and push), `working()`, `saved()`, `dirty()`.

**`WCPanel`** — lightweight tree panel without scene/camera (clothing actions):
`open(spec)` where `spec = {title, build() -> tree, onControl(control, value) -> Result, onClose()}`,
`refresh()`, `close()`, `isOpen()`.

**`WCClothing`** (clothing state controller): `perform(groupId, target)` → Result, `available()`,
`applyStates(ped, app)`, `openPanel()`.

**`WCSpawn`**, **`WCRespawn`**: see §11–§12.

**Domain entry points** (client): `WCStore.open(locationId)`, `WCWardrobe.open(locationId?)`,
`WCBarber.open(locationId)`, `WCSurgery.open(clinicId)` — each returns immediately if another
session/editor/scene is active, requests the matching `<kind>:open` callback and drives §17.

### 3.3 Server

`Bridge` (framework layer, kept), `CreatorLogs` (optional logger, kept).

**`WCMigrations`**: `register(id, fn)`, `run()` (called once on `w.database.ready`), `columnExists(t, c)`,
`tableExists(t)`. Applied ids are stored in `w_creators_migrations`.

**`WCSecurity`**: `rate(src, key, max, windowMs) -> boolean`, `payload(value, maxBytes) -> boolean`,
`lock(key) -> boolean` / `unlock(key)`, `violation(src, kind, detail)` (logs `security_violation`),
`near(src, coords, radius) -> boolean`.

**`WCEconomy`**: `charge(src, amount, reason)` → Result (`INSUFFICIENT_FUNDS`, `INVALID_PRICE`),
`refund(src, amount, reason)` → boolean, `withCharge(src, amount, reason, persistFn)` → Result
(charge → `pcall(persistFn)` → refund on failure; never double-charges).

**`WCSessions`** — the one server-side preview transaction:
- `open(src, kind, opts)` → Result(`{token, session}`). `kind ∈ store|wardrobe|barber|surgery`.
  Checks: service enabled, character active, no other open session, appearance not locked, location
  usable and player within `interactionRadius + 3` of its anchor (unless `opts.remote` and the kind
  allows remote), rate limit. Stores `snapshot` (saved appearance), `location`, `expires`.
- `get(src, token)` → session | nil, code.
- `commit(src, token, opId, fn)` → Result. Serialises per character (`CreatorAppearanceLocks`), marks
  busy, replays the cached Result for a repeated `opId`, runs `fn(session)` in `pcall`, closes the
  session on success.
- `close(src, token)`, automatic expiry, `playerDropped` cleanup, `onResourceStop` cleanup.

**`WCAppearanceRepo`**: `load(charid)` → `app, meta` (lazy v3 upgrade §6.2), `save(charid, app, extra?)`
(one transaction; `extra` = additional `{query, values}` pairs), `create(charid, identity, app, extra?)`,
`delete(charid)`, `cache` (per active character).

**`WCCharacters`**: `active(src)` → `{charid, sex}`, `setActive(src, charid, sex)`, `clear(src)`.

**`WCSync`**: `broadcast(src, app)`, `broadcastState(src, group, value)`, `forget(src)`.

**`WCOwnership`**: `list(charid)` → `{[hashString] = {category, palette, tint0, tint1, tint2, source}}`,
`owns(charid, hash)`, `grantQueries(charid, items, source)` → queries for a transaction, `tintOf(...)`.

**`WCOutfits`**: CRUD (§5.6).

---

## 4. Result contract and error codes

Every callback returns `WCResult`. The client translates `message` (a locale key) only at the UI boundary.

```
OK
INVALID_PAYLOAD  RATE_LIMITED  BUSY  SERVICE_DISABLED  LOCATION_DISABLED  LOCATION_NOT_FOUND
TOO_FAR  SESSION_EXPIRED  SESSION_NOT_FOUND  NO_CHARACTER  NO_CHANGES
CHARACTER_NOT_FOUND  NOT_CHARACTER_OWNER  CHARACTER_SLOT_LIMIT  CREATION_NOT_GRANTED
INVALID_NAME  INVALID_DOB  DELETE_CONFIRMATION_REQUIRED  DELETE_DISABLED  CREATION_DISABLED
INVALID_COMPONENT  COMPONENT_NOT_AVAILABLE  ITEM_NOT_OWNED  INVALID_TINT  CONFLICTING_ITEMS
INSUFFICIENT_FUNDS  INVALID_PRICE
STORE_DISABLED  BARBER_DISABLED  SURGERY_DISABLED  SURGERY_NOT_ALLOWED  WARDROBE_DISABLED
OUTFITS_DISABLED  OUTFIT_LIMIT  OUTFIT_NOT_FOUND  INVALID_OUTFIT_NAME
STATE_NOT_SUPPORTED  STATE_NOT_APPLICABLE  ACTIONS_DISABLED
INVALID_SPAWN  SPAWN_NOT_PENDING
DATABASE_ERROR  INTERNAL_ERROR
```

---

## 5. Data model

### 5.1 Appearance v3 (the one authoritative shape)

```lua
app = {
  version = 3,
  sex = 'male' | 'female',                 -- model = 'mp_' .. sex
  body = { upper = <u32 BODIES_UPPER>, lower = <u32 BODIES_LOWER>,
           height = 0.9..1.1 (float),      -- ped scale
           weight = 1..21 (int) },         -- waist type index into WAIST_TYPES
  head = { head = <u32 heads>, eyes = <u32 eyes>, teeth = <u32 teeth> },
  morph = { [expressionName] = -1.0..1.0 },   -- face AND body morphology, one map; 0 values omitted
  hair = { style = <u32 hair | 0>, facial = <u32 mustache | 0> },   -- facial = 0 for female
  overlays = { [layerId] = { style = 1..N, color = 1..64, opacity = 0..1 } }, -- absent = off
  clothing = {
    equipped = { [category] = <u32> },     -- clothing categories only (no body parts)
    tints    = { [category] = { palette = <palette name>, tint0 = 0..254, tint1 = 0..254, tint2 = 0..254 } },
    states   = { [stateGroupId] = <state value> },   -- runtime clothing states that persist
    outfit   = <outfit id | nil>,
  },
  grooming = { hair = { stage, seconds }, beard = { stage, seconds } },  -- server-owned
}
```

Section → fields map (used by `mergeSections` and by domain permissions):

| Section | Fields |
|---|---|
| `body` | `body.upper`, `body.lower`, `body.height`, `body.weight`, body morph fields |
| `face` | `head.head` (base head), face morph fields (includes eye/eyebrow *shape* morphs) |
| `eyebrows` | overlay `eyebrows` |
| `skin` | skin tone (the `_V_nnn` variant of head + bodies), overlays of section `skin` |
| `eyes` | `head.eyes` |
| `hair` | `hair.style`, overlay `hairov` |
| `facialHair` | `hair.facial`, overlay `beardstabble` (male only) |
| `makeup` | overlays of section `makeup` |
| `clothing` | `clothing.equipped`, `clothing.tints`, `clothing.outfit` |
| `states` | `clothing.states` |
| teeth | `head.teeth` belongs to `face` |

Skin tone is not a separate stored value: it is the shared `_V_nnn` variant of `heads`, `BODIES_UPPER`,
`BODIES_LOWER`. `setSkinTone` rewrites all three; `sanitize` repairs mismatched tones by adopting the head's.

### 5.2 Morphology hierarchy (creator/surgery tree)

```
Face
 ├─ Base head (heads model)            ├─ Eyes      eyesDistance eyesHeight eyesAngle eyesDepth
 ├─ Head shape  headWidth faceWidth    │            eyelidWidth eyelidHeight eyelidLeft eyelidRight  (+ Eye colour → section eyes)
 ├─ Jaw     jawWidth jawHeight jawDepth jawY
 ├─ Chin    chinWidth chinHeight chinDepth         ├─ Eyebrows  eyebrowWidth eyebrowHeight eyebrowDepth (+ eyebrow overlay → section eyebrows)
 ├─ Nose    noseWidth noseHeight noseSize noseAngle noseCurvature nostrilsDistance
 ├─ Cheeks  cheekbonesWidth cheekbonesHeight cheekbonesDepth
 ├─ Mouth   mouthWidth mouthDepth mouthX mouthY
 │    ├─ Left corner   mouthConerLeftWidth/Depth/Height/LipsDistance
 │    └─ Right corner  mouthConerRightWidth/Depth/Height/LipsDistance
 ├─ Lips    ├─ Upper lip upperLipWidth upperLipHeight upperLipDepth
 │          └─ Lower lip lowerLipWidth lowerLipHeight lowerLipDepth
 ├─ Ears    earsWidth earsHeight earsAngle earsDepth earlobes
 └─ Teeth (teeth component)
Body
 ├─ Build: Body type (BODIES_UPPER model) · Height · Weight
 ├─ Upper body  shoulders shoulderThickness shoulderBlades chest arms
 ├─ Torso       waist hip
 ├─ Legs        thighs calves
 └─ Neck        neckWidth neckDepth
```

Only the 61 w_lib-named expressions exist; nothing else is exposed. The NUI shows values as −100…+100
(`display.scale = 100`); storage is −1…1.

### 5.3 Clothing taxonomy (store, wardrobe, creator clothing stage)

`Config.Clothing.taxonomy` is an ordered list of groups; each group an ordered list of
subcategories; each subcategory owns **exactly one** catalog category (a category appears once):

```
Head         Hats(hats) · Masks(masks) · Eyewear(eyewear)
Neck         Bandanas & neckerchiefs(neckwear) · Ties(neckties)
Upper body   Shirts(shirts_full) · Vests(vests) · Coats(coats) · Closed coats(coats_closed)
             Ponchos(ponchos) · Cloaks(cloaks) · Dresses(dresses, female) · Armour(armor)
Arms & hands Gloves(gloves) · Gauntlets(gauntlets) · Bracelets(jewelry_bracelets)
             Rings — left(jewelry_rings_left) · Rings — right(jewelry_rings_right)
Lower body   Pants(pants) · Skirts(skirts, female) · Chaps(chaps) · Leg accessories(legs_acessories)
Feet         Boots(boots) · Spats(spats) · Boot accessories & spurs(boot_accessories)
Accessories  Suspenders(suspenders) · Belts(belts) · Buckles(belt_buckles) · Gun belts(gunbelts)
             Gun belt accessories(gunbelt_accs) · Holsters(holsters_left) · Loadouts(loadouts)
             Satchels(satchels) · Badges(badges) · Other accessories(accessories)
```

A subcategory is shown only if the catalog has items for the character's sex **and** (in a store) the
store profile has at least one available item. Every subcategory has an `order`, a `camera` preset and an
`art` glyph where one exists. `Config.Clothing.storeProfiles[id] = { include = {categories...}|'*',
exclude = {...}, models = {[category] = {min, max}}? }` filters items per store. `pricingProfiles[id] =
{ multiplier = 1.0 }`.

### 5.4 Tints

`Config.Clothing.tints = { enabled = true, price = 2.5, palettes = { [category] = {palette names} },
default = {palette names} }`. A tint is `{palette, tint0, tint1, tint2}` with integers 0..254. Store
purchases may tint (charged `tints.price` when the tint differs from the item's owned tint). The owned
row (`w_creators_clothes`) stores the item's tint; the wardrobe applies the owned tint and cannot change it.

### 5.5 Clothing states

`Config.ClothingStates.groups` (ordered; each `verified = 'likely'|'experimental'`, `persist`):

| Group | Parent (UI) | Category | Values | Mechanism |
|---|---|---|---|---|
| `hat` | Head › Hat | `hats` | `on`/`off` | visibility (remove/re-apply the equipped hash) |
| `eyewear` | Head › Eyewear | `eyewear` | `on`/`off` | visibility |
| `mask` | Head › Mask | `masks` | `on`/`off` | visibility |
| `bandana` | Neck › Bandana | `neckwear` | `down`/`up` | wearable state `base`/`mask_up` |
| `sleeves` | Upper body › Shirt | `shirts_full` | `down`/`rolled` | wearable state (w_lib sleeve roll) |
| `collar` | Upper body › Shirt | `shirts_full` | `closed`/`open` | wearable state (w_lib collar) |
| `coat` | Upper body › Coat | `coats`/`coats_closed` | `on`/`off` | visibility |
| `vest` | Upper body › Vest | `vests` | `on`/`off` | visibility |
| `poncho` | Upper body › Poncho/Cloak | `ponchos`/`cloaks` | `on`/`off` | visibility |
| `gloves` | Arms & hands › Gloves | `gloves` | `on`/`off` | visibility |
| `boots` | Feet › Boots | `boots` | `over`/`under` | wearable state `base`/`under_pants` (requires pants) |

An action is offered only when its category is equipped **and** the target differs from the current
state. Owned/equipped items are never removed by a state change: `off` hides the component on the ped;
`clothing.equipped` is unchanged.

### 5.6 Owned items and outfits

- **Owned item** — `w_creators_clothes(charid, hash, category, palette, tint0..2, source, acquired_at)`,
  unique `(charid, hash)`. Sources: `store`, `starter`, `legacy`, `admin`.
- **Equipped item** — `app.clothing.equipped`.
- **Runtime state** — `app.clothing.states`.
- **Outfit** — `w_creators_outfits(id, charid, name, data, created_at, updated_at)` where `data =
  {equipped = {[category] = hash}, states = {...}}` — references to owned hashes only (tints come
  from ownership). Limit `Config.Wardrobe.maxSavedOutfits`. Equipping validates ownership at equip time.

### 5.7 Database (additive, versioned migrations; nothing is dropped)

| Migration id | Change |
|---|---|
| `001_base_tables` | `characters_appearence`, `w_creators_clothes` (existing DDL, `IF NOT EXISTS`) |
| `002_appearance_v3` | `characters_appearence` + `appearance LONGTEXT NULL`, `appearance_version INT NOT NULL DEFAULT 2`, `updated_at TIMESTAMP NULL` |
| `003_clothes_meta` | `w_creators_clothes` + `source VARCHAR(16) NULL`, `acquired_at TIMESTAMP NULL` |
| `004_outfits` | `w_creators_outfits` |

`ADD COLUMN IF NOT EXISTS` is MariaDB-only; migrations check `information_schema.COLUMNS` first.

---

## 6. Persistence

### 6.1 Storage
The v3 appearance is stored in `characters_appearence.appearance` (JSON) with `appearance_version = 3`.
The legacy columns `isMale / components / faceFeatures / overlays` are rewritten in the same `UPDATE`
from `AppearanceSchema.toLegacy(app)` as a **derived compatibility projection** (so a rollback to the
previous release still loads the character). They are never read when `appearance_version >= 3`.

### 6.2 Lazy upgrade
`WCAppearanceRepo.load(charid)` reads the newest row for the charid. If `appearance_version < 3` or
`appearance` is NULL/corrupt: `fromLegacy(row)`. If the legacy decode needed **no** defaults for
essential parts, the upgraded v3 is written back (plus `legacy` ownership grants for the equipped
clothing, `INSERT IGNORE`) in one transaction. If defaults were needed the row is **not** written
(data is never silently replaced); the in-memory appearance uses the defaults and a warning is logged.
Console command `wc_migrate_appearances` upgrades all rows in batches (console only).

### 6.3 Identity
`firstname`, `lastname`: 2..25 UTF-8 characters each, letters (Latin incl. Latin-1 letters, Arabic
U+0621–U+064A, U+066E–U+06D3), space, apostrophe, hyphen; no leading/trailing/double spaces.
`dob`: `YYYY-MM-DD`, a real calendar date, age between `Config.Characters.identity.minAge` and `maxAge`
relative to `referenceYear` (nil = current real year). `sex` comes from the server-granted creation
session (the gender the player picked), not from free text.

### 6.4 Transactions
Every commit that changes more than one row uses `w.database.transaction.await(queries)`. Money is
charged **before** the transaction and refunded if the transaction fails (`WCEconomy.withCharge`).

---

## 7. Configuration

```
config/main.lua       Config.Debug, Config.Framework, Config.Services, Config.Characters,
                      Config.Creator, Config.Scene, Config.Experimental, Config.Keys, Config.Admin
config/locations.lua  Config.LocationDefaults, Config.Locations
config/clothing.lua   Config.Clothing (taxonomy, prices, tints, storeProfiles, pricingProfiles,
                      applyOrder, rules), Config.ClothingStates
config/barber.lua     Config.Barber (services, prices), Config.Grooming
config/surgery.lua    Config.CosmeticSurgery
config/wardrobe.lua   Config.Wardrobe
config/spawn.lua      Config.Spawn (selector, points, lastLocation, bounds, camera), Config.Respawn
config/outfits.lua    Config.StartingOutfits, Config.Creator.startingClothing
```

### 7.1 Service toggles (`Config.Services`)
`characterCreation, characterDeletion, clothingStores, barbers, surgery, wardrobe, savedOutfits,
clothingActions, spawnSelector, lastLocation, deathRespawn`. A disabled service: no prompts, no blips,
no NPCs, **and** every server callback of that service returns `*_DISABLED`/`SERVICE_DISABLED`.

### 7.2 Locations (`Config.Locations`)
```lua
{ id = 'valentine_clothing', type = 'clothing'|'barber'|'surgery'|'wardrobe', enabled = true,
  label = '<locale key>', town = '<locale key>',
  coords = vector3, interactionRadius = 2.0,
  npc = { model = 'S_M_M_Tailor_01', coords = vector4 } | false,
  blip = { sprite = 'blip_shop_clothing', label = '<key>' } | false,
  prompt = true,                          -- false = another resource provides the interaction (surgery → w_ambulancejob)
  preview = vector4 | nil,                -- fitting stand / chair: where the player stands while editing
  camera = '<preset>' | nil,
  storeProfile = 'general', pricingProfile = 'standard',
  allowedServices = { hair = true, facialHair = true, details = true } | nil,   -- barber
  hours = { open = 6, close = 22 } | nil }                                      -- availability rule
```
Adding a shop is a config edit only.

---

## 8. NUI contract

The NUI is presentation only. Lua builds a tree; the NUI renders it with the existing components
(`MenuRow`, `Choice`, `Slider`, `FeaturePad`, header, section tabs, footer, confirmation modal) and
returns control ids.

### 8.1 Lua → NUI
```
{ type='editor',
  session = { id, mode, title, subtitle, locale, dir },
  strings = { ...all chrome strings, already translated... },
  stages  = [ {id, label, done?, disabled?} ] | nil,    -- creator/surgery wizard tabs
  tree    = Node,                                      -- root group
  price   = { total, lines = [{label, amount}] } | nil, -- server-derived; display only
  identity= { fields = [ {key, label, type:'text'|'date'|'info', maxLength?, min?, max?, value?} ] } | nil,
  dirty, canSave, saveLabel,
  confirm = { title, body, confirmLabel },             -- save confirmation copy (e.g. "Confirm procedure")
  camera  = '<preset>' }
{ type='editorClose' }
{ type='panel', session = {id, title, locale, dir}, strings, tree }   -- WCPanel
{ type='panelClose' }
{ type='charCard', show, name, age, dob, gender, lastLocation, job, cash, bank, gold, locale, dir, strings }
```
A new `session.id` resets the NUI navigation; the same id keeps the current path, search and
selection (UI category state memory).

### 8.2 Node
```
Node = {
  id, kind, label, hint?, art?, summary?, badge? ('owned'|'equipped'|'locked'|'new'), badgeLabel?,
  camera?, disabled?, reason?,                      -- reason = translated why disabled
  children?  (group),  searchable? (group: show search box over children),
  control?, value?,
  options?  = [{value, label, badge?}]              -- choice with explicit options
  range?    = {min, max, none?}                     -- choice with generated numeric options (none ⇒ option 0 = strings.none)
  min?, max?, step?, display? = {scale, decimals}   -- slider
  x?, y?    = {control, label, value}               -- pad (FeaturePad)
  item?     = {name, price?, owned?, equipped?, variants?}   -- itemcard
  danger?, actionLabel?                             -- action
  maxLength?, placeholder?                          -- text
}
kind ∈ group | choice | slider | pad | action | text | info | itemcard | review | identity
```

### 8.3 NUI → Lua (all respond `{ok, code?, message?, payload?, closed?}`)
- `editor:action` `{id, op, control?, value?, values?, identity?, opId}`
  - `op='set'` one control; `op='setMany'` `values = {[control] = value}` (pads, one undo step);
    `op='invoke'` action/text nodes; `op='undo'|'reset'|'random'`; `op='save'` (creator sends
    `identity`); `op='cancel'` (discard and close).
- `editor:camera` `{id, preset?|rotate?|zoom?|reset?|pick?}`
- `panel:action` `{id, control, value?}`, `panel:close` `{id}`
- One NUI action = one Lua operation: the NUI locks while a request is pending; Lua rejects
  concurrent ops per session (`BUSY`); the server rejects duplicate `opId`s.

### 8.4 Control ids
```
body.type  body.height  body.weight  morph.<expressionName>
face.head  skin.tone  eyes.color  face.teeth
hair.style hair.color facial.style facial.color
overlay.<layerId>.style|color|opacity
clothing.<category>.style|variant|palette|tint0|tint1|tint2|remove
starter.preset
outfit.<id>.equip|update|rename|delete   outfit.new.name  outfit.new.save
state.<groupId>.<value>
```
Lua validates every control id against the current session's registry and clamps every value.

### 8.5 Dirty state and loading
`dirty` = working ≠ saved. Back/Escape at the root with `dirty` opens the existing confirmation modal
with **Save / Discard / Cancel**; without changes it closes immediately. Every async op shows
idle → loading → success | error; a purchase is never shown as done before the server answers.

### 8.6 Camera presets
`fullBody, upperBody, lowerBody, head, face, eyes, hair, facialHair, hands, feet, accessories`.
Selecting a node applies its `camera`. Controls: drag = rotate, wheel = zoom, right-click = reset,
click = pick body part.

---

## 9. Domain flows

### 9.1 Character selection
```
connect → session started → playerSpawned (first login) → WCCharacters list (server) →
selector scene (isolated bucket, one preview ped) → select → server: ownership + lock →
Bridge.LoginCharacter → wait GetCharId == charid (timeout) → load appearance (repo) →
WCCharacters.setActive → client applyAppearance (RestorePlayer) → broadcast →
spawn selection (if enabled) → spawn → world
```
Preview: one preview ped at a time; the next ped is created before the previous is destroyed (no flash),
never the player ped. Switching characters mid-game (`/characters`, `Config.Characters.allowSwitch`)
is refused while dead, in an editor or in a session.

### 9.2 Creation
Server grant (`characters:beginCreate`: service enabled, slots available) → gender scene → editor
(mode `creator`, stages identity/body/face/skin/hair/facialHair(male)/makeup/clothing/review) →
`characters:create(token, identity, app)` → identity + appearance sanitize → `characterCreated`
event → `Bridge.RegisterCharacter` → appearance row + starter ownership (one transaction) → client
renders on the player ped → `creationReady` → spawn. Creation is free.

### 9.3 Service editors (store, wardrobe, barber, surgery)
```
prompt → client requests <kind>:open(locationId) → server WCSessions.open → client enters preview
(fitting stand / chair, isolated bucket only for store fitting rooms), opens WCEditor with the
server snapshot → changes are local previews only → Save → <kind>:commit(token, opId, working) →
server: session valid → mergeSections(snapshot-from-DB, submitted, allowedSections) → validate →
price (server) → WCEconomy.withCharge(persist) → broadcast → client RestorePlayer(result app)
Cancel / close / death / disconnect / resource stop → client restores the snapshot, server closes the session.
```
Sections per mode: store `clothing` (+ tints); wardrobe `clothing` (owned only), outfits, `states`;
barber `hair`, `facialHair`, and `eyebrows`/`makeup` if enabled in `Config.Barber.services.details`;
surgery per `Config.CosmeticSurgery.allow`; creator all.

### 9.4 Appearance sync (OneSync)
The server caches the last broadcast appearance per player. Clients keep a remote cache and a 1 s
scope watcher: when a player's ped handle appears or changes (entered scope, respawned), the cached
appearance is re-applied to that ped once. Clothing state changes broadcast `remoteClothingState`
(small) and update the cache. Own ped: the local client applies its own appearance; remote
application is skipped for our own server id.

---

## 10. Native wrapper policy

Every wrapper in `client/natives/*.lua` is annotated:

```lua
--- _APPLY_SHOP_ITEM_TO_PED
-- hash: 0xD3A7B003ED343FD9 · confidence: Verified (w_lib/jo_libs production use)
-- params: ped (entity), shopItemHash (u32), immediately (bool), isMultiplayer (bool), p4 (bool)
-- returns: nothing · limitations: ped must be a metaped and ready; category derived from the hash
-- tested models: mp_male, mp_female (community) · MP safe: yes · OneSync tested here: no (see TESTING.md)
```

Confidence levels (mirrored in `docs/NATIVES.md`): **Verified** (used by the existing working
resource or w_lib in production), **Likely** (documented and widely used by the RedM community,
not exercised by this resource before), **Experimental** (research-only; behind
`Config.Experimental.*`, default off), **Deprecated / Avoid**.

The MetaPed request lifecycle (`0xF97C34C33487D569`, `0x43E4DA469541A9C9`, `0xC0940AC858C1E126`,
`0x0BCD4091C8EABA42`, `0x3972F78A78B5D9DF`) is wrapped with timeout and guaranteed release but is
**Experimental** and not on the production path (players and preview peds are `mp_male`/`mp_female`
created by model, which is the verified path). `_SET_PLAYER_HAT_ACCESS` (`0xA0C683284DF027C7`) is
wrapped but not used for equip/remove. Category discovery natives (`0xA622E66EEE92A08D`,
`0xCCB97B51893C662F`) are used only by dev tooling.

---

## 11. Spawn

Spawn kinds: `initial` (new character), `login` (existing character), `switch` (character switch),
`death` (respawn service), `admin`. The client only ever sends a spawn point **id** (`'__last'` or a
`Config.Spawn.points[].id`); the server resolves coordinates. The permission to spawn is a one-shot
server grant (`SpawnPending`). Last location: read from the framework, rejected if non-finite, outside
`Config.Spawn.bounds` (x, y, z), inside the creator scene radius, or all-zero → falls back to the first
enabled point. Client safe spawn: request collision, wait with timeout, probe ground from above
(`GetGroundZAndNormalFor_3dCoord`), reject a probe more than 20 m from the target, fall back to the
configured point, place, unfreeze, fade in, then `w_creators:client:spawn` handlers (w_core) run.

## 12. Respawn

Client state machine `ALIVE → DYING → DEAD → RESPAWN_PENDING → RESPAWNING → ALIVE`, polled every
250 ms (not every frame). `exports.w_creators:Resurrect(coords, heading, reason)` is the single
resurrect entry (used by w_ambulancejob with a fallback when w_creators is stopped): it refuses a second
resurrect while `RESPAWNING`, resurrects through `WCNative.respawn.resurrect`, waits for the new ped,
then `Appearance.RestorePlayer()`. A watcher also restores the appearance after any external
resurrect (ped handle changed or dead → alive). Appearance never touches weapons/inventory.

## 13. Public API

Server exports: `GetCharacterAppearance(src)`, `GetAppearance(src)` (w_lib bridge compat:
`{skin, clothes, appearance}`), `SetClothes(src, clothes, overwrite)`, `SetSkin(src, skin, overwrite)`,
`ApplyCharacterAppearance(src)`, `OpenCosmeticSurgery({source, clinicId})`, `OpenClothingStore(src, id)`,
`OpenBarber(src, id)`, `OpenWardrobe(src, id?)`, `OpenSpawnSelector(src)`, `RespawnPlayer(src, pointId)`,
`GetActiveCharacter(src)`. Server event `w_creators:server:characterCreated(src)` (w_lib) fires before
the framework login of a new character.

Client exports: `OpenWardrobe(id?)` (kept), `OpenCosmeticSurgery(clinicId)`, `OpenClothingActions()`,
`GetCurrentOutfit()`, `GetAppearance()`, `GetEquippedCategory(category)`, `SetClothingState(group,
value)`, `ToggleHat()`, `ToggleBandana()`, `ToggleSleeves()`, `RemoveClothingCategory(category)`,
`RestoreClothingCategory(category)`, `RefreshAppearance()`, `Resurrect(coords, heading, reason)`,
`IsInCharacterScene()`.

Kept event names (compatibility): `PersonaCreatorHandler.applyCharacterAppearance`,
`w_creators:client:applyRemoteAppearance`, `w_creators:client:spawn`, `w_creators:client:selectSpawn`,
`W:CHARCREATION:starting` (server-granted only), `w_creators:server:spawnAt`.

## 14. Security model

Every net event / callback: rate limit, payload size cap, type checks, session/ownership checks,
catalog validation, service + location toggles, proximity. Specific rejections: arbitrary charid,
arbitrary component hash, client price (ignored — prices are never read from payloads), negative/NaN
values, duplicate purchases (`opId` + session busy + per-character lock), disabled stores/services,
surgery without funds or while disabled, another player's character, creating past the slot limit,
arbitrary spawn coordinates, incompatible components (sex/category), corrupt appearance payloads,
disconnect during purchase/surgery (nothing is written unless the commit completed), resource restart
during creator (client cleanup + server session cleanup).

## 15. Subsystem classification

| Subsystem | Class | Why |
|---|---|---|
| w_lib integration (component, pedTexture, prompt, callback, database, blip, entity) | KEEP | Verified in production; single dependency the server already owns |
| Bridge (VORP/RSG/QBR/w_core) | KEEP → moved to `server/bridge/framework.lua` | Works; framework-specific code stays isolated |
| Scene isolation & preview ped lifecycle | REFACTOR | Keep mechanics; gate the bucket events (A2/A3) |
| Camera | REFACTOR | One service with semantic presets |
| Appearance normalize/render | REFACTOR → v3 | Single morph map, ordered pipeline, batched refresh |
| Editor (Lua) | REPLACE payload builder | Flat category payload → hierarchical tree + control registry |
| Editor (React) visuals | KEEP | Visual identity preserved; logic reworked to render the tree |
| Store/barber server | REFACTOR | Generalised into `WCSessions` + domain commits |
| Grooming growth | REFACTOR | Same behaviour, in-memory accumulation (A14) |
| Multicharacter | REFACTOR | Locks, grants, identity, typed delete |
| Spawn selector | REFACTOR | Enabled/order flags, bounds validation, safe spawn |
| Sync | REFACTOR | Scope-aware (A13) |
| `/starting`, open isolation events | REMOVE | Exploitable (A1–A3) |
| `/spawnprop` | REMOVE from production (dev tools, off) | Unrelated to characters |
| `data/features.lua` raw ids | REPLACE | `shared/morphology.lua` |

---

## 16. Callback and event catalogue (binding)

All callbacks are `w.callback.register(name, function(src, ...) ... end)` on the server and
`w.callback.await(name, false, ...)` on the client; all return a `WCResult`. `data` fields listed
below are the `data` of an `ok` result. Every callback applies `WCSecurity.rate` and type checks.

### 16.1 Characters
| Callback | Args | `data` / behaviour |
|---|---|---|
| `w_creators:characters:list` | — | `{characters = [{charid, name, firstname, lastname, dob, age, sex, lastLocation, job, cash, bank, gold, appearance}], slots, canCreate, deletion = {enabled, holdTime, typed}}` — `lastLocation` is the locale key of the nearest spawn point label or nil |
| `w_creators:characters:select` | `charid` | ownership + per-player lock → `Bridge.LoginCharacter` → wait until `Bridge.GetCharId(src) == charid` (timeout 10 s) → load appearance. `{appearance}`; or `{needsAppearance = true, token, sex?}` when the character has no appearance row (repair path → creator in appearance-only mode) |
| `w_creators:characters:loaded` | — | valid only after a successful `select`/`create`; marks the character active (`WCCharacters.setActive`), broadcasts the appearance, then starts the spawn flow (grant + `w_creators:client:selectSpawn` or `w_creators:client:spawn`). `{spawn = 'selector'|'direct'|'event'}` |
| `w_creators:characters:beginCreate` | — | service `characterCreation` + free slot → one-shot grant. `{token}` |
| `w_creators:characters:create` | `token, identity {firstname, lastname, dob}, app` | grant valid → `WCIdentity.validate` (skipped for appearance-only repair) → `AppearanceSchema.sanitize` with creator sections; starting clothing restricted to `Config.Creator.startingClothing` → `TriggerEvent('w_creators:server:characterCreated', src)` → `Bridge.RegisterCharacter` → appearance row + `starter` ownership in one transaction. `{appearance, charid}` |
| `w_creators:characters:cancelCreate` | `token` | releases the grant |
| `w_creators:characters:delete` | `charid, confirmText?` | service `characterDeletion`; ownership; when `typedConfirmation`, `confirmText` must equal the character's full name. Deletes framework character + appearance + owned clothes + outfits |

### 16.2 Scene
| Callback | Args | Behaviour |
|---|---|---|
| `w_creators:scene:prepare` | — | isolates the player in bucket `src` **only if** the player has no active character, is switching characters (server-tracked), or holds a store session with a fitting room; records that w_creators set the bucket |
| `w_creators:scene:registerPed` | `netId` | unchanged checks (owner, model, distance from anchor, player isolated) |
| `w_creators:scene:release` | — | resets the bucket to 0 **only if** w_creators set it for this player |
Legacy net events `w_creators:server:isolate`, `PersonaCreatorHandler.setPlayerRoutingBucket`,
`PersonaCreatorHandler.setRoutingBucket`, `w_creators:server:rejoinWorld` map to the same guarded functions.

### 16.3 Spawn / respawn
| Name | Kind | Behaviour |
|---|---|---|
| `w_creators:spawn:choose` | callback `pointId` | requires `SpawnPending[src]`; `'__last'` needs `lastLocation` service + valid last position; otherwise an enabled point id. Resolves coords server-side, clears the grant, bucket 0, fires `w_creators:client:spawn(pos, {kind})`. Legacy event `w_creators:server:spawnAt` → same |
| `w_creators:client:selectSpawn` | server→client | `{last = {x,y,z,heading,label}|nil, points = [enabled point ids in order], kind}` |
| `w_creators:client:spawn` | server→client | `(pos {x,y,z,heading}, meta {kind = 'initial'|'login'|'switch'|'admin'})` — w_core listens to this name |
| `w_creators:client:respawn` | server→client | admin respawn `(pos, meta)` |

### 16.4 Service sessions
| Callback | Args | `data` |
|---|---|---|
| `w_creators:store:open` | `locationId` | `{token, appearance, owned, prices = {[category] = price}, tintPrice, storeProfile, pricingProfile, preview (vector4 table or nil), expiresIn}` |
| `w_creators:store:commit` | `token, opId, app` | `{appearance, charged, purchases = [{category, hash}]}` |
| `w_creators:wardrobe:open` | `locationId|nil` | `{token, appearance, owned, outfits = [{id, name, data}], maxOutfits, outfitsEnabled}` |
| `w_creators:wardrobe:commit` | `token, opId, app` | `{appearance}` |
| `w_creators:outfits:save` | `token, name, equipped, states` | `{outfit, outfits}` |
| `w_creators:outfits:update` | `token, id, equipped, states` | `{outfit, outfits}` |
| `w_creators:outfits:rename` | `token, id, name` | `{outfit, outfits}` |
| `w_creators:outfits:delete` | `token, id` | `{outfits}` |
| `w_creators:barber:open` | `locationId` | `{token, appearance, growth, services = {hair={enabled,price}, facialHair={enabled,price}, details={enabled,price,eyebrows,makeup}}, sections}` |
| `w_creators:barber:commit` | `token, opId, app` | `{appearance, charged}` |
| `w_creators:surgery:open` | `clinicId` | `{token, appearance, price, allow, sections}` |
| `w_creators:surgery:commit` | `token, opId, app` | `{appearance, charged}` |
| `w_creators:session:close` | `token` | always ok (idempotent) |
| `w_creators:client:sessionClosed` | server→client `(token, code)` | forced close (expiry, resource stop, death) → client restores the snapshot |

### 16.5 Appearance and clothing states
| Name | Kind | Behaviour |
|---|---|---|
| `w_creators:appearance:reload` | callback | rate-limited (1 / 10 s). `{appearance}` and re-broadcast |
| `PersonaCreatorHandler.reloadCharacterAppearance` | legacy net event | same as above |
| `w_creators:clothing:setState` | callback `group, value` | service `clothingActions`; group exists, value valid, applicable to the equipped items; persists when `persist`; broadcasts `w_creators:client:remoteClothingState`. `{states}` |
| `w_creators:client:applyAppearance` | server→client `(app)` | own appearance (alias `PersonaCreatorHandler.applyCharacterAppearance`) |
| `w_creators:client:applyRemoteAppearance` | server→client `(serverId, app)` | |
| `w_creators:client:remoteClothingState` | server→client `(serverId, group, value)` | |
| `w_creators:client:forgetRemote` | server→client `(serverId)` | on drop / character switch |
| `w_creators:client:grooming` | server→client `(app)` | hair/beard stage changed |
| `w_creators:client:openSurgery` / `openStore` / `openBarber` / `openWardrobe` | server→client `(locationId)` | server exports; the client then calls the matching `open` callback (which re-validates) |
| `w_creators:server:characterCreated` | server-local `(src)` | fired before the framework login of a new character (w_lib) |
| `w_creators:server:appearanceChanged` | server-local `(src, charid, kind)` | after any committed appearance change |

## 17. Client flows per domain (who calls what)

- **Selector** (`client/characters/selector.lua`): scene prepare → list → preview peds via
  `CreatorScene.create` (one at a time) → select/create/delete → on `select` ok:
  `WCState.set(app)`, `Appearance.RestorePlayer(app)`, then `characters:loaded`.
- **Creator** (`client/creator/creator.lua`): `beginCreate` → gender scene → `WCEditor.open(ped,
  'creator', AppearanceSchema.default(sex), {sections = all, identity = {...}, onCommit = create})` →
  on ok: `Appearance.SetPlayerModel(sex)`, `RestorePlayer(app)`, release scene, `characters:loaded`.
- **Store / wardrobe / barber / surgery**: `<kind>:open` → (store: fitting-room teleport + isolation;
  others: stay in place, frozen) → `WCPreviewEnv.enter` → `WCEditor.open(PlayerPedId(), mode, data.appearance,
  {sections, context, onCommit = <kind>:commit})` → on success `WCState.set(result.appearance)` +
  `Appearance.RestorePlayer`; on cancel/close/death/resource stop: `Appearance.RestorePlayer(snapshot)`,
  `session:close`, `WCPreviewEnv.exit`, leave fitting room.
- **Clothing actions** (`client/clothing/states.lua`): keybind/command/export → `WCPanel.open` with
  the tree from `WCClothingStates.actions(WCState.appearance)` → action: optional animation (timeout,
  cancel-safe) → apply locally → `clothing:setState` → on failure revert to the previous state.
- **Respawn** (`client/respawn/respawn.lua`): state machine; `Resurrect` export; post-resurrect
  `Appearance.RestorePlayer()`.
- **Locations** (`client/services/locations.lua`): builds prompts/blips/NPCs for every usable
  location of every enabled service type (`WCLocations.active`), dispatching to
  `WCStore.open(id)`, `WCWardrobe.open(id)`, `WCBarber.open(id)`, `WCSurgery.open(id)`; rebuilds on
  language change; removes everything on resource stop.
