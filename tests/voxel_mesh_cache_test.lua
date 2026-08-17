-- Focused persistent voxel-cache checks. Loaded by dramatic_shape_test.lua
-- after the mod so it exercises the runtime module instances.

return function(T, Cache, ChunkMesher, VoxelScene, TerrainAtlas,
                CacheScreen, Structures, modPath)
  T.eq(Cache._test.backendName(), "persistence-fs",
    "current Gen1Recomp exposes the sandbox-safe persistence router")

  local files = {}
  local compressed = {}
  local packCalls, zipCalls, unzipCalls = 0, 0, 0
  local packed = {}

  -- The headless SDK does not emulate love.data. This deterministic codec has
  -- the same byte-count contract; a separate LOVE test exercises the real
  -- pack/LZ4/ByteData APIs used on device.
  local data = {}
  function data.pack(container, format, ...)
    if packCalls == 0 then
      T.eq(container, "string", "voxel vertices pack into strings")
      T.eq(format, "<ffffff",
        "voxel vertices use explicit little-endian floats")
      T.eq(select("#", ...), 6,
        "one packed voxel vertex contains six floats")
    end
    packCalls = packCalls + 1
    local value = ("%024d"):format(packCalls)
    packed[#packed + 1] = value
    return value
  end
  function data.compress(container, algorithm, raw)
    T.eq(container, "string", "persistent voxel chunks compress to strings")
    T.eq(algorithm, "lz4", "persistent voxel chunks use LOVE's LZ4 codec")
    zipCalls = zipCalls + 1
    local key = ("z%07d"):format(zipCalls)
    compressed[key] = raw
    return key
  end
  function data.decompress(container, algorithm, value)
    T.eq(container, "string", "persistent voxel chunks decompress to strings")
    T.eq(algorithm, "lz4", "persistent voxel chunks decode with LZ4")
    unzipCalls = unzipCalls + 1
    return assert(compressed[value], "unknown compressed test chunk")
  end
  function data.newByteData(value) return value end

  local backend = { android = true, data = data }
  function backend.read(key) return files[key] end
  function backend.write(key, value) files[key] = value; return true end
  function backend.delete(key) files[key] = nil; return true end
  Cache._test.setBackend(backend)

  local function map(id, width, height, tilesetId, changed)
    local blocks = {}
    for i = 1, width * height do blocks[i] = 0 end
    if changed then blocks[1] = 1 end
    local blockset = { {}, {} }
    for i = 1, 16 do
      blockset[1][i] = (i - 1) % 96
      blockset[2][i] = i % 96
    end
    local result = {
      id = id,
      def = {
        width = width, height = height, tileset = tilesetId,
        blocks = blocks,
      },
      tileset = {
        id = tilesetId, image = "tiles/" .. tilesetId .. ".png",
        tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
        blocks = blockset, grassTile = -1,
      },
      walkable = { [0] = true },
      waterTiles = {}, doorTiles = {}, warpTiles = {}, shoreTiles = {},
      tileAt = function(self, x, y)
        local bx, by = math.floor(x / 4), math.floor(y / 4)
        local block = self.def.blocks[by * width + bx + 1] or 0
        return blockset[block + 1][(y % 4) * 4 + (x % 4) + 1]
      end,
    }
    function result:cellTile(cx, cy) return self:tileAt(cx * 2, cy * 2 + 1) end
    function result:inBounds(cx, cy)
      return cx >= 0 and cy >= 0 and cx < width * 2 and cy < height * 2
    end
    function result:isWalkableCell(cx, cy)
      return self.walkable[self:cellTile(cx, cy)] or false
    end
    function result:isWaterCell() return false end
    function result:isDoorTileCell() return false end
    function result:isGrassCell() return false end
    return result
  end

  local base = map("CACHE_A", 1, 1, "OVERWORLD")
  local fp = Cache.fingerprint(base, "trees")
  T.check(type(fp) == "string" and #fp == 8,
    "a map geometry fingerprint is a stable eight-digit value")
  T.neq(Cache.fingerprint(map("CACHE_B", 1, 1, "OVERWORLD"), "trees"), fp,
    "the map id participates in the persistent-cache fingerprint")
  T.neq(Cache.fingerprint(map("CACHE_A", 2, 1, "OVERWORLD"), "trees"), fp,
    "map dimensions participate in the persistent-cache fingerprint")
  T.neq(Cache.fingerprint(map("CACHE_A", 1, 1, "FOREST"), "trees"), fp,
    "the tileset participates in the persistent-cache fingerprint")
  T.neq(Cache.fingerprint(map("CACHE_A", 1, 1, "OVERWORLD", true), "trees"), fp,
    "the live tile layout participates in the persistent-cache fingerprint")
  local borderChanged = map("CACHE_A", 1, 1, "OVERWORLD")
  borderChanged.def.borderBlock = 7
  T.neq(Cache.fingerprint(borderChanged, "trees"), fp,
    "border geometry participates in the persistent-cache fingerprint")
  T.neq(Cache.fingerprint(base, "black"), fp,
    "void fill participates in the persistent-cache fingerprint")

  -- A ready marker is the commit point. Its explicit schema and geometry
  -- versions are both rejected before any chunk is opened.
  local schemaMap = map("CACHE_SCHEMA", 1, 1, "OVERWORLD")
  local schemaFp = Cache.fingerprint(schemaMap)
  local schemaReady = Cache._test.keys(schemaMap)
  files[schemaReady] = Cache._test.readyBody(
      schemaFp, 6, 1, 0, 0, Cache.SCHEMA_VERSION + 1)
  T.eq(Cache.status(schemaMap), false,
    "a persistent voxel entry from another schema version is rejected")
  files[schemaReady] = Cache._test.readyBody(
      schemaFp, 6, 1, 0, 0, Cache.SCHEMA_VERSION, "other-geometry")
  Cache.forget(schemaMap.id)
  T.eq(Cache.status(schemaMap), false,
    "an entry from another geometry version is rejected")

  -- Exercise the real mesher-to-cache path without a GPU. The Android cold
  -- BODY path must write bounded persistent chunks directly, not construct a
  -- synchronous full neighbour mesh in Lua tables first.
  local generated = map("CACHE_GENERATED", 1, 1, "OVERWORLD")
  local realLoveData = love.data
  local realNewMesh = love.graphics.newMesh
  love.data = data
  love.graphics.newMesh = function()
    error("precompileBody must not allocate a GPU mesh")
  end
  local generatedOk, generatedWhy = ChunkMesher.precompileBody(generated)
  love.data = realLoveData
  love.graphics.newMesh = realNewMesh
  T.check(generatedOk, "the headless voxel mesher writes BODY cache chunks: "
          .. tostring(generatedWhy))
  T.check(Cache.status(generated),
    "headless generated voxel BODY geometry receives a durable ready marker")
  packed, packCalls = {}, 0

  local corners = {
    { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
  }
  local uv = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
  local store = assert(Cache.beginStore(base))
  local bodySink, waterSink = store:sink("body"), store:sink("water")
  local bodyPacks = 684 * 6 -- 4,104: deliberately crosses a chunk boundary
  for _ = 1, 684 do bodySink.push(corners, uv, 0.75) end
  local bodyExpected = table.concat(packed, "", 1, bodyPacks)
  waterSink.push(corners, uv, { 1, 0.9, 0.8, 0.7 })
  local waterExpected = table.concat(packed, "", bodyPacks + 1, #packed)
  T.check(store:commit(), "BODY and water vertex streams serialize successfully")
  local hit, _, meta = Cache.status(base)
  T.check(hit, "the completed per-map marker makes the entry valid")
  T.eq(meta.bodyChunks, 2, "large BODY geometry is split into bounded chunks")
  T.eq(meta.waterChunks, 1, "water has an independent bounded stream")

  local writes = {}
  local function receiver(kind, count)
    local parts = {}
    return {
      write = function(_, raw, first, n)
        parts[#parts + 1] = raw
        writes[#writes + 1] = { kind = kind, first = first, count = n,
                                bytes = #raw }
      end,
      finish = function() return table.concat(parts) end,
      abort = function() parts = {} end,
    }
  end
  local loaded, gotBody, gotWater = Cache.load(base, receiver)
  T.check(loaded, "a complete persistent voxel entry deserializes")
  T.eq(gotBody, bodyExpected, "BODY vertices survive serialize -> deserialize")
  T.eq(gotWater, waterExpected, "water vertices survive serialize -> deserialize")
  T.eq(#writes, 3, "decompression and upload are exposed as bounded chunk units")
  T.check(zipCalls >= 3 and unzipCalls >= 3,
    "the round trip crossed independently LZ4-compressed cache chunks")

  -- A restart loses RAM memo state, not completed per-map work. The unfinished
  -- second map remains missing, which is where preparation resumes.
  Cache._test.setBackend(backend)
  T.check(Cache.status(base), "a completed map remains cached after a restart")
  local second = map("CACHE_SECOND", 1, 1, "OVERWORLD")
  T.eq(Cache.status(second), false,
    "an interrupted warm-up resumes with only its missing maps")
  local signature = Cache.warmupSignature({ "CACHE_A", "CACHE_SECOND" }, "trees")
  T.check(Cache.markWarmupComplete(signature) and Cache.warmupComplete(signature),
    "a finished warm-up records its versioned candidate signature")
  local secondStore = assert(Cache.beginStore(second))
  secondStore:sink("body").push(corners, uv, 1)
  T.check(secondStore:commit(), "a missing warm-up map commits independently")
  T.eq(Cache.warmupComplete(signature), false,
    "new geometry clears a now-stale warm-up completion marker")

  -- The preparation screen skips an already completed map and resumes a
  -- suspended per-map coroutine on the next update instead of restarting it.
  local MapLoader = require("src.world.MapLoader")
  local screenOriginals = {
    load = MapLoader.load,
    trim = MapLoader.trim,
    cached = ChunkMesher.bodyCachedOnDisk,
    precompile = ChunkMesher.precompileBody,
    structures = Structures.invalidate,
  }
  local precompileSteps = 0
  MapLoader.load = function(_, id) return map(id, 6, 4, "OVERWORLD") end
  MapLoader.trim = function() end
  Structures.invalidate = function() end
  ChunkMesher.bodyCachedOnDisk = function(value)
    return value.id == "WARM_ALREADY_DONE"
  end
  ChunkMesher.precompileBody = function(value)
    T.eq(value.id, "WARM_RESUME", "warm-up builds the first missing map")
    precompileSteps = precompileSteps + 1
    coroutine.yield("test-slice")
    precompileSteps = precompileSteps + 1
    return true, "built"
  end
  local warmSignature = Cache.warmupSignature(
      { "WARM_ALREADY_DONE", "WARM_RESUME" })
  local fakeStack = {}
  local warmGame = { data = {}, input = {}, stack = fakeStack }
  local screen = CacheScreen.new(
      warmGame, { "WARM_ALREADY_DONE", "WARM_RESUME" }, warmSignature)
  fakeStack.top = function() return screen end
  fakeStack.pop = function() end
  screen:enter()
  screen:update()
  T.eq(screen.done, 1, "warm-up preserves and skips an already cached map")
  T.eq(precompileSteps, 1,
    "an unfinished map yields after its first bounded preparation slice")
  screen:update()
  T.eq(screen.done, 2, "the next update resumes and completes that map")
  T.eq(precompileSteps, 2, "resumable preparation continues the same coroutine")
  screen:update()
  T.check(screen.finished and Cache.warmupComplete(warmSignature),
    "the all-maps marker is committed only after resumed work completes")
  screen:exit()
  CacheScreen._reset()
  MapLoader.load = screenOriginals.load
  MapLoader.trim = screenOriginals.trim
  ChunkMesher.bodyCachedOnDisk = screenOriginals.cached
  ChunkMesher.precompileBody = screenOriginals.precompile
  Structures.invalidate = screenOriginals.structures

  local changed = map("CACHE_A", 1, 1, "OVERWORLD", true)
  T.eq(Cache.status(changed), false,
    "a layout fingerprint mismatch rejects otherwise compatible cache data")

  -- The ready marker may enqueue a load before payload validation. A truncated
  -- chunk must remove that marker and return a miss without escaping an error.
  Cache.forget(base.id)
  T.check(Cache.status(base), "a valid ready marker can enqueue a cache read")
  local _, bodyKey, completeKey = Cache._test.keys(base, "body", 1)
  files[completeKey] = signature
  files[bodyKey] = files[bodyKey]:sub(1, math.max(1, #files[bodyKey] - 9))
  Cache.forget(base.id)
  local safe, corruptOk = pcall(Cache.load, base, receiver)
  T.check(safe and corruptOk == false,
    "a truncated cache falls back safely instead of throwing")
  Cache.forget(base.id)
  T.eq(Cache.status(base), false,
    "a corrupt cache loses its per-map completion marker")
  T.eq(files[completeKey], nil,
    "corruption also clears the all-maps warm-up marker")

  -- Runtime invalidation clears status memoization. It does not destroy the
  -- global base-map entry; another save whose layout still matches may reuse it.
  local rebuilt = assert(Cache.beginStore(base))
  rebuilt:sink("body").push(corners, uv, 1)
  T.check(rebuilt:commit(), "the cache can be rebuilt after corruption")
  local readyKey = Cache._test.keys(base)
  T.check(Cache.status(base), "the rebuilt cache status is memoized")
  files[readyKey] = nil
  T.check(Cache.status(base), "the status memo is active before invalidation")
  ChunkMesher.invalidate(base.id)
  T.eq(Cache.status(base), false,
    "Cut/door/reload invalidation also clears persistent-cache status")

  local scheduler = ChunkMesher._test
  T.eq(scheduler.walkingAllows({ persistent = false }, false, true), false,
    "normal Android walking does not generate a cold neighbour mesh")
  T.check(scheduler.walkingAllows({ persistent = true }, false, true),
    "normal Android walking may stream a cached neighbour BODY")
  T.check(scheduler.walkingAllows({ persistent = false }, true, false),
    "a missing current-map BODY retains a small urgent recovery slice")
  T.eq(scheduler.walkingAllows({ persistent = true, terrainReady = true },
                               false, true), false,
    "optional work after terrain is visible stays paused while walking")

  -- Exercise prefetch with two direct neighbours. Both cached BODY requests
  -- are submitted immediately; the facing neighbour receives top priority.
  local requested = {}
  local originals = {
    request = ChunkMesher.request,
    pair = ChunkMesher.pair,
    failed = ChunkMesher.failed,
    cached = ChunkMesher.bodyCachedOnDisk,
    live = ChunkMesher.setLive,
    atlasLive = TerrainAtlas.setLive,
  }
  ChunkMesher.setLive = function() end
  TerrainAtlas.setLive = function() end
  ChunkMesher.pair = function() return nil, nil end
  ChunkMesher.failed = function() return false end
  ChunkMesher.bodyCachedOnDisk = function() return true end
  ChunkMesher.request = function(mapValue, bodyOnly, masks, urgent, warm)
    requested[#requested + 1] = {
      id = mapValue.id, body = bodyOnly, masks = masks,
      urgent = urgent, warm = warm,
    }
  end
  local current = map("PREFETCH_CURRENT", 4, 4, "OVERWORLD")
  local east = map("PREFETCH_EAST", 4, 4, "OVERWORLD")
  local west = map("PREFETCH_WEST", 4, 4, "OVERWORLD")
  VoxelScene.prefetch({
    map = current,
    player = { px = 112, py = 64, facing = "right" },
    neighbors = {
      { map = east, ox = 128, oy = 0 },
      { map = west, ox = -128, oy = 0 },
    },
  })
  ChunkMesher.request = originals.request
  ChunkMesher.pair = originals.pair
  ChunkMesher.failed = originals.failed
  ChunkMesher.bodyCachedOnDisk = originals.cached
  ChunkMesher.setLive = originals.live
  TerrainAtlas.setLive = originals.atlasLive
  local neighbourWarm = {}
  for _, request in ipairs(requested) do
    if request.id ~= current.id and request.body then
      neighbourWarm[request.id] = request.warm
    end
  end
  T.check((neighbourWarm.PREFETCH_EAST or 0) > 0
          and (neighbourWarm.PREFETCH_WEST or 0) > 0,
    "every direct neighbour is prefetched early from persistent BODY cache")
  T.check(neighbourWarm.PREFETCH_EAST > neighbourWarm.PREFETCH_WEST,
    "the neighbour in front of the player receives higher upload priority")

  local file = assert(io.open(modPath .. "/lib/VoxelScene.lua", "rb"))
  local sceneSource = file:read("*a")
  file:close()
  local prefetchStart = sceneSource:find("function VoxelScene.prefetch", 1, true)
  local prefetchEnd = prefetchStart
      and sceneSource:find("-- Capture every entity", prefetchStart, true)
  local prefetch = (prefetchStart and prefetchEnd)
      and sceneSource:sub(prefetchStart, prefetchEnd - 1) or ""
  T.check(#prefetch > 0, "the traversal prefetch function is inspectable")
  T.eq(prefetch:find("ChunkMesher.get", 1, true), nil,
    "the walking prefetch path never calls the synchronous mesh getter")
  T.eq(prefetch:find("ChunkMesher.build", 1, true), nil,
    "the walking prefetch path never calls the synchronous mesh builder")
  T.eq(sceneSource:find("forceTerrain", 1, true), nil,
    "no synchronous transition force-build path was introduced")

  Cache._test.clearBackend()
end
