# w_creators — Spawn and respawn

Operator guide for how a character enters the world, how a player already in the world is moved,
and how death respawn works with w_ambulancejob. Source of truth: `config/spawn.lua`,
`server/spawn/spawn.lua`, `server/respawn/respawn.lua`, `server/api.lua`, `client/spawn/selector.lua`,
`client/spawn/spawn.lua`, `client/respawn/respawn.lua`, `server/characters/characters.lua`,
`client/characters/selector.lua`, and in w_ambulancejob `client/main.lua`. Contract:
`docs/ARCHITECTURE.md` §11, §12, §16.3.

Nothing in this document was run on a live RedM server. Ground placement, streaming, fades, the
aerial camera, the resurrect native and the ped-handle behaviour **require live verification**; the
matching live checks are `docs/TESTING.md` L1.3–L1.5, L7.1–L7.7, L8.1–L8.2 and L9.3.

## 1. Spawn kinds

| Kind | When | Server → client event | Routing bucket | w_core `OnPlayerLoaded` |
|---|---|---|---|---|
| `initial` | a character was just created | `w_creators:client:spawn` | w_creators' scene bucket → 0 | fires |
| `login` | an existing character was selected | `w_creators:client:spawn` | w_creators' scene bucket → 0 | fires |
| `switch` | a character selected after `/characters` | `w_creators:client:spawn` | w_creators' scene bucket → 0 | fires |
| `admin` | `wc_respawn`, `exports.w_creators:RespawnPlayer` (default kind), `exports.w_creators:OpenSpawnSelector` | `w_creators:client:respawn` | never touched | does not fire |
| `death` | `exports.w_creators:RespawnPlayer(src, pointId, 'death')` | `w_creators:client:respawn` | never touched | does not fire |

After a character is loaded the server calls `WCSpawnServer.finish(src, kind, isNew)`:

1. A new character gets its survival metadata (`Config.Characters.setSurvivalMetadata`; not on VORP).
2. `Config.Creator.spawnEvent` set → the grant is withdrawn, the player is moved to bucket 0 and that
   framework event is fired on the client (**every** login, switch and first spawn). Never set it to
   `'W:CREATOR:FirstSpawn'`.
3. Else, selector on → one-shot grant + `w_creators:client:selectSpawn { last, points, kind }`.
4. Else, direct: a new character at `Config.Spawn.firstSpawn`; an existing one at its validated last
   location, or the first enabled point.

Login kinds move the player from the private bucket w_creators set to bucket 0; a bucket another
resource set since (jail, instance) is kept. A kind-`initial` spawn starts the first-spawn wagon ride
when `Config.Creator.enableCutscene = true`.

## 2. Selector and spawn point configuration (`Config.Spawn`)

| Key | Default | Meaning |
|---|---|---|
| `firstSpawn.coords`, `.heading` | Valentine `-274.09, 785.36, 119.29`, `90.0` | A new character's spawn when the selector is off; the fallback when no point is enabled and when a placement fails. |
| `selector.enabled` | `Config.Services.spawnSelector` | Both must be on. |
| `selector.transition` | `350` | Fade between two locations (ms, 0–5000). |
| `selector.sceneTimeout` | `8000` | Wait for the area to stream before showing it (ms, 0–60000). |
| `selector.keys.select` / `.prev` / `.next` | `RETURN` / `LEFT` / `RIGHT` | Keyboard key names. An optional `keys.cancel` (default `BACK`) cancels an `admin` selector. |
| `selector.promptPosition` | `'bottom-right'` | Prompt group position. |
| `selector.labels` | Arabic dictionary keys | `title`, `select`, `prev`, `next`, `lastPosition`, `lastRegion` (an optional `cancel` labels the `admin` cancel prompt, default `إلغاء` "Cancel"). |
| `camera` | `dist 110, height 55, angle 135, fov 50, orbit 1.5` | The aerial orbit; `orbit = 0` stops the rotation. Per point `cam = {...}` overrides any value. |
| `lastLocation.enabled` | `Config.Services.lastLocation` | Both must be on for `'__last'`. |
| `lastLocation.preselect` | `true` | Last location listed first and preselected; `false` lists it last. |
| `snapToGround` | `true` | Probe the ground after the move. |
| `bounds` | `x -8000..5000, y -6000..3000, z -150..1500` | A last location outside is rejected. |
| `sceneExclusionRadius` | `150.0` | A last location this close to the creator room anchor (`Config.Scene.anchor`) is rejected. |
| `points[]` | 9 towns | `id`, `label`, `region`, `coords`, `heading`, `enabled`, `order`, optional `cam`. |

Shipped point ids, in `order`: `valentine`, `saintdenis`, `rhodes`, `blackwater`, `strawberry`,
`armadillo`, `tumbleweed`, `vanhorn`, `annesburg`. A point with `enabled = false` or invalid
coordinates is not listed and the server refuses it (`INVALID_SPAWN`). The Z values are approximate;
the ground probe corrects them.

The client only ever sends a point **id** (`'__last'` or a `points[].id`); the server resolves every
coordinate. The selector resolves ids against `Config.Spawn.points` only for the camera and the labels.

## 3. Last-location validation

The last position is read from the framework (`Bridge.GetLastPosition`: VORP `characters.coords`,
otherwise the framework player's `PlayerData.position`) and never written by w_creators; saving it
stays the core's job. It is rejected when:

- any coordinate is not a finite number,
- it is exactly `0, 0, 0` (a row that never saved a position),
- it lies outside `Config.Spawn.bounds` (x, y or z),
- it lies within `sceneExclusionRadius` of the creator room anchor.

A rejected or missing last location falls back to the first enabled point (lowest `order`, then
config order), or to `firstSpawn` when no point is enabled. A new character is never offered
`'__last'`. The selector labels the last location with the nearest enabled point's `label`.

## 4. One-shot spawn grant

`SpawnPending[src]` is the permission to spawn; its kind is kept alongside.

- Given by `finish()` (login kinds) and by `OpenSpawnSelector` (kind `admin`).
- Consumed by the choice: callback `w_creators:spawn:choose(pointId)` → `{ pos, kind }`, or the legacy
  net event `w_creators:server:spawnAt(pointId)` (never refuses a granted player: an unknown id falls
  back to the first enabled point).
- A refused choice (`INVALID_SPAWN`, `INVALID_PAYLOAD`) keeps the grant. Rate limit: 5 per 5 s.
- Without a grant: `SPAWN_NOT_PENDING` and a `character_access_denied` log entry.
- Withdrawn when the player leaves the character scene without spawning (login kinds), when an
  `admin` selector is cancelled (`w_creators:server:spawnCancel`), on a world respawn, and on
  `playerDropped`.
- `OpenSpawnSelector` answers `BUSY` while any grant is pending, while a service session is open,
  outside routing bucket 0, and while w_ambulancejob (started) holds the player: its server exports
  `IsDead` / `InHospitalBed` (dead, last stand, hospital bed; `WCSpawnServer.heldByDeathOwner`). An
  admin respawn (`wc_respawn`, `RespawnPlayer` kind `admin`) is refused the same way. The client also
  refuses an `admin` selector (grant handed back) meanwhile.

## 5. Safe spawn (client)

`w_creators:client:spawn(pos, { kind })` (login kinds):

```
fade out ─► close the selector ─► wait for an appearance render in flight (20 s)
─► move + request collision (10 s) ─► ground probe from 2 m, then 20 m above the target
   (GetGroundZAndNormalFor_3dCoord; a ground more than 20 m from the target is rejected)
─► no collision / no ground: Config.Spawn.firstSpawn (placed as configured if that fails too)
─► place + heading ─► unfreeze, visible, vulnerable ─► leave the private bucket and the creator room
─► world UI and radar back ─► loading screen dismissed ─► fade in
```

Spawns are serialised (a second one waits up to 30 s). A resource stop mid-placement unfreezes the
player, restores the UI and lifts the fade.

## 6. w_core coupling

- w_core's client listens to `w_creators:client:spawn`: once the screen is no longer faded out (up to
  15 s, then 500 ms) it fires `WCore:Client:OnPlayerLoaded`, which sets `isLoggedIn`. That is why
  only login kinds use `client:spawn`; `admin` and `death` use `w_creators:client:respawn` so
  `OnPlayerLoaded` does not fire a second time.
- w_core's `playerSpawned` handler does not open a character selection; w_creators opens it itself.
- The framework bridge runs as `rsg` when `exports.w_lib:CompatStatus().inboundAliases` is set
  (w_core provides the RSG / QBR / VORP names); the last position is then read from the framework
  player.
- w_creators fires `w_creators:server:characterCreated(src)` before registering a new character (w_lib's
  w_core bridge listens for it).

## 7. Respawn state machine (client)

```
ALIVE ─► DYING ─► DEAD ─► RESPAWN_PENDING ─► RESPAWNING ─► ALIVE
```

Polled every `Config.Respawn.pollMs` (250 ms, clamped 50–5000), not every frame.

| State | Meaning |
|---|---|
| `ALIVE` | the ped is alive |
| `DYING` | death observed (`IsEntityDead` or `IsPedDeadOrDying(ped, true)`); open editors and panels are cancelled through their own cancel path (snapshot restored, session closed) |
| `DEAD` | waiting for a resurrect (hospital, admin, another resource) |
| `RESPAWN_PENDING` | `Resurrect` accepted; waiting up to 15 s for an appearance render in flight |
| `RESPAWNING` | the native ran; waiting `Config.Respawn.resurrectTimeoutMs` (10000) for the alive ped |

Transitions are ignored while the player is in the character scene (selection room, creator, a login
spawn selector) or while a w_creators spawn is placing the ped.

## 8. `Resurrect` export and w_ambulancejob

`exports.w_creators:Resurrect(coords, heading, reason)` (client) is the single resurrect entry. It
returns `true` on success and fires the local event `w_creators:client:resurrected(reason)`.

- Refused (`false`) while another resurrect is pending or running.
- A living player: no native is called; a move of more than 1 m is honoured; the event still fires.
- `coords = nil` resurrects where the ped stands; `reason` is free text (32 characters) for the log.
- The native is `NetworkResurrectLocalPlayer` (wrapper `WCNative.respawn.resurrect`). The ped handle
  may change: w_creators re-reads `PlayerPedId()` afterwards (**requires live verification**).

w_ambulancejob (`client/main.lua`, local `resurrect(pos, heading)`):

| Situation | What w_ambulancejob does |
|---|---|
| w_creators started | calls `exports.w_creators:Resurrect(pos, heading, 'hospital')` in its own thread and waits up to 45 s |
| Export missing or threw before resurrecting | falls back to `NetworkResurrectLocalPlayer(x, y, z, heading, true, false)` |
| w_creators stopped mid-call, or no answer in 45 s | falls back to the native only if the player is still down |
| Export answered `false` | no native (another resurrect in flight, or it already failed inside w_creators) |
| w_creators not started | the native directly |

w_ambulancejob listens to `w_creators:client:resurrected`: for any reason other than `'hospital'` (an
admin respawn, another death system) it clears its own dead / last-stand state without resurrecting
again.

## 9. Appearance restore after a resurrect

After every resurrect through the export, and once after an **external** resurrect (another resource
resurrected the player: the ped handle changed, or dead → alive), the saved appearance is rendered
with `Appearance.RestorePlayer` (the MP model is set when needed, then the full render). It runs only
when:

- `Config.Respawn.restoreAppearance ~= false`,
- the `deathRespawn` service is on (`Config.Services.deathRespawn`; the resurrect itself still works
  when it is off),
- a saved appearance is loaded, no editor is open, and the player is not in the character scene.

An external resurrect onto a non-MP model is left alone. The restore never touches weapons or
inventory.

## 10. Admin respawn

Command `wc_respawn <playerId> [pointId]` (server): console, or a player holding the ACE
`Config.Admin.ace` (`w_creators.admin`). `pointId` is a point id, `'__last'` (the target's validated
last location) or omitted (the first enabled point).

- Rate limit 5 per 10 s per caller; a caller without the ACE is refused silently and logged as
  `security_violation` (`admin_respawn`).
- The target must be online with an active character (`NO_CHARACTER`); refused (`BUSY`) while the
  target holds a login-kind grant (he is in the character scene); an `admin` / `death` grant is
  withdrawn.
- Sends `w_creators:client:respawn(pos, { kind = 'admin', point })`; logs `character_spawned` with
  `adminSource`.

Exports (server): `RespawnPlayer(src, pointId?, kind?)` → `Result { pos, kind, point }` (kind
`'admin'` default or `'death'`); `OpenSpawnSelector(src)` → `Result { points, kind }`.

On the client a world respawn (`admin` / `death`):

1. is ignored in the character scene;
2. cancels an open editor, panel or service visit and waits up to 15 s for it to end, otherwise gives
   up without moving the player;
3. stops the first-spawn wagon ride and closes the selector;
4. ends a w_ambulancejob hospital bed stay (`InHospitalBed` / `EndBedStay` exports);
5. revives a downed player (or any player on kind `death`) through w_ambulancejob's
   `hospital:client:Revive` when it runs (3 s to start, 30 s to finish), else `WCRespawn.resurrect`;
6. runs the safe placement and fades in. The routing bucket is not changed.

## 11. Character switch rules

`/characters` exists only when `Config.Characters.allowSwitch = true`. It is refused (client) while:

- the player is dead, a resurrect is running, or w_ambulancejob reports him dead / in last stand,
- an editor, clothing panel, clothing action, store / wardrobe / barber / surgery visit is running,
- the selection, creator, first-spawn ride, spawn selector or a spawn placement is running.

The server re-checks (`SERVICE_DISABLED` / `BUSY`): `allowSwitch`, dead (health ≤ 0 or
w_ambulancejob's server `IsDead` export), an open session, an appearance write in progress. After a
resource restart the adopted character may re-enter the selection for 2 minutes even with
`allowSwitch = false`. A switch that lapses outside the character scene is ended by the server (a
character selected but never loaded is finished, an open creation is cancelled and the character
switched away from comes back), logged as `security_violation`, and no new switch starts for 5 minutes.

Leaving the character writes its pending growth (`characterCleared`); the new character spawns with
kind `switch` (§1). A world respawn is refused while that login grant is pending.
