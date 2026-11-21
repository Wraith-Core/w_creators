fx_version "adamant"
games { "rdr3" }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'
version '1.2.5' -- 1.2.5 (2026-11-22) = unified /servicesadmin board with w_clothing & w_barber + framework admin check.

-- =====================================================================
--  w_creators v3 - the character lifecycle authority: account -> characters -> selection ->
--  identity -> appearance -> clothing ownership -> outfits -> clothing states -> barber ->
--  cosmetic surgery -> spawn -> respawn. Compatible with VORP / RSG / QBR.
--  The binding design contract is docs/ARCHITECTURE.md (file layout and load order: §2).
-- =====================================================================

shared_scripts {
    '@w_lib/init.lua', -- the library: must stay the first shared script
    -- configuration (main first)
    'config/main.lua',
    'config/locations.lua',
    'config/clothing.lua',
    'config/surgery.lua',
    'config/spawn.lua',
    'config/outfits.lua',
    'config/voice.lua',
    'config/board.lua',
    -- shared modules
    'shared/util.lua',
    'shared/result.lua',
    'shared/debug.lua',
    'shared/services.lua',
    'shared/locations.lua',
    'shared/morphology.lua',
    'shared/overlays.lua',
    'shared/catalog.lua',
    'shared/rules.lua',
    'shared/appearance.lua',
    'shared/grooming.lua',
    'shared/clothing_states.lua',
    'shared/identity.lua',
}

client_scripts {
    -- natives (the only place with raw native invokes)
    'client/natives/metaped.lua',
    'client/natives/ped.lua',
    'client/natives/clothing.lua',
    'client/natives/camera.lua',
    'client/natives/respawn.lua',
    'client/natives/scene.lua',
    'client/natives/ui.lua',
    'client/natives/promptlab.lua', -- the staff's /promptlab only (remove with client/lab/promptlab.lua)
    -- core
    'client/core/locale.lua',
    'client/core/ui.lua',
    'client/core/state.lua',
    -- appearance
    'client/appearance/pipeline.lua',
    'client/appearance/overlays.lua',
    'client/appearance/sync.lua',
    -- the speaking voice: greet / antagonize
    'client/voice/speak.lua',
    -- camera
    'client/camera/camera.lua',
    -- scene
    'client/scene/scene.lua',
    'client/scene/environment.lua',
    -- editor
    'client/editor/tree.lua',   -- WCEditorTree before the editor that builds with it
    'client/editor/editor.lua',
    'client/editor/panel.lua',
    -- domains
    'client/characters/selector.lua',
    'client/characters/rename.lua',   -- 2026-10-21: the store's name change (/changename)
    'client/creator/creator.lua',
    'client/creator/cutscene.lua',
    'client/services/locations.lua',
    'client/services/seat.lua',
    'client/surgery/surgery.lua',
    'client/services/board.lua',  -- the staff's surgery clinics board (/servicesadmin)
    'client/spawn/selector.lua',
    'client/spawn/spawn.lua',
    'client/respawn/respawn.lua',
    'client/dev/tools.lua',
    'client/lab/promptlab.lua',   -- 2026-11-03: the staff's game prompts lab (/promptlab)
    -- public API
    'client/api.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- bridge (logging is optional: its absence never blocks selection or spawn)
    'server/bridge/logging.lua',
    'server/bridge/framework.lua',
    -- core
    'server/core/migrations.lua',
    'server/core/security.lua',
    'server/core/refunds.lua',
    'server/core/economy.lua',
    'server/core/sessions.lua',
    -- appearance
    'server/appearance/repository.lua',
    'server/appearance/sync.lua',
    'server/voice/speak.lua',
    -- characters
    'server/characters/characters.lua',
    'server/characters/rename.lua',   -- 2026-10-21: the store's name change (/changename)
    -- scene
    'server/scene.lua',
    -- domains (clothing store/wardrobe moved to w_clothing; barber/grooming moved to w_barber)
    'server/clothing/ownership.lua', -- starter clothing ownership grants on character creation
    'server/surgery/surgery.lua',
    -- the service places edited in game (/servicesadmin)
    'server/locations/store.lua',
    'server/spawn/spawn.lua',
    'server/respawn/respawn.lua',
    'server/dev/tools.lua',
    'server/lab/promptlab.lua',   -- 2026-11-03: the staff's game prompts lab (/promptlab)
    -- public API
    'server/api.lua',
}

dependencies {
    '/onesync',
    '/native:0x635E5289',
    '/native:0x6504EB38',
    'w_lib',
}

files {
    -- The dictionaries: Arabic is the source (the keys) and en.json translates it.
    -- The language is the library's key (w.getLocaleKey): the player's choice in /w_lib or the
    -- server convar w_lib:locale. Only 'ar' and 'en' exist; anything else is treated as 'en'.
    'locales/*.json',
    'web/build/index.html',
    -- RDR design assets (vite copies public/ as files; undeclared they 404 inside the game).
    'web/build/tex/*.png',         -- 1.1.0: the board kit's torn edge, grain and bands (tear, grain, band, band-sm)
    'web/build/tex/ui/*.png',
    'web/build/tex/cloth/*.png',   -- the game's clothing icons (config/clothing.lua `icon`; also read by w_wheel)
    -- the tint sliders' palette strips (docs/CLOTHING.md §5.2): none ship; the owner exports them
    -- into web/public/tex/palettes, and undeclared they would 404 in game like any other asset
    -- 'web/build/tex/palettes/*.png',
    'web/build/fonts/*.woff2',
    'web/build/sounds/*.mp3',
    'web/build/img/*.jpg',
}

ui_page 'web/build/index.html'

-- The w_lib modules preloaded at start (both sides). w.pl (client only) resolves lazily on
-- its first access.
w_lib {
    'locale',           -- loads locales/{en,ar}.json before any script runs
    'component',        -- the clothing and tinting catalogue
    'callback',         -- the request/response calls
    'framework-bridge', -- framework detection and core object access (w_core / RSG / VORP / QBR)
}
