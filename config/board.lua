-- =====================================================================
--  config/board.lua  —  the staff's services board (/servicesadmin, 2026-10-19)
--  The places of the clothing stores, barbers, cosmetic surgery clinics and wardrobes are edited in
--  game: the server keeps them in w_creators_locations (server/locations/store.lua); config/locations.lua
--  only seeded that table once. A staff member needs the Config.Admin.ace permission.
-- =====================================================================

Config.Board = {
    command = 'servicesadmin',
    -- every spot a staff member sets must be within this many metres of him (the server checks)
    maxDistance = 80.0,
    -- interaction radius limits (metres) on the board
    radius = { min = 0.5, max = 10.0, default = 2.0 },
    labelMax = 48, -- characters of a place's name / town

    -- the NPC models the board suggests per place type (the staff may type another model name).
    -- Each one is spawned by working code here or on the old server.
    npcModels = {
        clothing = { 'S_M_M_Tailor_01', 'u_m_m_nbxgeneralstoreowner_01', 'u_f_m_tumgeneralstoreowner_01' },
        barber   = { 's_m_m_barber_01', 'u_m_m_valbarber_01', 'a_m_m_valtownfolk_01' },
        surgery  = { 'u_m_m_valdoctor_01', 'a_m_m_valtownfolk_01', 'a_f_m_valtownfolk_01' },
        wardrobe = { 'a_m_m_valtownfolk_01', 'a_f_m_valtownfolk_01' },
    },

    -- the chairs a staff member may place at a barber (props of the game)
    chairModels = { 'p_barberchair01x', 'p_barberchair02x', 'p_barberchair03x' },

    -- the ghost shown while placing the editing spot (where the player stands)
    previewModel = 'a_m_m_valtownfolk_01',

    -- a place whose type has no blip by default gets this sprite when the board turns its blip on
    blipSprites = {
        clothing = 'blip_shop_tailor',
        barber   = 'blip_shop_barber',
        surgery  = 'blip_shop_doctor',
        wardrobe = 'blip_shop_wardrobe',
    },
}
