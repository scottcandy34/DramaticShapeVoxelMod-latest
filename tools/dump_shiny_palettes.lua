-- Dump every species' ADVANCED palette and its shiny-shifted twin, as JSON.
--
--   luajit mods/DramaticShapeVoxelMod/tools/dump_shiny_palettes.lua > pals.json
--
-- Run from the PROJECT ROOT.
--
-- The game's battle pics are four-shade DMG grey (0/85/170/255) -- there is
-- no colour in the art at all. Under ADVANCED (`redpp`) the colour comes
-- entirely from a per-species palette applied over the top, which is why a
-- shiny SPRITE is a shifted palette rather than repainted art. This dumps
-- both halves so a comparison sheet can be built from them.
--
-- Reads the real generated data directly rather than going through
-- PaletteFX: the headless fixture dataset carries FIXMON placeholders, not
-- the 151, so a dump driven through it is of nothing.

local POK = dofile("data/generated/pokemon.lua")
local PACK = dofile("data/palettes_gbc.lua")

local V = { path = "mods/DramaticShapeVoxelMod" }
local loaded = {}
function V.require(name)
  if loaded[name] == nil then
    loaded[name] = assert(loadfile(V.path .. "/lib/" .. name .. ".lua"))(V)
  end
  return loaded[name]
end
V.mod = { log = { warn = function() end, info = function() end } }
local ShinyPalette = V.require("shiny/ShinyPalette")

local mons = POK.pokemon or POK
local rows = {}
for species, def in pairs(mons) do
  local dex = type(def) == "table" and def.dex
  if type(species) == "string" and dex and dex >= 1 and dex <= 151 then
    rows[#rows + 1] = { species = species, dex = dex,
                        name = def.name or species }
  end
end
table.sort(rows, function(a, b) return a.dex < b.dex end)

local function esc(s) return (tostring(s):gsub('"', '\\"')) end

io.write("[\n")
for i, r in ipairs(rows) do
  local palName = PACK.pokemon[r.species]
  local pal = palName and PACK.palettes[palName]
  if pal then
    local fn = ShinyPalette.paletteTransform(r.dex)
    local n, s = {}, {}
    for k = 1, 4 do
      local c = pal[k] or pal[#pal]
      local cr, cg, cb = c[1], c[2], c[3]
      n[k] = ("[%d,%d,%d]"):format(cr, cg, cb)
      if fn then
        local sr, sg, sb = fn(cr, cg, cb)
        s[k] = ("[%d,%d,%d]"):format(sr, sg, sb)
      else
        s[k] = n[k]
      end
    end
    io.write(('%s{"dex":%d,"species":"%s","name":"%s","pal":"%s",'
              .. '"normal":[%s],"shiny":[%s],"shifted":%s}')
      :format(i > 1 and ",\n" or "", r.dex, esc(r.species), esc(r.name),
              esc(palName), table.concat(n, ","), table.concat(s, ","),
              fn and "true" or "false"))
  end
end
io.write("\n]\n")
