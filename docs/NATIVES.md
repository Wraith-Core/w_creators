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
"OneSync tested here" in the doc blocks refers to `docs/TESTING.md` (what the automated tests cover
and what still needs an in-game check).

## Confidence levels

| Level | Meaning |
|---|---|
| **Verified** | Used by the pre-v3 working resource, by w_lib, or by another production resource on this server (w_ambulancejob, w_core), with the same argument layout. |
| **Likely** | Documented and widely used by the RedM community; not exercised by this resource before v3. |
| **Experimental** | Research only. Behind a gate that is off by default and not on any production path: a `Config.Experimental.*` flag, or `Config.Admin.devTools` for the dev-tools-only category discovery natives. Names may be unconfirmed. |
| **Deprecated / Avoid** | Known to be unreliable; kept documented so nobody reintroduces it. |

No native wrapped or called here is currently classified **Deprecated / Avoid**. The struct variant
`_NETWORK_RESURRECT_LOCAL_PLAYER_2` is documented as Experimental and deliberately not wrapped
(see "Resurrect variant" below).

## OneSync

**OneSync tested here: no.** Nothing in this resource was run on a live RedM server, with or
without OneSync. Every row below carries that flag; "Verified" means another resource runs the same
call in production, not that w_creators exercised it in game. The live checks are `docs/TESTING.md`
§2 (L9 for two-client sync) and §3 (verifying an experimental native).

Flags used below: **ped check** (`DoesEntityExist` + `IsEntityAPed` before the call), **entity check**
(`DoesEntityExist` only), **needs refresh** (batch `WCNative.ped.refresh` afterwards), **float
coercion** (numbers passed as floats, NaN/inf rejected), **gate** (returns `nil`/`false` unless the
named flag is on), **MP safe** (as recorded in the wrapper's doc block).

## Inventory

Every wrapper in `client/natives/*.lua` (`camera`, `clothing`, `metaped`, `ped`, `respawn`, `scene`,
`ui`).

| Hash | Name | Wrapper | Confidence | Used by | Flags | Notes |
|---|---|---|---|---|---|---|
| `0xA0BC8FAED8CFEB3C` | `_IS_PED_READY_TO_RENDER` | `WCNative.metaped.isReadyToRender(ped)` | Verified | appearance pipeline | ped check · MP safe: yes · OneSync tested here: no | Returns `true` or `1`; can be true while the skeleton is collapsed, so callers also check a bone height. |
| `0x77FF8D35EEC6BBC4` | `_EQUIP_META_PED_OUTFIT_PRESET` | `WCNative.metaped.equipOutfitPreset(ped, presetId, p2)` | Verified | appearance pipeline (preset step) | ped check · needs refresh · MP safe: yes · OneSync tested here: no | Must run before the saved face/body; preset 3 is the MP base outfit. |
| `0xFFA1594703ED27CA` | `_SET_PED_VARIATION_PRESET` (unconfirmed) | `WCNative.metaped.setVariationPreset(ped, presetHash, p2)` | Experimental | nothing | gate `Config.Experimental.variationPreset` · ped check · MP safe: unknown · OneSync tested here: no | Returns `false` while the flag is off. |
| `0xF97C34C33487D569` | `_REQUEST_META_PED_ASSET` (unconfirmed) | internal to `WCNative.metaped.requestPed` | Experimental | nothing | gate `Config.Experimental.metapedRequestPath` · timeout + guaranteed release · MP safe: unknown · OneSync tested here: no | Request lifecycle, see below. |
| — | request + wait + release | `WCNative.metaped.requestPed(assetHash, timeoutMs)` | Experimental | nothing | gate `Config.Experimental.metapedRequestPath` · timeout (default 5000 ms) · released on timeout / invalid request · OneSync tested here: no | Returns the handle or `nil`; see the request lifecycle below. |
| `0x43E4DA469541A9C9` | `_HAS_META_PED_ASSET_LOADED` (unconfirmed) | `WCNative.metaped.isRequestLoaded(handle)` | Experimental | nothing | tracked handles only (none exist while the gate is off) · MP safe: unknown · OneSync tested here: no | Tracked handles only. |
| `0xC0940AC858C1E126` | `_IS_META_PED_ASSET_REQUEST_VALID` (unconfirmed) | `WCNative.metaped.isRequestValid(handle)` | Experimental | nothing | tracked handles only · MP safe: unknown · OneSync tested here: no | Tracked handles only. |
| `0x0BCD4091C8EABA42` | `_CREATE_PED_FROM_META_PED_ASSET` (unconfirmed) | `WCNative.metaped.createPed(handle, coords, heading, networked)` | Experimental | nothing | loaded tracked handle only · float coercion · MP safe: unknown · OneSync tested here: no | The caller still owns the handle. |
| `0x3972F78A78B5D9DF` | `_RELEASE_META_PED_ASSET_REQUEST` (unconfirmed) | `WCNative.metaped.release(handle)` | Experimental | nothing | idempotent · MP safe: unknown · OneSync tested here: no | Idempotent; all outstanding handles are released on resource stop. |
| `0xCCB97B51893C662F` | `_GET_NUM_META_PED_COMPONENT_CATEGORIES` (unconfirmed) | `WCNative.metaped.numCategories(ped)` | Experimental | dev tools only | gate `Config.Admin.devTools` · ped check · read-only · OneSync tested here: no | Category discovery. `Config.Admin.devTools` (default off); returns `nil` when off. |
| `0xA622E66EEE92A08D` | `_GET_META_PED_COMPONENT_CATEGORY_AT_INDEX` (unconfirmed) | `WCNative.metaped.categoryAt(ped, index)` | Experimental | dev tools only | gate `Config.Admin.devTools` · ped check · read-only · OneSync tested here: no | Returns a u32 category hash. `Config.Admin.devTools` (default off); returns `nil` when off. |
| `0x5653AB26C82938CF` | `_SET_CHAR_EXPRESSION` | `WCNative.ped.setExpression(ped, expressionId, value)` | Verified | appearance pipeline (morph) | ped check · float, clamped −1..1 · needs refresh · MP safe: yes · OneSync tested here: no | Value must be a float (clamped −1..1); no refresh — batch with `refresh`. |
| `0x704C908E9C405136` | pre-refresh | `WCNative.ped.preRefresh(ped)` | Verified | `refresh` | ped check · MP safe: yes · OneSync tested here: no | w_lib uses the same pair. |
| `0xCC8CA3E88256E58F` | `_UPDATE_PED_VARIATION` | `WCNative.ped.updateVariation(ped)` | Verified | `refresh`, tailor NPCs | ped check · MP safe: yes · OneSync tested here: no | Params `(ped, false, true, true, true, false)`. |
| — | batch refresh | `WCNative.ped.refresh(ped)` | Verified | appearance pipeline | ped check · batched · OneSync tested here: no | `0x704C908E9C405136` then `0xCC8CA3E88256E58F`, once per structural commit, never per feature (fixes A11): three per full render (the preset, the body commit and the final commit after the morph, see the `client/appearance/pipeline.lua` header). |
| by name | `SET_PED_SCALE` | `WCNative.ped.setScale(ped, scale)` | Verified | appearance pipeline (height) | ped check · float coercion · MP safe: yes · OneSync tested here: no | Float coercion: an integer scale collapses the skeleton. |
| `0x9587913B9E772D29` | `_PLACE_ENTITY_ON_GROUND_PROPERLY` | `WCNative.ped.placeOnGround(entity)` | Verified | preview scene (`CreatorScene.position`); the store's fitting stand and the way back to the counter (`WCServiceFlow`, before the player is frozen / unfrozen) | entity check · MP safe: yes · OneSync tested here: no | Accepts peds (the OBJECT variant does not). The spawn does not use it: it probes the ground with `GetGroundZAndNormalFor_3dCoord`. |
| `0x1D491CCF7211FB74` | `_GET_PED_HEIGHT` | `WCNative.ped.height(ped)` | Likely | the editor's height readout (`WCEditorTree.heightDisplay`, `Config.Creator.heightUnit`) | ped check · read only · answer bounded 0.5..3.0 m · MP safe: yes · OneSync tested here: no | Read at the scale the ped wears; the tree divides by that scale for the height at 1.0. No answer keeps the plain ×100 readout. Needs an in-game check (L2.14). |
| `0x971D38760FBC02EF` | `SET_PED_KEEP_TASK` | `WCNative.ped.setKeepTask(ped, toggle)` | Verified | first-spawn cutscene | ped check · MP safe: yes · OneSync tested here: no | Wagon driver. |
| `0x5E3BDDBCB83F3D84` | `_GIVE_WEAPON_TO_PED_2` | `WCNative.ped.giveWeapon(ped, weapon, ammo, forceInHand, forceInHolster)` | Verified | preview scene | ped check · preview peds only · MP safe: yes · OneSync tested here: no | Holstered revolver on preview peds only; never the player ped. |
| `0x2703EFB583F0949A` | `_SET_VOFX_PED_VOICE` | `WCNative.ped.setVoice(ped, voice)` | Likely | appearance pipeline (`render` end, `ApplyDiff` on a voice/sex change) | ped check · name hashed · local to each client · MP safe: yes · OneSync tested here: no | 2026-10-19: `VOFX_PLAYER_MALE01..03` / `VOFX_PLAYER_FEMALE01..03` from `AppearanceSchema.vofxName(sex, voice)`; set on every ped the client draws (remote players too). Needs an in-game check. |
| `0xBC9AE166038A5CEC` | `PLAY_PAIN` | `WCNative.ped.playPain(ped, painId)` | Verified | the creator's voice sample (`body.voice.play`) | ped check · painId clamped 0..12 · local (isNetwork false) · MP safe: yes · OneSync tested here: no | Same call as w_hud (`PlayPain(ped, 9, 1, true, true)`); plays in the ped's current voice. |
| `0x6C8065A3B780185B` | `SET_AMBIENT_VOICE_NAME` | `WCNative.ped.setSpeechVoice(ped, name)` | Likely | appearance pipeline (`ApplyVoice`) | ped check · local to each client · MP safe: yes · OneSync tested here: no | 2026-10-19: the speaking voice (`AppearanceSchema.speechVoice`); mp_male/mp_female have no voice group, so the game spoke as JOHN. Needs an in-game check. |
| `0x8E04FEDD28D42462` | `PLAY_PED_AMBIENT_SPEECH_NATIVE` | `WCNative.ped.speak(ped, line, voice, paramsName)` | Verified | the voice sample; greet / antagonize (`client/voice/speak.lua`) | ped check · var-string pointers · syncOverNetwork 0 · MP safe: yes · OneSync tested here: no | The 0x40 params struct of w_store `client/speech.lua`; every client plays the relayed line itself. |
| `0x19173C3F15367B54` | `_SET_PLAYER_GREET_DISABLED_FOR_PED` | `WCNative.ped.muteGreet(ped, duration)` | Likely | `client/voice/speak.lua` (each frame while a person is focused) | ped check · MP safe: yes · OneSync tested here: no | Mutes the game's JOHN-line greet; ours replaces it. In-game check: the game's prompt must not show twice. |
| `0x5708EDD71B50C008` | `_SET_PLAYER_ANTAGONIZE_DISABLED_FOR_PED` | `WCNative.ped.muteAntagonize(ped, duration)` | Likely | `client/voice/speak.lua` (each frame while a person is focused) | ped check · MP safe: yes · OneSync tested here: no | The game's antagonize lines are player-only (JOHN/ARTHUR banks); ours replaces it. |
| `0xD3A7B003ED343FD9` | `_APPLY_SHOP_ITEM_TO_PED` | `WCNative.clothing.applyShopItem(ped, hash, immediately, isMultiplayer, p4)` | Verified | nothing (documented raw alternative of `w.component.apply`) | ped check · needs refresh · MP safe: yes · OneSync tested here: no | `Appearance.ApplyComponent` has no raw fallback: a failing `w.component.apply` is logged. Refresh afterwards. |
| `0xD710A5007C2AC539` | `_REMOVE_TAG_FROM_META_PED` | `WCNative.clothing.removeTag(ped, category, p2)` | Likely | nothing (documented raw alternative of `w.component.remove`) | ped check · needs refresh · MP safe: yes · OneSync tested here: no | `Appearance.RemoveCategory` has no raw fallback. Category name or hash; refresh afterwards. |
| `0xA0C683284DF027C7` | `_SET_PLAYER_HAT_ACCESS` | `WCNative.clothing.setHatAccess(player, access, p2)` | Experimental | nothing | gate `Config.Experimental.hatAccess` · per player, not per ped · MP safe: unknown · OneSync tested here: no | `Config.Experimental.hatAccess`; see below. |
| `0x69D65E89FFD72313` | `_REQUEST_LETTER_BOX_NOW` | `WCNative.camera.letterbox(enable, p1)` | Verified | first-spawn cutscene | per frame · local presentation · MP safe: yes · OneSync tested here: no | Re-request every frame while active. |
| by name | `NETWORK_RESURRECT_LOCAL_PLAYER` | `WCNative.respawn.resurrect(coords, heading)` | Verified | respawn service (`exports.w_creators:Resurrect`) | local player only · float coercion · MP safe: yes · OneSync tested here: no | The player ped handle **may** change (not confirmed: w_ambulancejob keeps using the handle it read before the call); the caller re-reads `PlayerPedId()` afterwards and restores the appearance. |
| `0x513F8AA5BF2F17CF` | `_NEW_LOAD_SCENE_START_SPHERE` | `WCNative.scene.loadSphere(x, y, z, radius, p4)` | Verified | creator/selection scene | asynchronous · float coercion · MP safe: yes · OneSync tested here: no | Asynchronous; wait on collision/IPL state with a timeout. |
| `0x524B54361229154F` | `TASK_START_SCENARIO_IN_PLACE_HASH` | `WCNative.scene.startScenario(ped, scenario, duration, heading)` | Verified | preview peds | ped check · MP safe: yes · OneSync tested here: no | Heading defaults to the ped's. |
| nine hashes (`WCNative.scene.DENSITY_THIS_FRAME`) | the ambient ped / human / animal, scenario ped / human / animal, vehicle, random and parked vehicle `…_DENSITY_MULTIPLIER_THIS_FRAME` natives (several are unnamed `_` natives) | `WCNative.scene.densityThisFrame(multiplier)` | Likely | creator/selection scene (`CreatorScene.suppressAmbient`, `Config.Scene.ambient = false`) | per frame · float coercion · local streaming only · MP safe: yes · OneSync tested here: no | Invoked by hash because several have no settled name; peds that already exist are removed once by `CreatorScene.cleanup`. |
| `0x1B5C85C612E5256E` | `ADD_SCENARIO_BLOCKING_AREA` | `WCNative.scene.blockScenarios(x, y, z, radius)` | Likely | creator/selection scene (`CreatorScene.load`) | float coercion · returns the area handle · MP safe: yes · OneSync tested here: no | A box of `cleanupRadius` around the anchor; removed on release and resource stop. |
| `0x31D16B74C6E29D66` | `REMOVE_SCENARIO_BLOCKING_AREA` | `WCNative.scene.unblockScenarios(handle)` | Likely | `CreatorScene.release`, resource stop | handle check · MP safe: yes · OneSync tested here: no | Only the handle `blockScenarios` returned. |
| `0x1FCA98E33C1437B3` | `_CREATE_ANIM_SCENE` | `WCNative.scene.createAnimScene(dict, flags, playlist)` | Likely | the store's catalogue book (`WCCatalogue.enter` / `exit`) | returns the scene handle · MP safe: yes (local) · OneSync tested here: no | One scene per playlist (`PBL_ENTER`, `PBL_EXIT_INDEX`); deleted with `deleteAnimScene`. Needs an in-game check. |
| `0x020894BF17A02EF2` | `SET_ANIM_SCENE_ORIGIN` | `WCNative.scene.setAnimSceneOrigin(scene, x, y, z, heading)` | Likely | `WCCatalogue` | float coercion · MP safe: yes (local) · OneSync tested here: no | The book lowered by `Config.Clothing.catalogue.scene.drop`, at the book's heading. |
| `0x8B720AD451CA2AB3` | `SET_ANIM_SCENE_ENTITY` | `WCNative.scene.setAnimSceneEntity(scene, name, entity)` | Likely | `WCCatalogue` | entity check · MP safe: yes (local) · OneSync tested here: no | The role names are the scene's own (`scene.entity`, `scene.bookEntity`): a wrong name is ignored by the game. |
| `0xAF068580194D9DC7` | `LOAD_ANIM_SCENE` | `WCNative.scene.loadAnimScene(scene)` | Likely | `WCCatalogue` | asynchronous · MP safe: yes (local) · OneSync tested here: no | Waited on with `isAnimSceneLoaded` and `scene.loadMs`. |
| `0x477122B8D05E7968` | `IS_ANIM_SCENE_LOADED` | `WCNative.scene.isAnimSceneLoaded(scene)` | Likely | `WCCatalogue` | BOOL answers 1 · MP safe: yes (local) · OneSync tested here: no | — |
| `0xF4D94AF761768700` | `START_ANIM_SCENE` | `WCNative.scene.startAnimScene(scene)` | Likely | `WCCatalogue` | MP safe: yes (local) · OneSync tested here: no | — |
| `0xD8254CB2C586412B` | `IS_ANIM_SCENE_FINISHED` | `WCNative.scene.isAnimSceneFinished(scene)` | Likely | `WCCatalogue` | BOOL answers 1 · MP safe: yes (local) · OneSync tested here: no | A looping playlist never finishes: every wait is capped (`waitMs`, `exitMs`). |
| `0x2BF96692C67F3E53` | `REMOVE_ANIM_SCENE_ENTITY` | `WCNative.scene.removeAnimSceneEntity(scene, name, entity)` | Likely | `WCCatalogue.release` (the player leaves the reading before the fitting-room move) | entity check · MP safe: yes (local) · OneSync tested here: no | The scene is deleted right after; the flow then clears the player's tasks and waits `WCServiceFlow.RELEASE_MS` before moving him, and checks under the fade that the move held (a scene that still held him put him back at the counter). Needs an in-game check. |
| `0x84EEDB2C6E650000` | `_DELETE_ANIM_SCENE` | `WCNative.scene.deleteAnimScene(scene)` | Likely | `WCCatalogue.stop` (under the fade, on every exit path and on resource stop) | never yields · MP safe: yes (local) · OneSync tested here: no | — |
| `0xEC9A1261BF0CE510` | `_GET_META_PED_TYPE` | `WCNative.clothing.metapedType(ped)` | Verified | `WCNative.clothing.wearableStates` (the wearer's type) | an existing ped only · MP safe: yes · OneSync tested here: no | The shop item natives take this int, as w_lib's component module passes it. |
| `0xFFCC2DB2D9953401` | `_GET_SHOP_ITEM_NUM_WEARABLE_STATES` | internal to `WCNative.clothing.wearableStates(hash, pedOrType)` | Likely | clothing states (`WCClothing.supports`), `wc_states` | read-only game data · MP safe: yes · OneSync tested here: no | The count of an item's own wearable states for the wearer's metaped type (read from the ped, or given). |
| `0x6243635AF2F1B826` | `_GET_SHOP_ITEM_WEARABLE_STATE_BY_INDEX` | internal to `WCNative.clothing.wearableStates(hash, pedOrType)` | Likely | clothing states: a raisable bandana, the loadout side, the vest tuck, the body-part fix | read-only game data · MP safe: yes · OneSync tested here: no | `wearableStates` answers the state hashes, or `nil` (then a garment's state is let through, and no body state is offered). |
| `0xFA925AC00EB830B9` | `_CREATE_VAR_STRING` | `WCNative.ui.varString(text)` | Verified | `blankObjective` (creator exit) | text coerced with `tostring` · MP safe: yes · OneSync tested here: no | `LITERAL_STRING`. |
| `0xFA233F8FE190514C` | `_UILOG_SET_CACHED_OBJECTIVE` | `WCNative.ui.setObjective(str)` | Verified | `clearObjective`, `blankObjective` (creator) | MP safe: yes · OneSync tested here: no | `0` clears. |
| `0xE9990552DEC71600` | `_UILOG_PRINT_CACHED_OBJECTIVE` | `WCNative.ui.printObjective()` | Verified | `clearObjective`, `blankObjective` (creator) | MP safe: yes · OneSync tested here: no | — |
| — | clear / blank objective | `WCNative.ui.clearObjective()`, `WCNative.ui.blankObjective()` | Verified | creator | built on the two above · MP safe: yes · OneSync tested here: no | The two pre-v3 idioms (`0`, and a literal space). |
| `0x2A32FAA57B937173` | `DRAW_MARKER` | `WCNative.ui.drawMarker(kind, x, y, z, size, r, g, b, a)` | Verified | services/board (the chair picker: box on the object under the crosshair, dot at the hit) | one frame, local to this client · MP safe: yes · OneSync tested here: no | w_doorlock's door picker draws the same box (`0x6EB7D3BB`) and sphere (`0x50638AB9`). |

`WCNative._` holds the shared validation helpers (`entity`, `ped`, `mpPed`, `invoke`, `bool`,
`float`, `fail`); it is internal to `client/natives/`.

### Named natives called outside `client/natives/`

Plain named natives are allowed anywhere (§0.4). The CitizenFX runtime resolves them by name, so this
repository never hard-codes their hash ("by name" below; the hashes were not checked independently
here). None has a `WCNative` wrapper. **Used by** paths are relative to `client/` without `.lua`.
**Basis** names the production resources that run the same native (pre-v3 w_creators, w_lib,
w_ambulancejob, w_core); "none" makes it **Likely**. **Flags**: "by-name lookup + pcall" = looked up
as a global and pcall'd (a missing native reads as `false` and the step is skipped), "pcall" = called
inside `pcall`, "existence-guarded" = the global is checked before use, "direct" = a plain call.

| Name | Hash | Wrapper | Confidence | Used by | Flags | Basis |
|---|---|---|---|---|---|---|
| `ClearFocus` | by name | — | Verified | camera/camera, scene/scene, spawn/selector | direct · OneSync tested here: no | pre-v3 |
| `ClearOverrideWeather` | by name | — | Likely | scene/environment | by-name lookup + pcall (scene/environment) · OneSync tested here: no | none |
| `ClearPedTasks` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `ClearPedTasksImmediately` | by name | — | Verified | creator/cutscene, scene/environment, scene/scene, spawn/spawn | by-name lookup + pcall (spawn/spawn); direct elsewhere · OneSync tested here: no | pre-v3, w_lib |
| `ClearTimecycleModifier` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `ClearWeatherTypePersist` | by name | — | Likely | scene/environment | by-name lookup + pcall (scene/environment) · OneSync tested here: no | none |
| `CreateCam` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `DestroyCam` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `DisableAllControlActions` | by name | — | Verified | characters/selector, creator/creator, creator/cutscene, scene/environment, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `DisablePlayerFiring` | by name | — | Verified | services/board | direct (chair picker, every frame) · OneSync tested here: no | w_doorlock |
| `DisplayHud` | by name | — | Verified | characters/selector, core/ui, scene/environment, spawn/selector, spawn/spawn | pcall (characters/selector); direct elsewhere · OneSync tested here: no | pre-v3, w_lib |
| `DisplayRadar` | by name | — | Verified | core/ui | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `DoScreenFadeIn` | by name | — | Verified | characters/selector, core/ui, spawn/selector | pcall (core/ui); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `DoScreenFadeOut` | by name | — | Verified | core/ui, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `DoesCamExist` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `DoesEntityExist` | by name | — | Verified | appearance/overlays, appearance/pipeline, appearance/sync, barber/barber, camera/camera, characters/selector, clothing/states, creator/creator, creator/cutscene, dev/tools, editor/editor, natives/metaped, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/selector, spawn/spawn | existence-guarded (editor/editor); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `DrawLightWithRange` | by name | — | Verified | scene/scene, scene/environment (the fitting-room light) | direct · OneSync tested here: no | pre-v3, w_lib |
| `EquipMetaPedOutfit` | by name | — | Verified | appearance/pipeline | existence-guarded: falls back to `w.component.setWaistType` · OneSync tested here: no | w_lib |
| `FreezeEntityPosition` | by name | — | Verified | barber/barber, characters/selector, creator/creator, scene/environment, scene/scene, services/locations, spawn/selector, spawn/spawn | pcall (barber/barber, services/locations); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `GetClosestObjectOfType` | by name | — | Likely | services/board | direct (chair picker: a barber chair of the game near the crosshair) · OneSync tested here: no | none (w_farming uses it for props) |
| `GetEntityCoords` | by name | — | Verified | appearance/pipeline, barber/barber, camera/camera, characters/selector, creator/cutscene, dev/tools, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `GetEntityHeading` | by name | — | Verified | barber/barber, camera/camera, natives/scene, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `GetEntityModel` | by name | — | Verified | appearance/pipeline, creator/cutscene, natives/metaped, respawn/respawn | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `GetGamePool` | by name | — | Verified | scene/scene | pcall (scene/scene) · OneSync tested here: no | pre-v3, w_lib, w_core |
| `GetEntityBoneIndexByName` | by name | — | Likely | camera/camera (`handLeft` / `handRight`: `SKEL_L_Hand`, `SKEL_R_Hand`) | existence-guarded + pcall: an unreadable bone falls back to the `hands` framing · OneSync tested here: no | none |
| `GetGroundZAndNormalFor_3dCoord` | by name | — | Verified | dev/tools, spawn/spawn | pcall (spawn/spawn); direct elsewhere · OneSync tested here: no | pre-v3, w_core |
| `GetInteriorAtCoords` | by name | — | Likely | scene/scene | existence-guarded + pcall (scene/scene: `Config.Scene.interior`) · OneSync tested here: no | none |
| `GetModelDimensions` | by name | — | Verified | services/board | direct · OneSync tested here: no | w_doorlock |
| `GetOffsetFromEntityInWorldCoords` | by name | — | Verified | scene/environment (the fitting-room light, `Config.Clothing.fittingLight`) | pcall · OneSync tested here: no | pre-v3, w_lib |
| `GetPedBoneCoords` | by name | — | Verified | appearance/pipeline, camera/camera | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `GetRegisteredCommands` | by name | — | Verified | clothing/states (a toggle command another resource registered is skipped) | existence-guarded + pcall · OneSync tested here: no | CitizenFX runtime function |
| `GetPedGroupIndex` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `GetPedRelationshipGroupHash` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `GetPlayerFromServerId` | by name | — | Verified | appearance/sync | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `GetPlayerPed` | by name | — | Verified | appearance/sync | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `GetWorldPositionOfEntityBone` | by name | — | Likely | camera/camera (the hand framings) | existence-guarded + pcall; an answer at the entity origin counts as unreadable · OneSync tested here: no | none |
| `GetPlayerServerId` | by name | — | Verified | appearance/sync | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `HasAnimDictLoaded` | by name | — | Verified | editor/editor (the teeth view) | existence-guarded + pcall · OneSync tested here: no | w_lib |
| `HasCollisionLoadedAroundEntity` | by name | — | Verified | barber/barber, creator/cutscene, scene/environment, scene/scene, services/locations, spawn/spawn | direct · OneSync tested here: no | pre-v3 |
| `HidePedWeapons` | by name | — | Likely | scene/environment | by-name lookup + pcall (scene/environment) · OneSync tested here: no | none |
| `IsEntityAMissionEntity` | by name | — | Verified | scene/scene (`CreatorScene.cleanup`: another resource's scripted ped near the stage is kept) | pcall · OneSync tested here: no | w_lib |
| `IsEntityAPed` | by name | — | Likely | natives/metaped (`WCNative._.ped` validation) | existence-guarded: a missing native skips the check · OneSync tested here: no | none |
| `IsEntityDead` | by name | — | Verified | barber/barber, characters/selector, clothing/states, creator/cutscene, respawn/respawn, services/locations, spawn/selector | by-name lookup + pcall (clothing/states, respawn/respawn); pcall (barber/barber, services/locations); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `IsEntityPlayingAnim` | by name | — | Verified | editor/editor (the teeth view) | existence-guarded + pcall · OneSync tested here: no | w_lib |
| `IsInteriorReady` | by name | — | Likely | scene/scene | existence-guarded + pcall (scene/scene: `Config.Scene.interior`) · OneSync tested here: no | none |
| `IsIplActiveByHash` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `IsLoadSceneLoaded` | by name | — | Verified | spawn/selector | by-name lookup + pcall (spawn/selector) · OneSync tested here: no | pre-v3 |
| `IsModelValid` | by name | — | Verified | creator/cutscene, dev/tools | direct · OneSync tested here: no | pre-v3, w_lib |
| `IsPedAPlayer` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `IsPedDeadOrDying` | by name | — | Verified | clothing/states, respawn/respawn | by-name lookup + pcall (clothing/states, respawn/respawn) · OneSync tested here: no | w_ambulancejob |
| `IsPedGettingIntoAVehicle` | by name | — | Likely | clothing/states | by-name lookup + pcall (clothing/states) · OneSync tested here: no | none |
| `IsPedInAnyVehicle` | by name | — | Verified | clothing/states, creator/cutscene, spawn/spawn | by-name lookup + pcall (clothing/states, spawn/spawn); direct elsewhere · OneSync tested here: no | w_ambulancejob |
| `IsPedInCombat` | by name | — | Likely | clothing/states | by-name lookup + pcall (clothing/states) · OneSync tested here: no | none |
| `IsPedInMeleeCombat` | by name | — | Likely | clothing/states | by-name lookup + pcall (clothing/states) · OneSync tested here: no | none |
| `IsPedInVehicle` | by name | — | Likely | creator/cutscene | direct · OneSync tested here: no | none |
| `IsPedOnMount` | by name | — | Verified | clothing/states | by-name lookup + pcall (clothing/states) · OneSync tested here: no | w_lib |
| `IsPedRagdoll` | by name | — | Verified | clothing/states | by-name lookup + pcall (clothing/states) · OneSync tested here: no | w_lib, w_ambulancejob |
| `IsPedUsingAnyScenario` | by name | — | Verified | barber/barber | direct (barber chair: did the scenario take) · OneSync tested here: no | w_baloot |
| `IsPlayerTeleportActive` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `IsRadarHidden` | by name | — | Likely | core/ui | pcall (core/ui); existence-guarded (core/ui) · OneSync tested here: no | none |
| `IsScreenFadedOut` | by name | — | Verified | characters/selector, core/ui, creator/cutscene, spawn/selector, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `IsScreenFadingIn` | by name | — | Verified | core/ui, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib |
| `IsScreenFadingOut` | by name | — | Verified | characters/selector, core/ui, creator/cutscene, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib |
| `LoadSceneStart` | by name | — | Verified | spawn/selector | by-name lookup + pcall (spawn/selector) · OneSync tested here: no | pre-v3 |
| `LoadSceneStop` | by name | — | Verified | spawn/selector | by-name lookup + pcall (spawn/selector) · OneSync tested here: no | pre-v3 |
| `NetworkClearClockTimeOverride` | by name | — | Verified | scene/environment, scene/scene | direct · OneSync tested here: no | pre-v3 |
| `NetworkClockTimeOverride` | by name | — | Verified | scene/environment, scene/scene | direct · OneSync tested here: no | pre-v3 |
| `NetworkGetEntityIsNetworked` | by name | — | Verified | appearance/overlays | direct · OneSync tested here: no | pre-v3, w_lib |
| `NetworkGetNetworkIdFromEntity` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `NetworkIsSessionStarted` | by name | — | Verified | appearance/sync, characters/selector | direct · OneSync tested here: no | pre-v3 |
| `NetworkSetEntityOnlyExistsForParticipants` | by name | — | Verified | characters/selector, creator/creator, creator/cutscene, spawn/selector, spawn/spawn | by-name lookup + pcall (spawn/selector, spawn/spawn); direct elsewhere · OneSync tested here: no | pre-v3, w_core |
| `PlaySoundFrontend` | by name | — | Verified | creator/creator | direct · OneSync tested here: no | pre-v3, w_lib |
| `PlayerId` | by name | — | Verified | appearance/pipeline, appearance/sync, scene/scene | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `PlayerPedId` | by name | — | Verified | appearance/pipeline, appearance/sync, barber/barber, characters/selector, clothing/states, creator/creator, creator/cutscene, dev/tools, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/selector, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `PointCamAtCoord` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3 |
| `RemoveImap` | by name | — | Verified | scene/scene | existence-guarded (scene/scene): fallback when `RemoveIplByHash` is missing · OneSync tested here: no | pre-v3 |
| `RemoveIplByHash` | by name | — | Likely | scene/scene | existence-guarded (scene/scene), `RemoveImap` fallback · OneSync tested here: no | none |
| `RemovePedFromGroup` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `RenderScriptCams` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `RequestAnimDict` | by name | — | Verified | editor/editor (the teeth view) | existence-guarded + pcall · OneSync tested here: no | w_lib |
| `RequestCollisionAtCoord` | by name | — | Verified | barber/barber, creator/cutscene, scene/environment, scene/scene, services/locations, spawn/selector, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_core |
| `RequestIplByHash` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `ResetEntityAlpha` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `SetBlockingOfNonTemporaryEvents` | by name | — | Verified | creator/cutscene, scene/scene | direct · OneSync tested here: no | pre-v3 |
| `SetCamActive` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `SetCamActiveWithInterp` | by name | — | Verified | camera/camera | direct · OneSync tested here: no | pre-v3, w_lib |
| `SetCamCoord` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib |
| `SetCamFov` | by name | — | Verified | camera/camera, spawn/selector | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `SetCinematicModeActive` | by name | — | Verified | creator/cutscene | pcall (creator/cutscene) · OneSync tested here: no | pre-v3 |
| `SetEntityAsMissionEntity` | by name | — | Verified | creator/cutscene, scene/scene | direct · OneSync tested here: no | pre-v3, w_core |
| `SetEntityCanBeDamaged` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3, w_lib |
| `SetEntityCollision` | by name | — | Verified | creator/creator, scene/scene | direct · OneSync tested here: no | pre-v3 |
| `SetEntityCoords` | by name | — | Verified | barber/barber, creator/cutscene, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/spawn | pcall (services/locations); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `SetEntityCoordsNoOffset` | by name | — | Verified | barber/barber | direct (barber chair: no scenario took him) · OneSync tested here: no | w_baloot |
| `SetEntityHeading` | by name | — | Verified | barber/barber, camera/camera, creator/cutscene, respawn/respawn, scene/environment, scene/scene, services/locations, spawn/spawn | pcall (services/locations); direct elsewhere · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob, w_core |
| `SetEntityInvincible` | by name | — | Verified | characters/selector, creator/creator, creator/cutscene, scene/environment, scene/scene, spawn/selector, spawn/spawn | direct · OneSync tested here: no | pre-v3, w_lib, w_ambulancejob |
| `SetEntityNoCollisionEntity` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `SetEntityVisible` | by name | — | Verified | characters/selector, creator/creator, scene/environment, scene/scene, spawn/selector, spawn/spawn | direct · OneSync tested here: no | pre-v3 |
| `SetFocusPosAndVel` | by name | — | Verified | camera/camera, scene/scene, spawn/selector | direct · OneSync tested here: no | pre-v3 |
| `SetModelAsNoLongerNeeded` | by name | — | Verified | appearance/pipeline | direct · OneSync tested here: no | pre-v3, w_lib, w_core |
| `SetNuiFocus` | by name | — | Verified | services/board, editor/editor, editor/panel, creator/creator, scene/environment | existence-guarded (board, editor, panel); pcall elsewhere · OneSync tested here: no | pre-v3, w_lib |
| `SetPedAsGroupMember` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `SetPedCanBeTargetted` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `SetPedIntoVehicle` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `SetPlayerModel` | by name | — | Verified | appearance/pipeline | direct · OneSync tested here: no | pre-v3, w_lib |
| `SetRelationshipBetweenGroups` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `SetTimecycleModifier` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `SetVehicleOnGroundProperly` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3, w_lib |
| `SetWeatherType` | by name | — | Likely | scene/environment | by-name lookup + pcall (scene/environment) · OneSync tested here: no | none |
| `ShutdownLoadingScreen` | by name | — | Verified | core/ui | pcall (core/ui) · OneSync tested here: no | pre-v3, w_core |
| `StartPlayerTeleport` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `StopAnimTask` | by name | — | Verified | clothing/states | pcall (clothing/states); existence-guarded (clothing/states) · OneSync tested here: no | w_lib, w_ambulancejob |
| `TaskLeaveVehicle` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `TaskPlayAnim` | by name | — | Verified | editor/editor (the teeth view: `Config.Creator.teethAnimation`) | existence-guarded + pcall · OneSync tested here: no | w_lib |
| `TaskStandStill` | by name | — | Verified | scene/scene | direct · OneSync tested here: no | pre-v3 |
| `TaskStartScenarioAtPosition` | by name | — | Likely | barber/barber | direct (barber chair: Config.Barber.chair.scenarios, args (ped, hash, x, y, z, heading, -1, false, true)) · OneSync tested here: no | w_baloot (PROP_PLAYER_BARBER_SEAT itself is untested in game) |
| `TaskVehicleDriveToCoord` | by name | — | Verified | creator/cutscene | direct · OneSync tested here: no | pre-v3 |
| `TriggerMusicEvent` | by name | — | Verified | creator/cutscene | pcall (creator/cutscene) · OneSync tested here: no | pre-v3 |

Argument layouts that matter (the Likely rows first):

| Name | Caller | Arguments used | Notes |
|---|---|---|---|
| `HidePedWeapons` | `scene/environment` (`WCPreviewEnv.enter{holster}`) | `(ped, 2, true)` | `exit()` does not re-draw the weapon. |
| `SetWeatherType` | `scene/environment` (`enter{weather}`) | `(GetHashKey(name), true, true, true, 0.0, true)` | Restored with `ClearOverrideWeather()` and `ClearWeatherTypePersist()` on `exit()`. |
| `RemoveIplByHash` (fallback `RemoveImap`) | `scene/scene` (`CreatorScene.unload()`) | `(hash)` | Unloads only the room maps `load()` requested; `RemoveImap` is what the pre-v3 creator used. |
| `IsPedInCombat`, `IsPedInMeleeCombat`, `IsPedGettingIntoAVehicle` | `clothing/states` (ped guard) | `(ped, 0)`, `(ped)`, `(ped)` | A missing native reads as false (that check is skipped). |
| `IsPedInVehicle` | `creator/cutscene` | `(ped, wagon, false)` | Seat checks of the wagon ride. |
| `IsRadarHidden` | `core/ui` (`IsRadarShown`) | `()` | Existence-guarded and pcall'd; a missing or failing native counts as "radar shown" (the flow hides it, then shows it again). |
| `IsEntityAPed` | `natives/metaped` (`WCNative._.ped`) | `(ped)` | A missing native skips the check (only `DoesEntityExist` remains). |
| `EquipMetaPedOutfit` | `appearance/pipeline` (waist type) | `(ped, AppearanceSchema.WAIST_TYPES[weight])` | Joins the batched refresh; falls back to `w.component.setWaistType` when the global is missing. |
| `GetGroundZAndNormalFor_3dCoord` | `spawn/spawn` (ground probe), `dev/tools` (`W:ADMIN:SpawnObject`) | `(x, y, z)` → `found, groundZ, normal` | Spawn: a probe more than 20 m from the target is rejected (§11); dev tools place the prop at `groundZ + 0.02`. |
| `LoadSceneStart`, `IsLoadSceneLoaded`, `LoadSceneStop` | `spawn/selector` | `(x, y, z, 0.0, 0.0, 0.0, 50.0, 0)`, `()`, `()` | Streams the spawn point shown by the selector. |
| `IsEntityDead`, `IsPedDeadOrDying` | respawn, spawn, selector, service flows, clothing states, cutscene | `(ped)`, `(ped, true)` | Death detection; last stand counts as dying. |
| `StopAnimTask` | `clothing/states` | `(ped, dict, clip, 1.0)` | Stops an interrupted clothing animation (`Config.Experimental.clothingAnimations`). |
| `NetworkSetEntityOnlyExistsForParticipants` | selector, creator, cutscene, spawn | `(entity, bool)` | Preview peds and the ride stay local to the player. |
| `SetVehicleOnGroundProperly`, `SetPedIntoVehicle`, `TaskVehicleDriveToCoord`, `TaskLeaveVehicle` | `creator/cutscene` | — | The wagon ride (passenger seat `1`, driver `-1`). |

CitizenFX runtime functions used on the client (not game natives; every resource uses them):
`AddEventHandler`, `CreateThread`, `Wait`, `RegisterNetEvent`, `RegisterCommand`, `RegisterNUICallback`,
`SendNUIMessage`, `SetNuiFocus`, `SetNuiFocusKeepInput`, `TriggerEvent`, `TriggerServerEvent`,
`GetCurrentResourceName`, `GetResourceState`, `LoadResourceFile`, `GetGameTimer`, `GetHashKey`,
`ShutdownLoadingScreenNui`.

### Server natives

Server-side natives by name (`server/` paths without `.lua`). The entity natives work on server-side
entities, which exist only with OneSync.

| Name | Hash | Wrapper | Confidence | Used by | Flags |
|---|---|---|---|---|---|
| `GetPlayerRoutingBucket` | by name | — | Verified | api, barber/grooming, scene | read-only · OneSync tested here: no |
| `SetPlayerRoutingBucket` | by name | — | Verified | spawn/spawn, scene | the scene isolation and `WCScene.toWorld` · OneSync tested here: no |
| `SetEntityRoutingBucket` | by name | — | Verified | scene | preview ped isolation; OneSync server entity · OneSync tested here: no |
| `GetEntityRoutingBucket` | by name | — | Verified | scene | read-back check; OneSync server entity · OneSync tested here: no |
| `GetPlayerPed` | by name | — | Verified | characters/characters, core/security, scene | OneSync server entity · OneSync tested here: no |
| `GetEntityHealth` | by name | — | Verified | characters/characters | switch death check; OneSync server entity · OneSync tested here: no |
| `GetEntityCoords` | by name | — | Verified | core/security, scene | proximity checks (`WCSecurity.near`); OneSync server entity · OneSync tested here: no |
| `GetEntityModel` | by name | — | Verified | scene | OneSync server entity · OneSync tested here: no |
| `GetEntityType` | by name | — | Verified | scene | OneSync server entity · OneSync tested here: no |
| `DoesEntityExist` | by name | — | Verified | core/security, scene | OneSync server entity · OneSync tested here: no |
| `NetworkGetEntityFromNetworkId` | by name | — | Verified | scene | OneSync server entity · OneSync tested here: no |
| `NetworkGetEntityOwner` | by name | — | Verified | scene | OneSync server entity · OneSync tested here: no |
| `IsPlayerAceAllowed` | by name | — | Verified | characters/characters, core/sessions (a location's `access.ace`), dev/tools, respawn/respawn | pcall in respawn and sessions · OneSync tested here: no |
| `GetPlayerName` | by name | — | Verified | api, characters/characters, respawn/respawn, scene, spawn/spawn | online check · OneSync tested here: no |
| `GetPlayers` | by name | — | Verified | barber/grooming, characters/characters | — · OneSync tested here: no |
| `GetPlayerIdentifier` | by name | — | Verified | bridge/framework | — · OneSync tested here: no |
| `GetPlayerIdentifierByType` | by name | — | Verified | bridge/framework | — · OneSync tested here: no |

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
