-- Minimal logger; warnings are collected so debug overlays can show them.

local Logger = { history = {} }

local function emit(level, fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  local line = string.format("[%s] %s", level, msg)
  print(line)
  table.insert(Logger.history, line)
  if #Logger.history > 200 then
    table.remove(Logger.history, 1)
  end
end

function Logger.info(fmt, ...) emit("info", fmt, ...) end
function Logger.warn(fmt, ...) emit("warn", fmt, ...) end
function Logger.error(fmt, ...) emit("error", fmt, ...) end

return Logger
