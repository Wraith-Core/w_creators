-- =====================================================================
--  data/overlay_map.lua  -  generated automatically, not edited by hand
--
--  A map of the resource's layers to w.pedTexture ids. It was derived by reversing the
--  overlaysInfo hashes against RDR2's naming pattern (mp_u_faov_<category>_<nnn>) rather than by guessing
--  from the position: the resource's arrays are ordered by the hash's value and not by the index, so the eyebrows for instance
--  have id 12 in their first position, not 1.
--
--  Two fixes are built in:
--    - ageing[1] was mp_u_faov_acne_000 - an acne texture in the wrinkles list, removed.
--    - hairov[4] a hash with no known name, dropped.
-- =====================================================================

OverlayMap = {
    ['acne'] = { layer = 'acne', ids = { 0 } },
    ['ageing'] = { layer = 'ageing', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 } },
    ['beardstabble'] = { layer = 'beard', ids = { 0 } },
    ['blush'] = { layer = 'blush', ids = { 0, 1, 2, 3 } },
    ['complex'] = { layer = 'complex', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 } },
    ['disc'] = { layer = 'disc', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    ['eyebrows'] = { layer = 'eyebrow', ids = { 12, 6, 3, 11, 2, 4, 13, 14, 15, 1, 3, 2, 6, 8, 5, 7, 7, 9, 0, 10, 5, 1, 0, 4 } },
    ['eyeliners'] = { layer = 'eyeliner', ids = { 0 } },
    ['foundation'] = { layer = 'foundation', ids = { 0 } },
    ['freckles'] = { layer = 'freckles', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 } },
    ['grime'] = { layer = 'grime', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    ['hairov'] = { layer = 'hair', ids = { 0, 2, 9 } },
    ['lipsticks'] = { layer = 'lipstick', ids = { 0 } },
    ['moles'] = { layer = 'moles', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    ['paintedmasks'] = { layer = 'masks', ids = { 0 } },
    ['scars'] = { layer = 'scar', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    ['shadows'] = { layer = 'eyeshadow', ids = { 0 } },
    ['spots'] = { layer = 'spots', ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
}
