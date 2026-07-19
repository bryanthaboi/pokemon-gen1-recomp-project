-- Text token expansion over the merged tokens registry.  Grammar: {NAME}
-- or {NAME:arg}; the handler is fn(game, arg) -> string | nil.  A nil
-- return drops the token (the RAM handler's contract for unset buffers);
-- an unknown NAME is also dropped -- rendering parity with the old
-- closed whitelist -- but logged once per name so a typo'd token is
-- findable instead of silently invisible.

local Logger = require("src.core.Logger")

local Tokens = {}

local warned = {}

function Tokens.warnOnce(name)
  if warned[name] then return end
  warned[name] = true
  Logger.warn("unknown text token {%s}", name)
end

-- handlers defaults to the merged registry (game.data.tokens); a headless
-- caller with no loader passes the engine set explicitly
function Tokens.expand(game, text, handlers)
  handlers = handlers or (game.data and game.data.tokens)
  if not handlers then return text end
  -- the span classes mirror the old {[%w_:]+} catch-all: extractor spans
  -- with spaces or pipes ({NUM:hCoins, 2 | LEADING_ZEROES ...}) were never
  -- dropped before and must stay in the text byte-for-byte
  return (text:gsub("{([%w_]+):?([%w_:]*)}", function(name, arg)
    local fn = handlers[name]
    if not fn then
      Tokens.warnOnce(name)
      return ""
    end
    local ok, out = pcall(fn, game, arg ~= "" and arg or nil)
    if not ok then
      Logger.error("token {%s}: %s", name, tostring(out))
      return ""
    end
    return out or ""
  end))
end

return Tokens
