local V = ...

local Voxel3D = V.require("voxel/Voxel3D")
local Budget = V.require("util/BuildBudget")
local MeshCache = V.require("voxel/VoxelMeshCache")

local ffi = nil
do
  local ok, mod = pcall(require, "ffi")
  if ok then ffi = mod end
end

-- love.system itself is sandboxed; current Gen1Recomp's compatibility facade
-- answers getOS while older sandboxes raise. Fail closed on those older builds
-- rather than changing desktop scheduling.
local IS_ANDROID = false
do
  local ok, osName = pcall(function() return love.system.getOS() end)
  IS_ANDROID = ok and osName == "Android"
end

local MeshSinks = {}

-- MeshCache hands back the exact interleaved six-float bytes expected by
-- Voxel3D.FORMAT. ByteData can be uploaded directly: no FFI pointer or copy is
-- needed, which is what keeps this path valid in the current mod sandbox.
function MeshSinks.cachedMeshReceiver(_, count)
  local mesh = love.graphics.newMesh(Voxel3D.FORMAT, count,
                                     "triangles", "static")
  return {
    write = function(self, raw, first)
      local data = love.data.newByteData(raw)
      mesh:setVertices(data, first + 1)
      if data.release then data:release() end
    end,
    finish = function() return mesh end,
    abort = function()
      if mesh and mesh.release then pcall(mesh.release, mesh) end
      mesh = nil
    end,
  }
end

-- ------------------------------------------------------------ vertex sinks

-- A sink accepts quads (4 corners, 4 uv pairs, flat or per-corner shade)
-- and finishes into a drawable mesh. The TABLE sink reproduces the
-- historical pure-Lua output -- geometry() returns its arrays for the
-- headless suite. The FFI sink packs the same six floats per vertex
-- straight into one growing native buffer, unindexed (v1 v2 v3 v1 v3 v4),
-- skipping ~a million short-lived Lua tables per route and LOVE's slow
-- table-by-table vertex upload.

function MeshSinks.newTableSink()
  local verts, indices, quads = {}, {}, 0
  return {
    push = function(c, uv, shade)
      local flat = type(shade) ~= "table"
      for i = 1, 4 do
        local cc, t = c[i], uv[i]
        verts[#verts + 1] = { cc[1], cc[2], cc[3], t[1], t[2],
                              flat and shade or shade[i] }
      end
      Voxel3D.pushQuad(indices, quads)
      quads = quads + 1
    end,
    results = function()
      return verts, indices, quads
    end,
    finish = function()
      return Voxel3D.newMesh(verts, indices)
    end,
  }
end

local TRI_ORDER = { 1, 2, 3, 1, 3, 4 }

local function newFfiSink()
  local cap = 4096 * 6
  local buf = ffi.new("float[?]", cap * 6)
  local n = 0
  local sink
  sink = {
    push = function(c, uv, shade)
      if n + 6 > cap then
        local grown = ffi.new("float[?]", cap * 2 * 6)
        ffi.copy(grown, buf, n * 6 * 4)
        buf, cap = grown, cap * 2
      end
      local flat = type(shade) ~= "table"
      local base = n * 6
      for k = 1, 6 do
        local i = TRI_ORDER[k]
        local cc, t = c[i], uv[i]
        buf[base] = cc[1]
        buf[base + 1] = cc[2]
        buf[base + 2] = cc[3]
        buf[base + 3] = t[1]
        buf[base + 4] = t[2]
        buf[base + 5] = flat and shade or shade[i]
        base = base + 6
      end
      n = n + 6
    end,
    finish = function()
      if n == 0 then return nil end
      -- upload in slices with budget ticks between: a route-sized mesh
      -- is ~10-20MB and one atomic setVertices was the last remaining
      -- frame spike. The mesh is not cached (so never drawn) until the
      -- whole upload lands, and LuaJIT yields fine across pcall.
      local ok, mesh = pcall(function()
        local m = love.graphics.newMesh(Voxel3D.FORMAT, n,
                                        "triangles", "static")
        local CHUNK = IS_ANDROID and MeshCache.CHUNK_VERTICES or 65536
        local i = 0
        while i < n do
          local count = math.min(CHUNK, n - i)
          local bytes = count * 6 * 4
          local data = love.data.newByteData(bytes)
          ffi.copy(data:getFFIPointer(), buf + i * 6, bytes)
          m:setVertices(data, i + 1)
          data:release()
          i = i + count
          Budget.check()
        end
        return m
      end)
      return ok and mesh or nil
    end,
  }
  return sink
end

function MeshSinks.newSink()
  if ffi and love and love.data and love.data.newByteData
     and love.graphics and love.graphics.newMesh then
    return newFfiSink()
  end
  return MeshSinks.newTableSink()
end

function MeshSinks.persistentCapable()
  return MeshCache.available() and love and love.data
         and love.data.newByteData and love.graphics
         and love.graphics.newMesh
end

return MeshSinks