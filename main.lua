-- Dramatic Shape Voxel Mod: a full 3D diorama overworld, shipped as a
-- rendering pipeline mod.
--
-- The engine's render_pipelines registry (src/mods/Schemas.lua) lets a mod
-- own part of the frame.  This mod registers two:
--
--   voxel      a drawWorld pipeline.  Instead of the flat tile blit, the
--              overworld's terrain is extruded into real geometry, walked
--              by a depth-buffered 3D camera, with characters as leaning
--              sprite slabs and a shadow map throwing real cast shadows
--              across whatever they land on.  Occlusion is the depth
--              buffer, not a y-sort: walk behind a building and the
--              building is simply in front.
--
--   tiltshift  a worldPresent pipeline -- the stage that post-processes
--              the finished world BEFORE the UI composites over it.  A
--              tilt-shift blur that sells the miniature-model look, on the
--              diorama only, leaving text boxes and menus crisp.
--
-- Everything a display mode needs beyond the two draw functions -- the
-- OFF/15/35/50 ladder, the options rows, the hotkeys, persistence in
-- save.options.pipelines, the free-roam gate, the mutual exclusion with
-- the engine's TILT mode -- is engine plumbing driven by the records
-- below.  This file declares; lib/ draws.
--
-- Voxel mode is presentational: it changes what the world LOOKS like and
-- nothing about what it IS.  TWO rungs are the deliberate exception. 1ST
-- (the camera in the player's own eyes) and 3RD (the same rig, boomed back
-- behind their shoulder) replace the grid WALK with a free,
-- camera-relative one while either is selected (lib/camera/FreeMove.lua), because
-- a camera you can steer with a mouse demands feet that go where it looks.
-- Even there the game is untouched: the walk asks the engine's own
-- collision the same questions a grid step asks, keeps the player's
-- logical cell synced, and fires the engine's own landing pipeline per
-- cell crossed -- warps, encounters, ledges, gates and scripts all run
-- exactly as themselves. Step off the rung and the grid walk is back.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules require each other through V rather than package.path: a
-- mod directory is not on it, and may live inside a mounted .love archive
-- that plain require cannot reach.  Each module is loaded once, with V
-- passed in as its vararg (`local V = ...`).

local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("DRAMATIC_SHAPE: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("DRAMATIC_SHAPE: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

-- ------- diagnostics (mod.storage-backed log)
--
-- Same idea as StadiumBattleFX: a ring of event lines persisted under
-- diagnostics/log in this mod's playthrough storage, exportable via
-- mod.exports.diagnosticLog() and a SAVE DIAGNOSTIC SNAPSHOT options row.
local ModStorage = V.require("ui/ModStorage")
V.storage = ModStorage
local ModLog = V.require("ui/ModLog")
V.log = ModLog.new(mod.log)

-- Compatibility bridge used by gen2-gold-beta-style call sites (V.dlog).
-- Routes into the persistent mod.storage log instead of love.filesystem.
function V.dlog(msg)
  msg = tostring(msg)
  if V.log then V.log:info("%s", msg) end
  print("[DRAMATIC_SHAPE] " .. msg)
end
V.dlog(("main.lua loading path=%s id=%s"):format(
  tostring(mod.path), tostring(mod.id)))

-- Pipeline registration (voxel + tiltshift) and geometry invalidation hooks.
-- See lib/Pipelines.lua.
V.require("Pipelines")

-- Installs for battles, shiny, free-roam inputs, hotkeys, settings, day/night,
-- transitions, and other engine seams. See lib/Bootstrap.lua.
V.require("Bootstrap")

mod.exports.version = "1.5.5"
-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
-- Diagnostic ring buffer (also under mod.storage key diagnostics/log).
mod.exports.diagnosticLog = function()
  return V.log and V.log:contents() or ""
end
mod.exports.flushDiagnostics = function()
  return V.log and V.log:flush()
end

V.log:info("main.lua load complete")
