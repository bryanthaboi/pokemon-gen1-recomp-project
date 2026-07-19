-- Status infliction against the merged statuses registry: the shared
-- immunity rules stay here, the per-status ones live on the records
-- (canInflict) and so does the landing text (onInflict), so a mod status
-- inflicts through the same path as the vanilla five.

local Runtime = require("src.mods.Runtime")
local Status = require("src.battle.Status")

local StatusRegistry = {}

-- pokered's <USER>/<TARGET> text macros (home/text.asm
-- PlaceMoveUsersName): enemy-mon texts print "Enemy " before the name
local function displayName(b)
  return b.isPlayer and b.name or ("Enemy " .. b.name)
end

-- opts: toxic (start the Toxic counter), moveType (for the type gates),
-- secondary (side-effect of a damaging move), source (inflicting move id).
-- Returns messages; empty means the status did not land.
function StatusRegistry.inflict(battle, target, status, opts)
  opts = opts or {}
  if target.mon.status then return {} end
  -- Substitutes block poison (PoisonEffect calls CheckTargetSubstitute)
  -- and every secondary status, but NOT primary Sleep or Thunder Wave,
  -- their handlers never check the substitute in Gen 1.
  if target.substituteHP and (opts.secondary or status == "PSN") then
    return {}
  end
  -- FreezeBurnParalyzeEffect: a secondary status never lands when the
  -- move's type matches either of the target's types (Body Slam can't
  -- paralyze Normals, Fire can't burn Fire, Ice can't freeze Ice)
  if opts.secondary and status ~= "PSN" then
    for _, t in ipairs(target.curTypes or {}) do
      if opts.moveType == t then return {} end
    end
  end
  local statuses = battle and battle.data and battle.data.statuses
  local record = Status.recordFor(statuses, status)
  if record and record.canInflict and not record.canInflict(target, opts) then
    return {}
  end
  target.mon.status = status
  local msgs
  local display = displayName(target)
  if record and record.onInflict then
    msgs = record.onInflict(battle, target, opts, display)
  else
    msgs = { ("%s\nwas afflicted\nby %s!"):format(display,
               record and record.label or tostring(status)) }
  end
  Runtime.emit("battle.status_inflicted", {
    battle = battle, target = target, status = status, source = opts.source,
  })
  return msgs
end

return StatusRegistry
