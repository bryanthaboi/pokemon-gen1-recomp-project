-- one no-op move anim per fixture move so anim lookups resolve
local none = { seq = {}, source = "fixture" }

return {
  moveAnims = {
    FIX_TACKLE = none,
    FIX_SCRATCH = none,
    FIX_EMBERISH = none,
    FIX_CUT = none,
  },
  subanims = {},
  tilesheets = {},
  baseCoords = {},
}
