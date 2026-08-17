-- Where a shiny SHOWS on the flat art: the battle pics and the status page.
--
-- The Stadium models carry genuinely recoloured texels (see ShinyPalette and
-- the extraction). Everything drawn as a Game Boy pic cannot, because the
-- engine bakes a species palette into an image cache keyed by path and
-- palette name -- a cache with no notion of WHICH Rattata is being drawn. So
-- the flat side is answered two ways:
--
--   the battle pic     tinted at draw time, per side, with the multiply
--                      ShinyPalette.tintFor derives from that species' own
--                      shiny slide. Under ADVANCED (`redpp`, the pokered-gbc
--                      colour pack) the pic is at its most colourful and the
--                      tint reads clearly; under the DMG modes there is
--                      barely any colour to shift, which is why the status
--                      page also carries a plain, mode-proof MARK.
--   the status page    a star beside the level, drawn in the engine's own
--                      GB pixel grid so it is palette-processed like every
--                      other pixel on the screen rather than floating over
--                      the finished frame.
--
-- Both are monkeypatches, idempotent by sentinel, the pattern the rest of
-- this mod uses (OverworldBattle.install, Stadium.install). The summary
-- screen has no hook at all -- there is no `ui.summary.*` anywhere in the
-- engine -- so a wrap is the only route to it, and it is deliberately a thin
-- one: draw the engine's screen, then add one glyph.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Shiny = V.require("Shiny")
local ShinyPalette = V.require("ShinyPalette")

local ShinyUI = {}

-- ------- the tint, applied to one draw
--
-- Lifted in shape from OverworldBattle.withTint, and for the same reason it
-- exists there: the pics layer sets its own colour many times over as it
-- draws (the faint slide's fade, the damage blink), so the way to tint the
-- result without clobbering any of that is to multiply every colour it sets
-- on its way past. Restored unconditionally, including on error, because a
-- leaked setColor would tint the entire rest of the frame.
function ShinyUI.withTint(tint, fn, ...)
  if not tint then return fn(...) end
  local r, g, b = tint[1] or 1, tint[2] or 1, tint[3] or 1
  if r > 0.999 and g > 0.999 and b > 0.999 then return fn(...) end
  local gfx = love.graphics
  local setColor = gfx.setColor
  gfx.setColor = function(cr, cg, cb, ca, ...)
    if type(cr) == "table" then
      return setColor({ (cr[1] or 1) * r, (cr[2] or 1) * g, (cr[3] or 1) * b,
                        cr[4] }, cg, ...)
    end
    if cr == nil then return setColor(cr, cg, cb, ca, ...) end
    return setColor(cr * r, (cg or 1) * g, (cb or 1) * b, ca, ...)
  end
  local ok, err = pcall(fn, ...)
  gfx.setColor = setColor
  setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
end

-- The tint for a mon, or nil when it is not shiny or we have no colours.
function ShinyUI.tintFor(mon, data)
  if not (mon and Shiny.isShiny(mon)) then return nil end
  local def = data and data.pokemon and data.pokemon[mon.species]
  local dex = def and def.dex
  if not dex then return nil end
  return ShinyPalette.tintFor(dex)
end

-- ------- the star
--
-- Drawn as rectangles rather than as a font character because the Game Boy
-- charmap has no star, and a letter would read as a typo. Four spokes and a
-- centre, in the same near-black the screen's text uses, so the palette pass
-- treats it exactly like a glyph -- under ADVANCED and under every DMG mode
-- alike.
--
-- Seven pixels square, which is the largest that fits the gap beside the
-- level without touching the DrawLineBox bracket at column 19.
function ShinyUI.drawStar(px, py)
  local g = love.graphics
  local r, gg, b, a = g.getColor()
  g.setColor(0, 0, 0, 1)
  -- vertical, horizontal, then the four diagonal nubs
  g.rectangle("fill", px + 3, py, 1, 7)
  g.rectangle("fill", px, py + 3, 7, 1)
  g.rectangle("fill", px + 1, py + 1, 1, 1)
  g.rectangle("fill", px + 5, py + 1, 1, 1)
  g.rectangle("fill", px + 1, py + 5, 1, 1)
  g.rectangle("fill", px + 5, py + 5, 1, 1)
  g.setColor(r, gg, b, a)
end

-- ------- install

function ShinyUI.install()
  ShinyUI.installSummary()
end

-- The status page. Wraps the draw and adds the star afterwards, so the
-- engine's own layout is untouched and a layout change upstream costs us
-- the glyph's position and nothing else.
function ShinyUI.installSummary()
  local ok, SummaryMenu = pcall(require, "src.ui.SummaryMenu")
  if not ok or type(SummaryMenu) ~= "table" then return end
  if SummaryMenu.dramaticShapeShiny then return end
  local inner = SummaryMenu.draw
  if type(inner) ~= "function" then return end

  function SummaryMenu:draw(...)
    local out = { inner(self, ...) }
    -- page 1 only: page 2 wipes the block the level sits in
    -- (status_screen.asm ClearScreenArea over (9,2)), so a mark left there
    -- would be half-erased by the engine's own clear.
    if self.page == 1 and Shiny.isShiny(self.mon) then
      -- beside PrintLevel at (14,2): column 13, row 2, in the gap the
      -- level's own leading space leaves
      pcall(ShinyUI.drawStar, 104, 17)
    end
    return unpack(out)
  end

  -- The summary PIC, through its PALETTE.
  --
  -- Recolouring the sprite's pixels here does NOT work, and it is worth
  -- writing down why rather than leaving it to be re-attempted: the summary
  -- art is four-shade DMG grey, and the screen's colour is applied
  -- afterwards by the palette pass over the finished frame. Whatever RGB is
  -- put in the ImageData is remapped away by it. The colour of that pic
  -- lives in the palette and nowhere else, so the palette is what has to
  -- move. (Tried it, shot it, reverted it.)
  --
  -- This is the ADVANCED-palette answer, and it is better than a multiply:
  -- SetPal_StatusScreen hands the pic zone the species palette
  -- (PaletteFX.monPal), and sgbPalettes is a method on the MENU, so unlike
  -- the battle pic's image cache it knows which individual is on screen.
  -- Running those four colours through the species' own shiny transform
  -- gives the summary a genuinely recoloured Pokemon -- brightening
  -- included, which a draw-colour multiply cannot do.
  --
  -- Only ZONE entries are touched. The first palette the engine returns is
  -- the whole-screen HP-bar one, and rotating that would recolour the text.
  local innerPal = SummaryMenu.sgbPalettes
  if type(innerPal) == "function" then
    function SummaryMenu:sgbPalettes(game, ...)
      local out = innerPal(self, game, ...)
      if type(out) ~= "table" or not Shiny.isShiny(self.mon) then return out end
      local def = game and game.data and game.data.pokemon
                  and game.data.pokemon[self.mon.species]
      local fn = def and def.dex
                 and ShinyPalette.transform(ShinyPalette.forDex(def.dex))
      if not fn then return out end
      for _, z in ipairs(out) do
        if type(z) == "table" and z.w and z.h and type(z.colors) == "table" then
          -- copied, never mutated in place: monPal hands back the dataset's
          -- own palette table, and writing through it would recolour every
          -- Pokemon of the species everywhere for the rest of the process
          local cols = {}
          for i, c in ipairs(z.colors) do
            if type(c) == "table" and c[1] then
              local r, g, b = fn(c[1], c[2], c[3])
              cols[i] = { r, g, b }
            else
              cols[i] = c
            end
          end
          z.colors = cols
        end
      end
      return out
    end
  end

  SummaryMenu.dramaticShapeShiny = true
end

-- ------- the battle pics are NOT tinted here any more
--
-- There used to be a third wrap in this file: a multiply over
-- BattleState:drawPicsLayer, with the tint above. It is gone, and the reason
-- is worth keeping so it is not put back.
--
-- A multiply can only DARKEN. Shiny Gyarados is blue turning red, and the
-- nearest a multiply gets to that is a dimmer blue -- so every species whose
-- shiny is lighter, or is a rotation rather than a dimming, read as the
-- ordinary one with the brightness down. And the engine's pic layer draws
-- BOTH sides in one call, so a shiny also dimmed the ordinary mon opposite it.
--
-- lib/ShinyPics.lua replaces it by moving the PALETTE instead, which is where
-- a battle pic's colour actually lives: getImage bakes the four DMG shades
-- into the species palette once and caches the result, so handing that bake a
-- shiny palette (under a cache name of its own) gives a genuinely recoloured
-- pic -- brightening included -- for one side alone.
--
-- ShinyUI.withTint and ShinyUI.tintFor stay: the 3D path still uses them for
-- the per-side canvas, and they are the only tint left in the mod.

return ShinyUI
