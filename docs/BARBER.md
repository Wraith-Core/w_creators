# w_creators — Barber and grooming

Operator guide for the barber chair and for hair / beard growth. Source of truth: `config/barber.lua`,
`config/locations.lua`, `server/barber/barber.lua`, `server/barber/grooming.lua`, `shared/grooming.lua`,
`client/barber/barber.lua`. Contract: `docs/ARCHITECTURE.md` §9.3, §16.4.

Nothing in this document was run on a live RedM server. Behaviour that depends on the game engine
(what a style looks like, camera framing, fades, the seat move) **requires live verification**; the
matching live checks are `docs/TESTING.md` L5.1–L5.5 and L8.4.

## 1. Sections

A barber visit edits these appearance sections only. Everything else in a submission is ignored: the
server merges the allowed sections into the **saved** appearance it loads itself.

| Section | Offered when | What it contains |
|---|---|---|
| `hair` | `Config.Barber.services.hair.enabled` and the location allows `hair` | hair style (the colour is part of the style asset) and the `hairov` overlay (light head hair) |
| `facialHair` | `Config.Barber.services.facialHair.enabled`, the location allows `facialHair`, **and the character is male** | beard / moustache style and the `beardstabble` overlay (stubble) |
| `eyebrows` | `services.details.enabled` and `services.details.eyebrows = true` and the location allows `details` | the `eyebrows` overlay |
| `makeup` | `services.details.enabled` and `services.details.makeup = true` (default `false`) and the location allows `details` | the makeup overlays (`foundation`, `blush`, `lipsticks`, `eyeliners`, `shadows`, `paintedmasks`) |

Per location, `allowedServices = { hair = true, facialHair = true, details = true }` narrows the list;
`nil` (the default in `Config.LocationDefaults.barber`) allows every enabled service. A location that
ends up with no section answers `BARBER_DISABLED`.

A submitted hair or beard hash must be a catalogue item of the character's sex (`0` = bald / clean
shaven is valid). An unknown hash is refused with `INVALID_COMPONENT`; it is never turned into "bald".

## 2. Pricing

All prices are computed on the server; nothing is read from the client payload.

```
Config.Barber = {
    services = {
        hair       = { enabled = true, price = 10 },
        facialHair = { enabled = true, price = 10 },
        details    = { enabled = true, price = 5, eyebrows = true, makeup = false },
    },
    prices = { visitCap = 10 },   -- nil = no cap
}
```

1. **Per service.** Each service whose sections changed adds its base `price` once: `hair`,
   `facialHair`, and `details` once for eyebrows and/or makeup.
2. **Visit cap.** The sum is capped at `prices.visitCap` (a base price, applied before the multiplier).
3. **Profile multiplier.** The capped sum is multiplied by the location's pricing profile,
   `Config.Clothing.pricingProfiles[location.pricingProfile or 'standard'].multiplier`
   (`standard = 1.0` ships), then rounded to cents.

With the shipped defaults every visit costs at most **10** (the pre-v3 flat price): hair only 10,
hair + beard 10, eyebrows only 5, hair + eyebrows 10.

Refusals:

| Case | Code | Charged |
|---|---|---|
| Nothing in an allowed section changed | `NO_CHANGES` | nothing |
| An enabled service has a missing / negative / non-finite price, or the location's pricing profile is unknown | `INVALID_PRICE` (at open, logged with `WCDebug.warn`) | nothing |
| Not enough cash | `INSUFFICIENT_FUNDS` | nothing |
| A free service | set `price = 0` explicitly (a missing price is `INVALID_PRICE`) | 0, the framework is not touched |

The open reply carries the prices **already multiplied** (`services.<key>.price`), the `multiplier`
and the multiplied cap (`visitCap`), so the editor's price preview matches the server's charge.
Growth is never charged.

## 3. Grooming (hair and beard growth)

**Growth ships disabled** (`enabled = false`, owner 2026-11-01, v1.0.5): no automatic growth, the barber
is only for picking a style. The feature below stays in the code and can be turned back on with
`enabled = true`. Saved appearances keep their `grooming` field; looks that already grew are not reverted
(the player picks a style again at the barber).

```
Config.Grooming = {
    enabled = false,
    minutesPerStage = { hair = 120, beard = 60 },
    stages = {
        male   = { hair = { ...3 prefixes }, beard = { ...3 prefixes } },
        female = { hair = { ...3 prefixes } },          -- no beard kind for female
    },
    saveIntervalSeconds = 300,
}
```

**Stages.** The growth state is stored in the appearance as
`grooming = { hair = { stage, seconds }, beard = { stage, seconds } }` (server-owned). A stage is the
index of the asset prefix in `stages[sex][kind]` that the current style name starts with; `0` = bald /
clean shaven; a style that matches no prefix counts as stage 1. A kind with no configured list for
the sex (female beard) never grows.

**Timing.** Every `minutesPerStage[kind]` minutes of counted time the kind advances one stage and the
style is swapped for `<next prefix><colour suffix of the current style>` (the colour is kept; with no
colour to keep, e.g. growing from bald, the suffix is `BROWN`). If that asset does not resolve in the
catalogue the stage still advances but the style hash is left unchanged. At the last stage the
counter stays at 0 (fully grown). Note that stage 0 grows too: a bald or clean-shaven character grows
into stage 1 after one interval.

**What counts.** A server thread ticks every 30 s (`WCGroomingServer.TICK_MS`) and counts at most
60 s per tick (a stalled server never jumps stages). Only time online counts, and only while:

- the player has an active character (not in the selection room / creator),
- the player is in routing bucket 0 (main world),
- no service session is open (store, wardrobe, barber, surgery),
- no spawn grant is pending and no character switch is in progress,
- the stored appearance is not degraded (a defaults-filled appearance never grows).

Offline time never counts. `Config.Grooming.enabled = false` stops the loop and hides the growth plate
in the barber editor.

**Save points.** Growth accumulates in memory; there are no per-tick database writes. It is written:

- when the accumulated time changes a stage (then broadcast to other players and sent to the owner as
  `w_creators:client:grooming`; runtime clothing states such as a raised bandana are kept),
- every `saveIntervalSeconds` (clamped to 30–86400, default 300),
- when the player drops, and when the character is cleared (character switch).

A write never overlaps another appearance writer (it takes the per-character appearance lock; a tick
that finds the lock held tries again on a later tick). A resource restart loses at most the growth
since the last save (live check L8.4).

**Barber, surgery and `SetSkin` interplay.** Before saving, these writers fold the pending in-memory
growth into the appearance they save (`WCGroomingServer.fold`, then `consumed` once the save
succeeded). A kind whose style the visit changed (a cut) restarts from the new style's stage with 0 s;
the other kind keeps its growth. The barber editor shows each kind's `stage`, `stages`,
`remainingMinutes` and `fullyGrown` while grooming is enabled.

## 4. Locations

Barbers are `Config.Locations` entries with `type = 'barber'`; adding one is a config edit.
Defaults (`Config.LocationDefaults.barber`): `interactionRadius = 2.0`, `prompt = true`, `npc = false`,
`blip = { sprite = 'blip_shop_barber', label = 'الحلاق' }`, `camera = 'hair'`, `allowedServices = nil`.

| id | Town | coords |
|---|---|---|
| `valentine_barber` | Valentine | `-307.51, 813.96, 118.99` |
| `blackwater_barber` | Blackwater | `-814.915, -1367.89, 43.75` |
| `saintdenis_barber` | Saint Denis | `2655.21, -1179.9, 53.27` |
| `annesburg_barber` | Annesburg | `2924.3, 1343.7, 44.4` |
| `armadillo_barber` | Armadillo | `-3684.22, -2621.05, -13.44` |
| `tumbleweed_barber` | Tumbleweed | `-5493.4, -2940.7, -0.46` |
| `strawberry_barber` | Strawberry | `-1810.92, -372.15, 162.89` |

Optional per-location fields: `enabled = false` (hidden, server answers `LOCATION_DISABLED`),
`hours = { open, close }` (server local time; closed → `LOCATION_CLOSED_HOURS`), `pricingProfile`,
`allowedServices`, `npc`, `blip`, `camera`, and `preview` (a `vector4` chair). No shipped barber has a
`preview`: the visit happens where the player stands. With a `preview`, `WCServiceSeat` fades out,
moves the player to the chair, and puts him back when the visit ends (requires live verification).

The prompt key is `Config.Keys.interact` (`'J'`). The server must see the player within
`interactionRadius + 3` m of `coords` (or of `preview`) at open **and** at commit (`TOO_FAR`).
Global switch: `Config.Services.barbers = false` removes prompts/blips and every barber callback
answers `BARBER_DISABLED`. Another resource can open a barber with the server export
`exports.w_creators:OpenBarber(src, locationId)` (same checks, then `w_creators:client:openBarber`).

## 5. Transaction flow

```
prompt (J) ─► WCBarber.open(locationId) ─► WCServiceFlow
  ─► callback w_creators:barber:open(locationId)
       WCSessions.open: service on, active character, no other session, location type/enabled/hours,
       distance, no appearance lock ─► snapshot of the saved appearance, token (session TTL 30 min)
       degraded appearance ─► INTERNAL_ERROR · no section ─► BARBER_DISABLED · bad price ─► INVALID_PRICE
  ─► preview environment, chair (if preview), editor in 'barber' mode (local preview only)
  ─► Save ─► callback w_creators:barber:commit(token, opId, appearance)
       rate limit 6 / 10 s, payload ≤ 64 KB, session valid, distance, per-character lock,
       idempotent per opId (a repeated opId replays the recorded answer for 120 s)
       merge allowed sections into the saved appearance ─► validate styles ─► price
       ─► fold pending growth ─► WCEconomy.withCharge( charge cash ─► save ─► refund if the save fails )
       ─► broadcast to other players ─► logs haircut + appearance_changed
       ─► event w_creators:server:appearanceChanged(src, charid, 'barber')
```

| Outcome | Result |
|---|---|
| Cancel, death, editor closed elsewhere | snapshot restored on the ped, session closed, nothing charged |
| Session expired / resource stopped / character changed | server sends `w_creators:client:sessionClosed(token, reason)`; the client restores the snapshot |
| Disconnect before Save | session dropped, nothing written |
| Commit refused (`NO_CHANGES`, `INSUFFICIENT_FUNDS`, `INVALID_COMPONENT`, …) | nothing charged, the answer returns to the editor |
| Save fails after the charge | cash refunded; the save's error code (`DATABASE_ERROR` by default) with `data.refunded`; a failed refund is logged as `security_violation` (`refund_failed`) |
| Reply lost (`INTERNAL_ERROR` / `BUSY`) | the client asks `w_creators:session:result(token, opId)` and takes the recorded answer; still unknown → reloads the saved look |

## 6. What the barber never changes

- body, height, weight, face shape and head, teeth, eyes, skin tone and skin overlays,
- clothing, clothing states, owned items and outfits,
- identity, and the ped model (growth and styles use existing multiplayer assets only),
- `facialHair` on a female character; eyebrows / makeup unless enabled in `services.details`,
- money beyond the computed price; growth is never charged.
