-- One-time Android preparation for persistent voxel BODY geometry.
--
-- Large map generation is moved off the traversal path. Every map commits
-- independently, so closing or skipping this opaque screen keeps completed
-- work and the next run resumes at the first missing fingerprint.

local V = ...

local Budget = V.require("BuildBudget")
local ChunkMesher = V.require("ChunkMesher")
local MeshCache = V.require("VoxelMeshCache")
local Structures = V.require("Structures")

local Screen = {}
Screen.__index = Screen
Screen.isOpaque = true

local W, H = 160, 144
local MIN_AREA = 24 -- blocks: routes/towns/forest, not tiny interiors
local SLICE = 0.018
local HOLD = 0.65

local asked = false
local active = false
local Font = nil

local function font()
  if Font then return Font end
  local ok, value = pcall(require, "src.render.Font")
  if ok then Font = value end
  return Font
end

local function text(value, x, y)
  local f = font()
  if not f then return end
  love.graphics.setColor(0, 0, 0, 1)
  f.draw(tostring(value), math.floor(x), math.floor(y))
end

local function centred(value, y)
  local f = font()
  if not f then return end
  value = tostring(value)
  text(value, (W - f.width(value)) / 2, y)
end

local function candidates(game)
  local ids, signatureParts = {}, {}
  local maps = game and game.data and game.data.maps or {}
  for id, def in pairs(maps) do
    local width = type(def) == "table" and tonumber(def.width) or nil
    local height = type(def) == "table" and tonumber(def.height) or nil
    -- Some engine revisions leave dimensions to MapLoader. Keep those ids and
    -- decide after load rather than silently missing an outdoor map.
    if not (width and height) or width * height >= MIN_AREA then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local def = maps[id]
    signatureParts[#signatureParts + 1] = table.concat({
      tostring(id),
      tostring(type(def) == "table" and def.width or "?"),
      tostring(type(def) == "table" and def.height or "?"),
      tostring(type(def) == "table" and def.tileset or "?"),
    }, ":")
  end
  return ids, MeshCache.warmupSignature(signatureParts)
end

local function trimLoadedMaps(game, MapLoader)
  if not (MapLoader and MapLoader.trim) then return end
  local protected = {}
  local ow = game and game.overworld
  if ow and ow.map and ow.map.id then protected[ow.map.id] = true end
  for _, nb in ipairs((ow and ow.neighbors) or {}) do
    if nb.map and nb.map.id then protected[nb.map.id] = true end
  end
  pcall(MapLoader.trim, protected)
end

function Screen.new(game, ids, signature)
  if not ids then ids, signature = candidates(game) end
  return setmetatable({
    game = game,
    ids = ids,
    signature = signature,
    index = 1,
    done = 0,
    built = 0,
    skipped = 0,
    failed = 0,
    current = nil,
    currentName = "",
    co = nil,
    hold = 0,
    finished = false,
  }, Screen)
end

function Screen:enter()
  active = true
end

function Screen:exit()
  active = false
end

local function pop(self)
  active = false
  if self.game and self.game.stack and self.game.stack:top() == self then
    self.game.stack:pop()
  end
end

local function nextMap(self)
  local MapLoader = require("src.world.MapLoader")
  while self.index <= #self.ids do
    local id = self.ids[self.index]
    self.index = self.index + 1
    local ok, map = pcall(MapLoader.load, self.game.data, id)
    if ok and map and map.def then
      local area = (tonumber(map.def.width) or 0)
                   * (tonumber(map.def.height) or 0)
      if area >= MIN_AREA then
        self.current = map
        self.currentName = tostring(map.id or id)
        if ChunkMesher.bodyCachedOnDisk(map) then
          self.done = self.done + 1
          self.skipped = self.skipped + 1
          Structures.invalidate(map.id)
          MeshCache.forget(map.id)
          self.current = nil
          trimLoadedMaps(self.game, MapLoader)
        else
          self.co = coroutine.create(function()
            return ChunkMesher.precompileBody(map)
          end)
          return true
        end
      else
        self.done = self.done + 1
      end
    else
      self.done = self.done + 1
      self.failed = self.failed + 1
    end
  end
  return false
end

function Screen:update()
  if self.finished then
    self.hold = self.hold + 1 / 60
    if self.hold >= HOLD then pop(self) end
    return
  end

  local input = self.game and self.game.input
  if input and input.wasPressed and input:wasPressed("b") then
    pop(self)
    return
  end

  if not self.co then
    if not nextMap(self) then
      if self.failed == 0 then MeshCache.markWarmupComplete(self.signature) end
      self.finished = true
      self.hold = 0
      return
    end
    if not self.co then return end
  end

  Budget.begin(self.co, SLICE)
  local ok, result = coroutine.resume(self.co)
  Budget.finish()
  if not ok then
    self.failed = self.failed + 1
    pcall(function()
      V.log:warn("voxel cache: %s failed: %s",
                 tostring(self.currentName), tostring(result))
    end)
  end

  if not ok or coroutine.status(self.co) == "dead" then
    if ok and result then
      self.built = self.built + 1
    elseif ok then
      self.failed = self.failed + 1
    end
    self.done = self.done + 1
    if self.current and self.current.id then
      Structures.invalidate(self.current.id)
      MeshCache.forget(self.current.id)
    end
    local okLoader, MapLoader = pcall(require, "src.world.MapLoader")
    if okLoader then trimLoadedMaps(self.game, MapLoader) end
    self.current, self.co = nil, nil
    collectgarbage("step", 300)
  end
end

function Screen:onKeyPressed(key)
  if key == "escape" or key == "backspace" or key == "x" then
    pop(self)
    return true
  end
  return false
end

function Screen:draw()
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", 0, 0, W, H)
  centred("VOXEL CACHE", 18)
  centred("ONE-TIME SETUP", 32)

  local total = math.max(1, #self.ids)
  local fraction = math.max(0, math.min(1, self.done / total))
  if self.finished then fraction = 1 end
  local x, y, width, height = 20, 66, 120, 9
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", x - 1, y - 1, width + 2, height + 2)
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", x, y, width, height)
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", x, y, math.floor(width * fraction + 0.5), height)

  if self.finished then
    if self.failed == 0 then
      centred("READY", 86)
      centred("3D MAPS CACHED", 100)
    else
      centred("CACHE PARTIAL", 86)
      centred(("%d FAILED"):format(self.failed), 100)
    end
  else
    centred(("%d/%d"):format(self.done, #self.ids), 84)
    local name = self.currentName ~= "" and self.currentName or "SCANNING MAPS"
    if #name > 18 then name = name:sub(1, 18) end
    centred(name, 98)
    centred("KEEP APP OPEN", 112)
    centred("B: SKIP FOR NOW", 128)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Screen.active()
  return active
end

function Screen.maybePush()
  if asked then return false end
  if not ChunkMesher.persistentCacheAvailable() then
    asked = true
    return false
  end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.stack and Game.overworld) then return false end
  if Game.stack:top() ~= Game.overworld then return false end
  local Voxel = V.require("VoxelState")
  if not (Voxel.active and Voxel.active()) then return false end

  asked = true
  local ids, signature = candidates(Game)
  local complete = MeshCache.warmupComplete(signature)
  local map = Game.overworld.map
  local area = map and map.def
               and (tonumber(map.def.width) or 0) * (tonumber(map.def.height) or 0)
               or 0
  if complete and (area < MIN_AREA or ChunkMesher.bodyCachedOnDisk(map)) then
    return false
  end
  Game.stack:push(Screen.new(Game, ids, signature))
  return true
end

function Screen._reset()
  asked, active = false, false
end

Screen._test = { candidates = candidates, minArea = MIN_AREA }

return Screen
