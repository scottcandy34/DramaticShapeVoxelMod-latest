-- STADIUM battles: importing the ROM, instead of being told where to put it.
--
-- The mod ships no Pokemon Stadium models and cannot -- they are that game's
-- data -- so the player supplies the cartridge. The original instruction for
-- that was "make a folder called baseroms next to the game and drop the file
-- in it", which is a fine sentence to write and a poor thing to ask. It needs
-- a folder the player has to create, in a place that is different on every
-- platform and is inside an unwritable archive on a packaged build, and it
-- fails SILENTLY: the two STADIUM rungs are simply not on the row, and
-- nothing on screen says why.
--
-- So this opens a file picker instead, from a row on the OPTIONS menu, and
-- the folder keeps working for anyone who prefers it (StadiumInstall).
--
-- ------- the picker is the host's, not LOVE's
--
-- LOVE 11.5 has no file dialog. love.window.showFileDialog arrived in 12 and
-- love.system.pickFile is a native bridge this project ships for mobile
-- rather than part of LOVE at all. What every desktop OS does have is a
-- dialog reachable from a shell, so that is what is used here -- osascript on
-- macOS, PowerShell's OpenFileDialog on Windows, zenity then kdialog on
-- Linux.
--
-- This is deliberately the SAME four commands the engine's own ROM importer
-- uses for the Game Boy cartridge (src/import/RomImporter.lua's chooseRom),
-- down to writing the Windows pick as UTF-8 -- the console's OEM codepage
-- mangles a non-ASCII path into something that crashes the next text draw.
-- Being a second copy of that is worth it: a mod cannot call into the
-- importer's private helpers, and the alternative is asking the engine to
-- grow a seam for one caller.
--
-- The dialog BLOCKS. io.popen waits for the player to choose, and the game is
-- frozen for as long as it is up. That is what the engine's importer does
-- too, it is what a modal dialog means, and the frame it freezes on is an
-- options menu.
--
-- ------- and the ROM is not kept
--
-- The picked file is read, built from, and forgotten -- nothing is copied
-- anywhere. A Stadium cartridge is 32 MB and the models built out of it are
-- 34, so keeping both would double the cost of a feature for a file that has
-- no further use: the packs are what the game reads afterwards, and the
-- marker records the ROM's md5 so a swapped cartridge is still noticed.
--
-- The one thing that costs is a format bump, which invalidates the packs and
-- leaves nothing to rebuild from. That is what the row still being there is
-- for -- it reads READY, and pressing it imports again.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumInstall = V.require("StadiumInstall")

local StadiumRomPick = {}

StadiumRomPick.LABEL = "STADIUM ROM"
StadiumRomPick.ID = "DRAMATIC_SHAPE:stadiumRom"

-- Names the REVISION, because that is the thing a player gets wrong: the
-- model offsets are keyed to US 1.0 and nothing else is going to work.
local PROMPT = "Choose your Pokemon Stadium (US) 1.0 ROM"

-- ------- the host, at arm's length
--
-- Everything below is read through pcall and a presence test. The mod loader
-- hands a mod the real `io` and `os` today, but a mod that TAKES that for
-- granted is one that stops loading the day a sandbox arrives -- and this is
-- a convenience on top of a folder scan that works without any of it.

local function haveShell()
  local ok, popen = pcall(function() return io and io.popen end)
  return (ok and popen) and true or false
end

local function haveFiles()
  local ok, open = pcall(function() return io and io.open end)
  return (ok and open) and true or false
end

-- Sandbox-safe diagnostic log (same fallbacks as StadiumInstall / ModLog).
local function dlog(fmt, ...)
  local msg
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, tostring(fmt), ...)
    msg = ok and formatted or tostring(fmt)
  else
    msg = tostring(fmt)
  end
  msg = "StadiumRomPick: " .. msg
  if V and V.log and V.log.warn then
    pcall(V.log.warn, V.log, "%s", msg)
  elseif V and V.dlog then
    pcall(V.dlog, msg)
  elseif V and V.mod and V.mod.log and V.mod.log.warn then
    pcall(V.mod.log.warn, V.mod.log, "%s", msg)
  else
    pcall(print, msg)
  end
end

-- Run a command and return its trimmed stdout, or nil for anything that did
-- not produce a line -- a cancelled dialog, a missing zenity, a shell that
-- is not there.
local function commandOutput(cmd)
  if not haveShell() then
    dlog("commandOutput: no shell (io.popen unavailable)")
    return nil
  end
  local ok, pipe = pcall(io.popen, cmd)
  if not (ok and pipe) then
    dlog("commandOutput: io.popen failed ok=%s err=%s", tostring(ok), tostring(pipe))
    return nil
  end
  local okRead, out = pcall(pipe.read, pipe, "*a")
  pcall(pipe.close, pipe)
  if not (okRead and type(out) == "string") then
    dlog("commandOutput: read failed ok=%s", tostring(okRead))
    return nil
  end
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  if out == "" then
    dlog("commandOutput: empty output (cancel or command failed)")
    return nil
  end
  return out
end

-- love.system is sandboxed away from mods on current gen1recomp builds, so
-- getOS() often returns nil. Fall back to package.config and uname so the
-- desktop dialog path still selects the right shell command.
local function osName()
  local ok, name = pcall(function() return love.system.getOS() end)
  if ok and type(name) == "string" and name ~= "" then return name end
  -- package / love.system may both be sandboxed away from mods.
  local okSep, sep = pcall(function()
    return package and package.config and package.config:sub(1, 1)
  end)
  if okSep and sep == "\\" then
    return "Windows"
  end
  local uname = commandOutput("uname -s 2>/dev/null")
  if uname then
    if uname:find("Darwin", 1, true) then return "OS X" end
    if uname:find("Linux", 1, true) then return "Linux" end
  end
  return nil
end

-- ------- can this machine open a DIALOG
--
-- Desktop only, and honestly so.
--
-- On ANDROID the picker is a native bridge (love.system.pickFile) whose
-- kind -> filename mapping is a fixed list of three in the engine's own C++,
-- and an unrecognised kind falls through to `picked_rom.gb`. That is not
-- merely the wrong name -- it is the file the engine's Game Boy importer is
-- watching, and reading that code settles it: the importer's size test only
-- SKIPS a 1 MB file it has already imported, so a 32 MB N64 ROM landing
-- there falls straight through to `love.filesystem.remove` and
-- `startData` -- deleted, and then reported to the player as a broken Game
-- Boy ROM. So the bridge is not called until it learns the kind, which is a
-- two-line change in System.cpp and an APK rebuild (see README).
--
-- Android is not stuck without it: conf.lua points the save directory at the
-- app's external-files folder, so `baseroms/` there is reachable over USB or
-- any file manager with no root and no permission prompt. What Android
-- lacked was being TOLD that -- the row vanished, and the folder's absolute
-- path was only ever written to a console no phone shows. That is what the
-- note below is for.
function StadiumRomPick.canDialog()
  -- Desktop shell dialog (osascript / PowerShell / zenity)
  if haveShell() and haveFiles() then
    local p = osName()
    if p == "Windows" or p == "OS X" or p == "Linux" then return true end
  end
  -- Mobile native bridge (love.system.pickFile) when present.
  -- Guarded: love.system is sandboxed away from mods on current gen1recomp.
  local ok, fn = pcall(function() return love.system and love.system.pickFile end)
  if ok and type(fn) == "function" then return true end
  return false
end

-- Kept as the old name for callers that only wanted "is there a dialog".
StadiumRomPick.available = StadiumRomPick.canDialog

-- Where a SAF pick would land if the native bridge grows a Stadium kind.
-- Watched unconditionally (see poll): on a build that never writes it this
-- costs one getInfo a frame, and on one that does the mod needs no further
-- change to use it.
StadiumRomPick.PICKED = "picked_stadium.z64"

-- Open the dialog. Returns the chosen absolute path, or nil when the player
-- cancelled or no dialog could be opened.
function StadiumRomPick.choose()
  local p = osName()
  if p == "OS X" then
    return commandOutput(
      ([[osascript -e 'POSIX path of (choose file with prompt "%s" of type ]]
       .. [[{"z64", "n64", "v64"})' 2>/dev/null]]):format(PROMPT))
  elseif p == "Windows" then
    -- Copy the pick to a plain-ASCII temp name and answer with that:
    -- the console's OEM codepage would mangle a non-ASCII path
    -- (Pokémon -> Pok\x82mon) and io.open on Windows needs ANSI bytes,
    -- so returning the original name both crashed the notice draw and
    -- could never have opened the file (same fix as engine #325/#665).
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='" .. PROMPT .. "';",
      "$d.Filter='Nintendo 64 ROM (*.z64;*.n64;*.v64)|*.z64;*.n64;*.v64"
      .. "|All files (*.*)|*.*';",
      "if($d.ShowDialog() -eq 'OK'){",
      "$t=Join-Path $env:TEMP 'ds_stadium_rom_pick.z64';",
      "Copy-Item -LiteralPath $d.FileName -Destination $t -Force;",
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
      "[Console]::Write($t)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif p == "Linux" then
    local path = commandOutput(
      ([[zenity --file-selection --title="%s" ]]
       .. [[--file-filter="Nintendo 64 ROM | *.z64 *.n64 *.v64" 2>/dev/null]])
        :format(PROMPT))
    if path then return path end
    -- zenity is absent on plenty of installs (and on most handheld Linux
    -- distributions); KDE's own dialog is the usual second answer
    return commandOutput(
      [[kdialog --getopenfilename "$HOME" "*.z64 *.n64 *.v64|]]
      .. [[Nintendo 64 ROM" 2>/dev/null]])
  end
  dlog("choose: no dialog command for platform=%s", tostring(p))
  return nil
end

-- Read an ABSOLUTE path, which love.filesystem cannot: it only sees inside
-- the physfs mount, and a picked file is anywhere on the disk. Returns the
-- bytes, or nil plus a reason short enough to fit the loading screen.
function StadiumRomPick.read(path)
  if not haveFiles() then return nil, "no file access" end
  local ok, fp = pcall(io.open, path, "rb")
  if not (ok and fp) then return nil, "could not open that file" end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 0) then
    return nil, "could not read that file"
  end
  return bytes
end

-- ------- the whole flow, from one keypress
--
-- Pick, read, start the build, and put the loading screen up over whatever
-- asked -- which is the OPTIONS menu, so the row is there again underneath
-- when the build finishes and now reads READY.
--
-- A CANCELLED dialog is not a failure and says nothing: the player opened a
-- file browser and changed their mind, and a mod that made an announcement
-- about that would be the second most annoying thing on the menu.
--
-- Everything else lands on the loading screen's own failure state, because it
-- is the one surface in this mode with room for a sentence -- and because a
-- player who has just chosen the wrong file is owed a reason and not a row
-- that quietly goes on saying IMPORT.
-- Paths checked (in order) when the player presses STADIUM ROM.
-- Relative paths under the mod are read via mod:read.
-- Only this mod's baseroms/ at the package root (launcher + drop-in).
local CANDIDATE_MOD_ROMS = {
  "baseroms/baserom.z64",
  "baseroms/baserom.n64",
  "baseroms/baserom.v64",
}

-- Also try these on the engine save/source FS (mods/<id>/...).
local function candidateFsRoms(modId)
  local id = modId or "DRAMATIC_SHAPE"
  local out = {}
  for _, rel in ipairs(CANDIDATE_MOD_ROMS) do
    out[#out + 1] = "mods/" .. id .. "/" .. rel
  end
  return out
end

local function startFromBytes(game, bytes, label)
  local StadiumScreen = V.require("StadiumScreen")
  dlog("directory rom start label=%s size=%d", tostring(label), #bytes)
  local started, err = StadiumInstall.beginFrom(bytes, label)
  if not started then
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = tostring(err)
    dlog("directory rom beginFrom failed: %s", tostring(err))
  end
  if game and game.stack then
    game.stack:push(StadiumScreen.new(game, true))
  end
  return true
end

local function persistentFs()
  local okSD, SaveData = pcall(require, "src.core.SaveData")
  if okSD and SaveData and type(SaveData.persistenceFs) == "function" then
    local okF, f = pcall(function() return SaveData.persistenceFs() end)
    if okF and type(f) == "table" and type(f.read) == "function" then return f end
  end
  return nil
end

-- Try to load a Stadium ROM that is already on disk (mod folder or save-dir
-- baseroms/). Returns true if a build was started.
local function tryDirectoryRom(game)
  local mod = V.mod
  local modId = (mod and mod.id) or (mod and mod.manifest and mod.manifest.id) or "DRAMATIC_SHAPE"
  dlog("tryDirectoryRom mod.id=%s hasRead=%s hasList=%s hasInfo=%s",
    tostring(modId), tostring(mod and mod.read ~= nil),
    tostring(mod and mod.list ~= nil), tostring(mod and mod.info ~= nil))

  -- Probe directory listing so logs show whether the folder is visible.
  if mod and mod.list then
    for _, dir in ipairs({ "baseroms" }) do
      local okL, items = pcall(mod.list, mod, dir)
      if okL and type(items) == "table" then
        dlog("mod:list %s -> %d entries: %s", dir, #items, table.concat(items, ", "):sub(1, 120))
      else
        dlog("mod:list %s failed: %s", dir, tostring(items))
      end
    end
  end

  -- 1) Mod-local paths via mod:read (fixed names + any .z64/.n64/.v64 in the
  --    baseroms folders). The folder often only has README until the player
  --    drops a ROM in; when they do, any name is accepted.
  local function tryModRead(rel)
    if not (mod and mod.read) then return false end
    local ok, bytes, err = pcall(function() return mod:read(rel) end)
    if ok and type(bytes) == "string" and #bytes > 0 then
      return startFromBytes(game, bytes, rel)
    end
    dlog("mod:read %s -> ok=%s type=%s err=%s",
      rel, tostring(ok), type(bytes), tostring(err or bytes))
    return false
  end

  if mod and mod.read then
    for _, rel in ipairs(CANDIDATE_MOD_ROMS) do
      if tryModRead(rel) then return true end
    end
    -- Scan directories for any stadium-sized ROM the player dropped in.
    if mod.list then
      for _, dir in ipairs({ "baseroms" }) do
        local okL, items = pcall(mod.list, mod, dir)
        if okL and type(items) == "table" then
          for _, name in ipairs(items) do
            local lower = name:lower()
            if lower:match("%.z64$") or lower:match("%.n64$") or lower:match("%.v64$") then
              local rel = dir .. "/" .. name
              dlog("tryDirectoryRom: found candidate %s", rel)
              if tryModRead(rel) then return true end
            end
          end
        end
      end
    end
  else
    dlog("tryDirectoryRom: V.mod.read unavailable")
  end

  -- 2) Engine FS paths (mods/DRAMATIC_SHAPE/... and save-dir baseroms/).
  local f = persistentFs()
  if f then
    for _, path in ipairs(candidateFsRoms(modId)) do
      local okInfo, info = pcall(function()
        return f.getInfo and f.getInfo(path, "file")
      end)
      if okInfo and info then
        local okR, data = pcall(function() return f.read(path) end)
        if okR and type(data) == "string" and #data > 0 then
          return startFromBytes(game, data, path)
        end
        dlog("fs.read %s failed: %s", path, tostring(data))
      else
        dlog("fs.getInfo %s -> nil", path)
      end
    end
  else
    dlog("tryDirectoryRom: persistentFs unavailable")
  end

  -- 3) StadiumInstall.romPath() (baseroms/ on PhysFS search path).
  if StadiumInstall.romPresent and StadiumInstall.romPresent() then
    dlog("directory rom via StadiumInstall.romPath")
    local StadiumScreen = V.require("StadiumScreen")
    local started, err = StadiumInstall.begin()
    if not started then
      StadiumInstall.status.state = "failed"
      StadiumInstall.status.error = tostring(err)
    end
    if game and game.stack then
      game.stack:push(StadiumScreen.new(game, true))
    end
    return true
  end

  dlog("tryDirectoryRom: no ROM found in any candidate path")
  return false
end

function StadiumRomPick.import(game)
  if StadiumInstall.status.state == "building" then
    dlog("import ignored: already building")
    return false
  end
  local StadiumScreen = V.require("StadiumScreen")

  local function fail(why)
    dlog("import failed: %s", tostring(why))
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = why
    if game and game.stack then
      game.stack:push(StadiumScreen.new(game, true))
    end
    return false
  end

  local function pushNote(title, lead, body)
    if not (game and game.stack) then
      dlog("pushNote: no game.stack (game=%s)", tostring(game ~= nil))
      return false
    end
    local ok, err = pcall(function()
      game.stack:push(StadiumScreen.newNote(game, title, lead, body))
    end)
    if not ok then
      dlog("pushNote failed: %s", tostring(err))
      return false
    end
    return true
  end

  local platform = osName()
  dlog("import start platform=%s shell=%s files=%s game=%s stack=%s",
    tostring(platform), tostring(haveShell()), tostring(haveFiles()),
    tostring(game ~= nil), tostring(game and game.stack ~= nil))

  -- Prefer an on-disk ROM in this mod's baseroms/
  -- so a single click imports without needing drag-and-drop.
  if tryDirectoryRom(game) then
    dlog("import: started from directory ROM")
    return true
  end
  dlog("import: no directory ROM found; falling back to drop / picker")

  -- Mobile / iOS: native pickFile when present.
  if platform == "Android" or platform == "iOS" then
    local okPick, pickFn = pcall(function() return love.system and love.system.pickFile end)
    if okPick and type(pickFn) == "function" then
      dlog("using love.system.pickFile")
      pcall(pickFn, "stadium")
      pushNote("STADIUM ROM", "PICK ROM", "Use the system file picker")
      return true
    end
    dlog("mobile path: no pickFile, using folder hint")
    pushNote("STADIUM ROM", "PUT ROM HERE",
      "baseroms/baserom.z64")
    return false
  end

  -- Desktop: prompt to drop the file (hooks from install()). Also mention
  -- the default mod-folder path so the player can place the ROM there and
  -- press STADIUM ROM again to auto-load it.
  dlog("desktop/unknown: prompting for file drop / directory")
  pushNote("STADIUM ROM", "DROP ROM ON WINDOW",
    "or: baseroms/baserom.z64")
  return true
end

-- ------- the row
--
-- An ACTION rather than a value, which is why it is not a ModSetting: there
-- is no rung to store, nothing for the mod manager's page to persist, and
-- nothing to restore on the next boot. What it shows is a STATE -- the models
-- are there or they are not -- and what it does is the only thing it can do.
--
-- Still offered once they ARE there, reading READY. Pressing it imports
-- again, which is how a player swaps to a different revision, and how they
-- rebuild after a format bump has invalidated the packs and left nothing on
-- disk to rebuild from (see the header: the ROM is not kept).
--
-- nil where no dialog can be opened, which takes the row off the menu
-- entirely rather than offering a button that cannot do anything.
function StadiumRomPick.row()
  return {
    id = StadiumRomPick.ID,
    label = StadiumRomPick.LABEL,
    value = function()
      if StadiumInstall.status.state == "building" then return "BUILDING" end
      if StadiumInstall.available() then return "READY" end
      -- WHERE, not IMPORT, where pressing it can only tell you the folder:
      -- a row that says IMPORT and then does not import is a worse row than
      -- one that says what it actually does
      return StadiumRomPick.canDialog() and "IMPORT" or "WHERE?"
    end,
    step = function(game)
      local ok, err = pcall(StadiumRomPick.import, game)
      if not ok then
        dlog("row step error: %s", tostring(err))
        pcall(function()
          local StadiumScreen = V.require("StadiumScreen")
          if game and game.stack and StadiumScreen and StadiumScreen.newNote then
            game.stack:push(StadiumScreen.newNote(game, "STADIUM ROM",
              "IMPORT ERROR",
              tostring(err):sub(1, 80)))
          end
        end)
      end
      return true
    end,
  }
end

-- ------- a pick that landed while we were not looking
--
-- The desktop dialog BLOCKS, so `import` above can read the answer on the
-- next line. A SAF pick cannot work that way: it is a separate activity,
-- Android is free to destroy the game while it is up, and the file appears
-- some frames later -- so the only way to notice one is to look for it.
--
-- Nothing writes this filename today (see canDialog). It is watched anyway so
-- that teaching the native bridge one more kind is the whole of the Android
-- picker work, with no second change needed here.
--
-- Consumed and DELETED either way: a 32 MB file left in the save directory
-- would be imported again on the next boot, and kept forever if the import
-- failed.
function StadiumRomPick.poll(game)
  -- love.filesystem is sandboxed away from mods; pcall so a blocked access
  -- is treated as "no native pick pending" rather than raising.
  local okFs, f = pcall(function() return love.filesystem end)
  if not (okFs and f and f.getInfo) then return false end
  if StadiumInstall.status.state == "building" then return false end
  local ok, info = pcall(f.getInfo, StadiumRomPick.PICKED, "file")
  if not (ok and info) then return false end

  local okRead, bytes = pcall(f.read, StadiumRomPick.PICKED)
  pcall(f.remove, StadiumRomPick.PICKED)
  if not (okRead and type(bytes) == "string") then return false end

  local StadiumScreen = V.require("StadiumScreen")
  local started, err = StadiumInstall.beginFrom(bytes, StadiumRomPick.PICKED)
  if not started then
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = tostring(err)
  end
  if game and game.stack then
    game.stack:push(StadiumScreen.new(game, true))
  end
  return true
end

-- ------- drag-and-drop for desktops
--
-- The mod sandbox blocks assignment to love.* callbacks and strips io /
-- package. love.filedropped is still *invoked* by the engine, but it is
-- routed to RomImporter:filedropped -- so we wrap THAT instead of love.*.
-- DroppedFile:read does not need io; it is a native path handle from LÖVE.

local function readDropped(file)
  if not file then return nil, "no file" end
  local name = ""
  pcall(function()
    if file.getFilename then name = file:getFilename() or "" end
  end)
  local okOpen, openErr = pcall(function()
    if file.open then
      local ok, err = file:open("r")
      if ok == false then error(err or "open failed") end
    end
  end)
  if not okOpen then return nil, "open failed: " .. tostring(openErr) end
  local okRead, data = pcall(function()
    if file.read then return file:read() end
    return nil
  end)
  pcall(function() if file.close then file:close() end end)
  if not okRead then return nil, "read failed: " .. tostring(data) end
  if type(data) ~= "string" or #data == 0 then return nil, "empty read" end
  return data, name
end

local function isStadiumName(name)
  local lower = (type(name) == "string" and name:lower()) or ""
  return lower:match("%.z64$") or lower:match("%.n64$") or lower:match("%.v64$")
end

local function handleStadiumDrop(file)
  if StadiumInstall.status.state == "building" then
    dlog("drop ignored: already building")
    return true
  end
  local name = ""
  pcall(function()
    if file and file.getFilename then name = file:getFilename() or "" end
  end)
  if not isStadiumName(name) then return false end

  dlog("stadium drop received name=%s", tostring(name))
  local bytes, errOrName = readDropped(file)
  if not bytes then
    dlog("stadium drop read failed: %s", tostring(errOrName))
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = "could not read dropped file: " .. tostring(errOrName)
    return true
  end
  -- readDropped returns (bytes, name) on success
  if type(errOrName) == "string" and errOrName ~= "" then name = errOrName end
  dlog("stadium drop read ok size=%d", #bytes)

  local started, err = StadiumInstall.beginFrom(bytes, name)
  if not started then
    dlog("stadium drop beginFrom failed: %s", tostring(err))
    StadiumInstall.status.state = "failed"
    StadiumInstall.status.error = tostring(err)
  else
    dlog("stadium drop beginFrom started")
  end

  -- Push the loading / result screen if we can reach a stack.
  local StadiumScreen = V.require("StadiumScreen")
  local pushed = false
  pcall(function()
    local okG, Game = pcall(require, "src.core.Game")
    if okG and Game and Game.stack then
      Game.stack:push(StadiumScreen.new(Game, true))
      pushed = true
    end
  end)
  if not pushed then
    pcall(function()
      local Storage = V.require("ModStorage")
      local g = Storage and Storage.game and Storage.game()
      if g and g.stack then
        g.stack:push(StadiumScreen.new(g, true))
        pushed = true
      end
    end)
  end
  if not pushed then
    pcall(function() V.require("StadiumScreen").maybePush() end)
  end
  dlog("stadium drop UI pushed=%s", tostring(pushed))
  return true
end

local filedropInstalled = false
function StadiumRomPick.install()
  if filedropInstalled then return end
  filedropInstalled = true
  dlog("install: wiring stadium drop handlers")

  local function loveHandler(file)
    local ok, handled = pcall(handleStadiumDrop, file)
    if not ok then
      dlog("drop handler error: %s", tostring(handled))
      return
    end
    if handled then return end
    -- forward non-stadium drops to whatever the engine had
    if StadiumRomPick._prevFiledropped then
      return StadiumRomPick._prevFiledropped(file)
    end
  end

  -- 1) Wrap RomImporter.filedropped (works while launcher Importer is alive)
  local wrappedImporter = false
  local okRI, RomImporter = pcall(require, "src.import.RomImporter")
  if okRI and type(RomImporter) == "table" and type(RomImporter.filedropped) == "function" then
    if not RomImporter._dsStadiumDropWrapped then
      local inner = RomImporter.filedropped
      StadiumRomPick._prevFiledropped = function(file)
        -- no instance; best-effort no-op for non-stadium when only love path hits this
      end
      function RomImporter.filedropped(self, file)
        local ok, handled = pcall(handleStadiumDrop, file)
        if not ok then
          dlog("handleStadiumDrop error: %s", tostring(handled))
        elseif handled then
          return
        end
        if inner then return inner(self, file) end
      end
      RomImporter._dsStadiumDropWrapped = true
      wrappedImporter = true
      dlog("install: wrapped RomImporter.filedropped")
    else
      wrappedImporter = true
    end
  else
    dlog("install: RomImporter unavailable ok=%s", tostring(okRI))
  end

  -- 2) Capture previous love.filedropped for forwarding
  local okOld, old = pcall(function() return love.filedropped end)
  if okOld and type(old) == "function" then
    StadiumRomPick._prevFiledropped = old
  end

  -- 3) Try several ways to attach; sandbox may block some/all.
  local attached = {}

  local ok1, err1 = pcall(function() love.filedropped = loveHandler end)
  local ok1b, cur1 = pcall(function() return love.filedropped end)
  if ok1 and ok1b and cur1 == loveHandler then attached[#attached + 1] = "love.filedropped" end

  local ok2, err2 = pcall(function()
    if rawset then rawset(love, "filedropped", loveHandler) end
  end)
  local ok2b, cur2 = pcall(function() return love.filedropped end)
  if ok2 and ok2b and cur2 == loveHandler then
    if attached[#attached] ~= "love.filedropped" then attached[#attached + 1] = "rawset love.filedropped" end
  end

  local ok3, err3 = pcall(function()
    if love.handlers then love.handlers.filedropped = loveHandler end
  end)
  local ok3b, cur3 = pcall(function()
    return love.handlers and love.handlers.filedropped
  end)
  if ok3 and ok3b and cur3 == loveHandler then attached[#attached + 1] = "love.handlers.filedropped" end

  dlog("install: drop attach=[%s] importer=%s loveSet=%s rawset=%s handlers=%s",
    table.concat(attached, ","),
    tostring(wrappedImporter),
    tostring(ok1), tostring(ok2), tostring(ok3))

  if #attached == 0 and not wrappedImporter then
    dlog("install: WARNING no drop hook attached; use baseroms/ folder")
  end
end


return StadiumRomPick
