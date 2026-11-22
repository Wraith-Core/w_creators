# w_creators

Character selection, character creator studio, appearance persistence, speaking voices, spawn selector, cosmetic surgery, and death resurrection authority for **Wraith Framework RedM**.

## Key Features

- **Multicharacter Selection:** Multi-slot character selector with configurable slot permissions and safe character deletion.
- **Character Creator Studio:** Hierarchical React + Vite appearance editor for heritage, facial features, body build, overlays, voice tone, and starter clothing.
- **Spawn & Respawn:** Configurable spawn locations, last-location restore, optional first-spawn intro scene, and single authoritative `Resurrect` export.
- **Modular Integration:** Integrates seamlessly with `w_clothing`, `w_barber`, `w_loading`, and `w_medic`.
- **Auto-Migrations:** Automatically creates and migrates required appearance tables on startup (reference schema in `sql/install.sql`).

## Installation

1. Place `w_creators` in `resources/[wraith]/w_creators`.
2. Import `sql/install.sql` (or let auto-migrations run on first boot).
3. Add `ensure w_creators` to `server.cfg` after `w_lib` and `w_core`.

## Key Exports

```lua
exports.w_creators:Resurrect(coords, heading, reason)
exports.w_creators:GetAppearance()
exports.w_creators:RefreshAppearance()
exports.w_creators:IsInCharacterScene()
```

## Documentation & Links

- **Developer Docs:** https://wraith-core.github.io/docs/#/resources/character-appearance
- **txAdmin Recipe:** https://github.com/Wraith-Core/txAdminRecipe
- **Credits:** See [CREDITS.md](CREDITS.md)
