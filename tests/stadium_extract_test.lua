-- The Lua ROM extractor, against the Python packer that is its oracle.
--
--   luajit mods/DramaticShapeVoxelMod/tests/stadium_extract_test.lua \
--          [--rom=PATH] [--oracle=DIR] [--only=25,6] [--out=DIR] [--mod=DIR]
--
-- Run from the PROJECT ROOT. Defaults: the ROM under
-- model_extract/baseroms/, the oracle in assets/stadium (whatever
-- tools/stadium_pack.py last wrote there).
--
-- --mod points at the mod directory whose lib/ is under test. It exists for
-- worktrees: the ROM and the packs are both gitignored, so a worktree has
-- neither, and without this the test would load the SHARED checkout's
-- modules while claiming to test the branch's.
--
-- ------- what this is for
--
-- lib/StadiumRom, StadiumFragment, StadiumFx and StadiumBuild are a port of
-- roughly fifteen hundred lines of dense numeric Python -- an F3DEX2
-- interpreter, six texture codecs, a bit-packed animation sampler, a noise
-- generator and a binary writer. Reading a port of that twice does not
-- establish that it is right. Producing the same thirty-four megabytes,
-- byte for byte, does.
--
-- It is also the guard on the two of them DRIFTING. The packer and the
-- extractor have to keep agreeing about the format forever, and a change to
-- one that is not made to the other shows up here as a differing offset
-- rather than as a Pokemon that renders as noise three months later.
--
-- Headless: no LOVE, no graphics. Everything these four modules do is
-- arithmetic on strings.

local args = {}
for _, a in ipairs({ ... }) do
  local k, v = a:match("^%-%-([%w_]+)=(.*)$")
  if k then args[k] = v else args[a:gsub("^%-%-", "")] = true end
end

local MOD = args.mod or "mods/DramaticShapeVoxelMod"
local ROM = args.rom or (MOD .. "/baseroms/baserom.z64")
local ORACLE = args.oracle or (MOD .. "/assets/stadium")

-- ------- the mod namespace, enough of it to load four modules

local loaded = {}
local V = {}
function V.require(name)
  if loaded[name] == nil then
    local chunk = assert(loadfile(MOD .. "/lib/" .. name .. ".lua"))
    loaded[name] = chunk(V)
  end
  return loaded[name]
end
V.mod = { log = { warn = function() end, info = function() end } }
-- the mod's own directory, so a module that loads a data file finds it
-- relative to the MOD rather than to wherever this was run from
V.path = MOD

local StadiumRom = V.require("StadiumRom")
local StadiumBuild = V.require("StadiumBuild")

-- ------- run

local function readFile(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local data = fp:read("*a")
  fp:close()
  return data
end

local romBytes = readFile(ROM)
if not romBytes then
  io.stderr:write("no ROM at " .. ROM .. "\n")
  os.exit(2)
end

local rom, err = StadiumRom.open(romBytes)
if not rom then
  io.stderr:write("could not open ROM: " .. tostring(err) .. "\n")
  os.exit(2)
end

local only = nil
if args.only then
  only = {}
  for n in args.only:gmatch("%d+") do only[tonumber(n)] = true end
end

local checked, matched, missing, failed = 0, 0, 0, 0
local shinyOk, shinyMissing, shinyBad = 0, 0, 0
local firstBad = nil
local t0 = os.clock()

for fileno = 0, StadiumRom.N_POKEMON - 1 do
  local ok, res = pcall(StadiumBuild.species, rom, fileno)
  if not ok or not res then
    -- res carries the message on the error path
    io.write(("file %d: EXTRACT FAILED: %s\n"):format(fileno, tostring(res)))
    failed = failed + 1
  elseif not only or only[res.species] then
    checked = checked + 1
    if args.out then
      local fp = io.open(("%s/%03d.dsm"):format(args.out, res.species), "wb")
      if fp then fp:write(res.bytes) fp:close() end
      -- the shiny variant too, so the pair can be diffed out of process
      if res.shinyBytes then
        local sp = io.open(("%s/%03ds.dsm"):format(args.out, res.species), "wb")
        if sp then sp:write(res.shinyBytes) sp:close() end
      end
    end
    -- The shiny pack is the same DSM3 with recoloured texels, so it must be
    -- exactly as long and must actually differ. A species that produced none
    -- is counted rather than failed: it ships without a recolour and the
    -- runtime falls back to its normal model.
    if not res.shinyBytes then
      shinyMissing = shinyMissing + 1
    elseif #res.shinyBytes ~= #res.bytes then
      shinyBad = shinyBad + 1
      io.write(("species %d: shiny pack is %d bytes, normal is %d\n")
               :format(res.species, #res.shinyBytes, #res.bytes))
    elseif res.shinyBytes == res.bytes then
      shinyBad = shinyBad + 1
      io.write(("species %d: shiny pack is identical to normal\n")
               :format(res.species))
    else
      shinyOk = shinyOk + 1
    end
    local want = readFile(("%s/%03d.dsm"):format(ORACLE, res.species))
    if not want then
      missing = missing + 1
    elseif want == res.bytes then
      matched = matched + 1
    else
      -- where, exactly: the first differing byte localises a format mistake
      -- far faster than "the file is wrong" does
      local at = nil
      local n = math.min(#want, #res.bytes)
      for i = 1, n do
        if want:sub(i, i) ~= res.bytes:sub(i, i) then at = i break end
      end
      io.write(("%03d.dsm DIFFERS: %d bytes vs %d, first at %s\n")
               :format(res.species, #res.bytes, #want,
                       at and ("offset " .. at) or "(one is a prefix)"))
      if not firstBad then firstBad = res.species end
    end
  end
end

io.write(("\n%d checked, %d identical, %d differ, %d oracle files missing, "
          .. "%d extractions failed  (%.1fs)\n")
         :format(checked, matched, checked - matched - missing, missing,
                 failed, os.clock() - t0))
io.write(("shiny: %d recoloured, %d without a variant, %d malformed\n")
         :format(shinyOk, shinyMissing, shinyBad))

-- NONE recoloured is a failure, not a quiet zero. It is what a missing or
-- unfindable data/shiny_colors.lua looks like, and the first version of this
-- test reported PASS through exactly that: 151 species built, every one of
-- them without a shiny variant, and nothing in the output that read as
-- wrong. A count of zero is now as loud as a malformed pack.
if checked > 0 and shinyOk == 0 then
  io.write("NO SPECIES RECOLOURED -- data/shiny_colors.lua was not found\n")
  shinyBad = shinyBad + 1
end

-- The oracle diff is the load-bearing assertion and is unchanged: the shiny
-- pass must not have moved a single byte of the normal packs. The shiny
-- counters are additional, and a malformed variant fails the run -- a pack
-- of the wrong length would be read as a corrupt model at runtime.
if matched == checked and failed == 0 and missing == 0 and shinyBad == 0 then
  io.write("PASS -- the Lua extractor reproduces the packer exactly\n")
  os.exit(0)
end
io.write("FAIL\n")
os.exit(1)
