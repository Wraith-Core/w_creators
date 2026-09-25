-- =====================================================================
--  client/clothing/catalogue.lua  —  WCCatalogue: the clothing store's catalogue book
--  (Config.Clothing.catalogue, Config.Locations[].book)
--
--  The prop: the game's catalogue book, a local frozen object (never networked) on the counter of
--  each clothing store that has a book. WCServicePoints creates it with the store's prompt and
--  removes it with it (a rebuild, a disabled service, the resource stop).
--
--  The reading: the game's catalogue anim scene at the book. Its enter playlist plays just before
--  the store opens (the player is seen leafing through the book, then the fade to the fitting
--  room); its exit playlist plays once the player is back at the counter. Nothing here can hold a
--  flow: every wait is bounded, and death or a step away ends the reading, never the visit. A stop
--  deletes the scene at once, without yielding.
--  Raw natives go through WCNative.scene (client/natives/scene.lua).
-- =====================================================================

WCCatalogue = {}
local Cat = WCCatalogue

Cat.MOVE_LIMIT = 3.0 -- metres: a player who walks off stops reading

local scene = nil      -- the running anim scene handle (one at a time)
local generation = 0   -- bumped by every start / stop: a newer reading supersedes an older wait
local props = {}       -- [locationId] = the book prop, for the scene's book role

local function cfg()
    return Config.Clothing and type(Config.Clothing.catalogue) == 'table' and Config.Clothing.catalogue or {}
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

local function isDead(ped)
    local ok, dead = pcall(IsEntityDead, ped)
    return ok and (dead == true or dead == 1)
end

--- Is the catalogue feature on?
function Cat.enabled()
    return cfg().enabled == true
end

--- The book of a clothing location: x, y, z, heading, or nil (not a store, or no book).
function Cat.book(loc)
    if type(loc) ~= 'table' or loc.type ~= 'clothing' or loc.book == nil then return nil end
    return CreatorScene.coords(loc.book)
end

--- Create the book prop of a location (WCServicePoints.build). Returns the entity or nil.
function Cat.spawn(loc)
    if not Cat.enabled() then return nil end
    local x, y, z, h = Cat.book(loc)
    local model = cfg().model
    if not x or type(model) ~= 'string' or model == '' then return nil end
    local ok, entity = pcall(w.entity.create, model, vector4(x, y, z, h), false)
    if not ok or type(entity) ~= 'number' or entity == 0 or not pedExists(entity) then
        WCDebug.warn('catalogue', 'the book of %s failed: %s', tostring(loc.id), tostring(entity))
        return nil
    end
    pcall(FreezeEntityPosition, entity, true)
    props[loc.id] = entity
    return entity
end

--- Delete a book prop (a missing one is fine).
function Cat.remove(entity)
    for id, prop in pairs(props) do
        if prop == entity then props[id] = nil end
    end
    if pedExists(entity) then pcall(w.entity.delete, entity) end
end

--- Free the running scene now (never yields). The player is let go where he stands.
function Cat.stop()
    generation = generation + 1
    if scene then
        pcall(WCNative.scene.deleteAnimScene, scene)
        scene = nil
    end
end

--- Let the player go of the reading before he is moved to the fitting room (never yields). The
--  scene gives him up and is freed. Freeing it alone leaves the game to end his part in it over the
--  next frames, and a move made meanwhile is lost: the scene put him back at the counter, where the
--  editor then framed him from behind the tailor. The flow then clears his tasks and waits a moment
--  before it moves him (WCServiceFlow.RELEASE_MS), and checks the move held before the fade-in.
function Cat.release(ped)
    local handle = scene
    if handle and pedExists(ped) then
        local sc = type(cfg().scene) == 'table' and cfg().scene or {}
        pcall(WCNative.scene.removeAnimSceneEntity, handle, type(sc.entity) == 'string' and sc.entity or 'player', ped)
    end
    Cat.stop()
end

--- Is a reading running (for diagnostics and tests)?
function Cat.active()
    return scene ~= nil
end

--- Start one playlist of the scene at the book with the player in it. Returns the handle or nil.
local function play(loc, playlist, ped)
    local sc = type(cfg().scene) == 'table' and cfg().scene or {}
    local x, y, z, h = Cat.book(loc)
    if not x or type(sc.dict) ~= 'string' or type(playlist) ~= 'string' then return nil end
    local handle = WCNative.scene.createAnimScene(sc.dict, 0, playlist)
    if not handle then return nil end
    -- the scene's origin is on the floor under the book, facing the way the book faces
    WCNative.scene.setAnimSceneOrigin(handle, x, y, z - WCUtil.number(sc.drop, 0, 5, 1.0), h)
    WCNative.scene.setAnimSceneEntity(handle, type(sc.entity) == 'string' and sc.entity or 'player', ped)
    if type(sc.bookEntity) == 'string' and sc.bookEntity ~= '' and pedExists(props[loc.id]) then
        WCNative.scene.setAnimSceneEntity(handle, sc.bookEntity, props[loc.id])
    end
    WCNative.scene.loadAnimScene(handle)
    local loaded = WCUtil.waitUntil(function() return WCNative.scene.isAnimSceneLoaded(handle) or nil end,
        WCUtil.int(sc.loadMs, 0, 10000, 1500), 50)
    if not loaded then
        pcall(WCNative.scene.deleteAnimScene, handle)
        return nil
    end
    WCNative.scene.startAnimScene(handle)
    return handle
end

--- Wait while the reading plays: until it finishes, ms passed, the player died or walked off, or
--  a newer start / a stop superseded it. Always returns (a wait never outlives ms).
local function hold(handle, gen, ped, ms)
    local from = GetEntityCoords(ped)
    WCUtil.waitUntil(function()
        if gen ~= generation or scene ~= handle then return true end
        if WCNative.scene.isAnimSceneFinished(handle) or isDead(ped) or not pedExists(ped) then return true end
        local at = GetEntityCoords(ped)
        if from and at then
            local dx, dy, dz = at.x - from.x, at.y - from.y, at.z - from.z
            if dx * dx + dy * dy + dz * dz > Cat.MOVE_LIMIT * Cat.MOVE_LIMIT then return true end
        end
        return nil
    end, ms, 100)
end

--- The player reads the book before the store opens (yields up to scene.waitMs). The scene keeps
--  running until Cat.stop (the flow stops it under the fade, before the move to the fitting room).
--  Returns true when the reading played.
function Cat.enter(loc)
    Cat.stop()
    if not Cat.enabled() or not Cat.book(loc) then return false end
    local ped = PlayerPedId()
    if not pedExists(ped) or isDead(ped) then return false end
    local sc = type(cfg().scene) == 'table' and cfg().scene or {}
    local gen = generation
    local handle = play(loc, sc.enter, ped)
    if not handle then return false end
    if gen ~= generation then
        pcall(WCNative.scene.deleteAnimScene, handle)
        return false
    end
    scene = handle
    hold(handle, gen, ped, WCUtil.int(sc.waitMs, 0, 10000, 2500))
    return true
end

--- The player closes the book once back at the counter (yields; run it in its own thread). The
--  scene is freed when its exit playlist ends or scene.exitMs passed.
function Cat.exit(loc)
    Cat.stop()
    if not Cat.enabled() or not Cat.book(loc) then return false end
    local ped = PlayerPedId()
    if not pedExists(ped) or isDead(ped) then return false end
    local c = cfg()
    local sc = type(c.scene) == 'table' and c.scene or {}
    -- the exit playlist plays clips of this dictionary: loaded first so it does not pop
    if type(c.exitDict) == 'string' and c.exitDict ~= '' and type(w.requestAnimDict) == 'function' then
        pcall(w.requestAnimDict, c.exitDict, 1500)
    end
    local gen = generation
    local handle = play(loc, sc.exit, ped)
    if not handle then return false end
    if gen ~= generation then
        pcall(WCNative.scene.deleteAnimScene, handle)
        return false
    end
    scene = handle
    hold(handle, gen, ped, WCUtil.int(sc.exitMs, 0, 10000, 4000))
    if scene == handle then Cat.stop() end
    return true
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    pcall(Cat.stop)
end)
