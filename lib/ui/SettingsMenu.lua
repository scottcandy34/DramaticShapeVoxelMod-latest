-- This mod's settings, in categories, on menus of their own.
--
-- ------- why the flat list had to end
--
-- Every setting used to be spliced straight into the engine's OPTIONS list,
-- one unbroken block of fourteen rows after the pipeline rows. OptionRows
-- shows FOUR boxes at a time (src/ui/OptionRows.VISIBLE), so that block alone
-- was four screens of scrolling inside a list that already carried twenty
-- engine rows -- and a player looking for SHADOWS had to know it was in there
-- somewhere, past the wireframe and the horizon bend.
--
-- The engine has no grouping to borrow: a row descriptor is
-- { id, label, value, step, activate } and nothing else. No headers, no
-- sections, no pages. What it DOES have is `activate`, and a state stack that
-- any state may push onto -- which is how the engine's own MODS and CONTROLS
-- rows work (src/ui/OptionsMenu.lua). So the categories are real screens.
--
-- ------- how the split was chosen
--
-- Not invented here: the mod already sorted its own settings, in the `full`
-- flag on each SETTINGS entry. `full` marks a row the FULL preset does NOT
-- take away, and the reasoning written next to each one is always the same
-- -- this is a question about the HARDWARE, or about the GAME, not a knob on
-- the diorama FULL is a preset for.
--
-- So 3D WORLD is exactly the set FULL owns, which is why it needs no special
-- case to disappear under FULL: every child filters itself out and the
-- category goes with them (see rows). PERFORMANCE is the three rows marked
-- `full` for cost -- FOREST FX among them, on its own comment's reasoning
-- ("`full` for the AA reason: additive shafts are fill rate"). BATTLES and VR
-- are the two features that are not about the look at all.
--
-- ------- what did NOT change
--
-- Nothing that persists. Every ModSetting keeps its key, its ladder and its
-- row id, so options.lua is byte-identical for a player who upgrades and
-- changes nothing -- see lib/ModSetting.lua for why the key is the only
-- identity a setting has. The hotkeys are untouched too, which is what makes
-- the nesting affordable: a buried row is still one keypress away.

-- the mod namespace (see main.lua)
local V = ...

local OptionRows = require("src.ui.OptionRows")
local PaletteFX = require("src.render.PaletteFX")

local SettingsMenu = {}
SettingsMenu.__index = SettingsMenu

-- Opaque like the OPTIONS menu it sits on: the screen underneath is fully
-- covered, so there is no reason to pay for drawing it.
SettingsMenu.isOpaque = true

SettingsMenu.ROOT = "root"
SettingsMenu.ROOT_LABEL = "DRAMATIC SHAPE.."

-- Row ids live in a namespace of their own -- "menu." rather than a setting
-- key -- so they can never collide with the "DRAMATIC_SHAPE:<key>" ids the
-- settings rows have carried since the beginning.
function SettingsMenu.id(catId)
  return "DRAMATIC_SHAPE:menu." .. catId
end

-- ------- the categories, in menu order
--
-- `summary` is the second line of the category's own row, the way MODS reads
-- "%d INSTALLED" on the engine's menu. Where one setting IS the category --
-- 3D-BTL for the battles, VR for the headset -- it says that setting's
-- current rung, which is the thing a player actually wants to know without
-- opening it. Where no single row speaks for the rest, it counts them, which
-- is honest rather than arbitrary.
SettingsMenu.CATEGORIES = {
  { id = "world", label = "3D WORLD..",
    help = "The diorama itself: how far the world bends, how much of it is "
      .. "drawn, what the water does and what hour it is outdoors." },
  { id = "battles", label = "BATTLES..",
    summary = function() return V.require("OverworldBattle").setting:valueLabel() end,
    help = "What a fight is drawn over, how it is framed, and how a ball is "
      .. "thrown." },
  { id = "perf", label = "PERFORMANCE..",
    help = "What the look costs -- the three most expensive things in the "
      .. "frame after the geometry itself." },
  { id = "vr", label = "VR..",
    summary = function() return V.require("VR").setting:valueLabel() end,
    help = "PCVR through OpenXR, and the one comfort setting that belongs to "
      .. "the headset alone." },
}

-- ------- help for the rows that are not settings
--
-- The thirteen settings each carry their own paragraph in main.lua's SETTINGS,
-- next to the row it explains. What is left is the two pipeline rows -- whose
-- descriptors belong to the ENGINE, so there is nowhere in them to put this --
-- and the ROM import, which is an action rather than a setting and has no
-- SETTINGS entry to live in.
local ROW_HELP = {
  ["pipeline:voxel"] = "The overworld extruded into real geometry and walked "
    .. "by a 3D camera, with the numbered rungs its angle in degrees.",
  ["pipeline:tiltshift"] = "A tilt-shift blur that sells the miniature-model "
    .. "look, sharp across the middle and softening above and below it.",
  ["DRAMATIC_SHAPE:stadiumRom"] = "Imports the Pokemon Stadium (US) 1.0 "
    .. "cartridge that 3D-BTL's STADIUM rungs need.",
}

-- ------- what the menus are built from
--
-- SETTINGS lives in main.lua, next to the help text that goes with each row
-- and the comments explaining every `when` and `full`. It is handed here
-- rather than moved, so this file stays about PRESENTATION and that one stays
-- the single place the mod's settings are declared.
local settings = {}
local pipelineRows = {}

function SettingsMenu.define(list)
  settings = list or {}
end

-- What SELECT shows for a row: the setting's own paragraph out of SETTINGS,
-- the category's out of CATEGORIES, or one of the three above for the rows
-- that have nowhere else to keep it.
--
-- Looked up BY ID rather than hung on the row as a field, because two of
-- these rows are the engine's own tables reused verbatim -- and annotating
-- somebody else's table is how a mod ends up owning a field it never meant
-- to. nil for a row with nothing to say, which SELECT reads as "no box".
function SettingsMenu.helpFor(id)
  if ROW_HELP[id] then return ROW_HELP[id] end
  for _, cat in ipairs(SettingsMenu.CATEGORIES) do
    if SettingsMenu.id(cat.id) == id then return cat.help end
  end
  for _, entry in ipairs(settings) do
    if "DRAMATIC_SHAPE:" .. entry[1].key == id then return entry[2] end
  end
  return nil
end

-- VOXEL and T-SHIFT are the ENGINE's row descriptors (src/render/Pipelines
-- .rows), captured by the options hook on its way past and shown here instead
-- of at the top level. Reused verbatim, tables and all: they persist in
-- save.options.pipelines through their own step functions, and rebuilding
-- them here would be a second implementation of a thing the engine already
-- got right.
function SettingsMenu.setPipelineRows(rows)
  pipelineRows = rows or {}
end

-- ------- a step here has the same consequences as a step anywhere
--
-- Two of these settings PIN something else when they change: 3D-BTL holds
-- BATTLE LAYOUT at OG while a fight can be staged on the map, and FULL holds
-- DAYTIME at SYNC while it owns that row. Both used to happen because every
-- step on the OPTIONS menu reran the ui.options.rows hook, which does the
-- pinning on its way past.
--
-- Nothing reruns that hook from in here, so the pin is asked for directly.
-- main.lua supplies it, because WHICH values follow which is a question about
-- the mod's settings and not about the menu they are on.
local onChanged = nil

function SettingsMenu.setOnChanged(fn)
  onChanged = fn
end

local function isFull()
  local Pipelines = require("src.render.Pipelines")
  return V.require("VoxelState").isFull(Pipelines.level("voxel"))
end

-- The one rule that decides whether a setting is on a menu, lifted unchanged
-- from the options hook it used to live in.
--
-- FULL: a preset that owns the look, so the rows that describe the look go
-- with it. And a row whose own switch is off the table this frame (BACK
-- SPRITES, which needs a staged fight to be about) is left off with it. The
-- mod manager's page carries every one of them either way.
local function offered(entry, full)
  return (entry.full or not full) and (not entry.when or entry.when())
end

-- The rows of one category, or of the root menu. PURE -- no state, no stack,
-- no side effects -- so a caller that only wants to know what is on a menu
-- (a test, or the root menu asking whether a category has anything in it)
-- does not have to push a screen to find out.
function SettingsMenu.rows(catId, game)
  local full = isFull()
  local out = {}
  if catId == SettingsMenu.ROOT then
    for _, row in ipairs(pipelineRows) do
      -- FULL owns the blur exactly as it owns the wireframe and the horizon
      -- bend, so T-SHIFT comes off with them
      if not (full and row.id == "pipeline:tiltshift") then
        out[#out + 1] = row
      end
    end
    -- ------- settings that belong to no category
    --
    -- A row can name SettingsMenu.ROOT as its `cat` and sit on the top-level
    -- menu next to the pipeline rows. For a setting that is about the GAME
    -- rather than about one of the four things the categories are for --
    -- SHINY ODDS is the first -- burying it under a heading it does not
    -- belong to is worse than the flat list this menu was built to end.
    --
    -- Above the categories, because these are rows you CHANGE and those are
    -- rows you OPEN: everything with a value on it stays together at the top
    -- of the screen, and the "..." rows read as the way further in.
    for _, entry in ipairs(settings) do
      if entry.cat == SettingsMenu.ROOT and offered(entry, full) then
        out[#out + 1] = entry[1]:row()
      end
    end
    for _, cat in ipairs(SettingsMenu.CATEGORIES) do
      local kids = SettingsMenu.rows(cat.id, game)
      -- An EMPTY category is not offered. This is the whole of what makes
      -- 3D WORLD disappear under FULL and VR disappear off Windows: no
      -- special case, just nothing left inside to open.
      if kids[1] then
        out[#out + 1] = {
          id = SettingsMenu.id(cat.id),
          label = cat.label,
          value = cat.summary
            or function() return ("%d SETTINGS"):format(#SettingsMenu.rows(cat.id, game)) end,
          activate = function(g)
            g.stack:push(SettingsMenu.new(g, cat.id))
          end,
        }
      end
    end
    -- ------- and the ROM import, last, on the top-level menu
    --
    -- An ACTION and not a setting: there is no rung to store, nothing for the
    -- mod manager's page to persist and nothing to restore on the next boot,
    -- so it is appended rather than living in SETTINGS.
    --
    -- On the ROOT menu rather than under the battles whose STADIUM rungs it
    -- unlocks. It is a piece of one-time SETUP -- point the mod at a cartridge
    -- and wait while it builds -- and a player who has been told to import a
    -- ROM should find the row where the mod begins, not two levels down a
    -- category they have no reason to open until it has worked. Last, because
    -- the categories are what the menu is FOR.
    local ok, importRow = pcall(function()
      return V.require("StadiumRomPick").row()
    end)
    if ok and importRow then out[#out + 1] = importRow end
    return out
  end
  for _, entry in ipairs(settings) do
    if entry.cat == catId and offered(entry, full) then
      out[#out + 1] = entry[1]:row()
    end
  end
  return out
end

-- ------- red ink for the mod's row on the OPTIONS menu
--
-- love.graphics.setColor CANNOT do this, and it is worth writing down why so
-- nobody spends an afternoon on it. Twice over:
--
--   1. The glyph atlas is BLACK ink on transparent (tools/extract/font.py),
--      and Font.drawCode is a plain love.graphics.draw, which LOVE tints
--      MULTIPLICATIVELY. black x red is black.
--   2. Even if it drew red, the palette shader (PaletteFX.shader) keys on the
--      RED CHANNEL alone and throws G and B away -- r > 0.83 ? c0 : ... So a
--      red pixel lands in c0, the LIGHTEST slot: white text on white paper.
--
-- What actually happens on this screen is that setColor picks a SHADE and the
-- zone palette picks the COLOR. Black text is c3 and the white box fill is
-- c0, so a zone whose c3 is red draws red text on paper that has not moved.
-- The engine does the same thing for the party menu's HP bars
-- (src/ui/PartyMenu.lua), which is the pattern this follows.
SettingsMenu.INK = { 255, 0, 0 }

-- Built by copying MEWMON -- the palette the OPTIONS menu already wears --
-- and replacing ONLY the ink slot, rather than inventing four colors. Red,
-- Blue and Yellow ship different MEWMON tables, and this way the paper under
-- the row is the same white as the row above it in all three.
function SettingsMenu.redPalette(data)
  local base = PaletteFX.pal(data, "MEWMON")
  if not base then return nil end
  local out = { base[1], base[2], base[3], base[4] }
  -- SGB INV REVERSES the table (PaletteFX.effectiveColors, INV_MAP), so under
  -- it the ink is the first slot and the paper the last. Put the red where it
  -- will land on the INK either way: without this the row draws as a solid
  -- red block with white letters cut out of it.
  --
  -- The other modes need nothing. OG, OG INV and CLASSIC discard the table
  -- outright and substitute their own, so the row simply draws monochrome --
  -- which is correct: the player asked for a screen with no colors in it.
  out[PaletteFX.mode == "gbc_inv" and 1 or 4] = SettingsMenu.INK
  return out
end

-- The two TEXT lines of the row in `slot` (1..OptionRows.VISIBLE), and only
-- those. OptionRows.draw puts the label at x=16 and the value at x=24 -- tiles
-- 2 and 3 -- on the second and third rows of each four-tile box. Tiles 0 and
-- 19 are the box's own borders and tile 1 is the cursor, and all three are
-- black glyphs that would turn red along with the text if the band spanned
-- the whole row.
function SettingsMenu.rowZone(data, slot)
  local pal = SettingsMenu.redPalette(data)
  if not pal then return nil end
  local top = (slot - 1) * 4 + 1
  return PaletteFX.zone(pal, 2, top, 18, top + 1)
end

-- ------- the screen
--
-- Deliberately NOT an OptionsMenu instance, though the update loop below is
-- modelled on its. main.lua monkey-patches OptionsMenu.update on the CLASS,
-- and that patch rebuilds self.rows from OptionsMenu.new whenever the voxel
-- level or the battle rows change -- which would replace a submenu's rows
-- with the whole top-level OPTIONS list under the player's cursor. A state of
-- our own cannot be caught by it.
--
-- It still renders through OptionRows, so it is the same four boxes, the same
-- cursor and the same bottom line as every other menu in the game.
function SettingsMenu.new(game, catId)
  local self = setmetatable({
    game = game,
    cat = catId or SettingsMenu.ROOT,
    index = 1,
    scroll = 0,
  }, SettingsMenu)
  self.rows = SettingsMenu.rows(self.cat, game)
  self.sig = SettingsMenu.signature(self.rows)
  return self
end

function SettingsMenu.signature(rows)
  local ids = {}
  for i, row in ipairs(rows) do ids[i] = tostring(row.id) end
  return table.concat(ids, "\1")
end

-- The bottom line is the only place on this screen to say anything that is
-- not a row: OptionRows' four boxes fill everything above it and there is no
-- header slot. It spends that line on the two buttons that are not obvious.
--
-- It used to carry the category's NAME instead, for orientation. The hint
-- won: a binding nobody knows about is worth nothing, and where the player is
-- was just answered by the row they pressed A on. Sixteen characters of the
-- eighteen the line has, which is also why the name could not stay -- "BACK:
-- PERFORMANCE" is seventeen on its own.
SettingsMenu.BACK_LABEL = "B BACK  SEL HELP"

function SettingsMenu:backLabel()
  return SettingsMenu.BACK_LABEL
end

-- A category's contents can change while the player is looking at them: 3D-BTL
-- gives and takes BACK SPRITES, VR gives and takes SMOOTH TURN, and stepping
-- VOXEL onto FULL empties 3D WORLD outright. Rebuilt only when the LIST
-- actually differs, so the common case -- every other rung of every other row
-- -- costs one string compare.
function SettingsMenu:refresh()
  local rows = SettingsMenu.rows(self.cat, self.game)
  local sig = SettingsMenu.signature(rows)
  if sig == self.sig then return end
  -- Follow the row the cursor was ON rather than the slot it was in: a row
  -- can appear ABOVE the one just used, which would otherwise slide the
  -- cursor onto its neighbour. The bottom line follows itself.
  local wasBack = self.index > #self.rows
  local wasOn = self.rows[self.index] and self.rows[self.index].id
  self.rows, self.sig = rows, sig
  self.index, self.scroll = 1, 0
  if wasBack then
    self.index = #rows + 1
  else
    for i, row in ipairs(rows) do
      if wasOn and row.id == wasOn then self.index = i break end
    end
  end
end

local function pop(self)
  local stack = self.game and self.game.stack
  if self.game and self.game.data then
    require("src.core.Sound").play(self.game.data, "Press_AB")
  end
  if stack and stack:top() == self then stack:pop() end
end

-- The engine's own options loop (src/ui/OptionsMenu.update), including its
-- two conventions worth naming: `activate` SHADOWS `step` and fires on A
-- alone, and the bottom line is a synthetic index past the end of the list
-- rather than a row, so nothing a category contains can orphan the way out.
function SettingsMenu:update()
  local input = self.game and self.game.input
  if not input then return end
  local rows = self.rows
  local back = #rows + 1
  local changed = false
  if input:wasPressed("up") then
    self.index = self.index - 1
    if self.index < 1 then self.index = back end
  elseif input:wasPressed("down") then
    self.index = self.index + 1
    if self.index > back then self.index = 1 end
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    local row = rows[self.index]
    if row and row.activate then
      if input:wasPressed("a") then row.activate(self.game) end
    elseif row and row.step then
      changed = row.step(self.game, dir) and true or false
    elseif input:wasPressed("a") then
      pop(self)
      return
    end
  elseif input:wasPressed("select") then
    -- SELECT explains the row the cursor is on. Every row on these menus has
    -- something to say -- the settings have carried a paragraph each since
    -- they were written, and nothing has ever drawn it (see SettingsHelp) --
    -- but a row that does not is simply left alone rather than opening an
    -- empty box.
    local row = rows[self.index]
    local help = row and SettingsMenu.helpFor(row.id)
    if help and self.game.stack then
      self.game.stack:push(
        V.require("SettingsHelp").new(self.game, row.label, help))
    end
    return
  elseif input:wasPressed("b") or input:wasPressed("start") then
    -- B and START both, like every other menu -- and one level only: this
    -- pops US, leaving the OPTIONS menu underneath exactly as the player
    -- left it, with its own onCancel still to fire when they leave THAT.
    pop(self)
    return
  end
  if changed then
    -- before the rebuild, not after: pinning can itself change which rows are
    -- offered (3D-BTL switched on takes BACK SPRITES from off the table to on
    -- it), and refresh has to see the settled answer
    if onChanged then pcall(onChanged, self.game) end
    if self.game.writeOptions then
      pcall(self.game.writeOptions, self.game)
    end
  end
  self:refresh()
  self.scroll = OptionRows.clampScroll(self.index, self.scroll, #self.rows,
                                       #self.rows + 1)
end

function SettingsMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll,
                  self:backLabel(), #self.rows + 1)
end

-- REQUIRED, even though nothing here is red.
--
-- Game:draw walks the stack from the top and stops at the first state that
-- HAS this method, not the first that answers something. Without one of our
-- own the walk would fall through to the OPTIONS menu underneath -- whose
-- sgbPalettes main.lua has patched to paint the mod's row red -- and that
-- zone is addressed by SLOT, so it would land on whatever this menu happens
-- to be showing in the same box.
--
-- MEWMON is what the OPTIONS menu wears, so a submenu is the same paper.
function SettingsMenu:sgbPalettes(game)
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

return SettingsMenu
