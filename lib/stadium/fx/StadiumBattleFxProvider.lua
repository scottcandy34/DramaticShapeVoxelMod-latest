-- Optional StadiumBattleFX Battle Presentation API v1 arena provider.

local V = ...
local OverworldBattle = V.require("battle/OverworldBattle")
local Provider = { registered = false, fallback = nil }

local function findMod(id)
  local finder = V.mod and V.mod.find
  if type(finder) ~= "function" then return nil end
  local ok, handle = pcall(finder, id)
  if ok and handle then return handle end
  ok, handle = pcall(finder, V.mod, id)
  return ok and handle or nil
end

function Provider:arena(context)
  if not OverworldBattle.providerAvailable(context and context.battle) then
    return self.fallback
  end
  return OverworldBattle.arena()
end

function Provider:begin(context)
  return OverworldBattle.providerBegin(context and context.battle)
    or self.fallback
end

function Provider:render(context, arena, drawActors)
  return OverworldBattle.providerRender(context and context.battle, drawActors)
    or self.fallback
end

function Provider:finish()
  OverworldBattle.providerFinish()
end

function Provider.register()
  if Provider.registered then return true end
  local handle = findMod("STADIUM_BATTLE_FX")
  local api = handle and handle.exports and handle.exports.battles
  if not (api and api.version == 1
      and type(api.registerComponent) == "function") then return false end
  Provider.fallback = api.FALLBACK
  local ok, id = pcall(api.registerComponent, api, V.mod.id, "arena",
    "voxel-map", {
      label = "DRAMATIC SHAPE VOXEL MAP",
      description = "Dramatic Shape's staged voxel-map arena; models and "
        .. "other features remain independently selectable.",
      provider = Provider,
      available = function(context)
        return OverworldBattle.providerAvailable(context and context.battle)
      end,
    })
  if not ok then
    if V.mod.log and V.mod.log.warn then
      V.mod.log:warn("StadiumBattleFX arena registration failed: %s", tostring(id))
    end
    return false
  end
  Provider.registered = true
  Provider.id = id
  return true
end

return Provider
