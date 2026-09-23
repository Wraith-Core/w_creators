# w_creators — Cosmetic surgery

Operator guide for the cosmetic surgery clinics. Source of truth: `config/surgery.lua`,
`config/locations.lua`, `server/surgery/surgery.lua`, `server/api.lua` (`OpenCosmeticSurgery`),
`client/surgery/surgery.lua`, and in w_ambulancejob `config.lua`, `client/job.lua`, `server/main.lua`.
Contract: `docs/ARCHITECTURE.md` §9.3, §13, §16.4.

Nothing in this document was run on a live RedM server. Prompt visibility, camera framing and the
on-screen editor **require live verification**; the matching live checks are `docs/TESTING.md`
L6.1–L6.5.

## 1. `Config.CosmeticSurgery` (w_creators, `config/surgery.lua`)

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Second switch of the `surgery` service (both this and `Config.Services.surgery` must be on). |
| `price` | `500.0` | Flat price of one procedure, whatever changed. A clinic entry's own `price` overrides it. The result is multiplied by the clinic's pricing profile (`Config.Clothing.pricingProfiles[pricingProfile or 'standard']`) and rounded to cents. |
| `allow.face` | `true` | head, teeth, face morphology |
| `allow.body` | `true` | body type, height, weight, body morphology |
| `allow.eyes` | `true` | eye colour |
| `allow.skin` | `true` | skin tone and skin overlays |
| `allow.hair` | `false` | hair style (+ `hairov` overlay) |
| `allow.facialHair` | `false` | beard (male only, even when `true`) |
| `allow.clothing` | `false` | clothing; only items the character already owns (`ITEM_NOT_OWNED` otherwise), tints forced to the owned / saved tint |
| `sessionMinutes` | `20` | How long a clinic session may stay open before the server expires it. |

Everything outside the allowed sections is kept from the saved appearance on the server, whatever the
client submits. Eyebrows and makeup are never a surgery section.

## 2. Clinic locations

Clinics are `Config.Locations` entries with `type = 'surgery'`. Defaults
(`Config.LocationDefaults.surgery`): `interactionRadius = 2.0`, `prompt = false`, `npc = false`,
`blip = false`, `camera = 'face'`.

| id | Town | coords (server proximity anchor) |
|---|---|---|
| `valentine_surgery` | Valentine | `-284.49, 807.49, 119.38` |
| `saintdenis_surgery` | Saint Denis | `2387.306, -1369.280, 46.541` |
| `armadillo_surgery` | Armadillo | `-3651.82, -2649.4, -13.45` |

`prompt = false` means w_creators draws **no** prompt, blip or NPC for the clinic: the doctor resource
(w_ambulancejob) provides the entry. Such a clinic opens **only** through the server export
`OpenCosmeticSurgery`, which hands out a one-use grant; a direct `w_creators:surgery:open` request, or
the client export `exports.w_creators:OpenCosmeticSurgery(clinicId)`, is refused with
`SURGERY_NOT_ALLOWED` (live check L6.4).

A clinic with `prompt = true` gets w_creators' own walk-up prompt (`Config.Keys.interact`) and opens
without a grant; the client export `OpenCosmeticSurgery(clinicId)` also works for it.

The server requires the player within `interactionRadius + 3` m (5 m by default) of `coords`, or of
`preview` when the clinic has one, at export time, at open and at commit (`TOO_FAR`). Other optional
fields: `enabled`, `hours`, `pricingProfile`, `price`, `camera`, `preview` (a `vector4` seat, handled
by `WCServiceSeat` like the barber chair).

## 3. The w_ambulancejob flow

w_ambulancejob `config.lua`:

```lua
Config.CosmeticSurgery = {
    enabled = true,                -- false removes the clinic prompts
    key = Config.PromptKey,
    cooldown = 3,                  -- seconds between two requests of one player
    clinics = {
        { clinicId = 'valentine_surgery',  coords = vector3(-282.49, 809.29, 119.38) },
        { clinicId = 'saintdenis_surgery', coords = vector3(2387.306, -1369.280, 46.541) },
        { clinicId = 'armadillo_surgery',  coords = vector3(-3651.82, -2649.4, -13.45) },
    },
}
```

`clinicId` must be a w_creators surgery location id; `coords` is where w_ambulancejob shows its prompt.
Keep it within a few metres of the w_creators clinic `coords` (the Valentine prompt sits about 2.7 m
from the anchor, away from the duty-desk prompt).

```
w_ambulancejob client (client/job.lua)
  w.prompt.at at the clinic coords; shown when the player is upright and w_creators is started
  ─► TriggerServerEvent('hospital:server:requestCosmeticSurgery', clinicId)
w_ambulancejob server (server/main.lua)
  per-player cooldown · clinicId must be in its own Config.CosmeticSurgery.clinics ·
  player not dead / in last stand (metadata) · w_creators started
  ─► exports.w_creators:OpenCosmeticSurgery({ source = src, clinicId = clinicId })
  ─► on any failure shows its own message 'error.surgery_unavailable'
w_creators server export (server/api.lua)
  valid player · surgery service on (SURGERY_DISABLED) · active character (NO_CHARACTER) ·
  no open session (BUSY) · surgery location exists (LOCATION_NOT_FOUND) · enabled and open
  (LOCATION_DISABLED) · distance (TOO_FAR) · the character's sex has an allowed section (SURGERY_DISABLED)
  ─► one-use grant for this clinic, valid 60 s (WCSurgeryService.GRANT_SECONDS)
  ─► TriggerClientEvent('w_creators:client:openSurgery', src, clinicId) ─► Result { locationId }
w_creators client (client/surgery/surgery.lua)
  openSurgery ─► WCSurgery.open(clinicId) ─► callback w_creators:surgery:open(clinicId)
w_creators server open
  WCSessions.open (service, character, location, hours, distance, locks; TTL = sessionMinutes)
  degraded appearance ─► INTERNAL_ERROR · prompt = false and no live grant ─► SURGERY_NOT_ALLOWED ·
  no allowed section ─► SURGERY_DISABLED · invalid price / profile ─► INVALID_PRICE ·
  allow.clothing ─► the owned-items list is loaded
  the grant is consumed only by an open that succeeded
  ─► { token, appearance, price, allow, sections, owned?, clinic, expiresIn }
editor in 'surgery' mode ─► Save ─► callback w_creators:surgery:commit(token, opId, appearance)
```

w_ambulancejob's prompt also reads `GlobalState['w_creators:clinics']` to hide clinics that are closed.
w_creators does **not** publish that key at this commit (grep finds no writer), so the prompt shows
whenever the player is upright and w_creators is started, and the server's answer decides.

## 4. Server authority

- The server computes the price (`WCSurgeryService.price`); the client never sends one.
- The commit merges only the allowed sections of the submission into the appearance the server loads
  itself. A submission whose only changes are in sections the clinic does not allow →
  `SURGERY_NOT_ALLOWED`; no change at all → `NO_CHANGES`; nothing is charged in either case.
- Hair / beard hashes must be catalogue items of the character's sex (`INVALID_COMPONENT`).
- The commit re-checks the service, the clinic (`enabled`, `hours`), the distance, the session token and
  the character; it is rate-limited (6 per 10 s), limited to a 64 KB payload, serialised per character
  and idempotent per `opId`.
- A degraded (defaults-filled) saved appearance is refused before anything is charged (`INTERNAL_ERROR`).
- Hair or beard changes (when allowed) restart that kind's growth; pending growth of the other kind is
  kept (`WCGroomingServer.fold`).
- Success: broadcast to other players, logs `surgery_completed` and `appearance_changed`, event
  `w_creators:server:appearanceChanged(src, charid, 'surgery')`.

## 5. Transaction safety

Money is charged **before** the save and refunded if the save fails (`WCEconomy.withCharge`). Nothing
is written before the commit.

| Situation | Outcome |
|---|---|
| Player cancels | snapshot restored on the ped, session closed, nothing charged |
| Player dies during the procedure | the respawn service cancels the editor; snapshot restored, nothing charged |
| Disconnect before Save | session and grant dropped on `playerDropped`; nothing written |
| Session expires (`sessionMinutes`) | `w_creators:client:sessionClosed(token, 'expired')`; the client closes the editor and restores the snapshot |
| Resource stop / restart before Save | sessions cleared (`stopped`); the client undoes the preview without yielding; nothing written or charged |
| Resource stop in the middle of a commit (between charge and save) | not covered by the refund path; the window is one database write; **requires live verification** |
| Not enough cash | `INSUFFICIENT_FUNDS`; nothing saved; the answer returns to the editor |
| Database save fails | cash refunded; the save's error code (`DATABASE_ERROR` by default) with `data.refunded`; a failed refund (e.g. the player already left) is logged as `security_violation` (`refund_failed`) |
| Reply lost (`INTERNAL_ERROR` / `BUSY`) | the client asks `w_creators:session:result(token, opId)`; a recorded success is applied, otherwise the saved look is reloaded |
| Save pressed twice | the second call replays the first answer (same `opId`) or is `BUSY` |

## 6. UX copy

Shown by the editor in `surgery` mode (Arabic source key → `locales/en.json`):

| Where | Key | English |
|---|---|---|
| Title | `عيادة التجميل` | Cosmetic Clinic |
| Save button, confirm dialog title | `تأكيد العملية` | Confirm procedure |
| Confirm dialog body | `ستُطبَّق التعديلات على مظهر الشخصية.` | The changes will be applied to the character’s appearance. |
| Review hint | `راجع التعديلات ثم أكّد العملية.` | Review the changes, then confirm the procedure. |
| Price line (when something changed) | `عيادة التجميل` + the server price | Cosmetic Clinic |
| `SURGERY_NOT_ALLOWED` | `هذا التعديل غير مسموح في عملية التجميل` | This change is not allowed in cosmetic surgery |
| `SURGERY_DISABLED` | `عمليات التجميل غير متاحة` | Cosmetic surgery is unavailable |
| `NO_CHANGES` | `لا توجد تغييرات` | There are no changes |

The subtitle is the clinic's `town`; the camera starts on the `face` preset. w_ambulancejob uses its
own keys: prompt `prompt.cosmetic_surgery` ("Cosmetic surgery"), title `text.surgery`, refusal
`error.surgery_unavailable` ("Cosmetic surgery is not available right now").

## 7. Disabling

| Scope | How | Effect |
|---|---|---|
| Globally | `Config.Services.surgery = false` or `Config.CosmeticSurgery.enabled = false` | every surgery callback and the export answer `SURGERY_DISABLED` |
| Globally, by content | every `Config.CosmeticSurgery.allow` flag `false` | `SURGERY_DISABLED` |
| One clinic | `enabled = false` on its location | `LOCATION_DISABLED` |
| One clinic, by time | `hours = { open, close }` | `LOCATION_DISABLED` outside the hours |
| The w_ambulancejob prompts | w_ambulancejob `Config.CosmeticSurgery.enabled = false`, or remove the clinic from its `clinics` list | no prompt; its server ignores a clinicId not in the list |
