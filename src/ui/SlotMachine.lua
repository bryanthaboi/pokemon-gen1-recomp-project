-- Game Corner slot machine minigame.
--
-- Wheels are the real symbol sequences (data/events/slot_machine_wheels.asm
-- via field.slotWheels: 15 symbols per wheel plus 3 wraparound entries,
-- read exactly like SlotMachine_GetWheelTiles).  Wheel positions are kept
-- in pokered's half-symbol offsets (wSlotMachineWheelXOffset, 0..29): a
-- wheel may only stop when its offset is odd (a symbol is centred), and
-- every animation step advances the offset by one (SlotMachine_AnimWheel),
-- so slips scroll on screen tile-by-tile like the original.
--
-- Per-wheel stop rules (engine/slots/slot_machine.asm):
--  * wheel 1 (SlotMachine_StopWheel1Early): at each centred position it
--    spends one of 4 slip charges (wSlotMachineWheel1SlipCounter); it stops
--    unless the centred middle symbol is a cherry, which it slips past.  In
--    seven-and-bar mode the early-stop test is pokered's bug (`cp
--    HIGH(SLOTS7)` / `jr c`, never true), so it always slips all 4.
--  * wheel 2 (SlotMachine_StopWheel2Early): stops as soon as wheels 1 and 2
--    line up any potential match (SlotMachine_FindWheel1Wheel2Matches); in
--    seven-and-bar mode it instead stops when the matched (or, with no
--    match, bottom) wheel-2 symbol is a 7 or BAR.  Up to 4 slips.
--  * wheel 3 (SlotMachine_StopOrAnimWheel3): stops at the next centred
--    position; SlotMachine_CheckForMatches then rerolls it one symbol at a
--    time -- past any match the luck flags forbid (without consuming the
--    counter), or toward a match while wSlotMachineRerollCounter (4) lasts.
--
-- Payouts/paylines follow SlotMachine_CheckForMatches: bet 1 plays the
-- middle row, bet 2 adds top and bottom, bet 3 adds both diagonals,
-- checked in pokered's order with the FIRST match taken; 7-7-7 pays 300,
-- BAR 100, CHERRY 8, anything else 15.
--
-- Hidden luck (SlotMachine_SetFlags + game_corner_slots.asm): one machine
-- per Game Corner visit is "lucky" (seven-and-bar mode chance 5/256 vs
-- 2/256).  Each spin: 1/256 arms a 60-charge allow-matches counter,
-- r > chance arms seven-and-bar mode (sticky until a BAR win clears it, or
-- a 300 win does so half the time), r in 211..chance allows a match, the
-- rest can't win.
--
-- Presentation follows pokered's flow: PromptUserToPlaySlots asks "Want to
-- play?" first; MainSlotMachineLoop shows the static SlotMachineMap frame
-- (gfx/slots/slots.tilemap, via field.slotSymbols.tilemap), a "Bet how many
-- coins?" prompt with the ×3/×2/×1 menu (cursor defaults to ×3), flashes the
-- screen on a win (SlotReward*Func b flips of rBGP, 5 frames each) and drips
-- the payout one coin per 8 frames (4 for a 7/BAR) with a jingle and a
-- symbol-palette flicker, then asks "One more go?".

local Font = require("src.render.Font")
local Sound = require("src.core.Sound")

local SlotMachine = {}
SlotMachine.__index = SlotMachine
SlotMachine.isOpaque = true

-- rBGP/rOBP0 `xor $40` from the default $e4 shows the darkest shade (3) one
-- step lighter (shade 2): the win-screen and payout flash
-- (SlotMachine_CheckForMatches .flashScreenLoop / SlotMachine_PayCoinsToPlayer).
local FLASH_MAP = { [0] = 0, [1] = 1, [2] = 2, [3] = 2 }

-- SGB: PalPacket_Slots + BlkPacket_Slots row bands.  While self.flash is set
-- the bands are permuted like pokered's rBGP flip so the machine flashes.
function SlotMachine:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local s1 = P.pal(game.data, "SLOTS1")
  if not s1 then return nil end
  -- self.flash "all" flips every band (the win-screen rBGP flash); "reels"
  -- flips only the symbol window (the payout-time rOBP0 symbol flicker, which
  -- the s1 zone at cols 4-15 / rows 4-9 covers).
  local function fx(c, reel)
    if c and self.flash and (self.flash == "all" or reel) then
      return P.permute(c, FLASH_MAP)
    end
    return c
  end
  return {
    P.zone(fx(P.pal(game.data, "SLOTS2")), 0, 0, 19, 11),
    P.zone(fx(P.pal(game.data, "SLOTS3")), 0, 4, 19, 9),
    P.zone(fx(P.pal(game.data, "SLOTS4")), 0, 6, 19, 7),
    P.zone(fx(s1, true), 4, 4, 15, 9),
    P.zone(fx(s1), 0, 12, 19, 17),
  }
end

local PAYOUT = { ["7"] = 300, BAR = 100, CHERRY = 8,
                 MOUSE = 15, FISH = 15, BIRD = 15 }
local SHORT = { ["7"] = " 7 ", BAR = "BAR", CHERRY = "CHR",
                MOUSE = "MSE", FISH = "FSH", BIRD = "BRD" }

-- MainSlotMachineLoop timing: one animation step every other frame
-- (DelayFrame in SlotMachine_HandleInputWhileWheelsSpin plus DelayFrames(1)
-- on SGB, which this port colorizes as).  The initial free spin is 20
-- steps at the same cadence (SlotMachine_SpinWheels .loop1).
local STEP_FRAMES = 2
local SPINUP_STEPS = 20

local function at(wheel, pos, off)
  return wheel[((pos + off - 1) % #wheel) + 1]
end

-- The three visible symbols at a centred position: wheel[pos] (bottom),
-- wheel[pos+1] (middle), wheel[pos+2] (top) -- SlotMachine_GetWheelTiles.
local function rows(wheel, pos)
  return at(wheel, pos, 0), at(wheel, pos, 1), at(wheel, pos, 2)
end

-- Paylines in pokered's check order (SlotMachine_CheckForMatches): a
-- 3-coin bet tries both diagonals first, then falls into the 2-coin
-- checks (top row, bottom row), then the 1-coin middle row.  The FIRST
-- matching line wins.  Entries are row offsets from the bottom.
local LINES = {
  { 0, 1, 2, bet = 3 }, -- wheel1 bottom / wheel2 middle / wheel3 top
  { 2, 1, 0, bet = 3 }, -- wheel1 top / wheel2 middle / wheel3 bottom
  { 2, 2, 2, bet = 2 }, -- top row
  { 0, 0, 0, bet = 2 }, -- bottom row
  { 1, 1, 1, bet = 1 }, -- middle row
}

-- stops = {pos1, pos2, pos3} (1-based bottom-row positions); returns the
-- first matching line's payout+symbol, like SlotMachine_CheckForMatches.
function SlotMachine.evaluate(wheels, stops, bet)
  for _, line in ipairs(LINES) do
    if bet >= line.bet then
      local a = at(wheels[1], stops[1], line[1])
      local b = at(wheels[2], stops[2], line[2])
      local c = at(wheels[3], stops[3], line[3])
      if a == b and b == c then
        return { payout = PAYOUT[a] or 15, symbol = a }
      end
    end
  end
  return nil
end

-- SlotMachine_StopWheel1Early: true = stop at this centred position.
-- Normally wheel 1 stops unless the centred middle symbol is a cherry.
-- In seven-and-bar mode pokered compares each visible tile with
-- `cp HIGH(SLOTS7)` / `jr c` -- never true, so it never stops early
-- (the wheel always slips through all four charges).
function SlotMachine.stopWheel1Early(wheels, pos1, sevenBar)
  if sevenBar then return false end
  local _, middle = rows(wheels[1], pos1)
  return middle ~= "CHERRY"
end

-- SlotMachine_FindWheel1Wheel2Matches: can wheels 1 and 2, as placed,
-- still line up a payline given a good wheel 3?  Pairs are checked in
-- pokered's order: bottom/bottom, bottom/middle, middle/middle,
-- top/middle, top/top (wheel 1 row first).  Returns matched plus the
-- wheel-2 tile DE points at afterwards (the matched tile, or wheel 2's
-- bottom tile when nothing matched).
function SlotMachine.findWheel1Wheel2Matches(wheels, pos1, pos2)
  local b1, m1, t1 = rows(wheels[1], pos1)
  local b2, m2, t2 = rows(wheels[2], pos2)
  if b2 == b1 then return true, b2 end
  if m2 == b1 then return true, m2 end
  if m2 == m1 then return true, m2 end
  if m2 == t1 then return true, m2 end
  if t2 == t1 then return true, t2 end
  return false, b2
end

-- SlotMachine_StopWheel2Early: true = stop at this centred position.
-- Normally wheel 2 stops as soon as any wheel-1/2 match is lined up; in
-- seven-and-bar mode it stops when the matched (or bottom, when nothing
-- matched) wheel-2 symbol is a 7 or BAR.
function SlotMachine.stopWheel2Early(wheels, pos1, pos2, sevenBar)
  local matched, tile = SlotMachine.findWheel1Wheel2Matches(wheels, pos1, pos2)
  if sevenBar then
    return tile == "7" or tile == "BAR"
  end
  return matched
end

-- One SlotMachine_CheckForMatches decision at the current stops:
--  "accept"  -- pay out `win`
--  "roll"    -- a match the flags forbid: roll wheel 3 down one symbol
--             and try again (does NOT consume the reroll counter)
--  "nomatch" -- nothing lined up (the caller consumes
--             wSlotMachineRerollCounter to keep rolling toward a match
--             when the flags allow a win)
function SlotMachine.checkForMatch(wheels, stops, bet, canWin, sevenBar)
  local win = SlotMachine.evaluate(wheels, stops, bet)
  if not win then return "nomatch" end
  if not (canWin or sevenBar) then return "roll", win end
  if not sevenBar and (win.symbol == "7" or win.symbol == "BAR") then
    return "roll", win
  end
  return "accept", win
end

function SlotMachine.new(game, lucky)
  local self = setmetatable({}, SlotMachine)
  self.game = game
  self.wheels = game.data.field.slotWheels
  -- intro | bet | spinup | spin | reroll | flash | message | payout | onemore
  -- PromptUserToPlaySlots asks "Want to play?" before the session starts.
  self.stage = "intro"
  self.yesno = 1        -- YES/NO cursor (1 = YES); wCurrentMenuItem
  -- CoinMultiplierSlotMachineText lists ×3/×2/×1 with the cursor defaulting to
  -- the top (wCurrentMenuItem 0), i.e. bet = 3 - menuItem.
  self.betIndex = 0
  self.bet = 3
  self.payoutDisplay = 0 -- wPayoutCoins (shown in the top payout box)
  self.flash = false
  -- wSlotMachineWheelXOffset: 29 matches pokered after LoadSlotMachineTiles
  -- draws offset $1c (wheel[15] centred on the bottom row).
  self.offset = { 29, 29, 29 }
  self.stopping = 0    -- wStoppingWhichSlotMachineWheel
  self.slip = { 4, 4 } -- wSlotMachineWheel{1,2}SlipCounter
  self.reroll = 4      -- wSlotMachineRerollCounter
  self.frame = 0
  self.message = nil
  -- the per-visit lucky machine gets better seven-and-bar odds
  -- (wSlotMachineSevenAndBarModeChance 250 vs 253)
  self.sevenBarChance = lucky and 250 or 253
  self.allowMatchesCounter = 0 -- wSlotMachineAllowMatchesCounter
  -- wSlotMachineFlags bits (BIT_SLOTS_CAN_WIN / _WITH_7_OR_BAR)
  self.canWin, self.sevenBar = false, false
  return self
end

local function coins(self) return self.game.save.coins or 0 end

-- SlotMachine_SetFlags, rolled as each spin starts.  Seven-and-bar mode,
-- once armed, is sticky (the asm returns early while the bit is set).
function SlotMachine:setFlags()
  if self.sevenBar then return end
  if self.allowMatchesCounter > 0 then
    self.canWin = true
    return
  end
  local r = love.math.random(0, 255)
  if r == 0 then
    -- 1/256: arm 60 guaranteed-winnable spins.  This spin's flags are
    -- left untouched (the asm returns before writing them).
    self.allowMatchesCounter = 60
    return
  end
  if r > self.sevenBarChance then
    self.sevenBar = true
    return
  end
  if r > 210 then
    self.canWin = true
    return
  end
  self.canWin = false
end

-- SlotMachine_AnimWheel: one half-symbol step; the offset wraps at 30.
function SlotMachine:animWheel(w)
  self.offset[w] = (self.offset[w] + 1) % 30
end

local function posOf(offset) return (offset + 1) / 2 end

function SlotMachine:stops()
  return { posOf(self.offset[1]), posOf(self.offset[2]), posOf(self.offset[3]) }
end

-- SlotMachine_StopOrAnimWheel1/2: a stopping wheel may halt only at odd
-- offsets; each centred position spends one slip charge on the wheel's
-- early-stop check, freezing the wheel when the check passes or (at the
-- next centred position) when the charges run out.
function SlotMachine:stopOrAnimWheel(w)
  if self.stopping < w then
    self:animWheel(w)
    return
  end
  local o = self.offset[w]
  if o % 2 == 0 then
    self:animWheel(w)
    return
  end
  if self.slip[w] == 0 then return end -- stopped
  self.slip[w] = self.slip[w] - 1
  local stop
  if w == 1 then
    stop = SlotMachine.stopWheel1Early(self.wheels, posOf(o), self.sevenBar)
  else
    stop = SlotMachine.stopWheel2Early(self.wheels, posOf(self.offset[1]),
                                       posOf(o), self.sevenBar)
  end
  if stop then
    self.slip[w] = 0
    return
  end
  self:animWheel(w)
end

-- SlotMachine_StopOrAnimWheel3: no slip charges; stops at the next
-- centred position.  Returns true when the spin is over.
function SlotMachine:stopOrAnimWheel3()
  if self.stopping < 3 then
    self:animWheel(3)
    return false
  end
  if self.offset[3] % 2 == 1 then return true end
  self:animWheel(3)
  return false
end

-- SlotMachine_CheckForMatches at the current stops; either resolves the
-- spin or starts a one-symbol wheel-3 roll (stage "reroll").
function SlotMachine:checkForMatches()
  local action, win = SlotMachine.checkForMatch(self.wheels, self:stops(),
                                                self.bet, self.canWin,
                                                self.sevenBar)
  if action == "accept" then
    self:resolveWin(win)
    return
  end
  if action == "nomatch" then
    if not (self.canWin or self.sevenBar) then
      self:resolveLose()
      return
    end
    self.reroll = self.reroll - 1
    if self.reroll == 0 then
      self:resolveLose()
      return
    end
  end
  -- .rollWheel3DownByOneSymbol: two half-steps, one per frame
  self.stage = "reroll"
  self.rerollSteps = 2
end

function SlotMachine:resolveWin(win)
  local sym, pay = win.symbol, win.payout
  -- SlotReward{300,100,8,15}Func side effects run first (before the flash),
  -- and set b = the number of screen flashes.
  local flashes
  if sym == "7" then
    Sound.play(self.game.data, "Get_Item2")
    -- SlotReward300Func: "Yeah!", the jackpot always ends an
    -- allow-matches streak, and half the time resets the luck flags
    if love.math.random(0, 255) >= 128 then
      self.canWin, self.sevenBar = false, false
    end
    self.allowMatchesCounter = 0
    flashes = 20 -- b = $14
  elseif sym == "BAR" then
    Sound.play(self.game.data, "Get_Key_Item")
    -- SlotReward100Func always clears the luck flags
    self.canWin, self.sevenBar = false, false
    flashes = 8 -- b = $8
  else
    -- SlotReward8Func/SlotReward15Func burn one allow-matches charge
    if self.allowMatchesCounter > 0 then
      self.allowMatchesCounter = self.allowMatchesCounter - 1
    end
    flashes = (pay == 8) and 2 or 4 -- b = $2 (cherry) / $4 (15)
  end
  self.win = win
  self.payoutRemaining = pay
  self.payoutDisplay = pay
  -- SlotReward300Func prints "Yeah!" (text_pause) before the flash; the port
  -- shows it in the box while the screen flashes.  LinedUpText follows.
  self.yeah = (sym == "7")
  self.message = ("%s lined up!\nScored %d coins!"):format(sym, pay)
  -- .flashScreenLoop: flip rBGP, wait 5 frames, b times.  The coins are not
  -- credited until the player dismisses the "lined up" text (see startPayout).
  self.stage = "flash"
  self.flashLeft = flashes
  self.flashTimer = 0
  self.flash = false
end

function SlotMachine:resolveLose()
  -- NotThisTimeText, then MainSlotMachineLoop asks "One more go?"
  self.message = "Not this time!"
  self.stage = "message"
  self.afterMessage = "onemore"
end

-- MainSlotMachineLoop restart: reset the ×3/×2/×1 menu (wCurrentMenuItem 0
-- defaults the cursor to ×3) and clear the payout box.
function SlotMachine:enterBet()
  self.stage = "bet"
  self.betIndex = 0
  self.bet = 3
  self.message = nil
  self.payoutDisplay = 0
end

-- OneMoreGoSlotMachineText + its YES/NO menu.
function SlotMachine:enterOneMore()
  self.stage = "onemore"
  self.yesno = 1
  self.message = nil
  self.payoutDisplay = 0
end

-- After a spin resolves: running out of coins ends the session (a 60-frame
-- delay then CloseTextDisplay), otherwise ask "One more go?".
function SlotMachine:afterSpin()
  if coins(self) == 0 then
    self.message = "Darn!\nRan out of coins!"
    self.stage = "message"
    self.afterMessage = nil
    self.exitTimer = 60
  else
    self:enterOneMore()
  end
end

-- SlotMachine_PayCoinsToPlayer: credit one coin every 8 frames (4 for a
-- 7/BAR), a jingle per coin, and flip the object palette every 5 coins.
function SlotMachine:startPayout()
  self.stage = "payout"
  local sym = self.win and self.win.symbol
  self.dripFrames = (sym == "7" or sym == "BAR") and 4 or 8
  self.dripTimer = 0
  self.dripFlash = 5 -- wAnimCounter
  self.flash = false
end

-- YES/NO prompt shared by the intro ("Want to play?") and "One more go?".
function SlotMachine:updateYesNo(onYes)
  local input = self.game.input
  if input:wasPressed("up") or input:wasPressed("down") then
    self.yesno = self.yesno == 1 and 2 or 1
  elseif input:wasPressed("a") then
    Sound.play(self.game.data, "Press_AB")
    if self.yesno == 1 then onYes() else self.game.stack:pop() end
  elseif input:wasPressed("b") then
    Sound.play(self.game.data, "Press_AB")
    self.game.stack:pop()
  end
end

function SlotMachine:update(dt)
  local input = self.game.input
  local save = self.game.save

  if self.stage == "intro" then
    -- PromptUserToPlaySlots: "A slot machine! Want to play?"
    self:updateYesNo(function() self:enterBet() end)
    return
  end

  if self.stage == "message" then
    if self.exitTimer then
      -- OutOfCoinsSlotMachineText: DelayFrames 60, then leave
      self.exitTimer = self.exitTimer - 1
      if self.exitTimer <= 0 then self.game.stack:pop() end
      return
    end
    if input:wasPressed("a") or input:wasPressed("b") then
      Sound.play(self.game.data, "Press_AB")
      local after = self.afterMessage
      self.afterMessage = nil
      if after == "payout" then
        self:startPayout()          -- WaitForTextScrollButtonPress -> pay
      elseif after == "onemore" then
        self:afterSpin()
      else
        self:enterBet()             -- NotEnoughCoinsSlotMachineText -> menu
      end
    end
    return
  end

  if self.stage == "onemore" then
    self:updateYesNo(function() self:enterBet() end)
    return
  end

  if self.stage == "flash" then
    -- .flashScreenLoop: toggle the palette every 5 frames, b times
    self.flashTimer = self.flashTimer + 1
    if self.flashTimer >= 5 then
      self.flashTimer = 0
      self.flash = self.flash and false or "all"
      self.flashLeft = self.flashLeft - 1
      if self.flashLeft <= 0 then
        self.flash = false
        self.stage = "message"
        self.afterMessage = "payout"
      end
    end
    return
  end

  if self.stage == "payout" then
    if (self.payoutRemaining or 0) <= 0 then
      self.flash = false
      self.payoutDisplay = 0
      self:afterSpin()
      return
    end
    self.dripTimer = self.dripTimer + 1
    if self.dripTimer >= self.dripFrames then
      self.dripTimer = 0
      save.coins = math.min(9999, coins(self) + 1)
      self.payoutRemaining = self.payoutRemaining - 1
      self.payoutDisplay = self.payoutRemaining
      Sound.play(self.game.data, "Slots_Reward")
      self.dripFlash = self.dripFlash - 1
      if self.dripFlash <= 0 then
        self.dripFlash = 5
        self.flash = self.flash and false or "reels" -- rOBP0 xor $40 flicker
      end
    end
    return
  end

  if self.stage == "bet" then
    if input:wasPressed("b") then
      self.game.stack:pop()
      return
    end
    -- vertical ×3/×2/×1 menu: UP toward ×3 (betIndex 0), DOWN toward ×1
    if input:wasPressed("up") then self.betIndex = math.max(0, self.betIndex - 1) end
    if input:wasPressed("down") then self.betIndex = math.min(2, self.betIndex + 1) end
    self.bet = 3 - self.betIndex
    if input:wasPressed("a") then
      if coins(self) < self.bet then
        self.message = "Not enough\ncoins!"
        self.afterMessage = "bet"
        self.stage = "message"
        return
      end
      save.coins = coins(self) - self.bet
      self:setFlags()
      self.stopping = 0
      self.slip = { 4, 4 }
      self.reroll = 4
      self.frame = 0
      self.spinupSteps = SPINUP_STEPS
      self.stage = "spinup"
      Sound.play(self.game.data, "Slots_New_Spin")
    end
    return
  end

  if self.stage == "spinup" then
    -- SlotMachine_SpinWheels .loop1: 20 free steps before input is read
    self.frame = self.frame + 1
    if self.frame % STEP_FRAMES == 0 then
      for w = 1, 3 do self:animWheel(w) end
      self.spinupSteps = self.spinupSteps - 1
      if self.spinupSteps == 0 then self.stage = "spin" end
    end
    return
  end

  if self.stage == "spin" then
    -- SlotMachine_HandleInputWhileWheelsSpin: A stops the next wheel,
    -- but is ignored while the previous wheel is still slipping
    if input:wasPressed("a") then
      local held = (self.stopping == 1 and self.slip[1] > 0)
                or (self.stopping == 2 and self.slip[2] > 0)
      if not held then
        self.stopping = self.stopping + 1
        Sound.play(self.game.data, "Slots_Stop_Wheel")
      end
    end
    self.frame = self.frame + 1
    if self.frame % STEP_FRAMES == 0 then
      self:stopOrAnimWheel(1)
      self:stopOrAnimWheel(2)
      if self:stopOrAnimWheel3() then
        self:checkForMatches()
      end
    end
    return
  end

  if self.stage == "reroll" then
    self:animWheel(3)
    self.rerollSteps = self.rerollSteps - 1
    if self.rerollSteps == 0 then
      self:checkForMatches()
    end
    return
  end
end

-- reel symbol screen x (wBaseCoordX $30/$50/$70 minus the OAM 8px offset)
-- and the reel window's vertical clip (rows 4-9 of the machine frame).
local SYM_X = { 40, 72, 104 }
local WIN_TOP, WIN_BOT = 32, 80

-- Lazily load the symbol sheet (symbols.png, OAM wheel tiles) and the static
-- machine frame sheet (red_slots_1.png, a tileCols-wide tile atlas).
function SlotMachine:loadArt()
  local art = self.game.data.field.slotSymbols
  if not art then return nil end
  if not self.symbolImg and not self.symbolImgFailed then
    local ok, img = pcall(love.graphics.newImage, art.sheet)
    if ok then self.symbolImg = img else self.symbolImgFailed = true end
  end
  if art.tilemap and not self.bgImg and not self.bgImgFailed then
    local ok, img = pcall(love.graphics.newImage, art.tilemap.sheet)
    if ok then self.bgImg = img else self.bgImgFailed = true end
  end
  return art
end

-- The three spinning strips over the reel windows.  Each strip scrolls in
-- half-symbol (8px) steps like SlotMachine_AnimWheel; even drawn offsets show
-- three full symbols with wheel[(o+1)/2] on the bottom row.
function SlotMachine:drawReels(art)
  for w = 1, 3 do
    local x = SYM_X[w]
    local wheel = self.wheels[w]
    local period = math.max(#wheel - 3, 1) -- 15 real symbols + 3 wrap entries
    local d = (self.offset[w] - 1) % 30    -- drawn strip offset
    local k = math.floor(d / 2)
    for j = k - 1, k + 3 do
      local yTop = (WIN_BOT - 16) - 16 * j + 8 * d
      local clipTop = math.max(yTop, WIN_TOP)
      local clipBot = math.min(yTop + 16, WIN_BOT)
      if clipBot > clipTop then
        local sym = wheel[(j % period) + 1]
        local rect = self.symbolImg and art.symbols[sym]
        if rect then
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.draw(self.symbolImg,
            love.graphics.newQuad(rect.x, rect.y + (clipTop - yTop),
                                  rect.w, clipBot - clipTop,
                                  self.symbolImg:getDimensions()),
            x, clipTop)
        elseif yTop >= WIN_TOP and yTop + 16 <= WIN_BOT then
          love.graphics.setColor(0, 0, 0, 1)
          Font.draw(SHORT[sym] or sym, x, yTop)
        end
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- The lower dialogue box and, when a prompt is up, the ×3/×2/×1 or YES/NO
-- menu on the right (like MainSlotMachineLoop's TextBoxBorder + menus).
function SlotMachine:drawBottom()
  local lines
  if self.stage == "intro" then
    lines = { "A slot machine!", "Want to play?" }
  elseif self.stage == "bet" then
    lines = { "Bet how many", "coins?" }
  elseif self.stage == "onemore" then
    lines = { "One more", "go?" }
  elseif self.stage == "flash" then
    lines = self.yeah and { "Yeah!" } or { "Start!" }
  elseif self.stage == "spinup" or self.stage == "spin"
         or self.stage == "reroll" then
    lines = { "Start!" }
  elseif self.message then -- message / payout: the wrapped prompt text
    lines = {}
    for line in (self.message .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then lines[#lines + 1] = line end
    end
  end
  if not lines then return end
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(lines[1] or "", 8, 14 * 8)
  Font.draw(lines[2] or "", 8, 16 * 8)
  if self.stage == "bet" then
    Font.drawBox(14, 11, 6, 5)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("×3", 16 * 8, 12 * 8)
    Font.draw("×2", 16 * 8, 13 * 8)
    Font.draw("×1", 16 * 8, 14 * 8)
    Font.drawCode(0xED, 15 * 8, (12 + self.betIndex) * 8)
  elseif self.stage == "intro" or self.stage == "onemore" then
    -- "One more go?" sits at the right of the box (hlcoord 14,12); the longer
    -- "A slot machine!" prompt would clip against it, so the intro's YES/NO
    -- floats above the reels instead.
    local by = self.stage == "intro" and 6 or 11
    Font.drawBox(13, by, 6, 5)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("YES", 15 * 8, (by + 1) * 8)
    Font.draw("NO", 15 * 8, (by + 2) * 8)
    Font.drawCode(0xED, 14 * 8, (by + 1 + (self.yesno == 1 and 0 or 1)) * 8)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function SlotMachine:draw()
  local art = self:loadArt()
  local tm = art and art.tilemap
  if not (tm and self.bgImg) then return self:drawPlain(art) end

  -- static machine frame (SlotMachineMap): blit each tile id from the
  -- red_slots_1.png tile atlas; below it stays white for the dialogue box
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  local iw, ih = self.bgImg:getDimensions()
  self.bgQuads = self.bgQuads or {}
  for row = 1, tm.rows do
    local cells = tm.tiles[row]
    for col = 1, tm.cols do
      local id = cells[col]
      local q = self.bgQuads[id]
      if not q then
        q = love.graphics.newQuad((id % tm.tileCols) * 8,
              math.floor(id / tm.tileCols) * 8, 8, 8, iw, ih)
        self.bgQuads[id] = q
      end
      love.graphics.draw(self.bgImg, q, (col - 1) * 8, (row - 1) * 8)
    end
  end

  self:drawReels(art)

  -- credit / payout numbers (SlotMachine_PrintCreditCoins @5,1 as BCD, and
  -- SlotMachine_PrintPayoutCoins @11,1 with leading zeroes)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 40, 8, 32, 8)
  love.graphics.rectangle("fill", 88, 8, 32, 8)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(("%4d"):format(math.min(9999, coins(self))), 40, 8)
  Font.draw(("%04d"):format(self.payoutDisplay or 0), 88, 8)
  love.graphics.setColor(1, 1, 1, 1)

  self:drawBottom()
end

-- Fallback layout for stale builds without the extracted machine frame.
function SlotMachine:drawPlain(art)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("SLOT MACHINE", 32, 4)
  Font.draw(("COINS %4d"):format(coins(self)), 8, 16)
  if art then self:drawReels(art) end
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(">", 12, 56)
  Font.draw("<", 140, 56)
  love.graphics.setColor(1, 1, 1, 1)
  self:drawBottom()
end

return SlotMachine
