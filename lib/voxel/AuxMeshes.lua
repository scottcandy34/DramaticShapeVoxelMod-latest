local V = ...

local Structures = V.require("voxel/Structures")
local Voxel3D = V.require("voxel/Voxel3D")

local AuxMeshes = {}

local function quadsMesh(quads, grass)
  if #quads == 0 then return nil end
  local verts, indices, n = {}, {}, 0
  for _, q in ipairs(quads) do
    for i = 1, 4 do
      local c = q[i]
      local uv = q.uv and q.uv[i] or { q.u, q.v }
      local v = { c[1], c[2], c[3], uv[1], uv[2], q.shade }
      if grass then
        v[7], v[8], v[9], v[10] = q.sway or 0, q.cx or 0,
                                     q.cz or 0,
                                     q.firefly and 2 or (q.leaf and 1 or 0)
      end
      verts[#verts + 1] = v
    end
    Voxel3D.pushQuad(indices, n)
    n = n + 1
  end
  if grass then return Voxel3D.newGrassMesh(verts, indices) end
  return Voxel3D.newMesh(verts, indices)
end

-- The tall-grass rows as their own mesh: VoxelScene draws it AFTER the
-- characters so the southern row of a grass cell still overdraws a
-- walker's feet (characters stamp over terrain, Gen 1 style, so ordinary
-- terrain could never do this).
function AuxMeshes.buildGrassMesh(map)
  return quadsMesh(Structures.forMap(map).grassQuads, true)
end

-- The flower billboards as their own mesh, for the same reason as the
-- grass one: it draws AFTER the characters WITH the same camera-ward
-- pull, so a flower south of a walker occludes their feet and one north
-- of them hides behind them. Baked into the terrain mesh they lost that
-- depth fight against the pulled character card whenever the player
-- stood among flowers. Unlike grass this mesh still CASTS shadows (the
-- sun pass draws it): a handful of flowers per meadow, not thousands of
-- tufts.
function AuxMeshes.buildFlowerMesh(map)
  return quadsMesh(Structures.forMap(map).flowerQuads)
end

-- Authored FIGURES (a person drawn into furniture) as one mesh each, in
-- the card's own local space -- because each one is placed by its own
-- matrix at draw time, leaned back by the camera pitch exactly like a
-- character card (VoxelScene). A figure baked into the terrain mesh could
-- not lean, and a shared mesh could not carry per-figure placement.
--
-- A list, not a mesh: `{ mesh, wx, wz, y, w }` per figure. Maps have one
-- or none, so the loop that draws them is shorter than the terrain's.
-- `w` is the card's own width in its local space (its quads start at
-- x = 0), measured here because the first-person pass yaws a card about
-- its middle -- a card yawed about its left edge swings off its seat.
function AuxMeshes.buildFigureMeshes(map)
  local out = {}
  for _, f in ipairs(Structures.forMap(map).figures or {}) do
    local mesh = quadsMesh(f.quads)
    if mesh then
      local w = 0
      for _, q in ipairs(f.quads) do
        for c = 1, 4 do
          local x = q[c] and q[c][1]
          if x and x > w then w = x end
        end
      end
      out[#out + 1] = { mesh = mesh, wx = f.wx, wz = f.wz, y = f.y, w = w }
    end
  end
  return out
end

-- Figure lists hold their meshes one level down, so the generic slot
-- release cannot reach them.
function AuxMeshes.releaseFigures(list)
  for _, f in ipairs(type(list) == "table" and list or {}) do
    if f.mesh and f.mesh.release then pcall(f.mesh.release, f.mesh) end
  end
end

return AuxMeshes