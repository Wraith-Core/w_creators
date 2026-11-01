# Clothing

Operator reference for clothing: the catalogue, the taxonomy, prices, store profiles, tints,
compatibility rules, the store transaction, ownership, the wardrobe and outfits, starting clothing, and
how to add a store. The main files are:

- `config/clothing.lua`, `config/outfits.lua`, `config/wardrobe.lua`, `config/locations.lua`
- `shared/catalog.lua` (`WCCatalog`), `shared/rules.lua` (`WCRules`)
- `server/clothing/store.lua` (`WCClothingStore`), `server/clothing/ownership.lua` (`WCOwnership`)
- `server/wardrobe/wardrobe.lua` (`WCWardrobeService`), `server/wardrobe/outfits.lua` (`WCOutfits`)

Clothing states (hat off, sleeves rolled…) are covered in [CLOTHING_STATES.md](CLOTHING_STATES.md).
The appearance shape is covered in [APPEARANCE.md](APPEARANCE.md).

> **Test status.** Everything below comes from reading the code and the automated tests. Nothing was
> run on a live RedM server. Whether an item renders correctly on the ped, or how a tint and palette
> look, **requires live verification**.

---

## 1. Catalogue source

The item catalogue is not copied into this resource. It comes from w_lib:
`w.component.getFullPedComponentList()`, indexed by `WCCatalog`.

- **Indexing.** `WCCatalog.forSex(sex)[category] = { models = { [m] = { {hash, name}... } }, hashes =
  { [hash] = {model, variant, name} } }`. Hashes are unsigned 32-bit. Model numbers `m` skip empty
  catalogue groups (the pre-v3 numbering), so legacy `{ model, variant }` data still resolves.
- **Build.** Built lazily, once per sex, and never rebuilt per click. Nothing is cached while w_lib
  returns no catalogue.
- **Body parts.** `heads, eyes, teeth, BODIES_UPPER, BODIES_LOWER, hair, mustache` are
  `WCCatalog.BODY_PARTS`, never clothing. The first five are essential and cannot be removed
  (`Config.Clothing.essentialNotRemovable`).
- **Clothing categories.** A category is clothing (`WCCatalog.isClothing`) when it is not a body part
  and appears in the taxonomy or the catalogue.
- **Offer rule.** A category is offered to a sex (`WCCatalog.offered`) when the taxonomy's optional
  `sex` allows it **and** the catalogue has items of that category for the sex. The server enforces
  this.

---

## 2. Taxonomy (as configured)

`Config.Clothing.taxonomy`: ordered groups, each an ordered list of subcategories. Each subcategory owns
exactly one catalogue category. Node ids equal the category names.

```
Head (head)                  camera head
  hats            Hats                     camera head       art hat
  masks           Masks                    camera face       art mask
  eyewear         Eyewear                  camera face
Neck (neck)                  camera upperBody
  neckwear        Neckerchiefs/bandanas    camera upperBody
  neckties        Ties                     camera upperBody
Upper body (upper)           camera upperBody
  shirts_full     Shirts                   camera upperBody  art shirt
  vests           Vests                    camera upperBody  art vest
  coats           Coats                    camera upperBody  art coat
  coats_closed    Closed coats             camera upperBody  art ccoat
  ponchos         Ponchos                  camera upperBody
  cloaks          Cloaks                   camera upperBody
  dresses         Dresses & gowns          camera fullBody
  armor           Armour                   camera upperBody
Arms & hands (arms)          camera hands
  gloves          Gloves                   camera handRight  art gloves
  gauntlets       Gauntlets                camera handRight
  jewelry_bracelets    Bracelets           camera handLeft
  jewelry_rings_left   Rings (left)        camera handLeft
  jewelry_rings_right  Rings (right)       camera handRight
Lower body (lower)           camera lowerBody
  pants           Pants                    camera lowerBody
  skirts          Skirts        sex=female camera lowerBody
  chaps           Chaps                    camera lowerBody
  legs_acessories Leg accessories          camera lowerBody
Feet (feet)                  camera feet
  boots           Boots                    camera feet       art boots
  spats           Spats                    camera feet
  boot_accessories Boot accessories        camera feet
Accessories (accessories)    camera accessories
  suspenders      Suspenders               camera upperBody
  belts           Belts                    camera upperBody
  belt_buckles    Buckles                  camera accessories
  gunbelts        Gun belts                camera accessories art gunbelt
  gunbelt_accs    Gun belt accessories     camera accessories
  holsters_left   Left holster             camera accessories
  loadouts        Loadouts                 camera upperBody
  satchels        Satchels                 camera upperBody
  badges          Badges                   camera upperBody
  accessories     Other accessories        camera fullBody
```

- `legs_acessories` is spelled as the catalogue category.
- `label` values are dictionary keys (Arabic source text, translated by `locales/en.json`).
- A subcategory is shown only when the catalogue has items for the character's sex. In a store, it
  also needs at least one item the store profile sells (`WCCatalog.available`, which includes having a
  price) or the item worn now.
- Groups and subcategories sort by `order`, then by config position.
- The wardrobe adds a group for saved outfits. The creator (free mode) adds an **Outfits** group with the
  starting presets (§10).

---

## 3. Prices and pricing profiles

`Config.Clothing.prices` holds the base price per category. The server is authoritative, and no price is
ever read from a client payload. A missing category or a negative price means **not for sale**. As
configured:

| Price | Categories |
|---|---|
| 20 | armor |
| 10 | masks, satchels |
| 6.7 | loadouts |
| 6 | eyewear |
| 5 | shirts_full, vests, coats, coats_closed, cloaks, gunbelts, pants, skirts, dresses, spats, boots |
| 4.25 | ponchos, gloves |
| 4 | chaps |
| 3.55 | boot_accessories |
| 3.5 | hats |
| 3.12 | holsters_left |
| 3 | gauntlets, legs_acessories |
| 2.15 | neckwear |
| 2 | neckties, belts, badges, accessories, jewelry_bracelets |
| 1.5 | suspenders |
| 1.25 | jewelry_rings_left, jewelry_rings_right |
| 1 | belt_buckles, gunbelt_accs |

`Config.Clothing.pricingProfiles[id] = { multiplier }`. The item price is `WCCatalog.price(category,
hash, profile)` = base × multiplier, rounded to cents. Configured profile: `standard = { multiplier = 1.0 }`.
A location picks one with `pricingProfile` (default `standard`).

- An **unknown profile id**, or a negative or non-finite multiplier, makes every item of that store
  unpriced. The store's `prices` map comes back empty, and every purchase is refused with
  `COMPONENT_NOT_AVAILABLE`.
- `WCCatalog.available` checks that the item has a price under the `standard` profile. **Keep
  `standard` defined** even when your stores use other profiles.

### 3.1 Per-model prices

`Config.Clothing.modelPrices[sex][category][model]` overrides the category price for one catalogue
model (the store's "<category> NN" style number):

| Value | Meaning |
|---|---|
| `-1` | not sold: the model is hidden in stores and a purchase is refused (`COMPONENT_NOT_AVAILABLE`) |
| `9` or `{ cash = 9, gold = 0.4 }` | the model's own price |
| `{ multiplier = 1.25 }` | the category price × 1.25 |

The pricing profile's multiplier applies after it. `WCCatalog.price(category, hash, profile, sex)`
(and `priceSpecOf`, every currency) is the one rule; the editor shows the model's own price on the item
(`WCEditorTree.itemPrice`, display only). Configured: empty (every model at its category price).

### 3.2 Currencies: cash and gold

A price is a number (cash) or a table naming its currencies: `{ cash = 5 }`, `{ gold = 0.25 }`, or
`{ cash = 5, gold = 0.25 }` (either one). The same shapes work in `modelPrices` and for
`tints.price`. `Config.Clothing.payment.currencies = { 'cash', 'gold' }` lists what stores take, in
the order of the store's **Payment** choice.

- The store's open data lists `currencies` (cash, and gold when something on sale is priced in gold)
  and `priceSpecs` (`{ [category] = { cash?, gold? } }`). With more than one currency the editor shows
  the **Payment** choice at the top of the store; it changes no garment.
- The commit carries `{ currency }`. The server works the total out in that currency
  (`WCClothingStore.plan(saved, app, owned, loc, currency)`); an item or a colour without a price in it
  is refused before any charge (`CURRENCY_NOT_ACCEPTED`), and so is a currency the store does not take.
  In the editor such an item blocks the save with its name (`payload.saveBlocked`).
- `WCEconomy.charge / refund / withCharge` take the currency: cash is the framework's money type `0`,
  gold `1` (w_lib's bridge, every supported core). A refund returns the same currency.
- Items are never a payment here.

---

## 4. Store profiles

`Config.Clothing.storeProfiles[id] = { include = '*' | {categories}, exclude = {categories}, models = {
[category] = { min, max } } }`. A location picks one with `storeProfile` (default `general`).

| Profile | Contents |
|---|---|
| `general` | `include = '*'`: every priced category offered to the sex |
| `premium` | example, **not assigned to any location**: hats, neckties, shirts_full, vests, coats, coats_closed, pants, skirts, dresses, gloves, boots, jewelry (bracelets, rings left/right). Hats limited to catalogue models 1–60 |

An item is sold (`WCCatalog.available(profile, sex, category, hash)`) only when all of these hold:

- the profile exists;
- the category is offered to the sex;
- the category is included and not excluded;
- the item's model is inside the `models` range (if one is set);
- the model is not listed in the profile's `restricted[category]` (e.g. a uniform only a job's own
  store sells: that store gets a location `access` rule and a profile without the restriction);
- the item has a price in at least one currency (a model priced `-1` has none).

An unknown `storeProfile` sells nothing.

---

## 5. Tints

`Config.Clothing.tints`:

| Key | Configured | Meaning |
|---|---|---|
| `enabled` | `true` | governs **new** tints only (see below) |
| `price` | `2.5` | charged for each colour of an item the character does not own yet (a number or `{ cash, gold }`) |
| `default` | `metaped_tint_generic_clean`, `metaped_tint_leather`, `metaped_tint_hair`, `metaped_tint_horse_leather`, `metaped_tint_makeup`, `metaped_tint_horse` | palettes of a category without its own list |
| `limits` | `{}` | per palette `{ min, max, disabled = { indices } }`: the tint sliders' bounds; an index outside them or disabled is refused (`WCCatalog.validTint`) and the slider steps over it |
| `swatches` | `true` | the tint sliders draw the palette's colours as their track, from `web/build/tex/palettes/<palette>.png` (see below) |
| `palettes.hats` | `metaped_tint_hat`, `metaped_tint_hat_clean`, `metaped_tint_generic_clean` | |
| `palettes.<leather>` | `metaped_tint_leather`, `metaped_tint_horse_leather`, `metaped_tint_generic_clean` | boots, gloves, gauntlets, belts, gunbelts, gunbelt_accs, holsters_left, satchels, loadouts, chaps, spats, boot_accessories |
| `palettes.skirts` | `metaped_tint_skirt_clean`, `metaped_tint_generic_clean` | |
| `palettes.<x> = false` | — | not tintable: jewelry_bracelets, jewelry_rings_left, jewelry_rings_right, badges |
| `labels` | palette → dictionary key | display names |

- A tint is `{ palette, tint0, tint1, tint2 }` with integers `0..254`. Only palette names that exist in
  w_lib's `w.component.data.palettes` are valid.
- **New tints** are checked against the live config by `WCCatalog.validTint`: `enabled`, then the
  category's palette list. This covers the store plan, `SetClothes`, owned tints, the editor, and a
  changed tint in `mergeSections`.
- **Stored tints** (saved appearance, owned rows) are checked only structurally
  (`WCCatalog.validStoredTint`). Disabling tints or narrowing a palette list never erases a saved dye.
  The renderer simply does not draw a tint the config forbids, and draws it again once the config
  allows it.
- **Store pricing.** Only what the player changed is priced:
  - An item worn as saved **with its saved tint** is free, and its owned row is not rewritten.
  - A changed tint costs `tints.price` when it differs from the baseline. The baseline is the item's
    owned tint, or its saved tint for the saved worn item that has no owned tint.
  - Going back to the baseline is free.
  - The editor preview (`WCEditorTree.price`) uses the same rule, for display only.
- The **wardrobe cannot dye**. It wears an item in its original colour or in one of the colours the
  character owns of it (colourways, below); an unowned colour falls back to the owned one.

### 5.1 Colourways: several owned colours of one garment

`w_creators_colorways(charid, hash, palette, tint0..2, price_paid, currency, acquired_at)`, unique on
`(charid, hash, palette, tint0, tint1, tint2)` (migration `006_colorways`), holds every colour a
character owns of each garment. The palette columns of `w_creators_clothes` stay the colour the item was
**last worn** in, so the older readers keep working. The migration copies every dye owned so far into
the new table (`INSERT IGNORE`: idempotent).

- `WCOwnership.list` adds `colors` to each owned row; `colorsOf(owned, hash)` (the last worn first) and
  `ownsColor(owned, hash, tint)` answer from it. The original colour is always owned with the item.
- **Store.** A colour the character owns of the item is **free** (it only becomes the colour the item
  is worn in); a colour it does not own yet costs `tints.price` and becomes owned (a colour row, and the
  last-worn colour). The editor lists the owned colours above the palette (control
  `clothing.<category>.owned`) so picking one sets palette and tints at no cost.
- **Wardrobe.** The item panel has a **Colour** choice (`clothing.<category>.colorway`): the original,
  then each owned colour. `false` in `app.clothing.tints` is the explicit original colour; no tint keeps
  the owned one (`WCOwnership.wornTint(saved, owned, category, hash, submitted)`).
- **Outfits** store each item's colour (`data.tints[category]` = a tint, or `false` for the original).
  Only owned colours of owned items are accepted (`INVALID_TINT`); an unowned worn item only in its
  saved colour. An outfit saved before colourways has no `tints` and wears the owned colours.
- The surgery clinic's clothing keeps the owned (last-worn) colour.
- Every grant with a tint also owns the colour (`WCOwnership.grantQueries`), the rows after the items.
- The purge deletes the colour rows with the character; the table is in w_core's citizen-id registry.

### 5.2 Palette swatches

A tint slider node carries `track = 'tex/palettes/<palette>.png'` (only that shape is used). The NUI
draws that strip as the slider's track and a chip of the chosen tint's colour, read from the strip
(tint `i` is the middle of cell `i` of the whole 0..254 palette). A slider narrowed by the palette's
`limits` shows only its `min..max` cells of the strip (`stripWindow`, web/src/treeState.js), so the
track and the chip stay the colours the tint really picks. A palette without a strip keeps the plain
slider. **Owner action:** the strips are not shipped: export them from the game's own palette
textures (`metaped_tint_*`) into `web/public/tex/palettes/<palette>.png` (one row of colours, tint 0 on
the left, 255 wide), then rebuild the NUI.

---

## 6. Compatibility rules and apply order

`Config.Clothing.rules` (`WCRules`):

| Rule | Configured |
|---|---|
| `conflicts` (symmetric) | coats ↔ coats_closed · ponchos ↔ cloaks · pants ↔ skirts · dresses ↔ pants · dresses ↔ skirts |
| `requires` (at least one of) | gunbelt_accs → gunbelts · belt_buckles → belts · boot_accessories → boots |

- `WCRules.equip(equipped, category, hash)`: the new item wins over the items it conflicts with.
  Dependants left without their requirement are removed, and an item whose own requirement is missing
  is not equipped. It returns the removed categories.
- `WCRules.normalize(equipped)` is deterministic. A category that conflicts with one kept earlier in
  `applyOrder` is dropped, then unmet requirements are dropped until the set is stable.
- The rules apply where the player **edits**: editors, store and wardrobe plans, `SetClothes`, outfit
  validation, and creation. Stored data is read and written as stored, so a rule change never silently
  drops saved clothing.
- The server rejects a change that breaks a rule with `CONFLICTING_ITEMS`. Removing an essential
  category fails with `INVALID_COMPONENT` (`WCOwnership.checkRules`).

`Config.Clothing.applyOrder` is the render order and the rule tie-break, from the innermost layer out:

```
BODIES_LOWER BODIES_UPPER heads eyes teeth hair mustache
pants skirts dresses shirts_full boots spats chaps legs_acessories boot_accessories vests suspenders
neckwear neckties coats coats_closed ponchos cloaks armor gloves gauntlets jewelry_bracelets
jewelry_rings_left jewelry_rings_right belts belt_buckles gunbelts gunbelt_accs holsters_left
loadouts satchels badges accessories eyewear masks hats
```

A category that is not listed is applied after the listed ones, sorted by name. The visual layering
**requires live verification** per item combination.

---

## 7. Store transaction

Callbacks: `w_creators:store:open(locationId)`, `w_creators:store:commit(token, opId, app, extra?)`,
`w_creators:store:resell(token, hash)` and `w_creators:session:close(token)`. Client flow:
`client/clothing/store.lua` through `WCServiceFlow`. `extra = { currency?, outfitName? }`.

### 7.1 Open

`WCSessions.open(src, 'store', ...)` checks the following:

- **Service.** `clothingStores` must be on (`*_DISABLED`).
- **Limits.** Rate limit of 5 per 10 s.
- **Character.** An active character is required (`NO_CHARACTER`).
- **Busy.** Refused with `BUSY` when another session is open or a commit is in flight.
- **Location.** The location must exist and be a `clothing` location (`LOCATION_NOT_FOUND`), enabled
  (`LOCATION_DISABLED`) and open (`LOCATION_CLOSED_HOURS`).
- **Distance.** Within `interactionRadius + 3` m of `coords` or `preview` (`TOO_FAR`).
- **Access.** A location with an `access` rule (§12) is refused to anyone it does not admit
  (`ACCESS_DENIED`).

Then:

- A **degraded** appearance is refused (`INTERNAL_ERROR`).
- The owned list is read (`DATABASE_ERROR`).

The result is `{ token, appearance, owned, prices, priceSpecs, currencies, tintPrice, tintPrices,
storeProfile, pricingProfile, preview, outfits, outfitsEnabled, maxOutfits, resell, expiresIn }`. The
session lasts 1800 s. `outfits` is the character's saved outfits (read only, §13) when the location's
`outfits` is on (default) and the `savedOutfits` service is.

### 7.2 Preview (client)

1. At a store with a catalogue `book` the player first reads the book (§12), then the client calls
   `w_creators:scene:prepare` (private routing bucket), fades out and moves the player to the
   location's `preview` stand. The fitting-room light is drawn while the editor is open.
   - The reading scene holds the player at the counter: it lets him go first (`WCCatalogue.release`),
     his tasks are cleared and the move waits `WCServiceFlow.RELEASE_MS` (100 ms). Under the fade the
     move is checked `STAND_CHECKS` times, `STAND_CHECK_MS` apart, and made again when the scene's
     release undid it; the editor's camera open checks once more (`anchorCamera`). A player left at
     the counter was framed from the far side of it, behind the tailor, whose back filled the screen.
   - The camera frames him from the stand's heading with the Jump On store's ped-relative framings
     (`WCCamera.SETS.shop`: full body 2.0 m / fov 60, body 1.5 m / 45, pants 2.0 m / 40, boots
     1.5 m / 30 seen a little from the side, the head and each hand on their bones). The wardrobe
     does the same from where the player stands. The screen fades back in only once the editor and
     its camera are up, so the game's own camera behind the player is never shown in between.
2. `WCEditor` opens in `store` mode, section `clothing` only.
3. Try-ons are drawn locally with `Appearance.ApplyDiff`. The price shown is the editor's estimate.
4. Cancel, death, or a server-forced close (`w_creators:client:sessionClosed`) restores the snapshot,
   closes the session and leaves the fitting room.

### 7.3 Commit (`WCClothingStore.commit`), in order

1. Rate limit 6 per 10 s (`RATE_LIMITED`). The token must be at most 128 characters and the payload at
   most 64 KB (`INVALID_PAYLOAD`).
2. `WCSessions.commit`:
   - `opId` is at most 64 characters. The replay cache lasts 120 s, so the same `opId` returns the
     recorded answer.
   - The token must be a store session (`SESSION_NOT_FOUND`), not busy (`BUSY`), and the player must
     still be in range (`TOO_FAR`).
   - The character appearance lock is taken.
3. The `clothingStores` service must still be on, and the location still enabled (`LOCATION_DISABLED`)
   and open (`LOCATION_CLOSED_HOURS`).
4. The saved appearance and the owned list are read again. A degraded appearance fails with
   `INTERNAL_ERROR`.
5. `WCClothingStore.plan` uses only the **clothing** section of the submission:
   - `clothing.equipped` must be a table (`INVALID_PAYLOAD`). A missing map is never read as "remove
     everything".
   - Every entry must be an item of that category for the sex (`INVALID_COMPONENT`). An essential
     category cannot be removed.
   - The rules must hold for every changed category (`CONFLICTING_ITEMS`).
   - A new or changed tint must satisfy the live tint config (`INVALID_TINT`). The unchanged saved dye
     is kept as stored, and so is an owned item's own dye (`WCOwnership.tintOf`, re-wearing it): that
     item is free and its owned row is not rewritten, even when tints are disabled or its palette is no
     longer offered (`mergeSections` keeps it through `opts.storedTints`; the wardrobe does the same).
     No tint (absent or `false`) is the item's original colour: an owned dye is reset only by that
     choice, never because a submitted dye was dropped (that is `INVALID_TINT`).
   - Every item that is **not owned** and was changed in any way, a dye of a worn but unowned uniform
     included, is a purchase. It must be sold by the store profile and priced by the pricing profile
     (`COMPONENT_NOT_AVAILABLE`).
   - The total is computed on the server (`INVALID_PRICE` if it is not finite).
   - The clothing states are settled: a swapped or removed item loses its state (a swapped item starts
     visible).
   - A plan with no clothing change fails with `NO_CHANGES`.
6. `WCEconomy.withCharge(src, total, 'clothing', …)`:
   - Cash is charged **first** (`INSUFFICIENT_FUNDS`; a zero total never touches the framework).
   - Then one transaction runs: the appearance save plus the ownership grants (source `store`).
   - If the transaction fails, the charge is **refunded**, and the failure carries `data.refunded`. A
     failed refund is logged as `refund_failed`.
7. On success:
   - The look is broadcast (`WCSync.broadcast`).
   - `clothing_purchased` is logged per item, then `appearance_changed`.
   - The server event `w_creators:server:appearanceChanged(src, charid, 'store')` fires.

The result is `{ appearance, charged, currency, purchases = [{ category, hash, price, tint, dyed }],
outfit? }`.

**Buy and save as outfit.** `extra.outfitName` saves the committed look as an outfit in the **same
transaction** as the purchase (`WCOutfits.insertQuery`): one charge, one save. It is checked before any
charge, under the character's outfit lock: the store offers outfits and `savedOutfits` is on
(`OUTFITS_DISABLED`), the name (`INVALID_OUTFIT_NAME`), the limit (`OUTFIT_LIMIT`), the contents as
they will be once the purchase is granted (each item owned or bought now, each colour owned or bought
now). A look with nothing bought can still be saved as an outfit. The save confirmation shows the name
field while the character is under the limit (`payload.saveOutfit`).

**Grants.** A new item without a tint is a plain grant (`INSERT IGNORE`, keeps an existing row). A dye
sets the owned tint and owns the colour. Resetting to the original colour clears the owned tint. A
purchase records what the item cost and its currency (`price_paid`, `currency`, migration
`005_clothes_paid`): only such an item can be sold back (§14). The clothes the player
arrived in are **not** granted. Clothing applied by another resource, such as a job uniform through
`SetClothes`, never becomes owned.

> Note: `ARCHITECTURE.md` §5.6 still says the store commit grants the clothes the player arrived in as
> `legacy`. The code (`server/clothing/store.lua`, `commitStore`) does not: pre-v3 outfits receive their
> `legacy` grants at the lazy upgrade instead (see [APPEARANCE.md](APPEARANCE.md) §2.3).

---

## 8. Owned, equipped and runtime state

| Concept | Where | Written by |
|---|---|---|
| **Owned** item | `w_creators_clothes(charid, hash, category, palette, tint0..2, source, acquired_at, price_paid, currency)`, unique `(charid, hash)` | store (`store`), creation (`starter`), lazy upgrade (`legacy`), `WCOwnership.grant` (default `admin`), an unwrapped garment item (`gift`). The wardrobe **never** writes ownership (except its optional resell / wrap, which remove it) |
| **Owned colour** | `w_creators_colorways(charid, hash, palette, tint0..2, price_paid, currency, acquired_at)` | every grant with a tint (§5.1) |
| **Equipped** item | `app.clothing.equipped` (+ `app.clothing.tints`) | store, wardrobe, surgery clothing, creator, `SetClothes` |
| **Runtime state** | `app.clothing.states` (persisting) + server memory (non-persisting) | [CLOTHING_STATES.md](CLOTHING_STATES.md) |

- A state never removes an owned or equipped item.
- The owned tint belongs to the item. The wardrobe applies it and cannot change it. Only a store
  purchase or dye rewrites it.
- An equipped item without an ownership row (clothing from `SetClothes`, a job uniform) may stay in its
  saved category in the wardrobe, and an outfit may include it only while it is worn there. It is
  never granted by the wardrobe.

---

## 9. Wardrobe and saved outfits

Config (`config/wardrobe.lua`):

| Key | Value | Meaning |
|---|---|---|
| `Config.Wardrobe.maxSavedOutfits` | 10 | outfits per character (clamped 0..100) |
| `Config.Wardrobe.outfitNameMax` | 24 | name length in UTF-8 characters |
| `Config.Wardrobe.allowRemote` | `true` | the `OpenWardrobe` export (client and server) without a location id, for jobs and housing. The `wardrobe` service toggle still applies |

**Open.** `w_creators:wardrobe:open(locationId | nil)` returns `{ token, appearance, owned, outfits,
maxOutfits, outfitsEnabled, remote, expiresIn }`.

- `nil` means a remote wardrobe.
- `owned` also lists the items worn now that have no ownership row, as `{ source = 'worn', worn = true }`.
  This is for display only.
- A degraded appearance is refused.

**Commit.** `w_creators:wardrobe:commit(token, opId, app)` is **free**. It merges the `clothing` and
`states` sections only.

- Rate limit 6 per 10 s.
- The location must still be enabled and open. A remote session is checked against `allowRemote`
  (`LOCATION_NOT_FOUND`).
- **Ownership.** Every worn item must be owned, or be the item already worn in that category in the
  saved look (`ITEM_NOT_OWNED`).
- **Tints** come from ownership (`WCOwnership.wornTint`).
- **Rules** must hold for changed categories.
- `clothing.outfit` is kept only if it is one of the character's outfit ids.
- **States.** With clothing actions on, submitted states are kept when they persist, are valid and
  apply. With them off, the saved states that still apply are kept.
- A commit with nothing changed fails with `NO_CHANGES`.
- On success: save, broadcast, then `appearanceChanged(src, charid, 'wardrobe')`.

**Outfits** (`w_creators_outfits(id, charid, name, data, created_at, updated_at)`,
`data = { equipped, states, tints? }`; each tint an owned colour of the item, `false` the original,
none the owned colour, §5.1):

| Callback | Arguments | Result |
|---|---|---|
| `w_creators:outfits:save` | `token, name, equipped, states, tints?` | `{ outfit, outfits }`. Fails with `OUTFIT_LIMIT` at the limit |
| `w_creators:outfits:update` | `token, id, equipped, states, tints?` | `{ outfit, outfits }` |
| `w_creators:outfits:rename` | `token, id, name` | `{ outfit, outfits }` |
| `w_creators:outfits:delete` | `token, id` | `{ outfits }` |

Checks on every outfit callback:

- They need an open **wardrobe** session token, the `savedOutfits` and `wardrobe` services, and, for a
  location session, the location open and in range.
- Rate limit 10 per 10 s. They run under a per-character lock (`BUSY`).
- **Ids** must be exact positive 32-bit integers, and an id of another character is not found
  (`OUTFIT_NOT_FOUND`).
- **Names** are trimmed, with repeated spaces collapsed (Unicode spaces count as a space), and must be
  1..`outfitNameMax` UTF-8 characters with at least one visible character. Control, bidi-override and
  invisible characters are rejected (`INVALID_OUTFIT_NAME`).
- **Contents.** Every item must be owned or currently worn (`ITEM_NOT_OWNED`) and the rules must hold
  (`CONFLICTING_ITEMS`). Only persisting states that apply to the outfit's own items are stored. With
  clothing actions off, no state is stored.

**Equipping an outfit.** Editor control `outfit.<id>.equip`, applied locally after the `onOutfit('equip',
…)` veto hook. Only items still owned are applied, with their owned tints, and the result goes through
the rules. The change is saved by `w_creators:wardrobe:commit`, which validates ownership again. Other
controls: `outfit.<id>.update|rename|delete` and `outfit.new.name` (typing a name and confirming saves
the current clothes).

---

## 10. Starting clothing

`Config.Creator.startingClothing` (`config/outfits.lua`):

| Key | Configured | Meaning |
|---|---|---|
| `mode` | `'free'` | `'free'`: the creator's clothing stage offers the allowed categories. `'presets'`: only `Config.StartingOutfits` (one choice, control `starter.preset`) |
| `categories` | `'*'` | `'*'` = every clothing category offered to the sex, or a list such as `{ 'shirts_full', 'pants', 'boots' }` |

`Config.StartingOutfits[sex]` = `{ { id, label, items = { { category, model, variant }... } }... }`
(1-based catalogue model/variant per sex). An item that does not resolve is skipped. Configured presets:
male `worker`, `traveler`; female `worker`, `traveler`. In free mode they also appear as an **Outfits**
group in the creator, filtered to the allowed categories.

Server enforcement (`restrictClothing` in `server/characters/characters.lua`):

- **Free mode.** Categories outside the allowed list are dropped, then the rules are applied.
- **Presets mode.** The equipped set must equal one preset exactly (`INVALID_COMPONENT` otherwise).
  Tints are cleared. With no presets for the sex, the character starts with no clothing.
- **Both modes.** The outfit id is cleared, and states that do not apply are dropped (all states are
  dropped when clothing actions are off).
- Every equipped item, with its tint, is granted as `starter` in the same transaction that creates the
  appearance row. Creation is free.

---

## 11. Adding a clothing store

A store is a config edit only. Add an entry to `Config.Locations` (`config/locations.lua`). The fields
merge over `Config.LocationDefaults.clothing` (`interactionRadius = 2.0`, `prompt = true`, `npc = false`,
blip `blip_shop_tailor`, `camera = 'fullBody'`, `storeProfile = 'general'`, `pricingProfile =
'standard'`, `outfits = true`):

```lua
{
    id = 'rhodes_clothing',              -- unique, fixed; the only thing the client ever sends (≤ 64 chars)
    type = 'clothing',
    enabled = true,                      -- false: hidden, and refused by the server (LOCATION_DISABLED)
    label = 'متجر الملابس', town = 'رودز', -- dictionary keys (add any new key to locales/ar.json and locales/en.json)
    coords = vector3(1325.0, -1290.0, 77.0),        -- the interaction point and server proximity anchor
    preview = vector4(1323.0, -1288.0, 77.0, 90.0), -- the fitting stand (x, y, z, heading)
    npc = { model = 'S_M_M_Tailor_01', coords = vector4(1326.0, -1291.0, 76.0, 0.0) }, -- or false
    storeProfile = 'general',            -- a Config.Clothing.storeProfiles id
    pricingProfile = 'standard',         -- a Config.Clothing.pricingProfiles id
    hours = { open = 6, close = 22 },    -- optional; server local time; open 06:00–21:59
    book = vector4(1325.0, -1290.0, 77.0, 90.0),    -- optional: the catalogue book on the counter (§12)
    access = { jobs = { tailor = 0 } },  -- optional: who may use it (§12)
},
```

The coordinates above are **placeholders**. Measure your own in game.

Rules:

- **Validation.** A location with a missing or duplicate `id`, an unknown `type` or invalid `coords` is
  skipped with a warning (`shared/locations.lua`).
- **Range.** The server allows `interactionRadius + 3` m around `coords` **or** `preview`.
- **Hours.** Invalid `hours` are ignored with a warning. If `close < open`, the hours span midnight.
- **New labels.** A new `label`, `town` or blip label is a dictionary key. Add it to **both**
  `locales/ar.json` (key → key) and `locales/en.json`, or `tests/test_locale_coverage.py` fails.
- **After editing,** restart the resource. **Requires live verification:** prompt placement, NPC
  spawn, the fitting-stand camera, and collision at `preview`.
- **Opening from another resource.** The server export `OpenClothingStore(src, id)` opens a store for
  a player. It sends the player to the same `w_creators:store:open` checks.

---

## 12. Store presence: blips, the catalogue book, the fitting-room light, access

- **Blips.** Stores use the game's `blip_shop_tailor`, wardrobes `blip_shop_wardrobe`
  (`Config.LocationDefaults`). The earlier `blip_shop_clothing` is not a sprite of the game and drew a
  plain dot. (w_map's catalogue reader now reads `config/locations.lua` with these sprites.)
- **The catalogue book** (`Config.Locations[].book`, a vector4; `Config.Clothing.catalogue`). The four
  stores' books are at their prompt (`coords`) with the book's heading. With `catalogue.enabled`:
  - `WCServicePoints` creates the game's catalogue prop (`mp001_s_mp_catalogue01x_store`), local and
    frozen, with the store's prompt, and deletes it with it (a rebuild, a disabled service, a stop);
  - before the fade to the fitting room the player reads it: the game's anim scene
    `script@ambient@shop@CATALOG_PLAYER`, playlist `PBL_ENTER`, its origin the book lowered by
    `scene.drop` (1.065 m) at the book's heading, capped at `scene.waitMs` (2.5 s). Death or a step of
    more than 3 m ends the reading, never the visit. The scene is freed under the fade;
  - back at the counter, `PBL_EXIT_INDEX` plays (its clips' dictionary `mech_inspection@catalog` is
    loaded first), freed when it ends or after `scene.exitMs`;
  - every exit path and a resource stop free the scene without waiting.
  **Requires live verification** at the four books: the scene's role name for the player
  (`scene.entity = 'player'`) and, if the scene animates the book, its role (`scene.bookEntity`).
- **Fitting-room light** (`Config.Clothing.fittingLight = { enabled, intensity = 10, range = 15,
  offset = { 0.5, 2.0, 0.3 }, color }`): drawn every frame by `WCPreviewEnv` at that offset from the
  player (right, forward, up) while the store or the wardrobe editor is open.
- **Access** (`Config.Locations[].access = { jobs = { [job] = minGrade }, ace = 'permission' }`, any
  location). The server refuses anyone it does not admit (`ACCESS_DENIED`, `WCSessions.accessAllowed`:
  the framework user's job and grade, `IsPlayerAceAllowed`), at the open and at the commit. The client
  hides the prompt from the server's answer (`w_creators:locations:access`, refreshed every 30 s while
  a rule-bound location exists).
- **The tailor** is dressed by w_lib (`w.entity.create` gives a story NPC its random outfit variation).

## 13. Outfits in the store, the tailor's suggestions, take off everything

- **Outfits** (location `outfits = true`, the default): the store's 8th group lists the character's
  saved outfits to **put on only** (a starting look to buy around). A piece no longer owned stays off;
  each piece in its outfit colour when still owned. Saving, renaming and deleting stay in the wardrobe;
  "save this look as an outfit" goes with the purchase (§7.3).
- **The tailor's suggestions** (`Config.Clothing.suggestions = { useStartingOutfits = true, male = {},
  female = {} }`): ready looks in the same group, each `{ id, label, items = { { category, item } |
  { category, model, variant } } }`, plus the creator's starting outfits when `useStartingOutfits` is
  on. Putting one on dresses the working look in the items of it this store sells (or the character
  owns), priced as usual; the body stays.
- **Take off everything** (`clothing.undress`, store and wardrobe): every removable garment of the
  working look comes off at once; free, saved by the normal commit, undone by Undo.

## 14. Selling back

`Config.Clothing.resell = { enabled = true, percent = 0.33, inWardrobe = false }`.
`w_creators:store:resell(token, hash)` (a store session, or a wardrobe one with `inWardrobe`):

- rate limit 6 per 10 s; the same gates as that session's commit, since a sale pays money out: the
  service on (`STORE_DISABLED` / `WARDROBE_DISABLED`), the location open, in range and its `access` rule
  still met (`ACCESS_DENIED`); a remote wardrobe only while `Config.Wardrobe.allowRemote` is on
  (`LOCATION_NOT_FOUND`). The character's appearance lock and outfit lock are held while it runs
  (`BUSY`);
- the item must be owned (`ITEM_NOT_OWNED`), **bought** in a store with a recorded price
  (`source = 'store'`, `price_paid`, `currency`; a starting, legacy, admin or gifted item was never paid
  for: `NOT_RESELLABLE`), not worn in the saved look (`ITEM_WORN`) and in no saved outfit
  (`ITEM_IN_OUTFIT`);
- its row and its owned colours are deleted in one transaction, **then** `price_paid × percent`
  (rounded to cents) is paid back in the currency it was paid in. A refund that fails puts the rows
  back (`INTERNAL_ERROR`; a failed put-back is logged as `security_violation`);
- logged as `clothing_sold`; the answer carries the new ownership list for the editor.

In the editor an owned, not-worn, bought item shows **Sell back · $x** (a danger action: the confirm
modal asks first); after the sale the category goes back to the saved item.

## 15. Clothing as inventory items (optional, off)

`Config.Clothing.items = { enabled = false, garment = 'w_garment', outfitCard = 'w_outfit_card' }`
(`server/clothing/items.lua`). Ownership stays in w_creators' tables; holding an item grants nothing.

- **Wrap a garment** (wardrobe, `w_creators:wardrobe:wrap(token, hash)`): an owned item that is not
  worn, not in an outfit and not a starting piece leaves the character (its rows, one transaction) and
  is handed over as the garment item with metadata `{ sex, category, hash, tint, colors, label }`
  (`w.framework:giveItem`). A failed hand-over puts the rows back (`INVENTORY_FULL`). The wardrobe
  commit's gates apply (the service, the location and its `access` rule, a remote wardrobe only while
  remote wardrobes are allowed).
- **Use a garment**: the same sex only (`WRONG_SEX`); an item the character owns already is refused
  (the item is kept). The item and its colours are granted as `gift` (never resold), **then** the item
  is taken; a failed take removes the grant again.
- **Share an outfit** (wardrobe, `w_creators:outfits:share(token, id)`): a card item with
  `{ name, sex, items = { { category, hash, tint } } }`. It grants nothing.
- **Use a card** at a clothing store (within its reach, open, allowed): the store opens with the card's
  look tried on (`w_creators:client:openStore(locationId, look)`): owned pieces free, the rest priced as
  usual by the store's own commit. Elsewhere: "use it inside a clothing store".
- The two item names must exist in the inventory (w_inventory's item list). Logged as `clothing_item`.
