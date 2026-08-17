-- LET'S GO: the whole party's experience, on one card.
--
-- Sharing experience to everybody has a cost the original game never had
-- to pay: six Pokemon means six "X gained N EXP. Points!" boxes for every
-- knockout, each needing its own press. That is the same information the
-- player wanted, delivered in the most tiring possible way -- and it is
-- worse than a wall of text, because the numbers arrive one at a time so
-- the one thing a shared payout is FOR (comparing them: the little one
-- gained five times what the big one did) can never be seen at once.
--
-- So the per-Pokemon lines are suppressed and this card is shown in their
-- place: one box, one press, every gain side by side, with a level-up
-- called out on the row it happened to. What the card cannot cover still
-- plays as it always did -- "X grew to level 6!", the stats window, and
-- any move learned -- because those are events, not a tally.
--
-- Drawn with the engine's own font and box, in the GB's own frame, so it
-- sits in a staged 3D battle exactly like every other battle panel.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ExpPanel = {}
ExpPanel.__index = ExpPanel

local Font = nil
local function font()
  if Font ~= nil then return Font or nil end
  local ok, F = pcall(require, "src.render.Font")
  Font = ok and F or false
  return Font or nil
end

-- the GB frame, in 8-pixel tiles
local TILE = 8
local COLS, ROWS = 20, 18
local ROW_H = 12          -- pixels between listed Pokemon

-- `rows` is filled by the award loop and read HERE, at draw time: the
-- loop runs to completion long before the battle queue reaches this
-- panel, so the table is always complete by the time it is shown.
function ExpPanel.new(game, rows)
  return setmetatable({ game = game, rows = rows or {}, t = 0 }, ExpPanel)
end

function ExpPanel:update(dt)
  self.t = (self.t or 0) + (dt or 0)
  local input = self.game and self.game.input
  if not input then return end
  -- a beat of deafness: the press that dismissed whatever came before
  -- must not dismiss this card in the same breath
  if self.t < 0.12 then return end
  if input:wasPressed("a") or input:wasPressed("b") then
    self.game.stack:pop()
    if self.onDone then self.onDone() end
  end
end

function ExpPanel:draw()
  local F = font()
  if not F then return end
  local rows = self.rows or {}
  local n = #rows
  if n == 0 then return end

  -- bottom-anchored and only as tall as it needs to be, so a two-Pokemon
  -- party does not black out the fight behind it
  local th = 3 + math.ceil(n * ROW_H / TILE)
  th = math.min(th, ROWS - 1)
  local ty = ROWS - th
  F.drawBox(0, ty, COLS, th)

  love.graphics.setColor(0, 0, 0, 1)
  local x0 = TILE
  local y0 = (ty + 1) * TILE + 2
  F.draw("EXP GAINED", x0, y0)

  for i, r in ipairs(rows) do
    local y = y0 + ROW_H + (i - 1) * ROW_H
    if y > (ROWS - 1) * TILE then break end
    local mon = r.mon
    local name = mon.nickname
                 or (self.game.data.pokemon[mon.species] or {}).name
                 or tostring(mon.species)
    F.draw(name, x0, y)
    -- a level-up is called out where it happened rather than left to the
    -- message that follows, so the card reads as the whole story
    if (r.to or 0) > (r.from or 0) then
      local up = ("L%d"):format(r.to)
      F.draw(up, 108 - F.width(up), y)
    end
    local amt = ("+%d"):format(r.gained or 0)
    F.draw(amt, 152 - F.width(amt), y)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return ExpPanel
