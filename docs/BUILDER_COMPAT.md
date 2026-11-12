# Services board (notebook look) — saved data check

2026-11-12. Read-only `SELECT id, type, position, data FROM w_creators_locations` on both servers, then every row
was put through the same checks the board uses (`web/src/board/model.ts` asPlace / formProblems / missingSpots,
and the server's save checks in `server/locations/store.lua`). Nothing was written.

| Server | Rows | Open in the board | Clothing / Barber / Surgery / Wardrobe | Blocks a save | Switched off |
|---|---|---|---|---|---|
| Wraith Studio (`wraith_studio`) | 17 | 17 | 4 / 7 / 3 / 3 | 0 | 0 |
| Red River (`wraith_core`) | 17 | 17 | 5 / 6 / 3 / 3 | 0 | 0 |

Every row has a type, an id and a service point (`coords`), a name of 1-60 letters, a plain NPC model name and a
radius in range, so each one opens and saves unchanged.

## Optional spots not set yet

These places work today without them (no NPC stands there, the player stays where he is, the barber has no chair).
The board says so softly in the readiness line («لم يُحدَّد بعد (اختياري): …») and in the story; it is never shown
as "missing" and never blocks a save.

| Place | Studio | Red River |
|---|---|---|
| tumbleweed_clothing | npc | npc |
| rhodes / valentine / saintdenis _wardrobe | npc, preview | npc, preview |
| valentine / blackwater / saintdenis / tumbleweed _barber | npc, preview, chair | npc, preview, chair |
| annesburg / armadillo / strawberry _barber | npc, preview, chair | (not on Red River) |
| valentine / saintdenis / armadillo _surgery | npc, preview | npc, preview |

## What did not change

- The row shape: no new saved field. The place words («فالنتاين · 12 م منك») are worked out on the client each time
  from w_lib's `lib.place.describe`; nothing is stored.
- The ops (`list create save delete spot clear`) and their checks: the world mode calls the same ops.
- `GlobalState['w_creators:clinicPoints']` (read by w_medic) keeps its shape.
