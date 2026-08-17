-- Voxel world mode: whether the sun casts at all.
--
-- lib/ShadowMap renders the whole scene a second time from the light every
-- frame the view or a pose changes, at up to 2048 squared, and every
-- surface in the main pass then takes four taps at it. That is the single
-- most expensive thing this mode does after the geometry itself -- and on a
-- phone, or an old laptop, it is the difference between the diorama running
-- and the diorama stuttering. So it gets a row.
--
-- OFF means OFF, not "fall back": VoxelScene keeps flat decal shadows for a
-- driver that cannot make the map (see Voxel3D.beginShadows), and those are
-- a stand-in for a machine that wanted shadows and could not have them.
-- A player who has just switched them off wants no shadow under anybody,
-- which is what this row gives -- see ShadowMap.wanted, the one gate both
-- halves hang off.
--
-- This file owns the toggle rather than the drawing: the value, where it
-- persists, and the row the player finds it on -- exactly as VoxelGrid does
-- for the wireframe.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local Shadows = {}

-- the key under options.modOptions.DRAMATIC_SHAPE, shared by the row in
-- OPTIONS and the mod manager's own settings page for this mod
Shadows.KEY = "shadows"
Shadows.LABEL = "SHADOWS"

-- ON is values[1] and so the default: cast shadows are what the mode is
-- for as much as the geometry is -- a world where a building throws
-- nothing reads as flat however many voxels it is made of. The row is for
-- the machine that cannot carry them, not a look anybody is choosing.
Shadows.setting = ModSetting.new(Shadows.KEY, Shadows.LABEL,
                                 { true, false }, { "ON", "OFF" })

function Shadows.enabled()
  return Shadows.setting:get() and true or false
end

function Shadows.set(enabled, game)
  return Shadows.setting:setIndex(enabled and 1 or 2, game)
end

function Shadows.toggle(game)
  return Shadows.setting:cycle(game)
end

function Shadows.sync(value)
  Shadows.setting:sync(value and true or false)
end

function Shadows.row()
  return Shadows.setting:row()
end

return Shadows
