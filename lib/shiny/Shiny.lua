-- Shiny Pokemon: the one fact, and everywhere that asks it.
--
-- WHAT MAKES A MON SHINY HERE IS ITS DVs, and nothing else. Gen 1 has no
-- shininess of its own, but it does have the four DVs Gen 2 later read to
-- decide it, and the engine already ships that reading:
-- src/pokemon/Stats.lua:90 isShiny(dvs) -- Defense, Speed and Special all
-- exactly 10, Attack one of 2/3/6/7/10/11/14/15. The engine's own comment
-- calls it "the RBY virtual shiny" and says it is there for indicator mods.
-- This is that mod.
--
-- Deriving rather than storing is the whole design, and it buys a great
-- deal:
--
--   * It persists for free. DVs are already in every save, every PC box,
--     every trade. No new save field, no migration, and a save made before
--     this mod was installed already HAS shiny Pokemon in it -- they were
--     always there, nothing was ever drawn differently.
--   * It survives evolution. Evolution.apply recalculates stats from the
--     same dvs table and never touches it (src/pokemon/Evolution.lua:99),
--     so a shiny Bulbasaur is a shiny Venusaur without being told.
--   * It cannot desync. A flag stored beside the DVs is a second copy of
--     the truth, and two copies drift -- most cruelly across a trade or a
--     box deposit, where the mon travels and the sidecar does not.
--   * PKHeX and the Gen 2 games agree with us, because it is their rule.
--
-- The odds, though, are ours to set, and that is the one thing DVs alone
-- cannot give: random DVs land on that pattern 1/16 * 1/16 * 1/16 * 8/16 =
-- exactly 1/8192, the classic rate, and there is no dial on it. So the roll
-- happens at encounter time and its VERDICT IS WRITTEN BACK INTO THE DVs
-- (forceShiny/forceCommon below). The mon does not carry a flag saying it
-- is shiny; it is made genuinely shiny by the game's own formula, and every
-- later reader -- ours, the engine's, a future mod's, PKHeX's -- reaches the
-- same answer without knowing we were involved.
--
-- mon.shiny is maintained too, but it is a CACHE and never the source: see
-- Shiny.mark.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

-- allowlisted for mods by name -- src/mods/Loader.lua:71 lists
-- src.pokemon.Stats precisely so an indicator mod can call isShiny
local Stats = require("src.pokemon.Stats")

local ModSetting = V.require("ModSetting")

local Shiny = {}

-- ------- the odds
--
-- One in ODDS_DENOM. The default is 8192 because that is what random DVs
-- already produce, so a player who never changes it gets the canonical rate
-- and the canonical feel -- this mod's default is not a buff.
--
-- The roll is made EXACT rather than additive. A naive implementation rolls
-- 1/N and forces shiny on a hit, but leaves the natural 1/8192 in place on a
-- miss, so the true rate is N and 8192 in parallel -- indistinguishable at
-- the default and quietly wrong at every other setting (at 1/100 you would
-- ship 1/99.99, and at 1/20000 you could never go rarer than 1/8192 no
-- matter what you set). forceCommon on a miss closes that: the rate is what
-- the number says.
Shiny.ODDS_DENOM = 8192

-- ------- the row the player cycles
--
-- A ladder that HALVES, so every step is exactly "twice as often as the one
-- above it" and the label says the whole truth -- 1:8192 down to 1:1. The
-- rate is what the number says, not an approximation of it, because the
-- miss branch of decide() closes the natural 1/8192 (see above); a rung of
-- 1:2 really is every other encounter.
--
-- values[1] is 8192: ModSetting treats the first rung as both the DEFAULT
-- and the fallback for an unreadable or unrecognised stored value, so the
-- canonical rate is what a player who never opens the menu gets and what a
-- corrupted options.lua comes back to.
--
-- No rung RARER than 8192. The mod's promise is that its default is not a
-- change to the game; making the game harder than it ships is a different
-- promise and nobody asked for it.
local ODDS = { 8192, 4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1 }

local ODDS_LABELS = {}
for i, n in ipairs(ODDS) do ODDS_LABELS[i] = "1:" .. n end

Shiny.setting = ModSetting.new("shinyOdds", "SHINY ODDS", ODDS, ODDS_LABELS)

-- ------- the setting is PULLED, not pushed
--
-- decide() asks this every roll rather than the menu telling us when it
-- changed. Two writers exist -- the OPTIONS row and the mod manager's own
-- settings page -- and only the first has a change hook to hang on; the
-- manager writes through mod.options and calls ModSetting:sync, which
-- notifies nothing. Pulling is the only way both are seen, and the cost is
-- a table read on an event that happens once per encounter.
--
-- ODDS_DENOM stays the live value and is written through on every ask, so
-- anything already reading that field keeps reading the truth.
local pinned = false

function Shiny.odds()
  if not pinned then
    local ok, value = pcall(Shiny.setting.get, Shiny.setting)
    local n = ok and tonumber(value)
    if n and n >= 1 then Shiny.ODDS_DENOM = math.floor(n) end
  end
  return Shiny.ODDS_DENOM
end

-- Set the denominator BY HAND, which also PINS it: a driver or a test that
-- has asked for 1:1 means it, and must not have the next roll quietly put
-- back to whatever the player left on the menu. Nothing in the game calls
-- this -- the row is how a player changes the rate.
--
-- Guards the degenerate values because a 0 or a negative here would
-- divide-by-zero or make every encounter shiny by accident rather than by
-- choice; 1 (always shiny) stays reachable because it is genuinely useful
-- for walking the whole model set.
function Shiny.setOdds(denom)
  denom = tonumber(denom)
  if not denom or denom < 1 then return Shiny.ODDS_DENOM end
  Shiny.ODDS_DENOM = math.floor(denom)
  pinned = true
  return Shiny.ODDS_DENOM
end

-- Hand the row back control, for a test that pinned the odds and wants the
-- setting to mean something again afterwards.
function Shiny.unpinOdds()
  pinned = false
  return Shiny.odds()
end

-- ------- reading it

-- The eight Attack DVs that satisfy the Gen 2 pattern, in order. Kept as a
-- list as well as the engine's set because forceShiny has to CHOOSE one and
-- wants the nearest, not just any.
local SHINY_ATK = { 2, 3, 6, 7, 10, 11, 14, 15 }

-- The HP DV is not free: Gen 1 derives it from the low bit of each of the
-- other four (src/pokemon/Stats.lua:19). Any write to the four must
-- recompute it, or the mon ends up with an HP stat the real game could
-- never produce -- which is exactly what a save inspector flags as illegal.
local function syncHpDv(dvs)
  dvs.hp = (dvs.attack % 2) * 8 + (dvs.defense % 2) * 4 +
           (dvs.speed % 2) * 2 + (dvs.special % 2)
  return dvs
end

-- The single question. Everything visual in this mod routes here.
function Shiny.isShiny(mon)
  if type(mon) ~= "table" then return false end
  return Stats.isShiny(mon.dvs) == true
end

-- ------- writing it

-- Make these DVs satisfy the pattern, moving them as little as it allows.
--
-- Defense, Speed and Special have exactly one legal value each, so they are
-- simply pinned. Attack has eight, and the nearest one to whatever was
-- rolled is chosen -- a mon rolled at Attack 15 keeps 15, one rolled at 0
-- becomes 2. That is not cosmetic: DVs are stats, and a shiny encounter
-- should not also be a stat reroll any larger than the pattern demands.
local function forceShiny(dvs)
  local want, best, bestd = dvs.attack or 0, SHINY_ATK[1], nil
  for _, v in ipairs(SHINY_ATK) do
    local d = math.abs(v - want)
    if not bestd or d < bestd then bestd, best = d, v end
  end
  dvs.attack = best
  dvs.defense, dvs.speed, dvs.special = 10, 10, 10
  return syncHpDv(dvs)
end

-- Make these DVs NOT satisfy the pattern, moving them as little as
-- possible: one step on Special is enough to break it, and Special is the
-- choice because in Gen 1 it is a single stat rather than the two Gen 2
-- split it into, so the disturbance stays inside one number.
--
-- Only ever reached by a mon that rolled non-shiny and happened to be shiny
-- by luck, which is 1/8192 of the time -- so this touches almost nothing,
-- and what it does touch it moves by one point.
local function forceCommon(dvs)
  if (dvs.special or 0) == 10 then
    dvs.special = 9
  elseif (dvs.defense or 0) == 10 then
    dvs.defense = 9
  end
  return syncHpDv(dvs)
end

-- mon.shiny: the cache.
--
-- The requirement is a flag ON the Pokemon, and this is it -- but it is
-- written from the DVs every time we touch a mon, never read as the truth.
-- Keeping it one-directional is what stops it becoming the second copy the
-- header warns about: if it ever disagrees with the DVs, the DVs win and
-- this is overwritten. It exists so other code -- and a save inspector, and
-- a companion mod -- can ask the cheap question without importing Stats.
function Shiny.mark(mon)
  if type(mon) ~= "table" then return false end
  local is = Shiny.isShiny(mon)
  mon.shiny = is or nil    -- nil rather than false: absent keeps saves clean
  return is
end

-- Recalculate the stats a DV write invalidated.
--
-- Split out because both decide() and set() move DVs, and a mon left
-- carrying stats computed from its old DVs is wrong in the only way the
-- player can actually see: its HP bar.
local function restat(mon)
  if not (mon.level and mon.species) then return end
  local ok, data = pcall(require, "src.core.Data")
  local def = ok and data and data.pokemon and data.pokemon[mon.species]
  if not def then return end
  local wasFull = mon.hp and mon.stats and mon.hp >= (mon.stats.hp or 0)
  mon.stats = Stats.calc(def, mon.level, mon.dvs, mon.statExp)
  -- A wild mon appears at full health, and a mon that WAS full stays full:
  -- recomputing max HP without following it here would put a freshly
  -- encountered mon on the field at less than full from its first frame.
  -- A wounded mon keeps its damage, clamped to the new maximum.
  if mon.hp then
    mon.hp = wasFull and mon.stats.hp or math.min(mon.hp, mon.stats.hp)
  end
end

-- ------- our own randomness
--
-- A PRIVATE stream, not love.math.random, and that is deliberate.
--
-- The game's RNG is a shared sequence: damage rolls, crits, encounter
-- slots and DV generation all draw from it in a fixed order. Taking a draw
-- out of it for a shiny check would shift every later draw, so installing
-- this mod would quietly change the outcome of fights that have nothing to
-- do with shininess -- and the manifest promises `affects_link = false`,
-- which a shifted stream would make untrue the moment two machines
-- disagreed about whose turn consumed what.
--
-- Seeded off the clock rather than the save, because shininess is a fact
-- about the encounter and not about the file: re-loading a save to re-roll
-- a Pokemon is the hunt, and a stream keyed to the save would hand back the
-- same answer every time.
local stream = nil

local function roll(n)
  if not stream then
    if love and love.math and love.math.newRandomGenerator then
      stream = love.math.newRandomGenerator(os.time(), os.clock() * 1e6)
    else
      -- headless (tests): math.random is nobody's shared sequence there
      stream = { random = function(_, a, b) return math.random(a, b) end }
    end
  end
  return stream:random(1, n)
end

-- Decide a freshly-built mon, in place.
--
-- rng may be passed to pin the verdict -- a test hands us a stub. Left nil,
-- the private stream above is used.
function Shiny.decide(mon, rng)
  if type(mon) ~= "table" or type(mon.dvs) ~= "table" then return false end
  -- same shape as love.math.random(lo, hi), so a caller can pass that or a
  -- stub and the call below reads identically either way
  rng = rng or function(_lo, hi) return roll(hi) end
  local hit = rng(1, Shiny.odds()) == 1

  if hit then
    forceShiny(mon.dvs)
    restat(mon)
  elseif Stats.isShiny(mon.dvs) then
    forceCommon(mon.dvs)
    restat(mon)
  end
  return Shiny.mark(mon)
end

-- Force a specific verdict: for tests, and for a scripted gift mon that
-- wants to be shiny on purpose.
function Shiny.set(mon, on)
  if type(mon) ~= "table" or type(mon.dvs) ~= "table" then return false end
  if on then forceShiny(mon.dvs) else forceCommon(mon.dvs) end
  restat(mon)
  return Shiny.mark(mon)
end

return Shiny
