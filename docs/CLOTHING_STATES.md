# Clothing states

Operator reference for runtime clothing states: hat on or off, bandana up, sleeves rolled, boots under
the pants, and so on. The main files are:

- `config/clothing.lua` (`Config.ClothingStates`)
- `shared/clothing_states.lua` (`WCClothingStates`)
- `client/clothing/states.lua` (`WCClothing`, the quick-access panel and the exports)
- `server/clothing/states.lua` (`WCClothingActions`, the `w_creators:clothing:setState` callback)
- `Appearance.ApplyClothingState` in `client/appearance/pipeline.lua`

The contract is in [ARCHITECTURE.md](ARCHITECTURE.md) §5.5 and §16.5.

> **Test status.** Nothing in this file was tested on a live RedM server. The logic (applicability,
> guards, persistence, sync, settlement) is covered by the automated tests against stubs. Every
> visual result, meaning what the ped actually shows after a state change, **requires live
> verification**. §9 is the checklist to run. It has **not** been executed.

**Core rule:** a state never removes an owned or equipped item. `off` only hides the component on the
ped. `app.clothing.equipped` and the ownership rows are never touched.

---

## 1. Enabling

Both switches must be on:

- `Config.Services.clothingActions` (the service)
- `Config.ClothingStates.enabled`, which defaults to the same value (`WCClothingStates.enabled()`)

When they are off:

- The panel, command, keybind and exports answer `ACTIONS_DISABLED`.
- The server callback refuses with `ACTIONS_DISABLED`.
- No submitted state is persisted anywhere (wardrobe, outfits, creation). Writers keep the saved states
  that still apply.

The `/clothing` command and the keybind are registered only when the service is on at resource start.

---

## 2. State groups

`Config.ClothingStates.groups`, in panel order. Every group is configured `verified = 'likely'`.
`verified` is informational: no code reads it. Its values are `'likely'` (documented and used by w_lib)
and `'experimental'` (research only).

| Group | Parent (panel: group › item) | Categories | Values (default first) | Mechanism | Persist | Animation clip (experimental) |
|---|---|---|---|---|---|---|
| `hat` | head › hats | `hats` | `on` / `off` | visibility | yes | `mech_inventory@clothing@hat` `hat_on` / `hat_off` |
| `eyewear` | head › eyewear | `eyewear` | `on` / `off` | visibility | yes | — |
| `mask` | head › masks | `masks` | `on` / `off` | visibility | yes | `…@bandana` `neck_2_face` / `face_2_neck` |
| `bandana` | neck › neckwear | `neckwear` | `down` / `up` | wearable `base` / `mask_up` | **no** | `…@bandana` `face_2_neck` / `neck_2_face` |
| `sleeves` | upper › shirts_full | `shirts_full` | `down` / `rolled` | w_lib `sleeveUnroll` / `sleeveRoll` | yes | `…@sleeves` `roll_down` / `roll_up` |
| `collar` | upper › shirts_full | `shirts_full` | `closed` / `open` | w_lib `collarClose` / `collarOpen` | yes | — |
| `coat` | upper › coats | `coats`, `coats_closed` | `on` / `off` | visibility | yes | — |
| `vest` | upper › vests | `vests` | `on` / `off` | visibility | yes | — |
| `poncho` | upper › ponchos | `ponchos`, `cloaks` | `on` / `off` | visibility | yes | — |
| `gloves` | arms › gloves | `gloves` | `on` / `off` | visibility | yes | `…@gloves` `gloves_on` / `gloves_off` |
| `boots` | feet › boots | `boots` | `over` / `under` | wearable `base` / `under_pants`, **requires `pants`** | yes | — |

### 2.1 Mechanisms

All of these go through `Appearance.ApplyClothingState(ped, app, groupId, value)`, followed by one
refresh.

- **visibility**
  - `off` removes every equipped category of the group from the ped (`w.component.remove`).
  - `on` re-applies the equipped hash with its tint. The tint is drawn only if the live tint config
    allows it.
  - During a full render, an item in state `off` is never put on at all.
- **wearable** (`wearable`)
  - `w.component.setWearableState(ped, category, hash, <state>)`.
- **wearable** (`lib`, the shirt)
  - The w_lib helpers `sleeveRoll`, `sleeveUnroll`, `collarOpen` and `collarClose`. They read the
    shirt's other half from the ped, so the combined state is one of `base`,
    `closed_collar_rolled_sleeve`, `open_collar_full_sleeve` or `open_collar_rolled_sleeve`.
- **Ordering.** Wearable states are applied only after the item they act on has been committed. The
  w_lib helpers read the ped's current component and tints back.
- **Resets.** An equipped wearable item whose group cannot act (boots with a skirt or a dress, no
  pants) is reset to `base`, because w_lib re-applies a remembered non-base state whenever the
  component goes back on.

Error codes from the pipeline: `STATE_NOT_SUPPORTED`, `INVALID_PAYLOAD`, `STATE_NOT_APPLICABLE` and
`INVALID_PED`.

---

## 3. Applicability

A group is **applicable** (`WCClothingStates.applicable(app, groupId)`) when:

- one of its categories is equipped (the first one equipped is the one it acts on), **and**
- if it has `requires`, one of those categories is equipped too.

Currently only `boots` has a requirement: `pants`.

An **action** is offered (`WCClothingStates.actions(app)`) when the feature is enabled, the group is
applicable, and the target value differs from the current one. The current value is the stored state,
or the group default.

The coat group covers `coats` and `coats_closed`, and the poncho group covers `ponchos` and `cloaks`.
These pairs conflict (see [CLOTHING.md](CLOTHING.md) §6), so only one of each pair is ever worn. The
panel item is named after the piece actually worn (a cloak, a closed coat).

### 3.1 Settlement when the equipped items change

| Writer | Rule |
|---|---|
| store commit, `SetClothes`, surgery clothing | a swapped or removed item loses its state (a new hat is worn visibly). States whose item is gone are dropped (`WCOwnership.settleStates`). The store editor previews the same (`WCEditorTree.storeStates`) |
| wardrobe commit | the wardrobe edits states itself. A submitted state is kept when it persists, is valid and applies to the result. With clothing actions off, the saved states that still apply are kept |
| saved outfit | only the persisting states that apply to the outfit's own items are stored |
| creation | states that do not apply are dropped. All states are dropped when clothing actions are off |
| legacy reconcile (`WCAppearanceRepo`) | states of unchanged items are kept |

---

## 4. Quick-access panel and access points

Controller: `WCClothing` (`client/clothing/states.lua`). The panel is a `WCPanel` tree of taxonomy group
› item › action. Control ids are `state.<groupId>.<value>`. Action labels are dictionary keys, for
example "Roll up sleeves" or "Take off cloak".

| Access | Name |
|---|---|
| Command | `/clothing` |
| Keybind | `wc_clothing_actions`. The default key is `Config.Keys.clothingActions` (`nil` = unbound, players can bind it in the game settings) |
| Client export | `OpenClothingActions()` → Result |
| Client export | `SetClothingState(groupId, value)` → Result `{ group, value, changed, states }` |
| Client export | `ToggleHat()`, `ToggleBandana()`, `ToggleSleeves()` → Result (next value of the group) |
| Client export | `RemoveClothingCategory(category)` / `RestoreClothingCategory(category)` → Result. Visibility groups only, and only when that category is the piece worn (`RemoveClothingCategory('cloaks')` never hides a poncho) |
| Client export (read) | `GetCurrentOutfit()` → `{ outfit, equipped, tints, states }` |
| Server callback | `w_creators:clothing:setState(group, value)` → `{ states }` |

- With no action available, the panel shows a notice and returns `STATE_NOT_APPLICABLE`
  (`data.reason = 'none'`).
- An open panel closes itself when the character is cleared, the feature is disabled, the ped dies, or
  a flow of this resource starts. It rebuilds when the equipped items or states change.
- The wardrobe editor shows the same actions in its own tree and saves them with the wardrobe commit.

### 4.1 Refusals (client guards, `WCClothing.perform`)

| Condition | Code |
|---|---|
| unknown group or value | `STATE_NOT_SUPPORTED` |
| feature off | `ACTIONS_DISABLED` |
| no character | `NO_CHARACTER` |
| group not applicable | `STATE_NOT_APPLICABLE` |
| an editor, selection, creator, spawn, respawn, service visit, character scene, seat or cutscene is active; the player's appearance is being rendered; another action runs (lock `clothingAction`) | `BUSY` (`data.reason`) |
| ped missing, dead or dying, ragdoll, in combat; mounted or in a vehicle **when an animation would play** | `STATE_NOT_APPLICABLE` (`data.reason`) |

Server refusals: `RATE_LIMITED` (12 per 10 s), `ACTIONS_DISABLED`, `STATE_NOT_SUPPORTED`,
`NO_CHARACTER`, `BUSY` (a live service session or a commit in flight), `STATE_NOT_APPLICABLE` (checked
against the **saved** appearance), and `CHARACTER_NOT_FOUND` / `DATABASE_ERROR`.

The ped-condition natives are looked up by name. If one is missing on a game build, its check is
skipped. **Requires live verification.**

---

## 5. Sequence and animations

1. Run the guards (§4.1).
2. If animations are on, play the animation up to its midpoint.
3. Re-check: no flow started, and the saved appearance was not replaced with a different value.
4. **Apply locally** (`ApplyClothingState` + refresh), so the change is visible at once.
5. Call `w_creators:clothing:setState`.
6. **If the server refuses,** the saved value is drawn back on the current ped.
7. **If it succeeds,** `WCState.appearance.clothing.states[group]` is updated. If the player's look was
   re-rendered during the round trip, the new value is drawn again.

**Animations** are **experimental** and off by default: `Config.Experimental.clothingAnimations = false`.

- **Clips.** `Config.ClothingStates.animations[group] = { dict, duration, midpoint, clips = { [value] =
  clip } }`. Configured for `hat`, `mask`, `bandana`, `sleeves` and `gloves`. The other groups change
  without an animation. The dictionary and clip names come from community research and are **not
  verified** on any game build.
- **Timing.** `duration` is clamped to 100–10000 ms (default 1000). `midpoint` is clamped to
  0–`duration` (default `duration / 2`). The state changes at the midpoint.
- **Loading and playback.** The dictionary must load within 2000 ms, or the change goes ahead without
  an animation. Playback is upper body plus secondary (flags `16 | 32`), so the player keeps walking.
- **Interruption before the midpoint.** Checked every 100 ms: death, ragdoll, combat, getting on a
  mount or into a vehicle, a new ped, a flow or render starting, or the resource stopping. **Nothing
  changes.** The clip is stopped and the result is a refusal with `data.interrupted`.
- **After the midpoint.** The change is committed. The clip is not stopped; it plays out its
  `duration`.
- Whether a clip actually exists, and how it looks, **requires live verification**. A missing
  dictionary or a failed play is logged and skipped.

---

## 6. Persistence and remote sync

| | Persisting group (`persist = true`) | Non-persisting (`bandana`) |
|---|---|---|
| Stored in | `app.clothing.states` in `characters_appearence.appearance` (one save, under the character lock). Not in the legacy projection | server memory only (`WCClothingActions`, per player and character) |
| Saved outfit | yes (when it applies) | never |
| Server event | `w_creators:server:appearanceChanged(src, charid, 'clothingState')` when a save happened | none |
| Broadcast | `w_creators:client:remoteClothingState(serverId, group, value)` to every client, and the server cache (`WCSync.broadcastState`) | same |

**Remote clients** (`Appearance.Sync.state`):

- The cached look is updated. If the remote ped already shows that look, the state is applied to it
  directly and refreshed.
- Otherwise the scope watcher re-renders the ped with the new state.
- A late joiner receives the server's cached look, which includes the current states.
- A re-send of the saved look (reload, grooming stage, the `ApplyCharacterAppearance` export) adds the
  runtime states back (`WCSync.withRuntimeStates`).

---

## 7. Respawn, reconnect and other resets

| Event | Persisting states | Bandana (runtime) |
|---|---|---|
| Resurrect or respawn (`WCRespawn`, `Config.Respawn.restoreAppearance`) | re-drawn: `Appearance.RestorePlayer()` renders `WCState.appearance` | kept on the owner (it is in `WCState.appearance`). Remote clients re-render the new ped from their cache, which includes it |
| Hair or beard growth stage | kept | kept (the client carries runtime states over, the server re-sends them) |
| `RefreshAppearance` / `/reloadappearance` | re-read from the database | kept |
| Store, wardrobe, barber, surgery or API commit | settled (§3.1) | **dropped**. The server forgets runtime states on any appearance change other than `clothingState`, and the new look has none |
| Character switch (`w_creators:server:characterCleared`) | loaded with the character | dropped |
| Disconnect and reconnect | loaded with the character | dropped (reset to `down`) |

---

## 8. Not supported, and why

- **Hiding a hat with the game's own hat access.** `_SET_PLAYER_HAT_ACCESS`
  (`WCNative.clothing.setHatAccess`) is per player, its interaction with script-applied metaped hats is
  undocumented, and it does not change `app.clothing.equipped`. It stays behind
  `Config.Experimental.hatAccess` (off) and no production path calls it. The `hat` state removes and
  re-applies the hat hash instead. See [NATIVES.md](NATIVES.md).
- **Other w_lib wearable states** (`w.component.data.wearableStates`) are **not configured**:
  - vest tucked under the pants (`vests` `under_pants`)
  - loadout side (`loadouts` `base_right`)
  - hair pomade (`hair` `pomade`: a hair look, not clothing)

  They could be added as `wearable` groups, but each needs live verification per item. The composite
  names in w_lib's `others` list are also not configured: open coat (`base_coat_open…`), tucked shirt
  (`base_tucked`, `tuck`), pants inside the boots (`under_boots`, `under_spats`, `under_chaps`) and
  glove variants. They depend on the combination of worn items, and no validated mapping exists.
- **Removing or unequipping through a state.** By design, a state never changes ownership or the
  equipped set. Use the wardrobe or the store to change the equipped set.
- **Persisting the bandana.** `persist = false` is deliberate. A raised bandana is a moment-to-moment
  state, never saved or put into an outfit.
- **Changing states while dead, ragdolled, in combat, inside this resource's flows, or with an
  animation while riding.** The guards in §4.1 refuse these.
- **Animations in production.** The clip names are unverified (§5).

---

## 9. Live verification checklist (not executed)

**Setup:** two clients on a OneSync server. Client A performs the actions and client B observes. Set
`Config.Debug.enabled = true` with domain `clothing`. Run each item with animations off, then again
with `Config.Experimental.clothingAnimations = true` where a clip is configured. For every state, check
all of the following:

- (a) A's ped shows the change.
- (b) B sees the same change within about 1 s.
- (c) Relog A: persisting states return, the bandana is `down`.
- (d) Resurrect A (`exports.w_creators:Resurrect`): the state is still drawn on A and seen by B.
- (e) B leaves scope and comes back: the state is still drawn.
- (f) `/clothing` offers only the reverse action.

| # | State | Steps and expected result |
|---|---|---|
| 1 | `hat` off/on | Wear a dyed hat. `off`: hat gone, hair intact. `on`: the same hat with **the same dye**. Buy a different hat while `off`: the new hat is visible |
| 2 | `eyewear` off/on | Glasses disappear and reappear, with no effect on other face items |
| 3 | `mask` off/on | Mask removed and restored. With a bandana also worn, both behave independently |
| 4 | `bandana` up/down | `mask_up` covers the face. `down` restores it. After a store purchase the bandana is `down` again. Relog → `down` |
| 5 | `sleeves` rolled/down | Sleeves roll. The shirt dye is unchanged. Combined with `collar` open, all four combinations render |
| 6 | `collar` open/closed | Collar opens. The sleeve state is kept. Buy a different shirt in the store: the new shirt starts `closed` and `down` |
| 7 | `coat` off/on | Test with `coats` and with `coats_closed`. `off` hides the worn one. `RemoveClothingCategory('coats_closed')` while wearing `coats` → `STATE_NOT_APPLICABLE` |
| 8 | `vest` off/on | The vest hides and returns. The shirt is unaffected |
| 9 | `poncho` off/on | Test with `ponchos` and with `cloaks`. The panel label names the worn piece |
| 10 | `gloves` off/on | Gloves hide and return. Shirt sleeves and hands render correctly |
| 11 | `boots` under/over | With pants: the boots go under the pants and back. Switch to a skirt: the action disappears and the boots render in `base` |
| 12 | Guards | While mounted: works without an animation, refused with one. Dead or ragdolled: refused. With a store open: `BUSY` |
| 13 | Animation interruption | Start `hat` off and get knocked down before the midpoint: the hat stays on |
| 14 | Late joiner | A sets hat `off` and bandana `up`. B joins afterwards and sees both |
