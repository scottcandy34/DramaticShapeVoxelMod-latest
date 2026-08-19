-- Voxel world mode: turn a map's tile layer into one static 3D mesh.
--
-- The scene description comes from Structures.lua, which -- 3dSen-style --
-- detects each connected drawn thing on the map and picks its model:
--
--   flat      ground / water / void: a single quad.
--   top art   ledges, roofs (profile-authored): a box with the art on its
--             TOP face; partial side bands crop the art (a 6px ledge face
--             is the bottom of the lip drawing).
--   volume    walls, buildings, tree lines: each column rises to the
--             structure's REAL drawn height (Structures measures it,
--             repeat-aware and region-consistent -- a 6-row house is 48px,
--             a 40-row border forest is rows of 16px trees). The south
--             face folds the full artwork upright, 8px band by band, band
--             k sampling the map row k tiles north; the top wears the
--             structure's top rows.
--   object    small props with a silhouette (plants, signs, lone trees):
--             per-pixel voxel prisms prebuilt by Structures, standing on
--             synthesized ground -- this mesher just emits their quads.
--             Round trees arrive as STAMPS (a shared hull template plus a
--             cell offset) and expand here, straight into the vertex
--             stream, so no map retains per-cell copies of its forests.
--
-- Side faces are never stretched: all sides are 8px bands with the art
-- tiled per band and cropped at partial bands.
--
-- Texturing samples the TILESET ATLAS, not a rendered copy of the map. The
-- atlas is 128x48; a map-space canvas covering the biggest routes would be
-- ~5 MB each with up to five live at once (connected maps), which is real
-- memory on the mobile targets. Sampling the atlas costs 24 KB, and costs
-- nothing in fidelity because TerrainAtlas hands back the same atlas
-- TileRenderer draws with -- including the fully recolored one RED++
-- bakes -- so terrain color comes through untouched.
--
-- BUILDS ARE ASYNCHRONOUS. A frame never blocks on meshing: VoxelScene
-- requests what it wants to draw, request() queues a build job, and
-- pump() -- called once a frame from the pipeline's update -- advances
-- the queue inside a few-millisecond budget (BuildBudget suspends the
-- job's coroutine mid-loop when the slice is spent). Until a mesh lands
-- the scene simply draws without it: the engine's flat path while the
-- current map has nothing, the body-only variant while the full one (the
-- border ring) is still cooking, neighbours popping in as they finish.
-- The synchronous get() remains for probes and tests.
--
-- Meshes are cached per map id and EVICTED down to the live set (current
-- map + connected neighbours) whenever that set changes -- setLive()
-- releases far maps' GPU meshes and their Structures analysis, which is
-- what used to grow the heap by gigabytes over a cross-region trek.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Structures = V.require("voxel/Structures")
local Budget = V.require("util/BuildBudget")
local MeshCache = V.require("voxel/VoxelMeshCache")

-- love.system itself is sandboxed; current Gen1Recomp's compatibility facade
-- answers getOS while older sandboxes raise. Fail closed on those older builds
-- rather than changing desktop scheduling.
local IS_ANDROID = false
do
  local ok, osName = pcall(function() return love.system.getOS() end)
  IS_ANDROID = ok and osName == "Android"
end

local ChunkMesher = {}

local cache = {}     -- map id -> { full = mesh|false, body = ..., grass = ... }
local gen = {}       -- map id -> generation, bumped by invalidate/evict

local MeshSinks = V.require("Voxel/MeshSinks")
local ChunkGeometry = V.require("Voxel/ChunkGeometry")
ChunkMesher.flatTopRow = ChunkGeometry.flatTopRow
ChunkMesher.geometry = ChunkGeometry.of
ChunkMesher.build = ChunkGeometry.build
local AuxMeshes = V.require("Voxel/AuxMeshes")

-- -------------------------------------------------------------- geometry

function ChunkMesher.persistentCacheAvailable()
  return MeshSinks.persistentCapable() and true or false
end

function ChunkMesher.bodyCachedOnDisk(map)
  if not MeshSinks.persistentCapable() then return false end
  local hit = MeshCache.status(map)
  return hit and true or false
end

-- Generate BODY directly into bounded persistent chunks. Unlike V19's raw
-- sink, this does not retain the whole map in an FFI buffer: each terrain or
-- water chunk is packed, optionally LZ4-compressed and committed independently.
function ChunkMesher.precompileBody(map)
  if not (MeshSinks.persistentCapable() and map) then return false, "unsupported" end
  if ChunkMesher.bodyCachedOnDisk(map) then return true, "cached" end
  local store, reason = MeshCache.beginStore(map)
  if not store then return false, reason end
  local ok, err = pcall(ChunkGeometry.run, map, true, nil,
                        store:sink("body"), store:sink("water"))
  if not ok then
    store:abort()
    return false, tostring(err)
  end
  local stored, storeReason = store:commit()
  return stored, stored and "built" or storeReason
end

function ChunkMesher.persistentCacheVersion()
  return MeshCache.SCHEMA_VERSION, MeshCache.GEOMETRY_VERSION
end

function ChunkMesher.persistentCacheDirectory()
  return MeshCache.DIRECTORY
end

-- Replace a cached slot, releasing whatever mesh it held.
local function swapSlot(c, slot, mesh)
  local old = c[slot]
  if old and old ~= mesh and old.release then pcall(old.release, old) end
  c[slot] = mesh
end

-- ------------------------------------------------------------- the cache

local function entry(id)
  local c = cache[id]
  if not c then
    c = {}
    cache[id] = c
  end
  return c
end

-- The water surface that came out of a terrain slot's own build. Kept
-- beside it rather than in a slot of its own because the two are ONE
-- answer: a full mesh drawn beside a body build's water would draw the
-- ring's ponds twice and miss the body's own.
local function waterSlot(slot)
  return slot .. "Water"
end

local function releaseEntry(c)
  for _, slot in ipairs({ "full", "body", "fullWater", "bodyWater",
                          "grass", "flowers" }) do
    local mesh = c[slot]
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    c[slot] = nil
  end
  AuxMeshes.releaseFigures(c.figures)
  c.figures = nil
  c.stale = nil
end

-- ---------------------------------------------------------- async builds

local jobs = {}       -- FIFO of pending jobs
local jobIndex = {}   -- "id:slot" -> job

local clock = (love and love.timer and love.timer.getTime) or os.clock

local function jobKey(id, slot)
  return id .. ":" .. slot
end

local function finishJob(job, ok, err)
  jobIndex[jobKey(job.id, job.slot)] = nil
  for i, j in ipairs(jobs) do
    if j == job then
      table.remove(jobs, i)
      break
    end
  end
  if not ok then
    -- name the reason: in a real session a lost build is a black map
    local msg = "[warn] voxel mesh build failed for " .. tostring(job.id)
                .. ": " .. tostring(err)
    print(msg)
    if V and V.dlog then V.dlog(msg) end
    if V and V.log then
      V.log:error("async mesh build failed map=%s: %s",
        tostring(job.id), tostring(err))
    end
    if (gen[job.id] or 0) == job.gen then
      entry(job.id)[job.slot] = false
    end
  end
end

-- A build only lands if the map's generation still matches the one the
-- job was queued under -- invalidate/evict bump it to cancel in-flight
-- work whose inputs went stale.
local function runJob(job)
  local map = job.map
  local c = entry(job.id)

  -- BODY jobs prefer the persistent stream. A corrupt/truncated entry is
  -- rejected by MeshCache, its ready marker is removed, and this job becomes
  -- ordinary cold work before it can continue.
  local mesh, water = nil, nil
  local loaded = false
  local attemptedPersistent = job.slot == "body"
      and job.allowPersistent ~= false and job.persistent
  if attemptedPersistent then
    loaded, mesh, water = MeshCache.load(map, MeshSinks.cachedMeshReceiver)
    if not loaded then job.persistent = false end
  end
  -- Do not turn a cached-neighbour upload that proved corrupt into a large
  -- live generation in the same walking frame.
  if not loaded and attemptedPersistent and job.moving and not job.urgent then
    coroutine.yield("cache-miss")
  end

  -- A cache miss on Android also generates through the bounded persistent
  -- sinks. This replaces V19's FFI staging buffer (FFI is no longer exposed
  -- to content mods): geometry is written in 4K-vertex chunks, then streamed
  -- into the GPU by the same checked load path. Stale runtime edits never take
  -- this route, because persisting a Cut/door state globally would be wrong.
  if not loaded and job.slot == "body" and job.allowPersistent ~= false
     and MeshSinks.persistentCapable() then
    local stored = ChunkMesher.precompileBody(map)
    if stored then
      loaded, mesh, water = MeshCache.load(map, MeshSinks.cachedMeshReceiver)
    end
  end

  if not loaded then
    local sink, waterSink = MeshSinks.newSink(), MeshSinks.newSink()
    ChunkGeometry.run(map, job.slot == "body", job.masks, sink, waterSink)
    mesh, water = sink.finish(), waterSink.finish()
  end

  if (gen[job.id] or 0) ~= job.gen then
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    if water and water.release then pcall(water.release, water) end
    return
  end
  swapSlot(c, job.slot, mesh or false)
  swapSlot(c, waterSlot(job.slot), water or false)
  if c.stale then c.stale[job.slot] = nil end

  -- Terrain becomes drawable before optional grass/flower/figure work. Keep
  -- the existing v1.8.4 auxiliary behavior, but resume it only in idle or
  -- covered time so a cheap persistent BODY cannot drag a Structures build
  -- into the same walking frame.
  if not job.covered then
    job.terrainReady = true
    job.urgent = false
    job.warm = 0
    coroutine.yield("terrain-ready")
  end

  if c.grass == nil or c.flowers == nil or c.figures == nil
     or (c.stale and c.stale.aux) then
    local okG, grass = pcall(AuxMeshes.buildGrassMesh, map)
    local okF, flowers = pcall(AuxMeshes.buildFlowerMesh, map)
    local okX, figures = pcall(AuxMeshes.buildFigureMeshes, map)
    if (gen[job.id] or 0) ~= job.gen then
      if okG and grass and grass.release then pcall(grass.release, grass) end
      if okF and flowers and flowers.release then
        pcall(flowers.release, flowers)
      end
      if okX then AuxMeshes.releaseFigures(figures) end
      return
    end
    swapSlot(c, "grass", (okG and grass) or false)
    swapSlot(c, "flowers", (okF and flowers) or false)
    AuxMeshes.releaseFigures(c.figures)
    c.figures = (okX and figures) or false
    if c.stale then c.stale.aux = nil end
  end
  if c.stale and not (c.stale.full or c.stale.body or c.stale.aux) then
    c.stale = nil
  end
end

-- Queue a build unless the slot is already cached or queued. Returns the
-- cached mesh when there is one (false-cached misses return nil).
-- `urgent` marks the current map's meshes: pump() gives those a bigger
-- slice and runs them before neighbour jobs. A slot refresh() marked
-- stale queues its rebuild AND keeps handing back the old mesh, so a
-- one-block edit never drops the scene to the flat 2D path while the
-- replacement cooks.
function ChunkMesher.request(map, bodyOnly, masks, urgent, warm)
  local slot = bodyOnly and "body" or "full"
  local c = cache[map.id]
  local stale = c and c.stale and (c.stale[slot] or c.stale.aux)
  if c and c[slot] ~= nil and not stale then return c[slot] or nil end

  local persistent = bodyOnly and not stale and ChunkMesher.bodyCachedOnDisk(map)
                     or false
  local key = jobKey(map.id, slot)
  local job = jobIndex[key]
  if not job then
    job = { id = map.id, map = map, slot = slot, masks = masks,
            urgent = urgent or false, warm = warm or 0,
            persistent = persistent,
            allowPersistent = bodyOnly and not stale,
            gen = gen[map.id] or 0 }
    jobIndex[key] = job
    jobs[#jobs + 1] = job
  else
    job.persistent = persistent
    if stale then job.allowPersistent = false end
    -- Priorities are live: turning away from a connection or making BODY
    -- drawable must demote an already queued job.
    if urgent ~= nil then job.urgent = urgent and true or false end
    if warm ~= nil then job.warm = warm or 0 end
  end
  return (c and c[slot]) or nil
end

function ChunkMesher.pending()
  return #jobs
end

function ChunkMesher.failed(map, bodyOnly)
  local c = map and cache[map.id] or nil
  return c and c[bodyOnly and "body" or "full"] == false or false
end

-- Advance queued builds inside a per-frame time budget. Urgent jobs (the
-- current map) come first and get the larger slice -- the first voxel
-- frame after a toggle is worth more milliseconds than a neighbour
-- popping in one frame later. `covered` says the world pass is hidden
-- this frame (a warp's fade, a menu): nothing visible can hitch, so the
-- slice opens up and a door fade swallows most of a destination build.
local URGENT_SLICE = IS_ANDROID and 0.0020 or 0.012
local IDLE_SLICE = IS_ANDROID and 0.0008 or 0.005
local MOVING_URGENT_SLICE = IS_ANDROID and 0.0009 or URGENT_SLICE
local MOVING_CACHE_SLICE = IS_ANDROID and 0.0006 or IDLE_SLICE
local IDLE_CACHE_SLICE = IS_ANDROID and 0.0030 or IDLE_SLICE
local COVERED_CACHE_SLICE = 0.030
local COVERED_HEAVY_SLICE = IS_ANDROID and 0.0080 or 0.030

local function chooseJob(moving)
  if #jobs == 0 then return nil, false, false end
  local warmPick, warmValue = nil, -math.huge
  for _, job in ipairs(jobs) do
    if job.urgent and not job.terrainReady then return job, true, false end
    -- During Android movement a cold warm job cannot run. Do not let it hide
    -- a lower-priority persistent neighbour that can make cheap progress.
    if not (IS_ANDROID and moving) or job.persistent then
      local value = job.warm or 0
      if not job.terrainReady and value > warmValue then
        warmPick, warmValue = job, value
      end
    end
  end
  if warmPick and warmValue > 0 then return warmPick, false, true end
  return jobs[1], false, false
end

local function walkingAllows(job, urgentPick, warmPick, android)
  if not android then return true end
  if job.terrainReady then return false end
  return urgentPick or (warmPick and job.persistent) or false
end

function ChunkMesher.pump(covered, moving)
  if #jobs == 0 then return end
  local pick, urgentPick, warmPick = chooseJob(moving)
  if not pick then return end
  if moving and not covered
     and not walkingAllows(pick, urgentPick, warmPick, IS_ANDROID) then
    return
  end

  local slice
  if covered then
    slice = pick.persistent and COVERED_CACHE_SLICE or COVERED_HEAVY_SLICE
  elseif moving then
    slice = pick.persistent and MOVING_CACHE_SLICE
            or (urgentPick and MOVING_URGENT_SLICE or 0)
  elseif pick.persistent then
    slice = IDLE_CACHE_SLICE
  else
    slice = urgentPick and URGENT_SLICE or IDLE_SLICE
  end
  if slice <= 0 then return end

  local deadline = clock() + slice
  while pick do
    if not pick.co then
      pick.co = coroutine.create(runJob)
    end
    pick.covered = covered and true or false
    pick.moving = moving and not covered
    Budget.begin(pick.co, math.max(0, deadline - clock()))
    local ok, err = coroutine.resume(pick.co, pick)
    Budget.finish()
    if not ok then
      finishJob(pick, false, err)
    elseif coroutine.status(pick.co) == "dead" then
      finishJob(pick, true)
    else
      return   -- slice spent mid-build; resume next frame
    end
    if clock() >= deadline or #jobs == 0 then return end
    pick, urgentPick, warmPick = chooseJob(moving)
    if not pick then return end
    if moving and not covered
       and not walkingAllows(pick, urgentPick, warmPick, IS_ANDROID) then
      return
    end
  end
end

ChunkMesher._test = {
  walkingAllows = function(job, urgentPick, warmPick)
    return walkingAllows(job, urgentPick, warmPick, true)
  end,
}

-- Meshes for `map`, built SYNCHRONOUSLY on first use -- the historical
-- contract, kept for probes and any direct caller. `false` is cached for
-- a map whose mesh could not be built so a headless run does not retry
-- every frame. `masks` (the full variant's neighbour-body rects) is
-- static per map id -- a map's connections never change -- so it caches
-- like everything else.
function ChunkMesher.get(map, bodyOnly, masks)
  local slot = bodyOnly and "body" or "full"
  local c = entry(map.id)
  if c.grass == nil or c.flowers == nil or (c.stale and c.stale.aux) then
    local okG, grass = pcall(AuxMeshes.buildGrassMesh, map)
    local okF, flowers = pcall(AuxMeshes.buildFlowerMesh, map)
    swapSlot(c, "grass", (okG and grass) or false)
    swapSlot(c, "flowers", (okF and flowers) or false)
    if c.stale then c.stale.aux = nil end
  end
  if c[slot] == nil or (c.stale and c.stale[slot]) then
    local ok, mesh, water = pcall(ChunkMesher.build, map, bodyOnly, masks,
                                  true)
    if not ok then
      local msg = "[warn] voxel mesh build failed for " .. tostring(map.id)
                  .. ": " .. tostring(mesh)
      print(msg)
      if V and V.dlog then V.dlog(msg) end
      if V.log then
        V.log:error("mesh build failed map=%s slot=%s: %s",
          tostring(map.id), tostring(slot), tostring(mesh))
      end
    end
    swapSlot(c, slot, (ok and mesh) or false)
    swapSlot(c, waterSlot(slot), (ok and water) or false)
    if c.stale then
      c.stale[slot] = nil
      if not (c.stale.full or c.stale.body or c.stale.aux) then
        c.stale = nil
      end
    end
    local key = jobKey(map.id, slot)
    local job = jobIndex[key]
    if job then finishJob(job, true) end
  end
  return c[slot] or nil
end

-- The cached mesh, or nil -- never builds. The async path's read side.
function ChunkMesher.peek(map, bodyOnly)
  local c = cache[map.id]
  local mesh = c and c[bodyOnly and "body" or "full"]
  return mesh or nil
end

-- A slot's terrain mesh AND the water surface lifted out of it, as one
-- answer. Never builds, like peek.
--
-- Both or neither, always from the SAME slot: the water was cut out of that
-- exact geometry, so pairing a full mesh with a body build's water would
-- draw the border ring's ponds twice and leave the body's as holes. Callers
-- that fall back from one variant to the other fall back through this, so
-- there is nowhere for the two to be chosen separately.
function ChunkMesher.pair(map, bodyOnly)
  local c = cache[map.id]
  if not c then return nil, nil end
  local slot = bodyOnly and "body" or "full"
  return c[slot] or nil, c[waterSlot(slot)] or nil
end

function ChunkMesher.grass(map)
  local c = cache[map.id]
  return c and c.grass or nil
end

function ChunkMesher.flowers(map)
  local c = cache[map.id]
  return c and c.flowers or nil
end

-- Authored figures as `{ mesh, wx, wz, y, w }` records -- each placed by
-- its own leaning matrix at draw time, so they cannot share one mesh.
function ChunkMesher.figures(map)
  local c = cache[map.id]
  local list = c and c.figures
  return (type(list) == "table") and list or nil
end

-- Rebuild a map's meshes IN PLACE: the stale meshes keep drawing while
-- replacements cook, and each slot swaps as its build lands. This is
-- the block-edit path (a cut tree, a door stamp) -- invalidate() drops
-- the mesh outright, and until the async rebuild landed the scene fell
-- to the flat 2D path, a whole-world blink for a one-block edit.
function ChunkMesher.refresh(mapId)
  if not mapId then return ChunkMesher.invalidate() end
  local c = cache[mapId]
  -- nothing drawable cached: the plain drop costs nothing visible
  if not (c and (c.full or c.body)) then
    return ChunkMesher.invalidate(mapId)
  end
  Structures.invalidate(mapId)
  -- Runtime block edits also invalidate the memoized persistent fingerprint.
  -- The on-disk entry itself is retained: status() will reject it if the
  -- rebuilt map/layout fingerprint differs, and can reuse it if an edit was
  -- subsequently reverted before the next load.
  MeshCache.forget(mapId)
  gen[mapId] = (gen[mapId] or 0) + 1
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if job.id == mapId then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
  -- false-cached slots count as stale too: a retry after a failed build
  -- is exactly a rebuild
  c.stale = { aux = true,
              full = (c.full ~= nil) or nil,
              body = (c.body ~= nil) or nil }
end

-- Evict everything outside `live` (a set of map ids): far maps' meshes
-- are released -- GPU buffer and LOVE's CPU copy both -- and their
-- Structures analysis dropped. The live set is the current map plus its
-- rendered neighbours, so memory stays bounded by what is on or near the
-- screen instead of growing with every area ever visited.
--
-- The PREVIOUS live set is retained too: warping into a building
-- collapses the set to one small interior, and evicting the town at the
-- door means rebuilding the whole neighbourhood on the way out -- a
-- flat-world flash after every house. One set of history makes the
-- round trip free while staying bounded at two neighbourhoods.
local prevLive = {}

function ChunkMesher.setLive(live)
  for id, c in pairs(cache) do
    if not live[id] and not prevLive[id] then
      releaseEntry(c)
      cache[id] = nil
      gen[id] = (gen[id] or 0) + 1
      Structures.invalidate(id)
      MeshCache.forget(id)
    end
  end
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if not live[job.id] and not prevLive[job.id] then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
  prevLive = live
end

-- Drop one map's mesh (Cut swapped a block) or all of them (hot reload).
-- Structures' analysis is derived from the same block layer, so it drops
-- in the same breath; in-flight builds of the map are cancelled through
-- the generation counter.
function ChunkMesher.invalidate(mapId)
  Structures.invalidate(mapId)
  MeshCache.forget(mapId)
  if mapId then
    local c = cache[mapId]
    if c then releaseEntry(c) end
    cache[mapId] = nil
    gen[mapId] = (gen[mapId] or 0) + 1
  else
    for _, c in pairs(cache) do releaseEntry(c) end
    cache = {}
    for id in pairs(gen) do gen[id] = gen[id] + 1 end
  end
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if mapId == nil or job.id == mapId then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
end

Assets.register(function() ChunkMesher.invalidate() end)

return ChunkMesher
