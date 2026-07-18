-- The battle state: wild and trainer battles driven entirely by generated
-- data (species, moves, type chart, trainer parties, encounter tables).
--
-- Flow: intro -> menu (FIGHT/PKMN/ITEM/RUN) -> move select -> turn
-- resolution (a queue of messages/actions/UI pushes) -> back to menu,
-- until one side is out, then finish.  Pops itself and calls
-- onFinish("win"|"lose"|"run"|"caught"|"skipped").
--
-- The Gen 1 move-effect pipeline (multi-hit, charge, trapping, thrash,
-- bide, recharge, confusion, screens, substitute, transform, ...) is
-- ported from engine/battle/core.asm; see docs/behavior-porting-notes.md.

local Catching = require("src.battle.Catching")
local Damage = require("src.battle.Damage")
local Experience = require("src.battle.Experience")
local Font = require("src.render.Font")
local Logger = require("src.core.Logger")
local MoveEffects = require("src.battle.MoveEffects")
local Party = require("src.pokemon.Party")
local Pokemon = require("src.pokemon.Pokemon")
local Status = require("src.battle.Status")
local TrainerAI = require("src.battle.TrainerAI")
local TurnOrder = require("src.battle.TurnOrder")
local TypeChart = require("src.battle.TypeChart")

local BattleState = {}
BattleState.__index = BattleState
BattleState.isOpaque = true

-- Battle colors itself per-pixel (species pics + HP bar tints), so the
-- SGB whole-screen remap must not run over it.
function BattleState.sgbPalettes() return nil end

local Rulesets = {
  gen1_faithful = require("src.battle.rulesets.gen1_faithful"),
  modern_clean = require("src.battle.rulesets.modern_clean"),
}

-- the Poké Ball toss chain (TossBallAnimation) plays even with battle
-- animations off: PlayMoveAnimation jumps to it before checking wOptions
local BALL_ANIMS = {
  TOSS_ANIM = true, GREATTOSS_ANIM = true, ULTRATOSS_ANIM = true,
  BLOCKBALL_ANIM = true, POOF_ANIM = true, HIDEPIC_ANIM = true,
  SHAKE_ANIM = true, SHOWPIC_ANIM = true,
}

local imageCache = {}
-- fully transparent rows below a pic's content (the extracted 32x32 back
-- pics carry baked-in padding); used to sit the pic flush on the text box
local imagePadBottom = {}
-- image -> { path, pal } so palette-fade variants (see fadeImage) can be
-- rebuilt for any battle pic, whatever code loaded it
local imageMeta = {}
-- pal = { name, colors } recolors the 4 GB shades like the Super Game Boy
local function getImage(path, pal)
  if not path then return nil end
  local key = pal and (path .. "#" .. pal.name) or path
  if not imageCache[key] then
    local img, pad = nil, 0
    if love.image and love.image.newImageData then
      local id = love.image.newImageData(path)
      if pal then
        local c = pal.colors
        id:mapPixel(function(_, _, r, g, b, a)
          if a == 0 then return r, g, b, a end
          local col = r > 0.83 and c[1] or r > 0.5 and c[2]
                      or r > 0.17 and c[3] or c[4]
          return col[1] / 255, col[2] / 255, col[3] / 255, a
        end)
      end
      local w, h = id:getDimensions()
      local bottom = h - 1
      while bottom >= 0 do
        local opaque = false
        for x = 0, w - 1 do
          local _, _, _, a = id:getPixel(x, bottom)
          if a > 0 then opaque = true break end
        end
        if opaque then break end
        bottom = bottom - 1
      end
      img = love.graphics.newImage(id)
      pad = h - 1 - bottom
    else
      img = love.graphics.newImage(path) -- headless stub: no pixel access
    end
    imageCache[key] = img
    imagePadBottom[img] = pad
    imageMeta[img] = { path = path, pal = pal }
  end
  return imageCache[key]
end

-- the species' SGB palette (data/pokemon/palettes.asm), or nil
local function monPalette(data, species)
  local p = data.palettes
  local name = p and p.pokemon[species]
  local colors = name and p.palettes[name]
  return colors and { name = name, colors = colors } or nil
end

-- a named palette from data/generated/palettes.lua as a getImage pal
local function namedPalette(data, name)
  local p = data.palettes
  local colors = p and p.palettes[name]
  return colors and { name = name, colors = colors } or nil
end

-- The battle-BGP fade variant of a pic (AnimationFlashScreen and the
-- SetAnimationBGPalette effects remap the four BG shades; on the SGB
-- the colorizer then colors the REMAPPED shade, so a faded pic shows
-- palette[bgp[shade]]).  bgp = shade map {[0..3] -> 0..3} or nil.
local function fadeImage(img, bgp)
  if not bgp or not img then return img end
  local meta = imageMeta[img]
  if not meta then return img end
  local PaletteFX = require("src.render.PaletteFX")
  local base = meta.pal and meta.pal.colors or PaletteFX.GRAYS
  local name = (meta.pal and meta.pal.name or "GB")
               .. "&" .. bgp[0] .. bgp[1] .. bgp[2] .. bgp[3]
  return getImage(meta.path,
                  { name = name, colors = PaletteFX.permute(base, bgp) })
end

-- the raw DMG-gray build of a colored pic (SE_WAVY_SCREEN bakes the
-- pics into the BG canvas so they wave with it; the zone pass then
-- colors them by region like the real SGB)
local function grayImage(img)
  local meta = imageMeta[img]
  if not meta or not meta.pal then return img end
  return getImage(meta.path) or img
end

-- the image a battler pic actually draws with this frame
function BattleState:picImage(img)
  if self.grayPics then return grayImage(img) end
  return fadeImage(img, self:activeBgp())
end

-- Gen 1 trainer Pokémon have fixed DVs (engine/battle/core.asm)
local TRAINER_DVS = { attack = 9, defense = 8, speed = 8, special = 8, hp = 8 }

-- Status-move effects whose pokered handlers call MoveHitTest (sleep/
-- poison/paralyze/confusion/leech seed/disable and the primary
-- stat-down moves).  Everything else in MoveEffects.primary is
-- self-targeting and never rolls accuracy.  Mimic also hit-tests but
-- runs its own mid-move flow (resolveMimic).
local ACC_CHECKED_STATUS = {
  SLEEP_EFFECT = true, POISON_EFFECT = true, PARALYZE_EFFECT = true,
  CONFUSION_EFFECT = true, LEECH_SEED_EFFECT = true, DISABLE_EFFECT = true,
  ATTACK_DOWN1_EFFECT = true, DEFENSE_DOWN1_EFFECT = true,
  DEFENSE_DOWN2_EFFECT = true, SPEED_DOWN1_EFFECT = true,
  ACCURACY_DOWN1_EFFECT = true,
}

-- pokered's <USER>/<TARGET> text macros (home/text.asm
-- PlaceMoveUsersName): battle texts naming the enemy mon print
-- "Enemy " before the nickname; player-side mons never get it.
local function displayName(b)
  return b.isPlayer and b.name or ("Enemy " .. b.name)
end

-- Apply the "Enemy " prefix to a pre-built message from a module that
-- only knows the raw nickname (Status.beforeMove/residual,
-- TrainerAI.useItem): splice it in before the first name occurrence.
local function prefixEnemy(msg, battler)
  if battler.isPlayer then return msg end
  local s = msg:find(battler.name, 1, true)
  if not s then return msg end
  return msg:sub(1, s - 1) .. "Enemy " .. msg:sub(s)
end

-- Level-up stats window (PrintStatsBox .LevelUpStatsBox: box (9,2)
-- 11x10 over the battle, dismissed with A/B)
local StatBox = {}
StatBox.__index = StatBox

function StatBox.new(game, mon, onDone)
  return setmetatable({ game = game, mon = mon, onDone = onDone }, StatBox)
end

function StatBox:update()
  local input = self.game.input
  if input:wasPressed("a") or input:wasPressed("b") then
    self.game.stack:pop()
    if self.onDone then self.onDone() end
  end
end

function StatBox:draw()
  Font.drawBox(9, 2, 11, 10)
  love.graphics.setColor(0, 0, 0, 1)
  local s = self.mon.stats
  local rows = { { "ATTACK", s.attack }, { "DEFENSE", s.defense },
                 { "SPEED", s.speed }, { "SPECIAL", s.special } }
  for i, r in ipairs(rows) do
    Font.draw(r[1], 88, 24 + (i - 1) * 16)
    Font.draw(("%3d"):format(r[2]), 128, 32 + (i - 1) * 16)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------

local function makeBattler(data, mon, isPlayer, save)
  local def = data.pokemon[mon.species]
  local badges = nil
  if isPlayer and save then
    -- Gen 1 badge stat boosts (x9/8)
    badges = {}
    for _, b in ipairs({ "BOULDERBADGE", "THUNDERBADGE", "SOULBADGE", "VOLCANOBADGE" }) do
      if save.inventory[b] then badges[b] = true end
    end
  end
  return {
    mon = mon,
    def = def,
    name = mon.nickname or def.name,
    isPlayer = isPlayer,
    badges = badges,
    shownHP = mon.hp, -- the HP the bar displays (UpdateHPBar drain)
    stages = {},
    -- volatile state; Transform/Conversion/Mimic override the cur* fields
    curStats = mon.stats,
    curTypes = def.types,
    curMoves = mon.moves,
    sprite = getImage(isPlayer and def.spriteBack or def.spriteFront,
                      monPalette(data, mon.species)),
  }
end

-- The battle pic for `species` on the given side (back pic for the
-- player side, front pic for the enemy side), tinted PAL_GRAYMON --
-- the same path makeBattler uses, but forced gray -- since this is only
-- ever used for a Transformed mon's swapped-in pic (transform.asm:31-53
-- AnimationTransformMon; the SGB color comes from DeterminePaletteID,
-- which forces PAL_GRAYMON for a Transformed mon rather than the copied
-- species' own palette).
function BattleState:speciesSprite(species, isPlayerSide)
  local def = self.data.pokemon[species]
  if not def then return nil end
  local PaletteFX = require("src.render.PaletteFX")
  local colors = PaletteFX.monPal(self.data, species, true)
  return getImage(isPlayerSide and def.spriteBack or def.spriteFront,
                  colors and { name = "GRAYMON", colors = colors } or nil)
end

local function markSeen(game, species)
  local dex = game.save.pokedex
  if dex then dex.seen[species] = true end
end

-- newly obtained mons carry the player's OT name/ID (status screen)
local function stampOT(save, mon)
  save.player.id = save.player.id or math.random(0, 65535)
  mon.ot = mon.ot or save.player.name
  mon.otId = mon.otId or save.player.id
end
BattleState.stampOT = stampOT

local function markOwned(game, species)
  local dex = game.save.pokedex
  if dex then
    dex.seen[species] = true
    if not dex.owned[species] then
      -- new dex page registered (SFX_DEX_PAGE_ADDED)
      require("src.core.Sound").play(game.data, "Dex_Page_Added")
    end
    dex.owned[species] = true
  end
end
BattleState.markOwned = markOwned
BattleState.StatBox = StatBox -- the level-up stat window (PrintStatsBox)

local function newBattle(game)
  local self = setmetatable({}, BattleState)
  self.game = game
  self.data = game.data
  self.ruleset = Rulesets[game.save.options and game.save.options.ruleset or "gen1_faithful"]
                 or Rulesets.gen1_faithful
  self.rng = function(a, b) return love.math.random(a, b) end
  TypeChart.load(game.data)
  -- the subanimation player (data/battle_anims via battle_anims.lua)
  if game.data.battle_anims then
    local ok, AnimPlayer = pcall(require, "src.battle.AnimPlayer")
    if ok then
      self.animPlayer = AnimPlayer.new(game.data.battle_anims)
    end
  end
  self.queue = {}
  self.phase = "intro"
  self.menuIndex = 1
  self.moveIndex = 1
  self.frame = 0
  return self
end

-- opts.hooked: rod encounter, announced with _HookedMonAttackedText
function BattleState.newWild(game, species, level, opts)
  local self = newBattle(game)
  self.kind = "wild"
  local playerMon = Party.firstHealthy(game.save.party)
  if not playerMon then
    Logger.warn("wild battle with no healthy party; skipping")
    self.dead = true
  else
    self.player = makeBattler(game.data, playerMon, true, game.save)
  end
  self.enemy = makeBattler(game.data, Pokemon.new(game.data, species, level), false)
  markSeen(game, species)
  if opts and opts.hooked then
    self.introText = ("The hooked\n%s\nattacked!"):format(self.enemy.name)
  else
    self.introText = ("Wild %s\nappeared!"):format(self.enemy.name)
  end
  return self
end

-- data/trainers/special_moves.asm + read_trainer_party.asm: boss move
-- overrides, always written into the mon's THIRD move slot.
--   LoneMoves: the gym scripts write the gym number to wGymLeaderNo, so
--   these fire only for the leaders' gym battles (Giovanni: party 3);
--   the table's "index n" lands on the (n+1)-th party mon via AddNTimes.
--   TeamMoves: despite the "whole team" comment, the code writes only
--   wEnemyMon5Moves+2,  the FIFTH mon of each Elite Four member.
--   RIVAL3 (Champion): Pidgeot gets SKY ATTACK, the starter's final
--   form gets MEGA DRAIN / FIRE BLAST / BLIZZARD.
local LONE_MOVES = {
  OPP_BROCK = { 2, "BIDE" },
  OPP_MISTY = { 2, "BUBBLEBEAM" },
  OPP_LT_SURGE = { 3, "THUNDERBOLT" },
  OPP_ERIKA = { 3, "MEGA_DRAIN" },
  OPP_KOGA = { 4, "TOXIC" },
  OPP_SABRINA = { 4, "PSYWAVE" },
  OPP_BLAINE = { 4, "FIRE_BLAST" },
  OPP_GIOVANNI = { 5, "FISSURE", onlyParty = 3 },
}
local TEAM_MOVES = {
  OPP_LORELEI = "BLIZZARD", OPP_BRUNO = "FISSURE",
  OPP_AGATHA = "TOXIC", OPP_LANCE = "BARRIER",
}
local RIVAL_STARTER_MOVES = {
  VENUSAUR = "MEGA_DRAIN", CHARIZARD = "FIRE_BLAST", BLASTOISE = "BLIZZARD",
}

local function setThirdMove(data, mon, moveId)
  if not mon then return end
  local mdef = data.moves[moveId]
  local entry = { id = moveId, pp = mdef and mdef.pp or 0 }
  mon.moves[math.min(3, #mon.moves + 1)] = entry
end

local function applySpecialMoves(data, oppClass, partyIndex, party)
  local lone = LONE_MOVES[oppClass]
  if lone and (not lone.onlyParty or lone.onlyParty == partyIndex) then
    setThirdMove(data, party[lone[1]], lone[2])
    return
  end
  local team = TEAM_MOVES[oppClass]
  if team then
    setThirdMove(data, party[5], team)
    return
  end
  if oppClass == "OPP_RIVAL3" then
    setThirdMove(data, party[1], "SKY_ATTACK")
    local starter = party[6]
    if starter and RIVAL_STARTER_MOVES[starter.species] then
      setThirdMove(data, starter, RIVAL_STARTER_MOVES[starter.species])
    end
  end
end

function BattleState.newTrainer(game, oppClass, partyIndex)
  local self = newBattle(game)
  self.kind = "trainer"
  self.trainer = game.data.trainers[oppClass]
  assert(self.trainer, "unknown trainer class " .. tostring(oppClass))
  self.enemyAIMods = self.trainer.aiMods
  local partyDef = self.trainer.parties[partyIndex or 1]
  assert(partyDef, ("trainer %s has no party %s"):format(oppClass, tostring(partyIndex)))
  self.enemyParty = {}
  for _, slot in ipairs(partyDef) do
    local mon = Pokemon.new(game.data, slot.species, slot.level)
    -- fixed trainer DVs, recomputed stats
    mon.dvs = TRAINER_DVS
    mon.stats = require("src.pokemon.Stats").calc(game.data.pokemon[slot.species],
                                                  slot.level, TRAINER_DVS)
    mon.hp = mon.stats.hp
    table.insert(self.enemyParty, mon)
  end
  applySpecialMoves(game.data, oppClass, partyIndex or 1, self.enemyParty)
  self.enemyIndex = 1
  local playerMon = Party.firstHealthy(game.save.party)
  if not playerMon then
    Logger.warn("trainer battle with no healthy party; skipping")
    self.dead = true
  else
    self.player = makeBattler(game.data, playerMon, true, game.save)
  end
  self.enemy = makeBattler(game.data, self.enemyParty[1], false)
  self.aiUses = self:aiUsesFor() -- wAICount, reset per enemy mon
  markSeen(game, self.enemyParty[1].species)
  -- SGB: the enemy-side battle palette while the trainer pic is up is
  -- MonsterPalettes[0] = PAL_MEWMON -- InitBattleCommon zeroes
  -- wEnemyMonSpecies2 before the intro's SET_PAL_BATTLE
  -- (engine/battle/core.asm:6682, engine/gfx/palettes.asm SetPal_Battle)
  self.trainerPic = getImage(self.trainer.pic, namedPalette(game.data, "MEWMON"))
  self.introText = ("%s wants\nto fight!"):format(self.trainer.name)
  return self
end

-- Pokémon Tower ghosts (engine/battle/core.asm): without the Silph Scope
-- the enemy is "GHOST", you're too scared to attack, and balls fail.
function BattleState:makeGhost()
  self.ghost = true
  self.enemy.name = "GHOST"
  -- the ghost keeps the disguised mon's SGB palette: InitWildBattle
  -- swaps only the pic, wEnemyMonSpecies2 still holds the real species
  -- (engine/battle/core.asm InitWildBattle .isGhost)
  self.enemy.sprite = getImage("assets/generated/battle/front/ghost.png",
                               monPalette(self.data, self.enemy.mon.species))
  self.introText = "The GHOST\nappeared!"
end

-- The old man's catch tutorial (BATTLE_TYPE_OLD_MAN,
-- engine/battle/core.asm DisplayBattleMenu .oldManName branch): no
-- player mon; the battle menu appears under the OLD MAN's name and a
-- scripted cursor hovers FIGHT, hops to ITEM and forces the item menu
-- (one POKé BALL x50).  The throw always catches; nothing is kept.
function BattleState:makeOldManDemo()
  self.demo = true
end

-- Safari Zone battles (engine/battle/core.asm safari sections +
-- engine/battle/safari_zone.asm): no player mon acts; the menu is
-- BALL / BAIT / ROCK / RUN.  state is save.safari ({balls, steps}).
function BattleState:makeSafari(state)
  self.safari = state
  self.safariCatchRate = self.enemy.def.catchRate
  self.baitFactor = 0
  self.escapeFactor = 0
end

-- ---------------------------------------------------------------------
-- message/action queue
-- ---------------------------------------------------------------------

function BattleState:say(text)
  table.insert(self.queue, { text = text })
end

function BattleState:act(fn)
  table.insert(self.queue, { fn = fn })
end

-- push a UI state above the battle; the queue pauses until it pops
function BattleState:ui(factory)
  table.insert(self.queue, { ui = factory })
end

-- insert an animation row right after the current queue item (the
-- POOF/ball-toss animations past the move table); `shakes` marks the
-- ball-shake row with its wNumShakes repeat count, `ball` marks a toss
-- row with the thrown ball item (wCurItem -- a Master/Ultra toss
-- flickers the OBJ palette, DoBallTossSpecialEffects)
function BattleState:animNext(name, isPlayer, shakes, ball)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert,
               { anim = name, attackerIsPlayer = isPlayer, shakes = shakes,
                 ball = ball })
end

-- insert an act right after the current queue item
function BattleState:actNext(fn)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { fn = fn })
end

-- insert message right after the currently-executing queue item (the
-- counter is reset by updateQueue before each fn item runs)
function BattleState:sayNext(text)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { text = text })
end

-- insert a UI push right after the current queue item (dex page, the
-- level-up stat box -- anything that must keep queue order)
function BattleState:uiNext(factory)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { ui = factory })
end

-- insert a wait for the HP bars to finish draining (UpdateHPBar):
-- the queue holds until every battler's displayed HP catches up
function BattleState:drainNext()
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { drain = true })
end

-- One frame of the HP-bar drain (engine/gfx/hp_bar.asm UpdateHPBar):
-- the bar animates a pixel per two frames, so displayed HP moves at
-- maxHP/96 per frame (48-pixel bar).  Returns true while animating.
function BattleState:stepHPDrain()
  local busy = false
  for _, b in ipairs({ self.player, self.enemy }) do
    if b and b.shownHP and b.shownHP ~= b.mon.hp then
      local step = math.max(1, b.mon.stats.hp) / 96
      if b.shownHP > b.mon.hp then
        b.shownHP = math.max(b.mon.hp, b.shownHP - step)
      else
        b.shownHP = math.min(b.mon.hp, b.shownHP + step)
      end
      busy = busy or b.shownHP ~= b.mon.hp
    end
  end
  return busy
end

-- the integer HP the HUD shows for a battler (whole HP ticks, like
-- UpdateHPBar's 1-HP steps)
local function shownHP(b)
  local shown = b.shownHP or b.mon.hp
  if shown > b.mon.hp then return math.ceil(shown) end
  return math.floor(shown)
end

function BattleState:startMessage(item)
  self.current = item
  self.lines = {}
  self.total = 0
  for chunk in (item.text .. "\n"):gmatch("(.-)\n") do
    local codes = Font.encode(chunk)
    table.insert(self.lines, codes)
    self.total = self.total + #codes
  end
  self.charIndex = 0
  self.holdTimer = nil
end

function BattleState:updateQueue()
  if self.waitingUI then
    if self.game.stack:top() ~= self then return true end
    self.waitingUI = nil
  end
  -- a queued hold (faint slide, hit blink) counts down before the next row
  if self.waitFrames and self.waitFrames > 0 then
    self.waitFrames = self.waitFrames - 1
    return true
  end
  -- an HP-bar drain holds the queue until the bar catches up
  if self.draining then
    if self:stepHPDrain() then return true end
    self.draining = nil
  end
  -- a move animation holds the queue until it finishes; its screen
  -- effects (SE_*) and per-row sounds route into the fx layer as they
  -- fire (applyAnimEffect implements each AnimationXXX routine)
  if self.animPlaying then
    self.animPlayer:update()
    if self.animPlayer.pollEffects and self.applyAnimEffect then
      for _, ev in ipairs(self.animPlayer:pollEffects()) do
        self:applyAnimEffect(ev)
      end
    end
    if self.animPlayer:isDone() then
      self.animPlaying = false
      -- the target's hit blink + damage sound follow the animation
      -- (pokered plays them after PlayMoveAnimation returns)
      if self.pendingHit then
        self:applyHitFx(self.pendingHit)
        self.pendingHit = nil
      end
    end
    return true
  end
  if not self.current then
    local item = table.remove(self.queue, 1)
    if not item then return false end
    if item.fn then
      self.nextInsert = 0 -- sayNext inserts right after this item
      item.fn()
      self.current = nil
      return true
    end
    if item.ui then
      self.waitingUI = true
      self.game.stack:push(item.ui())
      return true
    end
    if item.drain then
      self.draining = true
      return true
    end
    if item.wait then
      self.waitFrames = item.wait
      return true
    end
    if item.mimicSelect then
      -- pause the queue on Mimic's copy menu (MoveSelectionMenu with
      -- wMoveMenuType = 1 lists the enemy's moves; cursor starts on 1)
      local ctx = item.mimicSelect
      local rows = {}
      for i, m in ipairs(ctx.target.curMoves) do
        if m.id and m.pp ~= nil then rows[#rows + 1] = { slot = i, id = m.id } end
      end
      self.mimicMoves = rows
      self.mimicIndex = 1
      self.mimicCtx = ctx
      self.phase = "mimicSelect"
      return true
    end
    -- animation queue rows: play the move sound and start the
    -- subanimation (or just the coarse fx when animations are off).
    -- item.hit carries the target's blink + damage sound, applied when
    -- the animation ends (hitRow rows carry a hit with no animation --
    -- thrash/rage continuation turns that skip the announcement).
    if item.anim or item.hitRow then
      local mdef = item.anim and self.data.moves[item.anim]
      local anim = mdef and mdef.anim
      if item.anim == "POOF_ANIM" then
        -- the send-out poof plays SFX_BALL_POOF
        require("src.core.Sound").play(self.data, "Ball_Poof")
      elseif item.anim == "HIDEPIC_ANIM" then
        self.enemyHidden = true    -- SE_HIDE_ENEMY_MON_PIC
      elseif item.anim == "SHOWPIC_ANIM" then
        self.enemyHidden = false   -- SE_SHOW_ENEMY_MON_PIC
      end
      -- ball/send-out anims ignore the OPTIONS toggle: PlayMoveAnimation
      -- short-circuits to TossBallAnimation before its wOptions check
      -- (engine/battle/animations.asm:415)
      if item.anim and (self:animationsOn() or BALL_ANIMS[item.anim]) then
        if self.animPlayer then
          local ok = pcall(self.animPlayer.start, self.animPlayer,
                           item.anim, item.attackerIsPlayer,
                           (item.shakes or item.ball)
                             and { shakes = item.shakes, ball = item.ball }
                             or nil)
          self.animPlaying = ok
        end
        self.fx = self.fx or {}
        if anim and anim.shake and not self.animPlaying then self.fx.shake = 24 end
        if anim and anim.flash and not self.animPlaying then self.fx.flash = 16 end
      end
      if self.animPlaying then
        -- the animation rows carry their own sounds (PlayAnimation
        -- plays each row's MoveSoundTable entry with its pitch/tempo
        -- modifiers); which side the pic effects target follows the
        -- attacker (hWhoseTurn)
        self.animName = item.anim
        self.animAttackerIsPlayer = item.attackerIsPlayer
        self:resetPicFx()
        for _, ev in ipairs(self.animPlayer:pollEffects()) do
          self:applyAnimEffect(ev) -- frame-0 rows (first sound/effect)
        end
        self.pendingHit = item.hit
      else
        -- no subanimation player: keep the single-sound fallback (with
        -- the move's pitch/tempo modifiers; GROWL/ROAR play the
        -- attacker's cry -- GetMoveSound/IsCryMove)
        if item.anim == "GROWL" or item.anim == "ROAR" then
          local attacker = item.attackerIsPlayer and self.player or self.enemy
          if attacker then
            require("src.core.Sound").playMoveCry(self.data, attacker.mon.species,
                                                   anim and anim.tempo)
          end
        elseif anim and anim.sound then
          local Sound = require("src.core.Sound")
          if Sound.playMove then
            Sound.playMove(self.data, anim)
          else
            Sound.play(self.data, anim.sound)
          end
        end
        if item.hit then
          self:applyHitFx(item.hit)
        end
      end
      self.current = nil
      return true
    end
    self:startMessage(item)
  end
  if self.charIndex < self.total then
    self.charIndex = math.min(self.total, self.charIndex + 2)
  else
    self.holdTimer = (self.holdTimer or 40) - 1
    local input = self.game.input
    if self.holdTimer <= 0 or input:wasPressed("a") or input:wasPressed("b") then
      self.current = nil
    end
  end
  return true
end

-- ---------------------------------------------------------------------
-- update / menus
-- ---------------------------------------------------------------------

-- PrintSendOutMonMessage (engine/battle/common_text.asm): the shout
-- scales with the enemy's remaining HP percentage, approximated as
-- curHP * 25 / (maxHP / 4): >=70 "Go!", 40-69 "Do it!", 10-39
-- "Get'm!", below 10 "The enemy's weak!  Get'm!".
function BattleState:sendOutText(name)
  local e = self.enemy and self.enemy.mon
  local pct = 100
  if e and e.hp > 0 and math.floor(e.stats.hp / 4) > 0 then
    pct = math.floor(e.hp * 25 / math.floor(e.stats.hp / 4))
  end
  if pct >= 70 then return ("Go! %s!"):format(name) end
  if pct >= 40 then return ("Do it! %s!"):format(name) end
  if pct >= 10 then return ("Get'm! %s!"):format(name) end
  return ("The enemy's weak!\nGet'm! %s!"):format(name)
end

-- audio/play_battle_music.asm: gym leaders (wGymLeaderNo) get the
-- gym-leader theme, Lance does too, and the Champion (OPP_RIVAL3)
-- gets the final-battle theme
function BattleState:computeMusicKind()
  local isBoss = false
  if self.kind == "trainer" and self.trainer then
    local victories = require("data.scripts.victories")
    for key, reward in pairs(victories) do
      if reward.badge and key:find(self.trainer.id .. "#", 1, true) == 1 then
        isBoss = true
        break
      end
    end
  end
  if self.kind == "trainer" and self.trainer
     and self.trainer.id == "OPP_RIVAL3" then
    return "final"
  elseif isBoss or (self.trainer and self.trainer.id == "OPP_LANCE") then
    return "gym"
  elseif self.kind == "trainer" then
    return "trainer"
  end
  return "wild"
end

function BattleState:enter()
  if self.dead then
    self.game.stack:pop()
    if self.onFinish then self.onFinish("skipped") end
    return
  end
  local Music = require("src.core.Music")
  self.musicKind = self:computeMusicKind()
  -- normally already playing: the transition wipe starts the theme
  -- (audio/play_battle_music.asm runs before the transition, and
  -- Music.play no-ops on the same song); this covers battles pushed
  -- without a transition (link battles, scripted pushes)
  Music.playBattle(self.data, self.musicKind)
  -- intro presentation (SlidePlayerAndEnemySilhouettesOnScreen): both
  -- sides slide in; the trainer pics stay up until the send-outs
  self.introSlide = 40
  self.showEnemyTrainer = self.kind == "trainer" and self.trainerPic ~= nil
  -- SGB: the player-side battle palette while the back pic is up is
  -- MonsterPalettes[0] = PAL_MEWMON (wBattleMonSpecies is still 0 when
  -- the intro's SET_PAL_BATTLE runs -- SetPal_Battle,
  -- engine/gfx/palettes.asm:28)
  self.playerBackPic = getImage(self.demo
    and "assets/generated/battle/oldmanb.png"
    or "assets/generated/battle/redb.png",
    namedPalette(self.data, "MEWMON"))
  self.showPlayerBack = self.playerBackPic ~= nil
  self:say(self.introText)
  if self.kind == "trainer" then
    self:say(("%s sent\nout %s!"):format(self.trainer.name, self.enemy.name))
    self:act(function()
      -- EnemySendOutFirstMon (core.asm:1421-1434): after the text the
      -- pic grows out of the ball (AnimateSendingOutMon), then the cry
      self.showEnemyTrainer = false
      self:startGrowIn(self.enemy)
    end)
  end
  if not self.ghost then
    -- the enemy's cry plays as it appears (data/pokemon/cries.asm)
    self:act(function()
      require("src.core.Sound").playCry(self.data, self.enemy.mon.species)
    end)
  end
  if not self.safari and not self.demo then
    self:say(self:sendOutText(self.player.name))
    -- Red's pic clears, the POOF plays, then the mon appears with its
    -- cry (SendOutMon: message -> AnimateSendingOutMon -> PlayCry)
    self:act(function()
      self.showPlayerBack = false
      self.sendingOut = true
    end)
    table.insert(self.queue, { anim = "POOF_ANIM", attackerIsPlayer = false })
    self:act(function()
      self.sendingOut = false
      -- SendOutMon (core.asm:1757-1762): after the poof the mon grows
      -- out of the ball (AnimateSendingOutMon at hlcoord 4,11)
      self:startGrowIn(self.player)
      require("src.core.Sound").playCry(self.data, self.player.mon.species)
    end)
    self:markParticipant()
  end
  self.phase = "messages"
  self.afterQueue = "menu"
end

-- any pop (finish, script teardown) must silence the alarm loop
-- (end_of_battle.asm clears wLowHealthAlarm when a battle ends)
function BattleState:exit()
  require("src.core.Sound").stopLoop("Low_Health_Alarm")
end

-- An action the battler is locked into (bypasses the menu), or nil.
function BattleState:lockedAction(battler)
  if battler.mustRecharge then return { special = "recharge" } end
  if battler.charging then return battler.charging end
  if battler.thrashTurns and battler.thrashTurns > 0 then return battler.thrashMove end
  if battler.trappingTurns and battler.trappingTurns > 0 then
    return { special = "trapping" }
  end
  if battler.bideTurns then return { special = "bide" } end
  if battler.rageMove then return battler.rageMove end
  -- held in place while the OPPONENT's trapping move is running
  -- (core.asm:316-322 reads the live USING_TRAPPING_MOVE bit, so a
  -- trap ended early by paralysis/faint frees the victim immediately);
  -- boundTurns is a mirror kept for Status.beforeMove's held check
  local opp = battler.isPlayer and self.enemy or self.player
  battler.boundTurns = opp and opp.trappingTurns
                       and math.max(1, opp.trappingTurns) or nil
  if battler.boundTurns then
    return { special = "bound" }
  end
  return nil
end

function BattleState:playerHasPP()
  for i, mv in ipairs(self.player.curMoves) do
    if mv.pp > 0 and self.player.disabledSlot ~= i then return true end
  end
  return false
end

function BattleState:update(dt)
  self.frame = self.frame + 1
  self:updateFx()
  local input = self.game.input

  -- safety net: HP changed outside a queued drain (level-up heals,
  -- field effects) snaps once the queue is idle
  if self.phase == "menu" then
    for _, b in ipairs({ self.player, self.enemy }) do
      if b and b.shownHP then b.shownHP = b.mon.hp end
    end
  end

  if self.phase == "messages" then
    if not self:updateQueue() then
      if self.afterQueue == "menu" then
        self.phase = "menu"
      elseif self.afterQueue == "finish" then
        self:finish()
      end
    end
    return
  end

  if self.phase == "menu" and self.demo then
    -- DisplayBattleMenu's old-man branch (core.asm:2018-2050): input is
    -- never read.  The player name is swapped to OLD MAN, then the
    -- keystrokes are simulated on screen -- the '▶' cursor sits next to
    -- FIGHT (9,14) for 80 frames, hops down to ITEM (9,16) for 50, goes
    -- hollow ('▷') and the ITEM menu is forced (a = $2 ->
    -- .upperLeftMenuItemWasNotSelected).  The old man never attacks;
    -- backing out of the ball menu re-enters DisplayBattleMenu, which
    -- replays the whole script.
    self.demoTimer = (self.demoTimer or 0) + 1
    if self.demoTimer > 130 then
      self.demoTimer = nil
      self:openOldManBag()
    end
    return
  end

  if self.phase == "menu" and self.safari then
    if self.safari.balls <= 0 then
      self:say("PA: You're out of\nSAFARI BALLs!\nGame over!")
      self.phase = "messages"
      self.result = "run"
      self.afterQueue = "finish"
      return
    end
    local col = (self.menuIndex - 1) % 2
    local row = math.floor((self.menuIndex - 1) / 2)
    if input:wasPressed("left") or input:wasPressed("right") then
      col = 1 - col
    elseif input:wasPressed("up") or input:wasPressed("down") then
      row = 1 - row
    end
    self.menuIndex = row * 2 + col + 1
    if input:wasPressed("a") then
      self:safariAction(({ "ball", "bait", "rock", "run" })[self.menuIndex])
    end
    return
  end

  if self.phase == "menu" then
    -- forced replacement after a faint: ChooseNextMon (core.asm:1086)
    -- loops the party menu until a healthy mon is picked, so B and
    -- fainted picks land back here and reopen it
    if self.player.mon.hp <= 0 then
      if Party.firstHealthy(self.game.save.party) then
        self:openReplacementMenu()
      end
      return
    end
    -- core.asm:297-300: both sides' FLINCHED bits are cleared during
    -- move selection, but the clear is skipped while the player must
    -- recharge or is locked into Rage (core.asm:293-295 -- the Hyper
    -- Beam flinch-recharge glitch)
    if not (self.player.mustRecharge or self.player.rageMove) then
      self.player.flinched, self.enemy.flinched = false, false
    end
    -- locked multi-turn actions skip the menu entirely
    local locked = self:lockedAction(self.player)
    if locked then
      self:resolveTurn(locked)
      return
    end
    local col = (self.menuIndex - 1) % 2
    local row = math.floor((self.menuIndex - 1) / 2)
    if input:wasPressed("left") or input:wasPressed("right") then
      col = 1 - col
    elseif input:wasPressed("up") or input:wasPressed("down") then
      row = 1 - row
    end
    self.menuIndex = row * 2 + col + 1
    if input:wasPressed("a") then
      local choice = ({ "fight", "pkmn", "item", "run" })[self.menuIndex]
      if choice == "fight" and self.ghost then
        self:say(("%s is too\nscared to move!"):format(self.player.name))
        self.phase = "messages"
        self.afterQueue = "menu"
        self:act(function()
          self:executeAction(self.enemy, self.player, self:enemyAction())
        end)
        self:act(function() self:endOfTurn() end)
      elseif choice == "fight" then
        if not self:playerHasPP() then
          -- _NoMovesLeftText, then Struggle engages
          self:say(("%s has no\nmoves left!"):format(self.player.name))
          self:resolveTurn({ id = "STRUGGLE", pp = 1, struggle = true })
          return
        end
        self.phase = "moveSelect"
        self.moveIndex = math.min(self.moveIndex, #self.player.curMoves)
      elseif choice == "run" then
        self:tryRun()
      elseif choice == "item" then
        self:openItems()
      else
        self:openParty()
      end
    end
    return
  end

  if self.phase == "moveSelect" then
    local moves = self.player.curMoves
    if input:wasPressed("up") then
      self.moveIndex = self.moveIndex > 1 and self.moveIndex - 1 or #moves
    elseif input:wasPressed("down") then
      self.moveIndex = self.moveIndex < #moves and self.moveIndex + 1 or 1
    elseif input:wasPressed("b") then
      self.phase = "menu"
    elseif input:wasPressed("a") then
      local mv = moves[self.moveIndex]
      if self.player.disabledSlot == self.moveIndex then
        self:say("The move is\ndisabled!")
        self.phase = "messages"
        self.afterQueue = "menu"
      elseif mv.pp <= 0 then
        self:say("No PP left for\nthis move!")
        self.phase = "messages"
        self.afterQueue = "menu"
      else
        self:resolveTurn(mv)
      end
    end
    return
  end

  -- Mimic's mid-move copy menu (MimicEffect .letPlayerChooseMove,
  -- effects.asm:1243-1260): opened by the queue AFTER the hit test
  -- passes.  MoveSelectionMenu's mimic type watches only UP/DOWN/A
  -- (core.asm:2553-2557), so there is no backing out with B.
  if self.phase == "mimicSelect" then
    local moves = self.mimicMoves
    if input:wasPressed("up") then
      self.mimicIndex = self.mimicIndex > 1 and self.mimicIndex - 1 or #moves
    elseif input:wasPressed("down") then
      self.mimicIndex = self.mimicIndex < #moves and self.mimicIndex + 1 or 1
    elseif input:wasPressed("a") then
      local pick = moves[self.mimicIndex]
      local ctx = self.mimicCtx
      self.mimicMoves, self.mimicCtx = nil, nil
      self.phase = "messages"
      self.nextInsert = 0 -- the copy's anim + text go to the queue head
      self:applyMimic(ctx.user, ctx.target, ctx.moveInst, pick.slot)
    end
    return
  end
end

-- MimicEffect (engine/battle/effects.asm:1203-1273) runs MID-move: a
-- 50-frame beat, MoveHitTest, and only on a hit does the player's copy
-- menu open (.letPlayerChooseMove).  The enemy's Mimic -- and either
-- side of a link battle -- copies a RANDOM non-empty slot instead
-- (.getRandomMove).  Both failure paths (accuracy roll, mid-Fly/Dig
-- target) print PrintButItFailedText_ and skip the move animation.
function BattleState:resolveMimic(user, target, move, moveInst)
  -- ld c, 50 / call DelayFrames before anything happens
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { wait = 50 })
  if target.invulnerable
     or not Damage.accuracyRoll(self.ruleset, move, user, target, self.rng) then
    self:sayNext("But, it failed!")
    return
  end
  local slots = {}
  for i, m in ipairs(target.curMoves) do
    if m.id and m.pp ~= nil then slots[#slots + 1] = i end
  end
  if #slots == 0 then
    -- .getRandomMove rerolls empty slots forever; a moveless target
    -- can't happen in practice, so just fail instead of hanging
    self:sayNext("But, it failed!")
    return
  end
  if user.isPlayer and self.kind ~= "link" then
    if self.mimicChoice then -- test-injection hook for the player pick
      local slot = self:mimicChoice(target)
      if slot and target.curMoves[slot] and target.curMoves[slot].pp ~= nil then
        self:applyMimic(user, target, moveInst, slot)
        return
      end
    end
    -- pause the queue on a chooser row; the mimicSelect phase applies
    -- the pick and resumes
    self.nextInsert = self.nextInsert + 1
    table.insert(self.queue, self.nextInsert, {
      mimicSelect = { user = user, target = target, moveInst = moveInst },
    })
    return
  end
  self:applyMimic(user, target, moveInst, slots[self.rng(1, #slots)])
end

-- The copied move OVERWRITES the used slot's move id in place; the PP
-- byte is untouched (only wBattleMonMoves is written, effects.asm:
-- 1261-1266), so the copy inherits Mimic's remaining PP and keeps
-- draining that same slot (DecrementPP hits both the battle copy and
-- the party struct).  curMoves aliases mon.moves, so the original id is
-- remembered and restored when the battler leaves play -- pokered never
-- writes the party copy, and the battle copy is rebuilt from it on a
-- switch or at battle end.  Then PlayCurrentMoveAnimation and
-- _MimicLearnedMoveText.
function BattleState:applyMimic(user, target, moveInst, slot)
  local src = target.curMoves[slot]
  if not (src and src.id) then return end
  local mySlot
  for i, m in ipairs(user.curMoves) do
    if m == moveInst then mySlot = i break end
  end
  if not mySlot then
    -- a called Mimic (Metronome) isn't in the list.  For the player,
    -- non-link case, MimicEffect snapshots wCurrentMenuItem BEFORE the
    -- copy-picker menu opens and restores it afterward as the write
    -- index (effects.asm:1247, 1256/1261) -- it reuses whatever slot
    -- was left highlighted by the FIGHT menu.  That's provably always
    -- the calling move's own slot (e.g. METRONOME's): selecting a move
    -- syncs wCurrentMenuItem and wPlayerMoveListIndex together
    -- (core.asm's SelectMenuItem), and nothing touches either before
    -- the effect runs.  self.moveIndex mirrors this exactly -- it's
    -- frozen at the FIGHT-menu confirm and untouched through mid-move
    -- resolution -- so it already equals the calling move's slot here;
    -- there's no separate "reused index" to chase.  (Enemy/link Mimic
    -- instead reads w*MoveListIndex directly, effects.asm:1235-1241.)
    mySlot = user.isPlayer and math.min(self.moveIndex or 1, #user.curMoves) or 1
  end
  local entry = user.curMoves[mySlot]
  self.mimicRestores = self.mimicRestores or {}
  table.insert(self.mimicRestores, { battler = user, entry = entry, id = entry.id })
  entry.id = src.id
  entry.mimic = true
  self:animNext("MIMIC", user.isPlayer)
  -- _MimicLearnedMoveText: "<USER> / learned / MOVE!"
  self:sayNext(("%s\nlearned\n%s!"):format(displayName(user),
                                           self.data.moves[src.id].name))
end

-- Undo Mimic's in-place id overwrite for a battler leaving play (the GB
-- battle copy is discarded; the party struct never changed).
function BattleState:restoreMimicked(battler)
  if not self.mimicRestores then return end
  local keep = {}
  -- iterate newest-first so the oldest snapshot (the true pre-Mimic
  -- move id, from before any repeated Mimic-on-Mimic via Metronome)
  -- is applied last and wins, instead of a stale intermediate id
  for i = #self.mimicRestores, 1, -1 do
    local r = self.mimicRestores[i]
    if r.battler == battler then
      r.entry.id, r.entry.mimic = r.id, nil
    else
      keep[#keep + 1] = r
    end
  end
  self.mimicRestores = #keep > 0 and keep or nil
end

-- BagWasSelected's old-man fork (core.asm:2193-2210): the list menu is
-- fed OldManItemList -- one POKé BALL x50 -- instead of the player's
-- bag.  The list is as scripted as the battle menu (DisplayListMenuID's
-- old-man branch, home/list_menu.asm:65-80): no input is ever read --
-- backing out is impossible -- the '▶' sits in front of POKé BALL for
-- 80 frames, then A is auto-pressed and .buttonAPressed's
-- PlaceUnfilledArrowMenuCursor leaves the hollow '▷' on the row for the
-- handful of frames UseBagItem takes to reach ItemUseBall's screen
-- restore (item_effects.asm:145) and the throw text.
function BattleState:openOldManBag()
  local ListMenu = require("src.ui.ListMenu")
  local game = self.game
  self.phase = "messages"
  self.afterQueue = "menu"
  self:ui(function()
    local list
    list = ListMenu.new(game, "ITEMS", {
      { value = "POKE_BALL", label = "POKé BALL", right = "x50" },
    }, {
      script = function(l)
        l.scriptTimer = (l.scriptTimer or 0) + 1
        if l.scriptTimer == 81 then
          -- the auto A-press: the cursor goes hollow on the chosen row
          l.hollowIndex = l.index
        elseif l.scriptTimer > 88 then
          -- ItemUseBall takes over: list down, OLD MAN throws
          l:close()
          self:oldManThrow()
        end
      end,
    })
    return list
  end)
end

-- ItemUseBall for BATTLE_TYPE_OLD_MAN: the party/box-full checks are
-- skipped (item_effects.asm:114-118), every capture calculation is
-- skipped -- the old man branch jumps straight to .captured, $43 anim
-- data = 3 shakes and caught (:155-164 + :193-200) -- and
-- .oldManCaughtMon prints the caught text WITHOUT adding the mon to
-- the party or the dex (:568-570).  The "used" line reads OLD MAN
-- because DisplayBattleMenu swapped wPlayerName (core.asm:2024-2037);
-- no ball is consumed (.done returns early, :576-578).
function BattleState:oldManThrow()
  self.phase = "messages"
  self.afterQueue = "finish"
  self.result = "run" -- nothing is kept; wBattleResult only ends the demo
  self:say("OLD MAN used\nPOKé BALL!")
  self:act(function()
    require("src.core.Sound").play(self.data, "Ball_Toss")
    -- ItemUseBall's beat before the toss chain (like throwBall)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { wait = 20 })
    self:ballChain("TOSS_ANIM", true, 3, "POKE_BALL")
    self:actNext(function()
      require("src.core.Sound").play(self.data, "Caught_Mon")
    end)
    self:sayNext(("All right!\n%s was\ncaught!"):format(self.enemy.name))
  end)
end

-- ---------------------------------------------------------------------
-- turn resolution
-- ---------------------------------------------------------------------

function BattleState:moveDef(moveInst)
  return self.data.moves[moveInst.id]
end

-- wAICount: item/switch uses per enemy Pokémon for this trainer class
function BattleState:aiUsesFor()
  if self.kind ~= "trainer" or not self.trainer then return 0 end
  local class = require("data.scripts.ai_classes")[self.trainer.id]
  return class and class.uses or 0
end

-- Exp participants: every player mon that has been in against the
-- current enemy mon (wPartyGainExpFlags).
function BattleState:markParticipant()
  self.participants = self.participants or {}
  if self.player and self.player.mon then
    self.participants[self.player.mon] = true
  end
end

function BattleState:enemyAction()
  local locked = self:lockedAction(self.enemy)
  if locked then return locked end
  -- class AI may spend the turn on an item or a switch
  local classAct = TrainerAI.classAction(self)
  if classAct then return classAct end
  return TrainerAI.chooseMove(self.enemy, self.rng, self)
end

local function orderMove(action, data)
  if action and action.id then return data.moves[action.id] end
  return nil
end

function BattleState:resolveTurn(playerAction)
  local enemyAction = self:enemyAction()
  local pFirst = TurnOrder.firstMover(self.player, orderMove(playerAction, self.data),
                                      self.enemy, orderMove(enemyAction, self.data),
                                      self.rng)
  local order
  if pFirst then
    order = { { self.player, self.enemy, playerAction },
              { self.enemy, self.player, enemyAction } }
  else
    order = { { self.enemy, self.player, enemyAction },
              { self.player, self.enemy, playerAction } }
  end

  self.phase = "messages"
  self.afterQueue = "menu"
  self.turnCount = (self.turnCount or 0) + 1

  for _, entry in ipairs(order) do
    self:act(function()
      self:executeAction(entry[1], entry[2], entry[3])
    end)
  end
  self:act(function() self:endOfTurn() end)
end

-- A switch action: replace the player's mon, enemy gets a free move.
function BattleState:resolveSwitch(newMon)
  self.phase = "messages"
  self.afterQueue = "menu"
  self:act(function()
    self:restoreMimicked(self.player) -- the battle copy leaves with it
    self.player = makeBattler(self.data, newMon, true, self.game.save)
    self:markParticipant()
    self.sendingOut = true
    self:sayNext(self:sendOutText(self.player.name))
    self:animNext("POOF_ANIM", false)
    self:actNext(function()
      self.sendingOut = false
      -- SendOutMon (core.asm:1757-1762): poof, then the grow-in
      self:startGrowIn(self.player)
      require("src.core.Sound").playCry(self.data, self.player.mon.species)
    end)
  end)
  self:act(function()
    self:executeAction(self.enemy, self.player, self:enemyAction())
  end)
  self:act(function() self:endOfTurn() end)
end

function BattleState:endOfTurn()
  -- sideToxic mirrors w*ToxicCounter: it advances only while the
  -- battler's badly-poisoned flag (toxicCounter) is set, an item/AI
  -- cure clears the flag but NOT the side counter, and a fresh Toxic
  -- re-seeds it (effects.asm:137-139 zeroes the counter when setting
  -- BADLY_POISONED).  It is never copied back onto a battler: pokered
  -- reads the counter only while the flag is set, and the only code
  -- that sets the flag also zeroes the counter, so a stale value is
  -- unobservable (a switch or cure downgrades Toxic to plain poison).
  self.sideToxic = self.sideToxic or {}
  for _, pair in ipairs({ { self.player, self.enemy, "player" },
                          { self.enemy, self.player, "enemy" } }) do
    local b, opp, side = pair[1], pair[2], pair[3]
    if b.mon.hp > 0 then
      local msgs = Status.residual(b, opp)
      for _, m in ipairs(msgs) do self:sayNext(prefixEnemy(m, b)) end
      if #msgs > 0 then self:drainNext() end -- poison/burn/seed HP moved
      if b.toxicCounter then
        self.sideToxic[side] = b.toxicCounter
      end
      if b.mon.hp <= 0 then
        self:onFaint(b)
      end
    end
    -- CheckNumAttacksLeft (core.asm:683-697): a trapping counter that
    -- hit 0 this turn releases its bit only now, at the end of the turn
    if b.trappingTurns and b.trappingTurns <= 0 then
      b.trappingTurns = nil
    end
  end
end

-- ---------------------------------------------------------------------
-- battle animation layer
-- ---------------------------------------------------------------------
--
-- An approximation of the original's subanimation bytecode engine
-- (docs/known-differences.md): the move's real sound (data/moves/sfx.asm
-- via each move's anim table), screen shake / flash for moves whose
-- animation data uses SE_SHAKE_SCREEN / screen-flash effects, target
-- blink on damage, and a faint slide with the cry.  The Poké Ball toss
-- chain (toss/poof/hide/shake/show) rides the queue as anim rows.

-- the OPTIONS animation toggle (sounds always play)
function BattleState:animationsOn()
  local o = self.game.save.options
  return not o or o.animations ~= false
end

-- ------------------------------------------------------------------
-- special-effect (SE_*) implementations.  Palette effects are BGP
-- shade maps ({[i] = shade color index i displays as}); on the SGB the
-- colorizer colors the REMAPPED shade, so the zone palettes are
-- permuted through the active map (engine/battle/animations.asm
-- SetAnimationBGPalette / AnimationFlashScreen / ...ScreenLong).
-- ------------------------------------------------------------------

local BGP_IDENTITY = { [0] = 0, 1, 2, 3 }              -- $e4
local BGP_INVERT   = { [0] = 3, 2, 1, 0 }              -- $1b (flash phase 1)
local BGP_WHITE    = { [0] = 0, 0, 0, 0 }              -- $00 (flash phase 2)
local BGP_DARK     = { [0] = 3, 3, 2, 1 }              -- $6f DarkScreenPalette
local BGP_LIGHT    = { [0] = 0, 0, 1, 2 }              -- $90 LightScreenPalette
local BGP_DARKEN   = { [0] = 0, 1, 3, 3 }              -- $f4 DarkenMonPalette (SGB)

-- FlashScreenLongSGB (animations.asm:1010): 12 BGP values per cycle,
-- 3 cycles; the first cycle holds each for 2 frames, the rest for 1
-- (FlashScreenLongDelay)
local FLASH_LONG_MAPS = {
  { [0] = 0, 2, 3, 3 }, { [0] = 0, 3, 3, 3 }, { [0] = 3, 3, 3, 3 },
  { [0] = 0, 3, 3, 3 }, { [0] = 0, 2, 3, 3 }, { [0] = 0, 1, 2, 3 },
  { [0] = 0, 0, 1, 2 }, { [0] = 0, 0, 0, 1 }, { [0] = 0, 0, 0, 0 },
  { [0] = 0, 0, 0, 1 }, { [0] = 0, 0, 1, 2 }, { [0] = 0, 1, 2, 3 },
}

-- the shade map in force this frame (a running flash wins over the
-- persistent palette)
function BattleState:activeBgp()
  local fx = self.fx
  if not fx then return nil end
  local seq = fx.bgpSeq
  if seq then
    local st = seq.steps[seq.idx]
    if st then return st.map end
  end
  return fx.bgp
end

-- per-battler pic effect state (offsets/hides driven by the SE rows)
function BattleState:picFxFor(battler)
  if not battler then return nil end
  self.picFx = self.picFx or {}
  local pf = self.picFx[battler]
  if not pf then
    pf = { ox = 0, oy = 0 }
    self.picFx[battler] = pf
  end
  return pf
end

-- transient pic effects reset when a new animation row starts (each
-- PlayAnimation redraws from a clean slate); `minimized` survives --
-- the minimize sprite replaces the pic DATA, so redraws keep it until
-- the pic is reloaded (switch/Transform/ChangeMonPic)
function BattleState:resetPicFx()
  if not self.picFx then return end
  for _, pf in pairs(self.picFx) do
    pf.kind, pf.t = nil, nil
    pf.ox, pf.oy = 0, 0
    pf.hidden = nil
  end
end

-- the battler an SE row's routine acts on: "the mon" is the attacker's
-- side; the SE_*_ENEMY_* variants run through CallWithTurnFlipped
function BattleState:animFxBattler(flipped)
  local isPlayer = self.animAttackerIsPlayer
  if flipped then isPlayer = not isPlayer end
  return isPlayer and self.player or self.enemy
end

-- a row's sound byte is a move id: GetMoveSound plays its
-- MoveSoundTable sfx with the pitch/tempo modifier bytes; for the
-- GROWL/ROAR animations (IsCryMove) it plays the attacker's cry, with
-- the move's own pitch/tempo bytes (from its own row, soundMove ==
-- self.animName for these) layered on as the extra shift
function BattleState:playAnimSound(soundMove)
  local Sound = require("src.core.Sound")
  local mdef = self.data.moves[soundMove]
  if self.animName == "GROWL" or self.animName == "ROAR" then
    local attacker = self:animFxBattler(false)
    if attacker then
      Sound.playMoveCry(self.data, attacker.mon.species,
                         mdef and mdef.anim and mdef.anim.tempo)
    end
    return
  end
  if mdef and mdef.anim then
    if Sound.playMove then
      Sound.playMove(self.data, mdef.anim)
    else
      Sound.play(self.data, mdef.anim.sound)
    end
  end
end

local function startPicKind(pf, kind)
  if not pf then return end
  pf.kind, pf.t = kind, 0
  pf.hidden = nil
end

-- Route one AnimPlayer event into the fx layer.  Frame counts and
-- amplitudes are the routines' own (engine/battle/animations.asm;
-- shakes: engine/gfx/screen_effects.asm).
function BattleState:applyAnimEffect(ev)
  self.fx = self.fx or {}
  local fx = self.fx
  if ev.sound then
    self:playAnimSound(ev.sound)
  end
  local e = ev.effect
  if not e then return end

  if e == "SFX_TINK" then
    -- each ball shake opens with a tink (DoBallShakeSpecialEffects)
    require("src.core.Sound").play(self.data, "Tink")

  -- ---------------------------------------------- palette effects
  elseif e == "SE_DARK_SCREEN_PALETTE" then
    fx.bgp = BGP_DARK
  elseif e == "SE_LIGHT_SCREEN_PALETTE" then
    fx.bgp = BGP_LIGHT
  elseif e == "SE_DARKEN_MON_PALETTE" then
    fx.bgp = BGP_DARKEN
  elseif e == "SE_RESET_SCREEN_PALETTE" then
    fx.bgp = nil
  elseif e == "SE_DARK_SCREEN_FLASH" then
    -- AnimationFlashScreen: 2 frames inverted, 2 frames white, restore
    fx.bgpSeq = { steps = { { map = BGP_INVERT, frames = 2 },
                            { map = BGP_WHITE, frames = 2 } },
                  idx = 1, left = 2 }
  elseif e == "SE_FLASH_SCREEN_LONG" then
    local steps = {}
    for cycle = 1, 3 do
      for _, m in ipairs(FLASH_LONG_MAPS) do
        steps[#steps + 1] = { map = m, frames = (cycle == 1) and 2 or 1 }
      end
    end
    fx.bgpSeq = { steps = steps, idx = 1, left = steps[1].frames }

  -- ---------------------------------------------- screen shakes
  elseif e == "SE_SHAKE_SCREEN" then
    -- PredefShakeScreenHorizontally b=8: the window jumps right by b
    -- for 5 frames then home for 4, b counting down 8..1
    local prog = {}
    for b = 8, 1, -1 do
      prog[#prog + 1] = { dx = b, frames = 5 }
      prog[#prog + 1] = { dx = 0, frames = 4 }
    end
    fx.shakeProg = prog
  elseif e == "SE_ROCK_SLIDE_SHAKE" then
    -- DoRockSlideSpecialEffects: 1px horizontal then vertical rumble
    fx.shakeProg = { { dx = 1, frames = 5 }, { dx = 0, frames = 4 },
                     { dy = 1, frames = 3 }, { dy = 0, frames = 3 } }
  elseif e == "SE_SHAKE_ENEMY_HUD" then
    -- AnimationShakeEnemyHUD: SCX +-2 for 2 frames each, 8 times; the
    -- window + a sprite copy of the back pic keep everything below the
    -- enemy HUD still, so only the HUD area moves
    local prog = {}
    for _ = 1, 8 do
      prog[#prog + 1] = { dx = 2, frames = 2 }
      prog[#prog + 1] = { dx = -2, frames = 2 }
    end
    fx.hudShakeProg = prog
  elseif e == "SE_WAVY_SCREEN" then
    -- AnimationWavyScreen: 255 frames of per-scanline SCX offsets
    -- walking WavyScreenLineOffsets
    fx.wavy = { left = 255, phase = 0 }

  -- ---------------------------------------------- mon pic effects
  elseif e == "SE_SLIDE_MON_OFF" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "slideOff")
  elseif e == "SE_SLIDE_ENEMY_MON_OFF" then
    startPicKind(self:picFxFor(self:animFxBattler(true)), "slideOff")
  elseif e == "SE_SLIDE_MON_HALF_OFF" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "slideHalf")
  elseif e == "SE_SLIDE_MON_UP" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "slideUp")
  elseif e == "SE_SLIDE_MON_DOWN" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "slideDown")
  elseif e == "SE_SLIDE_MON_DOWN_AND_HIDE" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "slideDownHide")
  elseif e == "SE_SHAKE_BACK_AND_FORTH" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "shakeBF")
  elseif e == "SE_BOUNCE_UP_AND_DOWN" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "bounce")
  elseif e == "SE_SQUISH_MON_PIC" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "squish")
  elseif e == "SE_BLINK_MON" then
    startPicKind(self:picFxFor(self:animFxBattler(false)), "blink")
  elseif e == "SE_BLINK_ENEMY_MON" then
    startPicKind(self:picFxFor(self:animFxBattler(true)), "blink")
  elseif e == "SE_MOVE_MON_HORIZONTALLY" then
    -- redraw one tile inward: player pic at hlcoord 2,5 (from 1,5),
    -- enemy pic at 11,0 (from 12,0)
    local b = self:animFxBattler(false)
    local pf = self:picFxFor(b)
    if pf then
      pf.kind, pf.hidden = nil, nil
      pf.ox = b.isPlayer and 8 or -8
      pf.oy = 0
    end
  elseif e == "SE_RESET_MON_POSITION" then
    local pf = self:picFxFor(self:animFxBattler(false))
    if pf then
      pf.kind, pf.hidden, pf.ox, pf.oy = nil, nil, 0, 0
    end
  elseif e == "SE_SHOW_MON_PIC" then
    local pf = self:picFxFor(self:animFxBattler(false))
    if pf then pf.kind, pf.hidden, pf.ox, pf.oy = nil, nil, 0, 0 end
  elseif e == "SE_SHOW_ENEMY_MON_PIC" then
    local pf = self:picFxFor(self:animFxBattler(true))
    if pf then pf.kind, pf.hidden, pf.ox, pf.oy = nil, nil, 0, 0 end
  elseif e == "SE_HIDE_MON_PIC" or e == "SE_HIDE_ATTACKER_PIC" then
    local pf = self:picFxFor(self:animFxBattler(false))
    if pf then pf.kind, pf.hidden = nil, true end
  elseif e == "SE_HIDE_ENEMY_MON_PIC" then
    local pf = self:picFxFor(self:animFxBattler(true))
    if pf then pf.kind, pf.hidden = nil, true end
  elseif e == "SE_MINIMIZE_MON" then
    -- the pic data is replaced by the tiny MinimizedMonSprite blob
    local pf = self:picFxFor(self:animFxBattler(false))
    if pf then
      pf.kind, pf.hidden = nil, nil
      pf.minimized = true
    end
  elseif e == "SE_FLASH_MON_PIC" or e == "SE_FLASH_ENEMY_MON_PIC" then
    -- ChangeMonPic reloads the mon's own pic (clears a minimize)
    local pf = self:picFxFor(self:animFxBattler(e == "SE_FLASH_ENEMY_MON_PIC"))
    if pf then pf.kind, pf.hidden, pf.minimized = nil, nil, nil end
  elseif e == "SE_TRANSFORM_MON" then
    -- AnimationTransformMon redraws the user as the opposing species
    -- (MoveEffects.TRANSFORM_EFFECT swaps the rest when it applies)
    local user = self:animFxBattler(false)
    local target = self:animFxBattler(true)
    if user and target and self.speciesSprite then
      user.sprite = self:speciesSprite(target.mon.species, user.isPlayer)
                    or user.sprite
      local pf = self:picFxFor(user)
      if pf then pf.minimized = nil end
    end
  end
  -- SE_SUBSTITUTE_MON needs no visual here: the doll is drawn while
  -- battler.substituteHP is set (MoveEffects raises it with the move)
end

-- The target's post-animation hit feedback (PlayApplyingAttackAnimation,
-- engine/battle/animations.asm:475): the player's damaging moves blink
-- the ENEMY pic; the enemy's damaging moves shake the screen vertically
-- (ShakeScreenVertically -> PredefShakeScreenVertically b=8: the window
-- drops by b for 3 frames then home for 3, b counting down) -- the
-- player's pic never blinks.  Damage sound with either.  A hold keeps
-- the queue still until the effect finishes.
function BattleState:applyHitFx(hit)
  if hit.blink then
    self.fx = self.fx or {}
    if hit.blink.isPlayer then
      local prog = {}
      for b = 8, 1, -1 do
        prog[#prog + 1] = { dy = b, frames = 3 }
        prog[#prog + 1] = { dy = 0, frames = 3 }
      end
      self.fx.shakeProg = prog
      self.waitFrames = 48 -- the predef blocks until the shake settles
    else
      self.fx.blink = { target = hit.blink, frames = 20 }
      self.waitFrames = 20
    end
  end
  if hit.sfx then
    require("src.core.Sound").play(self.data, hit.sfx)
  end
end

-- AnimateSendingOutMon (core.asm:6801-6838): the mon grows out of the
-- ball -- a 3-frame ball beat, 4 frames of the pic at 3/7 scale (a 3x3
-- block of its 7x7 tiles), 5 frames at 5/7 (5x5), then full size.
-- Queues a hold so the text stays up while it grows.  Runs inside a
-- queued fn (updateQueue resets nextInsert before each one).
function BattleState:startGrowIn(battler)
  self.growIn = { battler = battler, frame = 0 }
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { wait = 12 })
end

-- Should the low-health alarm sound this frame?  pokered keys it off
-- the drawn bar color: DrawPlayerHUDAndHPBar (core.asm:1846-1875) sets
-- wLowHealthAlarm bit 7 when GetHealthBarColor says the player bar is
-- red (< 10 of 48 pixels -- the same threshold HudTiles.drawHPBar
-- tints with) and clears it when the bar isn't red or the mon fainted
-- (RemoveFaintedPlayerMon).  Winning disables it for the rest of the
-- battle (EndLowHealthAlarm sets wLowHealthAlarmDisabled, mirrored by
-- playVictoryMusic) and every other outcome tears it down in
-- end_of_battle.asm -- self.result covers those.  The damage drain
-- gates the start (the HUD redraw runs after UpdateHPBar finishes),
-- but healing out of the red stops it at once (item_effects.asm clears
-- the alarm before the bar animates).  No alarm before the player HUD
-- first draws (send-out), nor in the safari/old-man battles, which
-- have no player mon HUD.
function BattleState:lowHealthAlarmActive()
  local p = self.player
  if not p or self.safari or self.demo or self.result
     or self.lowHealthAlarmDisabled then return false end
  if self.showPlayerBack or (self.introSlide or 0) > 0 then return false end
  local hp = p.mon.hp
  if hp <= 0 or p.fainted then return false end
  if p.shownHP and p.shownHP > hp then return false end -- drain running
  local px = math.max(1, math.floor(hp * 48 / math.max(1, p.mon.stats.hp)))
  return px < 10
end

-- advance a {dx/dy, frames} step program; returns the current step
local function stepProgram(prog)
  local head = prog[1]
  while head and head.frames <= 0 do
    table.remove(prog, 1)
    head = prog[1]
  end
  if head then head.frames = head.frames - 1 end
  return head
end

function BattleState:updateFx()
  if self.introSlide and self.introSlide > 0 then
    self.introSlide = self.introSlide - 1
  end
  local fx = self.fx
  if fx then
    if fx.shake and fx.shake > 0 then fx.shake = fx.shake - 1 end
    if fx.flash and fx.flash > 0 then fx.flash = fx.flash - 1 end
    if fx.blink and fx.blink.frames > 0 then
      fx.blink.frames = fx.blink.frames - 1
    end
    if fx.faint and fx.faint.frames > 0 then
      fx.faint.frames = fx.faint.frames - 1
    end
    -- SE-driven screen offsets (window/SCX shakes)
    fx.shakeX, fx.shakeY = 0, 0
    if fx.shakeProg then
      local st = stepProgram(fx.shakeProg)
      if st then
        fx.shakeX, fx.shakeY = st.dx or 0, st.dy or 0
      else
        fx.shakeProg = nil
      end
    end
    fx.hudShakeX = 0
    if fx.hudShakeProg then
      local st = stepProgram(fx.hudShakeProg)
      if st then
        fx.hudShakeX = st.dx or 0
      else
        fx.hudShakeProg = nil
      end
    end
    -- BGP flash sequences
    local seq = fx.bgpSeq
    if seq then
      seq.left = seq.left - 1
      if seq.left <= 0 then
        seq.idx = seq.idx + 1
        local st = seq.steps[seq.idx]
        if st then
          seq.left = st.frames
        else
          fx.bgpSeq = nil -- restore: activeBgp falls back to fx.bgp
        end
      end
    end
    if fx.wavy then
      fx.wavy.left = fx.wavy.left - 1
      fx.wavy.phase = fx.wavy.phase + 1
      if fx.wavy.left <= 0 then fx.wavy = nil end
    end
  end
  -- SE-driven pic effects: advance the per-battler programs and apply
  -- their end states (timings in the SE_* handlers' comments)
  if self.picFx then
    for b, pf in pairs(self.picFx) do
      if pf.kind then
        pf.t = (pf.t or 0) + 1
        local k, t = pf.kind, pf.t
        if k == "slideOff" and t >= 24 then
          pf.kind, pf.hidden = nil, true
        elseif k == "slideHalf" and t >= 19 then
          pf.kind = nil
          pf.ox = b.isPlayer and -32 or 32 -- the pic stays half off
        elseif k == "slideUp" and t >= 14 then
          pf.kind = nil -- a full cyclic wrap lands back on the pic
        elseif k == "slideDown" and t >= 21 then
          pf.kind, pf.hidden = nil, true
        elseif k == "slideDownHide" and t >= 19 then
          pf.kind, pf.hidden = nil, true
        elseif k == "shakeBF" and t >= 96 then
          pf.kind, pf.hidden = nil, true -- the loop ends on a cleared pic
        elseif k == "bounce" and t >= 105 then
          pf.kind = nil -- AnimationShowMonPic after the last bounce
        elseif k == "squish" and t >= 24 then
          pf.kind, pf.hidden = nil, true
        elseif k == "blink" and t >= 60 then
          pf.kind = nil -- ends shown
        end
      end
    end
  end
  -- the send-out grow-in (AnimateSendingOutMon): 3+4+5 frames, then
  -- the pic draws at full size again
  if self.growIn then
    self.growIn.frame = self.growIn.frame + 1
    if self.growIn.frame >= 12 then self.growIn = nil end
  end
  -- low-HP alarm (audio/low_health_alarm.asm): the two-tone siren
  -- loops while the player's bar is red; see lowHealthAlarmActive
  local Sound = require("src.core.Sound")
  if self:lowHealthAlarmActive() then
    Sound.startLoop(self.data, "Low_Health_Alarm")
  else
    Sound.stopLoop("Low_Health_Alarm")
  end
end

-- ---------------------------------------------------------------------
-- move execution pipeline
-- ---------------------------------------------------------------------

function BattleState:executeAction(user, target, action)
  if user.mon.hp <= 0 or target.mon.hp <= 0 then return end
  if not action then return end

  -- ghost battles: the ghost never attacks; its whole turn is the
  -- GetOutText (ExecuteEnemyMove -> PrintGhostText, core.asm:5462-5463)
  if self.ghost and not user.isPlayer then
    self:sayNext(self.data.text._GetOutText or "GHOST: Get out...\nGet out...")
    return
  end

  -- refresh the held-in-place mirror before the status checks (see
  -- lockedAction): the victim is held exactly while the opponent's
  -- trapping bit is set -- including a counter sitting at 0 until the
  -- end-of-turn CheckNumAttacksLeft clear
  user.boundTurns = target.trappingTurns
                    and math.max(1, target.trappingTurns) or nil

  -- trainer class AI actions (engine/battle/trainer_ai.asm)
  if action.special == "aiItem" then
    self.aiUses = (self.aiUses or 1) - 1
    for _, m in ipairs(TrainerAI.useItem(self, action.item)) do
      self:sayNext(prefixEnemy(m, self.enemy))
    end
    self:drainNext()
    require("src.core.Sound").play(self.data, "Heal_Ailment")
    return
  end
  if action.special == "aiSwitch" then
    self.aiUses = (self.aiUses or 1) - 1
    local oldName = self.enemy.name
    self.enemyIndex = action.index
    self.enemy = makeBattler(self.data, self.enemyParty[action.index], false)
    self.aiUses = self:aiUsesFor()
    markSeen(self.game, self.enemy.mon.species)
    -- _AIBattleWithdrawText: "X with-/drew Y!"
    self:sayNext(("%s with-\ndrew %s!"):format(self.trainer.name, oldName))
    self:sayNext(("%s sent\nout %s!"):format(self.trainer.name, self.enemy.name))
    return
  end

  -- special locked actions.  All of them still run the status gauntlet:
  -- CheckPlayerStatusConditions (core.asm:3328-3583) evaluates sleep ->
  -- freeze -> held-in-place -> flinch -> recharge -> disable tick ->
  -- confusion -> paralysis BEFORE the bide/thrash/trapping handling.
  if action.special == "recharge" then
    -- only reaching .HyperBeamCheck consumes the flag (core.asm:3384-
    -- 3392): sleep/freeze/held/flinch keep the mon recharging next turn
    if self:preRechargeChecks(user, target) then return end
    user.mustRecharge = nil
    self:sayNext(("%s\nmust recharge!"):format(displayName(user)))
    return
  end
  if action.special == "bound" then
    if not target.trappingTurns then
      -- the trap ended earlier this turn: the CANNOT_MOVE selection is
      -- simply lost (ExecutePlayerMove returns immediately on $ff)
      return
    end
    -- sleep/freeze take precedence over the held-in-place message
    if self:statusInterrupt(user, target) then return end
    return
  end
  if action.special == "trapping" then
    if self:statusInterrupt(user, target) then return end
    self:continueTrapping(user, target)
    return
  end
  if action.special == "bide" then
    if self:statusInterrupt(user, target) then return end
    self:continueBide(user, target)
    return
  end

  if self:statusInterrupt(user, target) then return end
  self:performMove(user, target, action, false)
end

-- The pre-recharge slice of CheckPlayerStatusConditions (core.asm:
-- 3328-3382): sleep -> freeze -> held-in-place -> flinch, each losing
-- the turn WITHOUT consuming the recharge flag.  The disable/confusion/
-- paralysis ticks come after the recharge consume in the asm, so they
-- must not run on a recharge turn.  Mirrors Status.beforeMove's early
-- checks (kept there for normal moves).
function BattleState:preRechargeChecks(user, target)
  if user.skipMove then -- Haze forfeit (selected move = CANNOT_MOVE)
    user.skipMove = nil
    return true
  end
  local mon = user.mon
  if mon.status == "SLP" then
    user.sleepTurns = (user.sleepTurns or 1) - 1
    if user.sleepTurns <= 0 then
      mon.status = nil
      self:sayNext(displayName(user) .. "\nwoke up!")
    else
      self:sayNext(displayName(user) .. "\nis fast asleep!")
    end
    return true
  end
  if mon.status == "FRZ" then
    self:sayNext(displayName(user) .. "\nis frozen solid!")
    return true
  end
  if target.trappingTurns then
    self:sayNext(displayName(user) .. "\ncan't move!")
    return true
  end
  if user.flinched then
    -- reachable: the turn-start flinch reset is skipped while the
    -- player recharges, so the flinch eats the recharge turn and the
    -- flag survives (the Hyper Beam flinch glitch)
    user.flinched = false
    self:sayNext(displayName(user) .. "\nflinched!")
    return true
  end
  return false
end

-- Runs Status.beforeMove plus the shared interruption bookkeeping;
-- returns true when the user's action is interrupted.
function BattleState:statusInterrupt(user, target)
  local canMove, msgs, selfHit = Status.beforeMove(user, self.rng)
  for _, m in ipairs(msgs) do self:sayNext(prefixEnemy(m, user)) end
  if selfHit then
    -- confusion self-hit (core.asm:3428-3434): clears everything in
    -- status1 except CONFUSED, then HandleSelfConfusionDamage deals a
    -- 40-power typeless hit against the mon's own defense -- with the
    -- OPPONENT's Reflect still applying (the screen check keeps
    -- reading the opponent's battle status)
    local dmg = Damage.compute(self.ruleset, user, user,
                               { id = "CONFUSED", power = 40, type = "NORMAL", accuracy = 100 },
                               { rng = self.rng, forceCrit = false, typeless = true,
                                 screens = target })
    self:sayNext("It hurt itself in\nits confusion!")
    self:clearVolatiles(user, true)
    self:applyDamage(user, dmg)
    if user.mon.hp <= 0 then self:onFaint(user) end
    return true
  end
  if not canMove then
    -- full paralysis (core.asm:3459-3464) clears bide/thrash/charge/
    -- trapping; sleep, freeze, flinch and held-in-place leave every
    -- volatile in place (a sleeping wrapper keeps its victim held)
    if user.mon.status == "PAR" and msgs[#msgs]
       and msgs[#msgs]:find("fully paralyzed", 1, true) then
      self:clearVolatiles(user, false)
    end
    return true
  end
  return false
end

-- The status1 volatile clears shared by full paralysis and the
-- confusion self-hit.  selfHit additionally clears INVULNERABLE and
-- FLINCHED (status1 &= CONFUSED); full paralysis does NOT touch
-- INVULNERABLE -- the famous Fly/Dig invulnerability glitch.
function BattleState:clearVolatiles(user, selfHit)
  user.bideTurns, user.bideDamage = nil, nil
  user.thrashTurns, user.thrashMove, user.thrashAnnounced = nil, nil, nil
  user.charging, user.chargeReady = nil, nil
  user.trappingTurns = nil -- the opponent is freed via the live mirror
  if selfHit then
    user.invulnerable = nil
    user.flinched = false
  end
end

-- performMove runs a move (possibly via Metronome/Mirror Move recursion).
function BattleState:performMove(user, target, moveInst, isCalled)
  local move = self:moveDef(moveInst)
  if not move then
    Logger.warn("unknown move instance %s", tostring(moveInst.id))
    return
  end

  -- charge release?
  local releasing = user.charging == moveInst and user.chargeReady
  if releasing then
    user.charging, user.chargeReady, user.invulnerable = nil, nil, nil
  end

  -- PP: not for continuations, struggle, or called moves
  local isContinuation = releasing
      or (user.thrashTurns and user.thrashTurns > 0 and moveInst == user.thrashMove)
      or moveInst == user.rageMove
  if not isContinuation and not moveInst.struggle and not isCalled then
    moveInst.pp = math.max(0, moveInst.pp - 1)
  end

  local effect = move.effect

  self.moveAnimRow = nil
  if not (user.thrashTurns and moveInst == user.thrashMove and user.thrashAnnounced) then
    self:sayNext(("%s\nused %s!"):format(displayName(user), move.name))
    -- the move's animation plays right after the announcement; the
    -- damage path attaches the target's hit blink to this row so the
    -- blink follows the animation (pokered's order).  Mimic is the
    -- exception: PlayCurrentMoveAnimation runs only after a successful
    -- copy (effects.asm:1268), never on a miss -- applyMimic queues it
    if effect ~= "MIMIC_EFFECT" then
      self.nextInsert = (self.nextInsert or 0) + 1
      self.moveAnimRow = { anim = move.id, attackerIsPlayer = user.isPlayer }
      table.insert(self.queue, self.nextInsert, self.moveAnimRow)
    end
  end

  -- Metronome / Mirror Move
  if effect == "METRONOME_EFFECT" then
    local order = self.data.constants.moveOrder
    local pick
    repeat
      pick = order[self.rng(1, #order)]
    until pick ~= "METRONOME" and pick ~= "STRUGGLE" and self.data.moves[pick]
    self:performMove(user, target, { id = pick, pp = 1 }, true)
    return
  end
  if effect == "MIRROR_MOVE_EFFECT" then
    local last = target.lastMove
    if not last then
      self:sayNext("The MIRROR MOVE\nfailed!")
      return
    end
    self:performMove(user, target, { id = last, pp = 1 }, true)
    return
  end

  user.lastMove = move.id

  -- charge moves: first turn just charges; Fly AND Dig go
  -- semi-invulnerable (ChargeEffect sets INVULNERABLE for both)
  if (effect == "CHARGE_EFFECT" or effect == "FLY_EFFECT") and not releasing then
    user.charging = moveInst
    user.chargeReady = true
    local chargeText = ({
      FLY = "%s\nflew up high!",
      DIG = "%s\ndug a hole!",
      RAZOR_WIND = "%s\nmade a whirlwind!",
      SOLARBEAM = "%s\ntook in sunlight!",
      SKULL_BASH = "%s\nlowered its head!",
      SKY_ATTACK = "%s\nis glowing!",
    })[move.id] or "%s\nis charging up!"
    if effect == "FLY_EFFECT" or move.id == "DIG" then
      user.invulnerable = true
    end
    self:sayNext(chargeText:format(displayName(user)))
    return
  end

  if effect == "SWITCH_AND_TELEPORT_EFFECT" then
    -- SwitchAndTeleportEffect (effects.asm:810-909): in a wild battle
    -- it auto-succeeds when the user's level >= the opponent's;
    -- otherwise roll rand[0, userLevel+enemyLevel] and FAIL when the
    -- roll is below opponentLevel/4.  Teleport's failure text is "But
    -- it failed!", Roar/Whirlwind's is DidntAffectText; in trainer
    -- battles Teleport fails and Roar/Whirlwind are "unaffected".
    if self.kind == "wild" then
      local uLvl, tLvl = user.mon.level, target.mon.level
      local ok = uLvl >= tLvl
      if not ok then
        ok = self.rng(0, uLvl + tLvl) >= math.floor(tLvl / 4)
      end
      if ok then
        if move.id == "ROAR" then
          self:sayNext(("%s\nran away scared!"):format(displayName(target)))
        elseif move.id == "WHIRLWIND" then
          self:sayNext(("%s\nwas blown away!"):format(displayName(target)))
        else
          self:sayNext(("%s\nran from battle!"):format(displayName(user)))
        end
        self.result = "run"
        self.afterQueue = "finish"
      elseif move.id == "TELEPORT" then
        self:sayNext("But, it failed!")
      else
        self:sayNext(("It didn't affect\n%s!"):format(displayName(target)))
      end
    elseif move.id == "TELEPORT" then
      self:sayNext("But, it failed!")
    else
      self:sayNext(("%s\nis unaffected!"):format(displayName(target)))
    end
    return
  end

  if effect == "BIDE_EFFECT" then
    user.bideTurns = self.rng(2, 3)
    user.bideDamage = 0
    self:sayNext(("%s\nis storing energy!"):format(displayName(user)))
    return
  end

  -- Mimic runs its own mid-move flow: hit test, then the copy menu
  -- (player) or a random roll (enemy / link), all on the queue
  if effect == "MIMIC_EFFECT" then
    self:resolveMimic(user, target, move, moveInst)
    return
  end

  -- pure status moves
  local primary = MoveEffects.primary[effect]
  if move.power == 0 and primary then
    -- accuracy-checked status effects run MoveHitTest, which has no
    -- 100%-accuracy early-out (even Thunder Wave misses on the 255
    -- roll) and misses outright against a mid-Fly/Dig target; the
    -- never-miss paths (X ACCURACY) live inside Damage.accuracyRoll
    if ACC_CHECKED_STATUS[effect]
       and (target.invulnerable
            or not Damage.accuracyRoll(self.ruleset, move, user, target, self.rng)) then
      self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
      return
    end
    for _, m in ipairs(primary(self, user, target, move, moveInst)) do
      self:sayNext(m)
    end
    self:drainNext() -- REST/RECOVER/SOFTBOILED move the user's bar
    return
  end
  if move.power == 0 and not MoveEffects.special[effect] then
    MoveEffects.warnUnknown(effect)
    self:sayNext("But, it failed!")
    return
  end

  -- damaging move ---------------------------------------------------------

  -- Swift ignores semi-invulnerability (MoveHitTest returns hit for
  -- SWIFT_EFFECT before the INVULNERABLE check)
  if target.invulnerable and effect ~= "SWIFT_EFFECT" then
    self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
    return
  end

  if effect == "OHKO_EFFECT" then
    -- fails against faster opponents (Gen 1 rule) and immune types
    if TypeChart.effectiveness(move.type, target.curTypes) == 0 then
      self:sayNext(("It doesn't affect\n%s!"):format(displayName(target)))
      return
    end
    if TurnOrder.effectiveSpeed(user) < TurnOrder.effectiveSpeed(target) then
      self:sayNext("But, it failed!")
      return
    end
  end

  -- Dream Eater only works on sleeping targets (checked before damage)
  if effect == "DREAM_EATER_EFFECT" and target.mon.status ~= "SLP" then
    self:sayNext("But, it failed!")
    return
  end

  local hits = 1
  if effect == "TWO_TO_FIVE_ATTACKS_EFFECT" then
    local r = self.rng(0, 7)
    hits = ({ 2, 2, 2, 3, 3, 3, 4, 5 })[r + 1]
  elseif effect == "ATTACK_TWICE_EFFECT" or effect == "TWINEEDLE_EFFECT" then
    hits = 2
  end

  -- TrappingEffect runs BEFORE the hit test and clears the target's
  -- Hyper Beam recharge, even if the trapping move then misses
  -- (effects.asm:1091-1092 ClearHyperBeam)
  if effect == "TRAPPING_EFFECT" and not user.trappingTurns then
    target.mustRecharge = nil
  end

  -- accuracy (Swift never misses)
  if effect ~= "SWIFT_EFFECT" then
    if not Damage.accuracyRoll(self.ruleset, move, user, target, self.rng) then
      if effect == "JUMP_KICK_EFFECT" then
        self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
        self:sayNext(("%s\nkept going and\ncrashed!"):format(displayName(user)))
        self:applyDamage(user, 1)
        if user.mon.hp <= 0 then self:onFaint(user) end
      elseif effect == "EXPLODE_EFFECT" then
        self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
        self:selfDestruct(user)
      else
        self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
      end
      user.trappingTurns = nil
      return
    end
  end

  -- damage per hit
  local dmg, info
  if move.id == "COUNTER" then
    -- HandleCounterMove: 2x the last damage dealt in battle, only if
    -- the opponent's last move was Normal/Fighting with >0 power (and
    -- not Counter itself); wDamage is shared, so any last damage counts
    local lastId = target.lastMove
    local lm = lastId and lastId ~= "COUNTER" and self.data.moves[lastId]
    local counterable = lm and (lm.power or 0) > 0
                        and (lm.type == "NORMAL" or lm.type == "FIGHTING")
    if not counterable or (self.lastDamage or 0) == 0 then
      self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
      return
    end
    dmg = math.min(65535, self.lastDamage * 2)
    info = { crit = false, typeMult = 10 }
  elseif effect == "SPECIAL_DAMAGE_EFFECT" or effect == "SUPER_FANG_EFFECT" then
    -- fixed damage still respects type immunity (AdjustDamageForMoveType
    -- flags the miss before the special-damage override)
    if TypeChart.effectiveness(move.type, target.curTypes) == 0 then
      self:sayNext(("It doesn't affect\n%s!"):format(displayName(target)))
      return
    end
    if effect == "SUPER_FANG_EFFECT" then
      dmg = math.max(1, math.floor(target.mon.hp / 2))
    else
      dmg = self:specialDamage(user, target, move)
      if not dmg then
        self:sayNext("But, it failed!")
        return
      end
    end
    info = { crit = false, typeMult = 10 }
  elseif effect == "OHKO_EFFECT" then
    dmg = 65535
    info = { crit = false, typeMult = 10 }
  else
    dmg, info = Damage.compute(self.ruleset, user, target, move,
                               { rng = self.rng, explode = effect == "EXPLODE_EFFECT" })
  end

  if info.typeMult == 0 then
    self:sayNext(("It doesn't affect\n%s!"):format(displayName(target)))
    if effect == "EXPLODE_EFFECT" then self:selfDestruct(user) end
    return
  end
  if info.missed then
    -- 0.25x floored the damage to zero: the original registers a miss
    self:sayNext(("%s's\nattack missed!"):format(displayName(user)))
    if effect == "EXPLODE_EFFECT" then self:selfDestruct(user) end
    return
  end
  self.lastDamage = dmg -- wDamage (shared by both sides, read by Counter)

  -- the hit blink + damage sound ride the queue behind the animation:
  -- on the move's anim row when one was announced, else on a bare hit
  -- row (thrash/rage continuations), placed BEFORE the drain rows the
  -- hits loop inserts so the blink precedes the bar drain
  local hitRow = self.moveAnimRow
  if not hitRow then
    self.nextInsert = (self.nextInsert or 0) + 1
    hitRow = { hitRow = true }
    table.insert(self.queue, self.nextInsert, hitRow)
  end

  local totalDealt = 0
  local hitCount, brokeSub = 0, false
  for h = 1, hits do
    if target.mon.hp <= 0 then break end
    local hadSub = target.substituteHP ~= nil
    totalDealt = totalDealt + self:applyDamage(target, dmg)
    hitCount = h
    if hadSub and not target.substituteHP then
      -- AttackSubstitute: breaking the substitute ends a multi-hit move
      brokeSub = true
      break
    end
  end
  hits = hitCount > 0 and hitCount or hits
  if totalDealt > 0 then
    -- the original's per-hit sound: normal / super / not-very-effective
    local hitSfx = info.typeMult > 10 and "Super_Effective"
                   or info.typeMult < 10 and "Not_Very_Effective" or "Damage"
    hitRow.hit = { sfx = hitSfx,
                   blink = self:animationsOn() and target or nil }
  end
  -- PrintCriticalOHKOText prints "Critical hit!"/"One-hit KO!" right
  -- after the damage lands, BEFORE DisplayEffectiveness (core.asm
  -- .moveDidNotMiss); the multi-hit count follows the last hit
  if info.crit then self:sayNext("Critical hit!") end
  if effect == "OHKO_EFFECT" then
    self:sayNext("One-hit KO!")
  end
  if info.typeMult > 10 then
    self:sayNext("It's super\neffective!")
  elseif info.typeMult < 10 then
    self:sayNext("It's not very\neffective...")
  end
  if hits > 1 then
    -- player: _MultiHitText; enemy: _HitXTimesText (always plural)
    if user.isPlayer then
      self:sayNext(("Hit the enemy\n%d times!"):format(hits))
    else
      self:sayNext(("Hit %d times!"):format(hits))
    end
  end

  -- post-damage effect bookkeeping
  if effect == "RECOIL_EFFECT" or moveInst.struggle then
    -- recoil.asm reads the RAW computed wDamage (not the HP actually
    -- removed): overkill and substitute hits recoil at full strength
    local recoil = math.max(1, math.floor(dmg / (moveInst.struggle and 2 or 4)))
    self:sayNext(("%s's\nhit with recoil!"):format(displayName(user)))
    self:applyDamage(user, recoil)
  elseif effect == "DRAIN_HP_EFFECT" or effect == "DREAM_EATER_EFFECT" then
    -- drain_hp.asm halves the RAW wDamage IN PLACE (minimum 1) and
    -- heals that amount, so Counter would see the halved value
    local heal = math.max(1, math.floor(dmg / 2))
    self.lastDamage = heal
    user.mon.hp = math.min(user.mon.stats.hp, user.mon.hp + heal)
    self:drainNext()
    if effect == "DREAM_EATER_EFFECT" then
      self:sayNext(("%s's\ndream was eaten!"):format(displayName(target)))
    else
      self:sayNext(("Sucked health from\n%s!"):format(displayName(target)))
    end
  elseif effect == "EXPLODE_EFFECT" then
    self:selfDestruct(user)
  elseif effect == "HYPER_BEAM_EFFECT" then
    -- no recharge when the target faints OR its substitute breaks
    if target.mon.hp > 0 and not brokeSub then
      user.mustRecharge = true
    end
  elseif effect == "PAY_DAY_EFFECT" then
    self.payDay = (self.payDay or 0) + 2 * user.mon.level
    self:sayNext("Coins scattered\neverywhere!")
  elseif effect == "TRAPPING_EFFECT" then
    if not user.trappingTurns then
      -- TrappingEffect (effects.asm:1080-1103) rolls wNumAttacksLeft
      -- as 1-4 (weights 3/8 3/8 1/8 1/8): that many CONTINUATION
      -- attacks follow this first hit, 2-5 attacks total.  The victim
      -- is held while the counter runs (live mirror in lockedAction).
      local r = self.rng(0, 7)
      user.trappingTurns = ({ 1, 1, 1, 2, 2, 2, 3, 4 })[r + 1]
      user.trapDamage = dmg
      -- remember the move so its animation can replay on each locked
      -- continuation (core.asm:3554-3566 -> GetPlayerAnimationType)
      user.trapMove = move.id
    end
  elseif effect == "THRASH_PETAL_DANCE_EFFECT" then
    if not user.thrashTurns then
      user.thrashTurns = self.rng(2, 3) -- 3-4 attacks total, then confusion
      user.thrashMove = moveInst
      user.thrashAnnounced = true
    else
      user.thrashTurns = user.thrashTurns - 1
      if user.thrashTurns <= 0 then
        user.thrashTurns, user.thrashMove, user.thrashAnnounced = nil, nil, nil
        if not user.confusedTurns then
          user.confusedTurns = self.rng(2, 5)
          self:sayNext(("%s\nbecame confused!"):format(displayName(user)))
        end
      end
    end
  elseif effect == "RAGE_EFFECT" then
    user.rageMove = moveInst
  end

  -- secondary side effects (blocked by fainting)
  local secondary = MoveEffects.secondary[effect]
  if secondary and target.mon.hp > 0 and totalDealt > 0 then
    for _, m in ipairs(secondary(self, user, target, move)) do
      self:sayNext(m)
    end
  end
  if not MoveEffects.special[effect] and not MoveEffects.secondary[effect]
     and not MoveEffects.primary[effect] and effect ~= "NO_ADDITIONAL_EFFECT" then
    MoveEffects.warnUnknown(effect)
  end

  if target.mon.hp <= 0 then
    self:onFaint(target)
  end
  if user.mon.hp <= 0 then
    self:onFaint(user)
  end
end

function BattleState:continueTrapping(user, target)
  self:sayNext(("%s's\nattack continues!"):format(displayName(user)))
  -- .MultiturnMoveCheck (core.asm:3554-3566) prints AttackContinuesText
  -- then jumps to GetPlayerAnimationType, so the trapping move's full
  -- animation replays each locked turn (same damage, animation shown).
  -- Mirror performMove's anim row (BattleState.lua ~1307), gated on the
  -- OPTIONS animation toggle.
  if user.trapMove and self:animationsOn() then
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert,
                 { anim = user.trapMove, attackerIsPlayer = user.isPlayer })
  end
  -- the counter can sit at 0 until the END of the turn: the trapping
  -- bit is only cleared by CheckNumAttacksLeft (core.asm:439/467)
  -- after BOTH battlers acted, so a slower victim is still held
  -- through the attacker's final hit (endOfTurn nils it)
  user.trappingTurns = user.trappingTurns - 1
  self:applyDamage(target, user.trapDamage or 1)
  if target.mon.hp <= 0 then self:onFaint(target) end
end

function BattleState:continueBide(user, target)
  user.bideTurns = user.bideTurns - 1
  if user.bideTurns > 0 then
    self:sayNext(("%s\nis storing energy!"):format(displayName(user)))
    return
  end
  self:sayNext(("%s\nunleashed energy!"):format(displayName(user)))
  local dmg = (user.bideDamage or 0) * 2
  user.bideTurns, user.bideDamage = nil, nil
  if dmg <= 0 then
    self:sayNext("But, it failed!")
    return
  end
  self:applyDamage(target, dmg)
  if target.mon.hp <= 0 then self:onFaint(target) end
end

function BattleState:selfDestruct(user)
  user.mon.hp = 0
  self:onFaint(user)
end

-- Applies damage honoring Substitute, Bide storage and Rage; returns the
-- amount that counts as dealt (for recoil/drain).
function BattleState:applyDamage(target, dmg)
  if target.substituteHP then
    target.substituteHP = target.substituteHP - dmg
    if target.substituteHP <= 0 then
      target.substituteHP = nil
      self:sayNext(("%s's\nSUBSTITUTE broke!"):format(displayName(target)))
    else
      self:sayNext(("The SUBSTITUTE\ntook damage for\n%s!"):format(displayName(target)))
    end
    return dmg
  end
  local dealt = math.min(dmg, target.mon.hp)
  target.mon.hp = target.mon.hp - dealt
  if dealt > 0 then self:drainNext() end -- animate the bar down
  if target.bideTurns then
    target.bideDamage = (target.bideDamage or 0) + dealt
  end
  if target.rageMove and dealt > 0 then
    target.stages.attack = math.min(6, (target.stages.attack or 0) + 1)
    self:sayNext(("%s's\nRAGE is building!"):format(displayName(target)))
  end
  return dealt
end

-- fixed-damage moves (engine/battle/core.asm SpecialDamage)
function BattleState:specialDamage(user, target, move)
  local id = move.id
  if id == "SONICBOOM" then return 20 end
  if id == "DRAGON_RAGE" then return 40 end
  if id == "SEISMIC_TOSS" or id == "NIGHT_SHADE" then return user.mon.level end
  if id == "PSYWAVE" then
    local max = math.max(1, math.floor(user.mon.level * 3 / 2) - 1)
    return self.rng(1, max)
  end
  return nil
end

-- ---------------------------------------------------------------------
-- fainting / exp / party
-- ---------------------------------------------------------------------

function BattleState:onFaint(battler)
  if battler.faintQueued then return end
  battler.faintQueued = true
  -- the faint slide + cry ride the queue (after the move animation and
  -- the HP-bar drain, pokered's order); the slide finishes before the
  -- faint text via a queued hold
  self:actNext(function()
    battler.fainted = true
    local Sound = require("src.core.Sound")
    Sound.playCry(self.data, battler.mon.species)
    Sound.play(self.data, "Faint_Fall")
    self.fx = self.fx or {}
    self.fx.faint = { battler = battler, frames = 30 }
  end)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { wait = 30 })
  if not battler.isPlayer and self.kind == "wild" then
    -- FaintEnemyPokemon .wild_win (core.asm:792-795): beating a wild
    -- mon calls EndLowHealthAlarm and starts MUSIC_DEFEATED_WILD_MON
    -- as the slide lands, BEFORE EnemyMonFaintedText and the exp text;
    -- trainer battles keep the battle theme until TrainerBattleVictory.
    -- (Starting it even when the player mon dropped too matches the
    -- acknowledged core.asm:797-798 bug.)
    self:actNext(function() self:playVictoryMusic() end)
  end
  -- _EnemyMonFaintedText "Enemy X fainted!" / _PlayerMonFaintedText
  self:sayNext(("%s\nfainted!"):format(displayName(battler)))
  if battler.isPlayer then
    self:act(function() self:playerMonFainted() end)
  else
    self:act(function() self:enemyMonFainted() end)
  end
end

function BattleState:enemyMonFainted()
  -- exp is split among the mons that fought this enemy
  -- (engine/battle/experience.asm); traded mons earn x1.5; each
  -- participant gets the full stat exp
  -- the divisor counts EVERY participant, fainted ones included
  -- (DivideExpDataByNumMonsGainingExp keeps their flag bits); only the
  -- living ones are actually paid
  local participants, alive = 0, {}
  for _, mon in ipairs(self.game.save.party) do
    if self.participants and self.participants[mon] then
      participants = participants + 1
      if mon.hp > 0 then table.insert(alive, mon) end
    end
  end
  if participants == 0 and self.player.mon.hp > 0 then
    participants, alive = 1, { self.player.mon }
  end
  local function applyShare(mon, split, announce)
    local levels, gained = Experience.apply(self.data, mon, self.enemy.def,
                                            self.enemy.mon.level, self.kind == "trainer",
                                            split, mon.traded)
    local name = mon.nickname or self.data.pokemon[mon.species].name
    if announce then
      -- GainedText (experience.asm:342-354): "X gained" plus one of
      -- _WithExpAllText / _BoostedText / _ExpPointsText; the EXP.ALL
      -- pass beats the traded boost (wBoostExpByExpAll checks first),
      -- and _ExpPointsText prints wExpAmountGained -- the raw share,
      -- captured before the max-level cap (experience.asm:92-100)
      local tail = "%d EXP. Points!"
      if announce == "expAll" then
        tail = "with EXP.ALL,\n" .. tail
      elseif mon.traded then
        tail = "a boosted\n" .. tail
      end
      self:sayNext(("%s gained\n" .. tail):format(name, gained))
    end
    -- per level: GrewLevelText -> the stats window (PrintStatsBox) ->
    -- the move-learn checks (experience.asm:245-256)
    local game = self.game
    for _, lv in ipairs(levels) do
      self:sayNext(("%s grew\nto level %d!"):format(name, lv))
      self:uiNext(function()
        require("src.core.Sound").play(game.data, "Level_Up")
        return StatBox.new(game, mon)
      end)
      for _, moveId in ipairs(Experience.movesLearnedAt(
          self.data.pokemon[mon.species], lv)) do
        self:learnMove(mon, moveId)
      end
    end
  end
  -- with EXP.ALL, participants split half the exp and the other half
  -- is divided among the whole party (engine/battle/experience.asm)
  local expAll = (self.game.save.inventory.EXP_ALL or 0) > 0
  for _, mon in ipairs(alive) do
    applyShare(mon, participants * (expAll and 2 or 1), true)
  end
  if expAll then
    -- the second GainExperience pass sets the gain flags for the WHOLE
    -- party, so DivideExpDataByNumMonsGainingExp divides the already
    -- halved-and-participant-divided exp again by the party count, and
    -- .partyMonLoop still skips fainted mons (core.asm:818-858 +
    -- experience.asm:9-13); each mon gets its own GainedText with the
    -- "with EXP.ALL," tail (wBoostExpByExpAll) -- pokered prints no
    -- summary line
    for _, mon in ipairs(self.game.save.party) do
      if mon.hp > 0 then
        applyShare(mon, math.max(1, participants) * #self.game.save.party * 2, "expAll")
      end
    end
  end
  self.participants = {}

  if self.kind == "trainer" then
    if self.enemyIndex < #self.enemyParty then
      self.enemyIndex = self.enemyIndex + 1
      -- SHIFT battle style (the default): announce the next mon and
      -- offer a free switch (SET skips the prompt)
      local nextMon = self.enemyParty[self.enemyIndex]
      local nextName = nextMon.nickname or self.data.pokemon[nextMon.species].name
      local style = (self.game.save.options or {}).battleStyle or "shift"
      local healthy = 0
      for _, mon in ipairs(self.game.save.party) do
        if mon.hp > 0 then healthy = healthy + 1 end
      end
      if style ~= "set" and healthy > 1 and self.player.mon.hp > 0 then
        self:say(("%s is\nabout to use\n%s!"):format(self.trainer.name, nextName))
        self:say(("Will %s\nchange POKéMON?"):format(self.game.save.player.name))
        local game = self.game
        self:ui(function()
          local ChoiceBox = require("src.ui.ChoiceBox")
          return ChoiceBox.new(game, function(yes)
            if not yes then return end
            local PartyMenu = require("src.ui.PartyMenu")
            game.stack:push(PartyMenu.new(game, {
              battle = self,
              onSwitch = function(mon)
                if mon ~= self.player.mon and mon.hp > 0 then
                  self.player = makeBattler(self.data, mon, true, game.save)
                  self:markParticipant()
                  self.nextInsert = 0
                  self.sendingOut = true
                  self:sayNext(self:sendOutText(self.player.name))
                  self:animNext("POOF_ANIM", false)
                  self:actNext(function()
                    self.sendingOut = false
                    -- SendOutMon (core.asm:1757-1762): poof, then the grow-in
                    self:startGrowIn(self.player)
                    require("src.core.Sound").playCry(self.data, self.player.mon.species)
                  end)
                end
              end,
            }))
          end)
        end)
      end
      self:act(function()
        self.enemy = makeBattler(self.data, self.enemyParty[self.enemyIndex], false)
        self.aiUses = self:aiUsesFor()
        markSeen(self.game, self.enemy.mon.species)
        self:markParticipant()
        -- EnemySendOutFirstMon (core.asm:1413-1435): the enemy HUD area
        -- clears, TrainerSentOutText prints, THEN the pic appears
        -- (AnimateSendingOutMon) with the cry; no POOF -- that animation
        -- belongs to the player-side SendOutMon (core.asm:1757-1762)
        self.enemySendingOut = true
        self:sayNext(("%s sent\nout %s!"):format(self.trainer.name, self.enemy.name))
        self:actNext(function()
          self.enemySendingOut = false
          self:startGrowIn(self.enemy)
          self:actNext(function()
            require("src.core.Sound").playCry(self.data, self.enemy.mon.species)
          end)
        end)
      end)
      return
    end
    local prize = (self.trainer.baseMoney or 0) * self.enemy.mon.level
    self.game.save.money = self.game.save.money + prize
    -- the beaten trainer's pic returns for the defeat text (pokered
    -- DisplayBattleMenu's defeat flow)
    self:act(function() self.showEnemyTrainer = self.trainerPic ~= nil end)
    -- TrainerBattleVictory (core.asm:915-933): EndLowHealthAlarm, then
    -- the victory theme starts BEFORE TrainerDefeatedText and the
    -- prize money
    self:actNext(function() self:playVictoryMusic() end)
    -- _TrainerDefeatedText: "<PLAYER> defeated\nTRAINER!"
    self:sayNext(("%s defeated\n%s!"):format(self.game.save.player.name,
                                             self.trainer.name))
    self:sayNext(("%s got ¥%d\nfor winning!"):format(self.game.save.player.name, prize))
  end
  self.result = "win"
  self.afterQueue = "finish"
end

-- Queue the learn-a-move flow (auto if a slot is free, else the forget UI)
function BattleState:learnMove(mon, moveId)
  local mdef = self.data.moves[moveId]
  if not mdef then return end
  for _, mv in ipairs(mon.moves) do
    if mv.id == moveId then return end
  end
  if #mon.moves < 4 then
    table.insert(mon.moves, { id = moveId, pp = mdef.pp })
    self:sayNext(("%s learned\n%s!"):format(mon.nickname or self.data.pokemon[mon.species].name,
                                            mdef.name))
    return
  end
  -- the "trying to learn" preamble lives inside MoveLearnMenu:enter;
  -- ordered insert so multi-level gains keep each level's checks
  -- between its own stat box and the next "grew to level" text
  local game = self.game
  self:uiNext(function()
    local MoveLearnMenu = require("src.ui.MoveLearnMenu")
    return MoveLearnMenu.new(game, mon, moveId)
  end)
end

function BattleState:playerMonFainted()
  if self.result then return end -- double faint: the battle is decided
  local nextMon = Party.firstHealthy(self.game.save.party)
  if not nextMon then
    self:sayNext(("%s is out of\nuseable POKéMON!"):format(self.game.save.player.name))
    self:sayNext(("%s blacked\nout!"):format(self.game.save.player.name))
    self.result = "lose"
    self.afterQueue = "finish"
    return
  end
  -- DoUseNextMonDialogue (core.asm:1052-1078): only WILD battles ask
  -- "Use next POKéMON?"; NO goes through the run check with party slot
  -- 1's speed, and a failed run still forces the party menu.  Trainer
  -- battles go straight to the party menu (the menu-phase guard).
  if self.kind ~= "wild" then return end
  local game = self.game
  self:say(self.data.text._UseNextMonText or "Use next POKéMON?")
  self:ui(function()
    local ChoiceBox = require("src.ui.ChoiceBox")
    return ChoiceBox.new(game, function(yes)
      if yes then return end -- the menu-phase guard opens the party menu
      local pSpd = (game.save.party[1].stats or { speed = 0 }).speed or 0
      if self:runRoll(pSpd, TurnOrder.effectiveSpeed(self.enemy)) then
        require("src.core.Sound").play(self.data, "Run")
        self:say("Got away safely!")
        self.result = "run"
        self.afterQueue = "finish"
      else
        self:say("Can't escape!")
      end
    end)
  end)
end

-- ChooseNextMon (core.asm:1086-1128): the battle party menu; a fainted
-- pick re-prompts (via the menu-phase guard), a healthy pick is sent
-- out with no free enemy move.
function BattleState:openReplacementMenu()
  local game = self.game
  self.phase = "messages"
  self.afterQueue = "menu"
  self:ui(function()
    local PartyMenu = require("src.ui.PartyMenu")
    return PartyMenu.new(game, {
      battle = self,
      onSwitch = function(mon)
        if mon.hp <= 0 then
          self:say("There's no will\nto fight!")
          return -- the menu-phase guard reopens the menu
        end
        self:restoreMimicked(self.player)
        self.player = makeBattler(self.data, mon, true, game.save)
        self:markParticipant()
        self.nextInsert = 0
        self.sendingOut = true
        self:sayNext(self:sendOutText(self.player.name))
        self:animNext("POOF_ANIM", false)
        self:actNext(function()
          self.sendingOut = false
          -- SendOutMon (core.asm:1757-1762): poof, then the grow-in
          self:startGrowIn(self.player)
          require("src.core.Sound").playCry(self.data, self.player.mon.species)
        end)
      end,
    })
  end)
end

-- ---------------------------------------------------------------------
-- Safari game turns
-- ---------------------------------------------------------------------

-- BAIT halves the working catch rate and raises the bait factor by 1-5
-- (zeroing the escape factor); ROCK doubles the catch rate and raises
-- the escape factor by 1-5 (zeroing bait) -- ItemUseBait/ItemUseRock,
-- engine/items/item_effects.asm.
function BattleState:safariAction(choice)
  self.phase = "messages"
  self.afterQueue = "menu"
  local st = self.safari
  local playerName = self.game.save.player.name

  if choice == "run" then
    self:say("Got away safely!")
    self.result = "run"
    self.afterQueue = "finish"
    return
  end

  if choice == "ball" then
    st.balls = st.balls - 1
    self:say(("%s used\nSAFARI BALL!"):format(playerName))
    self:act(function()
      require("src.core.Sound").play(self.data, "Ball_Toss")
      local caught, shakes = Catching.attempt("SAFARI_BALL", self.enemy.mon,
                                              self.enemy.def, self.rng,
                                              self.safariCatchRate)
      -- SAFARI_BALL is neither POKE nor GREAT, so TossBallAnimation
      -- lands on the ULTRATOSS arc (no flicker: SAFARI_BALL is $08,
      -- above DoBallTossSpecialEffects's <= ULTRA_BALL check)
      self:ballChain("ULTRATOSS_ANIM", caught, shakes, "SAFARI_BALL")
      if caught then
        -- ItemUseBallText05's sound_caught_mon: fanfare with the text
        self:actNext(function()
          require("src.core.Sound").play(self.data, "Caught_Mon")
        end)
        self:sayNext(("All right!\n%s was\ncaught!"):format(self.enemy.name))
        -- same ItemUseBall .captured flow as a regular ball
        self:act(function() self:storeCaughtMon() end)
      else
        self:sayNext(self:ballMissMessage(shakes))
        self:act(function() self:safariEnemyTurn() end)
      end
    end)
    return
  end

  if choice == "bait" then
    self:say(("%s threw some\nBAIT."):format(playerName))
    self.safariCatchRate = math.floor(self.safariCatchRate / 2)
    self.baitFactor = math.min(255, self.baitFactor + self.rng(1, 5))
    self.escapeFactor = 0
  else -- rock
    self:say(("%s threw a\nROCK."):format(playerName))
    self.safariCatchRate = math.min(255, self.safariCatchRate * 2)
    self.escapeFactor = math.min(255, self.escapeFactor + self.rng(1, 5))
    self.baitFactor = 0
  end
  self:act(function() self:safariEnemyTurn() end)
end

-- Per-turn factor decay (PrintSafariZoneBattleText,
-- engine/battle/safari_zone.asm: when the escape factor runs out the
-- catch rate resets) then the flee check (engine/battle/core.asm:
-- b = 2*speed, quartered while eating, doubled while angry; the mon
-- flees when speed > 127 or rand(0,255) < b).
function BattleState:safariEnemyTurn()
  if self.baitFactor > 0 then
    self.baitFactor = self.baitFactor - 1
    self:sayNext(("Wild %s\nis eating!"):format(self.enemy.name))
  elseif self.escapeFactor > 0 then
    self.escapeFactor = self.escapeFactor - 1
    if self.escapeFactor == 0 then
      self.safariCatchRate = self.enemy.def.catchRate
    end
    self:sayNext(("Wild %s\nis angry!"):format(self.enemy.name))
  end
  self:act(function()
    local speed = self.enemy.curStats.speed % 256
    local fled = speed > 127
    local b = (speed * 2) % 256
    if not fled then
      if self.baitFactor > 0 then
        b = math.floor(b / 4)
      end
      if self.escapeFactor > 0 then
        b = math.min(255, b * 2)
      end
      fled = self.rng(0, 255) < b
    end
    if fled then
      self:sayNext(("Wild %s\nran!"):format(self.enemy.name))
      self.result = "run"
      self.afterQueue = "finish"
    end
  end)
end

-- ---------------------------------------------------------------------
-- run / items / party
-- ---------------------------------------------------------------------

-- Gen 1 escape formula (engine/battle/core.asm TryRunningFromBattle),
-- shared by the RUN menu choice and the faint dialogue's NO branch;
-- counts a run attempt each call.
function BattleState:runRoll(pSpd, eSpd)
  self.runAttempts = (self.runAttempts or 0) + 1
  if self.ghost then
    return true -- IsGhostBattle -> always escapes
  end
  if pSpd >= eSpd then return true end
  local b = math.floor(eSpd / 4) % 256
  if b == 0 then
    return true -- divisor of zero auto-escapes
  end
  local x = math.floor(pSpd * 32 / b)
  -- +30 per PREVIOUS attempt, escape on 8-bit overflow or on
  -- rand <= x (the original's jr nc keeps the equal case)
  x = x + 30 * (self.runAttempts - 1)
  return x >= 256 or self.rng(0, 255) <= x
end

-- Gen 1 escape formula (engine/battle/core.asm TryRunningFromBattle)
function BattleState:tryRun()
  self.phase = "messages"
  self.afterQueue = "menu"
  if self.kind == "trainer" then
    self:say("No! There's no\nrunning from a\ntrainer battle!")
    return
  end
  -- modified in-battle speeds (stat stages + paralysis), like the
  -- wBattleMonSpeed the original hands to TryRunningFromBattle
  local escaped = self:runRoll(TurnOrder.effectiveSpeed(self.player),
                               TurnOrder.effectiveSpeed(self.enemy))
  if escaped then
    require("src.core.Sound").play(self.data, "Run")
    self:say("Got away safely!")
    self.result = "run"
    self.afterQueue = "finish"
  else
    self:say("Can't escape!")
    self:act(function()
      self:executeAction(self.enemy, self.player, self:enemyAction())
    end)
    self:act(function() self:endOfTurn() end)
  end
end

function BattleState:openItems()
  local BagMenu = require("src.ui.BagMenu")
  local game = self.game
  self.phase = "messages"
  self.afterQueue = "menu"
  self:ui(function()
    return BagMenu.new(game, { battle = self })
  end)
end

-- called by BagMenu after an item is used in battle (consumes the turn)
function BattleState:itemUsed(messages)
  for _, m in ipairs(messages or {}) do self:say(m) end
  table.insert(self.queue, { drain = true }) -- potions animate the bar
  self:act(function()
    self:executeAction(self.enemy, self.player, self:enemyAction())
  end)
  self:act(function() self:endOfTurn() end)
end

-- Wobble messages by shake count (ItemUseBallText01..04)
function BattleState:ballMissMessage(shakes)
  local t = self.data.text
  if shakes == 0 then
    return t._ItemUseBallText01 or "You missed the\nPOKéMON!"
  elseif shakes == 1 then
    return t._ItemUseBallText02 or "Darn! The POKéMON\nbroke free!"
  elseif shakes == 2 then
    return (t._ItemUseBallText03 or "Aww! It appeared\nto be caught!"):gsub("%s+$", "")
  end
  return t._ItemUseBallText04 or "Shoot! It was so\nclose too!"
end

-- The caught mon joins the party or a PC box (ItemUseBall .captured,
-- item_effects.asm:518-566): the caught text, then for a NEW species
-- "New POKéDEX data will be added" + the dex entry page, then the
-- party add (with the nickname ask) or the PC transfer text.
function BattleState:storeCaughtMon()
  -- ItemUseBall reloads the caught mon via LoadEnemyMonData
  -- (item_effects.asm:472-501), regenerating its move list from the
  -- base data -- a Mimic'd slot never leaves the battle with it
  self:restoreMimicked(self.enemy)
  local game = self.game
  local dex = game.save.pokedex
  local species = self.enemy.mon.species
  local isNew = dex ~= nil and not dex.owned[species]
  markOwned(game, species)
  stampOT(game.save, self.enemy.mon)
  if isNew then
    -- _ItemUseBallText06 + ShowPokedexData
    self:sayNext(("New POKéDEX data\nwill be added for\n%s!"):format(self.enemy.name))
    self:uiNext(function()
      local DexEntryMenu = require("src.ui.DexEntryMenu")
      return DexEntryMenu.new(game, species)
    end)
  end
  if Party.add(game.save.party, self.enemy.mon) then
    -- nickname prompt (AskName runs inside AddPartyMon; box mons are
    -- never offered a nickname)
    local caught = self.enemy.mon
    local enemyName = self.enemy.name
    self:uiNext(function()
      local ChoiceBox = require("src.ui.ChoiceBox")
      local TextBox = require("src.render.TextBox")
      return TextBox.new(game, ("Do you want to\ngive a nickname\nto %s?")
          :format(enemyName), function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then return end
          local ok, NamingScreen = pcall(require, "src.ui.NamingScreen")
          if not ok then return end
          game.stack:push(NamingScreen.new(game, {
            title = "NICKNAME?", maxLen = 10,
            onDone = function(name)
              if name and #name > 0 then caught.nickname = name end
            end,
          }))
        end))
      end)
    end)
  else
    local boxNum = require("src.pokemon.Boxes").deposit(game.save, self.enemy.mon)
    if boxNum then
      -- _ItemUseBallText07/08 keyed on EVENT_MET_BILL
      local pc = (game.save.flags and game.save.flags.EVENT_MET_BILL)
                 and "BILL's PC" or "someone's PC"
      self:sayNext(("%s was\ntransferred to\n%s!"):format(self.enemy.name, pc))
    else
      self:sayNext("But every BOX\nis full!")
    end
  end
  self.result = "caught"
  self.afterQueue = "finish"
end

-- TossBallAnimation (engine/battle/animations.asm:2582): the tier's toss
-- anim, then wPokeBallAnimData's upper-nybble count of .PokeBallAnimations
-- entries -- POOF+HIDEPIC+SHAKE for a capture ($43), all five (plus a
-- reappearing POOF+SHOWPIC) for a breakout ($6x); a clean miss ($20)
-- stops after the poof, so the mon never hides
function BattleState:ballChain(tossAnim, caught, shakes, ball)
  self:animNext(tossAnim, true, nil, ball)
  self:animNext("POOF_ANIM", true)
  if not caught and shakes == 0 then return end
  self:animNext("HIDEPIC_ANIM", true)
  self:animNext("SHAKE_ANIM", true, shakes)
  if not caught then
    self:animNext("POOF_ANIM", true)
    self:animNext("SHOWPIC_ANIM", true)
    return
  end
  -- on a capture the $43 chain simply ends after SHAKE_ANIM
  -- (TossBallAnimation returns): the GB leaves the resting closed ball
  -- in OAM, so it stays on screen through the caught text
  self:actNext(function()
    self.lockedBall = self.animPlayer and self.animPlayer:finalSprites() or nil
  end)
end

-- TossBallAnimation picks the toss arc from wCurItem: POKE->TOSS,
-- GREAT->GREATTOSS, everything else (ULTRA/MASTER/SAFARI...)->ULTRATOSS
local function tossAnimFor(ball)
  return ball == "POKE_BALL" and "TOSS_ANIM"
         or ball == "GREAT_BALL" and "GREATTOSS_ANIM"
         or "ULTRATOSS_ANIM"
end

-- called by BagMenu when a ball is thrown
function BattleState:throwBall(ball)
  self:say(("%s used\n%s!"):format(self.game.save.player.name,
                                   self.data.items[ball].name))
  self:act(function()
    require("src.core.Sound").play(self.data, "Ball_Toss")
    if self.kind ~= "wild" then
      self:sayNext("The TRAINER\nblocked the BALL!")
      self:sayNext("Don't be a thief!")
      return
    end
    if self.ghost then
      -- ItemUseBall's can't-be-caught path (item_effects.asm:149-153):
      -- the ball is thrown (TossBallAnimation still picks the arc from
      -- wCurItem, so a Master/Ultra toss keeps its flicker), dodged
      -- ($10 anim data, no wobbles), and the turn is spent like any
      -- failed throw
      self:animNext(tossAnimFor(ball), true, nil, ball)
      self:sayNext("It dodged the\nthrown BALL!")
      self:sayNext("This POKéMON\ncan't be caught!")
      self:act(function()
        self:executeAction(self.enemy, self.player, self:enemyAction())
      end)
      self:act(function() self:endOfTurn() end)
      return
    end
    local caught, shakes = Catching.attempt(ball, self.enemy.mon,
                                            self.enemy.def, self.rng)
    -- ItemUseBall's 20-frame beat, then the toss chain for the outcome
    -- (TossBallAnimation maps POKE->TOSS, GREAT->GREATTOSS, else ULTRATOSS)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { wait = 20 })
    self:ballChain(tossAnimFor(ball), caught, shakes, ball)
    if caught then
      -- ItemUseBallText05 carries sound_caught_mon (item_effects.asm:
      -- 608-614): the fanfare sounds with the caught message, before
      -- the prompt, not after the text is dismissed
      self:actNext(function()
        require("src.core.Sound").play(self.data, "Caught_Mon")
      end)
      self:sayNext(("All right!\n%s was\ncaught!"):format(self.enemy.name))
      self:act(function() self:storeCaughtMon() end)
    else
      self:sayNext(self:ballMissMessage(shakes))
      self:act(function()
        self:executeAction(self.enemy, self.player, self:enemyAction())
      end)
      self:act(function() self:endOfTurn() end)
    end
  end)
end

function BattleState:openParty()
  local PartyMenu = require("src.ui.PartyMenu")
  local game = self.game
  self.phase = "messages"
  self.afterQueue = "menu"
  self:ui(function()
    return PartyMenu.new(game, {
      battle = self,
      onSwitch = function(mon)
        if mon == self.player.mon then
          self:say(("%s is\nalready out!"):format(self.player.name))
        elseif mon.hp <= 0 then
          self:say("There's no will\nto fight!")
        else
          self:resolveSwitch(mon)
        end
      end,
    })
  end)
end

-- PlayBattleVictoryMusic (core.asm:959-967) + EndLowHealthAlarm
-- (core.asm:864-872): winning stops the low-health alarm and disables
-- it for the rest of the battle (wLowHealthAlarmDisabled), then starts
-- the victory theme once; gym leaders, Lance and the final rival share
-- MUSIC_DEFEATED_GYM_LEADER (core.asm:917-926).
function BattleState:playVictoryMusic()
  require("src.core.Sound").stopLoop("Low_Health_Alarm")
  self.lowHealthAlarmDisabled = true
  if self.victoryMusicPlayed then return end
  self.victoryMusicPlayed = true
  local kind = self.musicKind == "final" and "gym" or (self.musicKind or "wild")
  require("src.core.Music").playVictory(self.data, kind)
end

function BattleState:finish()
  if self.payDay and self.result == "win" then
    self.game.save.money = self.game.save.money + self.payDay
    self:say(("%s picked up\n¥%d!"):format(self.game.save.player.name, self.payDay))
    self.payDay = nil
    self.afterQueue = "finish"
    self.phase = "messages"
    return
  end
  self.lockedBall = nil
  -- pokered never writes Mimic's copy into the party struct; leaving
  -- battle discards the battle copy, so the original ids come back
  self:restoreMimicked(self.player)
  self:restoreMimicked(self.enemy)
  -- end_of_battle.asm clears wLowHealthAlarm at battle teardown
  require("src.core.Sound").stopLoop("Low_Health_Alarm")
  -- the victory theme already started when the win was decided
  -- (FaintEnemyPokemon .wild_win / TrainerBattleVictory) and loops until
  -- the battle screen closes; leaving battle brings back the map theme,
  -- like the overworld reload's PlayDefaultMusicFadeOutCurrent
  -- (home/overworld.asm:2343-2348)
  require("src.core.Music").restoreMap(self.data)
  self.game.stack:pop()
  if self.onFinish then self.onFinish(self.result or "run") end
end

-- ---------------------------------------------------------------------
-- draw
-- ---------------------------------------------------------------------

-- In-battle HUD tiles + the tile HP bar live in src/render/HudTiles.lua
-- (shared with the status screen)
local HudTiles = require("src.render.HudTiles")
local hudTile = HudTiles.tile
local drawHPBar = HudTiles.drawHPBar

-- CenterMonName: 1-2 letter names print two tiles right, 3-4 one tile
local function nameX(tx, name)
  local n = #name
  return tx * 8 + (n <= 2 and 16 or n <= 4 and 8 or 0)
end

-- Party pokeball row (SetupPokeballs tiles: ball / status ball /
-- fainted ball / empty), 6 slots stepping dx from (x,y).
local ballQuads
function BattleState:drawBallRow(party, x, y, dx)
  if ballQuads == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/generated/battle/balls.png")
    if ok then
      ballQuads = { img = img }
      for i = 0, 3 do
        ballQuads[i] = love.graphics.newQuad(i * 8, 0, 8, 8, img:getDimensions())
      end
    else
      ballQuads = false
    end
  end
  if not ballQuads then return end
  for i = 1, 6 do
    local mon = party[i]
    local tile = not mon and 3 or mon.hp <= 0 and 2 or mon.status and 1 or 0
    love.graphics.draw(ballQuads.img, ballQuads[tile], x + (i - 1) * dx, y)
  end
end

-- the grow-in scale for a battler's pic this frame: nil when not
-- growing, else 0 (ball beat) / 3/7 / 5/7 -- AnimateSendingOutMon's
-- stages (core.asm:6801-6838): 3 frames of the ball tile, 4 frames of
-- a 3x3 block of the 7x7 pic tiles, 5 frames of 5x5, then full size
function BattleState:growInScale(battler)
  local grow = self.growIn
  if not grow or grow.battler ~= battler then return nil end
  local f = grow.frame
  return f < 3 and 0 or f < 7 and 3 / 7 or 5 / 7
end

-- battler hidden this frame? (damage blink)
function BattleState:fxHidden(battler)
  local fx = self.fx
  if fx and fx.blink and fx.blink.target == battler and fx.blink.frames > 0 then
    return self.frame % 8 < 4
  end
  return false
end

-- is the faint slide currently playing for this battler?
function BattleState:fxFaintActive(battler)
  local fx = self.fx
  return fx and fx.faint and fx.faint.battler == battler
         and fx.faint.frames > 0 or false
end

-- vertical slide offset for a fainting battler (the player's pic is
-- drawn 2x, so it slides 2x as fast to sink at the same visual rate)
function BattleState:fxFaintOffset(battler)
  local fx = self.fx
  if self:fxFaintActive(battler) then
    return (30 - fx.faint.frames) * 2 * (battler.isPlayer and 2 or 1)
  end
  return 0
end

-- Substitute doll (AnimationSubstitute, engine/battle/animations.asm):
-- while a battler's substitute is up, its pic is replaced by the mini
-- doll from gfx/sprites/monster.png -- the facing-DOWN frame for the
-- enemy, facing-UP for the player, a 16x16 sprite at pic tiles
-- (2..3,4..5) / (3..4,4..5) of the 7x7 frame: screen (112,32) enemy,
-- (32,72) player.
local substDoll
function BattleState:drawSubstituteDoll(battler)
  if substDoll == nil then
    local ok, img = pcall(love.graphics.newImage,
                          "assets/generated/sprites/monster.png")
    if ok then
      local w, h = img:getDimensions()
      substDoll = { img = img,
                    down = love.graphics.newQuad(0, 0, 16, 16, w, h),
                    up = love.graphics.newQuad(0, 16, 16, 16, w, h) }
    else
      substDoll = false
    end
  end
  if not substDoll then return end
  -- in colorized mode the doll (drawn from BG tiles on the GB) takes
  -- its screen zone's SGB palette like everything else in the region
  local shader
  if self:colorMode() then
    local PaletteFX = require("src.render.PaletteFX")
    shader = PaletteFX.shader()
    if shader then
      local colors = self:zoneColorsAt(battler.isPlayer and 32 or 112,
                                       battler.isPlayer and 72 or 32)
      if colors then
        love.graphics.setShader(shader)
        PaletteFX.sendColors(shader,
          require("src.render.PaletteFX").permute(colors, self:activeBgp()))
      else
        shader = nil
      end
    end
  end
  if battler.isPlayer then
    love.graphics.draw(substDoll.img, substDoll.up, 32, 72)
  else
    love.graphics.draw(substDoll.img, substDoll.down, 112, 32)
  end
  if shader then love.graphics.setShader() end
end

-- MinimizedMonSprite (animations.asm:1745): the 8x5 blob that replaces
-- a minimized mon's pic, written at pic tile (3,4)+2px.  Rows are bit
-- patterns, drawn as shade-3 pixels.
local MINIMIZED_ROWS = {
  { 3, 4 },          -- ...XX...
  { 2, 5 },          -- ..XXXX..
  { 1, 6 },          -- .XXXXXX.
  { 2, 5 },          -- ..XXXX..
  { 2, 2, 5, 5 },    -- ..X..X..
}
function BattleState:drawMinimizedBlob(battler, x, y)
  local r, g, b, a = love.graphics.getColor()
  local col = { 0, 0, 0, 1 }
  local pals = self:colorMode() and self:sgbBattlePals()
  if pals then
    local P = pals[battler.isPlayer and 2 or 3]
    local shade = P[4]
    col = { shade[1] / 255, shade[2] / 255, shade[3] / 255, 1 }
  end
  love.graphics.setColor(col)
  for row, runs in ipairs(MINIMIZED_ROWS) do
    for i = 1, #runs, 2 do
      love.graphics.rectangle("fill", x + 24 + runs[i], y + 34 + row - 1,
                              runs[i + 1] - runs[i] + 1, 1)
    end
  end
  love.graphics.setColor(r, g, b, a)
end

-- Draw a battler pic, sinking it behind its own baseline while the
-- faint slide plays (pokered's AnimationSlideMonDown); a fainted
-- battler stays hidden once the slide ends.  A standing substitute
-- shows the mini doll instead of the mon's own pic.  The SE-driven
-- pic effects (slides/squish/blink/minimize; see applyAnimEffect)
-- offset, clip or replace the pic, and an active BGP fade swaps in a
-- shade-remapped recolor of it.
function BattleState:drawBattlerPic(battler, x, y, scale)
  local img = self:picImage(battler.sprite)
  if battler.substituteHP and not self:fxFaintActive(battler)
     and not battler.fainted then
    self:drawSubstituteDoll(battler)
    return
  end
  if self:fxFaintActive(battler) then
    local off = self:fxFaintOffset(battler)
    local visible = img:getHeight() - math.floor(off / scale)
    if visible > 0 then
      local quad = love.graphics.newQuad(0, 0, img:getWidth(), visible,
                                         img:getWidth(), img:getHeight())
      love.graphics.draw(img, quad, x, y + off, 0, scale, scale)
    end
    return
  end
  if battler.fainted then return end

  local pf = self.picFx and self.picFx[battler]
  if not pf or (not pf.kind and not pf.hidden and not pf.minimized
                and (pf.ox or 0) == 0 and (pf.oy or 0) == 0) then
    love.graphics.draw(img, x, y, 0, scale, scale)
    return
  end
  if pf.hidden then return end
  if pf.minimized then
    self:drawMinimizedBlob(battler, x, y)
    return
  end

  local w, h = img:getWidth(), img:getHeight()
  local ox, oy = pf.ox or 0, pf.oy or 0
  local k, t = pf.kind, pf.t or 0
  local xscale = 1
  -- while an SE effect displaces the pic, confine it to its side's
  -- tile window like the GB tilemap does (the pic can never overwrite
  -- the HUD columns or the text box rows)
  local clip = love.graphics.setScissor and love.graphics.intersectScissor
  local scx, scy, scw, sch
  if clip then
    scx, scy, scw, sch = love.graphics.getScissor()
    if battler.isPlayer then
      love.graphics.intersectScissor(0, 0, 80, 96)
    else
      love.graphics.intersectScissor(88, 0, 72, 56)
    end
  end
  if k == "slideOff" then
    -- one tile (8px) toward the mon's own screen edge per 3 frames
    local dir = battler.isPlayer and -1 or 1
    ox = ox + dir * 8 * math.min(8, math.floor(t / 3) + 1)
  elseif k == "slideHalf" then
    local dir = battler.isPlayer and -1 or 1
    ox = ox + dir * 8 * math.min(4, math.floor(t / 4) + 1)
  elseif k == "slideDown" then
    oy = oy + 8 * math.min(7, math.floor(t / 3) + 1)
  elseif k == "slideDownHide" then
    oy = oy + 16 * (math.floor(t / 8) + 1)
  elseif k == "bounce" then
    -- 5 back-to-back AnimationSlideMonDown passes
    oy = oy + 8 * math.min(7, math.floor((t % 21) / 3) + 1)
  elseif k == "shakeBF" then
    ox = ox + ((math.floor(t / 3) % 2 == 0) and -8 or 8)
  elseif k == "squish" then
    xscale = math.max(0, 7 - 2 * (math.floor(t / 6) + 1)) / 7
  elseif k == "blink" then
    -- skip; falls through to the scissor-restore below instead of an
    -- early return that would leave the pic-window scissor stuck
  end

  local skipDraw = (k == "squish" and xscale <= 0)
                    or (k == "blink" and math.floor(t / 5) % 2 == 0)

  if skipDraw then
    -- draw nothing this frame, but still restore the scissor rect
  elseif oy > 0 then
    -- sink below the baseline (AnimationSlideMonDown-style row clip)
    local visible = h - math.floor(oy / scale)
    if visible > 0 then
      local quad = love.graphics.newQuad(0, 0, w, visible, w, h)
      love.graphics.draw(img, quad, x + ox, y + oy, 0, scale, scale)
    end
  elseif k == "slideUp" then
    -- AnimationSlideMonUp: cyclic upward wrap, one row per 2 frames
    local scroll = 8 * math.min(7, math.floor(t / 2) + 1)
    local src = math.floor(scroll / scale) % h
    if src == 0 then
      love.graphics.draw(img, x + ox, y, 0, scale, scale)
    else
      local top = love.graphics.newQuad(0, src, w, h - src, w, h)
      love.graphics.draw(img, top, x + ox, y, 0, scale, scale)
      local bottom = love.graphics.newQuad(0, 0, w, src, w, h)
      love.graphics.draw(img, bottom, x + ox, y + (h - src) * scale,
                         0, scale, scale)
    end
  elseif xscale < 1 then
    -- AnimationSquishMonPic: columns collapse toward the middle
    love.graphics.draw(img, x + w * scale * (1 - xscale) / 2, y,
                       0, scale * xscale, scale)
  else
    love.graphics.draw(img, x + ox, y + oy, 0, scale, scale)
  end
  if clip then
    if scx then
      love.graphics.setScissor(scx, scy, scw, sch)
    else
      love.graphics.setScissor()
    end
  end
end

-- ------------------------------------------------------------------
-- SGB battle colorization.  SetPal_Battle (engine/gfx/palettes.asm:28)
-- assigns pal 0 = player HP-bar palette, pal 1 = enemy HP-bar palette,
-- pal 2 = player mon palette, pal 3 = enemy mon palette;
-- BlkPacket_Battle (data/sgb/sgb_packets.asm:65) maps them onto screen
-- regions.  The BG layer is drawn in DMG grays to a canvas and each
-- region is recolored through the PaletteFX shader; the OAM anim
-- sprites are colored per sprite afterwards (BGP fades never touch
-- them, matching the hardware).
-- ------------------------------------------------------------------

-- BlkPacket_Battle ATTR_BLK data: pal slot + inclusive tile rect.
-- The first entry is the %111 outside fill; the blocks are disjoint.
local BATTLE_ZONES = {
  { pal = 0, 0, 0, 19, 17 },  -- everything else
  { pal = 1, 1, 0, 10, 3 },   -- enemy HUD
  { pal = 0, 10, 7, 19, 10 }, -- player HUD
  { pal = 2, 0, 4, 8, 11 },   -- player mon
  { pal = 3, 11, 0, 19, 6 },  -- enemy mon
  { pal = 2, 0, 12, 19, 17 }, -- message box
}

-- the colorizer needs canvases + shaders + pixel access (headless
-- stubs and stripped-down builds fall back to the flat colored path)
function BattleState:colorMode()
  if self.colorFxReady == nil then
    local ready = false
    local g = love and love.graphics
    if g and g.newCanvas and g.setScissor and g.setShader and g.getCanvas
       and love.image and self.data.palettes
       and require("src.render.PaletteFX").shader() then
      local ok1, bg = pcall(g.newCanvas, 160, 144)
      local ok2, wv = pcall(g.newCanvas, 160, 144)
      if ok1 and ok2 and bg and wv then
        self.bgCanvas, self.waveCanvas = bg, wv
        ready = true
      end
    end
    self.colorFxReady = ready
  end
  return self.colorFxReady
end

-- The four SGB palettes SetPal_Battle would currently send: bar
-- palettes track the drawn HP bars (GetHealthBarColor), the mon slots
-- hold MonsterPalettes[wBattleMonSpecies]/[wEnemyMonSpecies2] --
-- PAL_MEWMON (= MonsterPalettes[0]) while a side still shows its
-- trainer/back pic (the species bytes are 0 then).
function BattleState:sgbBattlePals()
  local pals = self.data.palettes and self.data.palettes.palettes
  if not pals then return nil end
  local PaletteFX = require("src.render.PaletteFX")
  local function bar(b)
    if not b then return pals.GREENBAR end
    local hp = b.shownHP or b.mon.hp
    return pals[PaletteFX.barPalName(hp, b.mon.stats.hp)] or pals.GREENBAR
  end
  local function mon(b, placeholder)
    if placeholder or not b then return pals.MEWMON or pals.GREENBAR end
    local name = self.data.palettes.pokemon[b.mon.species]
    return pals[name] or pals.MEWMON
  end
  return {
    [0] = bar(self.player),
    [1] = bar(self.enemy),
    [2] = mon(self.player, self.showPlayerBack or self.safari or self.demo),
    [3] = mon(self.enemy, self.showEnemyTrainer),
  }
end

-- the SGB palette covering a screen pixel (BlkPacket_Battle regions)
function BattleState:zoneColorsAt(x, y)
  local pals = self:sgbBattlePals()
  if not pals then return nil end
  local tx = math.floor(x / 8)
  local ty = math.floor(y / 8)
  if ty >= 12 then return pals[2] end                      -- message box
  if tx >= 11 and ty <= 6 then return pals[3] end          -- enemy mon
  if tx <= 8 and ty >= 4 and ty <= 11 then return pals[2] end -- player mon
  if tx >= 1 and tx <= 10 and ty <= 3 then return pals[1] end -- enemy HUD
  return pals[0]
end

-- AnimationWavyScreen's per-scanline SCX offsets
-- (WavyScreenLineOffsets, animations.asm:1926)
local WAVY_OFFSETS = { 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1,
                       0, 0, 0, 0, 0, -1, -1, -1, -2, -2, -2, -2, -2,
                       -1, -1, -1 }

-- wave the BG canvas one scanline at a time; the offset table walks
-- one entry per frame like the asm's advancing pointer
function BattleState:applyWavy(src)
  local wavy = self.fx and self.fx.wavy
  if not wavy then return src end
  local g = love.graphics
  local prev = g.getCanvas()
  g.setCanvas(self.waveCanvas)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)
  self.waveQuad = self.waveQuad or g.newQuad(0, 0, 160, 1, 160, 144)
  for line = 0, 143 do
    self.waveQuad:setViewport(0, line, 160, 1)
    g.draw(src, self.waveQuad,
           WAVY_OFFSETS[(line + wavy.phase) % 32 + 1], line)
  end
  g.setCanvas(prev)
  return self.waveCanvas
end

-- recolor the grayscale BG canvas per zone; an active BGP fade permutes
-- the zone palette (the SGB colors the remapped DMG shade).  A window
-- shake draws a second, offset copy over the base one: the color
-- regions themselves never move on the SGB, and the vacated strip
-- shows the unshifted BG map like the hardware.
function BattleState:drawZonePass(src, sx, sy)
  local PaletteFX = require("src.render.PaletteFX")
  local shader = PaletteFX.shader()
  local pals = self:sgbBattlePals()
  local bgp = self:activeBgp()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(shader)
  for _, z in ipairs(BATTLE_ZONES) do
    PaletteFX.sendColors(shader, PaletteFX.permute(pals[z.pal], bgp))
    love.graphics.setScissor(z[1] * 8, z[2] * 8,
                             (z[3] - z[1] + 1) * 8, (z[4] - z[2] + 1) * 8)
    love.graphics.draw(src, 0, 0)
    if sx ~= 0 or sy ~= 0 then
      love.graphics.draw(src, sx, sy)
    end
  end
  love.graphics.setScissor()
  love.graphics.setShader()
end

-- colors for one anim-layer OAM sprite at screen pixel (px, py): the
-- zone palette under that pixel's 8x8 attribute cell (the SGB colors
-- the composited picture per cell, so AnimPlayer samples once per cell
-- the tile overlaps), through the OBJ palette the routine ran with
-- (SetAnimationPalette: wAnimPalette = $f0 on SGB, rOBP1 = $6c,
-- ambient rOBP0 = $e4)
local OBJ_SHADES = {
  f0 = { 0, 3, 3 },   -- color 1 -> shade 0, colors 2/3 -> shade 3
  f0x = { 3, 0, 3 },  -- $f0 xor %00111100 = $cc: the Master/Ultra ball
                      -- toss flicker (DoBallTossSpecialEffects)
  e4 = { 1, 2, 3 },   -- identity
  obp1 = { 3, 2, 1 }, -- $6c
}
function BattleState:animSpriteColors(s, px, py)
  local P = self:zoneColorsAt(px or (s.x - 8 + 4), py or (s.y - 16 + 4))
  if not P then return nil end
  local m = OBJ_SHADES[s.obp or "f0"] or OBJ_SHADES.f0
  local function c(shade)
    local col = P[shade + 1]
    return { col[1] / 255, col[2] / 255, col[3] / 255 }
  end
  return { c(m[1]), c(m[2]), c(m[3]) }
end

-- the OAM anim layer (subanimation sprites / the resting caught ball)
function BattleState:drawAnimLayer(colorized)
  local colorFn
  if colorized then
    colorFn = function(s, px, py) return self:animSpriteColors(s, px, py) end
  end
  if self.animPlaying and self.animPlayer then
    love.graphics.setColor(1, 1, 1, 1)
    pcall(self.animPlayer.draw, self.animPlayer, colorFn)
  elseif self.lockedBall and self.animPlayer then
    -- the resting closed ball stays on screen through the caught text
    -- (the $43 chain ends after SHAKE_ANIM and the GB never clears the
    -- ball's OAM entries until the battle screen is torn down)
    love.graphics.setColor(1, 1, 1, 1)
    pcall(self.animPlayer.drawSprites, self.animPlayer, self.lockedBall,
          colorFn)
  end
end

-- the two mon pics (or the trainer/back pics), offset by the window
-- shake -- on the GB the pics are BG tiles, so they move with it
function BattleState:drawPicsLayer(slide, sx, sy)
  -- The move-select boxes are BG tiles on the GB, so they REPLACE the
  -- player pic's rows: the TYPE/PP box at (0,8) (PrintMenuItem) wipes
  -- pic rows 8+, and Mimic's copy menu at (0,7) (MoveSelectionMenu
  -- .mimicmenu) wipes rows 7+.  The port draws pics above the menu
  -- layer in the colorized pipeline, so clip them to the visible rows.
  local g = love.graphics
  local clipY = self.phase == "mimicSelect" and 56
                or self.phase == "moveSelect" and 64 or nil
  local clipped, cs1, cs2, cs3, cs4
  if clipY and g.getScissor and g.intersectScissor then
    cs1, cs2, cs3, cs4 = g.getScissor()
    g.intersectScissor(0, 0, 160, clipY)
    clipped = true
  end
  -- Enemy: front sprite top-right (GB: pic at hlcoord 12,0).
  if self.showEnemyTrainer and self.trainerPic then
    -- the enemy trainer pic holds the mon slot until the send-out
    local img = self:picImage(self.trainerPic)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, 160 - 8 - img:getWidth() - slide + sx,
                       math.max(0, 48 - img:getHeight()) + sy)
  elseif self.enemy and self.enemy.sprite and not self.enemyHidden
     and not self.enemySendingOut and not self:fxHidden(self.enemy) then
    local img = self:picImage(self.enemy.sprite)
    love.graphics.setColor(1, 1, 1, 1)
    local ex = 160 - 8 - img:getWidth() - slide + sx
    local ey = math.max(0, 48 - img:getHeight()) + sy
    local gs = self:growInScale(self.enemy)
    if gs then
      -- AnimateSendingOutMon: the downscaled pic keeps its bottom edge
      -- and horizontal center pinned to the mon's slot while it grows
      if gs > 0 then
        love.graphics.draw(img, ex + img:getWidth() * (1 - gs) / 2,
                           ey + img:getHeight() * (1 - gs), 0, gs, gs)
      end
    else
      self:drawBattlerPic(self.enemy, ex, ey, 1)
    end
  end

  -- Player: back sprite bottom-left (2x like the GB, feet near y=100).
  local hidePlayer = self.safari or self.demo
  if self.showPlayerBack and self.playerBackPic then
    -- Red's (or the old man's) back pic until "Go!"; it stays up for
    -- the whole safari / catch-demo battle like the original
    local img = self:picImage(self.playerBackPic)
    local pad = imagePadBottom[self.playerBackPic] or 0
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, 16 + slide + sx,
                       96 - (img:getHeight() - pad) * 2 + sy, 0, 2, 2)
  elseif self.player and self.player.sprite and not hidePlayer
     and not self.sendingOut and not self:fxHidden(self.player) then
    local img = self:picImage(self.player.sprite)
    love.graphics.setColor(1, 1, 1, 1)
    -- feet flush on the text box top (y=96), ignoring baked-in padding
    local pad = imagePadBottom[self.player.sprite] or 0
    local gs = self:growInScale(self.player)
    if gs then
      -- the player-side AnimateSendingOutMon grow (after the poof,
      -- core.asm:1757-1762): feet pinned at y=96, center at x=16+w
      if gs > 0 then
        love.graphics.draw(img, 16 + img:getWidth() * (1 - gs) + sx,
                           96 - (img:getHeight() - pad) * 2 * gs + sy,
                           0, 2 * gs, 2 * gs)
      end
    else
      self:drawBattlerPic(self.player, 16 + sx,
                          96 - (img:getHeight() - pad) * 2 + sy, 2)
    end
  end
  if clipped then
    if cs1 then
      g.setScissor(cs1, cs2, cs3, cs4)
    else
      g.setScissor()
    end
  end
end

-- the BG-tile UI: HUDs, pokeball rows, safari ball count.  Grayscale;
-- the zone pass colors it in colorized mode.
function BattleState:drawHUDs(slide)
  -- the HUD clears with the send-out text (ClearScreenArea,
  -- core.asm:1414-1417) and DrawEnemyHUDAndHPBar (1435) only redraws
  -- it after the grow-in + cry
  local barData = self:colorMode() and {} or self.data -- gray fill when zoned
  local fx = self.fx
  local hudShake = (fx and fx.hudShakeX) or 0
  if self.enemy and not self.showEnemyTrainer and not self.enemySendingOut
     and not self:growInScale(self.enemy) and slide == 0 then
    -- enemy HUD (DrawEnemyHUDAndHPBar): name row 0, <LV>+level (4,1),
    -- HP bar (2,2) with the vertical tick at (1,2), underline row 3;
    -- AnimationShakeEnemyHUD nudges just this block via SCX
    if hudShake ~= 0 then
      love.graphics.push()
      love.graphics.translate(hudShake, 0)
    end
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(self.enemy.name, nameX(1, self.enemy.name), 0)
    if self.enemy.mon.status then
      Font.draw(self.enemy.mon.status, 40, 8)
    else
      hudTile(0x6E, 32, 8) -- <LV>
      Font.draw(tostring(self.enemy.mon.level), 40, 8)
    end
    hudTile(0x73, 8, 16)
    drawHPBar(barData, 2, 2,
              { hp = shownHP(self.enemy), stats = self.enemy.mon.stats })
    hudTile(0x74, 8, 24)
    for i = 2, 9 do hudTile(0x76, i * 8, 24) end
    hudTile(0x78, 80, 24)
    if hudShake ~= 0 then
      love.graphics.pop()
    end
  end

  -- Safari shows only the ball count; the old man demo shows neither mon
  if self.safari then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("BALLx%2d"):format(self.safari.balls), 88, 72)
  end
  -- trainer-battle party pokeball rows during the intro
  -- (SetupPlayerAndEnemyPokeballs, draw_hud_pokeball_gfx.asm)
  if self.kind == "trainer" and (self.showEnemyTrainer or self.showPlayerBack)
     and slide == 0 then
    love.graphics.setColor(1, 1, 1, 1)
    if self.showEnemyTrainer and self.enemyParty then
      self:drawBallRow(self.enemyParty, 64, 16, -8)
    end
    if self.showPlayerBack then
      self:drawBallRow(self.game.save.party, 88, 80, 8)
    end
  end
  local hidePlayer = self.safari or self.demo
  if self.player and not hidePlayer and not self.showPlayerBack
     and slide == 0 then
    -- player HUD (DrawPlayerHUDAndHPBar): name (10,7), <LV>+level
    -- (14,8), HP bar (10,9), HP numbers row 10, underline row 11 with
    -- the tick at (18,10) and the triangle at (9,11)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(self.player.name, nameX(10, self.player.name), 56)
    if self.player.mon.status then
      Font.draw(self.player.mon.status, 120, 64)
    else
      hudTile(0x6E, 112, 64) -- <LV>
      Font.draw(tostring(self.player.mon.level), 120, 64)
    end
    drawHPBar(barData, 10, 9,
              { hp = shownHP(self.player), stats = self.player.mon.stats },
              1) -- wHPBarType 1: the $6D cap
    Font.draw(("%3d/%3d"):format(shownHP(self.player), self.player.mon.stats.hp), 88, 80)
    hudTile(0x73, 144, 80)
    hudTile(0x77, 144, 88)
    for i = 10, 17 do hudTile(0x76, i * 8, 88) end
    hudTile(0x6F, 72, 88)
  end
end

function BattleState:drawTextArea()
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  if self.phase == "messages" and self.current then
    local shown = 0
    for li, codes in ipairs(self.lines) do
      local y = 104 + li * 8
      for i = 1, #codes do
        if shown >= self.charIndex then break end
        Font.drawCode(codes[i], 8 + (i - 1) * 8, y)
        shown = shown + 1
      end
    end
  elseif self.phase == "menu" and self.demo then
    -- the old-man script (DisplayBattleMenu, core.asm:2038-2049): the
    -- standard menu, with the '▶' hand drawn by the scripted keystrokes
    -- -- next to FIGHT (9,14) for the first 80 frames, then ITEM (9,16)
    Font.drawBox(8, 12, 12, 6)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("FIGHT", 80, 112)
    Font.drawCode(0xE1, 128, 112); Font.drawCode(0xE2, 136, 112)
    Font.draw("ITEM", 80, 128); Font.draw("RUN", 128, 128)
    Font.drawCode(0xED, 72, (self.demoTimer or 0) <= 80 and 112 or 128)
  elseif self.phase == "menu" then
    local col = (self.menuIndex - 1) % 2
    local row = math.floor((self.menuIndex - 1) / 2)
    if self.safari then
      -- SAFARI_BATTLE_MENU_TEMPLATE: full-width box, "BALLx  BAIT /
      -- THROW ROCK  RUN" from (2,14)
      Font.drawBox(0, 12, 20, 6)
      Font.draw("BALLx", 16, 112); Font.draw("BAIT", 112, 112)
      Font.draw("THROW ROCK", 16, 128); Font.draw("RUN", 112, 128)
      Font.drawCode(0xED, (col == 0 and 8 or 104), 112 + row * 16)
    else
      -- BATTLE_MENU_TEMPLATE: box (8,12)-(19,17), "FIGHT <PK><MN> /
      -- ITEM  RUN" from (10,14); cursor columns 9 / 15
      Font.drawBox(8, 12, 12, 6)
      Font.draw("FIGHT", 80, 112)
      Font.drawCode(0xE1, 128, 112); Font.drawCode(0xE2, 136, 112)
      Font.draw("ITEM", 80, 128); Font.draw("RUN", 128, 128)
      Font.drawCode(0xED, (col == 0 and 72 or 120), 112 + row * 16)
    end
  elseif self.phase == "moveSelect" then
    -- pokered MoveSelectionMenu: move list in a box at (4,12) 16x6,
    -- names at column 6 from row 13, cursor at column 5.  PrintMenuItem:
    -- the TYPE/PP box at (0,8) 11x5, with "TYPE/" at (1,9), the type at
    -- (2,10) and "PP cur/max" at (5,11); its bottom border merges into
    -- the move box's top border ('─' at (4,12), '┘' at (10,12)).
    Font.drawBox(0, 8, 11, 5)
    Font.drawBox(4, 12, 16, 6)
    Font.drawCode(Font.BORDER.h, 32, 96)
    Font.drawCode(Font.BORDER.br, 80, 96)
    love.graphics.setColor(0, 0, 0, 1)
    for i, mv in ipairs(self.player.curMoves) do
      Font.draw(self.data.moves[mv.id].name, 48, 96 + i * 8)
    end
    Font.drawCode(0xED, 40, 96 + self.moveIndex * 8)
    local sel = self.player.curMoves[self.moveIndex]
    if sel then
      if self.player.disabledSlot == self.moveIndex then
        Font.draw("disabled!", 8, 80)
      else
        local def = self.data.moves[sel.id]
        Font.draw("TYPE/", 8, 72)
        Font.draw(def.type or "", 16, 80)
        local maxPP = def.pp + (sel.ppUps or 0) * math.floor(def.pp / 5)
        Font.draw(("%2d/%2d"):format(sel.pp, maxPP), 40, 88)
      end
    end
  elseif self.phase == "mimicSelect" then
    -- Mimic's copy menu (MoveSelectionMenu .mimicmenu, core.asm:
    -- 2506-2517): the enemy's move list in a 16x6 box at (0,7), names
    -- single-spaced from (2,8), cursor at column 1
    Font.drawBox(0, 7, 16, 6)
    love.graphics.setColor(0, 0, 0, 1)
    for i, m in ipairs(self.mimicMoves) do
      Font.draw(self.data.moves[m.id].name, 16, (7 + i) * 8)
    end
    Font.drawCode(0xED, 8, (7 + self.mimicIndex) * 8)
  end
end

function BattleState:draw()
  local fx = self.fx
  -- window shakes (SE_SHAKE_SCREEN / the enemy-hit vertical shake);
  -- the animations-off fallback keeps the old +-2 alternation
  local sx = (fx and fx.shakeX) or 0
  local sy = (fx and fx.shakeY) or 0
  if sx == 0 and sy == 0 and fx and fx.shake and fx.shake > 0 then
    sx = self.frame % 4 < 2 and 2 or -2
  end
  local slide = (self.introSlide or 0) * 4 -- intro slide-in offset

  if self:colorMode() then
    -- SGB pipeline: gray BG canvas -> (wavy) -> zone recolor with the
    -- BGP fade -> mon pics -> OAM anim sprites (never BGP-faded)
    local g = love.graphics
    local prev = g.getCanvas()
    local wavy = fx and fx.wavy
    g.setCanvas(self.bgCanvas)
    g.setColor(1, 1, 1, 1)
    g.rectangle("fill", 0, 0, 160, 144)
    self:drawHUDs(slide)
    self:drawTextArea()
    if wavy then
      -- the mon pics are BG tiles on the GB, so SE_WAVY_SCREEN bends
      -- them too: bake them into the canvas as DMG grays and let the
      -- zone pass color them by region (exactly what the SGB did)
      self.grayPics = true
      g.setScissor(0, 0, 160, 96) -- BG pics live above the text box
      self:drawPicsLayer(slide, 0, 0)
      g.setScissor()
      self.grayPics = nil
    end
    g.setCanvas(prev)
    self:drawZonePass(self:applyWavy(self.bgCanvas), sx, sy)
    if not wavy then
      -- the pics are BG tiles in rows 0-11 on the GB: they can never
      -- cover the text box, whatever the SE offsets do (a vertical
      -- window shake moves the box down with everything else)
      g.setScissor(0, 0, 160, 96 + math.max(0, sy))
      self:drawPicsLayer(slide, sx, sy)
      g.setScissor()
    end
    self:drawAnimLayer(true)
  else
    -- flat fallback (headless / no shader support): pre-colorized pics
    -- on white, no palette fades
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    local shaking = sx ~= 0 or sy ~= 0
    if shaking then
      love.graphics.push()
      love.graphics.translate(sx, sy)
    end
    self:drawPicsLayer(slide, 0, 0)
    self:drawHUDs(slide)
    self:drawAnimLayer(false)
    self:drawTextArea()
    if shaking then
      love.graphics.pop()
    end
  end
  -- screen flash (flash-effect moves without the subanimation player):
  -- white flicker overlay
  if fx and fx.flash and fx.flash > 0 and self.frame % 4 < 2 then
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return BattleState
