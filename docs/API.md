# w_creators — Public API

This page covers what other resources may call or listen to. The binding contract is
`docs/ARCHITECTURE.md` (§13 public API, §16 callback and event catalogue). Callbacks named
`w_creators:<domain>:<action>` belong to w_creators' own client. They are not an integration API:
use the exports below.

Nothing on this page has been run against a live RedM server. The behaviour described is what the
code does and what the unit tests (`tests/test_server_services_api.py`,
`tests/test_client_services_api.py`, `tests/test_client_states_*.py`,
`tests/test_client_spawn_respawn.py`, `tests/test_client_services_ambulance.py`) check. Anything
that depends on the game engine requires live verification (`docs/TESTING.md`).

## Server authority rule

The server decides every price, ownership, slot count, identity check, allowed section, spawn
coordinate, service and location toggle, and every stored value. A value that arrives from a client
or another resource is validated against the catalogue (`WCCatalog`), the config, the database and
the player's session. It is **refused, never repaired**. Consequences for integrators:

- Call the writing and opening exports on the **server**. Client exports only ask the server, and
  the server checks everything again (for example `OpenCosmeticSurgery` on the client cannot open a
  `prompt = false` clinic).
- Never send prices or coordinates. The server does not read prices from payloads, and spawn
  requests carry a point id (`'__last'` or a `Config.Spawn.points[].id`).
- The `Open*` exports send `w_creators:client:open<Kind>(locationId)`. The client then calls the
  matching `<kind>:open` callback, which validates everything a second time.

## Result shape

Every export that can refuse returns a `WCResult` (`shared/result.lua`):

```lua
{ ok = true,  code = 'OK', data = { ... } }
{ ok = false, code = 'BUSY', message = '<locale key>', data = { ... } | nil }
```

`message` is a key of w_creators' dictionary (`locales/*.json`), not translated text. Another
resource should use its own messages. The codes are listed in ARCHITECTURE.md §4.

## Server exports (`server/api.lua`)

Each export is also `WCApi.<name>`. The ones that read the database (`GetCharacterAppearance`,
`GetAppearance`, `SetClothes`, `SetSkin`, `ApplyCharacterAppearance`, `OpenCosmeticSurgery`,
`OpenSpawnSelector`, and `GetActiveCharacter` when the sex is unknown) **yield**. Call them from a
thread, an event handler or a callback, never from a plain `exports` evaluation at file load.

`src` must be a connected player's server id (a positive integer that `GetPlayerName` resolves).
Anything else returns `nil` (readers) or `INVALID_PAYLOAD` (writers and openers).

### Reading

| Export | Returns |
|---|---|
| `GetActiveCharacter(src)` | `{ charid, sex = 'male'|'female'|nil }` or `nil` (no active character) |
| `GetCharacterAppearance(src)` | a copy of the active character's v3 appearance (ARCHITECTURE.md §5.1) or `nil` |
| `GetAppearance(src)` | `{ skin, clothes, appearance }` or `nil`. The w_lib w_core bridge uses it (see below) |
| `IsBandanaUp(src)` | boolean: the player's bandana is raised over the face (a masked player, for police / wanted resources). The same answer is on the replicated player state bag `Player(src).state.wcBandanaUp` (`Config.ClothingStates.bandanaStateBag`), which other resources can read without calling this one |

`GetAppearance` shapes:

- `skin = { model = 'mp_male'|'mp_female', sex = 1|2, headHash, bodyUpperHash, bodyLowerHash,
  eyesHash, teethHash, hair = { hash }?, beards_complete = { hash }? (male only), bodyWeight,
  bodyScale, expressions, overlays }`.
  `bodyWeight` is the waist outfit hash `AppearanceSchema.WAIST_TYPES[body.weight]`. `bodyScale` is
  `body.height`. `expressions` is a copy of `app.morph` (w_lib expression names, -1..1).
  `overlays` is keyed by the `w.pedTexture` layer name: `{ id, opacity, palette, tint0 }`. There is
  no `bodyType`, because the body type is `bodyUpperHash`.
- `clothes = { [category] = { hash, palette?, tint0?, tint1?, tint2? } }` (the equipped items).
- `appearance` = a copy of the v3 appearance.

### Writing

**`SetClothes(src, clothes, overwrite)`** → Result `{ appearance, changed, sections }`

- `clothes = { [category] = hash | { hash (or comp), palette?, tint0?, tint1?, tint2? } | 0 }`.
  `0`, `-1`, `false`, or a table whose hash is `0`/`-1`/`false` removes the category.
- `overwrite = true` replaces the whole equipped set and its tints. Otherwise the listed
  categories are merged into the saved set.
- Validation (nothing is written on any refusal):
  - `clothes` must be a table of at most 64 KiB of JSON (`INVALID_PAYLOAD`).
  - Every key must be a clothing category, and every hash an item of that category offered to the
    character's sex (`INVALID_COMPONENT`, `data.category`).
  - A tint needs a palette of that category, given as a name or as a palette-name hash, with
    integer `tint0..2` (`INVALID_TINT`).
  - Items are equipped in `Config.Clothing.applyOrder` through the clothing rules. The rules code is
    returned. A requested item the rules drop gives `CONFLICTING_ITEMS`.
- No active character → `NO_CHARACTER`. An open service session or a held character lock →
  `BUSY`. A failed save → `DATABASE_ERROR`. A thrown error → `INTERNAL_ERROR`.
- Side effects when something changed:
  - The tint of an item replaced without a new tint is dropped, and the outfit id is cleared when
    the worn set changed.
  - Clothing states are settled: a state whose item is gone is dropped, and a swapped item starts
    visible.
  - The appearance is saved, `w_creators:client:applyAppearance` is sent to the owner, the look is
    broadcast to the other players, and `appearanceChanged(src, charid, 'api')` fires.
  - **No ownership row is added.** `SetClothes` dresses the character; it does not sell items.
- Nothing changed → `ok` with `{ appearance = <saved>, changed = false }`.

**`SetSkin(src, skin, overwrite)`** → Result `{ appearance, changed, sections }`

Only the sections `body`, `face`, `eyes`, `skin`, `hair`, `facialHair`, `eyebrows` and `makeup` can
change. Clothing is ignored and the sex never changes. `skin` is either:

- **A standard (framework-bridge) skin.**
  - `model`/`sex` (when present) must be the character's own (`'mp_male'`, `'male'`, `1`, or the
    female equivalents, or the model hash). Otherwise → `INVALID_PAYLOAD` (`data.field = 'sex'`).
  - `headHash`, `eyesHash`, `teethHash`, `bodyUpperHash` and `bodyLowerHash` must be catalogue items
    (`heads`, `eyes`, `teeth`, `BODIES_UPPER`, `BODIES_LOWER`) for that sex.
  - `hair` is a hash or `{ hash }`, and `0` removes it. `beards_complete` (or `mustache`) is male
    only.
  - `bodyScale` must be within 0.9..1.1. `bodyWeight` is a waist hash (signed or unsigned) or an
    index 1..21.
  - Each `expressions` id must exist in `WCMorph.byId`, with a value within -1..1 (a value above 1
    is read as a percent and divided by 100).
  - `overlays` are keyed by layer name or v3 layer id: `{ id | style, tint0 | color, opacity }`.
    Opacity 0..1 (or a percent ≤ 100); ≤ 0, `false` or `0` turns the layer off.
- **A v3 appearance** (`version = 3`). Its `sex` must equal the saved sex. Every value is checked
  as the schema checks it, but nothing is clamped or repaired. Only the fields it carries replace
  the saved ones (a body/head/hair field, a morph id, an overlay layer).
- `overwrite = true` replaces the whole morphology and overlay set, clearing them when left out.
  Otherwise the given values are merged.
- Refusals: `INVALID_PAYLOAD` / `INVALID_COMPONENT` with `data.field`, and `NO_CHARACTER`, `BUSY`,
  `DATABASE_ERROR`, `INTERNAL_ERROR` as for `SetClothes`.
- Hair and beard growth: pending growth is folded in before the save, and a changed hair or beard
  restarts that growth counter.
- The save, render, broadcast and `appearanceChanged(src, charid, 'api')` happen as for
  `SetClothes`.

**`ApplyCharacterAppearance(src)`** → Result `{ appearance }`: sends the saved appearance to the
owner again and broadcasts it, keeping runtime clothing states such as a raised bandana. Refusals:
`INVALID_PAYLOAD`, `NO_CHARACTER`, `DATABASE_ERROR`, `CHARACTER_NOT_FOUND`. Nothing is written.

### Opening services

| Export | Result | Client event sent |
|---|---|---|
| `OpenCosmeticSurgery({ source, clinicId })` or `OpenCosmeticSurgery(src, clinicId)` | `{ locationId }` | `w_creators:client:openSurgery(clinicId)` |
| `OpenClothingStore(src, locationId)` | `{ locationId }` | `w_creators:client:openStore(locationId)` (an outfit card used at a store also sends a second argument, the card's look `{ equipped, tints }`, tried on when the store opens) |
| `OpenBarber(src, locationId)` | `{ locationId }` | `w_creators:client:openBarber(locationId)` |
| `OpenWardrobe(src, locationId?)` | `{ locationId }` (`nil` = remote) | `w_creators:client:openWardrobe(locationId)` |

`OpenCosmeticSurgery` also accepts the table keys `src` / `playerId` and `clinic` / `locationId`.

Checks, in order:

1. The service toggle is on, else the service's code (`SURGERY_DISABLED`, `STORE_DISABLED`,
   `BARBER_DISABLED`, `WARDROBE_DISABLED`).
2. The player has an active character (`NO_CHARACTER`).
3. No service session is open (`BUSY`).
4. The location:
   - It must be a string id of at most 64 characters, of the right `type` (`LOCATION_NOT_FOUND`).
   - It must be `enabled` (`LOCATION_DISABLED`) and inside its `hours` (`LOCATION_CLOSED_HOURS`).
   - The player must be within `interactionRadius + 3` m of its `coords` or `preview` (`TOO_FAR`).
   - A location with an `access` rule admits only the jobs (at their grade) or the ACE permission it
     names (`ACCESS_DENIED`; CLOTHING.md §12).
   - A remote wardrobe (`locationId = nil`) needs `Config.Wardrobe.allowRemote`, else
     `LOCATION_NOT_FOUND`.
   - Surgery also refuses a character whose sex has no allowed section (`SURGERY_DISABLED`).
5. **Surgery grant.** `OpenCosmeticSurgery` gives the player a one-use grant for that clinic
   (`WCSurgeryService.grant`, 60 s). A clinic with `prompt = false` opens only with this grant; the
   client's `surgery:open` without it is `SURGERY_NOT_ALLOWED`. The grant is used up only by an
   open that succeeds, and it is dropped on disconnect.

w_ambulancejob uses it this way: the station prompt calls its own server, and that server calls
`exports.w_creators:OpenCosmeticSurgery({ source = src, clinicId = clinicId })`.

### Spawn

- **`OpenSpawnSelector(src)`** → Result `{ points, kind = 'admin' }`. Gives a one-shot `admin`
  spawn grant and sends `w_creators:client:selectSpawn`. Refusals: `SERVICE_DISABLED` (the
  `spawnSelector` service or `Config.Spawn.selector.enabled` is off), `NO_CHARACTER`, `BUSY` (a
  session is open, a spawn grant is pending, or the routing bucket is not 0), `INTERNAL_ERROR`.
  The player may cancel this in-world selector (`Config.Spawn.selector.keys.cancel`, default
  `BACK`). The client then sends `w_creators:server:spawnCancel`, which withdraws the `admin` grant.
- **`RespawnPlayer(src, pointId?, kind?)`** → Result `{ pos, kind, point }`.
  - `pointId`: `nil` = the first enabled point, `'__last'` = the validated last location, or a
    point id of at most 64 characters (`INVALID_SPAWN` when unknown or disabled).
  - `kind`: `'death'`, or `'admin'` (the default; any other value is `'admin'`).
  - Refused (`BUSY`) while a login-kind grant is pending, because the player is in the character
    scene. A pending in-world selector grant is withdrawn.
  - Sends `w_creators:client:respawn(pos, { kind, point })`. The routing bucket is not touched.

## Client exports

| Export | Returns | Notes |
|---|---|---|
| `GetAppearance()` | v3 appearance (copy) or `nil` | the local character's saved appearance |
| `GetCurrentOutfit()` | `{ outfit, equipped, tints, states }` (copies) or `nil` | `outfit` = the saved-outfit id it was last dressed from, or `nil` |
| `GetEquippedCategory(category)` | `hash` (u32), `tint` (copy) or `nil` | clothing categories plus the body parts `heads`, `eyes`, `teeth`, `BODIES_UPPER`, `BODIES_LOWER`, `hair`, `mustache` / `beards_complete` (hash only). An item hidden by a state (hat off) is still equipped. `category` must be a string of 1..64 characters |
| `IsInCharacterScene()` | boolean | selection room, creator, or a login spawn selection (an admin selection in the world does not count) |
| `RefreshAppearance()` | boolean (started) | reloads through `w_creators:appearance:reload` (server: 1 per 10 s, `BUSY` during a session) and renders it. If refused, it renders the local copy again. `false` when no character, in the character scene, in an editor or while a render runs |
| `OpenWardrobe(locationId?)` | `true` | starts the wardrobe flow in a thread. `nil` = remote wardrobe (server: `Config.Wardrobe.allowRemote`). A refusal is shown to the player |
| `OpenCosmeticSurgery(clinicId)` | boolean | `false` for an id that is not a string of 1..64 characters. Opens only clinics with their own prompt; `prompt = false` clinics need the server export |
| `OpenClothingActions()` | Result | opens the clothing-actions panel (`ACTIONS_DISABLED`, `NO_CHARACTER`, `BUSY`, `STATE_NOT_APPLICABLE`) |
| `SetClothingState(group, value)` | Result `{ group, value, changed, states }` | `group` = a `Config.ClothingStates.groups[].id`. Yields (server round trip). On failure it goes back to the saved value |
| `GetClothingActions()` | `{ status, rows }` | The clothing actions available **right now**, flattened for a menu: one row per state group, `{ group, value, label, item, itemId, icon, control }`, in `WCClothing.available` order. `status` is `'disabled'` (the service or `Config.ClothingStates` is off) or `'no_character'` — both mean *hide the menu entirely*, not *show an empty one* — or `'ok'` / `'empty'`. Only **equipped** categories produce rows (`WCClothingStates.applicable`), so the caller does no filtering of its own. Plain data, safe across the export bridge. Pair it with `SetClothingState` to act on a row |
| `ToggleHat()`, `ToggleBandana()`, `ToggleSleeves()` | Result | next value of that group (`STATE_NOT_SUPPORTED` when none) |
| `IsBandanaUp()` | boolean | the local character's bandana is raised (applicable and `up`) |
| `RemoveClothingCategory(category)`, `RestoreClothingCategory(category)` | Result | `'off'` / `'on'` of the category's visibility group. Only when that category is the one worn (`STATE_NOT_APPLICABLE`, `data.reason = 'category'`); `STATE_NOT_SUPPORTED` without a group |
| `Resurrect(coords?, heading?, reason?)` | boolean | the only resurrect entry point, see below |

A clothing state never removes an owned or equipped item. It only hides the component or changes
how it is worn.

`Resurrect(coords, heading, reason)` (`client/respawn/respawn.lua`) yields.

- It returns `false` while another resurrect is pending or running, and for invalid coordinates.
- `reason` is free text of up to 32 characters (default `'external'`).
- On a downed player it resurrects through `WCNative.respawn.resurrect`, waits up to
  `Config.Respawn.resurrectTimeoutMs` for the new ped, then renders the saved appearance.
- On a living player it only moves him when `coords` is more than 1 m away.
- Every success fires the client event `w_creators:client:resurrected(reason)`.

w_ambulancejob calls it with `reason = 'hospital'` and falls back to the plain native when
w_creators is not started.

### Store, wardrobe and items callbacks (client → server, token-bound)

Besides `store:open` / `store:commit` / `wardrobe:*` / `outfits:*` (CLOTHING.md §7, §9):

| Callback | Arguments | Result |
|---|---|---|
| `w_creators:store:commit` | `token, opId, app, extra?` | `extra = { currency = 'cash' | 'gold', outfitName }`; `{ appearance, charged, currency, purchases, outfit? }` |
| `w_creators:store:resell` | `token, hash` | `{ refunded, currency, hash, owned }` (CLOTHING.md §14) |
| `w_creators:outfits:save` / `update` | `token, name / id, equipped, states, tints?` | the item colours of the outfit (colourways) |
| `w_creators:locations:access` | — | `{ [locationId] = boolean }` for the locations with an `access` rule |
| `w_creators:wardrobe:wrap` | `token, hash` | `{ owned }`; only with `Config.Clothing.items.enabled` (CLOTHING.md §15) |
| `w_creators:outfits:share` | `token, id` | `{}`; only with `Config.Clothing.items.enabled` |

No price, amount or currency value is ever read from these payloads: the server works every total
out itself.

## Public events

### Server-local (`AddEventHandler` on the server)

| Event | Arguments | When |
|---|---|---|
| `w_creators:server:characterCreated` | `(src)` | a new character is about to be registered in the framework (before its login). w_lib's w_core bridge listens |
| `w_creators:server:characterActivated` | `(src, charid, sex)` | a character became the player's active one: selection, creation, or adoption after a resource restart |
| `w_creators:server:characterCleared` | `(src, charid, reason)` | the active character was cleared: `reason = 'switch'` (character switch) or `'dropped'` (disconnect) |
| `w_creators:server:appearanceChanged` | `(src, charid, kind)` | after any committed appearance change. `kind` ∈ `store`, `wardrobe`, `clothingState`, `barber`, `surgery`, `api` |

Hair and beard growth does not fire `appearanceChanged`; it sends `w_creators:client:grooming` to
the owner. `charid` is the framework character id as a string.

### Client (`AddEventHandler` / `RegisterNetEvent` on the client)

| Event | Arguments | Notes |
|---|---|---|
| `w_creators:client:spawn` | `(pos { x, y, z, heading }, meta { kind = 'initial'|'login'|'switch' })` | net event from the server, the last step of every login path. **w_core** listens to it (`w_core/client/events.lua`): after the fade-in it fires `WCore:Client:OnPlayerLoaded`. w_creators' own handler performs the safe spawn |
| `w_creators:client:respawn` | `(pos, meta { kind = 'admin'|'death', point })` | a player already in the world is moved. Not a login: w_core does not treat it as `OnPlayerLoaded` |
| `w_creators:client:resurrected` | `(reason)` | local event after every successful `Resurrect`. A death system clears its own dead state for the reasons it did not start (w_ambulancejob skips `'hospital'`) |
| `W:CREATOR:FirstSpawn` | — | local event, raised for kind `'initial'` when `Config.Creator.enableCutscene` is on |
| `Config.Creator.spawnEvent` | — | when set, the server sends this client event on every login spawn (first spawn, login, switch) in place of the spawn selector and the built-in spawn. `w_creators:client:spawn` is then not sent, so w_core's `OnPlayerLoaded` hook above does not run from it |

## Integration with w_lib and w_core

w_lib's w_core bridge (`w_lib/modules/framework-bridge/cores/w_core/server.lua`) calls:

- `exports.w_creators:GetAppearance(source)`: its skin and clothes getters read `data.skin` and
  `data.clothes`.
- `exports.w_creators:SetClothes(source, clothes, overwrite)` and
  `exports.w_creators:SetSkin(source, skin, overwrite)`: these go through the full validation above
  and are refused, not repaired. A refusal leaves the saved appearance unchanged. The bridge
  ignores the Result.
- `AddEventHandler('w_creators:server:characterCreated', ...)`: it marks the next
  `WCore:Server:PlayerLoaded` as a new character.

w_core calls, when a character is deleted (by staff or from the character selection):

- **`exports.w_creators:PurgeCharacter(citizenid, ctx)`** → `true, { characters_appearence = n,
  w_creators_clothes = n, w_creators_outfits = n, memory = n? }` or `false, reason`. It is not a
  Result. It deletes the character's appearance, owned clothing and outfits in one transaction and
  forgets it in memory: the repository cache, the degraded flag, pending legacy grants, and a
  pending selection, grant, switch or cleanup that names it. After that its citizen id can be given
  to another character with nothing left over. `ctx = { by, at, tombstone }`; w_creators keeps no
  history under the id and moves no money. The purge holds the character's appearance lock and
  outfit lock while it deletes, so a write already running finishes first. A later write finds no
  row and creates nothing. Running it twice is safe: the second run counts 0 rows and succeeds.
  Only w_core may call it: any other caller gets `false, 'forbidden'`.
  It refuses before changing anything with `invalid_id`, `online` (a connected player still has
  the character in play or logged in), `busy` (a writer did not finish within
  `WCCharacters.PURGE_LOCK_WAIT_MS`, 10 s), `database_not_ready` or `database`.

## Compatibility shims (kept pre-v3 names)

| Name | Kind | v3 behaviour |
|---|---|---|
| `exports.w_creators:OpenWardrobe()` (client) | export | kept. Opens a remote wardrobe when `Config.Wardrobe.allowRemote` and the `wardrobe` service are on |
| `GetAppearance` / `SetClothes` / `SetSkin` (server) | exports | added in v3 for the w_lib bridge (they did not exist before; audit A19) |
| `PersonaCreatorHandler.applyCharacterAppearance` | server→client net event `(app)` | alias of `w_creators:client:applyAppearance` (renders the own appearance) |
| `PersonaCreatorHandler.reloadCharacterAppearance` | client→server net event | same as the `w_creators:appearance:reload` callback (rate-limited, `BUSY` during a session). On success the server answers with `w_creators:client:applyAppearance` |
| `PersonaCreatorHandler.setPlayerRoutingBucket` | client→server net event | the guarded scene isolation. Refused and logged unless a server-tracked scene or fitting session allows it. Never starts a character switch |
| `PersonaCreatorHandler.setRoutingBucket` | client→server net event `(netId)` | registers the preview ped (`scene:registerPed` checks) |
| `w_creators:server:isolate`, `w_creators:server:rejoinWorld` | client→server net events | guarded isolation and release. Release restores only a bucket w_creators itself set; rate-limited |
| `w_creators:server:requestAppearances` | client→server net event | the cached appearances of the other players (2 per 10 s) |
| `w_creators:server:creationReady` | client→server net event | same as `characters:loaded` (valid only after a successful select/create) |
| `w_creators:server:spawnAt` | client→server net event `(pointId)` | needs a pending one-shot spawn grant. An unknown id falls back to the first enabled point |
| `w_creators:client:applyRemoteAppearance`, `w_creators:client:selectSpawn`, `w_creators:client:spawn` | server→client | kept names |
| `W:CHARCREATION:starting` | client event | only a request: the server grant (`characters:beginCreate`) decides. Ignored while a character is in play (use `/characters`) |

Removed in v3: the `/starting` command, unguarded isolation, and client-sent spawn coordinates
(audit A1–A3, ARCHITECTURE.md §1).
