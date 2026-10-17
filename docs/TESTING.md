# w_creators — Testing

There are two kinds of tests:

1. **Automated suites** run outside the game: Python + lupa for the Lua code, and Node for the
   React NUI. They load the real resource files over stubs of the game, w_lib, the database and
   the framework.
2. **Live tests** need a RedM server with OneSync and real clients. **None of the live tests below
   has been executed.** Every row is marked `NOT EXECUTED — requires a live RedM server`. Do not
   treat the resource as verified in game until they have been run and their results recorded here.

## 1. Automated suites

### Prerequisites

- Python 3 with `lupa` (Lua 5.4 runtime, `lupa.lua54`). `luaparser` is optional; without it the
  global-symbol audit in `tests/test_global_symbols.py` is skipped.
- Sibling checkouts next to `w_creators/`:
  - `../w_lib`: the real clothing catalogue. Tests marked `REAL_CATALOG` are skipped without it.
  - `../w_ambulancejob`: needed by the ambulance tests.
- Node.js with `web/node_modules` installed (`cd web && npm install`).

### Running

```sh
# Lua (python + lupa)
cd w_creators
python3 -m unittest discover -s tests -p 'test_*.py'

# NUI (build first: the render tests bundle web/src with esbuild)
cd w_creators/web
npm run build
npm test            # node --test tests/*.test.mjs
```

If you change the Lua editor tree, regenerate the NUI payload fixtures with
`python3 web/tests/fixtures/generate_payloads.py`.

Results at this release (branch `claude/w-creators-rearch-u23ewx`, 2026-09-23):

| Suite | Result |
|---|---|
| Python (`tests/test_*.py`) | 1284 tests, OK (0 failures, 0 errors, 0 skipped) |
| NUI (`web/tests/*.test.mjs`) | 53 tests, 53 pass, 0 fail, 0 skipped |
| NUI build (`npm run build`) | OK (`web/build/index.html`, 210.84 kB) |

After the creator and clothing-store additions (Windows, 2026-09-25): Python 1443 tests, 6 failures that
were there before these changes (four `test_static_hygiene` / `test_locale_coverage` checks that compare
`/` paths and fail on Windows only, `test_debug_is_silent_unless_enabled`, and five result codes of other
work missing from ARCHITECTURE.md §4); NUI 65 of 65 pass.

### What each group covers

`tests/harness.py`, `tests/lua_source.py`, `tests/lua/stubs.lua` and `tests/lua/json.lua` are the
runtime: a fake clock and threads, events, players and routing buckets, `FakeDB`, fake framework
users, and w_lib stubs. `tests/fixtures/` holds the test catalogue. Every `tests/test_*_support.py`
file holds shared stubs for one group and contains no tests of its own.

| Group | Files | Covers |
|---|---|---|
| Static rules | `test_syntax.py`, `test_static_hygiene.py`, `test_global_symbols.py`, `test_natives.py` | every Lua file compiles under plain Lua 5.4; the manifest lists exactly the files on disk; no raw native outside `client/natives/`; no backtick hashes; no `print`/`console.log`/blind `Wait`; the event catalogue matches the code; every global a script reads is defined on its side; native wrappers validate, batch, never throw and stay behind their experimental gates |
| Locale | `test_locale_coverage.py`, `test_locale_keys.py` | every dictionary key the Lua can show exists in `locales/ar.json` (key → key) and `locales/en.json`; w_ambulancejob's keys too |
| Shared model | `test_shared_core.py`, `test_appearance.py`, `test_catalog_rules.py`, `test_morph_states_grooming.py`, `test_identity.py`, `test_render_scale.py` | `WCUtil`, `WCResult`, services, locations and hours, the config files; `AppearanceSchema` (defaults, sanitize, legacy v1/v2 → v3, merging, change detection); catalogue, taxonomy, prices, tints, rules; morphology, overlays, clothing states, grooming; identity validation; float/integer scale on preview peds |
| Server core | `test_server_core.py`, `test_optional_logger.py` | migrations, economy (charge/refund), security (rate limits, payload caps, locks), sessions, the appearance repository, the bridge, spawn grants; a missing or throwing logger never blocks selection, spawn or isolation |
| Server characters and world | `test_server_characters_flow.py`, `test_server_characters_world.py` | list/select/create/delete/switch callbacks, slots, typed delete, creation grants; scene isolation and release, spawn and admin respawn, appearance sync, restart adoption |
| Server commerce | `test_server_commerce_store.py`, `test_server_commerce_wardrobe.py`, `test_server_commerce_states.py`, `test_server_commerce_review.py` | ownership, store open/commit and pricing, wardrobe and saved outfits, `clothing:setState` |
| Server services | `test_server_services_api.py`, `test_server_services_barber.py`, `test_server_services_grooming.py`, `test_server_services_surgery.py`, `test_server_services_devtools.py` | every server export (`docs/API.md`), barber pricing and cap, growth accumulation/fold/cut, surgery sections, grants and ownership, dev tools gating |
| Client infrastructure and editor | `test_client_infra_env.py`, `test_client_infra_pipeline.py`, `test_client_infra_sync.py`, `test_editor_lua.py`, `test_editor_regressions.py` | preview environment, camera presets, scene peds, state locks; render pipeline order and batched refresh; remote sync scope watcher; editor tree per mode, control registry, undo, dirty state, prices, outfits, panel |
| Client characters | `test_client_characters_selector.py`, `test_client_characters_creator.py`, `test_client_characters_cutscene.py`, `test_client_characters_review.py` | selector boot, one preview ped, select → render → loaded, delete, `/characters`; creator grant, gender scene, stages, repair path; first-spawn cutscene |
| Creator scene and features | `test_creator_features.py` | the theatre stage data, its ped-relative coloured lights, the interior wait, the ambient population kept out (client and bucket), the pair camera, glide and profile turn; body build, custom eye tint, makeup sheet styles and extra tints, eyebrow texture sets, eyebrows following the hair, stacked scars, named styles and colour chips, hide clothes, the mouth on the teeth view, draft resume and keep-draft cancel, the height readout in metres / feet (`_GET_PED_HEIGHT`), the locked sex a grant reports (`beginCreate` `locked`) |
| Client commerce | `test_client_commerce_locations.py`, `test_client_commerce_store.py`, `test_client_commerce_wardrobe.py` | prompts/blips/NPCs per location, hours, dispatch; store fitting room, commit/cancel/forced close/death/stop; wardrobe outfits and the `OpenWardrobe` export |
| Clothing store additions | `test_clothing_store_features.py` | the game's blip sprites and the catalogue books; access rules (server and the client's answer); per-model prices, withheld and restricted models; paying with gold (currencies, a missing price, a client amount never taken); colourways (the owned-colour list, free owned colours, charged and kept new ones, the wardrobe's colour, outfit colours); tint limits; the boot accessories rule; selling back (share, refusals, the put-back on a failed refund); outfits in the store and buy-and-save-as-outfit (one transaction, refusals before any charge); the inventory bridge (off by default, wrap / put-back, use as a gift, the outfit card); the bandana state bag; the migrations and the citizen registry; the store / wardrobe editor trees (take off everything, the Payment choice, owned colours, strips and limits on the sliders, sell back, suggestions, the save-as-outfit field); the catalogue reading, the fitting-room light, the commit extras, the card look; the hand framings; the loadout / vest tuck / body states from the game's own list; the toggle commands |
| Client services | `test_client_services_api.py`, `test_client_services_barber.py`, `test_client_services_surgery.py`, `test_client_services_devtools.py`, `test_client_services_ambulance.py` | client exports and `/reloadappearance`; barber and surgery flows; dev commands; w_ambulancejob's surgery prompt → its server → `OpenCosmeticSurgery`, and its `w_creators:client:resurrected` listener |
| Client spawn and respawn | `test_client_spawn_flow.py`, `test_client_spawn_respawn.py`, `test_client_spawn_review.py` | spawn selector sends ids only, safe spawn ground probe (20 m rule) and fallback, admin/death respawn; the respawn state machine, `Resurrect`, external resurrect restore |
| Client clothing states | `test_client_states_controller.py`, `test_client_states_panel.py`, `test_client_states_review.py`, `test_hair_crown.py` | available actions, guards, per-action lock, server round trip with revert, experimental animation, panel tree, `/clothing` and the keybind, category exports; the long hair's crown: the REAL w_lib component module and pipeline on a fake metaped engine (`tests/lua/metaped_engine.lua`) that models the shop-item triggers (a raised bandana or a hat tucks a long hair), resolved on the state change or deferred to the next commit. Replays /hat and the wheel, the bandana, a relog with the bandana up, the store's diff, the creator's hide clothes, a remote player and a hat the game knocks off (the hat watch in `client/clothing/states.lua`). Skipped without `../w_lib` |
| Review regressions | `test_foundation_regressions.py`, `test_integration_final.py`, `test_verified_flow_gaps.py`, `test_final_gaps.py`, `test_review_server_r1.py`, `test_review_server_r2.py`, `test_review_server_r3.py`, `test_review_client_r1.py`, `test_review_client_r2.py`, `test_review_client_r3.py`, `test_review_shared_r1.py`, `test_review_nui_r1.py`, `test_review_nui_r2.py`, `test_review_ambulance_r1.py`, `test_review_ambulance_r2.py` | one test per confirmed finding of the review rounds (security, lifecycle, data, rollback fingerprint, docs consistency) |
| NUI | `web/tests/render.test.mjs`, `web/tests/treeState.test.mjs`, `web/tests/review_client_r3.test.mjs` | server-side React renders of every editor mode, the panel and the character card from `web/tests/fixtures/payloads.json`; navigation/request-state helpers; NUI review regressions |

### What the automated suites cannot prove

- **Natives** are stubs. The tests prove the call order, arguments and validation, not what the
  engine draws.
- **Database** is `FakeDB` (a scripted schema simulator), not MariaDB/MySQL through oxmysql.
- **Frameworks** are fakes (VORP / RSG / QBR / w_core users). The real login, registration,
  money and save behaviour of each framework is untested.
- **OneSync** scope, culling, routing buckets as the server applies them, and network ownership
  are simulated only.
- **NUI** is rendered with `react-dom/server` in Node, not in RedM's CEF: focus, keyboard, sounds,
  textures and fonts in game are untested.
- **Timing**: streaming, fades and ped readiness use a fake clock.

## 2. Live test matrix

### Setup for every live test

- A test server (never production) with OneSync on, the start order from `README.md`, and
  `Config.Debug = { enabled = true, domains = {} }`. `WCDebug.log` output shows in the server
  console and the client F8 console.
- Two clients, **A** and **B**, on different accounts. Give the tester the `Config.Admin.ace` ACE
  (`w_creators.admin`) for `wc_respawn`.
- Keep the database open to check rows: `characters_appearence` (`appearance`,
  `appearance_version`), `w_creators_clothes`, `w_creators_outfits`, `w_creators_migrations`.
- For every row, record the game build, the RedM server version, the framework, the date and the
  tester. Replace `NOT EXECUTED` with `PASS` or `FAIL <note>`.

### L1 — Multi-character

| # | Steps | Expected | Status |
|---|---|---|---|
| L1.1 | Connect A with an account that has no characters. | Selection room fades in (no black screen). Empty slots up to `Config.Characters.defaultSlots`. The prompt shows `RETURN` / `LEFT` / `RIGHT`. | NOT EXECUTED — requires a live RedM server |
| L1.2 | Create one male and one female character (L2). Disconnect, reconnect. | Both listed with name, age and last-location label. `LEFT`/`RIGHT` switches the preview. Only one preview ped at a time, with no flash between peds. | NOT EXECUTED — requires a live RedM server |
| L1.3 | Select character 1 (`RETURN`). | The framework logs it in. The ped matches the saved look before the fade-in. Spawn flow starts (L7). `WCore:Client:OnPlayerLoaded` fires once (w_core). | NOT EXECUTED — requires a live RedM server |
| L1.4 | In the world, `/characters`, select character 2. | Character 1 is cleared (`characterCleared` reason `switch`). Character 2 is logged in with its own look, money and job. No double login in the framework log. | NOT EXECUTED — requires a live RedM server |
| L1.5 | `/characters` while dead, while in a store editor, and with `Config.Characters.allowSwitch = false`. | Refused with a message each time. The player is not moved or isolated. | NOT EXECUTED — requires a live RedM server |
| L1.6 | Fill every slot, then try to create. | No empty slot offered. A forced `beginCreate` answers `CHARACTER_SLOT_LIMIT`. | NOT EXECUTED — requires a live RedM server |
| L1.7 | Delete a character: hold `DELETE` for `deletion.holdTime` ms. Repeat with `typedConfirmation = true` and a wrong name. | Hold: the character is gone from the list, the framework row is deleted, and its `characters_appearence`, `w_creators_clothes` and `w_creators_outfits` rows are removed. Wrong typed name: refused, nothing deleted. | NOT EXECUTED — requires a live RedM server |
| L1.8 | Press `RETURN` twice quickly on a character. | One login only (per-player lock). No duplicate spawn. | NOT EXECUTED — requires a live RedM server |

### L2 — Creator (male and female)

| # | Steps | Expected | Status |
|---|---|---|---|
| L2.1 | Empty slot → `RETURN`. Gender scene: `LEFT`, then the editor's root Back ("change the sex"), then `RIGHT`, back again, `BACK`. | The Saint Denis theatre stage: the man and the woman side by side, the camera on the pair, no passers-by. `LEFT` opens the man's editor at once where he stands (the woman hidden, the camera glides); Back returns to the pair without a question and without a re-render; `RIGHT` opens the woman with her own look and the name typed for the man; `BACK` asks first when a draft holds work, then returns to the selector. | NOT EXECUTED — requires a live RedM server |
| L2.2 | Walk through every stage: identity, body, face (every subsection), skin, hair, facialHair, makeup, clothing, review. Use the arrows, Enter and Escape, drag, the wheel, right click, and a click on the face or feet. | Each stage frames its camera preset. Every slider changes the preview ped at once and nothing else. Escape goes back one level; from the root it returns to the gender choice and keeps the look. Undo and restore work. | NOT EXECUTED — requires a live RedM server |
| L2.3 | Identity: a 1-letter name, a name with digits, a DOB outside `minAge`..`maxAge`. | `INVALID_NAME` / `INVALID_DOB` message. Cannot confirm. | NOT EXECUTED — requires a live RedM server |
| L2.4 | Randomise several times. | Only valid parts and moderate features. No masks or makeup added. | NOT EXECUTED — requires a live RedM server |
| L2.5 | Confirm the male character. | Registered in the framework. The player ped matches the preview (head, eyes, teeth, body, height, weight, 63 morph controls, overlays, clothing). DB: `appearance_version = 3`, starter clothing in `w_creators_clothes` with `source = 'starter'`. | NOT EXECUTED — requires a live RedM server |
| L2.6 | Repeat L2.1–L2.5 for female. | No facialHair stage. `skirts` offered. Same persistence checks. | NOT EXECUTED — requires a live RedM server |
| L2.7 | Cancel a creation at the review stage. Also disconnect in the middle of a creation. | Back to the selector (cancel) / nothing left behind (disconnect). No framework character is created. | NOT EXECUTED — requires a live RedM server |
| L2.8 | Reconnect and select each new character. | Look identical to the confirmed one. | NOT EXECUTED — requires a live RedM server |
| L2.9 | `Config.Creator.enableCutscene = true`, create a new character. | Wagon ride from `cutscene.start` to `cutscene.arrival`. The player is released at the arrival (or after `maxDuration`). Existing characters never get the ride. | NOT EXECUTED — requires a live RedM server |
| L2.10 | The stage in the theatre: look at the room, the lights and the floor. | The interior is loaded (no empty shell), both characters stand on the stage (not below it), the key / warm fill / red rim lights read well. If the room looks flat, set `Config.Scene.timecycle = 'Online_Character_Editor'`. | NOT EXECUTED — requires a live RedM server |
| L2.11 | Body › Build: every build; Face › Teeth; a depth slider (jaw depth, ear angle); the camera plate's "hide clothes". | Each build changes the body and survives a weight change; the teeth view opens the mouth and any other view closes it; a depth slider turns the character to its profile and a width slider back; the clothes, hair and beard come off and back. | NOT EXECUTED — requires a live RedM server |
| L2.12 | Makeup: every eyeliner / eyeshadow / lipstick style and the 2nd / 3rd colours; Skin › Scars with 3 extra scars; Eyebrows every style on the woman with "match the hair" on and off. | 16 / 6 / 7 distinct designs; the extra colours show; every scar shows; all 24 eyebrow styles show on the woman (8 used to draw nothing) and take the hair colour. | NOT EXECUTED — requires a live RedM server |
| L2.13 | Eyes › Custom eye tint on, move the three tints, save; reconnect. | The eye colour changes and stays after the save and on other clients. | NOT EXECUTED — requires a live RedM server |
| L2.14 | Body › Height: drag the slider end to end on the man and on the woman; set `Config.Creator.heightUnit = 'ft'` and look again. | The readout is the character's height in metres (feet), plausible for an adult, and it follows the drag. If it shows the bare ×100 number, `_GET_PED_HEIGHT` gave no usable answer: report it. | NOT EXECUTED — requires a live RedM server |

### L3 — Clothing per category

Procedure for each category below, for male and female where offered:

1. At a clothing store (e.g. `valentine_clothing`), press `J`.
2. Choose the category. Browse at least the first, a middle and the last model, and two variants.
3. Tint it where the category has palettes. Buy it, then reconnect.

Expected:

- The fitting-room teleport works and only the edited category changes on the ped.
- The price equals `Config.Clothing.prices[category]` × the location's pricing profile multiplier,
  plus `Config.Clothing.tints.price` when the tint differs.
- Confirming charges exactly that amount and adds a `w_creators_clothes` row. The item is still worn
  after a reconnect.
- Cancel restores the previous look, returns the player to the shop floor with the original
  heading, and charges nothing.
- No clipping worse than in the base game. Record any clipping.

| Group | Categories | Male | Female |
|---|---|---|---|
| head | `hats`, `masks`, `eyewear` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| neck | `neckwear`, `neckties` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| upper | `shirts_full`, `vests`, `coats`, `coats_closed`, `ponchos`, `cloaks`, `dresses`, `armor` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| arms | `gloves`, `gauntlets`, `jewelry_bracelets`, `jewelry_rings_left`, `jewelry_rings_right` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| lower | `pants`, `skirts` (female only), `chaps`, `legs_acessories` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| feet | `boots`, `spats`, `boot_accessories` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |
| accessories | `suspenders`, `belts`, `belt_buckles`, `gunbelts`, `gunbelt_accs`, `holsters_left`, `loadouts`, `satchels`, `badges`, `accessories` | NOT EXECUTED — requires a live RedM server | NOT EXECUTED — requires a live RedM server |

| # | Steps | Expected | Status |
|---|---|---|---|
| L3.1 | Rules: equip `coats` then `coats_closed`; `ponchos` then `cloaks`; `pants` then `skirts`; `dresses` with `pants`; `gunbelt_accs` without `gunbelts`; `belt_buckles` without `belts`. | The item equipped last wins in each conflict. An item that needs another one is not kept without it. | NOT EXECUTED — requires a live RedM server |
| L3.2 | Buy with too little money. | `INSUFFICIENT_FUNDS`. Look and money unchanged. | NOT EXECUTED — requires a live RedM server |
| L3.3 | Wardrobe (`valentine_wardrobe`): wear owned items, save an outfit, rename it, update it, delete it, fill up to `maxSavedOutfits`. | Only owned items and the worn set are offered. No money charged. `w_creators_outfits` rows follow each action. The limit gives `OUTFIT_LIMIT`. | NOT EXECUTED — requires a live RedM server |
| L3.4 | Die while a store editor is open. Separately, disconnect while the purchase confirms. | Editor closed and snapshot restored. Nothing is charged unless the commit completed. | NOT EXECUTED — requires a live RedM server |
| L3.5 | Set `enabled = false` on a store, and `Config.Services.clothingStores = false`. | No prompt, blip or NPC. `OpenClothingStore` answers `LOCATION_DISABLED` / `STORE_DISABLED`. | NOT EXECUTED — requires a live RedM server |
| L3.6 | Look at the map near the four stores and three wardrobes. | The tailor and wardrobe icons show (not a plain dot). | NOT EXECUTED — requires a live RedM server |
| L3.7 | At each of the four stores: the book on the counter, then open the store. | The catalogue prop stands on the book spot, facing the right way. The player leafs through it, then the fade; back at the counter the closing clip plays. Death or walking off during the reading only cuts the reading. If nothing plays, check `Config.Clothing.catalogue.scene.entity`. | NOT EXECUTED — requires a live RedM server |
| L3.8 | In a dim store, open the fitting room. | A white light in front of the player while the editor is open, none after. | NOT EXECUTED — requires a live RedM server |
| L3.9 | Set a model price, a gold price on a category and `payment.currencies = { 'cash', 'gold' }`. Buy with gold. | The Payment choice shows; the item shows its model price; gold is taken (not cash); a refund on failure returns gold. | NOT EXECUTED — requires a live RedM server |
| L3.10 | Buy a hat, dye it (colour A), buy it again in colour B, then switch between A and B in the store and in the wardrobe; save an outfit in B. | A second colour is charged once; switching back to an owned colour is free; the wardrobe offers the original, A and B; the outfit wears B. | NOT EXECUTED — requires a live RedM server |
| L3.11 | Sell back a bought, not-worn hat; try a starting piece, a worn item and an item in an outfit. | 33 % of the paid price comes back; the others are refused with their message. | NOT EXECUTED — requires a live RedM server |
| L3.12 | Put on a saved outfit and a tailor's suggestion in a store; buy with "save this look as an outfit". | Owned pieces free, others priced; the new outfit appears in the wardrobe. | NOT EXECUTED — requires a live RedM server |
| L3.13 | The rings / bracelets / gloves views; take off everything; `/hat`, `/tuck`, `/loadout`. | The camera frames the hand that wears the item; everything comes off (the body stays); the commands flip their state. | NOT EXECUTED — requires a live RedM server |
| L3.14 | `Config.Clothing.items.enabled = true` with the two items in the inventory: wrap a garment, give it to another player, use it; share an outfit card and use it at a store. | The garment leaves and arrives once; the card opens the store with the look tried on. | NOT EXECUTED — requires a live RedM server |

### L4 — Clothing states per action

Procedure for each group:

1. Wear an item of the listed category.
2. Open `/clothing` (or the `wc_clothing_actions` keybind) and perform each action.
3. Repeat the action through the export, e.g. `exports.w_creators:ToggleHat()`, from a test
   resource thread.
4. Watch from client B.

Expected:

- The visual change happens on A and on B.
- The item stays owned and equipped: the wardrobe still lists it, and `GetEquippedCategory` still
  returns its hash.
- The panel refreshes.
- `persist = true` values survive a reconnect. `bandana` (`persist = false`) is reset on reconnect.

| Group | Category | Actions | Persist | Status |
|---|---|---|---|---|
| `hat` | `hats` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `eyewear` | `eyewear` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `mask` | `masks` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `bandana` | `neckwear` | down / up | no | NOT EXECUTED — requires a live RedM server |
| `sleeves` | `shirts_full` | down / rolled | yes | NOT EXECUTED — requires a live RedM server |
| `collar` | `shirts_full` | closed / open | yes | NOT EXECUTED — requires a live RedM server |
| `coat` | `coats`, `coats_closed` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `vest` | `vests` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `poncho` | `ponchos`, `cloaks` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `gloves` | `gloves` | on / off | yes | NOT EXECUTED — requires a live RedM server |
| `boots` | `boots` (needs `pants`) | over / under | yes | NOT EXECUTED — requires a live RedM server |

| # | Steps | Expected | Status |
|---|---|---|---|
| L4.1 | Try an action while dead, ragdolled and in combat, and (with `Config.Experimental.clothingAnimations = true`) while mounted. | `STATE_NOT_APPLICABLE`. Nothing changes. | NOT EXECUTED — requires a live RedM server |
| L4.2 | `RemoveClothingCategory('cloaks')` while wearing a poncho. | `STATE_NOT_APPLICABLE` (`reason = 'category'`). The poncho stays visible. | NOT EXECUTED — requires a live RedM server |
| L4.3 | With `Config.Experimental.clothingAnimations = true`, run each group that has an animation (`hat`, `mask`, `bandana`, `sleeves`, `gloves`). Interrupt one before its midpoint. | The clip plays, and the state changes at the midpoint. Interrupted before it: unchanged. A missing clip is skipped and the state still changes. | NOT EXECUTED — requires a live RedM server |

### L5 — Barber

| # | Steps | Expected | Status |
|---|---|---|---|
| L5.1 | At `valentine_barber`, `J`. Male: change the hair, then the beard, then the eyebrows. | Editor sections `hair`, `facialHair` and `eyebrows` (makeup only if `services.details.makeup`). The camera frames the hair. | NOT EXECUTED — requires a live RedM server |
| L5.2 | Confirm a visit that changes hair and beard with the default prices. | Charged 10 (`hair` 10 + `facialHair` 10, capped by `prices.visitCap = 10`). Look saved. | NOT EXECUTED — requires a live RedM server |
| L5.3 | Cancel a visit. | Previous hair and beard restored. Nothing charged. | NOT EXECUTED — requires a live RedM server |
| L5.4 | Female character. | No facialHair section. The hair styles are the female list. | NOT EXECUTED — requires a live RedM server |
| L5.5 | Growth: set `Config.Grooming.minutesPerStage = { hair = 1, beard = 1 }` and `saveIntervalSeconds = 30` (the minimum), then restart. Play several minutes in the main world. Then shave only the beard at a barber. **Restore the config afterwards.** | Hair and beard move through `stages` one per minute and keep the colour. Growth pauses in the selector, editors and a non-zero bucket. Shaving resets only the beard. Growth survives a reconnect. | NOT EXECUTED — requires a live RedM server |

### L6 — Cosmetic surgery

| # | Steps | Expected | Status |
|---|---|---|---|
| L6.1 | With w_ambulancejob started, go to its Valentine clinic prompt (`Config.CosmeticSurgery.clinics`) and use it. | w_ambulancejob's server calls `OpenCosmeticSurgery`. The editor opens with the `face`, `body`, `eyes` and `skin` sections only (`Config.CosmeticSurgery.allow`). | NOT EXECUTED — requires a live RedM server |
| L6.2 | Change the face and body, then confirm. | Charged `Config.CosmeticSurgery.price` (500). Look saved and seen by B. Hair and clothing unchanged. | NOT EXECUTED — requires a live RedM server |
| L6.3 | Cancel. Die during the procedure. | Snapshot restored. Nothing charged. | NOT EXECUTED — requires a live RedM server |
| L6.4 | From A's F8 or a test resource, run `exports.w_creators:OpenCosmeticSurgery('valentine_surgery')` (client export) without going through w_ambulancejob. | `SURGERY_NOT_ALLOWED`: a `prompt = false` clinic needs the server grant. | NOT EXECUTED — requires a live RedM server |
| L6.5 | Use the clinic prompt while downed, and with `Config.Services.surgery = false`. | w_ambulancejob shows its `error.surgery_unavailable` message. Nothing opens. | NOT EXECUTED — requires a live RedM server |

### L7 — Spawn and respawn

| # | Steps | Expected | Status |
|---|---|---|---|
| L7.1 | Select an existing character with `spawnSelector` on. | Selector shows "last location" first and preselected (when `lastLocation` is on), then the enabled points in `order`. The aerial camera orbits and each town streams in before it is shown. | NOT EXECUTED — requires a live RedM server |
| L7.2 | Spawn at every point. | The player lands on the ground: no fall through the map, no floating. The screen fades in and controls work. Bucket 0: A and B see each other. | NOT EXECUTED — requires a live RedM server |
| L7.3 | Set `enabled = false` on `rhodes`. | Not listed. A forced `spawn:choose('rhodes')` gives `INVALID_SPAWN`. | NOT EXECUTED — requires a live RedM server |
| L7.4 | `Config.Services.spawnSelector = false`. Log in a new and an existing character. | New: `Config.Spawn.firstSpawn`. Existing: the validated last location, or the first enabled point when it is outside `Config.Spawn.bounds` or near the creator room. | NOT EXECUTED — requires a live RedM server |
| L7.5 | `wc_respawn <A's citizen id> valentine` in the console (and `#<A's server id>`), then as a player without the ACE. | A is moved (`client:respawn`, kind `admin`) and `OnPlayerLoaded` does not fire again. Without the ACE: refused and logged. An offline citizen id: `PLAYER_OFFLINE`. | NOT EXECUTED — requires a live RedM server |
| L7.6 | Die with w_ambulancejob. Respawn at the hospital. Also get revived by a medic. | `Resurrect(…, 'hospital')` resurrects. The saved appearance (clothing, hair, overlays) is back on the new ped. No weapon or inventory changes. | NOT EXECUTED — requires a live RedM server |
| L7.7 | Die with w_ambulancejob stopped, and get resurrected by another script. | The watcher restores the appearance once after the external resurrect. | NOT EXECUTED — requires a live RedM server |

### L8 — Resource restart

| # | Steps | Expected | Status |
|---|---|---|---|
| L8.1 | A in the world: `restart w_creators`. | A keeps position and look. The character is adopted (`characterActivated`). `/clothing`, stores and `/reloadappearance` work. `/characters` is allowed for 2 minutes even with `allowSwitch = false`. | NOT EXECUTED — requires a live RedM server |
| L8.2 | A in the selector, then in the creator: restart. | No frozen player, black screen or hidden HUD. A is not left in a private bucket. The selector reopens. | NOT EXECUTED — requires a live RedM server |
| L8.3 | A in a store fitting room with unsaved changes: restart. | Session closed. Look restored to the saved one, player back in bucket 0, nothing charged. | NOT EXECUTED — requires a live RedM server |
| L8.4 | A mid-growth (L5.5 settings): restart. | At most the growth since the last save is lost. No error. | NOT EXECUTED — requires a live RedM server |
| L8.5 | Fresh database: start. Pre-v3 database dump: start. | `w_creators_migrations` holds `001_base_tables`…`006_colorways` (every dye owned so far is now an owned colour in `w_creators_colorways`). The pre-v3 characters load and are upgraded lazily; `wc_migrate_appearances` reports the scanned and upgraded counts. | NOT EXECUTED — requires a live RedM server |

### L9 — Two-client OneSync sync

| # | Steps | Expected | Status |
|---|---|---|---|
| L9.1 | A and B far apart (out of scope). A buys clothing and visits the barber. B walks to A. | When A enters B's scope, B sees A's current look (applied once per ped handle). | NOT EXECUTED — requires a live RedM server |
| L9.2 | A and B together. A toggles the hat, bandana and sleeves. | B sees each change within about a second, with no full re-render flash. | NOT EXECUTED — requires a live RedM server |
| L9.3 | A dies and respawns, then A switches character. | B sees A's look after the resurrect, then the new character's look (`forgetRemote` + new broadcast). | NOT EXECUTED — requires a live RedM server |
| L9.4 | A third client C joins late next to A. | C sees A's look (`requestAppearances`). | NOT EXECUTED — requires a live RedM server |
| L9.5 | A is in a store fitting room (isolated) while B stands at the store. | B does not see A's unsaved preview. After the confirm, B sees the bought item. | NOT EXECUTED — requires a live RedM server |

## 3. Verifying an experimental native

Experimental wrappers (`docs/NATIVES.md`) are off by default, and no production path calls them.
To verify one:

1. **Use a test server only.** Set `Config.Debug = { enabled = true, domains = { natives = true } }`
   so every wrapper failure is logged by `WCDebug.log('natives', …)`.
2. **Turn on only its gate** and restart the resource:
   - `Config.Experimental.metapedRequestPath` for `WCNative.metaped.requestPed`, `isRequestLoaded`,
     `isRequestValid`, `createPed` and `release`.
   - `Config.Experimental.hatAccess` for `WCNative.clothing.setHatAccess`.
   - `Config.Experimental.variationPreset` for `WCNative.metaped.setVariationPreset`.
   - `Config.Experimental.clothingAnimations` for the clothing-state clips.
   - `Config.Admin.devTools` for `WCNative.metaped.numCategories` / `categoryAt`.
3. **Exercise it.**
   - Category discovery: `wc_inspect`, which needs `Config.Admin.devAce`. It prints the ped's
     categories to F8.
   - Clothing animations: L4.3.
   - The others have no command. Call the wrapper from a temporary client file in a local copy of
     the resource that is never shipped, for example
     `WCNative.clothing.setHatAccess(PlayerId(), false, 0)` or
     `WCNative.metaped.requestPed(GetHashKey('mp_male'), 5000)`.
   - Afterwards, check the return value, F8 for `natives` log lines, and the ped on both clients.
   - For the request lifecycle, confirm that every handle is released: `release` is idempotent,
     and `onResourceStop` releases the handles still open.
4. **Repeat** on `mp_male` and `mp_female`, on two clients (OneSync), and across a resource
   restart. Record the game build.
5. **Record** the result in the wrapper's doc block and in `docs/NATIVES.md`: tested models, MP safe,
   OneSync tested here. Only then may its confidence move from **Experimental** to **Likely** (or to
   **Verified** after production use). Keep the gate `false` by default until a reviewer accepts the
   change, and update `tests/test_natives.py` if the gating changes.
6. Turn the gate and `Config.Debug` off again.

`_NETWORK_RESURRECT_LOCAL_PLAYER_2` is not wrapped and must not be added without a verified struct
layout (`docs/NATIVES.md`).
