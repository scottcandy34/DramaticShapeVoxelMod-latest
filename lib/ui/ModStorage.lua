-- Sandbox-safe access to this mod's playthrough storage.
-- Runtime modules use logical keys only; the engine owns every real path.
-- Mirrors the pattern used by StadiumBattleFX (anxiousintrovert).

local V = ...
local Storage = {}
local currentGame
local fallback = {}

function Storage.setGame(game)
  if game then currentGame = game end
  return currentGame
end

function Storage.game()
  if currentGame then return currentGame end
  local ok, game = pcall(function() return V.mod.game end)
  if ok then return game end
end

function Storage.active()
  return V.mod and V.mod.storage ~= nil and Storage.game() ~= nil
end

function Storage.read(key)
  local api, game = V.mod and V.mod.storage, Storage.game()
  if api and api.read and game then
    local value, code, message = api:read(game, key)
    if value ~= nil then return value end
    return nil, code, message
  end
  local value = fallback[key]
  if value ~= nil then return value end
  return nil, "storage_unavailable",
    "Mod storage needs an active playthrough."
end

function Storage.write(key, value)
  local api, game = V.mod and V.mod.storage, Storage.game()
  if api and api.write and game then return api:write(game, key, value) end
  -- In-memory fallback for early boot / headless before a game is bound.
  fallback[key] = value
  return true
end

function Storage.delete(key)
  local api, game = V.mod and V.mod.storage, Storage.game()
  if api and api.delete and game then return api:delete(game, key) end
  fallback[key] = nil
  return true
end

return Storage
