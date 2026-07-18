-- Event flags stored in the save table, keyed by pokered event constant
-- names (e.g. "EVENT_FOLLOWED_OAK_INTO_LAB").

local Flags = {}

function Flags.set(save, name)
  save.flags[name] = true
end

function Flags.clear(save, name)
  save.flags[name] = nil
end

function Flags.get(save, name)
  return save.flags[name] == true
end

return Flags
