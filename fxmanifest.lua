fx_version "adamant"
games { "rdr3" }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

-- =====================================================================
--  w_creators - a complete character creator (multicharacter + creation + spawn)
--  Compatible with VORP / RSG / QBR. Lua owns appearance state; web/ owns the shared React editor.
-- =====================================================================

shared_scripts {
	'@w_lib/init.lua',   -- the library: must stay the first shared script
	'config.lua',
	'data/components.lua',
	'data/overlay_map.lua',
	'data/stores.lua',   -- the clothing shops and the wardrobes (coordinates + prices)
	'data/appearance.lua',
    'data/grooming.lua',
	'data/features.lua',
}

client_scripts {
	'bridge/client.lua',
	'modules/natives.lua',
	'modules/appearance.lua',
	'modules/overlay_bridge.lua',
	'modules/camera.lua',
	'modules/scene.lua',
	'modules/editor.lua',
	'creator/client.lua',
	'creator/spawn.lua',
	'multichar/client.lua',
	'spawnselect/client.lua', -- the spawn location selection screen (Config.SpawnSelector)
	'store/client.lua',    -- the clothing shops
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	-- The logs are optional: the resource being absent or stumbling does not stop the character selection and the spawn.
	'bridge/logging.lua',
	'bridge/server.lua',
	'server/scene.lua',
	'server/server.lua',
	'multichar/server.lua',
	'store/server.lua',
    'server/grooming.lua',
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
	-- RDR design assets. They are no longer inlined inside index.html because vite copies
	-- public/ as files; if they are not declared here they give a 404 inside the game so the
	-- interface shows with no textures and no fonts and no sounds.
	'web/build/tex/ui/*.png',
	'web/build/fonts/*.woff2',
	'web/build/sounds/*.mp3',
	'web/build/img/*.jpg',
}

ui_page 'web/build/index.html'

-- The w_lib modules preloaded at start (both sides). w.pl (client only) resolves lazily on
-- its first access.
w_lib {
    'locale',    -- loads locales/{en,ar}.json before any script runs
    'component', -- the clothing and tinting catalogue (the creator and the clothing shop)
    'callback',  -- the purchase calls
}
