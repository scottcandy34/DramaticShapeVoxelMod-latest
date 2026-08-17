-- Persistent, player-exportable diagnostics for Dramatic Shape.
-- Entries are event-based (no per-frame spam). Survives across boots via
-- mod.storage under the key diagnostics/log.

local V = ...
local Storage = V.require("ModStorage")
local Log = {}
Log.__index = Log

local MAX_LINES = 1500

local function clean(value)
  return tostring(value or "nil"):gsub("[\r\n\t]+", " "):gsub("%s+", " ")
end

local function now()
  if os and os.date then return os.date("!%Y-%m-%dT%H:%M:%SZ") end
  return "runtime"
end

local function format(message, ...)
  if select("#", ...) == 0 then return clean(message) end
  local ok, value = pcall(string.format, tostring(message), ...)
  return clean(ok and value or message)
end

function Log.new(host)
  local self = setmetatable({ host = host, lines = {} }, Log)
  local ver = (V.mod and V.mod.manifest and V.mod.manifest.version)
    or (V.mod and V.mod.version) or "unknown"
  self:info("session started; Dramatic Shape %s", tostring(ver))
  self:event("runtime", "environment", {
    api = (V.mod and V.mod.manifest and V.mod.manifest.api) or "unknown",
    id = (V.mod and V.mod.id) or "DRAMATIC_SHAPE",
  })
  return self
end

function Log:loadStored()
  if self.loaded then return self.loaded end
  if not Storage.game() then return false end
  local record = Storage.read("diagnostics/log")
  if type(record) == "table" and type(record.lines) == "table" then
    local current = self.lines
    self.lines = {}
    for _, line in ipairs(record.lines) do
      if type(line) == "string" then self.lines[#self.lines + 1] = line end
    end
    for _, line in ipairs(current) do self.lines[#self.lines + 1] = line end
  end
  self.loaded = true
  return true
end

function Log:flush()
  -- Bind whatever game we can see, then persist.
  if not Storage.game() then
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game then Storage.setGame(Game) end
  end
  if not self:loadStored() and not Storage.game() then
    return false, "storage_unavailable", "No active playthrough for mod storage."
  end
  local ok, code, message = Storage.write("diagnostics/log", {
    format = 1,
    lines = self.lines,
    updated = now(),
  })
  return ok, code, message
end

function Log:record(level, message, ...)
  self:loadStored()
  local line = ("%s [%s] %s"):format(now(), level, format(message, ...))
  self.lines[#self.lines + 1] = line
  while #self.lines > MAX_LINES do table.remove(self.lines, 1) end
  -- Best-effort persist; never raise from logging.
  pcall(function() self:flush() end)
  local fn = self.host and self.host[level:lower()]
  if type(fn) == "function" then pcall(fn, self.host, "%s", line) end
  return line
end

function Log:info(message, ...) return self:record("INFO", message, ...) end
function Log:warn(message, ...) return self:record("WARN", message, ...) end
function Log:error(message, ...) return self:record("ERROR", message, ...) end

-- Structured line for cross-mod / LLM-friendly diagnostics.
function Log:event(scope, name, fields)
  local parts = {}
  for key, value in pairs(type(fields) == "table" and fields or {}) do
    parts[#parts + 1] = clean(key) .. "=" .. clean(value)
  end
  table.sort(parts)
  local suffix = #parts > 0 and (" " .. table.concat(parts, " ")) or ""
  return self:info("[%s] %s%s", clean(scope), clean(name), suffix)
end

function Log:scope(scope)
  local parent = self
  return {
    info = function(_, message, ...)
      return parent:info("[%s] " .. message, scope, ...)
    end,
    warn = function(_, message, ...)
      return parent:warn("[%s] " .. message, scope, ...)
    end,
    error = function(_, message, ...)
      return parent:error("[%s] " .. message, scope, ...)
    end,
    event = function(_, name, fields)
      return parent:event(scope, name, fields)
    end,
  }
end

function Log:contents()
  return table.concat(self.lines, "\n") .. "\n"
end

function Log:clear()
  self.lines = {}
  self.loaded = true
  return self:flush()
end

return Log
