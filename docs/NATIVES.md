# w_creators — Native wrappers

`client/natives/*.lua` is the only place in the resource that calls `Citizen.InvokeNative` / `N_0x…`
(ARCHITECTURE.md §0.4, §10). Everything else uses these wrappers, the w_lib wrappers
(`w.component.*`, `w.pedTexture.*`, `w.entity.*`) or plain named natives (`SetEntityCoords`, …).

Every wrapper:

- carries the §10 doc block (hash, name, confidence, params, returns, limitations, tested models,
  MP safe, OneSync tested here),
- validates its entity (`DoesEntityExist`, `IsEntityAPed`) and its arguments (hashes normalised with
  `WCUtil.u32`, floats coerced with `+ 0.0`, NaN/inf rejected),
- never throws: the native runs inside `pcall`; an invalid entity or a failing native returns
  `false`/`nil` and is reported through `WCDebug.log('natives', …)` (silent unless `Config.Debug`).

`tests/test_natives.py` checks the validation, the batching order, the experimental gating and the
request lifecycle; `tests/test_syntax.py` checks that no file outside `client/natives/` invokes a raw
native and that every `H.invoke(0x…)` has a documented hash.

## Confidence levels

| Level | Meaning |
|---|---|
| **Verified** | Used by the pre-v3 working resource, by w_lib, or by another production resource on this server (w_ambulancejob). |
| **Likely** | Documented and widely used by the RedM community; not exercised by this resource before v3. |
| **Experimental** | Research only. Behind a `Config.Experimental.*` flag (default off) and not on any production path. Names may be unconfirmed. |
| **Deprecated / Avoid** | Known to be unreliable; kept documented so nobody reintroduces it. |

## Inventory

| Hash | Name | Wrapper | Confidence | Used by | Notes |
|---|---|---|---|---|---|
| `0xA0BC8FAED8CFEB3C` | `_IS_PED_READY_TO_RENDER` | `WCNative.metaped.isReadyToRender(ped)` | Verified | appearance pipeline, preview scene | Returns `true` or `1`; can be true while the skeleton is collapsed, so callers also check a bone height. |
| `0x77FF8D35EEC6BBC4` | `_EQUIP_META_PED_OUTFIT_PRESET` | `WCNative.metaped.equipOutfitPreset(ped, preset, p2)` | Verified | appearance pipeline (preset step) | Must run before the saved face/body; preset 3 is the MP base outfit. |
| `0xFFA1594703ED27CA` | `_SET_PED_VARIATION_PRESET` (unconfirmed) | `WCNative.metaped.setVariationPreset(ped, preset, p2)` | Experimental | nothing | `Config.Experimental.variationPreset`. |
| `0xF97C34C33487D569` | `_REQUEST_META_PED_ASSET` (unconfirmed) | internal to `WCNative.metaped.requestPed` | Experimental | nothing | Request lifecycle, see below. |
| `0x43E4DA469541A9C9` | `_HAS_META_PED_ASSET_LOADED` (unconfirmed) | `WCNative.metaped.isRequestLoaded(handle)` | Experimental | nothing | Tracked handles only. |
| `0xC0940AC858C1E126` | `_IS_META_PED_ASSET_REQUEST_VALID` (unconfirmed) | `WCNative.metaped.isRequestValid(handle)` | Experimental | nothing | Tracked handles only. |
| `0x0BCD4091C8EABA42` | `_CREATE_PED_FROM_META_PED_ASSET` (unconfirmed) | `WCNative.metaped.createPed(handle, coords, heading, networked)` | Experimental | nothing | The caller still owns the handle. |
| `0x3972F78A78B5D9DF` | `_RELEASE_META_PED_ASSET_REQUEST` (unconfirmed) | `WCNative.metaped.release(handle)` | Experimental | nothing | Idempotent; all outstanding handles are released on resource stop. |
| `0xCCB97B51893C662F` | `_GET_NUM_META_PED_COMPONENT_CATEGORIES` (unconfirmed) | `WCNative.metaped.numCategories(ped)` | Experimental | dev tools only | Category discovery. `Config.Admin.devTools` (default off); returns `nil` when off. |
| `0xA622E66EEE92A08D` | `_GET_META_PED_COMPONENT_CATEGORY_AT_INDEX` (unconfirmed) | `WCNative.metaped.categoryAt(ped, index)` | Experimental | dev tools only | Returns a u32 category hash. `Config.Admin.devTools` (default off); returns `nil` when off. |
| `0x5653AB26C82938CF` | `_SET_CHAR_EXPRESSION` | `WCNative.ped.setExpression(ped, id, value)` | Verified | appearance pipeline (morph) | Value must be a float (clamped −1..1); no refresh — batch with `refresh`. |
| `0x704C908E9C405136` | pre-refresh | `WCNative.ped.preRefresh(ped)` | Verified | `refresh` | w_lib uses the same pair. |
| `0xCC8CA3E88256E58F` | `_UPDATE_PED_VARIATION` | `WCNative.ped.updateVariation(ped)` | Verified | `refresh`, tailor NPCs | Params `(ped, false, true, true, true, false)`. |
| — | batch refresh | `WCNative.ped.refresh(ped)` | Verified | appearance pipeline | `0x704C908E9C405136` then `0xCC8CA3E88256E58F`, once per apply (fixes A11). |
| by name | `SET_PED_SCALE` | `WCNative.ped.setScale(ped, scale)` | Verified | appearance pipeline (height) | Float coercion: an integer scale collapses the skeleton. |
| `0x9587913B9E772D29` | `_PLACE_ENTITY_ON_GROUND_PROPERLY` | `WCNative.ped.placeOnGround(entity)` | Verified | preview scene, spawn | Accepts peds (the OBJECT variant does not). |
| `0x971D38760FBC02EF` | `SET_PED_KEEP_TASK` | `WCNative.ped.setKeepTask(ped, toggle)` | Verified | first-spawn cutscene | Wagon driver. |
| `0x5E3BDDBCB83F3D84` | `_GIVE_WEAPON_TO_PED_2` | `WCNative.ped.giveWeapon(ped, weapon, ammo, inHand, inHolster)` | Verified | preview scene | Holstered revolver on preview peds only; never the player ped. |
| `0xD3A7B003ED343FD9` | `_APPLY_SHOP_ITEM_TO_PED` | `WCNative.clothing.applyShopItem(ped, hash, immediately, isMp, p4)` | Verified | raw fallback of `w.component.apply` | Refresh afterwards. |
| `0xD710A5007C2AC539` | `_REMOVE_TAG_FROM_META_PED` | `WCNative.clothing.removeTag(ped, category, p2)` | Likely | raw fallback of `w.component.remove` | Category name or hash; refresh afterwards. |
| `0xA0C683284DF027C7` | `_SET_PLAYER_HAT_ACCESS` | `WCNative.clothing.setHatAccess(player, access, p2)` | Experimental | nothing | `Config.Experimental.hatAccess`; see below. |
| `0x69D65E89FFD72313` | `_REQUEST_LETTER_BOX_NOW` | `WCNative.camera.letterbox(enable, p1)` | Verified | first-spawn cutscene | Re-request every frame while active. |
| by name | `NETWORK_RESURRECT_LOCAL_PLAYER` | `WCNative.respawn.resurrect(coords, heading)` | Verified | respawn service (`exports.w_creators:Resurrect`) | The ped handle changes; the caller waits for it and restores the appearance. |
| `0x513F8AA5BF2F17CF` | `_NEW_LOAD_SCENE_START_SPHERE` | `WCNative.scene.loadSphere(x, y, z, radius, p4)` | Verified | creator/selection scene | Asynchronous; wait on collision/IPL state with a timeout. |
| `0x524B54361229154F` | `TASK_START_SCENARIO_IN_PLACE_HASH` | `WCNative.scene.startScenario(ped, scenario, duration, heading)` | Verified | preview peds | Heading defaults to the ped's. |
| `0xFA925AC00EB830B9` | `_CREATE_VAR_STRING` | `WCNative.ui.varString(text)` | Verified | creator exit | `LITERAL_STRING`. |
| `0xFA233F8FE190514C` | `_UILOG_SET_CACHED_OBJECTIVE` | `WCNative.ui.setObjective(str)` | Verified | creator | `0` clears. |
| `0xE9990552DEC71600` | `_UILOG_PRINT_CACHED_OBJECTIVE` | `WCNative.ui.printObjective()` | Verified | creator | — |
| — | clear / blank objective | `WCNative.ui.clearObjective()`, `WCNative.ui.blankObjective()` | Verified | creator | The two pre-v3 idioms (`0`, and a literal space). |

`WCNative._` holds the shared validation helpers (`entity`, `ped`, `mpPed`, `invoke`, `bool`,
`float`, `fail`); it is internal to `client/natives/`.

## Why these are not on the production path

### MetaPed request lifecycle

`0xF97C34C33487D569 → 0x43E4DA469541A9C9 / 0xC0940AC858C1E126 → 0x0BCD4091C8EABA42 →
0x3972F78A78B5D9DF` requests a MetaPed asset, waits for it, creates a ped from it and releases the
request. Players and preview peds in w_creators are `mp_male` / `mp_female` created by model and
dressed through w_lib — the path the pre-v3 resource and vorp_character run in production. The
request natives' names and parameter layouts come from research notes and are not confirmed on the
current game build, and a request that is never released leaks. The wrappers therefore exist only
behind `Config.Experimental.metapedRequestPath` (default `false`) and are built so they cannot leak:
`requestPed(assetHash, timeoutMs)` waits with a timeout (`WCUtil.waitUntil`) and releases the
request on timeout or when the request becomes invalid; `release(handle)` is idempotent; every
outstanding handle is released on `onResourceStop`.

### Hat access

`_SET_PLAYER_HAT_ACCESS` changes whether the player may wear/remove a hat through the game's own
interaction. It is per player (not per ped), its interaction with metaped hats applied by script is
undocumented, and toggling it does not change `app.clothing.equipped`. The production hat state
(`Config.ClothingStates` group `hat`) instead removes the equipped hat component and re-applies the
same hash, which works on every ped (player and preview) and keeps ownership untouched. The wrapper
stays behind `Config.Experimental.hatAccess` (default `false`).

### Variation preset

`0xFFA1594703ED27CA` is recorded in the research notes as a ped variation preset setter; its name
and semantics are unconfirmed. The render pipeline already establishes valid drawable slots with
the verified `_EQUIP_META_PED_OUTFIT_PRESET` (preset 3) followed by explicit components, so the
unconfirmed native is not needed. It is behind `Config.Experimental.variationPreset` (default
`false`).

### Resurrect variant

`NETWORK_RESURRECT_LOCAL_PLAYER` (plain parameters) is what w_ambulancejob uses in production, and
`WCNative.respawn.resurrect` wraps exactly that call. The research notes also name
`_NETWORK_RESURRECT_LOCAL_PLAYER_2`, which takes a native struct whose layout is not verified;
passing a wrongly laid out struct to a native is undefined behaviour. It is documented as
**Experimental** and deliberately **not wrapped and not used**.
