-- Standalone entry point for the focused persistent voxel-cache suite.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = T.fixtures.load()
local MOD_PATH = os.getenv("DS_MOD_PATH") or "mods/DramaticShapeVoxelMod"
local run = T.sdk.loadMod(MOD_PATH, { data = Data })

T.eq(#run.errors, 0,
  "DRAMATIC_SHAPE loads clean: " .. table.concat(run.errors, "; "))

local lib = run.loader.exports.DRAMATIC_SHAPE.lib
dofile(MOD_PATH .. "/tests/voxel_mesh_cache_test.lua")(
  T,
  lib.require("VoxelMeshCache"),
  lib.require("ChunkMesher"),
  lib.require("VoxelScene"),
  lib.require("TerrainAtlas"),
  lib.require("VoxelCacheScreen"),
  lib.require("Structures"),
  MOD_PATH)

run.release()
T.finish("DRAMATIC_SHAPE voxel mesh cache")
