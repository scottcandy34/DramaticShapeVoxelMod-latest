-- A shiny's battle pic, genuinely recoloured.
--
-- ------- why the tint had to go
--
-- The first answer to "a shiny on the flat art" was a MULTIPLY at draw time,
-- and it was the wrong shape twice over:
--
--   * A multiply can only DARKEN. Shiny Gyarados is blue turning RED; the
--     nearest a multiply gets is a dimmer blue. Every species whose shiny is
--     lighter, or is a hue rotation rather than a dimming, came out looking
--     like the ordinary one with the brightness down -- which is exactly what
--     "shinies don't work in 2D" describes.
--   * It tinted the whole PICS LAYER, both sides at once, because that is the
--     granularity the engine's own draw has. A shiny facing an ordinary mon
--     dimmed its opponent too.
--
-- ------- where the colour actually lives
--
-- The battle pic is not drawn from four-shade art at play time. getImage
-- (src/battle/BattleState.lua:147) snaps the four DMG shades to the species'
-- palette ONCE, with mapPixel, and caches the finished image under
-- `path .. "#" .. pal.name`. By the time anything is drawn the colour is
-- already baked in, and the only way to change it is to hand that bake a
-- different palette -- which also means a different cache NAME, or the shiny
-- and the ordinary pic fight over one cache slot.
--
-- That is the whole of this file. It is the same conclusion ShinyUI reached
-- for the status screen ("the palette is what has to move"), applied to the
-- one other place a Pokemon is drawn flat.
--
-- ------- the seam
--
-- monPalette (BattleState.lua:216) is a local, so it cannot be wrapped. What
-- it calls -- PaletteFX.monPal and PaletteFX.monPalName -- are not, and they
-- are asked in that order for every battle pic the game builds.
--
-- Neither is told WHICH Pokemon is being drawn; both take a species. The
-- individual arrives one call earlier, at the engine's own `pokemon.sprite`
-- hook, which carries ctx.mon -- so the hook notes "the pic about to be built
-- is this shiny mon's" and the two palette wraps consume that note. A flag
-- rather than an argument, because the argument does not exist.
--
-- It is consumed ONCE, and matched on species as well, so a leak (monPalette
-- returns early when a species has no palette at all, and then never asks for
-- the name) cannot recolour somebody else's pic -- the worst case is one
-- extra ordinary pic built under a shiny cache key, which the next call
-- corrects.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Shiny = V.require("Shiny")
local ShinyPalette = V.require("ShinyPalette")

local ShinyPics = {}

-- { species = <name>, dex = <n> } while a shiny's pic is being built
local pending = nil

-- The suffix that makes the shiny pic its own cache entry. Part of the
-- palette NAME rather than the path, because the name is what getImage keys
-- on and the path is real art on disk that this mod does not add to.
ShinyPics.SUFFIX = "-SHINY"

-- ------- what the sprite hook notices
--
-- Called for every battle pic the engine resolves. Returns nothing: the point
-- is the note it leaves.
function ShinyPics.note(ctx)
  pending = nil
  if type(ctx) ~= "table" or ctx.kind ~= "battle" then return end
  local mon = ctx.mon
  if not (mon and Shiny.isShiny(mon)) then return end
  local def = ctx.data and ctx.data.pokemon and ctx.data.pokemon[ctx.species]
  local dex = def and def.dex
  if not dex then return end
  pending = { species = ctx.species, dex = dex }
end

-- Whether the pic currently being built is a shiny's -- for a test, and for
-- the palette wraps below.
function ShinyPics.pendingDex(species)
  if pending and pending.species == species then return pending.dex end
  return nil
end

-- ------- the palette wraps
--
-- Idempotent by sentinel, the pattern every wrap in this mod uses.
function ShinyPics.install()
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok or type(PaletteFX) ~= "table" then return false end
  if PaletteFX.dramaticShapeShiny then return true end
  local innerPal = PaletteFX.monPal
  local innerName = PaletteFX.monPalName
  if type(innerPal) ~= "function" or type(innerName) ~= "function" then
    return false
  end

  function PaletteFX.monPal(data, species, transformed, ...)
    local cols = innerPal(data, species, transformed, ...)
    local dex = ShinyPics.pendingDex(species)
    if not (cols and dex) then
      -- nothing to recolour, and monPalette's early return means the name
      -- wrap below may never run: drop the note here rather than leave it
      -- for whoever asks next
      if not cols then pending = nil end
      return cols
    end
    local fn = ShinyPalette.paletteTransform(dex)
    if not fn then return cols end
    -- ------- the first and last shades DO NOT MOVE
    --
    -- A Game Boy mon palette is four shades and only the middle two are the
    -- Pokemon. The first is the PAPER -- 255,239,255 in every species'
    -- palette in the dataset, the white the pic sits on -- and the last is
    -- the INK, 25,16,16, the outline every pic is drawn with. Both are shared
    -- constants, not colours anybody chose for this animal.
    --
    -- Sliding them is what a shiny looks like when it is broken: shiny Golbat
    -- rotates far enough that its white became NAVY (31,34,93) and the pic
    -- read as a mon on a blue card rather than a green Golbat. Stadium's
    -- slides were authored for model textures, which have no paper and no
    -- outline in them, so there was nothing there to warn against it.
    --
    -- COPIED, never written through, for the rest. monPal hands back the
    -- dataset's own palette table, and mutating it would recolour every
    -- Pokemon of the species everywhere for the rest of the process -- the
    -- same trap ShinyUI's summary wrap documents.
    local last = #cols
    local out = {}
    for i, c in ipairs(cols) do
      if type(c) == "table" and c[1] and i > 1 and i < last then
        local r, g, b = fn(c[1], c[2], c[3])
        out[i] = { r, g, b }
      else
        out[i] = c
      end
    end
    return out
  end

  function PaletteFX.monPalName(data, species, ...)
    local name = innerName(data, species, ...)
    local dex = ShinyPics.pendingDex(species)
    pending = nil                       -- consumed: one pic, one note
    if not (name and dex) then return name end
    if not ShinyPalette.paletteTransform(dex) then return name end
    return name .. ShinyPics.SUFFIX
  end

  PaletteFX.dramaticShapeShiny = true
  return true
end

return ShinyPics
