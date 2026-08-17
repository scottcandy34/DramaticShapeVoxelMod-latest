-- Emit what tools/shiny_pic_sheet.py needs to bake the battle pics.
--
--   luajit mods/DramaticShapeVoxelMod/tools/shiny_pic_dump.lua > pics.tsv
--
-- Run from the PROJECT ROOT. One species per line, tab separated:
--
--   dex  name  spriteFront  kind  n1 n2 n3 n4  s1 s2 s3 s4
--
-- where each colour is r,g,b. TSV rather than JSON because there is no JSON
-- encoder in this tree and the payload is eight colours and a path.
--
-- The COLOURS are the point: they come from the real wrap (ShinyPics over
-- PaletteFX.monPal), not from a second implementation of it, so what the
-- sheet shows is what the game bakes.

package.path = "./?.lua;./?/init.lua;" .. package.path

local MOD = "mods/DramaticShapeVoxelMod"

local loaded, V = {}, {}
function V.require(n)
  if loaded[n] == nil then
    loaded[n] = assert(loadfile(MOD .. "/lib/" .. n .. ".lua"))(V)
  end
  return loaded[n]
end
function V.data(n) return assert(loadfile(MOD .. "/data/" .. n .. ".lua"))(V) end
V.path = MOD
V.mod = { id = "DRAMATIC_SHAPE",
          log = { warn = function() end, info = function() end } }

local ShinyPics = V.require("shiny/ShinyPics")
local ShinyPalette = V.require("shiny/ShinyPalette")
local PaletteFX = require("src.render.PaletteFX")

local Data = {
  pokemon = dofile("data/generated/pokemon.lua"),
  palettes = dofile("data/generated/palettes.lua"),
}

assert(ShinyPics.install(), "the palette wrap did not install")

local SHINY = { dvs = { attack = 10, defense = 10, speed = 10,
                        special = 10, hp = 15 } }

local rows = {}
for name, def in pairs(Data.pokemon) do
  if type(def) == "table" and def.dex and def.dex >= 1 and def.dex <= 151
     and def.spriteFront then
    rows[#rows + 1] = { name = name, dex = def.dex, path = def.spriteFront }
  end
end
table.sort(rows, function(a, b) return a.dex < b.dex end)

local function cols(t)
  local o = {}
  for i = 1, 4 do
    local c = t and t[i]
    o[i] = (type(c) == "table" and c[1])
           and ("%d,%d,%d"):format(c[1], c[2], c[3]) or "0,0,0"
  end
  return table.concat(o, "\t")
end

for _, row in ipairs(rows) do
  local normal = PaletteFX.monPal(Data, row.name)
  ShinyPics.note({ kind = "battle", species = row.name, mon = SHINY,
                   data = Data })
  local shiny = PaletteFX.monPal(Data, row.name)
  local spec = ShinyPalette.forDex(row.dex)
  local kind = spec and (spec.lut and "table" or "slide") or "none"
  io.write(("%d\t%s\t%s\t%s\t%s\t%s\n")
           :format(row.dex, row.name, row.path, kind, cols(normal),
                   cols(shiny)))
end
