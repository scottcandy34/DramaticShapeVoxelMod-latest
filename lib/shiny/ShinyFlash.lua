-- The arrival sparkle, on the FLAT battle screen.
--
-- ------- why ShinyFx could not be reused
--
-- lib/ShinyFx.lua is the sparkle for the STADIUM rungs, and every line of it
-- is about the 3D arena: it is armed from Stadium.update on the frame a
-- side's model changes, it is sized from the model's own world height and
-- radius, and it draws additive quads into the voxel scene through
-- Voxel3D.blend. None of that exists on the other rungs -- 3D-BTL OFF has no
-- arena at all, and the two 2D-3D rungs stand flat PICS up as billboards
-- rather than building a model to measure.
--
-- So the effect was Stadium-only, and had been since it was written: ShinyFx
-- .arm is called from exactly one file. On every other rung a shiny simply
-- appeared, with no announcement. This is the announcement, in the one
-- coordinate space those rungs share -- the Game Boy's own 160x144 grid,
-- where the pic itself is drawn.
--
-- ------- the two slots
--
-- Both are the engine's, and neither moves: the enemy's front pic lives in
-- the 7x7 tile slot at hlcoord 12,0 (x 96..152, y 0..56) and the player's
-- back pic stands at x=8 with its feet on the text box at y=96, two-times
-- scaled, so it fills y 32..96. The burst springs from a point inside each,
-- a little above centre, which is roughly where a Pokemon's chest is in art
-- drawn to fill its box.
--
-- Deliberately NOT measured off the drawn image. resolveBattleScale can
-- rescale a pic per species, the send-out grow animates the scale from zero,
-- and following either would make the burst jump around during exactly the
-- moment it is playing. The slot is fixed; the sparkle uses the slot.
--
-- ------- black AND white, both
--
-- Each spark is drawn twice: a wider near-black cross, then a white one
-- inside it. One colour alone would be invisible half the time -- the battle
-- screen's field is white, so a white spark vanishes on OFF, and the 2D-3D
-- rungs composite the same pic over a sky or a map, where a black one does.
-- The pair reads on both, and costs ten extra rectangles.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Shiny = V.require("Shiny")

local ShinyFlash = {}

ShinyFlash.LIFE = 0.75            -- seconds, matching ShinyFx
ShinyFlash.SPARKS = 9

-- The two slots, in GB pixels: where the burst starts and how far it travels.
ShinyFlash.SLOTS = {
  enemy  = { x = 124, y = 24, rx = 34, ry = 26 },
  player = { x = 40,  y = 62, rx = 34, ry = 30 },
}

-- Where each spark sits on the ring, as a fraction of a turn. Spread by hand
-- rather than randomly: nine sparks on an even ring reads as a ring, and nine
-- random ones read as a mess at this size. The half-step offset on alternate
-- sparks keeps it from looking like a clock face.
local ANGLES = {}
for i = 1, ShinyFlash.SPARKS do
  ANGLES[i] = (i - 1) / ShinyFlash.SPARKS + (i % 2 == 0 and 0.5 or 0)
                                            / ShinyFlash.SPARKS
end

-- ------- why the clock is the WALL clock
--
-- Everything here happens on the DRAW side (see install), and a draw is
-- handed no dt. Rather than accumulate one nobody offers, a burst records
-- the time it started and its age is read back off love.timer.
--
-- That also makes it immune to being asked to draw more than once in a
-- frame, which the wide layout does -- once per side -- and which a
-- per-call dt accumulator would age at double speed.
local function now()
  return (love.timer and love.timer.getTime and love.timer.getTime()) or 0
end

-- live bursts: side -> the time it started
local live = {}

-- what each side's pic was showing last frame, so an arrival is an EDGE
local showing = {}

-- for the tests and the shot drivers, the way ShinyFx.debug is
ShinyFlash.debug = { renders = 0, follows = 0, occupied = 0,
                     armed = 0, draws = 0, sparks = 0, err = "" }

function ShinyFlash.arm(side)
  live[side] = now()
  ShinyFlash.debug.armed = ShinyFlash.debug.armed + 1
end

function ShinyFlash.clear(side)
  live[side] = nil
end

function ShinyFlash.reset()
  live, showing = {}, {}
end

-- How far through its life this side's burst is, 0..1, or nil when there
-- isn't one (or it has finished, which retires it on the way past).
function ShinyFlash.age(side)
  local started = live[side]
  if not started then return nil end
  local u = (now() - started) / ShinyFlash.LIFE
  if u >= 1 then
    live[side] = nil
    return nil
  end
  return u
end

function ShinyFlash.active(side)
  return ShinyFlash.age(side) ~= nil
end

-- ------- is a Pokemon's own pic on screen for this side
--
-- The conditions are the engine's, read off drawPicsLayer rather than
-- guessed: a side showing a TRAINER is showing a person and not a Pokemon,
-- and the send-out, the faint fade and the safari/demo cases each have their
-- own reason for the slot to be empty.
--
-- Returns the mon whose pic is up, or nil.
function ShinyFlash.occupant(battle, side)
  if type(battle) ~= "table" then return nil end
  if side == "enemy" then
    if battle.showEnemyTrainer and battle.trainerPic then return nil end
    local b = battle.enemy
    if not (b and b.sprite) then return nil end
    if battle.enemyHidden or battle.enemySendingOut then return nil end
    if battle.fxHidden and battle:fxHidden(b) then return nil end
    return b.mon
  end
  if battle.showPlayerBack and battle.playerBackPic then return nil end
  if battle.safari or battle.demo then return nil end
  local b = battle.player
  if not (b and b.sprite) then return nil end
  if battle.sendingOut then return nil end
  if battle.fxHidden and battle:fxHidden(b) then return nil end
  return b.mon
end

-- Arm on the frame a side's occupant CHANGES to a shiny -- a send-out, a
-- switch and a wild foe's first appearance alike, which is the same edge
-- ShinyFx picks for the models.
function ShinyFlash.follow(battle)
  ShinyFlash.debug.follows = ShinyFlash.debug.follows + 1
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = ShinyFlash.occupant(battle, side)
    if mon then ShinyFlash.debug.occupied = ShinyFlash.debug.occupied + 1 end
    if mon ~= showing[side] then
      showing[side] = mon
      if mon and Shiny.isShiny(mon) then
        ShinyFlash.arm(side)
      else
        ShinyFlash.clear(side)
      end
    end
  end
end

-- ------- drawing
--
-- Whole pixels. The screen this lands on is 160x144 and everything else in
-- it is on the pixel grid, so a spark at x=41.37 would be the one soft thing
-- on a hard-edged frame.
local function spark(px, py, arm)
  local g = love.graphics
  px, py = math.floor(px + 0.5), math.floor(py + 0.5)
  -- the dark cross first, one pixel proud of the light one on every side
  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", px - arm - 1, py - 1, arm * 2 + 3, 3)
  g.rectangle("fill", px - 1, py - arm - 1, 3, arm * 2 + 3)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", px - arm, py, arm * 2 + 1, 1)
  g.rectangle("fill", px, py - arm, 1, arm * 2 + 1)
end

-- One side's burst, if it has one.
function ShinyFlash.draw(side, sx, sy)
  local u = ShinyFlash.age(side)
  if not u then return end
  local slot = ShinyFlash.SLOTS[side]
  if not slot then return end
  local g = love.graphics
  local r, gg, b, a = g.getColor()

  -- Out and fading. The ring eases OUT rather than travelling at a constant
  -- speed -- fast off the mark, slow at the edge -- because a burst that
  -- decelerates reads as thrown and one that does not reads as a wipe.
  local ease = 1 - (1 - u) * (1 - u)
  local fade = 1 - u
  g.setColor(1, 1, 1, 1)
  ShinyFlash.debug.draws = ShinyFlash.debug.draws + 1

  for i = 1, ShinyFlash.SPARKS do
    -- every third spark is held back a little, so the ring has some depth
    -- rather than nine points on one circle
    local lag = (i % 3 == 0) and 0.78 or 1
    local ang = ANGLES[i] * math.pi * 2
    local px = (sx or 0) + slot.x + math.cos(ang) * slot.rx * ease * lag
    local py = (sy or 0) + slot.y - math.sin(ang) * slot.ry * ease * lag
    -- arms shrink as the spark fades, so it goes out rather than vanishing
    local arm = 1 + math.floor(fade * 2.5)
    spark(px, py, arm)
    ShinyFlash.debug.sparks = ShinyFlash.debug.sparks + 1
  end

  g.setColor(r, gg, b, a)
end

-- ------- BEHIND the Pokemon, not over it
--
-- The burst springs from inside the mon and flies outward, so the frames that
-- matter most are the ones where the ring is still small and sitting ON the
-- body. Drawn from the overlay hook -- the end of the battle draw -- every one
-- of those lands in FRONT of the pic, and the sparkle reads as stuck to the
-- glass rather than as coming from the Pokemon.
--
-- So it is drawn from the PICS LAYER instead, before the engine's own pics go
-- down. That is the only place in the frame that is behind the mon and in
-- front of the field.
--
-- The overlay hook stays, and is still the only seam the 3D rungs have:
-- OverworldBattle captured drawPicsLayer at install time and its battle draw
-- calls the captured copy, so the wrap below never runs there. Whichever seam
-- fires first draws; the other one sees the side already spent and leaves it
-- alone. `spent` is cleared by the overlay, which is the one call guaranteed
-- to happen exactly once per battle draw.
local spent = {}

-- One side, unless it has already been drawn this frame.
local function once(side, sx, sy)
  if spent[side] then return end
  spent[side] = true
  ShinyFlash.draw(side, sx, sy)
end

-- The pics layer, BEFORE the engine's pics. `onlySide` is the wide layout
-- drawing one side per call, and is honoured so the burst lands in the same
-- pass its Pokemon does.
--
-- Skipped while the layer is SLIDING (the intro walks the whole battle in
-- from the side): the slot this draws to is fixed, so a burst during the
-- slide would sit still while the mon travelled past it. Nothing is lost --
-- the arrival edge that arms it is after the slide is over.
function ShinyFlash.renderBehind(battle, slide, sx, sy, onlySide)
  ShinyFlash.debug.behinds = (ShinyFlash.debug.behinds or 0) + 1
  ShinyFlash.follow(battle)
  if (slide or 0) ~= 0 then return end
  if onlySide ~= "player" then once("enemy", sx, sy) end
  if onlySide ~= "enemy" then once("player", sx, sy) end
end

-- Follow the occupants and draw whatever the pics layer did not, in one call.
function ShinyFlash.render(battle)
  ShinyFlash.debug.renders = ShinyFlash.debug.renders + 1
  ShinyFlash.follow(battle)
  once("enemy", 0, 0)
  once("player", 0, 0)
  spent = {}                     -- one battle draw ends here; the next is new
end

-- ------- install
--
-- Through the engine's own `battle.overlay` hook, whose comment at the call
-- site names this exact use ("shiny sparkles, custom HUD chrome"). It fires
-- at the very end of BattleState:draw, in the Game Boy's own 160x144 space,
-- with the battle as its argument -- which is all this needs.
--
-- A MONKEYPATCH ON UPDATE WAS TRIED FIRST AND DOES NOT WORK, which is worth
-- recording so it is not tried again: BattleState:update never fires during
-- the intro, because the battle is not the top of the stack there and
-- StateStack:update only calls the top. Measured -- installed, confirmed live
-- on the class, zero calls -- rather than reasoned about.
--
-- The hook has no shake offset to give, and does not need one: it is called
-- after the screen-shake translate has been popped, so nominal coordinates
-- are the right ones.
--
-- ------- and the second seam, for depth
--
-- The overlay alone draws the burst OVER the Pokemon. The pics layer is
-- wrapped as well so it can go down BEHIND it (see renderBehind), on every
-- rung where the engine's own method is the one called. On the 3D rungs it is
-- not -- OverworldBattle captured drawPicsLayer at install time and calls the
-- captured copy -- and there the overlay is still the seam, which is why both
-- are installed rather than one replacing the other.
function ShinyFlash.install()
  local mod = V.mod
  if not (mod and mod.hooks and mod.hooks.wrap) then return false end
  if ShinyFlash.installed then return true end
  mod.hooks:wrap("battle.overlay", function(next, battle)
    local out = next(battle)
    local ok, err = pcall(ShinyFlash.render, battle)
    if not ok then ShinyFlash.debug.err = tostring(err) end
    return out
  end)

  local okBS, BattleState = pcall(require, "src.battle.BattleState")
  if okBS and type(BattleState) == "table"
     and type(BattleState.drawPicsLayer) == "function"
     and not BattleState.dramaticShapeShinyFlash then
    local inner = BattleState.drawPicsLayer
    function BattleState:drawPicsLayer(slide, sx, sy, onlySide, ...)
      ShinyFlash.debug.picsCalls = (ShinyFlash.debug.picsCalls or 0) + 1
      local ok, err = pcall(ShinyFlash.renderBehind, self, slide, sx, sy,
                            onlySide)
      if not ok then ShinyFlash.debug.err = tostring(err) end
      return inner(self, slide, sx, sy, onlySide, ...)
    end
    BattleState.dramaticShapeShinyFlash = true
  end

  ShinyFlash.installed = true
  return true
end

return ShinyFlash
