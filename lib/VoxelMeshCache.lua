-- Persistent BODY geometry for the voxel world.
--
-- ChunkMesher remains the sole owner of geometry generation, invalidation and
-- GPU objects. This module fingerprints BODY inputs and stores the resulting
-- unindexed six-float vertex stream in independent, checksummed chunks.
--
-- Current Gen1Recomp sandboxes love.filesystem and FFI. Persistence therefore
-- goes through SaveData.persistenceFs() (already used by this mod's Stadium
-- cache under its engine_internals permission), with the official opaque-byte
-- mod.storage API as a fallback on runtimes that expose it. love.data remains
-- available to content mods and supplies float packing plus optional LZ4.

local V = ...

local Budget = V.require("BuildBudget")

local Cache = {}

-- Container schema and geometry meaning are deliberately separate. Bump the
-- schema when records change; bump GEOMETRY_VERSION when BODY generation or a
-- geometry-affecting data table changes while the record layout stays valid.
Cache.SCHEMA_VERSION = 2
Cache.GEOMETRY_VERSION = "v184-body-1"
Cache.VERSION = Cache.SCHEMA_VERSION
Cache.CHUNK_VERTICES = 4096
Cache.VERTEX_FLOATS = 6
Cache.VERTEX_BYTES = Cache.VERTEX_FLOATS * 4
Cache.DIRECTORY = "dramatic_shape/voxel_mesh_cache_v"
                  .. Cache.SCHEMA_VERSION

local MAX_VERTICES = 4000000
local MAX_CHUNKS = math.ceil(MAX_VERTICES / Cache.CHUNK_VERTICES)
local UINT32 = 4294967296
local TRI_ORDER = { 1, 2, 3, 1, 3, 4 }

local testBackend = nil
local runtimeBackend = nil
local memo = {}
local sourceDigest = nil
local atlasDigests = {}
local Assets = nil

local function dataApi()
  return (testBackend and testBackend.data) or (love and love.data)
end

local function isAndroid()
  if testBackend and testBackend.android ~= nil then
    return testBackend.android and true or false
  end
  local ok, osName = pcall(function() return love.system.getOS() end)
  return ok and osName == "Android"
end

local function ensureParent(fs, path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and fs.createDirectory then
    local ok, made = pcall(fs.createDirectory, dir)
    return ok and made ~= false
  end
  return true
end

local function persistenceBackend()
  local okSave, SaveData = pcall(require, "src.core.SaveData")
  if not (okSave and SaveData and SaveData.persistenceFs) then return nil end
  local okFs, fs = pcall(SaveData.persistenceFs)
  if not (okFs and fs and fs.read and fs.write and fs.getInfo) then return nil end

  local function pathFor(key)
    return Cache.DIRECTORY .. "/" .. key .. ".dsvc"
  end
  return {
    name = "persistence-fs",
    read = function(key)
      local path = pathFor(key)
      local okInfo, info = pcall(fs.getInfo, path, "file")
      if not (okInfo and info) then return nil end
      local ok, bytes = pcall(fs.read, path)
      return (ok and type(bytes) == "string") and bytes or nil
    end,
    write = function(key, bytes)
      local path = pathFor(key)
      if not ensureParent(fs, path) then return false, "create directory" end
      local ok, wrote, err = pcall(fs.write, path, bytes)
      if not ok then return false, tostring(wrote) end
      if wrote == false or wrote == nil then return false, tostring(err or "write") end
      return true
    end,
    delete = function(key)
      if not fs.remove then return false end
      local ok = pcall(fs.remove, pathFor(key))
      return ok
    end,
  }
end

local function storageBackend()
  local storage = V.mod and V.mod.storage
  if not (storage and storage.readBytes and storage.writeBytes
          and storage.delete) then
    return nil
  end
  local okGame, game = pcall(function() return V.mod.game end)
  if not (okGame and game) then return nil end
  return {
    name = "mod-storage-bytes",
    read = function(key)
      local ok, bytes = pcall(storage.readBytes, storage, game, key)
      return (ok and type(bytes) == "string") and bytes or nil
    end,
    write = function(key, bytes)
      local ok, wrote, code, message = pcall(
          storage.writeBytes, storage, game, key, bytes)
      if not ok then return false, tostring(wrote) end
      if not wrote then return false, tostring(message or code or "write") end
      return true
    end,
    delete = function(key)
      local ok = pcall(storage.delete, storage, game, key)
      return ok
    end,
  }
end

local function backend()
  if testBackend then return testBackend end
  if runtimeBackend then return runtimeBackend end
  -- Preserve V19's one-cache-for-all-saves semantics when the maintained
  -- runtime's persistence router is reachable. Opaque mod.storage is the
  -- supported fallback for a future runtime that closes the internal route.
  runtimeBackend = persistenceBackend() or storageBackend()
  return runtimeBackend
end

function Cache.available()
  local data = dataApi()
  return isAndroid() and backend() ~= nil and data ~= nil
         and type(data.pack) == "function"
         and type(data.newByteData) == "function"
end

local function safeId(id)
  return tostring(id):gsub("[^%w_%-]", "_")
end

local function hashBytes(value)
  local h = 5381
  value = tostring(value or "")
  for i = 1, #value do
    h = (h * 65599 + value:byte(i) + 257) % UINT32
  end
  return string.format("%08x", h)
end

-- Cache compatibility follows the code and authored profile that actually
-- determine BODY vertices, not just a manually maintained version string.
-- This also makes developer hot reloads safe when the manifest version has
-- not changed. mod:read is the supported sandbox route for bundled sources.
local SOURCE_FILES = {
  "lib/ChunkMesher.lua",
  "lib/Structures.lua",
  "lib/Buildings.lua",
  "lib/TileShape.lua",
  "data/voxel_heights.lua",
}

local function sourceFingerprint()
  if sourceDigest then return sourceDigest end
  local parts = {}
  for _, path in ipairs(SOURCE_FILES) do
    local ok, value = pcall(function() return V.mod:read(path) end)
    value = ok and type(value) == "string" and value or "<missing>"
    parts[#parts + 1] = path
    parts[#parts + 1] = tostring(#value)
    parts[#parts + 1] = value
  end
  sourceDigest = hashBytes(table.concat(parts, "\0"))
  return sourceDigest
end

-- Buildings and several structural classifiers inspect atlas pixels. The
-- path alone is insufficient when another mod overrides that asset in place,
-- so hash the resolved ImageData bytes once per tileset. Assets.invalidate
-- clears this memo below.
local function atlasFingerprint(tileset)
  local path = tileset and tileset.image
  if type(path) ~= "string" then return "none" end
  local resolved = path
  if Assets and Assets.resolve then
    local ok, value = pcall(Assets.resolve, path)
    if ok and type(value) == "string" then resolved = value end
  end
  if atlasDigests[resolved] then return atlasDigests[resolved] end
  local digest = "unreadable"
  if Assets and Assets.imageData then
    local okData, imageData = pcall(Assets.imageData, resolved)
    if okData and imageData and imageData.getString then
      local okRaw, raw = pcall(imageData.getString, imageData)
      if okRaw and type(raw) == "string" then digest = hashBytes(raw) end
    end
    if imageData and imageData.release then pcall(imageData.release, imageData) end
  end
  digest = resolved .. "@" .. digest
  atlasDigests[resolved] = digest
  return digest
end

local function mapKey(map)
  local id = tostring(map and map.id or "unknown")
  return "maps/" .. safeId(id) .. "-" .. hashBytes(id)
end

local function readyKey(map)
  return mapKey(map) .. "/ready"
end

local function chunkKey(map, kind, index)
  return ("%s/%s-%06d"):format(mapKey(map), kind, index)
end

local COMPLETE_KEY = "complete"

local function newHash()
  local h = 5381
  local function addNumber(value)
    h = (h * 65599 + (tonumber(value) or 0) + 257) % UINT32
  end
  local function addString(value)
    local text = tostring(value or "")
    addNumber(#text)
    for i = 1, #text do addNumber(text:byte(i)) end
  end
  return function() return h end, addNumber, addString
end

local function currentVoidFill(explicit)
  if explicit ~= nil then return tostring(explicit) end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and TileRenderer then return tostring(TileRenderer.voidFill or "trees") end
  return "trees"
end

local function sortedKeys(values)
  local keys = {}
  if type(values) ~= "table" then return keys end
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- Deterministic hash of the inputs BODY geometry reads. The geometry version
-- handles code/data changes; this fingerprint handles map and runtime inputs.
function Cache.fingerprint(map, voidFill)
  if not (map and map.id and map.def and map.tileAt) then return nil end
  local width, height = tonumber(map.def.width), tonumber(map.def.height)
  if not (width and height and width >= 0 and height >= 0) then return nil end

  local tileset = map.tileset or {}
  local finishHash, addNumber, addString = newHash()
  addString("schema"); addNumber(Cache.SCHEMA_VERSION)
  addString("geometry"); addString(Cache.GEOMETRY_VERSION)
  addString("source"); addString(sourceFingerprint())
  addString("map"); addString(map.id)
  addString("dimensions"); addNumber(width); addNumber(height)
  addString("border"); addString(map.def.borderBlock or "")
  addString("outdoor")
  addString(map.def.outdoor == nil and "default" or map.def.outdoor)
  addString("tileset"); addString(tileset.id or map.def.tileset or "?")
  for _, field in ipairs({ "image", "tilesPerRow", "imageWidth",
                           "imageHeight", "grassTile", "flowerTile" }) do
    addString(field); addString(tileset[field] or "")
  end
  addString("atlas-bytes"); addString(atlasFingerprint(tileset))
  addString("void"); addString(currentVoidFill(voidFill))

  local function addTable(label, values)
    addString(label)
    if type(values) ~= "table" then addNumber(-1); return end
    local keys = sortedKeys(values)
    addNumber(#keys)
    for _, key in ipairs(keys) do
      addString(type(key)); addString(key)
      local value = values[key]
      if type(value) == "table" then
        local nested = sortedKeys(value)
        addNumber(#nested)
        for _, nk in ipairs(nested) do
          addString(type(nk)); addString(nk); addString(value[nk])
        end
      else
        addString(type(value)); addString(value)
      end
    end
  end

  addTable("walkable", map.walkable or tileset.walkable)
  addTable("doors", map.doorTiles or tileset.doorTiles)
  addTable("warps", map.warpTiles or tileset.warpTiles)
  addTable("water", map.waterTiles or tileset.waterTiles)
  addTable("shore", map.shoreTiles or tileset.shoreTiles)

  -- Standard maps expose compact block layout and blockset tables. Hashing
  -- those directly covers live setBlock edits without thousands of protected
  -- tileAt calls during an early neighbour prefetch.
  if type(map.def.blocks) == "table" and type(tileset.blocks) == "table" then
    addTable("layout", map.def.blocks)
    addTable("blockset", tileset.blocks)
  else
    addString("expanded-tiles")
    for y = 0, height * 4 - 1 do
      for x = 0, width * 4 - 1 do
        local ok, tile = pcall(map.tileAt, map, x, y)
        if not ok or tonumber(tile) == nil then return nil end
        addNumber(tile)
      end
    end
  end
  addString("end")
  return string.format("%08x", finishHash())
end

local function expectedChunks(vertices)
  return vertices == 0 and 0
         or math.ceil(vertices / Cache.CHUNK_VERTICES)
end

local function readyBody(fp, bodyVertices, bodyChunks, waterVertices,
                         waterChunks, schema, geometry)
  return ("DSVM|%d|%s|%s|%d|%d|%d|%d|%d|%d\n"):format(
      schema or Cache.SCHEMA_VERSION,
      geometry or Cache.GEOMETRY_VERSION,
      fp, bodyVertices, bodyChunks, waterVertices, waterChunks,
      Cache.CHUNK_VERTICES, Cache.VERTEX_BYTES)
end

local function parseReady(value)
  if type(value) ~= "string" or #value > 256 then return nil end
  local schema, geometry, fp, bodyVertices, bodyChunks,
        waterVertices, waterChunks, chunkVertices, vertexBytes = value:match(
      "^DSVM|(%d+)|([^|]+)|([0-9a-fA-F]+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)\n$")
  schema = tonumber(schema)
  bodyVertices, bodyChunks = tonumber(bodyVertices), tonumber(bodyChunks)
  waterVertices, waterChunks = tonumber(waterVertices), tonumber(waterChunks)
  chunkVertices, vertexBytes = tonumber(chunkVertices), tonumber(vertexBytes)
  if schema ~= Cache.SCHEMA_VERSION
     or geometry ~= Cache.GEOMETRY_VERSION
     or not fp or #fp ~= 8
     or not bodyVertices or bodyVertices < 0 or bodyVertices > MAX_VERTICES
     or not waterVertices or waterVertices < 0 or waterVertices > MAX_VERTICES
     or bodyVertices % 3 ~= 0 or waterVertices % 3 ~= 0
     or bodyChunks ~= expectedChunks(bodyVertices)
     or waterChunks ~= expectedChunks(waterVertices)
     or bodyChunks > MAX_CHUNKS or waterChunks > MAX_CHUNKS
     or chunkVertices ~= Cache.CHUNK_VERTICES
     or vertexBytes ~= Cache.VERTEX_BYTES then
    return nil
  end
  return {
    fingerprint = fp:lower(),
    bodyVertices = bodyVertices,
    bodyChunks = bodyChunks,
    waterVertices = waterVertices,
    waterChunks = waterChunks,
  }
end

local function encodeChunk(kind, fp, index, raw)
  local mode, payload = "R", raw
  local data = dataApi()
  if data and data.compress then
    local ok, packed = pcall(data.compress, "string", "lz4", raw)
    if ok and type(packed) == "string" and #packed < #raw then
      mode, payload = "L", packed
    end
  end
  local header = ("DSVC|%d|%s|%s|%s|%06d|%08x|%08x|%s|%s\n"):format(
      Cache.SCHEMA_VERSION, Cache.GEOMETRY_VERSION, kind, fp, index,
      #raw, #payload, hashBytes(raw), mode)
  return header .. payload
end

local function decodeChunk(value, kind, fp, expectedIndex, expectedBytes)
  if type(value) ~= "string" then return nil, "missing chunk" end
  local newline = value:find("\n", 1, true)
  if not newline or newline > 256 then return nil, "bad chunk header" end
  local header, payload = value:sub(1, newline), value:sub(newline + 1)
  local schema, geometry, gotKind, gotFp, index, rawBytes, storedBytes,
        checksum, mode = header:match(
      "^DSVC|(%d+)|([^|]+)|([^|]+)|([0-9a-fA-F]+)|(%d+)|([0-9a-fA-F]+)|([0-9a-fA-F]+)|([0-9a-fA-F]+)|([RL])\n$")
  schema, index = tonumber(schema), tonumber(index)
  rawBytes, storedBytes = tonumber(rawBytes, 16), tonumber(storedBytes, 16)
  if schema ~= Cache.SCHEMA_VERSION
     or geometry ~= Cache.GEOMETRY_VERSION or gotKind ~= kind
     or not gotFp or gotFp:lower() ~= fp or index ~= expectedIndex
     or rawBytes ~= expectedBytes or storedBytes ~= #payload
     or storedBytes <= 0 or storedBytes > expectedBytes + 65536
     or not checksum or #checksum ~= 8 then
    return nil, "incompatible chunk"
  end
  local raw = payload
  if mode == "L" then
    local data = dataApi()
    if not (data and data.decompress) then return nil, "lz4 unavailable" end
    local ok, unpacked = pcall(data.decompress, "string", "lz4", payload)
    if not ok then return nil, "lz4 decode" end
    raw = unpacked
  end
  if type(raw) ~= "string" or #raw ~= expectedBytes then
    return nil, "truncated chunk"
  end
  if hashBytes(raw) ~= checksum:lower() then return nil, "chunk checksum" end
  return raw
end

local function remove(cacheBackend, key)
  if cacheBackend and cacheBackend.delete then pcall(cacheBackend.delete, key) end
end

function Cache.status(map)
  if not (map and map.id) then return false, nil end
  local cached = memo[map.id]
  if cached and cached.map == map then
    return cached.hit, cached.fingerprint, cached.meta
  end
  local cacheBackend = backend()
  if not cacheBackend then return false, nil end
  local fp = Cache.fingerprint(map)
  local meta = fp and parseReady(cacheBackend.read(readyKey(map))) or nil
  local hit = meta ~= nil and meta.fingerprint == fp
  memo[map.id] = {
    map = map, fingerprint = fp, hit = hit and true or false,
    meta = hit and meta or nil,
  }
  return hit and true or false, fp, hit and meta or nil
end

function Cache.forget(mapId)
  if mapId ~= nil then memo[mapId] = nil else memo = {} end
end

local function newStoreSink(session, kind)
  local parts, buffered, vertices, chunks = {}, 0, 0, 0
  local sink = {}

  local function flush()
    if buffered == 0 then return end
    local raw = table.concat(parts)
    chunks = chunks + 1
    local key = chunkKey(session.map, kind, chunks)
    local ok, err = session.backend.write(
        key, encodeChunk(kind, session.fingerprint, chunks, raw))
    if not ok then error("voxel cache chunk write failed: " .. tostring(err), 0) end
    session.written[#session.written + 1] = key
    parts, buffered = {}, 0
    Budget.check()
  end

  sink.push = function(corners, uv, shade)
    local data = dataApi()
    local flat = type(shade) ~= "table"
    for k = 1, 6 do
      local i = TRI_ORDER[k]
      local c, t = corners[i], uv[i]
      parts[#parts + 1] = data.pack(
          "string", "<ffffff", c[1], c[2], c[3], t[1], t[2],
          tonumber(flat and shade or shade[i]) or 1)
      buffered = buffered + 1
      vertices = vertices + 1
      if vertices > MAX_VERTICES then error("voxel cache vertex limit", 0) end
      if buffered >= Cache.CHUNK_VERTICES then flush() end
    end
  end

  sink.finish = function()
    flush()
    return vertices, chunks
  end
  return sink
end

function Cache.beginStore(map)
  local cacheBackend = backend()
  local fp = Cache.fingerprint(map)
  if not cacheBackend then return nil, "storage unavailable" end
  if not fp then return nil, "fingerprint unavailable" end
  local previous = parseReady(cacheBackend.read(readyKey(map)))
  remove(cacheBackend, readyKey(map))
  remove(cacheBackend, COMPLETE_KEY)
  memo[map.id] = nil

  local session = {
    map = map,
    backend = cacheBackend,
    fingerprint = fp,
    previous = previous,
    written = {},
    sinks = {},
    finished = false,
  }

  function session:sink(kind)
    assert(kind == "body" or kind == "water", "unknown cache stream")
    if not self.sinks[kind] then self.sinks[kind] = newStoreSink(self, kind) end
    return self.sinks[kind]
  end

  function session:abort()
    if self.finished then return end
    self.finished = true
    remove(self.backend, readyKey(self.map))
    for _, key in ipairs(self.written) do remove(self.backend, key) end
    memo[self.map.id] = nil
  end

  function session:commit()
    if self.finished then return false, "store already finished" end
    local body = self:sink("body")
    local water = self:sink("water")
    local bodyVertices, bodyChunks = body.finish()
    local waterVertices, waterChunks = water.finish()
    if bodyVertices % 3 ~= 0 or waterVertices % 3 ~= 0 then
      self:abort()
      return false, "non-triangle vertex count"
    end
    local ok, err = self.backend.write(readyKey(self.map), readyBody(
        self.fingerprint, bodyVertices, bodyChunks,
        waterVertices, waterChunks))
    if not ok then
      self:abort()
      return false, err or "ready marker write"
    end
    self.finished = true

    -- Remove chunks left by a previous, larger generation after the new ready
    -- marker is durable. They are never consulted by the new metadata.
    local previous = self.previous
    if previous then
      for i = bodyChunks + 1, previous.bodyChunks do
        remove(self.backend, chunkKey(self.map, "body", i))
      end
      for i = waterChunks + 1, previous.waterChunks do
        remove(self.backend, chunkKey(self.map, "water", i))
      end
    end
    local meta = {
      fingerprint = self.fingerprint,
      bodyVertices = bodyVertices, bodyChunks = bodyChunks,
      waterVertices = waterVertices, waterChunks = waterChunks,
    }
    memo[self.map.id] = {
      map = self.map, fingerprint = self.fingerprint, hit = true, meta = meta,
    }
    return true, self.fingerprint
  end

  return session
end

local function abortReceiver(receiver)
  if receiver and receiver.abort then pcall(receiver.abort, receiver) end
end

local function loadStream(map, kind, fp, vertices, chunks, receiverFactory,
                          cacheBackend)
  if vertices == 0 then return true, nil end
  local receiver = nil
  local ok, result = pcall(function()
    receiver = assert(receiverFactory(kind, vertices))
    local first = 0
    for index = 1, chunks do
      local count = math.min(Cache.CHUNK_VERTICES, vertices - first)
      local expectedBytes = count * Cache.VERTEX_BYTES
      local raw, err = decodeChunk(
          cacheBackend.read(chunkKey(map, kind, index)), kind, fp,
          index, expectedBytes)
      assert(raw, err)
      receiver:write(raw, first, count)
      first = first + count
      -- Decompression and the corresponding GPU upload are one bounded unit.
      -- The scheduler's deadline decides how many units may land this frame.
      Budget.check()
    end
    assert(first == vertices, "cache vertex count")
    return receiver:finish()
  end)
  if not ok then
    abortReceiver(receiver)
    return false, nil, tostring(result)
  end
  return true, result
end

local function release(value)
  if value and value.release then pcall(value.release, value) end
end

local function markCorrupt(map, cacheBackend)
  remove(cacheBackend, readyKey(map))
  remove(cacheBackend, COMPLETE_KEY)
  memo[map.id] = nil
end

-- receiverFactory(kind, vertexCount) returns an object with
-- write(rawBytes, firstVertex, vertexCount), finish(), and optional abort().
function Cache.load(map, receiverFactory)
  local hit, fp, meta = Cache.status(map)
  if not hit then return false, nil, nil, "miss" end
  local cacheBackend = backend()
  if not cacheBackend then return false, nil, nil, "storage unavailable" end

  local okBody, body, bodyErr = loadStream(
      map, "body", fp, meta.bodyVertices, meta.bodyChunks,
      receiverFactory, cacheBackend)
  if not okBody then
    markCorrupt(map, cacheBackend)
    return false, nil, nil, bodyErr
  end
  local okWater, water, waterErr = loadStream(
      map, "water", fp, meta.waterVertices, meta.waterChunks,
      receiverFactory, cacheBackend)
  if not okWater then
    release(body)
    markCorrupt(map, cacheBackend)
    return false, nil, nil, waterErr
  end
  return true, body, water
end

function Cache.warmupSignature(ids, voidFill)
  local finishHash, _, addString = newHash()
  addString("warmup")
  addString(Cache.SCHEMA_VERSION)
  addString(Cache.GEOMETRY_VERSION)
  addString(sourceFingerprint())
  addString(currentVoidFill(voidFill))
  for _, id in ipairs(ids or {}) do addString(id) end
  return ("DSVM-WARM|%d|%s|%08x\n"):format(
      Cache.SCHEMA_VERSION, Cache.GEOMETRY_VERSION, finishHash())
end

function Cache.warmupComplete(signature)
  local cacheBackend = backend()
  return cacheBackend ~= nil and cacheBackend.read(COMPLETE_KEY) == signature
end

function Cache.markWarmupComplete(signature)
  local cacheBackend = backend()
  if not cacheBackend then return false end
  local ok = cacheBackend.write(COMPLETE_KEY, signature)
  return ok and true or false
end

Cache._test = {
  hashBytes = hashBytes,
  readyBody = readyBody,
  parseReady = parseReady,
  encodeChunk = encodeChunk,
  decodeChunk = decodeChunk,
  keys = function(map, kind, index)
    return readyKey(map), chunkKey(map, kind or "body", index or 1),
           COMPLETE_KEY
  end,
  backendName = function()
    local value = backend()
    return value and value.name or nil
  end,
  setBackend = function(value)
    testBackend = value
    memo = {}
  end,
  clearBackend = function()
    testBackend = nil
    memo = {}
  end,
}

-- The maintained engine's central invalidation is raised for asset overrides
-- and developer reloads. Clearing both layers forces the next request to
-- recompute source/atlas identity before considering a disk entry.
pcall(function()
  Assets = require("src.render.Assets")
  Assets.register(function()
    sourceDigest = nil
    atlasDigests = {}
    Cache.forget()
  end)
end)

return Cache
