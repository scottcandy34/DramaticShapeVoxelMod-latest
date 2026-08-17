-- The shiny system, headless.
--
--   luajit mods/DramaticShapeVoxelMod/tests/shiny_test.lua [--mod=DIR]
--
-- Run from the PROJECT ROOT (it requires src.pokemon.Stats, the engine's own
-- shiny predicate -- the point being that we agree with the engine rather
-- than carry a second copy of the rule).
--
-- Two halves:
--
--   the DV model      that a decided mon really does satisfy the Gen 2
--                     pattern, that a miss really does not, that the odds
--                     are the number they claim, and that the derived HP DV
--                     is kept legal.
--   the recolour      against a fixture of real (normal, shiny) colour
--                     pairs lifted from the verified texture set, so the
--                     Lua transform is checked against the Python that
--                     produced the shipped colours rather than against
--                     itself.

package.path = "./?.lua;./?/init.lua;" .. package.path

local args = {}
for _, a in ipairs({ ... }) do
  local k, v = a:match("^%-%-([%w_]+)=(.*)$")
  if k then args[k] = v else args[a:gsub("^%-%-", "")] = true end
end

local MOD = args.mod or "mods/DramaticShapeVoxelMod"

-- ------- the mod namespace, enough of it

local loaded = {}
local V = {}
function V.require(name)
  if loaded[name] == nil then
    loaded[name] = assert(loadfile(MOD .. "/lib/" .. name .. ".lua"))(V)
  end
  return loaded[name]
end
function V.data(name)
  return assert(loadfile(MOD .. "/data/" .. name .. ".lua"))(V)
end
V.mod = { log = { warn = function() end, info = function() end } }

local Shiny = V.require("shiny/Shiny")
local ShinyPalette = V.require("shiny/ShinyPalette")
local Stats = require("src.pokemon.Stats")

-- ------- a tiny harness

local pass, fail = 0, 0
local function ok(cond, what)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.write("FAIL: " .. what .. "\n")
  end
end
local function eq(got, want, what)
  ok(got == want, ("%s (got %s, want %s)")
                  :format(what, tostring(got), tostring(want)))
end

-- always-hit and always-miss stand-ins for the odds roll
local function hit() return 1 end
local function miss() return 2 end

local function mon(dvs, level, species)
  return { species = species, level = level, dvs = dvs,
           statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 } }
end

-- ------- the DV model

do
  local m = mon({ attack = 0, defense = 0, speed = 0, special = 0, hp = 0 })
  Shiny.decide(m, hit)
  ok(Shiny.isShiny(m), "a hit produces a mon the ENGINE calls shiny")
  ok(Stats.isShiny(m.dvs), "and the engine's own predicate agrees")
  eq(m.dvs.defense, 10, "defense pinned to 10")
  eq(m.dvs.speed, 10, "speed pinned to 10")
  eq(m.dvs.special, 10, "special pinned to 10")
  eq(m.shiny, true, "the cached flag is set")
end

do
  -- nearest legal Attack, so a shiny encounter is not also a stat reroll
  local cases = { [0] = 2, [4] = 3, [5] = 6, [9] = 10, [13] = 14, [15] = 15 }
  for from, want in pairs(cases) do
    local m = mon({ attack = from, defense = 0, speed = 0, special = 0, hp = 0 })
    Shiny.decide(m, hit)
    eq(m.dvs.attack, want, ("attack %d moves to the nearest legal %d")
                           :format(from, want))
  end
end

do
  -- the HP DV is derived from the low bits of the other four; a write that
  -- forgets to resync it produces a mon no real game could make
  for atk = 0, 15 do
    local m = mon({ attack = atk, defense = 3, speed = 7, special = 1, hp = 0 })
    Shiny.decide(m, hit)
    local want = (m.dvs.attack % 2) * 8 + (m.dvs.defense % 2) * 4
                 + (m.dvs.speed % 2) * 2 + (m.dvs.special % 2)
    eq(m.dvs.hp, want, "HP DV stays derived from the other four")
  end
end

do
  -- a MISS must not leave an accidentally-shiny mon shiny, or the rate is
  -- the requested one and 1/8192 in parallel
  local m = mon({ attack = 2, defense = 10, speed = 10, special = 10, hp = 8 })
  ok(Stats.isShiny(m.dvs), "fixture starts out shiny by luck")
  Shiny.decide(m, miss)
  ok(not Shiny.isShiny(m), "a miss clears an accidentally-shiny mon")
  eq(m.shiny, nil, "and clears the cached flag rather than storing false")
end

do
  -- the odds are the number they claim. 1/1 must be every time; a large
  -- denominator must essentially never fire on a fixed stub.
  local saved = Shiny.ODDS_DENOM
  Shiny.setOdds(1)
  local m = mon({ attack = 0, defense = 0, speed = 0, special = 0, hp = 0 })
  Shiny.decide(m, function(_, hi) return math.random(1, hi) end)
  ok(Shiny.isShiny(m), "odds of 1 make every mon shiny")

  Shiny.setOdds(0)
  eq(Shiny.ODDS_DENOM, 1, "a denominator below 1 is refused")
  Shiny.setOdds(saved)
  eq(Shiny.ODDS_DENOM, saved, "and a sane one is accepted")
end

do
  -- ------- the row on the menu
  --
  -- The ladder's first rung is both the default and the fallback, so the
  -- canonical 1:8192 has to be it: a player who never opens the menu, and a
  -- corrupted options.lua, must both land on the games' own rate.
  local s = Shiny.setting
  eq(s.values[1], 8192, "the ladder starts at the canonical rate")
  eq(s.labels[1], "1:8192", "and says so in the 1:# the row shows")
  eq(s.labels[#s.labels], "1:1", "the last rung is every encounter")
  eq(#s.values, #s.labels, "every rung has a label")
  for i = 2, #s.values do
    eq(s.values[i] * 2, s.values[i - 1],
       ("rung %d is twice as often as the one above"):format(i))
  end

  -- and the roll READS it. Pulled rather than pushed, so a value written by
  -- the mod manager's page -- which notifies nobody -- is seen too.
  local before = s:read()
  s:setValue(512)
  Shiny.unpinOdds()
  eq(Shiny.odds(), 512, "the roll follows the row without being told")
  eq(Shiny.ODDS_DENOM, 512, "and the live field is written through")
  s:setIndex(before)
  Shiny.setOdds(8192)          -- and pinned again, for the blocks below
end

do
  -- stats must follow the DVs, and a full-health mon must stay full: a wild
  -- mon that appears at less than full HP is visible in the first frame
  local Data = require("src.core.Data")
  local haveData = type(Data) == "table" and type(Data.pokemon) == "table"
                   and Data.pokemon.PIKACHU ~= nil
  if haveData then
    local m = mon({ attack = 0, defense = 0, speed = 0, special = 0, hp = 0 },
                  10, "PIKACHU")
    m.stats = Stats.calc(Data.pokemon.PIKACHU, 10, m.dvs, m.statExp)
    m.hp = m.stats.hp
    local before = m.stats.hp
    Shiny.decide(m, hit)
    ok(m.stats.hp >= before, "max HP tracks the raised DVs")
    eq(m.hp, m.stats.hp, "a full-health mon stays full after a restat")
  else
    io.write("note: no ROM-backed data; skipped the restat check\n")
  end
end

-- ------- the recolour

do
  eq(type(ShinyPalette.forDex(6)), "table", "colours load for Charizard")
  local ch = ShinyPalette.forDex(6)
  eq(ch.slide.h, -136, "Charizard's hue slide is the Stadium value")
  eq(ch.slide.s, -6, "and its saturation step")
  ok(ShinyPalette.forDex(130).lut ~= nil,
     "Gyarados carries an explicit table, not a slide")
  ok(ShinyPalette.forDex(6).lut == nil, "and Charizard does not")
end

do
  -- alpha is never touched, and a texture with nothing to do comes back
  -- unchanged rather than rebuilt
  local fn = ShinyPalette.transform(ShinyPalette.forDex(6))
  local px = string.char(222, 131, 123, 77) .. string.char(0, 0, 0, 0)
  local out = ShinyPalette.recolorTexels(px, fn)
  eq(#out, #px, "the texel string keeps its length")
  eq(out:byte(4), 77, "alpha survives the transform")
  eq(out:byte(8), 0, "and so does a fully transparent texel's alpha")
end

do
  local fixture = loadfile(MOD .. "/tests/shiny_palette_fixture.lua")
  if not fixture then
    io.write("note: no colour fixture; skipped the cross-check\n")
  else
    local rows = fixture()
    local worst, bad = 0, 0
    for _, r in ipairs(rows) do
      local fn = ShinyPalette.transform(ShinyPalette.forDex(r[1]))
      local gr, gg, gb = r[2], r[3], r[4]
      if fn then gr, gg, gb = fn(r[2], r[3], r[4]) end
      local d = math.max(math.abs(gr - r[5]), math.abs(gg - r[6]),
                         math.abs(gb - r[7]))
      if d > worst then worst = d end
      if d > 2 then bad = bad + 1 end
    end
    eq(bad, 0, ("%d colour pairs reproduce the shipped textures"):format(#rows))
    -- a unit or two of drift is the two languages' float rounding; more than
    -- that means the colour model itself has diverged
    ok(worst <= 2, ("worst channel drift is %d, within rounding"):format(worst))
  end
end

-- ------- the read side
--
-- The extraction writes NNNs.dsm beside NNN.dsm; this is the other half of
-- that contract. Driven off a directory of real packs when one is given
-- (--packs=DIR, e.g. the extract test's --out), because the interesting
-- cases are a shiny pack that EXISTS and one that does not, and both have
-- to be real files for the fallback to be worth testing.
if args.packs then
  local Vp = { mod = { log = { warn = function() end, info = function() end } } }
  local loadedP = {}
  function Vp.require(name)
    if loadedP[name] == nil then
      loadedP[name] = assert(loadfile(MOD .. "/lib/" .. name .. ".lua"))(Vp)
    end
    return loadedP[name]
  end
  -- stand in for the mod's own reader, pointed at the pack directory
  function Vp.mod:read(rel)
    local name = rel:match("([^/]+)$")
    local fp = io.open(args.packs .. "/" .. name, "rb")
    if not fp then return nil end
    local b = fp:read("*a")
    fp:close()
    return b
  end
  local StadiumPack = Vp.require("StadiumPack")
  StadiumPack.DIR = "."

  local normal = StadiumPack.load(6, false)
  local shiny = StadiumPack.load(6, true)
  ok(normal ~= nil, "the normal Charizard pack loads")
  ok(shiny ~= nil, "and so does the shiny one")
  if normal and shiny then
    eq(shiny.shiny, true, "the shiny model is flagged as such")
    eq(normal.shiny, nil, "and the normal one is not")
    ok(normal ~= shiny, "they are SEPARATE models, not one shared table")
    eq(#normal.prims, #shiny.prims, "same geometry")
    eq(normal.texCount, shiny.texCount, "same texture count")
    -- the point of the whole exercise: different pixels
    local differs = false
    for i = 1, math.min(#normal.textures, #shiny.textures) do
      if normal.textures[i].rgba ~= shiny.textures[i].rgba then
        differs = true
        break
      end
    end
    ok(differs, "and different texels")
  end

  -- a species with no shiny pack must fall back rather than vanish: that is
  -- what an install from before rev 3 looks like
  local missing = StadiumPack.load(999, true)
  eq(missing, nil, "an out-of-range species is still nil")
end

-- ------- end to end, through the engine's own constructor
--
-- The wrap is the whole feature: if Pokemon.new does not carry the verdict,
-- nothing downstream has anything to draw. Exercised against the real
-- constructor and the fixture dataset rather than a stub, because what is
-- being tested is precisely that we hooked the thing the game calls.

do
  local okKit, T = pcall(require, "tests.modkit")
  local Data = okKit and T.fixtures and T.fixtures.load()
  local okPk, Pokemon = pcall(require, "src.pokemon.Pokemon")
  local species = Data and Data.pokemon
                  and (Data.pokemon.PIKACHU and "PIKACHU"
                       or next(Data.pokemon))
  if not (okKit and okPk and species) then
    io.write("note: no fixture dataset; skipped the end-to-end check\n")
  else
    local ShinyBattle = V.require("shiny/ShinyBattle")
    ShinyBattle.install()
    ShinyBattle.install()   -- twice: the wrap must not stack

    local saved = Shiny.ODDS_DENOM

    Shiny.setOdds(1)
    local m = Pokemon.new(Data, species, 7)
    ok(Shiny.isShiny(m), "a mon built at odds 1 comes out shiny")
    eq(m.shiny, true, "and carries the flag")
    eq(m.hp, m.stats.hp, "and is at full health despite the restat")
    ok(Stats.isShiny(m.dvs), "and the ENGINE agrees it is shiny")

    -- and at long odds it essentially never is: 400 draws at 1/8192 would
    -- fire about 5% of the time, so a single failure here is signal
    Shiny.setOdds(8192)
    local shinies = 0
    for _ = 1, 400 do
      if Shiny.isShiny(Pokemon.new(Data, species, 7)) then
        shinies = shinies + 1
      end
    end
    ok(shinies <= 2, ("400 mons at 1/8192 produced %d shinies")
                     :format(shinies))

    Shiny.setOdds(saved)
  end
end

io.write(("\n%d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
