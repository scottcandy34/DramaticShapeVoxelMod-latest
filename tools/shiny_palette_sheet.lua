-- Every species' battle palette, normal beside shiny, as one HTML page.
--
--   luajit mods/DramaticShapeVoxelMod/tools/shiny_palette_sheet.lua
--
-- Run from the PROJECT ROOT. Writes
-- mods/DramaticShapeVoxelMod/.claude/shiny_update/palettes.html
--
-- ------- what it is actually showing
--
-- Not the shiny COLOURS table (data/shiny_colors.lua) -- that is Stadium's
-- values for a model's texels, and it is already checked against the Python
-- that produced it. This is the other end: what those values become after
-- ShinyPics puts them through the engine's four-shade battle palette, which
-- is where the flat art gets its colour and the only place a mistake there
-- shows up.
--
-- Two rules are visible in the output and both were bugs first:
--
--   * shade 1 and shade 4 never move. They are the shared paper (255,239,255)
--     and the shared ink (25,16,16), not colours anybody chose for this
--     animal, and sliding them turned shiny Golbat's white navy.
--   * the five TABLE species rotate hue like everyone else, because their
--     slide is measured back out of their lookup table rather than falling
--     back to a multiply that can only darken.
--
-- The COLORS pack is whatever PaletteFX defaults to in a headless process
-- (the GBC pack). The RED++ pack is a different set of four colours per
-- species and would want its own sheet.

package.path = "./?.lua;./?/init.lua;" .. package.path

local MOD = "mods/DramaticShapeVoxelMod"
local OUT = MOD .. "/.claude/shiny_update/palettes.html"

-- ------- the mod namespace, enough of it (see tests/shiny_test.lua)
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

-- Def/Spd/Spc all 10 and Atk 10 is the Gen 2 pattern src/pokemon/Stats.lua
-- reads; any mon carrying it is shiny as far as the engine is concerned.
local SHINY = { dvs = { attack = 10, defense = 10, speed = 10,
                        special = 10, hp = 15 } }

-- ------- collect, in dex order
local rows = {}
for name, def in pairs(Data.pokemon) do
  if type(def) == "table" and def.dex and def.dex >= 1 and def.dex <= 151 then
    rows[#rows + 1] = { name = name, dex = def.dex }
  end
end
table.sort(rows, function(a, b) return a.dex < b.dex end)

local function hex(c)
  return ("#%02x%02x%02x"):format(c[1] or 0, c[2] or 0, c[3] or 0)
end

local moved, still, missing = 0, 0, 0

for _, row in ipairs(rows) do
  row.normal = PaletteFX.monPal(Data, row.name)
  row.palName = PaletteFX.monPalName(Data, row.name)
  ShinyPics.note({ kind = "battle", species = row.name, mon = SHINY,
                   data = Data })
  row.shiny = PaletteFX.monPal(Data, row.name)
  row.shinyName = PaletteFX.monPalName(Data, row.name)

  local spec = ShinyPalette.forDex(row.dex)
  row.kind = spec and (spec.lut and "table" or "slide") or "none"
  local slide = spec and (spec.lut and ShinyPalette.lutSlide(row.dex)
                          or spec.slide)
  row.slide = slide

  if not (row.normal and row.shiny) then
    missing = missing + 1
  else
    -- how far the two middle shades actually travelled, as the largest
    -- per-channel step: a row that reads 0 is a shiny nobody can see
    local d = 0
    for i = 2, #row.normal - 1 do
      local a, b = row.normal[i], row.shiny[i]
      if type(a) == "table" and type(b) == "table" then
        for k = 1, 3 do d = math.max(d, math.abs((a[k] or 0) - (b[k] or 0))) end
      end
    end
    row.delta = d
    if d >= 8 then moved = moved + 1 else still = still + 1 end
  end
end

-- ------- the page
local out = {}
local function w(s) out[#out + 1] = s end

w([[<!doctype html>
<html><head><meta charset="utf-8">
<title>Shiny battle palettes</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 13px/1.5 ui-monospace, Menlo, Consolas, monospace;
         margin: 24px; background: #14151a; color: #e6e6ea; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  p.lede { color: #9aa0aa; max-width: 62em; margin: 0 0 20px; }
  table { border-collapse: collapse; }
  th, td { padding: 3px 10px 3px 0; text-align: left; vertical-align: middle;
           white-space: nowrap; }
  th { color: #9aa0aa; font-weight: 400; border-bottom: 1px solid #2a2c34; }
  tr:hover { background: #1c1e26; }
  .sw { display: inline-block; width: 26px; height: 20px;
        border: 1px solid #000; vertical-align: middle; }
  .fixed { opacity: .45; }
  .kind-table { color: #ffc46b; }
  .kind-slide { color: #7fb2ff; }
  .flat { color: #ff8a8a; }
  td.n { text-align: right; color: #9aa0aa; }
</style></head><body>
<h1>Shiny battle palettes &mdash; normal beside shiny</h1>
<p class="lede">What <code>ShinyPics</code> hands the battle pic cache, per
species. The first and last shades are the shared paper and ink and are held
still on purpose (shown faded); only the two middle shades are the Pokemon.
<span class="kind-slide">slide</span> species use Stadium's declared values;
the five <span class="kind-table">table</span> species use a slide measured
back out of their own lookup table, which is what lets Gyarados reach red.
&Delta; is the largest per-channel step across the two middle shades &mdash;
a row in <span class="flat">red</span> barely moved.</p>
]])

w(("<p class=\"lede\">%d species &middot; %d visibly recoloured &middot; "
   .. "%d barely moved &middot; %d with no palette</p>\n")
  :format(#rows, moved, still, missing))

w("<table><tr><th>#</th><th>species</th><th>pal</th><th>kind</th>"
  .. "<th>slide h / s / l</th><th>normal</th><th>shiny</th><th>&Delta;</th>"
  .. "</tr>\n")

for _, row in ipairs(rows) do
  local function swatches(cols)
    if not cols then return "&mdash;" end
    local o = {}
    for i, c in ipairs(cols) do
      local fixed = (i == 1 or i == #cols) and " fixed" or ""
      if type(c) == "table" and c[1] then
        o[#o + 1] = ("<span class=\"sw%s\" style=\"background:%s\" "
                     .. "title=\"%d,%d,%d\"></span>")
                    :format(fixed, hex(c), c[1], c[2], c[3])
      end
    end
    return table.concat(o)
  end
  local s = row.slide
  w(("<tr><td class=\"n\">%03d</td><td>%s</td><td>%s</td>"
     .. "<td class=\"kind-%s\">%s</td><td>%s</td><td>%s</td><td>%s</td>"
     .. "<td class=\"n%s\">%s</td></tr>\n")
    :format(row.dex, row.name, tostring(row.palName), row.kind, row.kind,
            s and ("%.0f&deg; / %+.1f / %+.1f"):format(s.h or 0, s.s or 0,
                                                       s.l or 0) or "&mdash;",
            swatches(row.normal), swatches(row.shiny),
            (row.delta and row.delta < 8) and " flat" or "",
            row.delta and tostring(row.delta) or "&mdash;"))
end

w("</table></body></html>\n")

local f = assert(io.open(OUT, "wb"))
f:write(table.concat(out))
f:close()

print(("%s -- %d species, %d recoloured, %d barely moved, %d no palette")
      :format(OUT, #rows, moved, still, missing))
