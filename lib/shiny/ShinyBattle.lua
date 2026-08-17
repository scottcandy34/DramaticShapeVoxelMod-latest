-- Where shininess enters the game, and where it is shown.
--
-- ------- one seam decides it
--
-- Every Pokemon the player can ever own is built by Pokemon.new
-- (src/pokemon/Pokemon.lua:60). There are five callers and they are the
-- whole surface:
--
--   BattleState.lua:569    the wild encounter
--   BattleState.lua:659    a trainer's party
--   BattleState.lua:785    the level-5 stand-in the Oak battle builds
--   Commands.lua:656       a gift or a starter
--   Commands.lua:969       an in-game trade
--
-- So the roll goes THERE rather than on the encounter hooks. Two reasons,
-- and the second is decisive:
--
--   * encounter.roll and encounter.species fire before the mon exists --
--     they carry {species, level} and nothing to write a verdict onto.
--   * makeBattler bakes mon.sprite INSIDE newWild
--     (src/battle/BattleState.lua:455-461), before battle.started is
--     emitted. A verdict applied at battle.started is already too late for
--     the sprite the fight will draw.
--
-- Wrapping the constructor puts the decision before every one of those, and
-- picks up gift mons, starters and trades for free rather than needing a
-- seam each.
--
-- TRAINER MONS COME OUT NON-SHINY BY THEMSELVES, and correctly so. The
-- engine overwrites every trainer slot's DVs with a fixed TRAINER_DVS
-- (src/battle/BattleState.lua:350, :661) right after construction, and that
-- constant fails the shiny pattern. So the roll is made and then discarded
-- for them -- which matches the real games, where a trainer's Pokemon is
-- never shiny.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Shiny = V.require("Shiny")

local ShinyBattle = {}

-- ------- install
--
-- Idempotent by sentinel, the pattern every wrap in this mod uses
-- (OverworldBattle.install, Stadium.install): a hot reload must not stack a
-- second copy of the wrapper on top of the first.
function ShinyBattle.install()
  local Pokemon = require("src.pokemon.Pokemon")
  if not Pokemon.dramaticShapeShiny then
    local inner = Pokemon.new
    function Pokemon.new(data, species, level, rng)
      local mon = inner(data, species, level, rng)
      -- pcall: a mon that fails to be decided is an ordinary mon, which is
      -- a blemish. A mon that fails to be BUILT is a broken game.
      pcall(Shiny.decide, mon)
      return mon
    end
    Pokemon.dramaticShapeShiny = true
  end

  -- Party mons that predate the mod, and any mon built by a path we have
  -- not wrapped, still answer isShiny correctly -- their DVs were always
  -- there. This only refreshes the mon.shiny cache so a save opened for the
  -- first time under this mod has the field populated rather than absent
  -- until the mon next changes.
  ShinyBattle.markParty()
end

-- Refresh the cached flag across the player's party.
function ShinyBattle.markParty()
  local ok, Game = pcall(require, "src.core.Game")
  if not ok then return end
  local party = Game and Game.save and Game.save.party
  if type(party) ~= "table" then return end
  for _, mon in ipairs(party) do
    pcall(Shiny.mark, mon)
  end
end

-- ------- asking about a battler
--
-- The battler wrapper carries the save-shaped mon on `.mon`
-- (src/battle/BattleState.lua:432-463), so the question is always about
-- that table and never about the wrapper.
function ShinyBattle.battlerIsShiny(battler)
  return battler ~= nil and Shiny.isShiny(battler.mon)
end

-- Which side of a battle, by the engine's own side names.
function ShinyBattle.sideIsShiny(battle, side)
  if not battle then return false end
  return ShinyBattle.battlerIsShiny(side == "player" and battle.player
                                                     or battle.enemy)
end

return ShinyBattle
