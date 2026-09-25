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
   `locale(key, ...)`. The NUI receives already-translated strings. No hardcoded UI copy in JSX. The
   one exception is the header wordmark `WRAITH · CHARACTER STUDIO` (`web/src/brand.js`): a brand
   mark, shown as fixed Latin text in both languages as in the pre-v3 UI, not copy.
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
    editor/      tree.lua  editor.lua  panel.lua
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
  locales/       ar.json  en.json  (key-sorted; tests/test_locale_coverage.py checks every key the Lua uses)
  web/           React NUI (src/) → build/index.html
  sql/           install.sql (reference; the resource migrates itself)
  docs/          ARCHITECTURE.md (this contract) NATIVES.md NUI_CONTRACT.md TESTING.md
  tests/         python + lupa unit tests; web/tests for the NUI
```

Load order (fxmanifest): shared = `@w_lib/init.lua`, `config/*.lua` (main first), then `shared/`
in the order listed above. Client = natives → core → appearance → camera → scene → editor
(`tree.lua` before `editor.lua`: the editor builds with `WCEditorTree`) → domains → api. Server =
`@oxmysql/lib/MySQL.lua` → bridge → core → appearance (repository, sync) → characters → scene →
domains → spawn/respawn → dev → api. Every file the manifest lists exists and every Lua file on disk
is listed; the pre-v3 files (`bridge/`, `creator/`, `multichar/`, `spawnselect/`, `store/`,
`config.lua`, `data/*.lua`, `sql/characters_appearence.sql`) were removed in the final integration
(`sql/install.sql` is the reference schema).

---

## 3. Global modules and their APIs

All functions return plain values unless stated; "Result" means a `WCResult` table (§4).

### 3.1 Shared

**`WCUtil`**: `copy(v)`, `deepEqual(a,b)`, `isFinite(n)`, `number(v, lo, hi, fallback)` (NaN/inf →
fallback, clamps), `int(v, lo, hi, fallback)`, `decode(v)` (JSON string|table → table, never throws),
`encode(v)`, `sortedKeys(t, cmp?)`, `trim(s)`, `utf8len(s)`, `round2(n)` (cents),
`u32(h)` (`h & 0xffffffff`, accepts signed), `waitUntil(fn, timeoutMs, stepMs?) -> value|nil`,
`clampString(s, maxChars)` (UTF-8 aware), `jsonSize(v)` (bytes of the encoded value),
`today()` → `{year, month, day, hour}` | nil (the os library where the runtime has one — the server —
otherwise the date the server publishes in `GlobalState[WCUtil.TODAY_KEY]` (`'w_creators:today'`):
the RedM client has no os library, so client and shared code never read `os` directly). Shared date
rules use it: `WCIdentity.validateDob` leaves the age window to the server when the date is unknown
(its age is then nil), `WCLocations.hour()` is the published hour on the client.

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
- `tintable(category)` → palette list or nil; `validTint(category, tint)` → boolean (the live config: new edits);
  `validStoredTint(category, tint)` → boolean (structural only: a w_lib palette, integers 0..254; stored data).
- `colorKey(hashname)` → locale key for hair/beard colour names (e.g. `_BLONDE`).
- `styleLabel(category, model)` → translated `"<category label> <nn>"`.

**`WCRules`** (clothing compatibility engine): `conflicts[category]` → list, `requires[category]` →
list; `equip(equipped, category, hash)` → `newEquipped, removedCategories`;
`normalize(equipped)` → `equipped, violations` (drops conflicting/unsatisfied items deterministically);
`canRemove(category)`.

**`AppearanceSchema`** (§5.1 is the data shape):
- `VERSION = 3`
- `WAIST_TYPES` — the 21 waist-type metaped outfit hashes (signed); `body.weight` is the 1-based
  index. The one list for both sides: `Appearance.WAIST_TYPES` (client renderer) and
  `WCApi.WAIST_TYPES` (server `bodyWeight`) are this table.
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

**`WCClothingStates`**: `groups` (ordered definitions, §5.5), `byId[id]`, `applicable(app, groupId, keepHidden?)`,
`current(app, groupId)`, `actions(app)` → ordered `{group, parent, label, current, targets={...}}`,
`isValid(groupId, value)`.

**`WCIdentity`**: `validateName(s)` → `ok, cleaned|code`, `validateDob(s)` → `ok, dob|code, age`,
`validate(identity)` → `ok, cleanedIdentity|code`.

### 3.2 Client

**`WCNative`** (only place with raw invokes; §10): sub-tables `metaped`, `ped`, `clothing`, `camera`,
`respawn`, `scene`, `ui`.

**`WCState`**: `character` (`{charid, sex}` or nil), `appearance` (saved v3 of the local character),
`set(app)` (stores a copy, keeps `character.sex` in step), `get()` (copy), `setCharacter(charid, sex)`,
`clear()`, `busy(name)` → held?, `busy(name, true)` → acquired? (false when already held),
`busy(name, false)` releases (named client locks `LOCKS`: `editor`, `selection`, `spawn`, `respawn`,
`clothingAction`, `service` — a store / wardrobe / barber / surgery visit from its first check until
the player is back), `inEditor()` (the `editor` lock is held or `WCEditor.session()` exists).

**Locale helpers** (kept as globals for compatibility): `UiLocale()` (`'ar'|'en'`), `UiDir()`,
`OnLanguageChange(fn)`, `TranslateTree(node)` (copy; translates name, subTitle, title, label, hint,
summary, badgeLabel, reason, actionLabel, placeholder, xLabel/yLabel). `w_lib:setLocale` reloads the
dictionary and runs every refresher in `pcall`.

**UI helpers** (kept globals): `WCurtain.show(key)/hide()`, `WCurtain.held()` (true while a loading
curtain or a screen fade raised by this resource is up), `WCurtain.restore(force?)` (fade in + lower
the curtain when held, always with `force`; the resource-stop handler uses it so an interrupted
transition never leaves the screen black), `StartFade(ms, key)`, `EndFade(ms)` (condition waits with a
timeout), `DismissLoadingScreen()`, `SuppressGameHud()`, `SetCustomHudVisible(b)`, `SetPlayerHudVisible(b)`
(the w_hud show flag plus its stement gate: the one that holds for a player in play, whose show flag
w_hud's own tick sets back), `SetWorldUiVisible(b)`.

**`Appearance`** (the one pipeline):
- `RestoreCharacter(ped, app, opts?)` → `ok, err, failedCategories`. It never throws: callers check
  `ok`. Two restores of the same ped never overlap. Order: validate ped/model → preset 3 → commit →
  strip clothes → body → head/eyes/teeth → hair → facial hair (category `0xF8016BCA`) → waist
  (`EquipMetaPedOutfit(WAIST_TYPES[weight])`) / height → clothing (`applyOrder`, tints) → clothing
  states (every group, including default values; an equipped group that cannot apply — e.g. boots
  `under` without pants — is reset to base) → **body commit** → morph → one final refresh → wait ready
  → overlays (`w.pedTexture` whole-set overwrite on the committed head, no further refresh). Three
  structural commits per restore, none per feature (A11). `opts.skipStates`, `opts.skipOverlays`.
  Error codes (pipeline-internal, not `WCResult` codes): `INVALID_PED`, `INVALID_PAYLOAD`,
  `MODEL_MISMATCH`, `NOT_READY`, `BUSY`, `INTERNAL_ERROR`. A ped that never becomes ready costs at
  most 2 × `READY_TIMEOUT`.
- `ApplyDiff(ped, before, after)` → `ok, failedCategories, err` — incremental preview; falls back to
  `RestoreCharacter` when the sex, `body.upper`/`body.lower` or `head.head` changes; no refresh when
  nothing changed or only overlays changed; a waist change commits and then re-sets every morph
  channel; a state group is re-applied when its required item changed or its applicability changed.
- `ApplyComponent(ped, category, hash, tint?)` → `ok, err`, `RemoveCategory(ped, category)`,
  `Refresh(ped, timeout?)`, `ApplyClothingState(ped, app, groupId, value)` → `ok, err`
  (`STATE_NOT_SUPPORTED`, `INVALID_PAYLOAD`, `STATE_NOT_APPLICABLE`, `INVALID_PED`; no refresh).
- `SetPlayerModel(sex)` → `ok, err` (`INVALID_PAYLOAD`, `MODEL_TIMEOUT`; never applies to a stale handle).
- `RestorePlayer(app?, opts?)` → sets the model if needed and restores the local player's ped
  (default `WCState.appearance`); calls are serialised.
- Helpers: `IsReady(ped)` (render-ready **and** head bone more than `MIN_HEAD_DISTANCE` = 0.2 m from the
  entity origin, so a lying ped is ready and a collapsed skeleton is not), `WaitReady(ped, ms)`,
  `SetWaist`, `SetHeight`, `ApplyMorph`, `IsPlayerApplying()`; constants `WAIST_TYPES`,
  `FACIAL_HAIR_CATEGORY`, `PRESET`, `READY_TIMEOUT`.
- `Appearance.Overlays`: `payload(layerId, o, sex)`, `build(app)`, `apply(ped, app)`, `applied(ped)`,
  `forget(ped)`, `reset()`.
- `Appearance.Sync` (§9.4): `set`, `get`, `forget`, `state`, `check`, `tick`, `applyOwn(app)`,
  `applyingOwn()`, `INTERVAL = 1000`, `MAX_FAILURES = 5`. Own-appearance events
  (`w_creators:client:applyAppearance`, its legacy alias, and `w_creators:client:grooming`) store the
  appearance in `WCState` and render it unless an editor is open (the newest queued payload wins).
  "Is the local player being rendered" = `Appearance.IsPlayerApplying() or Appearance.Sync.applyingOwn()`.

**`WCCamera`**: `open(ped, preset?)`, `focus(preset, force?)`, `rotate(deg)` (turns the actor; the
view direction stays), `zoom(delta)`, `height(delta)`, `reset()` (→ `fullBody`), `pick(x, y, aspect)`
→ preset|nil (`PICK`: eyes→`eyes`, head→`head`, body→`upperBody`, pant→`lowerBody`, boot→`feet`),
`current()`, `isOpen()`, `ped()`, `close()` (destroys both cameras, clears focus). Presets §8.6 plus
`selection`; the pre-v3 names `default/body/pant/boot` still resolve.
`anchor(ped, { heading, set, hold })` sets how the next `open` of that ped frames it: the viewing
direction from `heading` (the actor is turned to it and held there for `hold` ms, never against a
`rotate` / `pose`), and a framing set of `SETS` (`currentSet()` answers it). The clothing store and the
wardrobe (`WCServiceFlow`) anchor on the fitting stand's heading (the wardrobe: the player's own) with
`SETS.shop`, the Jump On store's ped-relative framings; every other open uses the §8.6 presets.
`clearAnchor()` drops an anchor no open took (the flow's editor did not open), so it never frames the
next open of the player (a barber's chair) from the store's stand.

**`CreatorScene`** (preview peds and the creator room; returns values, never throws): `load()` →
arrived? (teleport retried every `TELEPORT_RETRY` = 250 ms; records the room maps it requested),
`isolate()` → `ok, code` (server `scene:prepare`), `release(opts?)` (`{keepBucket, unload}`: releases the
server bucket this client isolated itself into unless `keepBucket`; `unload = true` also unloads the
room maps — the final exit of the selector/creator passes it), `unload()` → count (removes only the maps
`load()` requested, `RemoveIplByHash`, fallback `RemoveImap`), `create(model?, coords, app)` → `ped` |
`nil, err` (the ped is deleted on any failure), `position(ped, coords)` → `ok, err`, `ready(ped, ms)`,
`show(ped)`, `destroy(ped)`, `cleanup()` → count, `arm(ped, sex)`, `idle(ped, sex)`, `drawLights()`,
`peds()`, `coords(c)`, `isLoaded()`, `isIsolated()`. On resource stop the room maps are unloaded unless
the player is still inside the room.

**`WCPreviewEnv`**: `enter(opts)` / `exit()` — symmetric and idempotent; `active()`, `changes()`.
`opts`: `ped`, `controls`, `hud`, `worldUi`, `holster` (`HidePedWeapons`; `exit` does not re-draw),
`freeze`, `invincible`, `clearTasks`, `coords` (restored on exit), `time`, `weather`. One per-frame
thread runs only while active. `hud` hides the w_hud HUD (`SetPlayerHudVisible`) for the whole visit,
whatever the radar shows, and `exit()` gives it back first (a w_hud restarted mid-visit is hidden
again); the radar wish is turned off and back on only when the radar was shown. `exit()` never calls
`DisplayRadar` (the radar belongs to `w.setRadarVisible`). On resource stop: exit, NUI focus off, camera closed, and the player unfrozen /
made visible / HUD restored only if a w_creators flow was holding them.

**`WCEditor`** — the one appearance editor session (creator, surgery, barber, store, wardrobe):
- `open(ped, mode, app, opts)` → `true` | `false, code` (`BUSY` — an editor is open or being opened,
  `INVALID_PAYLOAD`, `INVALID_COMPONENT` — the `opts.render` first render failed, `INTERNAL_ERROR` —
  the first payload could not be built; everything taken is rolled back). Takes the `WCState`
  `editor` lock (released on close only if this session took it) and closes an open `WCPanel`.
  `opts`: `title` (locale key), `subtitle?`, `sections` (list or set of allowed `AppearanceSchema`
  sections; domain modules pass the server's `data.sections` unchanged), `context` (mode data, passed
  unchanged from the `<kind>:open` result: `owned`, `ownedTints`, `prices`|`pricing`,
  `pricingProfile`, `tintPrice`, `storeProfile`, `outfits`, `maxOutfits`, `outfitsEnabled`, `growth`,
  `services`, `multiplier`, `visitCap`, `price`, `startingClothing`), `identity?` (creator only;
`{sex, locked = false}` for a new character; `{sex, locked = true, firstname, lastname, dob}` shows the
framework identity read-only and never submits it — the repair path; the date field's min/max come
from `referenceYear` or `WCUtil.today()` and are left out when the date is unknown),
  `onCommit(working, {opId, identity}) -> Result` (called on Save; synchronous-yielding; on `ok` the
  editor closes; the `opId` is reused while the working appearance and identity are unchanged and the
  last answer was uncertain — `INTERNAL_ERROR`, `BUSY`, a throw or a non-Result), `onCancel()`,
  `onOutfit(op, id, value, session) -> Result` (§5.6: `'equip'` is a **veto hook** — `nil` or an ok
  Result lets the editor apply the owned outfit locally, a failed Result refuses it; `'update'`,
  `'rename'`, `'delete'`, `'save'` call the server; a returned `data.outfits` replaces
  `context.outfits`), `onState(group, value) -> Result`, `camera` (initial preset), `saveLabel`,
  `render` (render `app` on the ped first).
- `close()` (no restore), `session()`, `isOpen()` (open or opening), `refresh()` (rebuild tree and
  push), `working()`, `saved()`, `dirty()`, `touchedCategories(before, after)` → set|nil (nil = all:
  the sex changed). A render failure reverts an edit only when the failed category was touched by it.
- Character card (§8.1): `cardPayload(card)` → the `charCard` message for a `characters:list` card
  (labels translated, `sex` → translated gender, `lastLocation` key translated, the appearance
  never sent), `showCard(card|nil)`, `cardStrings()`, `CARD_STRINGS`.
- Also `payload(s)`, `strings()`, `action(data)`, `cameraAction(data)` (applies now),
  `cameraRequest(data, cb)` (the `editor:camera` callback: parks a request made while busy, §8.3), `validate`, `STRINGS`,
  `uiLocale()`, `uiDir()`.

**`WCEditorTree`** (tree builder, `client/editor/tree.lua`): `build(s)` → `root, registry`, `stages`,
`price(s)` (display-only copy of the server price rules — store: only changed categories are priced,
the saved item with its saved tint is free, a changed tint is compared with the owned tint or, for the
saved item without one, its saved tint; barber: base prices of the changed services capped at
`visitCap` then multiplied, `context.multiplier`/`visitCap` used when present), `storeStates(s, app)`
(store preview: the saved states kept only while their items are unchanged and still applicable — the
server's `WCOwnership.settleStates`), `taxonomy`, `clothingActions(app, reg?, makeEntry?)`,
`randomize`, `allowedModels`, `PRESETS`, `PAIRS`.

**`WCPanel`** — lightweight tree panel without scene/camera (clothing actions):
`open(spec)` → `true` | `false, code` (`BUSY` while an editor is open or opening, `INVALID_PAYLOAD`,
`INTERNAL_ERROR`) where `spec = {title, build() -> tree, onControl(control, value) -> Result,
onClose()}`, `refresh()`, `close()`, `isOpen()`, `payload()`, `action()`, `closeAction()`.

**`WCClothing`** (clothing state controller, `client/clothing/states.lua`): `perform(groupId, target,
opts?)` → Result `{group, value, changed, states}` (`opts.notify = false` silences the failure
notice), `available(app?)`, `applyStates(ped, app)` → `ok, failedGroups`, `openPanel()`,
`closePanel()`, `isPanelOpen()`, `busy()`, `tree(app?)`, `groupOfCategory(category)`,
`toggle(groupId)`, `removeCategory(category)` / `restoreCategory(category)` (only when that category
is the one worn in its group, else `STATE_NOT_APPLICABLE` with `data.reason = 'category'`). Refusals:
`BUSY` (`data.reason`) while any flow holds the player (the `clothingAction` lock, an editor, the
selection, a spawn / respawn, the `service` lock, a store / wardrobe / barber / surgery flow, a barber
seat, the cutscene, a redraw of the player); `STATE_NOT_APPLICABLE` for the ped's condition (dead,
dying, ragdoll, combat, mount) or an interruption before the animation midpoint (`data.interrupted`).
The state is written locally only after a last re-check, and repaired when the saved appearance was
replaced during the server round trip.

**`WCSelector`** (`client/characters/selector.lua`): `open(opts)`, `back(errorKey)`, `finish(spawnMode)`,
`leave()`, `active()`, `busy()`, `canSwitch()` → `true | false, localeKey` (refused while dead, in an
editor / panel, a selection / spawn / clothing action / `service` lock, `WCPreviewEnv.active()`, the
creator, the cutscene, the spawn selector or a spawn flow). Command `/characters` only with
`Config.Characters.allowSwitch`; local event `w_creators:client:backToSelection(errorKey?)`.
**`WCCreator`** (`client/creator/creator.lua`): `start(opts)` (`opts.repair = {token, sex?, charid,
appearance?, identity?}`), `active()`, `stage()`, `abort(key)`; the compatibility event
`W:CHARCREATION:starting` asks for a grant first. **`WCCutscene`** (`client/creator/cutscene.lua`):
`active()`, `stop()`, `configured()` (the ride's coordinates are in `Config.Creator.cutscene`); the
event `W:CREATOR:FirstSpawn` is raised only by the spawn module, for `'initial'` spawns when
`Config.Creator.enableCutscene` is on (never set `Config.Creator.spawnEvent` to it).

**`WCServiceFlow`** (`client/services/locations.lua`): the client half of one `WCSessions` preview
transaction, shared by the store, the wardrobe, the barber and the surgery: `run(spec)` → `ok, code`
(takes the `service` lock, `LOCK = 'service'`), `blocked()`, `current()`, `busy()`, `finish()`,
`abort()`, `call()`, `notify()`; leave order fade → move back → `scene:release` → `WCPreviewEnv.exit`
→ fade in; a resource stop undoes the preview without yielding (no render: the ped keeps the preview
look until the next start renders the player). **`WCServicePoints`**: `build()`, `clear()`,
`relabel()`, `dispatch()`, `canInteract()`, `isOpen()`, `title()`, `points()`, `TYPES`,
`HOUR_KEY = 'w_creators:hour'` (opening hours from the hour the server publishes; without it the
prompt shows and the server decides); `prompt = false` locations get no prompt, blip or NPC.
**`WCServiceSeat`** (`client/barber/barber.lua`): `take(flow, preview)`, `active()`, `kind()` (the
barber chair / clinic seat). **`WCStore`**, **`WCWardrobe`**, **`WCBarber`**, **`WCSurgery`**:
`open(id)` → `true | false, code` (a refusal because another flow holds the player shows `BUSY`,
except for a dead player), `busy()`.

**`WCClientApi`** (`client/api.lua`): the client exports of §13 (`appearance()`, `currentOutfit()`,
`equippedCategory(category)` → `hash, tint`, `refresh()`, `inCharacterScene()`, `openSurgery(id)`),
the `w_creators:client:openBarber` handler and the command `/reloadappearance`. **`WCDevClient`**
(`client/dev/tools.lua`): only with `Config.Admin.devTools` the commands `wc_inspect`, `wc_apply`,
`wc_remove`, `wc_restore`, each allowed by the server first (`w_creators:dev:allowed`, §16.5); only
with `Config.Admin.spawnProp` the `W:ADMIN:SpawnObject` handler.

**`WCSpawnSelector`**, **`WCSpawn`**, **`WCRespawn`**: see §11–§12.

**Domain entry points** (client): `WCStore.open(locationId)`, `WCWardrobe.open(locationId?)`,
`WCBarber.open(locationId)`, `WCSurgery.open(clinicId)` — each returns immediately if another
session/editor/scene is active, requests the matching `<kind>:open` callback and drives §17. The
server events `w_creators:client:openStore|openWardrobe|openBarber|openSurgery(locationId)` (server
exports, §13) call the same entry points.

### 3.3 Server

`Bridge` (framework layer, kept), `CreatorLogs` (optional logger, kept: `Emit(event, payload)` →
logged? and `Register(fn)` never throw, even when `w.logs` is missing, its readiness probe throws or
its transport throws; a logger that starts later is picked up by the readiness watcher, which fires
`w_creators:server:logsReady`; log types register once).
- `Bridge.RegisterCharacter(src, {firstname, lastname, dob?, age?, isMale})` → charid | nil. rsg/qbr
  store the validated identity `dob` as `charinfo.birthdate` (derived from the age only when no dob
  is given); VORP stores the age (`data.age`, else computed from the dob).
- `Bridge.DeleteCharacter(src, charid)` → `true` | `false, stage` (`'framework'` — the framework
  refused, nothing else is touched; `'appearance'` — the `WCAppearanceRepo.delete` transaction
  failed). rsg/qbr delete asynchronously: `true` means the core accepted the request, and
  `characters:delete` confirms the framework row is gone before answering.

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
- `get(src, token)` → session | nil, code. `current(src)` → the open session or nil.
- `commit(src, token, opId, fn, opts?)` → Result. `opts.kind` refuses a session of another kind
  (`SESSION_NOT_FOUND`); every domain commit passes it. Serialises per character
  (`CreatorAppearanceLocks`, via `lockCharacter(charid, owner)` / `unlockCharacter`), marks busy,
  replays the cached Result for a repeated `opId` (per-player replay cache, 120 s, survives the
  session close), runs `fn(session)` in `pcall`, closes the session on success.
- `close(src, token)`, automatic expiry, `playerDropped` cleanup, `onResourceStop` cleanup. A close
  that arrives while a commit runs is recorded (`closeRequested`) and done by that commit when it
  fails (a successful commit closes the session anyway).
- `open` replaces a session of the same kind that the client never used (no token-bearing call seen
  through `get`) once it is `REPLACE_UNUSED_MS` (35 s, past the w_lib callback timeout) old: an open
  reply lost on the way never leaves the player `BUSY` until the TTL. Close reason `replaced`.
- `result(src, token, opId)` → the recorded answer of a commit (read only: never executes one);
  `BUSY` while that session's commit still runs; `SESSION_NOT_FOUND` when nothing was recorded.
- `withinRange(src, location)` → the player is within `interactionRadius + 3` of the anchor or the
  fitting stand (used by open, commit and the fitting-room isolation, §16.2).
- `onClose(fn(session, reason))` hooks; reasons `commit|close|expired|dropped|stopped|character|replaced`.
  The built-in hook sends `w_creators:client:sessionClosed(token, reason)` for `expired`, `stopped`,
  `character` and `replaced` (forced closes the client did not ask for; `NOTIFY_REASONS`).
- Registers the `w_creators:session:close(token)` and `w_creators:session:result(token, opId)`
  callbacks (§16.4).
- The server clock for the client (it has no os library): `publishClock()` (at start and every
  `CLOCK_INTERVAL` = 60 s) sets `GlobalState[HOUR_KEY]` (`'w_creators:hour'`, 0..23, read by the
  service prompts) and `GlobalState[WCUtil.TODAY_KEY]` (`{year, month, day, hour}`, read through
  `WCUtil.today()` by the creator's date-of-birth window), then runs the `onClock(fn)` listeners (the
  surgery clinics publication).

**`WCAppearanceRepo`**: `load(charid)` → `app, meta` (lazy v3 upgrade §6.2), `save(charid, app, extra?)`
(one transaction; `extra` = additional `{query, values}` pairs), `create(charid, identity, app, extra?)`,
`delete(charid)` → boolean, `purge(charid)` → `true, counts` | `false, reason` (w_core's character
deletion: the rows are counted, then `delete`), `degraded(charid)`, `invalidate(charid)`, `legacyGrants`,
`migrateAll`, `cache` (per active character). It registers the console command
`wc_migrate_appearances` (§6.2).

**`WCCharacters`**: `active(src)` → `{charid, sex}` | nil, `setActive(src, charid, sex)` (drops the
player's creation grant; fires `w_creators:server:characterActivated(src, charid, sex)`),
`clear(src, reason?)` (also `WCSync.forget`; fires `w_creators:server:characterCleared(src, charid,
reason)`), `isSwitching(src)`, `inFlow(src)` (false whenever a character is active), `slots(src)`,
`ownerOf(charid)`, `beginSwitch(src)` → `true` | `false, code` (`SERVICE_DISABLED` when
`allowSwitch` is off, `BUSY` when dead, in a session or locked). Callbacks §16.1.

**`WCScene`** (`server/scene.lua`): `isolate(src, startSwitch?)`, `registerPed(src, netId)`,
`release(src)`, `isIsolated(src)`, `toWorld(src, reason?)` (bucket 0, tracking dropped), `forget(src)`.
Callbacks §16.2.

**`WCSpawnServer`** (`server/spawn/spawn.lua`, §11): `grant(src, kind)`, `pending(src)` → kind|nil,
`cancel(src)`, `finish(src, kind, isNew)` → `'selector'|'direct'|'event'`, `resolve(pointId, src)` →
`pos, id` | `nil, code`, `validateLast(pos)`, `lastPosition(src)`, `nearestLabel(pos)`, `points()`,
`pointIds()`, `respawn(src, pointId?, kind, extra?)` → Result (sends `w_creators:client:respawn`).
Kept bridge entry points: `Bridge.FinishCharacter`, `Bridge.GetSpawnCoords`, `Bridge.FindSpawnPoint`.

**`WCRespawnServer`**: `admin(adminSrc, target, pointId?)` → Result (`target` = the typed citizen id,
`#<server id>` for a server id, resolved by `w.citizen.requireOnline`: `INVALID_CITIZEN_ID` /
`PLAYER_NOT_FOUND` / `PLAYER_OFFLINE`); command `wc_respawn <citizenId>
[pointId]` (console or `Config.Admin.ace`; rate-limited 5 / 10 s **before** the ACE check, so a
non-admin writes at most 5 violations per window and gets no feedback).

**`WCSync`**: `broadcast(src, app)`, `broadcastState(src, group, value)`, `forget(src)`, `get(src)`
(copy of the cached appearance), `reload(src)` (§16.5).

**`WCOwnership`**: `list(charid)` → `{[u32 string] = {category, palette, tint0, tint1, tint2, source}}` |
`nil, 'DATABASE_ERROR'`, `owns(charid, hash)`, `entry(owned, hash)`, `tintOf(owned, hash, category)`,
`key(hash)`, `grantQueries(charid, items, source)` → queries for a transaction (item `tint`: nil =
insert keeping an existing row, table = upsert the tint, `false` = reset it to NULL), `wornGrants`,
`grant`, `resolveEquipped(sex, equipped)`, `changedCategories`, `checkRules(savedEq, resolved)`,
`sameTint`, `cleanTint`, `settleStates(app, states, reset?)` (persisting, valid, applicable states
not in `reset`), `groupsOf(categories)`, `exactId(v)` (exact positive 32-bit id or nil).

**Domain services** (callbacks §16.4): `WCClothingStore` (`open`, `commit`, `plan`, `prices`,
`tintPrice`), `WCWardrobeService` (`open`, `commit`, `plan`, `validStates`, `maxOutfits`),
`WCOutfits` (CRUD §5.6: `list`, `get`, `validateName`, `validateData`, `create`, `update`, `rename`,
`remove`, `max`; session functions `save`, `updateOutfit`, `renameOutfit`, `deleteOutfit`),
`WCClothingActions` (`setState`, `states`, `forget`), `WCBarberService` (`open`, `commit`, `offer`,
`price`, `plan`, `validStyles`, `multiplier`, `sectionList`), `WCGroomingServer` (`tick`, `flush`,
`pending`, `fold(charid, app, previous, meta)` → seconds, `consumed(charid, seconds)`, `TICK_MS`; it
tracks a character from `characterActivated` and writes on `characterCleared`/drop),
`WCSurgeryService` (`open`, `commit`, `allow`, `sections`, `price`, `plan`, `grant(src, clinicId)`,
`granted(src, clinicId)`, `GRANT_SECONDS = 60`), `WCApi` (§13), `WCDevTools` (`clientAllowed(src,
command)` behind the `w_creators:dev:allowed` callback, `CLIENT_COMMANDS`, `validate()`,
`printReport(report)`; commands `wc_catalog_validate` and `spawnprop`, both off unless
`Config.Admin.devTools` / `Config.Admin.spawnProp`).

---

## 4. Result contract and error codes

Every callback returns `WCResult`. The client translates `message` (a locale key) only at the UI boundary.

```
OK
INVALID_PAYLOAD  RATE_LIMITED  BUSY  SERVICE_DISABLED  LOCATION_DISABLED  LOCATION_NOT_FOUND
TOO_FAR  ACCESS_DENIED  SESSION_EXPIRED  SESSION_NOT_FOUND  NO_CHARACTER  NO_CHANGES
CHARACTER_NOT_FOUND  NOT_CHARACTER_OWNER  CHARACTER_SLOT_LIMIT  CREATION_NOT_GRANTED
INVALID_NAME  INVALID_DOB  DELETE_CONFIRMATION_REQUIRED  DELETE_DISABLED  CREATION_DISABLED
INVALID_COMPONENT  COMPONENT_NOT_AVAILABLE  ITEM_NOT_OWNED  INVALID_TINT  CONFLICTING_ITEMS
INSUFFICIENT_FUNDS  INVALID_PRICE  CURRENCY_NOT_ACCEPTED
NOT_RESELLABLE  ITEM_IN_OUTFIT  ITEM_WORN  ITEMS_DISABLED  INVENTORY_FULL  WRONG_SEX
STORE_DISABLED  BARBER_DISABLED  SURGERY_DISABLED  SURGERY_NOT_ALLOWED  WARDROBE_DISABLED
OUTFITS_DISABLED  OUTFIT_LIMIT  OUTFIT_NOT_FOUND  INVALID_OUTFIT_NAME
STATE_NOT_SUPPORTED  STATE_NOT_APPLICABLE  ACTIONS_DISABLED
INVALID_SPAWN  SPAWN_NOT_PENDING
INVALID_CITIZEN_ID  PLAYER_NOT_FOUND  PLAYER_OFFLINE
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

Only the 63 w_lib-named expressions exist; nothing else is exposed. The NUI shows values as −100…+100
(`display.scale = 100`); storage is −1…1.

### 5.3 Clothing taxonomy (store, wardrobe, creator clothing stage)

`Config.Clothing.taxonomy` is an ordered list of groups; each group an ordered list of
subcategories; each subcategory owns **exactly one** catalog category (a category appears once):

```
Head         Hats(hats) · Masks(masks) · Eyewear(eyewear)
Neck         Bandanas & neckerchiefs(neckwear) · Ties(neckties)
Upper body   Shirts(shirts_full) · Vests(vests) · Coats(coats) · Closed coats(coats_closed)
             Ponchos(ponchos) · Cloaks(cloaks) · Dresses & gowns(dresses) · Armour(armor)
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
purchases may tint. Only what the player changed is priced: an item worn as saved **with its saved
tint** is never charged (and its owned row is never rewritten), even when its owned tint differs. A
changed tint is charged `tints.price` when it differs from the baseline — the item's owned tint, or,
for the saved worn item without an owned tint, its saved tint; going back to the baseline is free. The
editor's price preview (`WCEditorTree.price`) uses the same rule. The owned row (`w_creators_clothes`)
stores the item's tint; the wardrobe applies the owned tint and cannot change it.

The `enabled` flag and the palette lists govern **new** tints only (store plan, `SetClothes`, owned
tints, the editor, a changed tint in `mergeSections`). Stored data (`sanitize` with `rules = false`:
repository reads/writes, `normalize`, `toLegacy`) checks a tint structurally (`validStoredTint`), so
disabling tints or narrowing a category's palettes never erases a saved dye; the renderer skips
a tint that `validTint` rejects while the config forbids it.

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
`clothing.equipped` is unchanged. Non-persisting states (`persist = false`, e.g. the bandana) live in
memory only and are never saved in an outfit.

State settlement on a commit (`WCOwnership.settleStates`): the **store** resets the state of every
swapped or removed item and drops states whose item is gone (the store editor previews the same result,
`WCEditorTree.storeStates`); the **wardrobe** keeps a state on a swapped item when it still applies
(its editor edits states itself) and drops states that no longer apply; an **outfit** keeps only the
persisting states that apply to its own equipped items.

### 5.6 Owned items and outfits

- **Owned item** — `w_creators_clothes(charid, hash, category, palette, tint0..2, source, acquired_at)`,
  unique `(charid, hash)`. Sources: `store`, `starter`, `legacy`, `admin`.
- **Equipped item** — `app.clothing.equipped`.
- **Runtime state** — `app.clothing.states`.
- **Outfit** — `w_creators_outfits(id, charid, name, data, created_at, updated_at)` where `data =
  {equipped = {[category] = hash}, states = {...}}` — references to owned hashes only (tints come
  from ownership). Limit `Config.Wardrobe.maxSavedOutfits`. Equipping validates ownership at equip time.
- Outfit names: trimmed, repeated spaces collapsed (Unicode spaces count as a space), 1..
  `outfitNameMax` characters with at least one visible character; C0/C1 controls, line/paragraph
  separators, bidi overrides, the BOM and invisible characters (soft hyphen, ZW spaces/joiners,
  LRM/RLM, U+2060–U+206F, Hangul fillers, tag characters…) are rejected. Ids are exact positive 32-bit
  integers (`WCOwnership.exactId`); anything else is `OUTFIT_NOT_FOUND`.
- The wardrobe never writes ownership rows. Items worn now that have no ownership row are listed in
  `wardrobe:open`'s `owned` map marked `{source = 'worn', worn = true}` (display only) and may only stay
  in their saved category. The store commit grants the clothes the player arrived in as `legacy`
  (pre-v3 behaviour) in the same transaction as the purchase.
- Equipping an outfit in the editor (`outfit.<id>.equip`) applies the owned outfit locally after the
  `onOutfit('equip', ...)` veto hook (§3.2); the result is saved by `wardrobe:commit`.

### 5.7 Database (additive, versioned migrations; nothing is dropped)

| Migration id | Change |
|---|---|
| `001_base_tables` | `characters_appearence`, `w_creators_clothes` (existing DDL, `IF NOT EXISTS`) |
| `002_appearance_v3` | `characters_appearence` + `appearance LONGTEXT NULL`, `appearance_version INT NOT NULL DEFAULT 2`, `updated_at TIMESTAMP NULL` |
| `003_clothes_meta` | `w_creators_clothes` + `source VARCHAR(16) NULL`, `acquired_at TIMESTAMP NULL` |
| `004_outfits` | `w_creators_outfits` |
| `005_clothes_paid` | `w_creators_clothes` + `price_paid DECIMAL(10,2) NULL`, `currency VARCHAR(8) NULL` (what a store purchase charged: selling back) |
| `006_colorways` | `w_creators_colorways(charid, hash, palette, tint0..2, price_paid, currency, acquired_at)`, unique `(charid, hash, palette, tint0, tint1, tint2)`; backfilled from every dyed `w_creators_clothes` row (`INSERT IGNORE`) |

`ADD COLUMN IF NOT EXISTS` is MariaDB-only; migrations check `information_schema.COLUMNS` first.
`sql/install.sql` (the same end state for a manual install) creates the ledger table but records no
id: its `CREATE TABLE IF NOT EXISTS` statements do nothing on an existing pre-v3 table, so the
resource still runs every step once (a no-op on a fresh install, the missing columns on a pre-v3 one).

---

## 6. Persistence

### 6.1 Storage
The v3 appearance is stored in `characters_appearence.appearance` (JSON) with `appearance_version = 3`.
The legacy columns `isMale / components / faceFeatures / overlays` are rewritten in the same `UPDATE`
from `AppearanceSchema.toLegacy(app)` as a **derived compatibility projection** (so a rollback to the
previous release still loads the character). At v3 they are **read only as a fingerprint**: every v3
write stores, inside the JSON (top-level key `projection`, never part of the returned appearance), a
fingerprint of the legacy columns as the row holds them after that write. On every v3 load the
columns are fingerprinted again; when they differ (an older release — a rollback — wrote them after
the last v3 write) the appearance is **rebuilt** from them with `fromLegacy`, keeping the v3-only data
that still applies (tints of the items still worn, states of unchanged items, the outfit id when the
worn set is unchanged), written back with the new fingerprint and logged. A column that is NULL,
empty or undecodable is ignored (the v3 JSON is kept, fingerprint unchanged), and so is a rebuild that
would need essential defaults. JSON written before the fingerprint existed carries none and is trusted.
**Do not edit a v3 row's legacy columns by hand expecting them to be inert**: a valid edit replaces
the v3 JSON on the next load (and drops the tints of the items it changed).

### 6.2 Lazy upgrade
`WCAppearanceRepo.load(charid)` reads the newest row for the charid. If `appearance_version < 3` or
`appearance` is NULL/corrupt: `fromLegacy(row)`. If the legacy decode needed **no** defaults for
essential parts, the upgraded v3 is written back (plus `legacy` ownership grants for the equipped
clothing, `INSERT IGNORE`) in one transaction. If defaults were needed the row is **not** written
(data is never silently replaced); the in-memory appearance uses the defaults and a warning is logged.
A row already at `appearance_version >= 3` whose JSON is unreadable is **recovered** from the projection
the same way but **without** `legacy` grants (its ownership is already authoritative; the projection
may hold clothing applied through `SetClothes`) and logged as a recovery (`meta.recovered`).
Cache: every write / invalidation bumps a per-character generation; a load caches what it read only
when the generation did not move while it yielded (a pre-save read never replaces what a save cached).
Console command `wc_migrate_appearances` upgrades all rows in batches (console only).

### 6.3 Identity
`firstname`, `lastname`: 2..25 UTF-8 characters each, letters (Latin incl. Latin-1 letters, Arabic
U+0621–U+064A, U+066E–U+06D3; Arabic diacritics U+064B–U+0652/U+0670 allowed after a letter), space, apostrophe, hyphen; no leading/trailing/double spaces.
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
  blip = { sprite = 'blip_shop_tailor', label = '<key>' } | false,   -- the game's own sprites (wardrobe: blip_shop_wardrobe)
  prompt = true,                          -- false = another resource provides the interaction (surgery → the
                                          -- doctor resource, through the server export OpenCosmeticSurgery, §13)
  preview = vector4 | nil,                -- fitting stand / chair: where the player stands while editing
  camera = '<preset>' | nil,
  storeProfile = 'general', pricingProfile = 'standard',
  allowedServices = { hair = true, facialHair = true, details = true } | nil,   -- barber
  hours = { open = 6, close = 22 } | nil }                                      -- availability rule
```
Adding a shop is a config edit only. Opening hours use the server's local hour; the client prompts
read the hour the server publishes (`GlobalState['w_creators:hour']`, §3.3) and show the prompt when
it is not published — the server's `<kind>:open` (`LOCATION_DISABLED`) always decides.

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
  dirty, canSave, canUndo, canRandom, saveLabel,     -- canUndo: history not empty; canRandom: creator
  confirm = { title, body, confirmLabel },             -- save confirmation copy (e.g. "Confirm procedure")
  camera  = '<preset>' }
{ type='editorClose' }
{ type='panel', session = {id, title, locale, dir}, strings, tree }   -- WCPanel
{ type='panelClose' }
{ type='charCard', show, name, age, dob, gender, lastLocation, job, cash, bank, gold, locale, dir,
  strings = {name, age, dob, gender, lastLocation, job, cash, bank, gold} }  -- WCEditor.cardPayload
```
A new `session.id` resets the NUI navigation; the same id keeps the current path, search and
selection (UI category state memory).

`strings` (chrome, `WCEditor.STRINGS`, all translated; the header wordmark is not one, §0.7): `appearance, back, close, undo, reset,
random, search, none, empty, saving, confirm, stay, discard, save, leaveTitle, leave, resetBody,
dangerBody, total, free, center, padHelp, advanced, camera, clickZoom, dragRotate, rightReset,
nameHint, details, error, owned, equipped, locked, new, apply, price, variants` and `view.<preset>`
for every §8.6 preset. The leave modal's primary button shows `saveLabel` and the total and opens the
standard save confirmation (a purchase is never made without the price on screen).

### 8.2 Node
```
Node = {
  id, kind, label, hint?, art?, summary?, badge? ('owned'|'equipped'|'locked'|'new'), badgeLabel?,
  camera?, disabled?, reason?,                      -- reason = translated why disabled
  children?  (group),  searchable? (group: show search box over children),
  control?, value?,
  options?  = [{value, label, badge?, badgeLabel?}] -- choice with explicit options
  range?    = {min, max, none?}                     -- choice with generated numeric options (none ⇒ option 0 = strings.none)
  min?, max?, step?, display? = {scale, decimals}   -- slider; pads carry the same four for both axes
  x?, y?    = {control, label, value}               -- pad (FeaturePad)
  item?     = {name, price?, owned?, equipped?, variants?}   -- itemcard
  danger?, confirmBody?, actionLabel?               -- action; danger ⇒ the NUI asks for confirmation
                                                    -- first (title "Parent › Action", body confirmBody
                                                    -- or strings.dangerBody) and invokes only on Confirm
  maxLength?, placeholder?                          -- text
  items?    = [{label, value}]                      -- info / review rows (already translated)
}
kind ∈ group | choice | slider | pad | action | text | info | itemcard | review | identity
```
Search is client-side: a searchable group matches its navigable descendants up to 4 levels deep
(at most 60 results); a result carries `via` (its path) and a "Parent › Child" label, and opening it
pushes the whole path. Choices carry model / variant / tone indices, never hashes; morph values are
stored −1..1 and shown −100..100.

### 8.3 NUI → Lua (all respond `{ok, code?, message? (translated), payload?, closed?, camera?}`)
- `editor:action` `{id, op, control?, value?, values?, identity?, opId}`
  - `op='set'` one control; `op='setMany'` `values = {[control] = value}` (pads, one undo step);
    `op='invoke'` action/text nodes; `op='undo'|'reset'|'random'`; `op='save'` (creator sends
    `identity`); `op='cancel'` (discard and close).
- `editor:camera` `{id, preset?|rotate?|zoom?|reset?|pick?|hide?}`. A request that arrives while an
  operation runs (a live preview, a set) is not refused: it is parked and applied the moment the
  operation ends, then answered, so the view the NUI names is the one the camera took. Latest wins
  per slot (a view — preset, pick, reset — replaces the parked view and drops parked turns / zooms;
  turns and zooms add up; the hide toggle has its own slot); a replaced request answers `ok = false`,
  and so does one still parked when the session closes.
- `panel:action` `{id, control, value?}`, `panel:close` `{id}`
- One NUI action = one Lua operation: the NUI locks while a request is pending; Lua rejects
  concurrent ops per session (`BUSY`); the server replays a duplicate `opId` (§3.3 `WCSessions.commit`).
  The `opId` of a Save is generated by Lua, not the NUI: it is reused for a retry while the working
  appearance and identity are unchanged and the previous answer was uncertain.
- `op='setMany'` accepts at most 8 controls. `op='invoke'` on an outfit's `equip` runs the
  `onOutfit('equip')` veto hook first (§3.2).

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
is refused while dead, in an editor or in a session. The switch is server-tracked: the first of
`scene:prepare`, `characters:list`, `characters:select` or `characters:beginCreate` called by a player
with an active character starts it (`WCCharacters.beginSwitch`: `SERVICE_DISABLED` when `allowSwitch`
is off, `BUSY` when dead — server `GetEntityHealth <= 0`, or the death system says so:
`WCCharacters.DEATH_OWNER` = `{resource = 'w_ambulancejob', export = 'IsDead'}` (its dead / last-stand
metadata, also while the ped is alive: the hospital-bed heal timer, a dead character logging in) —,
in a session or while a commit holds the character lock). The client mirrors the death-owner check
in `WCSelector.canSwitch` (`WCSpawn.DEATH_OWNER.isDead`, the w_ambulancejob client export `IsDead`). The leaving character is cleared (`characterCleared`, reason `switch`) and its spawn
grant withdrawn.
A switch the player is not isolated in the character scene for **lapses** after
`WCScene.ROOM_GRACE_MS` (`WCCharacters.checkSwitches`): a character selected, created or repaired but
never loaded is finished (active + broadcast, no spawn grant); an open creation / repair grant is
cancelled and the character switched away from comes back (logged in again when the framework holds
a character without a usable look — a provisioned creation). A lapse is a `security_violation`
(`character_switch_lapsed`) and no new switch starts for `WCCharacters.SWITCH_LAPSE_COOLDOWN_MS`
(5 min; `BUSY`).
Re-selecting the character the framework already has logged in never logs it out and in again. On
rsg / qbr a login over a logged-in character first saves it on the server (`Player.Functions.Save`)
and waits until the players row holds what was saved (`job`, `gang`, `metadata`, plus `money` without
w_core; `Bridge.SAVE_CONFIRM_MS`, 3 s); an unconfirmed save refuses the login (the character stays).
VORP keeps every character of the user in memory, so its `setUsedCharacter` loses nothing.

Resource restart: players whose framework character is still logged in are **adopted** as active
again once the database is ready (only if they are still connected, still logged into that character
and hold no flow state). An adopted player may re-enter the selector for **2 minutes** after the
adoption even when `allowSwitch` is off (the restarted client reopens the selector); the window ends
early when a character is activated.

### 9.2 Creation
Server grant (`characters:beginCreate`: service enabled, slots available; the grant is taken under the
per-player lock, and a player with an active character never holds one) → gender scene (the man and
the woman side by side on the stage of `Config.Scene`, the camera on the pair; `LEFT` / `RIGHT` opens
the editor on that character at once, where it stands, the other one hidden) → editor
(mode `creator`, stages identity/body/face/skin/hair/facialHair(male)/makeup/clothing/review; its root
Back, "change the sex", returns to the pair and keeps each gender's look as a draft and the typed name)
→ at the save `beginCreate(sex)` again (same token; takes the sex the design has, once per sex; a
grant already locked to the other sex refuses the save) →
`characters:create(token, identity, app)` → identity + appearance sanitize → `characterCreated`
event → `Bridge.RegisterCharacter` → appearance row + starter ownership (one transaction) → client
renders on the player ped → `characters:loaded` (legacy net event `creationReady`) → spawn. Creation is
free. A repeated `create` with the same token returns the same result without a second registration.
Repair path: `select` answers `{needsAppearance, token, sex?}` for a character without an appearance
row → creator in appearance-only mode → `create(token, nil, app)` → `loaded`. A **degraded** character
(its stored look needed essential defaults) gets `{needsAppearance, token, sex, appearance, degraded,
repairSections}`: the save takes `repairSections` only (body, face, eyebrows, skin, eyes, hair,
facialHair, makeup) and keeps the saved clothing, so the repair editor offers those sections and no
clothing stage.
Registration never binds a creation to a character the player already had: VORP's asynchronous
`addCharacter` is resolved by reading the account's ids first and accepting only a **new** id (none
within 4 s → `nil`), and `createNew` refuses a registered charid that was in the list read before it.
A player who drops while `select` / `create` yields leaves nothing behind (no pending / grant, the
repository entry released).

### 9.3 Service editors (store, wardrobe, barber, surgery)
```
prompt → client requests <kind>:open(locationId) → server WCSessions.open → client enters preview
(fitting stand / chair, isolated bucket only for store fitting rooms), opens WCEditor with the
server snapshot → changes are local previews only → Save → <kind>:commit(token, opId, working) →
server: session valid → mergeSections(snapshot-from-DB, submitted, allowedSections) → validate →
price (server) → WCEconomy.withCharge(persist) → broadcast → client RestorePlayer(result app)
Cancel / close / death / disconnect / resource stop → client restores the snapshot, server closes the session.
Forced server close (expiry, resource stop, character change) → w_creators:client:sessionClosed(token,
reason) → the client closes the editor, restores the snapshot and leaves the preview.
```
A flow that ends without a commit after an uncertain commit answer (`INTERNAL_ERROR` / `BUSY`: a lost
reply) closes its session, then asks `w_creators:session:result(token, opId)`: a recorded ok is taken
(WCState + render), a recorded refusal or no record changes nothing, a still unknown answer reloads the
saved look (`appearance:reload`). A flow that restored its snapshot (cancel, death, forced close) draws
the non-persisting clothing states of `WCState.appearance` (e.g. the bandana raised) on the ped again.
Leaving a fitting room restores the heading the player had on the shop floor.
A commit refuses a degraded (defaults-filled) saved appearance before anything is charged (`open`
already returns `INTERNAL_ERROR` for one). Store: only changed categories are priced (§5.4), states of
swapped items reset (§5.5). Wardrobe: every item must be owned or the item already worn in the saved
appearance; tints come from ownership; no ownership row is written. Barber: base prices of the
services whose sections changed, capped at `visitCap`, then multiplied by the location's pricing
profile; an unknown hair/beard hash is `INVALID_COMPONENT` (bald = 0 is valid). Surgery: changes only
in sections the clinic does not allow are `SURGERY_NOT_ALLOWED`; with `allow.clothing`, a newly worn
item must be owned (`ITEM_NOT_OWNED {category}`) and tints are forced to the owned / saved tint.
Barber, surgery and `SetSkin` fold the pending grooming growth into their save (`WCGroomingServer.fold`
/ `consumed`): the part that was cut restarts, the other keeps its growth; growth is never charged.
Sections per mode: store `clothing` (+ tints); wardrobe `clothing` (owned only), outfits, `states`;
barber `hair`, `facialHair`, and `eyebrows`/`makeup` if enabled in `Config.Barber.services.details`;
surgery per `Config.CosmeticSurgery.allow`; creator all.

### 9.4 Appearance sync (OneSync)
The server caches the last broadcast appearance per player. Clients keep a remote cache and a 1 s
scope watcher: when a player's ped handle appears or changes (entered scope, respawned), the cached
appearance is re-applied to that ped once. Clothing state changes broadcast `remoteClothingState`
(small) and update the cache. Own ped: the local client applies its own appearance; remote
application is skipped for our own server id. The watcher keys each render on server id + ped handle
+ cache revision, retries a model mismatch up to 5 times (`MAX_FAILURES`), and forgets both the
fingerprint and the failure count when a ped leaves scope (a reused handle renders again). A clothing
state that arrives during a full render only updates the cache; the next pass renders it. The client
sends `w_creators:server:requestAppearances` once the session has started (server: 2 / 10 s).

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
not exercised by this resource before), **Experimental** (research-only; behind a gate that is off
by default: `Config.Experimental.*`, or `Config.Admin.devTools` for the dev-only category discovery
natives), **Deprecated / Avoid**.

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

Kinds `admin` and `death` belong to a player who is already in the world: their spawn choice (and
`WCSpawnServer.respawn`) sends `w_creators:client:respawn(pos, {kind, point})` instead of
`w_creators:client:spawn` (w_core treats `client:spawn` as a fresh login and fires `OnPlayerLoaded`
again) and never touches the routing bucket (a bucket another resource set after the grant — jail,
instance — is kept). `OpenSpawnSelector` refuses (`BUSY`) while any grant is pending, while a session
is open, outside bucket 0 and while w_ambulancejob holds the player (`heldByDeathOwner`: its server
`IsDead` / `InHospitalBed`; an admin respawn too).

Client modules. **`WCSpawnSelector`** (`client/spawn/selector.lua`): `open(data)`, `close(opts?)`,
`active()`, `kind()`, `holding()`, `current()`, `points()`, `index()`, `resolve(data)`, `move(delta)`,
`confirm()`; it handles `w_creators:client:selectSpawn`, confirms with `spawn:choose(id)` (the id only)
and, with no usable point, sends `w_creators:server:spawnAt(false)` (the server's fallback). It takes
no `WCState` lock: the other flows check `WCSpawnSelector.active()`. **`WCSpawn`**
(`client/spawn/spawn.lua`): `spawn(pos, meta)`, `respawn(pos, meta)`, `place(pos)`, `probe(x, y, z)`,
`count()`, `busy()`; it handles `client:spawn` and `client:respawn`. The ground probe casts from
2 m, then 20 m, above the target (`PROBE_ABOVE`) and accepts a ground within 20 m of it
(`GROUND_MAX_DELTA`), else the configured first spawn; a broken
`Config.Spawn.firstSpawn` keeps the player in place. A world respawn (`admin` / `death`) first
cancels an open editor, panel or uncommitted service visit and waits up to `FLOW_TIMEOUT` (15 s) for
them to end — otherwise it gives up without moving the player — and stops the first-spawn cutscene.
A downed player is revived through `WCSpawn.DEATH_OWNER` (`w_ambulancejob`'s own
`hospital:client:Revive`, so its dead state is cleared) when that resource runs (3 s to start, 30 s to
finish), else through `WCRespawn.resurrect`. The character scene (selection room, creator, a login
spawn selection) ignores world respawns.

## 12. Respawn

Client state machine `ALIVE → DYING → DEAD → RESPAWN_PENDING → RESPAWNING → ALIVE`, polled every
250 ms (not every frame). `exports.w_creators:Resurrect(coords, heading, reason)` is the single
resurrect entry (used by w_ambulancejob with a fallback when w_creators is stopped): it refuses a second
resurrect while `RESPAWNING`, resurrects through `WCNative.respawn.resurrect`, waits for the new ped,
then `Appearance.RestorePlayer()`. A watcher also restores the appearance after any external
resurrect (ped handle changed or dead → alive). Appearance never touches weapons/inventory.
**`WCRespawn`**: `STATES`, `state()`, `poll()`, `resurrect(coords, heading, reason)`, `isDown(ped?)`,
`inScene()`, `closeEditors()`, `reset()`. Every successful resurrect fires the local event
`w_creators:client:resurrected(reason)`: a death system clears its own dead state for the reasons it
did not resurrect itself (w_ambulancejob skips `'hospital'`).

## 13. Public API

Server exports (`WCApi`, `server/api.lua`):
- Reading: `GetActiveCharacter(src)` → `{charid, sex}` | nil (`WCCharacters.active` through
  `WCSessions.activeCharacter`), `GetCharacterAppearance(src)` → v3 | nil, `GetAppearance(src)` (w_lib
  bridge compat) → `{skin, clothes, appearance}` where `skin = {model, sex = 1|2, headHash,
  bodyUpperHash, bodyLowerHash, eyesHash, teethHash, hair = {hash}, beards_complete = {hash},
  bodyWeight = <waist outfit hash, AppearanceSchema.WAIST_TYPES[body.weight]>, bodyScale, expressions,
  overlays}` (no `bodyType`: the body type is `bodyUpperHash`; overlays keyed by `w.pedTexture` layer
  name as `{id, opacity, palette, tint0}`) and `clothes = {[category] = {hash, palette?, tint0..2?}}`.
- Writing: `SetClothes(src, clothes, overwrite)`, `SetSkin(src, skin, overwrite)` → Result
  `{appearance, changed, sections}`. Every value is validated for the character's sex and **refused,
  never repaired** (`INVALID_COMPONENT`, `INVALID_TINT`, `CONFLICTING_ITEMS`, `INVALID_PAYLOAD`);
  `bodyWeight` accepts a waist hash (signed or unsigned) or an index 1..21; `bodyScale` must be within
  0.9..1.1, an expression within -1..1 and an overlay opacity within 0..1 (after the bridge's percent
  convention: a value above 1 is divided by 100) — never clamped. `SetSkin` also accepts a v3
  appearance (its clothing is ignored): only what it carries replaces the saved values (a body / head /
  hair field, a morph id, an overlay layer); a section or field it leaves out keeps the saved one
  (`overwrite = true` replaces the morphology and overlays, as for a standard skin). `BUSY`
  while a session is open or the character is locked. On success: save (with the folded grooming
  growth), `w_creators:client:applyAppearance` to the owner, broadcast, `appearanceChanged(src, charid,
  'api')`. `ApplyCharacterAppearance(src)` re-sends the saved appearance. Exports that read the
  database yield: call them from a thread.
- Opening services: `OpenCosmeticSurgery({source, clinicId})` (also `(src, clinicId)`),
  `OpenClothingStore(src, id)`, `OpenBarber(src, id)`, `OpenWardrobe(src, id?)` → Result
  `{locationId}`; each checks the service, location, character, no open session and distance, then
  sends `w_creators:client:openSurgery|openStore|openBarber|openWardrobe(locationId)` (a remote
  wardrobe is `nil`). **Surgery at a clinic with `prompt = false`** opens only through this export:
  it gives the player a one-use grant for that clinic (`WCSurgeryService.grant`, 60 s); the client's
  `surgery:open` consumes it (without one → `SURGERY_NOT_ALLOWED`); clinics with their own prompt need
  no grant; grants are dropped on disconnect. The doctor resource (w_ambulancejob) shows its own
  client prompt, calls **its own server**, and that server calls
  `exports.w_creators:OpenCosmeticSurgery({source = src, clinicId = id})` — the client never grants
  itself.
- Spawn: `OpenSpawnSelector(src)` → Result `{points, kind = 'admin'}` (grant + `selectSpawn`;
  `BUSY` while a spawn is pending, a session is open or outside bucket 0; `SERVICE_DISABLED` when the
  selector is off); `RespawnPlayer(src, pointId?, kind?)` → `WCSpawnServer.respawn(src, pointId,
  kind)` with kind `'admin'` (default) or `'death'`. `respawn` refuses (`BUSY`) while a login-kind
  spawn grant is pending (the player is in the character scene) and withdraws a pending in-world
  grant (`admin` / `death` selector), which the client respawn closes without a `spawn:choose`.

Server-local events: `w_creators:server:characterCreated(src)` (w_lib) fires before the framework
login of a new character; `characterActivated(src, charid, sex)`, `characterCleared(src, charid,
reason)` and `appearanceChanged(src, charid, kind)` (§16.5).

Client exports: `OpenWardrobe(id?)` (kept), `OpenCosmeticSurgery(clinicId)`, `OpenClothingActions()`,
`GetCurrentOutfit()` → `{outfit, equipped, tints, states}`, `GetAppearance()`,
`GetEquippedCategory(category)` → `hash, tint` (clothing and the body parts heads, eyes, teeth,
BODIES_UPPER, BODIES_LOWER, hair, mustache), `SetClothingState(group, value)`, `ToggleHat()`, `ToggleBandana()`, `ToggleSleeves()`, `RemoveClothingCategory(category)`,
`RestoreClothingCategory(category)`, `RefreshAppearance()`, `Resurrect(coords, heading, reason)`,
`IsInCharacterScene()` (selection room, creator, a login spawn selection). Each export is registered
once, by its module (`OpenWardrobe` in the wardrobe, the clothing-state exports in
`client/clothing/states.lua`, `Resurrect` in the respawn module, the rest in `client/api.lua`).
Command `/reloadappearance` → `RefreshAppearance()`. Local event
`w_creators:client:resurrected(reason)` (§12).

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
| `w_creators:characters:loaded` | — | valid only after a successful `select`/`create` (a repeated call replays the last answer while that activation stands); marks the character active (`WCCharacters.setActive`), broadcasts the appearance, then starts the spawn flow (grant + `w_creators:client:selectSpawn` or `w_creators:client:spawn`). `{spawn = 'selector'|'direct'|'event'}` |
| `w_creators:characters:beginCreate` | `sex?` (`'male'|'female'`) | service `characterCreation` + free slot → one-shot grant, taken under the per-player lock. `{token, sex, locked}` (`locked = true` once the sex can no longer change: the framework character exists, or a completed creation is replayed; the creator then offers only that sex in the gender scene). Called again with the design's `sex` right before `create` (the creator settles the sex at the save): same token, sex locked server-side (once the framework character exists the answer carries the locked sex and the creator refuses a save of the other sex; a `create` of the other sex is then `INVALID_PAYLOAD`). After a creation that completed but was never loaded (a lost reply, a failed render) it answers that creation's token (and sex): `create` with it replays the stored result, so no second character is registered |
| `w_creators:characters:create` | `token, identity {firstname, lastname, dob}, app` | grant valid (a player with an active character → `CREATION_NOT_GRANTED`) → `WCIdentity.validate` (skipped for appearance-only repair) → `AppearanceSchema.sanitize` with creator sections; starting clothing restricted to `Config.Creator.startingClothing` → `TriggerEvent('w_creators:server:characterCreated', src)` → `Bridge.RegisterCharacter` (with the identity `dob`) → appearance row + `starter` ownership in one transaction. `{appearance, charid}`; a repeated token returns the same result |
| `w_creators:characters:keepAlive` | `token` | renews the creation grant's 30-minute TTL while the editor is open. The client pings it once a minute (`client/creator/creator.lua` `startKeepAlive`). Without it the grant was issued once and never renewed, and the editor makes no other server call between `beginCreate` and `create` — so a character that took longer than the TTL to build was refused at the save with `CREATION_NOT_GRANTED` and lost. `RATE_LIMITED` above 3 per 10 s; `CREATION_NOT_GRANTED` when the token does not match, the grant is gone, or a character is already active. `{expires}` |
| `w_creators:characters:cancelCreate` | `token` | releases the grant |
| `w_creators:characters:delete` | `charid, confirmText?` | service `characterDeletion`; ownership; when `typedConfirmation`, `confirmText` must equal the character's full name. `BUSY` for the character in play, the one being loaded, the one the framework still has logged in (switch, repair, provisioned creation) or the one being switched away from. Deletes framework character + appearance + owned clothes + outfits (`Bridge.DeleteCharacter`), then waits up to 5 s for the framework row to disappear; `DATABASE_ERROR` when the framework refused, the row survived or the appearance transaction failed. When the framework row is gone but the appearance cleanup failed, the charid is remembered for that player: a retry of `delete` for it runs only the appearance cleanup (no ownership check, no violation log) and forgets it once it succeeds; a cleanup still owed when the player drops is attempted once more in the background. With w_core, its `DeleteCharacter` purges this resource itself (`exports.w_creators:PurgeCharacter` → `WCCharacters.purge`) before it answers; the delete then removes nothing more and records no cleanup. `busy` from w_core (a purge that waited too long for a writer) answers `BUSY`; `economy_not_ready`, `funds`, `loan` and `assets` still map to `ECONOMY_NOT_READY` / `DELETE_HOLDS_*` for an older w_core. `{charid}` |
| `w_creators:server:creationReady` | legacy net event | same as `characters:loaded` |
| `w_creators:server:characterActivated` | server-local `(src, charid, sex)` | a character became active (selection, creation, restart adoption) |
| `w_creators:server:characterCleared` | server-local `(src, charid, reason)` | the active character was cleared (`switch`, `dropped`, …); grooming writes the leaving character's growth |

### 16.2 Scene
| Callback | Args | Behaviour |
|---|---|---|
| `w_creators:scene:prepare` | — | isolates the player in bucket `src` **only if** the player has no active character, is switching characters (server-tracked), or holds a store session with a fitting room **and stands at that store** (`WCSessions.withinRange`: its anchor — the client isolates before the teleport — or its fitting stand; a fitting isolation is released by a periodic check, `WCScene.FITTING_CHECK_MS` = 5 s, once the player is away or the session gone). For a player with an active character and no fitting-room session it **starts the guarded switch** (`WCCharacters.beginSwitch`), so the selector's order prepare → list works mid-game. Records the bucket the player was in. `{bucket, reason}`; refusals: `SERVICE_DISABLED` / `BUSY` (switch refused, not logged as a violation), `SESSION_NOT_FOUND` (nothing allows isolation; logged as `security_violation`) |
| `w_creators:scene:registerPed` | `netId` | unchanged checks (owner, model, distance from anchor, player isolated) |
| `w_creators:scene:release` | — | `{released, bucket?}`: restores the bucket the player was in before isolation, **only if** w_creators set the current bucket and the player is still in it; idempotent; rate-limited (6 / 10 s, shared with the legacy `rejoinWorld` event) → `RATE_LIMITED` |
Legacy net events `w_creators:server:isolate`, `PersonaCreatorHandler.setPlayerRoutingBucket`,
`PersonaCreatorHandler.setRoutingBucket`, `w_creators:server:rejoinWorld` map to the same guarded
functions but never start a switch (refused and logged). A store session's close releases its
fitting-room bucket; resource stop resets only tracked buckets.

### 16.3 Spawn / respawn
| Name | Kind | Behaviour |
|---|---|---|
| `w_creators:spawn:choose` | callback `pointId` | requires `SpawnPending[src]` (else `SPAWN_NOT_PENDING`, logged); `'__last'` needs `lastLocation` service + valid last position; otherwise an enabled point id (`INVALID_SPAWN`; a refused choice keeps the grant). Resolves coords server-side and clears the grant. Kinds `initial`/`login`/`switch`: bucket 0, fires `w_creators:client:spawn(pos, {kind})`. Kinds `admin`/`death`: bucket untouched, fires `w_creators:client:respawn(pos, {kind, point})` (§11). `{pos, kind}`. Legacy event `w_creators:server:spawnAt` → same (an unknown id falls back to the first enabled point). Net event `w_creators:server:spawnCancel` (rate-limited): the client cancelled an in-world selector — only an `admin` grant is withdrawn |
| `w_creators:client:selectSpawn` | server→client | `{last = {x,y,z,heading,label}|nil, points = [enabled point ids in order], kind}` |
| `w_creators:client:spawn` | server→client | `(pos {x,y,z,heading}, meta {kind = 'initial'|'login'|'switch'})` — w_core listens to this name (a fresh login) |
| `w_creators:client:respawn` | server→client | `(pos, meta {kind = 'admin'|'death', point})` — a player already in the world is moved (admin respawn, `RespawnPlayer`, an admin spawn choice) |
| `wc_respawn <citizenId> [pointId]` | command | console or `Config.Admin.ace`; rate-limited before the ACE check; `#<n>` = server id n |

### 16.4 Service sessions
| Callback | Args | `data` |
|---|---|---|
| `w_creators:store:open` | `locationId` | `{token, appearance, owned (+ pricePaid, currency, colors per row), prices = {[category] = price} (every category the store sells to that sex for cash, after the pricing profile), priceSpecs = {[category] = {cash?, gold?}}, currencies, tintPrice, tintPrices, storeProfile, pricingProfile, preview = {x, y, z, w, heading} or nil, outfits (read only), outfitsEnabled, maxOutfits, resell, expiresIn}`; a degraded saved appearance → `INTERNAL_ERROR`; a location `access` rule → `ACCESS_DENIED` |
| `w_creators:store:commit` | `token, opId, app, extra?` | `extra = {currency?, outfitName?}` → `{appearance, charged, currency, purchases = [{category, hash, price, tint?, dyed}], outfit?}` — only changed categories are priced (§5.4), in the chosen currency (`CURRENCY_NOT_ACCEPTED`); an owned colour is free (colourways); `outfitName` saves the look as an outfit in the same transaction (checked before any charge); states of swapped/removed items reset (§5.5); `appearance_changed` lists `clothing` (+ `states` when they changed); one `clothing_purchased` log per item |
| `w_creators:store:resell` | `token, hash` | `{refunded, currency, hash, owned}` — a store session (a wardrobe one with `resell.inWardrobe`); only an item bought with a recorded price, not worn, in no outfit (`NOT_RESELLABLE`, `ITEM_WORN`, `ITEM_IN_OUTFIT`); rows deleted first, then `price_paid × percent` refunded in its currency; logs `clothing_sold` |
| `w_creators:locations:access` | — | `{[locationId] = boolean}` for the locations with an `access` rule (the client hides their prompt); rate-limited |
| `w_creators:wardrobe:open` | `locationId|nil` | `{token, appearance, owned (worn-only entries `{source = 'worn', worn = true}`), outfits = [{id, name, data}], maxOutfits, outfitsEnabled, remote, expiresIn}`; a remote session after `allowRemote` was turned off → `LOCATION_NOT_FOUND` |
| `w_creators:wardrobe:commit` | `token, opId, app` | `{appearance}`; `ITEM_NOT_OWNED`, `NO_CHANGES`; no ownership write |
| `w_creators:outfits:save` | `token, name, equipped, states, tints?` | `{outfit, outfits}` (needs an open wardrobe session, `savedOutfits` + `wardrobe` services, the player in range, a per-character lock; logs `outfit_saved`; each tint an owned colour of the item, `false` its original) |
| `w_creators:outfits:update` | `token, id, equipped, states, tints?` | `{outfit, outfits}` |
| `w_creators:wardrobe:wrap` / `w_creators:outfits:share` | `token, hash` / `token, id` | `Config.Clothing.items` only (off by default): a garment becomes an inventory item / an outfit card is given (CLOTHING.md §15) |
| `w_creators:outfits:rename` | `token, id, name` | `{outfit, outfits}` |
| `w_creators:outfits:delete` | `token, id` | `{outfits}` |
| `w_creators:barber:open` | `locationId` | `{token, appearance, growth, services = {hair={enabled,price}, facialHair={enabled,price}, details={enabled,price,eyebrows,makeup}} (prices already multiplied), multiplier, visitCap? (cap × multiplier, rounded; nil = no cap), sections (a set: `{hair = true, …}`), location, expiresIn}`; an offered service without a valid price → `INVALID_PRICE` (a price of 0 must be explicit); a degraded saved appearance → `INTERNAL_ERROR` (also `surgery:open`, before its grant is used) |
| `w_creators:barber:commit` | `token, opId, app` | `{appearance, charged, sections = [changed section names]}` |
| `w_creators:surgery:open` | `clinicId` | `{token, appearance, price, allow, sections (set), owned? (only when `allow.clothing`: `WCOwnership.list(charid)`; a failed read closes the session → `DATABASE_ERROR`), clinic, expiresIn}`; at a clinic with `prompt = false` without a live grant → `SURGERY_NOT_ALLOWED` (§13); the grant is consumed only by an open that succeeds |
| `w_creators:surgery:commit` | `token, opId, app` | `{appearance, charged, sections = [changed section names]}`; `SURGERY_NOT_ALLOWED`, `NO_CHANGES` (clothing-state differences are no change), `ITEM_NOT_OWNED {category}` when clothing is allowed |
| `w_creators:session:close` | `token` | ok for any known or unknown token (idempotent); `RATE_LIMITED` / `INVALID_PAYLOAD` on abuse (more than 10 calls in 10 s; a token that is not a string or longer than 128 characters); a running commit keeps its session and closes it when it fails. Registered by `WCSessions` |
| `w_creators:session:result` | `token, opId` | the recorded answer of that commit (120 s replay cache, also after the session closed); `BUSY` while it still runs; `SESSION_NOT_FOUND` when nothing was recorded. Read only. The client asks after closing a flow that ended (cancel, death, forced close) with an uncertain commit answer (`INTERNAL_ERROR` / `BUSY`): ok → the committed look is taken; still unknown → `appearance:reload`. Rate limited (10 / 10 s). Registered by `WCSessions` |
| `w_creators:client:sessionClosed` | server→client `(token, reason)` | forced close — `reason ∈ expired | stopped | character | replaced` (a drop has nobody to tell; `commit`/`close` are known to the client) → the client closes its editor, restores the snapshot and leaves the preview |

Every `open` result carries the session `token` and `expiresIn` (seconds); every commit is
`WCSessions.commit(..., {kind = <kind>})`, so a token of another kind is `SESSION_NOT_FOUND`.

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
| `w_creators:client:grooming` | server→client `(app)` | hair/beard stage changed; `client/appearance/sync.lua` stores and renders it like `applyAppearance` |
| `w_creators:client:openSurgery` / `openStore` / `openBarber` / `openWardrobe` | server→client `(locationId)` | server exports; the client then calls the matching `open` callback (which re-validates) |
| `w_creators:server:characterCreated` | server-local `(src)` | fired before the framework login of a new character (w_lib) |
| `w_creators:server:appearanceChanged` | server-local `(src, charid, kind)` | after any committed appearance change; `kind ∈ store | wardrobe | clothingState | barber | surgery | api` |
| `w_creators:server:requestAppearances` | legacy net event | the cached appearances of the other players, sent to the requester only (2 / 10 s; never the requester's own) |
| `w_creators:dev:allowed` | callback `(command)` | `SERVICE_DISABLED` unless `Config.Admin.devTools`; only `wc_inspect`, `wc_apply`, `wc_remove`, `wc_restore` (else `INVALID_PAYLOAD`); the player must hold `Config.Admin.devAce` (else `SERVICE_DISABLED` with the developers-only message, logged as a violation); rate-limited (10 / 10 s). The client dev commands run only after an ok |
| `W:ADMIN:SpawnObject` | server→client `(model)` | dev tool, only when `Config.Admin.spawnProp`: the ACE-restricted `spawnprop <model>` command (`server/dev/tools.lua`) sends it to the caller; `client/dev/tools.lua` handles it (valid model → an object on the ground at the player's position, deleted when the resource stops) |

## 17. Client flows per domain (who calls what)

- **Selector** (`client/characters/selector.lua`): `scene:prepare` (also starts the server-tracked
  switch mid-game; on `SERVICE_DISABLED`/`BUSY` show `locale(result.message)` and stop) → `list` →
  preview peds via `CreatorScene.create` (one at a time) → the info panel via
  `WCEditor.showCard(card)` (§8.1) → select/create/delete → on `select` ok: `WCState.set(app)`,
  `Appearance.RestorePlayer(app)`, then `characters:loaded`; on `{needsAppearance, token}`: the
  creator in appearance-only mode → `create(token, nil, app)` → `loaded`. The final exit calls
  `CreatorScene.release({unload = true})` once the player has left the room.
- **Creator** (`client/creator/creator.lua`): `beginCreate` → gender scene (`WCCamera.openPair`) →
  pick → `WCEditor.open(ped, 'creator', AppearanceSchema.default(sex), {sections = all, identity = {...},
  working = draft, keepDraft = true, keepCamera = true, onCommit = create})` (cancel hands the draft
  and the typed identity back; the gender scene shows again without a re-render) → save:
  `beginCreate(sex)` → `create` → on ok: `Appearance.SetPlayerModel(sex)`, `RestorePlayer(app)`,
  `CreatorScene.release({unload = true})`, `characters:loaded`.
- **Store / wardrobe / barber / surgery**: `<kind>:open` → (store: fitting-room teleport + isolation;
  others: stay in place, frozen) → `WCPreviewEnv.enter` → `WCEditor.open(PlayerPedId(), mode,
  data.appearance, {sections = data.sections, context = <the open data, unchanged>, onCommit =
  <kind>:commit})` → on success `WCState.set(result.appearance)` + `Appearance.RestorePlayer`; on
  cancel/close/death/resource stop **or `w_creators:client:sessionClosed(token)`**:
  `Appearance.RestorePlayer(snapshot)`, `session:close`, `WCPreviewEnv.exit`, leave fitting room.
  Barber passes `multiplier`/`visitCap` in `context` (they are in the open data). The wardrobe passes
  `onOutfit` (the `outfits:*` callbacks for `save`/`update`/`rename`/`delete`; `'equip'` may return
  nil). Surgery's `context.owned` is the `owned` list of its open data (present only when the clinic allows
  clothing).
- **Surgery at a clinic with `prompt = false`**: the doctor resource's client prompt → its own
  server → `exports.w_creators:OpenCosmeticSurgery({source, clinicId})` (validates, grants once, 60 s)
  → `w_creators:client:openSurgery(clinicId)` → `WCSurgery.open(clinicId)` → `surgery:open` consumes
  the grant → the flow above. A direct `surgery:open` without the grant is `SURGERY_NOT_ALLOWED`.
- **Server-opened services**: `w_creators:client:openStore|openWardrobe|openBarber|openSurgery
  (locationId)` → the matching `WC<Kind>.open(locationId)` (the `open` callback re-validates).
- **Clothing actions** (`client/clothing/states.lua`): keybind/command/export → `WCPanel.open` with
  the tree from `WCClothingStates.actions(WCState.appearance)` → action: optional animation (timeout,
  cancel-safe) → apply locally → `clothing:setState` → on failure revert to the previous state.
- **Spawn** (`client/spawn/`): `selectSpawn` → selector → `spawn:choose(pointId)`; `client:spawn` →
  safe spawn (§11); `client:respawn(pos, {kind, point})` → move the living player (no login flow).
- **Respawn** (`client/respawn/respawn.lua`): state machine; `Resurrect` export; post-resurrect
  `Appearance.RestorePlayer()`.
- **Own appearance** (`client/appearance/sync.lua`): `applyAppearance`, its legacy alias and
  `grooming` → `Appearance.Sync.applyOwn`; the pre-v3 `bridge/client.lua` handlers are retired
  (`sync.lua` owns `applyRemoteAppearance` and the `requestAppearances` request).
- **Dev tools** (`client/dev/tools.lua`): with `Config.Admin.devTools`, `wc_inspect` / `wc_apply` /
  `wc_remove` / `wc_restore` → `w_creators:dev:allowed(command)` → the local-only action (refused
  while an editor, a service visit, the character scene or a flow lock is active). With
  `Config.Admin.spawnProp`: `W:ADMIN:SpawnObject(model)` (§16.5) → model name or hash → valid model
  only → object on the ground at the player's position through the library/native wrappers (deleted
  on resource stop).
- **Locations** (`client/services/locations.lua`): builds prompts/blips/NPCs for every usable
  location of every enabled service type (`WCLocations.active`), except locations with
  `prompt = false`, dispatching to `WCStore.open(id)`, `WCWardrobe.open(id)`, `WCBarber.open(id)`,
  `WCSurgery.open(id)`; rebuilds on language change; removes everything on resource stop.

## 18. Contract changes log

- **Wave A integration.** The contract was aligned with the implemented modules: pipeline order with
  a body commit before the morph and overlays last (§3.2, precautions from review findings 3 and 9 of
  the client infrastructure); `WCurtain.held/restore`, `CreatorScene.load/unload/release(opts)`
  (§3.2); editor opts, veto `equip` hook, character card builder, store price/state parity (§3.2, §5.4,
  §5.5, §8); `WCSessions.commit(..., {kind})`, the `session:close` callback and the `sessionClosed`
  notifications (§3.3, §16.4); `Bridge.RegisterCharacter` dob / `Bridge.DeleteCharacter` result (§3.3);
  `beginCreate(sex?)`, `characterActivated/Cleared`, delete `BUSY`/`DATABASE_ERROR`, prepare-starts-switch
  and the 2-minute restart window (§9.1, §16.1, §16.2); admin/death spawns through `client:respawn`
  (§11, §16.3); export details, the shared `WAIST_TYPES`, `bodyWeight` as a waist hash and the
  one-use surgery grant for `prompt = false` clinics opened through the server export (§3.1, §13, §17).
- **Final integration (after wave B).** The client has no os library: `WCUtil.today()` and the
  server clock in `GlobalState` (`w_creators:hour`, `w_creators:today`; §3.1, §3.3, §7.2); the
  `service` client lock and `canSwitch` refusing a service visit (§3.2); `identity.locked` for the
  creator's repair path (§3.2); the `w_creators:dev:allowed` callback (§16.5, §17);
  `Config.Creator.cutscene` holds the ride's coordinates and `Config.Keys.clothingActions` the keybind
  default; per-value clips in `Config.ClothingStates.animations`; the module APIs of wave B
  (§3.2, §11, §12, §13); the fixed header wordmark (§0.7); the pending locale queues merged and the
  pre-v3 files removed (§2). Enforced by `tests/test_locale_coverage.py`, `tests/test_static_hygiene.py`
  and `tests/test_global_symbols.py`.
- **Final gaps (server/shared side of the client review round 3).** The store keeps an owned item's
  stored dye when it is re-worn (free, not `INVALID_TINT`; `AppearanceSchema.mergeSections(saved,
  submitted, allowed, opts)` with `opts.storedTints`, also used by the wardrobe) and resets a dye only on
  an explicit original colour (§5.4); `WCOverlays.UNTINTED` / `WCOverlays.tintable` (layer `tint = false`
  for the 8 blend-type-1 layers, read by the client renderer) and `sanitize` stores their colour as 1, so
  a colour-only change is `NO_CHANGES`; a repeated `characters:loaded` replays the last answer while its
  activation stands (§16.1); `OpenSpawnSelector` and an admin respawn answer `BUSY` while w_ambulancejob
  reports the player dead, downed or in a bed (`WCSpawnServer.heldByDeathOwner`, §11, §13);
  `GlobalState['w_creators:clinics']` is published by `WCSurgeryService.publishClinics` at start and on
  the clock tick (`WCSessions.onClock`, §3.3). Enforced by `tests/test_final_gaps.py`.
