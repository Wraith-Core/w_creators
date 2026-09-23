# Appearance (v3)

Operator reference for the character appearance: the stored shape, the pre-v3 migration, how a ped is
drawn, and how other players see it. The code is the source of truth. The main files are:
`shared/appearance.lua` (`AppearanceSchema`), `shared/morphology.lua` (`WCMorph`), `shared/overlays.lua`
(`WCOverlays`), `server/appearance/repository.lua` (`WCAppearanceRepo`), `server/appearance/sync.lua`
(`WCSync`), `client/appearance/pipeline.lua` (`Appearance`), `client/appearance/overlays.lua` and
`client/appearance/sync.lua`. The binding contract is in [ARCHITECTURE.md](ARCHITECTURE.md) §5, §6 and §9.4.

> **Test status.** Everything below comes from reading the code and from the automated tests
> (`tests/`), which run the Lua modules against stubs. Nothing was run on a live RedM server.
> Anything that depends on the game engine is marked **requires live verification**: how the
> metaped renders, native behaviour, streaming, and OneSync scope.

---

## 1. The v3 model

One authoritative shape (`AppearanceSchema.VERSION = 3`):

| Field | Type / range | Notes |
|---|---|---|
| `version` | `3` | |
| `sex` | `'male'` \| `'female'` | the model is `mp_<sex>`. It never changes after creation (`mergeSections` keeps the saved sex) |
| `body.upper` | u32 hash of `BODIES_UPPER` | **essential**. Its model number is the "body type" |
| `body.lower` | u32 hash of `BODIES_LOWER` | **essential**. It is paired with the upper body by asset name (`UPPER`→`LOWER`) |
| `body.height` | float `0.9..1.1`, default `1.0` | the ped scale, always a float |
| `body.weight` | int `1..21`, default `11` | a 1-based index into `AppearanceSchema.WAIST_TYPES` (21 waist outfit hashes) |
| `head.head` | u32 hash of `heads` | **essential**. Its model number is the "base head" |
| `head.eyes` | u32 hash of `eyes` | **essential** |
| `head.teeth` | u32 hash of `teeth` | **essential** |
| `morph[<expression>]` | float `-1..1` | face and body morphology in one map. A value of `0` is omitted. Only the `WCMorph` fields (§4) |
| `hair.style` | u32 hash of `hair` or `0` | |
| `hair.facial` | u32 hash of `mustache` or `0` | always `0` for a female character |
| `overlays[<layerId>]` | `{ style = 1..N, color = 1..64, opacity = 0..1 }` | an absent layer is off (§5) |
| `clothing.equipped[<category>]` | u32 hash | clothing categories only, never body parts (see [CLOTHING.md](CLOTHING.md)) |
| `clothing.tints[<category>]` | `{ palette, tint0, tint1, tint2 }` (ints `0..254`) | only for an equipped category |
| `clothing.states[<groupId>]` | state value | persisting groups only (see [CLOTHING_STATES.md](CLOTHING_STATES.md)) |
| `clothing.outfit` | int `1..2147483647` or nil | the id of the saved outfit being worn |
| `grooming.hair` / `grooming.beard` | `{ stage = 0..99, seconds = 0..864000 }` | owned by the server. A client submission never sets it |

Defaults: `AppearanceSchema.default(sex)` resolves named assets through `WCCatalog`, falling back to the
first catalogue item. Male: head `CLOTHING_ITEM_M_HEAD_008_V_001`. Female: head `..._F_HEAD_001_V_001`.
Both sexes get body `..._BODIES_UPPER_001_V_001` / `_LOWER_001_V_001`, eyes `..._EYES_001_TINT_014`,
teeth `..._TEETH_000` and hair `..._HAIR_001_BLONDE`. The default clothing is the first item of
`shirts_full`, `pants` and `boots`, plus eyebrows `{ style = 1, color = 1, opacity = 0.85 }`.

### 1.1 Sections

`AppearanceSchema.SECTIONS` = `identity, body, face, eyebrows, skin, eyes, hair, facialHair, makeup,
clothing, states`. Each domain may change only its own sections (`mergeSections`, §6):

| Section | Fields |
|---|---|
| `body` | `body.upper`, `body.lower`, `body.height`, `body.weight`, morph fields of section `body` |
| `face` | `head.head` (model), `head.teeth`, morph fields of section `face` |
| `eyes` | `head.eyes` |
| `skin` | the skin tone (§3), overlays of section `skin` |
| `eyebrows` | overlay `eyebrows` |
| `hair` | `hair.style`, overlay `hairov` |
| `facialHair` | `hair.facial`, overlay `beardstabble` |
| `makeup` | overlays of section `makeup` |
| `clothing` | `clothing.equipped`, `clothing.tints`, `clothing.outfit` |
| `states` | `clothing.states` |

Which domain may change which sections:

| Writer | Sections |
|---|---|
| store (`server/clothing/store.lua`) | `clothing` |
| wardrobe (`server/wardrobe/wardrobe.lua`) | `clothing`, `states` |
| barber (`Barber.SERVICE_SECTIONS`) | `hair`; `facialHair`; `details` = `eyebrows` + `makeup` (per enabled service) |
| surgery (`EDITABLE` in `server/surgery/surgery.lua`) | `body, face, eyebrows, skin, eyes, hair, facialHair, makeup, clothing` (limited by the clinic's allowed set) |
| `SetSkin` export (`BUCKET_SECTIONS`) | `body, face, eyes, skin, hair, facialHair, eyebrows, makeup` |
| `SetClothes` export | `clothing` |
| degraded-character repair (`REPAIR_SECTIONS`) | `body, face, eyebrows, skin, eyes, hair, facialHair, makeup` |

### 1.2 Storage columns (`characters_appearence`)

| Column | Role |
|---|---|
| `appearance` (LONGTEXT) | the v3 JSON. Authoritative when `appearance_version >= 3`. It also holds a top-level `projection` key (the fingerprint of the legacy columns, §2.3), which is never part of the returned appearance |
| `appearance_version` (INT, default 2) | `3` after any v3 write |
| `updated_at` | set on every v3 write |
| `isMale`, `components`, `faceFeatures`, `overlays` | the **legacy projection**, rewritten on every save from `AppearanceSchema.toLegacy` so that rolling back to the pre-v3 release still loads the character |
| `name`, `age` | written by `WCAppearanceRepo.create`. They are the fallbacks for the selection cards |

Migrations `001`–`004` (`server/core/migrations.lua`, `sql/install.sql`) only add columns and tables.
`appearance_version` defaults to `2`, so a row that has not been upgraded is read as legacy.

### 1.3 The legacy projection (`toLegacy`)

`toLegacy(app)` writes the v2 shape as JSON strings:

- `isMale` = `1` or `0`.
- `components` holds `heads, eyes, teeth, BODIES_UPPER, BODIES_LOWER, hair`, `mustache` (male only),
  every equipped clothing hash, `__version = 2`, `__scale` (height), `__waist` (weight),
  `__expressions` (the morph fields that are not legacy face features) and `__grooming`.
- `faceFeatures` is a list of `{ hash = <expression id>, index = <value> }` for the 39 fields the
  pre-v3 creator stored by hash (`LEGACY_FACE_FEATURES`), sorted by hash.
- `overlays` is a list of `{ compType = <layerId>, offsetModel = style, offsetVariation = color,
  opacity }` in layer order.

**Not projected:** clothing tints, clothing states and the outfit id. A rollback to the pre-v3
release loses them.

---

## 2. Legacy (v1 / v2) → v3 migration

### 2.1 Detection

`AppearanceSchema.normalize(raw)` accepts a v3 table, a JSON string or a legacy row, and never throws.

- A table with `version == 3` goes through `sanitize(rules = false)`.
- Anything else goes through `fromLegacy(row)`.
- In `fromLegacy`, the row is **v1** when any non-`__` component value is a table without a `hash`
  field (a `{ model, variant }` array). Otherwise it is **v2** (hashes).
- A v1 `{ model, variant }` resolves through `WCCatalog.resolve`. Model numbers skip empty catalogue
  groups, exactly as the pre-v3 resource numbered them.

### 2.2 Field mapping (`fromLegacy`)

| Legacy | v3 | Rule |
|---|---|---|
| `isMale` | `sex` | `true`, `1`, `'1'`, `'male'` or `'true'` give `male`. Anything else gives `female` (`sexOf`) |
| `components.heads` / `eyes` / `teeth` | `head.head` / `eyes` / `teeth` | essential. Missing or invalid → the sex default, and the section is reported in `defaultsUsed` |
| `components.BODIES_UPPER` | `body.upper` | essential |
| `components.BODIES_LOWER` | `body.lower` | if the key is absent (old creators stored only the upper body), it is paired by name from the upper body. If that fails → default, `body` is reported |
| `components.hair` | `hair.style` | absent → the default hair. Present but invalid → `0` |
| `components.mustache` | `hair.facial` | male only |
| `components.__scale` | `body.height` | clamped to `0.9..1.1`, default `1.0` |
| `components.__waist` | `body.weight` | clamped to `1..21`, default `11` |
| `components.__expressions` (by name) + `faceFeatures` (`{hash, index}` by expression id) | `morph` | merged. For the same field, `faceFeatures` wins |
| `overlays` (`{compType, offsetModel, offsetVariation, opacity}`) | `overlays[compType]` | `style = offsetModel`, `color = offsetVariation`. The first entry per layer wins and `offsetModel < 1` is skipped. A NULL `overlays` column → default eyebrows |
| every other non-`__` clothing category | `clothing.equipped` | kept as stored: `WCRules` are **not** applied. A hash not in the catalogue is left out and listed in `meta.dropped` (logged) |
| `components.__grooming` | `grooming` | |
| — | `clothing.tints`, `clothing.states`, `clothing.outfit` | empty |

The result goes through `sanitize(sex = <row sex>, rules = false)`. `meta = { version = 1|2,
defaultsUsed = { section... }, violations, dropped }`.

### 2.3 Write-back rules (`WCAppearanceRepo.load`)

| Row state | What happens |
|---|---|
| `appearance_version < 3`, or `appearance` NULL / not v3 JSON, and **no** essential defaults | Upgraded. The v3 JSON (with the fingerprint of the columns as they are) is written, together with `legacy` ownership grants for the equipped clothing (`INSERT IGNORE`), in **one transaction**. The legacy columns are not rewritten here. If the write fails, the grants are owed and join the next save's transaction |
| same, but essential defaults were needed | **Nothing is written** (data is never silently replaced). The in-memory appearance uses defaults, a warning is logged, and the character is **degraded** (§2.4). The `legacy` grants are still owed to the repair save |
| `appearance_version >= 3` but JSON unreadable | **Recovered** from the projection (`meta.recovered`) **without** `legacy` grants. Tints, states and outfit are lost, and this is logged |
| v3 JSON readable, stored fingerprint differs from the current columns (an older release wrote them after the last v3 write, e.g. a rollback) | **Reconciled.** The look is rebuilt from the columns with `fromLegacy`, keeping the v3-only data that still applies: tints of items still worn, states of unchanged items (`WCOwnership.settleStates`), and the outfit id if the worn set is unchanged. It is written back with the new fingerprint and logged (`meta.reconciled`). Skipped (v3 kept) if a column is NULL, empty or not JSON, or if the rebuild needs essential defaults |
| v3 JSON without a `projection` key (written before the fingerprint existed) | trusted as is |

The fingerprint is two FNV-1a hashes plus the text length, computed over `sex`, `components`,
`faceFeatures` and `overlays` (`WCAppearanceRepo.fingerprint`).

> **Do not hand-edit the legacy columns of a v3 row expecting them to be ignored.** A valid edit
> replaces the v3 JSON on the next load and drops the tints of the items it changed.

Console command `wc_migrate_appearances` (server console only; a player source is ignored) upgrades
every row with `appearance IS NULL OR appearance_version < 3` in batches of 100. It prints
`scanned` and `upgraded`. A degraded row counts as scanned, not upgraded.

### 2.4 Degraded rows

A character whose loaded appearance needed essential defaults (`meta.degraded`,
`WCAppearanceRepo.degraded(charid)`):

- `WCAppearanceRepo.save` refuses it (`INTERNAL_ERROR`) unless `opts.replaceDegraded = true`. Only the
  creator's appearance-only repair path, which `w_creators:characters:select` offers for a degraded character,
  passes that flag.
- Store and wardrobe **open** refuse it up front (`INTERNAL_ERROR`), and their commits refuse it again
  before charging.
- The owed `legacy` grants join the repair save's transaction. That save makes the row v3, so the lazy
  upgrade never runs again.

### 2.5 Operator checklist for an upgrade

1. Back up `characters_appearence` and `w_creators_clothes`.
2. Start the resource. The migrations add the columns (check the console for `migrations`
   warnings).
3. Optional: run `wc_migrate_appearances` in the server console. Otherwise rows upgrade lazily on
   first load.
4. Search the logs for `not upgraded`, `needed defaults` and `left out`. Those rows are degraded or
   lost clothing that is not in the catalogue, and need a manual look.

---

## 3. Skin tone

The skin tone is **not** a separate stored value. It is the shared `_V_nnn` variant number in the asset
names of `head.head`, `body.upper` and `body.lower`.

| Function | Rule |
|---|---|
| `AppearanceSchema.skinTone(app)` | the head's `_V_` number (nil when the head name carries none) |
| `setSkinTone(app, tone)` | tone int `1..999`. It rewrites head, upper and lower to that variant when it exists in the catalogue, and returns true only if the head took the tone |
| `setHead(app, model)` / `setBodyType(app, model)` | change the model and keep the current tone. If the new model has no variant in that tone, the variant at index `tone` is used, clamped to the model's variant count. The body type re-pairs the lower body by name |
| `sanitize` | repairs mismatched bodies to the head's tone (violation `tone`). If a body model has no variant in that tone, it is reported (`tone_unavailable`) and not guessed |
| `mergeSections` | the tone changes **only** through the `skin` section. A submitted head or body model with no variant in the kept tone falls back to the saved part |

The editor's `skin.tone` control offers the tones that exist for the current head model.

---

## 4. Morphology

`WCMorph` builds the tree from `shared/morphology.lua`. Field ids are w_lib expression names. The
numeric ids are read at runtime from `w.component.data.expressions` and never hardcoded. A w_lib
expression that is not placed in the tree is logged. If the table is unavailable, no morph fields
exist. Storage is `-1..1`. The NUI shows `-100..+100`. Control id: `morph.<expressionName>`.

**63 expressions** (52 face + 11 body):

| Node | Expressions |
|---|---|
| Face › Base (`face.base`) | control `face.head` (base head model) |
| Face › Head shape | `headWidth` `faceWidth` |
| Face › Jaw | `jawWidth` `jawHeight` `jawDepth` `jawY` |
| Face › Chin | `chinWidth` `chinHeight` `chinDepth` |
| Face › Nose | `noseWidth` `noseHeight` `noseSize` `noseAngle` `noseCurvature` `nostrilsDistance` |
| Face › Cheekbones | `cheekbonesWidth` `cheekbonesHeight` `cheekbonesDepth` |
| Face › Mouth | `mouthWidth` `mouthDepth` `mouthX` `mouthY` |
| Face › Mouth › Left corner | `mouthConerLeftWidth` `mouthConerLeftDepth` `mouthConerLeftHeight` `mouthConerLeftLipsDistance` |
| Face › Mouth › Right corner | `mouthConerRightWidth` `mouthConerRightDepth` `mouthConerRightHeight` `mouthConerRightLipsDistance` |
| Face › Lips › Upper | `upperLipWidth` `upperLipHeight` `upperLipDepth` |
| Face › Lips › Lower | `lowerLipWidth` `lowerLipHeight` `lowerLipDepth` |
| Face › Ears | `earsWidth` `earsHeight` `earsAngle` `earsDepth` `earlobes` |
| Face › Eyes | `eyesDistance` `eyesHeight` `eyesAngle` `eyesDepth` `eyelidWidth` `eyelidHeight` `eyelidLeft` `eyelidRight` (+ control `eyes.color`, section `eyes`) |
| Face › Eyebrows | `eyebrowWidth` `eyebrowHeight` `eyebrowDepth` (+ control `overlay.eyebrows`, section `eyebrows`) |
| Face › Teeth | control `face.teeth` |
| Body › Build | controls `body.type`, `body.height`, `body.weight` |
| Body › Upper body | `shoulders` `shoulderThickness` `shoulderBlades` `chest` `arms` |
| Body › Torso | `waist` `hip` |
| Body › Legs | `thighs` `calves` |
| Body › Neck | `neckWidth` `neckDepth` |

The `Coner` spelling is w_lib's expression name. All face fields belong to section `face` and all body
fields to section `body`.

---

## 5. Overlays (head texture layers)

There are 18 layers (`WCOverlays`), all applied through `w.pedTexture` only. `id` is the legacy
`compType`. `library` is the `w.pedTexture` layer. Style N uses texture id `ids[N]`. Stored as
`{ style, color, opacity }`: `style` is clamped to the layer's style count, `color` to `1..64`, and
`opacity` to `0..1` (default 1). Control ids: `overlay.<layerId>.style|color|opacity`.

| Section | Layer id (`library`, styles) |
|---|---|
| `skin` | `complex` (complex, 14) · `disc` (disc, 16) · `ageing` (ageing, 24) · `freckles` (freckles, 15) · `moles` (moles, 16) · `spots` (spots, 16) · `acne` (acne, 1) · `scars` (scar, 16) · `grime` (grime, 16) |
| `makeup` | `foundation` (1) · `blush` (4) · `lipsticks` (lipstick, 1) · `eyeliners` (eyeliner, 1) · `shadows` (eyeshadow, 1) · `paintedmasks` (masks, 1) |
| `eyebrows` | `eyebrows` (eyebrow, 24) |
| `hair` | `hairov` (hair, 3) |
| `facialHair` | `beardstabble` (beard, 1). **Male only** |

- Colour N is `tint0 = N - 1` of the layer palette: `metaped_tint_hair` for eyebrows, hair and beard,
  `metaped_tint_makeup` for every other layer.
- The skin-section libraries (`Appearance.Overlays.UNTINTED`) are drawn by w_lib with blend type 1 and
  no palette, so their colour has no visible effect. **Requires live verification.**
- The whole head layer set is rewritten every time: `w.pedTexture.overwriteBodyPart(ped, 'heads', set,
  true)`, then `refreshNow`. `w.pedTexture` only acts on **networked** peds, so on an unnetworked ped
  the overlays are skipped (logged).
- Stored data (`rules = false`) keeps a layer of the other sex, such as a female beard shadow from the
  pre-v3 creator. The editors never add one, and the renderer does not draw it
  (`WCOverlays.allowed`).

---

## 6. `sanitize` and `mergeSections`

`AppearanceSchema.sanitize(app, opts)` returns `app, violations, defaultsUsed` and never throws.

- Every hash is checked against `WCCatalog` for the sex, numbers are clamped, and unknown keys, morph
  ids, overlay ids and state groups are dropped. Each drop is a `violation`.
- Missing or invalid essentials get the sex default, and their section is reported in `defaultsUsed`.
- `opts.sex` sets the sex authoritatively (the server-granted creation session or the saved
  character).
- `opts.rules = false` is the **stored-data mode** used by every repository read and write and by
  `normalize`/`toLegacy`. The equipped set is kept as stored (no `WCRules`), tints are checked only for
  structure (`WCCatalog.validStoredTint`, so a dye survives tints being disabled or narrowed), and
  other-sex overlay layers are kept. The default (edit) mode applies `WCRules.normalize` and the live
  tint config (`WCCatalog.validTint`).
- `opts.grooming = false` drops grooming (client submissions).
- Only persisting, valid clothing states are kept.

`mergeSections(saved, submitted, allowed)`:

- Only the `allowed` sections come from `submitted`. Everything else, and grooming, comes from `saved`.
  The sex never changes.
- An invalid submitted essential falls back to the saved part, never to a default.
- The clothing rules apply only when the submitted equipped set differs from the saved one.
- A saved item with its saved tint keeps that tint. Any other tint must pass the live tint config.
- The skin tone rule from §3.
- The result is sanitized with `rules = false`.

`changedSections(a, b)` compares the sections without the tone: body and head are compared by model,
and `skin` by tone plus skin overlays.

---

## 7. Render pipeline (`Appearance.RestoreCharacter`)

Every ped that shows a character (the player, a preview ped, a remote player) is drawn by one pipeline,
in this fixed order:

1. Validate the ped and the model (`mp_<sex>`). The error codes are `INVALID_PED`, `INVALID_PAYLOAD`
   and `MODEL_MISMATCH`.
2. Outfit preset `3` (`Appearance.PRESET`), then commit and wait until the ped is ready.
3. Clean slate: `w.component.removeAllClothes`, and remove `hair` and `mustache`.
4. `BODIES_LOWER`, `BODIES_UPPER`, `heads`, `eyes`, `teeth`.
5. Hair, then facial hair (male; the `mustache` category is metaped `0xF8016BCA`).
6. Waist type (`EquipMetaPedOutfit`, falling back to `w.component.setWaistType`), then height
   (`WCNative.ped.setScale`, always a float).
7. Clothing in `Config.Clothing.applyOrder` (then any other equipped category, sorted), each with its
   tint **when the live config allows it**. A tint the config forbids is left out: the stored dye is
   kept and drawn again once the config allows it. Items hidden by an `off` visibility state are not
   put on.
8. **Body commit** (refresh and ready). The waist outfit and the clothing must be committed before
   the morph and the wearable states.
9. Wearable clothing states. Applicable groups get their value. Equipped groups that do not apply are
   reset to `base`. Skipped with `opts.skipStates`.
10. Morph: every `WCMorph` channel is reset to `0.0`, then the stored values are set. **Final commit**
    and ready.
11. Overlays on the committed head (`w.pedTexture`). Skipped with `opts.skipOverlays`.

Behaviour of the pipeline:

- **Batching.** There are three structural commits (preset, body, final) and no refresh per feature.
- **Readiness.** `WCNative.metaped.isReadyToRender` is true **and** the head bone is more than 0.2 m
  from the entity origin, which catches a collapsed zero-scale skeleton. The timeout is 10 s
  (`READY_TIMEOUT`). If the ped is not ready after the final commit, the result is `NOT_READY`.
- **Serialisation.** Two restores of one ped never interleave. A second restore waits up to 15 s
  (`PED_WAIT_TIMEOUT`), then returns `BUSY`. `Appearance.RestorePlayer` also serialises the local
  player and switches the model first (`MODEL_TIMEOUT` 15 s).
- **Failures.** A component the engine does not know is reported in `failedCategories`, never thrown.
- **Incremental preview.** `Appearance.ApplyDiff(ped, before, after)` redraws only what changed. It
  falls back to the full restore when the sex, `body.upper`, `body.lower` or `head.head` changes.
  Removals go first, then additions, in apply order. A touched wearable state is re-applied after a
  commit of its item. A new waist re-applies every morph channel after a commit.

Every step that depends on the engine (commit timing, readiness, waist or morph interaction, overlay
compositing) **requires live verification**.

---

## 8. Multiplayer sync

RedM does not replicate metaped components, so every client draws the other players itself.

**Server (`WCSync`):**

- The last broadcast appearance of each player is cached per server id.
- `WCSync.broadcast(src, app)` sends `w_creators:client:applyRemoteAppearance(serverId, app)` to all
  players after a login, a store, wardrobe, barber or surgery commit, a creation, and the API writers.
- `WCSync.broadcastState(src, group, value)` updates the cache and sends
  `w_creators:client:remoteClothingState`.
- `WCSync.forget(src)` runs on `playerDropped` and sends `w_creators:client:forgetRemote`.
- A late joiner sends `w_creators:server:requestAppearances` once the network session has started
  (rate limited to 2 per 10 s). It receives every cached appearance except its own.
- `w_creators:appearance:reload` (callback) and the legacy `PersonaCreatorHandler.reloadCharacterAppearance`
  share one limit of 1 per 10 s. Both re-read the saved look and re-broadcast it. They are refused
  (`BUSY`) while a service session is open or a commit is in flight.
- A re-send that is not a change of the look (reload, grooming stage, `ApplyCharacterAppearance`
  export) adds the player's runtime states (`WCSync.withRuntimeStates`).

**Client (`Appearance.Sync`):**

- **Remote cache.** Stored per server id as `{ app, rev }`. A legacy payload is normalised. An
  identical look is not re-rendered.
- **Scope watcher.** Runs every 1 s (`Sync.INTERVAL`). The fingerprint is `ped handle : cache
  revision`. When a player's ped appears or changes (entering scope, respawn), the cached look is
  re-applied once. When a player leaves scope, the fingerprint, failure count and overlay set are
  forgotten, so the next ped is drawn fresh.
- **Concurrency.** At most 4 renders at once (`Sync.MAX_CONCURRENT`), each in its own thread. A
  fingerprint that fails 5 times (`Sync.MAX_FAILURES`) is given up until the ped or the look changes.
- **Incremental render.** Used when the same ped already shows the previous look (`ApplyDiff`).
  Otherwise the full restore runs.
- **Remote state delta.** Applied directly to the ped when it shows the cached look. Otherwise the
  fingerprint is cleared and the watcher re-renders.
- **Own appearance.** `w_creators:client:applyAppearance` (legacy alias
  `PersonaCreatorHandler.applyCharacterAppearance`) and `w_creators:client:grooming` go through one
  queue where the newest wins. While an editor is open, the look is stored but not rendered. A
  grooming stage redraws only hair and facial hair and keeps the runtime clothing states. The client
  export `RefreshAppearance` and the command `/reloadappearance` reload and keep the runtime states.
  Own-id payloads are ignored by the remote path.

Scope timing, handle reuse and remote overlay rendering **require live verification** on a OneSync
server with several clients.

---

## 9. Caching

| Cache | Key | Invalidation |
|---|---|---|
| `WCAppearanceRepo.cache` (server) | charid | every save, create, delete and `invalidate`, and `playerDropped`. A load caches only if no write happened while it yielded (per-character generation) |
| degraded flags / owed `legacy` grants (server) | charid | cleared by a successful repair save, create or delete |
| `WCSync` cache (server) | server id | replaced by each broadcast. Dropped on disconnect or character switch |
| `WCCatalog.forSex` (shared) | sex | built lazily once. Not cached while the w_lib catalogue is empty. `WCCatalog.reset()` |
| `AppearanceSchema.defaults` (shared) | sex | cached once the catalogue is available |
| remote cache / fingerprints (client) | server id | `forgetRemote`, a new payload, leaving scope |
| `Appearance.Overlays` applied set (client) | ped handle | pruned for deleted peds on every apply. `forget` / `reset` |

Without the w_lib catalogue (`w.component.getFullPedComponentList`), the repository refuses every
read and write (`INTERNAL_ERROR`), because an appearance cannot be validated.
