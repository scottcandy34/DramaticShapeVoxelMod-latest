-- LET'S GO: the row, the modes, and every engine seam the capture game
-- stands on.
--
-- Three rungs:
--
--   OFF         nothing changes. The default, and what an unrecognised
--               stored value falls back to.
--   FULL        the whole Let's Go treatment. A wild encounter opens
--               STRAIGHT into capture mode (B backs out to the classic
--               menu for anyone who came to fight), Poke/Great/Ultra
--               Balls are half price at every mart, and EXPERIENCE works
--               the way that game's does: every healthy party member
--               gains from every catch AND every trainer knockout, each
--               measured against its own level. A catch adds the throw
--               stack on top -- grade, first throw, new species, combo.
--   CATCH ONLY  the fights are untouched and the shops are untouched;
--               the one change is that throwing a ball -- from the bag,
--               or a SAFARI BALL from the safari menu -- runs the throw
--               minigame instead of the automatic toss. The minigame's
--               grade still folds into the Gen 1 catch roll (a good
--               throw should matter or the ring is a lie), but nothing
--               outside the throw changes.
--
-- The capture game itself lives in lib/CatchThrow.lua and the ball it
-- throws in lib/Pokeball.lua; this file is the wiring: the ModSetting,
-- the two BattleState wraps that intercept a ball being thrown, the
-- auto-entry tick for FULL, the price patch, and the experience hooks.
--
-- ------- where the minigame declines to run
--
-- The throw is a 3D scene: it needs the staged battle standing (the
-- over-the-shoulder shot the option's own 3D-BTL row provides, ON by
-- default), a driver with a depth buffer, and a flat screen (the VR seat
-- draws through a different pass entirely). Anywhere that fails -- 3D-BTL
-- switched off, a headless driver, a headset -- the ball quietly takes
-- the engine's own toss, which is exactly what the mod's "declines
-- cleanly" rule demands. Trainers, the ghost, the RESTLESS SOUL and the
-- old man's demo keep the vanilla path on purpose: those branches ARE
-- their behaviour.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local Voxel3D = V.require("Voxel3D")
local CatchThrow = V.require("CatchThrow")

local LetsGo = {}

LetsGo.KEY = "letsgo"
LetsGo.LABEL = "LET'S GO"

-- `false` first: the default, and the fallback for a stored value from
-- some other version of this ladder
LetsGo.setting = ModSetting.new(LetsGo.KEY, LetsGo.LABEL,
                                { false, "full", "catching" },
                                { "OFF", "FULL", "CATCH ONLY" })

-- false | "full" | "catching"
function LetsGo.mode()
  return LetsGo.setting:get()
end

local function game() return require("src.core.Game") end

-- ------- half-price balls (FULL)
--
-- Prices are live data (game.data.items[id].price) and every reader --
-- the buy list, the affordability check, the quantity box -- reads them
-- per use, so patching the table IS the feature. Applied and reverted on
-- the option's edge, polled from the tick because the row, the manager's
-- page and a loaded save can all move it and none of them announces to
-- us. The sell price follows automatically (the mart pays half of list),
-- which is coherent: cheaper balls are worth less back too.
local PRICED = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL" }
local fullPrices = nil     -- originals while halved, or nil

local function applyPrices()
  local g = game()
  local items = g and g.data and g.data.items
  if not items then return end
  local wantHalf = LetsGo.mode() == "full"
  if wantHalf and not fullPrices then
    fullPrices = {}
    for _, id in ipairs(PRICED) do
      local def = items[id]
      if def and def.price then
        fullPrices[id] = def.price
        def.price = math.floor(def.price / 2)
      end
    end
  elseif not wantHalf and fullPrices then
    for id, price in pairs(fullPrices) do
      if items[id] then items[id].price = price end
    end
    fullPrices = nil
  end
end

-- ------- whether a throw can be the minigame

local function vrOn()
  local ok, vr = pcall(V.require, "VR")
  return ok and vr and vr.enabled and vr.enabled() or false
end

-- ------- the battles that are cutscenes wearing a battle's clothes
--
-- The catch tutorials -- the VIRIDIAN CITY old man, and Yellow's PROF.OAK
-- catching the PIKACHU (both BattleState:makeOldManDemo, which is why one
-- flag covers both) -- are scripted from the first frame: the cursor moves
-- itself, the bag opens itself, the ball is thrown by someone who is not
-- the player, and the throw always catches a Pokemon nobody keeps. There
-- is no decision in them to hand a minigame, and the story beat is the
-- point, so LET'S GO stays out of them entirely at whatever rung: no
-- capture screen, no FULL treatment, no experience.
function LetsGo.scripted(battle)
  return battle and (battle.demo or battle.oakDemo) and true or false
end

function LetsGo.wantsMinigame(battle)
  if not LetsGo.mode() then return false end
  if not battle or battle.kind ~= "wild" then return false end
  if LetsGo.scripted(battle) then return false end
  if battle.ghost or battle.noCatch then return false end
  if not Voxel3D.available() or vrOn() then return false end
  -- the staged shot must actually be standing: this is "there is a 3D
  -- battle on screen right now", which the throw is aimed into
  local ok, shot = pcall(function()
    return V.require("OverworldBattle").shot()
  end)
  return (ok and shot) and true or false
end

-- A Let's Go wild: the encounters FULL owns outright. In these the foe
-- never takes a turn, the player's Pokemon is never sent out or shown,
-- B runs (and always escapes), and the encounter lives in throw mode
-- from the wipe to the last message.
function LetsGo.fullWild(battle)
  return LetsGo.mode() == "full" and battle and battle.kind == "wild"
         and not LetsGo.scripted(battle)
         and not (battle.safari or battle.ghost or battle.noCatch)
         and true or false
end

-- ------- the experience stack (FULL)
--
-- Let's Go pays a catch like a knockout, through the Gen VII scaled
-- formula -- every party member paid against its OWN level -- times the
-- catch bonuses. Three engine hooks carry it:
--
--   battle.catch_exp    "does a catch pay at all" -- yes, under FULL
--   battle.exp_award    the distribution: every healthy party member its
--                       own full share, no participant split
--   exp.gain            the amount: the scaled formula times the bonus
--                       stack, in place of floor(b*L/7)
--
-- The stack: throw grade (NICE 1.1 / GREAT 1.5 / EXCELLENT 2.0), first
-- ball of the encounter 1.5, species new to the dex 1.1, and the catch
-- combo tier. Traded 1.5 still rides through the engine's own flag.
local expCtx = nil        -- {battle, mult} while a Let's Go catch pays out
local granting = nil      -- set across the applyShare loop for exp.gain

local function comboMult(n)
  if n <= 10 then return 1.1 end
  if n <= 20 then return 1.5 end
  if n <= 30 then return 2.0 end
  if n <= 40 then return 2.5 end
  return 3.0
end

-- the catch combo, persisted with the save (mod.save rides save.modData):
-- catching the same species again extends it, anything else restarts it
local function bumpCombo(species)
  local ms = V.mod and V.mod.save
  local combo = { species = species, count = 1 }
  if ms then
    local ok, held = pcall(ms.get, ms, "letsgoCombo")
    if ok and type(held) == "table" and held.species == species then
      combo.count = (tonumber(held.count) or 0) + 1
    end
    pcall(ms.set, ms, "letsgoCombo", combo)
  end
  return combo.count
end

function LetsGo.combo()
  local ms = V.mod and V.mod.save
  if not ms then return nil end
  local ok, held = pcall(ms.get, ms, "letsgoCombo")
  return ok and type(held) == "table" and held or nil
end

-- Called by CatchThrow the moment a capture resolves as caught, BEFORE
-- storeCaughtMon runs -- the dex is not yet marked, so "new species" is
-- still answerable, and the exp hooks fire inside storeCaughtMon.
function LetsGo.noteCatch(battle, info)
  local species = battle.enemy and battle.enemy.mon
                  and battle.enemy.mon.species
  local chain = species and bumpCombo(species) or 1
  if LetsGo.mode() ~= "full" then return end
  local mult = info.mult or 1
  if info.firstThrow then mult = mult * 1.5 end
  local dex = game().save and game().save.pokedex
  if dex and species and not dex.owned[species] then mult = mult * 1.1 end
  mult = mult * comboMult(chain)
  expCtx = { battle = battle, mult = mult }
end

-- The Gen VII scaled gain: a * b * L / 5, scaled by the RECEIVER's own
-- level, +1, then the traded boost and (for a catch) the bonus stack.
-- `s`, the split divisor, is 1 -- the award loop below hands every mon a
-- full share rather than a share of one.
--
-- `a` is the wild/trainer multiplier, 1.5 for a trainer's Pokemon. It is
-- absent from the catch-side write-ups of this formula for the simple
-- reason that a caught Pokemon is always wild, so it is always 1 there --
-- which is also why adding it leaves every catch payout exactly where it
-- was, verified against the published table in the suite.
local function scaledGain(c, mult)
  local b = (c.defeatedDef and c.defeatedDef.baseExp) or 50
  local L = c.level or 1
  local Lp = (c.mon and c.mon.level) or L
  local a = c.isTrainer and 1.5 or 1
  local scale = ((2 * L + 10) / (L + Lp + 10)) ^ 2.5
  local exp = math.floor(math.floor(a * b * L / 5) * scale + 1)
  if c.traded then exp = math.floor(exp * 1.5) end
  return math.max(1, math.floor(exp * (mult or 1)))
end

LetsGo._scaledGain = scaledGain   -- named for the suite
LetsGo._comboMult = comboMult

-- ------- FULL's auto-entry
--
-- The moment a wild battle's menu opens under FULL, capture mode opens
-- over it, with the last ball the player threw (or the first ball in the
-- bag). B backs out to the classic menu and stays out for that battle --
-- the bag's own ball route still re-enters the throw.
local function autoEnter()
  if LetsGo.mode() ~= "full" then return end
  if CatchThrow.active() then return end
  local ok, battle = pcall(function()
    return V.require("OverworldBattle").battle()
  end)
  if not (ok and battle) then return end
  local g = game()
  if not (g.stack and g.stack:top() == battle) then return end
  if battle.phase ~= "menu" then return end
  if battle.safari then return end      -- the safari menu is already a
                                        -- catch menu; its BALL row enters
  if battle.dramaticShapeDeclined then return end
  if not LetsGo.wantsMinigame(battle) then return end
  local ball = CatchThrow.pickBall()
  local full = LetsGo.fullWild(battle)
  -- An empty bag does NOT fall back to the classic menu under FULL. A
  -- Let's Go wild has no player Pokemon in it and a foe that never takes a
  -- turn, so the menu it would fall back to offers a FIGHT that cannot
  -- happen -- the encounter has to keep its own screen and its own exit.
  -- The capture screen opens empty-handed instead: the foe stands there,
  -- the readout says there is nothing to throw, and RUN is the way out.
  -- At CATCH ONLY there is no auto-entry to speak of and the bag is the
  -- only route in, so no balls simply means no throw, as it always did.
  if not (ball or full) then return end
  CatchThrow.begin(battle, ball, { consumed = false, canSwitch = true,
                                   fullWild = full })
end

-- ------- per frame, from the voxel pipeline's update hook
--
-- BEFORE OverworldBattle.update on the same tick, so the ball pose this
-- frame computes is the ball the scene render a moment later draws.
function LetsGo.update(dt)
  applyPrices()
  CatchThrow.update(dt)
  autoEnter()
end

-- ------- install: the two throw seams, the hooks, the input
--
-- Installed from main.lua AFTER every other input seam, so the capture's
-- pointer wraps sit outside them all while it aims.
local installed = false

function LetsGo.install()
  if installed then return end
  installed = true

  local mod = V.mod
  local BattleState = require("src.battle.BattleState")

  if not BattleState.dramaticShapeLetsGoHook then
    -- The bag's ball route: BagMenu has already consumed the ball and
    -- closed itself when this is called, so a session here owns a paid
    -- ball (cancel refunds it). Vanilla path untouched whenever the
    -- minigame cannot or should not run.
    local innerThrow = BattleState.throwBall
    function BattleState:throwBall(ball)
      if LetsGo.wantsMinigame(self) then
        if CatchThrow.begin(self, ball, {
             consumed = true, fullWild = LetsGo.fullWild(self),
           }) then return end
      end
      return innerThrow(self, ball)
    end

    -- The safari menu's BALL row: same interception, safari flavour --
    -- the ball count and the flee check belong to the safari turn, and
    -- CatchThrow hands back to safariEnemyTurn on a failure.
    local innerSafari = BattleState.safariAction
    function BattleState:safariAction(choice)
      if choice == "ball" and LetsGo.wantsMinigame(self)
         and self.safari and self.safari.balls > 0 then
        if CatchThrow.begin(self, "SAFARI_BALL",
                            { consumed = false, safari = true }) then
          return
        end
      end
      return innerSafari(self, choice)
    end

    BattleState.dramaticShapeLetsGoHook = true
  end

  -- a catch pays experience under FULL, exactly as a knockout would
  -- Never for a scripted demo: the old man's catch is a cutscene, nobody
  -- keeps the Pokemon, and the party it would pay may not exist yet
  -- (Yellow's Pallet intro runs before the lab gift). The engine's own
  -- flow does not reach either hook for a demo today -- oldManThrow ends
  -- the battle without storeCaughtMon or awardExp -- so this guards the
  -- INVARIANT rather than a live bug: a demo pays nothing, whatever route
  -- some later engine takes to get there.
  mod.hooks:wrap("battle.catch_exp", function(next_, ctx)
    if LetsGo.mode() == "full" and ctx and ctx.battle
       and ctx.battle.kind == "wild"
       and not LetsGo.scripted(ctx.battle) then
      return true
    end
    return next_(ctx)
  end)

  -- ------- the Let's Go distribution: every healthy party member, in full
  --
  -- The engine's own rule is that only the Pokemon that FOUGHT are paid,
  -- and they split one award between them; EXP.ALL exists to soften that.
  -- Let's Go deletes the whole arrangement -- everybody gains from
  -- everything, which is why that game ships no EXP.ALL at all -- and
  -- each one is measured against its OWN level, so the low member of a
  -- party pulls several times what the high one does from the same
  -- knockout.
  --
  -- Two ways in. A CATCH arrives with a bonus stack attached (throw
  -- grade, first ball, new species, combo) which `expCtx` carries. A
  -- KNOCKOUT under FULL takes the same distribution with no stack --
  -- those bonuses are rewards for the throw, and there was no throw.
  --
  -- Everything else -- CATCH ONLY, the row switched off, another mod's
  -- battle -- falls through to the engine's own split untouched.
  -- ------- and it is announced ONCE, not once per Pokemon
  --
  -- Six party members would otherwise mean six "X gained N EXP. Points!"
  -- boxes per knockout. The per-Pokemon lines are suppressed (the `false`
  -- to applyShare) and one card is shown instead -- see lib/ExpPanel.lua
  -- for why that is better than a faster wall of the same text.
  --
  -- The card is queued BEFORE the loop that fills it. That is not a race:
  -- applyShare applies its experience immediately and only QUEUES its
  -- messages, so the loop runs to completion synchronously here, while
  -- the queue does not reach the card's factory until later -- by which
  -- time `rows` is complete. Queueing it first is what puts the tally
  -- ahead of the "grew to level" chatter it is a summary of.
  local ExpPanel = V.require("ExpPanel")
  local function payParty(ctx, mult)
    local battle = ctx.battle
    local rows = {}
    battle:uiNext(function() return ExpPanel.new(battle.game, rows) end)
    granting = { mult = mult }
    local okAward, err = pcall(function()
      for _, mon in ipairs(battle.game.save.party) do
        if mon.hp > 0 then
          local exp0, lv0 = mon.exp, mon.level
          ctx.applyShare(mon, 1, false)
          rows[#rows + 1] = { mon = mon, gained = mon.exp - exp0,
                              from = lv0, to = mon.level }
        end
      end
    end)
    granting = nil
    if not okAward then error(err, 0) end
  end

  mod.hooks:wrap("battle.exp_award", function(next_, ctx)
    if ctx and LetsGo.scripted(ctx.battle) then return next_(ctx) end
    local cc = expCtx
    if cc and ctx and ctx.battle == cc.battle then
      expCtx = nil
      return payParty(ctx, cc.mult)
    end
    if LetsGo.mode() == "full" and ctx and ctx.battle then
      return payParty(ctx, 1)
    end
    return next_(ctx)
  end)

  -- and the amount, per receiving mon, while that loop runs
  mod.hooks:wrap("exp.gain", function(next_, c)
    if not granting then return next_(c) end
    return scaledGain(c, granting.mult)
  end)

  -- ------- FULL owns a wild encounter from its first frame
  --
  -- The engine's intro ends by sending the player's Pokemon out -- the
  -- back pic slides off, "Go! X!", the poof, the grow-in -- and a Let's
  -- Go wild has no player Pokemon in it at all. The send-out is exactly
  -- the LAST SIX rows of the intro queue when this event fires (built in
  -- BattleState's start, gated `not safari and not demo`), so they are
  -- stripped by SHAPE -- act, wait, act, say, POOF, act -- and left alone
  -- if a future engine moves them: the veil still hides the visuals, the
  -- engine just narrates a send-out that is not shown.
  --
  -- Stripping them leaves showPlayerBack TRUE for the whole battle, which
  -- is the flag the engine's own HUD path reads as "no player HUD" -- the
  -- player's side vanishes from the readout for free.
  --
  -- The veil goes up in the same breath: the capture table, installed
  -- before any session exists, so the whole encounter -- wipe, "Wild X
  -- appeared!", every beat between throws -- plays from the held head-on
  -- seat with the player's side out of the shot.
  mod.events:on("battle.started", function(payload)
    local b = payload and payload.battle
    if not (b and LetsGo.fullWild(b)) then return end
    if not (Voxel3D.available() and not vrOn()) then return end
    -- deliberately NOT gated on owning a ball: an empty bag still gets the
    -- Let's Go encounter (see autoEnter), so the send-out still has to go
    local q = b.queue
    local n = q and #q or 0
    if n >= 6 and type(q[n]) == "table" and q[n].fn
       and q[n - 1] and q[n - 1].anim == "POOF_ANIM"
       and q[n - 2] and q[n - 2].text
       and q[n - 3] and q[n - 3].fn
       and q[n - 4] and q[n - 4].wait
       and q[n - 5] and q[n - 5].fn then
      for _ = 1, 6 do table.remove(q) end
    end
    pcall(CatchThrow.veil, b)
  end)

  -- a battle ending sweeps everything: the capture epilogue, the veil, a
  -- session a script tore down, and the exp context if the payout never
  -- fired
  mod.events:on("battle.ended", function()
    expCtx = nil
    pcall(CatchThrow.onBattleEnded)
  end)

  CatchThrow.installInput()
end

return LetsGo
