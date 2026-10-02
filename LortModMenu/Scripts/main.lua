--[[
  LORT Mod Menu (UE4SS Lua)
  F1 / Insert ......... open / close the menu
  Up / Down ........... select (also Numpad 8 / 2)
  Left / Right ........ change value (also Numpad 4 / 6)
  Enter ............... toggle / run action (also Numpad 5)
  Delete .............. reset the selected tweak to default

  Single-player / private co-op only. Everything is done through the game's own systems:
  GAS attribute sets (TrySetAttributeBaseValue), the developer cheat extensions that ship in the
  game (BWPlayerCheats, BWGameplayCheats, BWDebugCheats, BWAICheats) and the game's own damage function.
]]

local MOD_DIR = "Mods/LortModMenu/"   -- UE4SS runs with the ue4ss folder as working directory
do
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*[\\/])Scripts[\\/]main%.lua$")
    if dir then MOD_DIR = dir end
end
local LOG_FILE = MOD_DIR .. "menu.log"
local SETTINGS_FILE = MOD_DIR .. "settings.txt"
local SELFTEST_FLAG = MOD_DIR .. "selftest.flag"

---------------------------------------------------------------------------------------------------
-- util
---------------------------------------------------------------------------------------------------
do local f = io.open(LOG_FILE, "w"); if f then f:write("LortModMenu log\n"); f:close() end end
local function log(s)
    print("[LortModMenu] " .. s .. "\n")
    local f = io.open(LOG_FILE, "a")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
end

local function safe(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("ERR " .. name .. ": " .. tostring(err)) end
    return ok, err
end

local function later(ms, fn)
    ExecuteWithDelay(ms, function() ExecuteInGameThread(function() safe("later", fn) end) end)
end

local function valid(o) return o ~= nil and o:IsValid() end
local function addr(o) return valid(o) and o:GetAddress() or 0 end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function near(a, b) return math.abs(a - b) < 1e-3 end

---------------------------------------------------------------------------------------------------
-- game references
---------------------------------------------------------------------------------------------------
local refs = { pcAddr = 0, cheats = {} }

local function getPC()
    local pc = FindFirstOf("BP_PlayerController_C")
    if valid(pc) then return pc end
    pc = FindFirstOf("PlayerController")
    if valid(pc) then return pc end
end

local function getPawn()
    local pc = getPC()
    if not pc then return nil end
    local pawn = pc.Pawn
    if valid(pawn) then return pawn end
end

-- Developer cheat extensions, created with the CheatManager as outer (they find the PC through it).
local CHEAT_CLASSES = {
    player = "/Script/Angelscript.BWPlayerCheats",
    gameplay = "/Script/Angelscript.BWGameplayCheats",
    debug = "/Script/Angelscript.BWDebugCheats",
    ai = "/Script/Angelscript.BWAICheats",
    challenge = "/Script/Angelscript.BWChallengeCheats",
}
local function cheat(kind)
    local pc = getPC()
    if not pc then return nil end
    if addr(pc) ~= refs.pcAddr then refs.pcAddr = addr(pc); refs.cheats = {} end
    local ext = refs.cheats[kind]
    if valid(ext) then return ext end
    local cm = pc.CheatManager
    if not valid(cm) then
        -- the game's CheatClass is BWCheatManager; make one if UE4SS's enabler hasn't yet
        local cls = StaticFindObject("/Script/BWGame.BWCheatManager")
        if valid(cls) then
            cm = StaticConstructObject(cls, pc)
            pc.CheatManager = cm
        end
    end
    if not valid(cm) then return nil end
    local cls = StaticFindObject(CHEAT_CLASSES[kind])
    if not valid(cls) then log("cheat class missing: " .. kind); return nil end
    ext = StaticConstructObject(cls, cm)
    refs.cheats[kind] = ext
    return ext
end

local function toggleStatus(ext, fname)
    -- EBWToggleStatus: On = 0, Off = 1, NoToggle = 2
    local st = ext:GetToggleStatus(FName(fname))
    return st == 0
end

local function damageStatics()
    if not valid(refs.damage) then
        refs.damage = StaticFindObject("/Script/Angelscript.Default__Module_Combat_BWDamageExecutionStatics")
    end
    return refs.damage
end

-- attribute set owned by the player pawn
local function playerSet(cls)
    local pawn = getPawn()
    if not pawn then return nil end
    local pa = addr(pawn)
    for _, s in ipairs(FindAllOf(cls) or {}) do
        if s:IsValid() and addr(s:GetOuter()) == pa then return s end
    end
end

local function enemies()
    local out = {}
    for _, e in ipairs(FindAllOf("BWEnemyCharacter") or {}) do
        if e:IsValid() and not e:GetFullName():find("Default__", 1, true) then out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- attribute overrides: keep the game's original base value, write orig -> desired
---------------------------------------------------------------------------------------------------
local attrState = {}   -- key "Set.Attr" -> { set = addr, orig = n, last = n }

local function applyAttr(cls, name, fn)   -- fn(orig) -> desired, or nil to restore
    local set = playerSet(cls)
    if not set then return end
    local key = cls .. "." .. name
    local base = set[name].BaseValue
    local st = attrState[key]
    if not st or st.set ~= addr(set) then
        st = { set = addr(set), orig = base }
        attrState[key] = st
    elseif st.last and not near(base, st.last) then
        st.orig = base   -- the game changed the base (level up, item): adopt it as the new original
    end
    local desired = fn(st.orig)
    if desired == nil then
        if not near(base, st.orig) then set:TrySetAttributeBaseValue(FName(name), st.orig) end
        attrState[key] = nil
        return
    end
    if not near(base, desired) then set:TrySetAttributeBaseValue(FName(name), desired) end
    st.last = desired
end

local function attrCur(cls, name)
    local set = playerSet(cls)
    if set then return set[name].CurrentValue end
end

local function setAttrBase(cls, name, v)
    local set = playerSet(cls)
    if set then set:TrySetAttributeBaseValue(FName(name), v) end
end

---------------------------------------------------------------------------------------------------
-- cooldowns & skill charges
---------------------------------------------------------------------------------------------------
local function playerASC()
    local pawn = getPawn()
    if not pawn then return nil end
    if valid(refs.asc) and refs.ascPawn == addr(pawn) then return refs.asc end
    local owners = { [addr(pawn)] = true }
    local pc = getPC()
    if pc and valid(pc.PlayerState) then owners[addr(pc.PlayerState)] = true end
    for _, c in ipairs(FindAllOf("BWAbilitySystemComponent") or {}) do
        if c:IsValid() and owners[addr(c:GetOuter())] then
            refs.asc, refs.ascPawn = c, addr(pawn)
            return c
        end
    end
end

local function worldTime()
    local gs = refs.gameplayStatics
    if not valid(gs) then gs = StaticFindObject("/Script/Engine.Default__GameplayStatics"); refs.gameplayStatics = gs end
    return gs:GetTimeSeconds(getPawn())
end

local function hasTag(container, tag)
    local arr = container.GameplayTags
    for i = 1, #arr do if arr[i].TagName:ToString() == tag then return true end end
    return false
end

local cdDefs = {}   -- def address -> { cd = bool, granted = component index }
local function cooldownInfo(def)
    local a = addr(def)
    local info = cdDefs[a]
    if info then return info end
    info = { cd = false }
    local comps = def.GEComponents
    for i = 1, #comps do
        local c = comps[i]
        local cn = c:GetClass():GetFName():ToString()
        if cn == "AssetTagsGameplayEffectComponent" and hasTag(c.InheritableAssetTags.CombinedTags, "Ability.Cooldown") then
            info.cd = true
        elseif cn == "TargetTagsGameplayEffectComponent" then
            info.granted = i
        end
    end
    cdDefs[a] = info
    return info
end

function cutCooldowns(v)
    local asc = playerASC()
    if not asc then return end
    local now = worldTime()
    local effs = asc.ActiveGameplayEffects.GameplayEffects_Internal
    local remove = {}
    for i = 1, #effs do
        local e = effs[i]
        local def = e.Spec.Def
        if valid(def) then
            local info = cooldownInfo(def)
            if info.cd and info.granted then
                local dur = e.Spec.duration
                if v >= 1 or (dur > 0 and now - e.StartWorldTime >= dur * (1 - v)) then
                    remove[#remove + 1] = def.GEComponents[info.granted].InheritableGrantedTagsContainer.CombinedTags
                end
            end
        end
    end
    for _, tags in ipairs(remove) do asc:RemoveActiveEffectsWithGrantedTags(tags) end
end

-- Skill charges regen on their own (about 6 s each). Learn the real regen time, then refill faster.
local chargeState = {}
function fastCharges(v)
    local s = playerSet("BWPlayerAttributes")
    if not s then return end
    local now = worldTime()
    for _, name in ipairs({ "Skill1Charges", "Skill2Charges" }) do
        local key = name .. "@" .. addr(s)
        local st = chargeState[key]
        if not st then st = { max = 0, period = 6, last = nil, drop = nil }; chargeState[key] = st end
        local cur = s[name].CurrentValue
        if cur > st.max then st.max = cur end
        if st.max > 0 then
            if st.last and cur > st.last and not st.ours and st.drop then
                st.period = clamp(now - st.drop, 0.5, 60)   -- the game regenerated one: that's the real period
                st.drop = now
            end
            st.ours = false
            if cur < st.max then
                st.drop = st.drop or now
                if v >= 1 or now - st.drop >= st.period * (1 - v) then
                    local target = (v >= 1) and st.max or (cur + 1)
                    s:TrySetAttributeBaseValue(FName(name), target)
                    st.ours = true
                    st.drop = (target < st.max) and now or nil
                    cur = target
                end
            else
                st.drop = nil
            end
            st.last = cur
        end
    end
end

---------------------------------------------------------------------------------------------------
-- movement / scale overrides (remember originals per pawn)
---------------------------------------------------------------------------------------------------
local moveOrig = { pawn = 0 }
local function moveComp()
    local pawn = getPawn()
    if not pawn then return nil end
    local cm = pawn.CharacterMovement
    if not valid(cm) then return nil end
    if moveOrig.pawn ~= addr(pawn) then
        moveOrig = { pawn = addr(pawn), gravity = cm.GravityScale, jumpZ = cm.JumpZVelocity, applied = {} }
    end
    return cm, pawn
end

---------------------------------------------------------------------------------------------------
-- menu model
---------------------------------------------------------------------------------------------------
local toast   -- forward decl: toast(text, seconds)
local chaos = { on = false, active = nil, overrides = {} }

local function eff(item)
    local o = chaos.overrides[item.id]
    if o ~= nil then return o end
    return item.value
end

local items = {}
local byId = {}
local function add(item) items[#items + 1] = item; if item.id then byId[item.id] = item end; return item end
local function header(text) add({ kind = "header", label = text }) end
local function toggle(id, label, apply, extra)
    local it = { kind = "toggle", id = id, label = label, value = false, default = false, apply = apply }
    for k, v in pairs(extra or {}) do it[k] = v end
    return add(it)
end
local function slider(id, label, default, lo, hi, step, fmt, apply)
    return add({ kind = "slider", id = id, label = label, value = default, default = default, lo = lo, hi = hi,
                 step = step, fmt = fmt, apply = apply })
end
local function action(label, run) return add({ kind = "action", label = label, run = run }) end

local function fmtX(v) return string.format("x%.2g", v) end
local function fmtPct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local function fmtInt(v) return string.format("%d", math.floor(v + 0.5)) end
local function fmtPlus(v) return string.format("+%d%%", math.floor(v * 100 + 0.5)) end

-- cheat toggles: keep the game's state equal to ours. If the game doesn't report a state
-- (NoToggle), track it ourselves and only flip when our wish changes.
local cheatState = {}      -- key -> what we believe the game state is
local untracked = {}       -- fname -> true when GetToggleStatus doesn't follow the cheat
local pendingCheck = {}    -- key -> status reported right before we flipped it
local function syncCheatToggle(kind, fname, want)
    local ext = cheat(kind)
    if not ext then return end
    local key = kind .. "." .. fname .. "@" .. addr(ext)
    local st = ext:GetToggleStatus(FName(fname))
    if pendingCheck[key] ~= nil then
        if st == pendingCheck[key] and not untracked[fname] then
            untracked[fname] = true
            log("toggle " .. fname .. " doesn't report its state (status " .. tostring(st) .. "); tracking it myself")
        end
        pendingCheck[key] = nil
    end
    local on
    if untracked[fname] or (st ~= 0 and st ~= 1) then on = cheatState[key] or false else on = (st == 0) end
    if on ~= want then
        ext[fname](ext)
        cheatState[key] = want
        if not untracked[fname] then pendingCheck[key] = st end
    end
end

---------------------------------------------------------------------------------------------------
header("PLAYER")
toggle("god", "God Mode", function(it) syncCheatToggle("player", "God", eff(it)) end)
-- Dodge = 1 charge by default, refilled by the game after a short delay. Raise the max to 10 and keep it full.
toggle("dodges", "Infinite Dodges", function(it)
    local on = eff(it)
    applyAttr("BWPlayerAttributes", "MaxDodgeCharges", function(o) if not on then return nil end return math.max(o, 10) end)
    if not on then return end
    local s = playerSet("BWPlayerAttributes")
    if s and s.DodgeCharges.CurrentValue < s.MaxDodgeCharges.CurrentValue then
        s:TrySetAttributeBaseValue(FName("DodgeCharges"), s.MaxDodgeCharges.CurrentValue)
    end
end)
toggle("heals", "Infinite Heal Potions", function(it)
    if not eff(it) then return end
    local s = playerSet("BWPlayerAttributes")
    if s and s.HealCharges.CurrentValue < s.MaxHealCharges.CurrentValue then
        s:TrySetAttributeBaseValue(FName("HealCharges"), s.MaxHealCharges.CurrentValue)
    end
end)
slider("maxhp", "Max Health", 1, 1, 20, 0.5, fmtX, function(it)
    local v = eff(it)
    applyAttr("BWHealthAttributes", "MaxHealth", function(o) if v == 1 then return nil end return o * v end)
end)
slider("regen", "Health Regen", 1, 1, 50, 1, fmtX, function(it)
    local v = eff(it)
    applyAttr("BWHealthAttributes", "HealthRegen", function(o) if v == 1 then return nil end return o * v end)
end)
slider("speed", "Move Speed", 0, 0, 3, 0.25, fmtPlus, function(it)
    local v = eff(it)
    applyAttr("BWMovementAttributes", "MoveSpeedIncreaseModifier", function(o) if v == 0 then return nil end return o + v end)
end)
slider("jumps", "Air Jumps", 1, 1, 10, 1, fmtInt, function(it)
    local v = eff(it)
    applyAttr("BWMovementAttributes", "MaxJumpCount", function(o) if v == 1 then return nil end return v end)
end)

header("COMBAT")
slider("dmg", "Damage", 1, 1, 50, 1, fmtX, function(it)
    local v = eff(it)
    applyAttr("BWCombatAttributes", "DamageMultiplier", function(o) if v == 1 then return nil end return o + (v - 1) end)
end)
toggle("onehit", "One-Hit Kills", function(it)
    applyAttr("BWCombatAttributes", "TotalDamageMultiplier", function(o) if not eff(it) then return nil end return o + 999 end)
end)
slider("aspd", "Attack Speed", 1, 1, 4, 0.25, fmtX, function(it)
    local v = eff(it)
    applyAttr("BWCombatAttributes", "AttackSpeedMultiplier", function(o) if v == 1 then return nil end return o * v end)
end)
slider("crit", "Crit Chance", 0, 0, 1, 0.05, function(v) return v == 0 and "game" or fmtPct(v) end, function(it)
    local v = eff(it)
    applyAttr("BWCombatAttributes", "CriticalChance", function(o) if v == 0 then return nil end return v end)
end)
slider("critdmg", "Crit Damage", 0, 0, 10, 0.5, function(v) return v == 0 and "game" or fmtX(v) end, function(it)
    local v = eff(it)
    applyAttr("BWCombatAttributes", "CriticalDamageMultiplier", function(o) if v == 0 then return nil end return v end)
end)
-- Cooldowns in LORT are GameplayEffects with asset tag "Ability.Cooldown" (e.g. GE_Cooldown_Wizard_Ignition,
-- 15 s) that grant a unique tag (Ability.Cooldown.Skill2). The AbilityCooldownReduction attribute doesn't
-- shorten them, so we end each one early: after duration * (1 - reduction) has passed.
-- Skill 1 uses charges (Skill1Charges) that regen on their own; we refill them faster the same way.
slider("cdr", "Cooldown Reduction", 0, 0, 1, 0.1, function(v)
    if v == 0 then return "game" elseif v >= 1 then return "NO COOLDOWNS" end return fmtPct(v)
end, function(it)
    local v = eff(it)
    if v <= 0 then return end
    safe("cooldowns", cutCooldowns, v)
    safe("skill charges", fastCharges, v)
end)

header("FUN")
slider("timescale", "Game Speed", 1, 0.1, 3, 0.1, fmtX, function(it)
    local v = eff(it)
    local pc = getPC()
    if not pc or not valid(pc.CheatManager) then return end
    if not chaos.lastTime or not near(chaos.lastTime, v) then
        pc.CheatManager:Slomo(v)
        chaos.lastTime = v
    end
end)
slider("size", "Player Size", 1, 0.25, 5, 0.25, fmtX, function(it)
    local v = eff(it)
    local cm, pawn = moveComp()
    if not pawn then return end
    if v == 1 and not moveOrig.applied.size then return end
    local s = pawn:GetActorScale3D()
    if not near(s.X, v) then pawn:SetActorScale3D({ X = v, Y = v, Z = v }) end
    moveOrig.applied.size = (v ~= 1) or nil
end)
slider("gravity", "Gravity", 1, 0.1, 3, 0.1, fmtX, function(it)
    local v = eff(it)
    local cm = moveComp()
    if not cm then return end
    local want = moveOrig.gravity * v
    if not near(cm.GravityScale, want) then cm.GravityScale = want end
end)
slider("jumph", "Jump Height", 1, 0.5, 5, 0.25, fmtX, function(it)
    local v = eff(it)
    local cm = moveComp()
    if not cm then return end
    local want = moveOrig.jumpZ * v
    if not near(cm.JumpZVelocity, want) then cm.JumpZVelocity = want end
end)
local enemyScaled = {}
slider("esize", "Enemy Size", 1, 0.25, 4, 0.25, fmtX, function(it)
    local v = eff(it)
    for _, e in ipairs(enemies()) do
        local a = addr(e)
        if v ~= 1 or enemyScaled[a] then
            local s = e:GetActorScale3D()
            local base = enemyScaled[a] or s.X
            enemyScaled[a] = base
            local want = base * v
            if not near(s.X, want) then e:SetActorScale3D({ X = want, Y = want, Z = want }) end
            if v == 1 then enemyScaled[a] = nil end
        end
    end
end)
-- Noclip: flying movement mode + no actor collision. Space = up, Left Ctrl = down, WASD as usual.
local MOVE_FALLING, MOVE_FLYING = 3, 5
local fly = { on = false, pawn = 0 }
local function noclipSet(on)
    local cm, pawn = moveComp()
    if not pawn then return end
    if on then
        if not fly.on or fly.pawn ~= addr(pawn) then
            fly.origFlySpeed = fly.pawn == addr(pawn) and fly.origFlySpeed or cm.MaxFlySpeed
            fly.origBrake = fly.pawn == addr(pawn) and fly.origBrake or cm.BrakingDecelerationFlying
            fly.on, fly.pawn = true, addr(pawn)
            toast("Noclip ON  -  Space up, Ctrl down", 2.5)
        end
        pawn:SetActorEnableCollision(false)
        if cm.MovementMode ~= MOVE_FLYING then cm:SetMovementMode(MOVE_FLYING, 0) end
        local speed = 1000 * (byId.flyspeed and byId.flyspeed.value or 1)
        if not near(cm.MaxFlySpeed, speed) then cm.MaxFlySpeed = speed end
        cm.BrakingDecelerationFlying = 6000
    elseif fly.on then
        fly.on = false
        pawn:SetActorEnableCollision(true)
        if fly.pawn == addr(pawn) then
            if fly.origFlySpeed then cm.MaxFlySpeed = fly.origFlySpeed end
            if fly.origBrake then cm.BrakingDecelerationFlying = fly.origBrake end
        end
        cm:SetMovementMode(MOVE_FALLING, 0)
    end
end
toggle("noclip", "Noclip (fly through walls)", function(it) noclipSet(eff(it)) end)
slider("flyspeed", "Fly Speed", 1, 0.5, 5, 0.5, fmtX, nil)

-- vertical flight, polled fast while noclip is on
local KEY_UP = { KeyName = FName("SpaceBar") }
local KEY_DOWN = { KeyName = FName("LeftControl") }
local FLY_MS = 20
LoopAsync(FLY_MS, function()
    if not fly.on then return false end
    ExecuteInGameThread(function()
        safe("fly", function()
            local pc, pawn = getPC(), getPawn()
            if not pc or not pawn or addr(pawn) ~= fly.pawn then return end
            local dz = 0
            if pc:IsInputKeyDown(KEY_UP) then dz = dz + 1 end
            if pc:IsInputKeyDown(KEY_DOWN) then dz = dz - 1 end
            if dz ~= 0 then
                local step = dz * 1000 * (byId.flyspeed.value or 1) * FLY_MS / 1000
                local l = pawn:K2_GetActorLocation()
                pawn:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + step }, false, {}, true)
            end
        end)
    end)
    return false
end)
toggle("notarget", "Enemies Ignore Me", function(it) syncCheatToggle("ai", "NoTarget", eff(it)) end)
toggle("chaos", "CHAOS MODE", function(it) chaos.on = it.value end)

header("ACTIONS")
action("+1000 Gold", function() cheat("player"):Gold(1000); toast("+1000 Gold") end)
action("+500 Rune Juice", function() cheat("player"):AddRuneJuice(500); toast("+500 Rune Juice") end)
action("Full Heal", function()
    local s = playerSet("BWHealthAttributes")
    if s then s:TrySetAttributeBaseValue(FName("Health"), s.MaxHealth.CurrentValue) end
    toast("Healed")
end)
action("NUKE (everything near you)", function()
    local pawn = getPawn()
    local d = damageStatics()
    if not pawn or not valid(d) then return end
    local loc = pawn:K2_GetActorLocation()
    -- EBWDamageType.Cheat = 4, EBWDamageSourceType.None = 0
    d:ApplyRadialDamage(pawn, loc, 4000.0, 999999.0, 99999.0, 4, 0, 3000.0, 1500.0, pawn)
    toast("NUKE!")
end)
action("Kill All Enemies", function()
    local pawn = getPawn()
    local d = damageStatics()
    if not pawn or not valid(d) then return end
    local n = 0
    for _, e in ipairs(enemies()) do
        safe("kill", function() d:ApplyDamage(pawn, e, 999999.0, 99999.0, 4, 0, 0, { X = 0, Y = 0, Z = 0 }, pawn) end)
        n = n + 1
    end
    toast("Smited " .. n .. " enemies")
end)
action("Open All Chests", function() cheat("gameplay"):OpenAllChests(); toast("Chests opened") end)
action("Give Every Powerup", function() cheat("gameplay"):GiveEveryPowerup(); toast("ALL the powerups") end)
action("Teleport: Boss", function() cheat("player"):Tele2Boss(); toast("To the boss!") end)
action("Teleport: Exit", function() cheat("player"):Tele2Exit(); toast("To the exit") end)
action("Teleport: Shop", function() cheat("player"):Tele2Shop(); toast("To the shop") end)
-- Achievements: every Steam achievement in LORT is tied 1:1 to a challenge (UBWChallenge.AchievementId).
-- Completing challenges through the game's own cheat makes the ChallengeManager write the achievements.
local function achievementStatus()
    local pc = getPC()
    local lib = StaticFindObject("/Script/OnlineSubsystemUtils.Default__AchievementBlueprintLibrary")
    local db = FindFirstOf("BWChallengeDatabase")
    if not pc or not valid(lib) or not valid(db) then return nil end
    local total, unlocked = 0, 0
    local arr = db.Challenges
    for i = 1, #arr do
        local id = arr[i].AchievementId:ToString()
        if id ~= "None" and id ~= "" then
            total = total + 1
            local out = {}
            lib:GetCachedAchievementProgress(pc, pc, FName(id), out, out)
            if out.bFoundID and (out.Progress or 0) >= 100 then unlocked = unlocked + 1 end
        end
    end
    return unlocked, total
end

header("ACHIEVEMENTS")
action("Check Achievements", function()
    local u, t = achievementStatus()
    if u then toast(string.format("Achievements: %d / %d unlocked", u, t), 3) else toast("Achievement data not ready", 2) end
end)
local unlockArmed = 0
action("UNLOCK ALL ACHIEVEMENTS", function()
    if os.clock() > unlockArmed then
        unlockArmed = os.clock() + 4
        toast("Permanent! Also completes all challenges. Press Enter again to confirm", 4)
        return
    end
    unlockArmed = 0
    local ext = cheat("challenge")
    if not ext then toast("Challenge cheats not available", 2); return end
    log("CompleteAllChallenges")
    ext:CompleteAllChallenges()
    local mgr = FindFirstOf("BWChallengeManager")
    if valid(mgr) then later(1500, function() mgr:FlushPendingAchievements(); log("FlushPendingAchievements") end) end
    toast("Unlocking achievements...", 3)
    later(6000, function()
        local u, t = achievementStatus()
        if u then toast(string.format("Achievements: %d / %d unlocked", u, t), 4); log(string.format("achievements after unlock: %d/%d", u, t)) end
    end)
end)

action("Reset All Tweaks", function()
    for _, it in ipairs(items) do if it.default ~= nil then it.value = it.default end end
    toast("All tweaks reset")
end)

---------------------------------------------------------------------------------------------------
-- settings persistence
---------------------------------------------------------------------------------------------------
local function saveSettings()
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return end
    for _, it in ipairs(items) do
        if it.id and it.id ~= "chaos" then f:write(it.id .. "=" .. tostring(it.value) .. "\n") end
    end
    f:close()
end

local function loadSettings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.+)$")
        local it = k and byId[k]
        if it then
            if it.kind == "toggle" then it.value = (v == "true")
            elseif it.kind == "slider" then local n = tonumber(v); if n then it.value = clamp(n, it.lo, it.hi) end end
        end
    end
    f:close()
end

---------------------------------------------------------------------------------------------------
-- chaos mode
---------------------------------------------------------------------------------------------------
local CHAOS_EVENTS = {
    { "SLOW-MO",        { timescale = 0.35 } },
    { "TURBO",          { timescale = 1.8 } },
    { "GIANT",          { size = 3 } },
    { "TINY",           { size = 0.4 } },
    { "MOON GRAVITY",   { gravity = 0.2, jumph = 1.5 } },
    { "HEAVY",          { gravity = 2.5 } },
    { "GIANT ENEMIES",  { esize = 2.5 } },
    { "SHRINK RAY",     { esize = 0.35 } },
    { "BOUNCE HOUSE",   { jumph = 3, jumps = 6 } },
    { "SONIC",          { speed = 3 } },
    { "BERSERK",        { dmg = 10, aspd = 2.5 } },
    { "BIG HEAD MODE... SORT OF", { size = 1.8, esize = 1.8 } },
}
local CHAOS_ON_SEC, CHAOS_GAP_SEC = 12, 8
local chaosClock = 0

local function chaosTick(dt)
    if not chaos.on then
        if chaos.active then chaos.active = nil; chaos.overrides = {} end
        chaosClock = 0
        return
    end
    chaosClock = chaosClock + dt
    if chaos.active then
        if chaosClock >= CHAOS_ON_SEC then
            chaos.active = nil; chaos.overrides = {}; chaosClock = 0
            toast("chaos calms down...", 2)
        end
    elseif chaosClock >= CHAOS_GAP_SEC then
        local ev = CHAOS_EVENTS[math.random(#CHAOS_EVENTS)]
        chaos.active = ev[1]; chaos.overrides = {}
        for k, v in pairs(ev[2]) do chaos.overrides[k] = v end
        chaosClock = 0
        toast("CHAOS: " .. ev[1], 3)
    end
end

---------------------------------------------------------------------------------------------------
-- UI (UMG built from Lua)
---------------------------------------------------------------------------------------------------
local VISIBLE_ROWS = 18
local ui = { open = false, sel = 2, top = 1, rows = {} }
local COL = {
    title = { R = 0.71, G = 1.0, B = 0.23, A = 1 },
    header = { R = 1.0, G = 0.62, B = 0.18, A = 1 },
    item = { R = 0.86, G = 0.86, B = 0.86, A = 1 },
    sel = { R = 1.0, G = 0.95, B = 0.35, A = 1 },
    on = { R = 0.45, G = 1.0, B = 0.45, A = 1 },
    off = { R = 0.55, G = 0.55, B = 0.55, A = 1 },
    changed = { R = 0.45, G = 0.85, B = 1.0, A = 1 },
    hint = { R = 0.6, G = 0.6, B = 0.6, A = 1 },
}
local VIS = { Visible = 0, Collapsed = 1, HitTestInvisible = 3, SelfHitTestInvisible = 4 }

local function C(path) return StaticFindObject(path) end
local function slate(c) return { SpecifiedColor = c, ColorUseRule = 0 } end

local fontObj
local function textBlock(tree, name, size, color, font)
    local t = StaticConstructObject(C("/Script/UMG.TextBlock"), tree, FName(name))
    local f = t.Font
    if font then f.FontObject = font end
    f.Size = size
    t:SetFont(f)
    t:SetColorAndOpacity(slate(color))
    t:SetShadowOffset({ X = 1.5, Y = 1.5 })
    t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
    return t
end

local function buildUI()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return false end
    fontObj = C("/Game/UI/Fonts/Labrada-Font.Labrada-Font")
    if not valid(fontObj) then fontObj = nil end
    local uniq = tostring(math.random(100000, 999999))
    local w = StaticConstructObject(C("/Script/UMG.UserWidget"), gi, FName("LortModMenu_" .. uniq))
    local tree = StaticConstructObject(C("/Script/UMG.WidgetTree"), w, FName("LortTree_" .. uniq))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(C("/Script/UMG.CanvasPanel"), tree, FName("LortCanvas"))
    tree.RootWidget = canvas

    -- menu panel
    local border = StaticConstructObject(C("/Script/UMG.Border"), tree, FName("LortMenuBorder"))
    border:SetBrushColor({ R = 0.015, G = 0.02, B = 0.03, A = 0.86 })
    border:SetPadding({ Left = 22, Top = 16, Right = 26, Bottom = 16 })
    local slot = canvas:AddChildToCanvas(border)
    slot:SetAutoSize(true)
    slot:SetPosition({ X = 50, Y = 110 })
    local vbox = StaticConstructObject(C("/Script/UMG.VerticalBox"), tree, FName("LortMenuVBox"))
    border:SetContent(vbox)

    local title = textBlock(tree, "LortTitle", 26, COL.title, fontObj)
    title:SetText(FText("LORT MOD MENU"))
    vbox:AddChildToVerticalBox(title)
    local sub = textBlock(tree, "LortSub", 13, COL.hint, nil)
    sub:SetText(FText("Up/Down select   Left/Right change   Enter use   Del reset   F1 close"))
    vbox:AddChildToVerticalBox(sub)
    local spacer = textBlock(tree, "LortSpacer", 6, COL.hint, nil)
    spacer:SetText(FText(" "))
    vbox:AddChildToVerticalBox(spacer)

    ui.rows = {}
    for i = 1, VISIBLE_ROWS do
        local h = StaticConstructObject(C("/Script/UMG.HorizontalBox"), tree, FName("LortRow" .. i))
        local l = textBlock(tree, "LortRowL" .. i, 17, COL.item, nil)
        l:SetMinDesiredWidth(300)
        local r = textBlock(tree, "LortRowR" .. i, 17, COL.item, nil)
        r:SetMinDesiredWidth(90)
        h:AddChildToHorizontalBox(l)
        h:AddChildToHorizontalBox(r)
        vbox:AddChildToVerticalBox(h)
        ui.rows[i] = { l = l, r = r }
    end
    ui.status = textBlock(tree, "LortStatus", 13, COL.hint, nil)
    vbox:AddChildToVerticalBox(ui.status)

    -- toast
    local tb = StaticConstructObject(C("/Script/UMG.Border"), tree, FName("LortToastBorder"))
    tb:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.6 })
    tb:SetPadding({ Left = 18, Top = 8, Right = 18, Bottom = 8 })
    local ts = canvas:AddChildToCanvas(tb)
    ts:SetAutoSize(true)
    ts:SetAnchors({ Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } })
    ts:SetAlignment({ X = 0.5, Y = 0.0 })
    ts:SetPosition({ X = 0, Y = 70 })
    local tt = textBlock(tree, "LortToastText", 30, COL.title, fontObj)
    tb:SetContent(tt)

    w:SetVisibility(VIS.HitTestInvisible)
    w:AddToViewport(900)

    ui.widget, ui.panel, ui.toastBorder, ui.toastText = w, border, tb, tt
    ui.toastUntil = 0
    border:SetVisibility(ui.open and VIS.HitTestInvisible or VIS.Collapsed)
    tb:SetVisibility(VIS.Collapsed)
    log("UI built")
    return true
end

local function ensureUI()
    if valid(ui.widget) and valid(ui.panel) and valid(ui.toastText) then return true end
    local ok, res = safe("buildUI", buildUI)
    return ok and res
end

local function valueText(it)
    if it.kind == "toggle" then
        local v = eff(it)
        return v and "ON" or "off", v and COL.on or COL.off
    elseif it.kind == "slider" then
        local v = eff(it)
        local c = near(v, it.default) and COL.off or COL.changed
        if chaos.overrides[it.id] ~= nil then c = COL.header end
        return it.fmt(v), c
    elseif it.kind == "action" then
        return "[Enter]", COL.off
    end
    return "", COL.item
end

local function render()
    if not ui.open or not ensureUI() then return end
    if ui.sel < ui.top then ui.top = ui.sel end
    if ui.sel >= ui.top + VISIBLE_ROWS then ui.top = ui.sel - VISIBLE_ROWS + 1 end
    for i = 1, VISIBLE_ROWS do
        local row = ui.rows[i]
        local it = items[ui.top + i - 1]
        if not it then
            row.l:SetText(FText(" ")); row.r:SetText(FText(" "))
        elseif it.kind == "header" then
            row.l:SetText(FText("— " .. it.label .. " —"))
            row.l:SetColorAndOpacity(slate(COL.header))
            row.r:SetText(FText(" "))
        else
            local selected = (ui.top + i - 1) == ui.sel
            row.l:SetText(FText((selected and "> " or "   ") .. it.label))
            row.l:SetColorAndOpacity(slate(selected and COL.sel or COL.item))
            local vt, vc = valueText(it)
            if selected and it.kind == "slider" then vt = "< " .. vt .. " >" end
            row.r:SetText(FText(vt))
            row.r:SetColorAndOpacity(slate(vc))
        end
    end
    local st = string.format("item %d/%d", ui.sel, #items)
    if chaos.on then st = st .. "   |   chaos: " .. (chaos.active or "waiting...") end
    ui.status:SetText(FText(st))
end

toast = function(text, seconds)
    if not ensureUI() then return end
    ui.toastText:SetText(FText(text))
    ui.toastBorder:SetVisibility(VIS.HitTestInvisible)
    ui.toastUntil = os.clock() + (seconds or 2)
    log("toast: " .. text)
end

local function setOpen(open)
    ui.open = open
    if not ensureUI() then return end
    ui.panel:SetVisibility(open and VIS.HitTestInvisible or VIS.Collapsed)
    if open then render() end
end

---------------------------------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------------------------------
local function moveSel(d)
    local n = #items
    local i = ui.sel
    repeat i = ((i - 1 + d) % n) + 1 until items[i].kind ~= "header"
    ui.sel = i
end

local function change(dir)
    local it = items[ui.sel]
    if not it then return end
    if it.kind == "slider" then
        it.value = clamp(math.floor((it.value + dir * it.step) / it.step + 0.5) * it.step, it.lo, it.hi)
        saveSettings()
    elseif it.kind == "toggle" then
        it.value = not it.value
        saveSettings()
        toast(it.label .. (it.value and ": ON" or ": off"), 1.5)
    end
end

local function activate()
    local it = items[ui.sel]
    if not it then return end
    if it.kind == "action" then safe("action " .. it.label, it.run)
    elseif it.kind == "toggle" then change(1)
    end
end

local function resetSel()
    local it = items[ui.sel]
    if it and it.default ~= nil then it.value = it.default; saveSettings() end
end

local function onKey(fn, needsOpen)
    return function()
        ExecuteInGameThread(function()
            if needsOpen and not ui.open then return end
            safe("key", fn)
            render()
        end)
    end
end

local function bind(key, fn, needsOpen)
    if key then RegisterKeyBind(key, onKey(fn, needsOpen)) end
end

bind(Key.F1, function() setOpen(not ui.open) end, false)
bind(Key.INS, function() setOpen(not ui.open) end, false)
bind(Key.UP_ARROW, function() moveSel(-1) end, true)
bind(Key.DOWN_ARROW, function() moveSel(1) end, true)
bind(Key.LEFT_ARROW, function() change(-1) end, true)
bind(Key.RIGHT_ARROW, function() change(1) end, true)
bind(Key.RETURN, activate, true)
bind(Key.DEL, resetSel, true)
bind(Key.NUM_EIGHT, function() moveSel(-1) end, true)
bind(Key.NUM_TWO, function() moveSel(1) end, true)
bind(Key.NUM_FOUR, function() change(-1) end, true)
bind(Key.NUM_SIX, function() change(1) end, true)
bind(Key.NUM_FIVE, activate, true)

---------------------------------------------------------------------------------------------------
-- main loop: re-apply every tweak (the game resets things on spawn / level change)
---------------------------------------------------------------------------------------------------
local TICK_MS = 250
local lastPawn = 0
local function tick()
    local pawn = getPawn()
    if not pawn then return end
    if addr(pawn) ~= lastPawn then
        lastPawn = addr(pawn)
        attrState = {}
        enemyScaled = {}
        chaos.lastTime = nil
        log("new pawn " .. pawn:GetFullName())
    end
    chaosTick(TICK_MS / 1000)
    for _, it in ipairs(items) do
        if it.apply then safe("apply " .. it.id, it.apply, it) end
    end
    if ui.toastUntil and ui.toastUntil > 0 and os.clock() > ui.toastUntil and valid(ui.toastBorder) then
        ui.toastBorder:SetVisibility(VIS.Collapsed)
        ui.toastUntil = 0
    end
    if ui.open and chaos.on then render() end
end

LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function() safe("tick", tick) end)
    return false
end)

---------------------------------------------------------------------------------------------------
-- self test (only when selftest.flag exists): exercises every item and logs results
---------------------------------------------------------------------------------------------------
local function selfTest()
    log("SELFTEST begin")
    setOpen(true)
    local snap = function(tag)
        local h = playerSet("BWHealthAttributes")
        local c = playerSet("BWCombatAttributes")
        local m = playerSet("BWMovementAttributes")
        local cm, pawn = moveComp()
        log(string.format("[%s] MaxHP=%.1f Regen=%.3f Dmg=%.2f TotDmg=%.1f ASpd=%.2f Crit=%.2f CritD=%.2f CDR=%.2f Jumps=%.0f MoveInc=%.2f Grav=%.2f JumpZ=%.0f Scale=%.2f Gold=%d",
            tag, h.MaxHealth.CurrentValue, h.HealthRegen.CurrentValue, c.DamageMultiplier.CurrentValue, c.TotalDamageMultiplier.CurrentValue,
            c.AttackSpeedMultiplier.CurrentValue, c.CriticalChance.CurrentValue, c.CriticalDamageMultiplier.CurrentValue, c.AbilityCooldownReduction.CurrentValue,
            m.MaxJumpCount.CurrentValue, m.MoveSpeedIncreaseModifier.CurrentValue, cm.GravityScale, cm.JumpZVelocity, pawn:GetActorScale3D().X,
            getPC().PlayerState.PlayerWallet.Gold))
    end
    snap("before")
    local set = { maxhp = 3, regen = 10, speed = 1, jumps = 4, dmg = 5, aspd = 2, crit = 0.5, critdmg = 4, cdr = 0.5,
                  timescale = 0.5, size = 2, gravity = 0.5, jumph = 2, esize = 2 }
    for k, v in pairs(set) do byId[k].value = v end
    for _, k in ipairs({ "god", "dodges", "heals", "onehit", "noclip", "notarget" }) do byId[k].value = true end
    later(1500, function()
        snap("tweaked")
        for _, k in ipairs({ "god", "noclip", "notarget" }) do
            local kind = ({ god = "player", noclip = "debug", notarget = "ai" })[k]
            local fname = ({ god = "God", noclip = "NoClip", notarget = "NoTarget" })[k]
            safe("status " .. k, function() log("toggle " .. k .. " raw status=" .. tostring(cheat(kind):GetToggleStatus(FName(fname))) .. " (0=on 1=off 2=none) untracked=" .. tostring(untracked[fname])) end)
        end
        safe("gold", function() cheat("player"):Gold(1000) end)
        later(1000, function()
            snap("gold+1000")
            for _, it in ipairs(items) do if it.default ~= nil then it.value = it.default end end
            later(1500, function()
                snap("reset")
                for _, k in ipairs({ "god", "noclip", "notarget" }) do
                    local kind = ({ god = "player", noclip = "debug", notarget = "ai" })[k]
                    local fname = ({ god = "God", noclip = "NoClip", notarget = "NoTarget" })[k]
                    safe("status " .. k, function() log("toggle " .. k .. " raw status=" .. tostring(cheat(kind):GetToggleStatus(FName(fname))) .. " (0=on 1=off 2=none) untracked=" .. tostring(untracked[fname])) end)
                end
                -- chaos: force one event right away
                byId.chaos.value = true; chaos.on = true
                chaosTick(CHAOS_GAP_SEC)
                log("chaos active: " .. tostring(chaos.active))
                later(1500, function()
                    snap("chaos")
                    byId.chaos.value = false; chaos.on = false
                    for _, it in ipairs(items) do
                        if it.label == "NUKE (everything near you)" or it.label == "Kill All Enemies" or it.label == "Full Heal" then
                            local ok = safe("action " .. it.label, it.run)
                            log("action " .. it.label .. " ok=" .. tostring(ok))
                        end
                    end
                    log("enemies found: " .. #enemies())
                    later(1500, function()
                        snap("end")
                        saveSettings()
                        toast("self test done", 3)
                        log("SELFTEST end")
                    end)
                end)
            end)
        end)
    end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    later(3000, function()
        ensureUI()
        safe("achievement status", function()
            local u, t = achievementStatus()
            log("achievements: " .. tostring(u) .. "/" .. tostring(t))
        end)
        local f = io.open(SELFTEST_FLAG, "r")
        if f then f:close(); later(2000, selfTest) end
    end)
end)

loadSettings()
math.randomseed(os.time())
log("loaded, " .. #items .. " menu items")
