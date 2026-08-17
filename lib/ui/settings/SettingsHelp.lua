-- SELECT on a row explains what it does.
--
-- ------- why this exists at all
--
-- Every setting in this mod has ALWAYS carried a paragraph of help. It goes
-- into the schema handed to the mod manager (ModSetting:schema takes it), it
-- has been written and kept up to date beside every row in main.lua's
-- SETTINGS -- and nothing in the engine has ever drawn it. Not the OPTIONS
-- menu, whose row is a label and a value and has no room for a third thing;
-- not the mod manager's own page, which renders the same two lines. It was
-- authored, structured, accurate prose sitting in a field with no reader.
--
-- So it gets one. A row on this mod's menus says what it IS on one line and
-- what it is SET TO on the next, and SELECT says what that means -- which is
-- the question a row like RENDER DIST or 2D-3D B cannot answer in eighteen
-- characters however the label is worded.
--
-- SELECT rather than a button that already does something: A steps a setting,
-- B leaves, and the d-pad moves. SELECT is free on a menu -- the mod's own
-- SELECT hotkey is installed on OverworldController:handleInput, which only
-- runs while the overworld is the top state, so a menu can have the button
-- without taking anything from the map.
--
-- ------- the shape of it
--
-- The game's own dialogue box: drawn with Font.drawBox, so the border is the
-- ROM's own glyphs and a mod-supplied font theme retextures this along with
-- everything else (Font.BORDER) -- and anchored to the BOTTOM of the screen
-- with the menu still visible above it, which is where this game has put
-- every line of text anybody has ever read in it.
--
-- Sized to what it holds rather than to the screen. Each description is one
-- sentence, so most of these are five or six tiles tall and the row being
-- asked about is still on screen over the top of the box. A sentence long
-- enough to overflow scrolls instead of growing past MAX_LINES, a line at a
-- time on the d-pad -- which is a fallback, not the design: the answer to a
-- description that needs scrolling is a shorter description.

-- the mod namespace (see main.lua)
local V = ...

local Font = require("src.render.Font")
local Theme = require("src.ui.Theme")
local PaletteFX = require("src.render.PaletteFX")

local SettingsHelp = {}
SettingsHelp.__index = SettingsHelp

-- NOT opaque: the menu stays drawn underneath, so the row being asked about
-- is still on screen above the box. That is most of why the box is only as
-- tall as it needs to be.
SettingsHelp.isOpaque = false

-- The box spans the screen's twenty tiles and its border owns the outer ring,
-- so text runs from tile 1. Seventeen columns rather than eighteen: tile 18
-- is kept clear for the more-arrow, which would otherwise land on top of the
-- last character of any line that filled the width.
local COLS = 17
local PEN_X = 8
local SCREEN_ROWS = 18
-- title, plus the body, plus the two border rows
local CHROME_ROWS = 3
-- A sentence needing more than this scrolls. Eight lines of seventeen is 136
-- characters, which is a long sentence and a box two thirds up the screen.
local MAX_LINES = 8

-- Break a string into lines that fit, on word boundaries. Unbounded, unlike
-- StadiumScreen's -- that one is capping a save path to what a fixed plate can
-- show, and this one is the whole point of the screen.
local function wrapped(str, cols)
  cols = cols or COLS
  local lines, line = {}, nil
  for word in tostring(str or ""):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if #try <= cols then
      line = try
    else
      if line then lines[#lines + 1] = line end
      -- a word longer than the line is broken across lines rather than cut;
      -- nothing in the help text is that long today, but losing the end of a
      -- sentence silently is not a failure mode worth leaving open
      while #word > cols do
        lines[#lines + 1] = word:sub(1, cols)
        word = word:sub(cols + 1)
      end
      line = word
    end
  end
  if line then lines[#lines + 1] = line end
  return lines
end

SettingsHelp.wrapped = wrapped

function SettingsHelp.new(game, title, body)
  return setmetatable({
    game = game,
    title = tostring(title or ""):gsub("%.%.$", ""),
    lines = wrapped(body),
    top = 0,
  }, SettingsHelp)
end

-- How many body lines this box shows: all of them, unless there are more than
-- a box is allowed to be tall.
function SettingsHelp:bodyRows()
  return math.min(#self.lines, MAX_LINES)
end

function SettingsHelp:maxTop()
  return math.max(0, #self.lines - self:bodyRows())
end

-- Every button that could mean "done" closes it, including SELECT itself --
-- the press that opened the box is the one a player is most likely to reach
-- for to get rid of it. A is in there too: it steps a setting everywhere else
-- on these menus, and stepping one you cannot see would be worse than an
-- extra way out.
local DISMISS = { "a", "b", "start", "select" }

function SettingsHelp:update()
  local input = self.game and self.game.input
  if not input then return end
  local maxTop = self:maxTop()
  -- the d-pad only does anything when there is something below the fold; a
  -- box showing its whole sentence has nowhere to go and says so by not
  -- moving
  if input:wasPressed("down") then
    self.top = math.min(maxTop, self.top + 1)
    return
  elseif input:wasPressed("up") then
    self.top = math.max(0, self.top - 1)
    return
  end
  for _, btn in ipairs(DISMISS) do
    if input:wasPressed(btn) then
      local stack = self.game.stack
      if self.game.data then
        require("src.core.Sound").play(self.game.data, "Press_AB")
      end
      if stack and stack:top() == self then stack:pop() end
      return
    end
  end
end

function SettingsHelp:draw()
  local body = self:bodyRows()
  local th = body + CHROME_ROWS
  local ty = SCREEN_ROWS - th          -- anchored to the bottom of the screen
  Font.drawBox(0, ty, 20, th)
  love.graphics.setColor(0, 0, 0, 1)
  -- the row's own name, so the box says what it is about even where it covers
  -- the row that was asked
  Font.draw(self.title, PEN_X, (ty + 1) * 8)
  for i = 1, body do
    local line = self.lines[self.top + i]
    if not line then break end
    Font.draw(line, PEN_X, (ty + 1 + i) * 8)
  end
  -- the same marker the options list uses for "there is more below this", so
  -- it means here what it means there
  if self.top < self:maxTop() then
    Font.drawCode(Theme.moreArrow, 144, (ty + th - 2) * 8)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- Game:draw stops at the first state that HAS this method, so without one the
-- box would inherit whatever is underneath -- which is a menu of ours, whose
-- answer happens to be right. Stated anyway: the reason that answer is right
-- is not a property of this screen, and a future menu that paints something
-- of its own would silently repaint this box with it.
function SettingsHelp:sgbPalettes(game)
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

return SettingsHelp
