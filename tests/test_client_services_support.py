"""Shared runtime for the barber / cosmetic surgery / public client API / dev tools client tests
(test_client_services_*.py).

make_services() returns the commerce runtime (test_client_commerce_support: client infrastructure,
the real editor, WCServiceFlow, store and wardrobe over recording fakes) with client/barber/barber.lua,
client/surgery/surgery.lua, client/dev/tools.lua and client/api.lua loaded on top, plus:

  barberData(extra) / surgeryData(extra)   ok open answers of w_creators:barber:open / surgery:open
  setPreview(id, x, y, z, h)               give a location a `preview` seat (WCLocations reloaded)
  stopResource()                           fire onResourceStop for w_creators

`setup` runs before any module loads (e.g. Config.Admin flags, which dev/tools.lua reads at load).
This module has no tests of its own.
"""
from test_client_commerce_support import PLAYER_START, make_commerce, settle  # noqa: F401 (re-exported)

MODULES = (
    'client/barber/barber.lua', 'client/surgery/surgery.lua', 'client/dev/tools.lua', 'client/api.lua',
)

SERVICE_STUBS = r'''
function barberData(extra)
    local d = { token = 'btok', appearance = AppearanceSchema.default('male'),
                growth = { hair = { stage = 1, remainingMinutes = 30 }, beard = { stage = 0, remainingMinutes = 12 } },
                services = { hair = { enabled = true, price = 15 }, facialHair = { enabled = true, price = 15 },
                             details = { enabled = true, price = 7.5, eyebrows = true, makeup = false } },
                multiplier = 1.5, visitCap = 15, sections = { hair = true, facialHair = true, eyebrows = true },
                location = 'valentine_barber', expiresIn = 600 }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { ok = true, code = 'OK', data = d }
end
function surgeryData(extra)
    local d = { token = 'gtok', appearance = AppearanceSchema.default('male'), price = 500,
                allow = { face = true, body = true, eyes = true, skin = true, hair = false, facialHair = false,
                          clothing = false },
                sections = { face = true, body = true, eyes = true, skin = true },
                clinic = 'valentine_surgery', expiresIn = 600 }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { ok = true, code = 'OK', data = d }
end
function setPreview(id, x, y, z, h)
    for _, loc in ipairs(Config.Locations) do
        if loc.id == id then loc.preview = vector4(x, y, z, h) end
    end
    WCLocations.reload()
end
function stopResource() fireEvent('onResourceStop', nil, 'w_creators') end
function lastRender() return RenderCalls[#RenderCalls] end
function lastRestore() return RestoreCalls[#RestoreCalls] end
'''


def make_services(setup=''):
    """The runtime with the service modules loaded. `setup` runs before the modules load."""
    rt = make_commerce()
    rt.run(SERVICE_STUBS)
    if setup:
        rt.run(setup)
    rt.load(*MODULES)
    rt.run('tick(0)')
    return rt
