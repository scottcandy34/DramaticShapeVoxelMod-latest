-- Options-row action: force-flush the diagnostic log to mod.storage.
-- The log is also always available via mod.exports.diagnosticLog().

local V = ...
local Export = {}
local last = { state = "SAVE", message = nil }

local function result(state, message)
  last = { state = state, message = message }
  return state == "SAVED", message
end

function Export.available()
  return V.mod and V.mod.storage ~= nil
end

function Export.status()
  return last.state, last.message
end

function Export.export()
  if not Export.available() then
    return result("UNAVAILABLE", "Mod storage is unavailable.")
  end
  local log = V.log
  if not log or not log.flush then
    return result("FAILED", "Diagnostic log is not initialised.")
  end
  local ok, code, message = log:flush()
  if not ok then
    return result("FAILED", tostring(message or code or "Could not save diagnostics."))
  end
  return result("SAVED", "Diagnostic snapshot saved for this playthrough.")
end

function Export.row()
  return {
    id = "DRAMATIC_SHAPE:exportLog",
    label = "SAVE DIAGNOSTIC SNAPSHOT",
    value = function()
      if not Export.available() then return "UNAVAILABLE" end
      return last.state
    end,
    step = function() return Export.export() end,
  }
end

return Export
