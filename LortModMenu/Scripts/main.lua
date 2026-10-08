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

local MOD_DIR = "ue4ss/Mods/LortModMenu/"   -- fallback, relative to the game's working dir (Binaries/Win64)
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

-- Everything runs on the game thread. Running Lua from UE4SS's async threads (LoopAsync /
-- ExecuteWithDelay / keybind callbacks) at the same time as the game thread corrupts the Lua state and
-- crashes UE4SS (lua_setiuservalue AV), so this mod only uses the *InGameThread* schedulers.
local function later(ms, fn)
    if ExecuteInGameThreadWithDelay then
        ExecuteInGameThreadWithDelay(ms, function() safe("later", fn) end)
    else
        ExecuteWithDelay(ms, function() ExecuteInGameThread(function() safe("later", fn) end) end)
    end
end

local function gameLoop(ms, fn)
    if LoopInGameThreadWithDelay then
        return LoopInGameThreadWithDelay(ms, function() safe("loop", fn) end)
    end
    LoopAsync(ms, function() ExecuteInGameThread(function() safe("loop", fn) end); return false end)
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
local currentTab = "PLAYER"
local function add(item) item.tab = item.tab or currentTab; items[#items + 1] = item; if item.id then byId[item.id] = item end; return item end
local function header(text) currentTab = text end
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
-- Skills/attacks are animation montages; speed up whichever montage is playing (skip dodge rolls).
slider("skillspeed", "Skill Speed", 1, 1, 10, 1, function(v) return v >= 10 and "INSTANT" or fmtX(v) end, nil)
local animState = { montage = 0, base = 1 }
function animStep()
    local it = byId.skillspeed
    local v = eff(it)
    if v <= 1 then animState.montage = 0; return end
    local pawn = getPawn()
    if not pawn then return end
    local mesh = pawn.Mesh
    if not valid(mesh) then return end
    local ai = mesh:GetAnimInstance()
    if not valid(ai) then return end
    local m = ai:GetCurrentActiveMontage()
    if not valid(m) then animState.montage = 0; return end
    local a = addr(m)
    if a ~= animState.montage then
        animState.montage = a
        animState.skip = m:GetFName():ToString():lower():find("dodge", 1, true) ~= nil
        animState.base = ai:Montage_GetPlayRate(m)
        if animState.base <= 0 then animState.base = 1 end
        animState.seen = (animState.seen or 0) + 1
    end
    if animState.skip then return end
    local rate = animState.base * ((v >= 10) and 25 or v)
    if not near(ai:Montage_GetPlayRate(m), rate) then ai:Montage_SetPlayRate(m, rate) end
end
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
function flyStep(dtMs)
    if not fly.on then return end
    local pc, pawn = getPC(), getPawn()
    if not pc or not pawn or addr(pawn) ~= fly.pawn then return end
    local dz = 0
    if pc:IsInputKeyDown(KEY_UP) then dz = dz + 1 end
    if pc:IsInputKeyDown(KEY_DOWN) then dz = dz - 1 end
    if dz ~= 0 then
        local step = dz * 1000 * (byId.flyspeed.value or 1) * dtMs / 1000
        local l = pawn:K2_GetActorLocation()
        pawn:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + step }, false, {}, true)
    end
end
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

-- Persisting challenge completion. CompleteAllChallenges fires the Steam achievements, but the game never
-- writes the completion to its profile save (Saved/SaveGames/<steamid>/ProfileN*.sav, JSON), so unlocks reset
-- on restart. The game overwrites that file from memory while running, so we record what to add and patch
-- the save on the next launch, before the game loads it (this file runs before the profile is read).
-- Save format: completedChallenges = [challenge guid], unlocks.<kind> = [{"iD": reward id, "guid": challenge guid}].
local PENDING_FILE = MOD_DIR .. "pending_unlocks.txt"
local DIFF_NAMES = { [0] = "Easy", [1] = "Normal", [2] = "Hard", [3] = "Veteran" }
local function guidStr(g) return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF) end

local function newestProfilePrefix()
    -- the active account/profile is the one the game saved most recently
    local root = (os.getenv("LOCALAPPDATA") or "") .. "\\LORT\\Saved\\SaveGames"
    local p = io.popen('dir /b /s /o-d "' .. root .. '\\Profile*.sav" 2>nul')
    if not p then return nil end
    local first = p:read("*l")
    p:close()
    if not first then return nil end
    local dir, prefix = first:match("^(.*)\\(Profile%d+)[^\\]*%.sav$")
    return dir, prefix
end

local function recordPendingUnlocks()
    local db = FindFirstOf("BWChallengeDatabase")
    if not valid(db) then return false end
    local dir, prefix = newestProfilePrefix()
    if not dir then return false end
    local lines = { "DIR " .. dir, "PREFIX " .. prefix }
    local arr = db.Challenges
    for i = 1, #arr do
        local c = arr[i]
        local g = guidStr(c.Guid)
        lines[#lines + 1] = "C " .. g
        local ul = c.Unlocks
        for j = 1, #ul do
            local u = ul[j]
            local cls = u:GetClass():GetFName():ToString()
            local function R(kind, id) lines[#lines + 1] = "R " .. kind .. " " .. g .. " " .. id end
            if cls == "BWUnlock_ItemUnlock" then for k = 1, #u.ItemIds do R("items", u.ItemIds[k].RowName:ToString()) end
            elseif cls == "BWUnlock_PowerupUnlock" then R("powerups", u.PowerupId.RowName:ToString())
            elseif cls == "BWUnlock_SkinUnlock" then R("skins", u.SkinId.RowName:ToString())
            elseif cls == "BWUnlock_QuestUnlock" then R("quests", u.Quest:GetFName():ToString())
            elseif cls == "BWUnlock_RuneJuice" then R("runeJuice", "RuneJuice_" .. guidStr(u.UnlockGuid))
            elseif cls == "BWUnlock_Difficulty" then local d = DIFF_NAMES[u.Difficulty]; if d then R("difficulties", d) end
            end
        end
    end
    local f = io.open(PENDING_FILE, "w")
    if not f then return false end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    log("recorded pending unlocks for " .. dir .. "\\" .. prefix .. " (" .. #arr .. " challenges)")
    return true
end

-- text-level JSON patch (keeps the game's formatting); returns new text, challenges added, rewards added
function patchSaveText(text, challenges, rewardsList)
    local addedC, addedR = 0, 0
    local s, e = text:find('"completedChallenges"%s*:%s*%[')
    if not s then return text, 0, 0 end
    local close = text:find("%]", e + 1, false)
    local body = text:sub(e + 1, close - 1)
    local have = {}
    for g in body:gmatch('"(%x+)"') do have[g] = true end
    local add = {}
    for _, g in ipairs(challenges) do if not have[g] then add[#add + 1] = '\r\n\t\t"' .. g .. '"'; have[g] = true end end
    if #add > 0 then
        local sep = body:find('"') and "," or ""
        local ins = sep .. table.concat(add, ",")
        local trimmed = body:gsub("%s+$", "")
        text = text:sub(1, e) .. trimmed .. ins .. "\r\n\t" .. text:sub(close)
        addedC = #add
    end
    local us = select(2, text:find('"unlocks"%s*:%s*{'))
    if us then
        local byKind = {}
        for _, r in ipairs(rewardsList) do byKind[r.kind] = byKind[r.kind] or {}; table.insert(byKind[r.kind], r) end
        for kind, list in pairs(byKind) do
            local ks, ke = text:find('"' .. kind .. '"%s*:%s*%[', us)
            if ks then
                local kclose = text:find("%]", ke + 1, false)
                local kbody = text:sub(ke + 1, kclose - 1)
                local haveId = {}
                for id in kbody:gmatch('"iD"%s*:%s*"([^"]+)"') do haveId[id] = true end
                local objs = {}
                for _, r in ipairs(list) do
                    if not haveId[r.id] then
                        objs[#objs + 1] = '\r\n\t\t\t{\r\n\t\t\t\t"iD": "' .. r.id .. '",\r\n\t\t\t\t"guid": "' .. r.guid .. '"\r\n\t\t\t}'
                        haveId[r.id] = true
                    end
                end
                if #objs > 0 then
                    local sep = kbody:find("{") and "," or ""
                    local trimmed = kbody:gsub("%s+$", "")
                    text = text:sub(1, ke) .. trimmed .. sep .. table.concat(objs, ",") .. "\r\n\t\t" .. text:sub(kclose)
                    addedR = addedR + #objs
                end
            end
        end
    end
    return text, addedC, addedR
end

local function applyPendingUnlocks()
    local f = io.open(PENDING_FILE, "r")
    if not f then return end
    local dir, prefix, challenges, rewardsList = nil, nil, {}, {}
    for line in f:lines() do
        local k, rest = line:match("^(%S+) (.+)$")
        if k == "DIR" then dir = rest
        elseif k == "PREFIX" then prefix = rest
        elseif k == "C" then challenges[#challenges + 1] = rest
        elseif k == "R" then
            local kind, g, id = rest:match("^(%S+) (%S+) (.+)$")
            if kind then rewardsList[#rewardsList + 1] = { kind = kind, guid = g, id = id } end
        end
    end
    f:close()
    if not dir or not prefix then os.remove(PENDING_FILE); return end
    local p = io.popen('dir /b "' .. dir .. '\\' .. prefix .. '*.sav" 2>nul')
    local patched = 0
    if p then
        for name in p:lines() do
            local path = dir .. "\\" .. name
            local sf = io.open(path, "rb")
            if sf then
                local text = sf:read("*a"); sf:close()
                local newText, ac, ar = patchSaveText(text, challenges, rewardsList)
                if ac + ar > 0 then
                    local bk = io.open(MOD_DIR .. name .. ".before-unlock", "wb"); if bk then bk:write(text); bk:close() end
                    local wf = io.open(path, "wb"); wf:write(newText); wf:close()
                    patched = patched + 1
                end
                log(string.format("save %s: +%d challenges, +%d rewards", name, ac, ar))
            end
        end
        p:close()
    end
    os.remove(PENDING_FILE)
    log("pending unlocks applied to " .. patched .. " save file(s)")
end
safe("apply pending unlocks", applyPendingUnlocks)

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
    local recorded = false
    safe("record unlocks", function() recorded = recordPendingUnlocks() end)
    toast(recorded and "Achievements unlocking... RESTART the game to save all unlocks" or "Unlocking achievements...", 5)
    later(6000, function()
        local u, t = achievementStatus()
        if u then toast(string.format("Achievements: %d / %d unlocked", u, t), 4); log(string.format("achievements after unlock: %d/%d", u, t)) end
    end)
end)

currentTab = "ACTIONS"
action("Reset All Tweaks", function()
    for _, it in ipairs(items) do if it.default ~= nil and it.tab ~= "SETTINGS" then it.value = it.default end end
    toast("All tweaks reset")
end)

---------------------------------------------------------------------------------------------------
-- SETTINGS tab: menu key + per-feature hotkeys
---------------------------------------------------------------------------------------------------
HOTKEYS = {}          -- hotkey id -> FKey name (e.g. "G")
MENU_KEY = "F1"
local hkItems = {}
for _, it in ipairs(items) do
    if it.kind ~= "header" then
        it.hk = it.id or (it.label:gsub("[^%w]", ""))
        hkItems[it.hk] = it
    end
end
local bindables = {}
for _, it in ipairs(items) do
    if (it.kind == "toggle" or it.kind == "action") and it.label ~= "UNLOCK ALL ACHIEVEMENTS" then
        bindables[#bindables + 1] = it
    end
end
currentTab = "SETTINGS"
add({ kind = "keybind", label = "Menu Key", target = "menu" })
slider("menusize", "Menu Size", 1, 0.5, 2, 0.05, function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end, nil).hidden = true   -- zoom kept internally; resize from corners instead
action("Reset Menu Position & Size", function() RESET_PANEL(); toast("Menu reset") end)
action("Clear All Hotkeys", function() HOTKEYS = {}; SAVE_ALL(); toast("All hotkeys cleared") end)
-- one row per bindable feature: click it, press a key (Esc cancel, Backspace / Del clear)
for _, b in ipairs(bindables) do
    add({ kind = "keybind", label = "Hotkey:  " .. b.label, target = b })
end

---------------------------------------------------------------------------------------------------
-- settings persistence
---------------------------------------------------------------------------------------------------
PANEL_POS = { X = 60, Y = 90 }
PANEL_SIZE = { W = 470, H = 390 }   -- row width and list height (window-style resize)
local function saveSettings()
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return end
    for _, it in ipairs(items) do
        if it.id and it.id ~= "chaos" then f:write(it.id .. "=" .. tostring(it.value) .. "\n") end
    end
    f:write("menukey=" .. MENU_KEY .. "\n")
    for hk, key in pairs(HOTKEYS) do f:write("hk_" .. hk .. "=" .. key .. "\n") end
    f:close()
end

local function loadSettings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.+)$")
        if k == "menukey" then MENU_KEY = v end
        if k and k:sub(1, 3) == "hk_" and hkItems[k:sub(4)] then HOTKEYS[k:sub(4)] = v end
        if k == "panelX" or k == "panelY" then local n = tonumber(v); if n then PANEL_POS[k == "panelX" and "X" or "Y"] = n end end
        if k == "panelW" or k == "panelH" then local n = tonumber(v); if n then PANEL_SIZE[k == "panelW" and "W" or "H"] = n end end
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
-- UI: tabbed panel built from UMG widgets, usable with keyboard AND mouse, draggable by its title bar.
-- UE4SS Lua can't bind UMG delegates (OnClicked), so buttons are polled: IsPressed / IsHovered every
-- POLL_MS while the menu is open; a press->release while hovered is a click.
---------------------------------------------------------------------------------------------------
local TABS = { "PLAYER", "COMBAT", "FUN", "ACTIONS", "ACHIEVEMENTS", "SETTINGS" }
local tabItems = {}
for _, t in ipairs(TABS) do tabItems[t] = {} end
for _, it in ipairs(items) do
    if it.kind ~= "header" and not it.hidden and it.tab and tabItems[it.tab] then table.insert(tabItems[it.tab], it) end
end
local ROWS = 1
for _, t in ipairs(TABS) do ROWS = math.max(ROWS, #tabItems[t]) end
local MAX_LIST_HEIGHT = 390   -- ~13 rows, the rest scrolls (mouse wheel / keyboard)

local ui = { open = false, tab = 1, sel = 1, rows = {}, clickables = {}, pos = PANEL_POS }
local function rgba(r, g, b, a) return { R = r, G = g, B = b, A = a or 1 } end
-- Frosted-glass theme: everything is white at different opacities over a blurred background
local COL = {
    title = rgba(1, 1, 1), text = rgba(1, 1, 1), dim = rgba(1, 1, 1, 0.68), dark = rgba(0.09, 0.15, 0.22),
    sel = rgba(1, 0.93, 0.6), changed = rgba(0.6, 0.92, 1.0), chaos = rgba(1.0, 0.68, 0.25),
    glass = rgba(0.06, 0.08, 0.11, 0.42), outline = rgba(1, 1, 1, 0.38), side = rgba(0, 0, 0, 0.25),
    none = rgba(1, 1, 1, 0), navHover = rgba(1, 1, 1, 0.14), navOn = rgba(1, 1, 1, 0.96),
    rowSel = rgba(1, 1, 1, 0.16), rowHover = rgba(1, 1, 1, 0.09),
    pm = rgba(1, 1, 1, 0.24), pmHover = rgba(1, 1, 1, 0.38), pmPress = rgba(1, 1, 1, 0.7),
    on = rgba(0.2, 0.78, 0.35, 1), off = rgba(1, 1, 1, 0.26),
    run = rgba(1.0, 0.42, 0.36, 0.95), runHover = rgba(1.0, 0.56, 0.45, 1), key = rgba(1, 1, 1, 0.22),
    listen = rgba(1.0, 0.68, 0.25, 0.95), close = rgba(1, 0.33, 0.33, 0.92), closeHover = rgba(1, 0.48, 0.48, 1),
    track = rgba(1, 1, 1, 0.26), fill = rgba(1, 1, 1, 0.95),
}
local VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
local HALIGN = { Fill = 0, Left = 1, Center = 2, Right = 3 }
local VALIGN = { Fill = 0, Top = 1, Center = 2, Bottom = 3 }
local TAB_TITLES = { PLAYER = "Player", COMBAT = "Combat", FUN = "Fun", ACTIONS = "Actions", ACHIEVEMENTS = "Achievements", SETTINGS = "Settings" }
local TAB_ICONS = { PLAYER = "player", COMBAT = "combat", FUN = "fun", ACTIONS = "actions", ACHIEVEMENTS = "achievements", SETTINGS = "settings" }
local BAR_W = 84
local ROW_W = 470   -- default row width: labels fill, controls line up on the right edge
local MIN_W, MAX_W, MIN_H, MAX_H = 360, 1000, 150, 900

local function C(path) return StaticFindObject(path) end
local function slate(c) return { SpecifiedColor = c, ColorUseRule = 0 } end
local WHITE = rgba(1, 1, 1, 1)

local fontObj
local nameSeq = 0
local function uname(base) nameSeq = nameSeq + 1; return FName(base .. "_" .. nameSeq) end

-- Rounded corners: edit the brush in place (never pass brush/style structs to a setter: that crashes UE4SS here).
-- radius = number (fixed radius) or "pill" (half-height); corners = {tl,tr,br,bl} optional.
local function roundBrush(brush, radius, corners, outline)
    brush.DrawAs = 4                                   -- ESlateBrushDrawType::RoundedBox
    local o = brush.OutlineSettings
    if radius == "pill" then
        o.RoundingType = 1                             -- HalfHeightRadius
    else
        o.RoundingType = 0                             -- FixedRadius
        local c = corners or { radius, radius, radius, radius }
        o.CornerRadii = { X = c[1], Y = c[2], Z = c[3], W = c[4] }
    end
    if outline then
        o.Width = outline.width
        o.Color = slate(outline.color)
    else
        o.Width = 0
    end
end

local function textBlock(tree, size, color, font, minW)
    local t = StaticConstructObject(C("/Script/UMG.TextBlock"), tree, uname("LortTxt"))
    local f = t.Font
    if font then f.FontObject = font end
    f.Size = size
    t:SetFont(f)
    t:SetColorAndOpacity(slate(color))
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.6 })
    if minW then t:SetMinDesiredWidth(minW) end
    return t
end

-- flat rounded button: state brushes tinted white, colour driven by SetBackgroundColor from the poll loop
local function button(tree, content, pad, halign, radius)
    local b = StaticConstructObject(C("/Script/UMG.Button"), tree, uname("LortBtn"))
    local st = b.WidgetStyle
    for _, k in ipairs({ "Normal", "Hovered", "Pressed" }) do
        st[k].TintColor = slate(WHITE)
        roundBrush(st[k], radius or 9)
    end
    st.NormalPadding = pad
    st.PressedPadding = pad
    -- NOTE: don't call b:SetStyle(st): passing FButtonStyle through UE4SS hard-crashes LORT.
    b.IsFocusable = false
    local slot = b:SetContent(content)
    pcall(function() slot:SetHorizontalAlignment(halign or HALIGN.Left); slot:SetVerticalAlignment(VALIGN.Center) end)
    return b, slot
end

local function hbox(tree) return StaticConstructObject(C("/Script/UMG.HorizontalBox"), tree, uname("LortHB")) end
local function vbox(tree) return StaticConstructObject(C("/Script/UMG.VerticalBox"), tree, uname("LortVB")) end
local function border(tree, color, pad, radius, corners, outline)
    local b = StaticConstructObject(C("/Script/UMG.Border"), tree, uname("LortBorder"))
    if radius then roundBrush(b.Background, radius, corners, outline) end
    b:SetBrushColor(color)
    b:SetPadding(pad)
    return b
end
local function sizeBox(tree, w, h)
    local s = StaticConstructObject(C("/Script/UMG.SizeBox"), tree, uname("LortSize"))
    if w then s:SetWidthOverride(w) end
    if h then s:SetHeightOverride(h) end
    return s
end
local function pad(l, t, r, b) return { Left = l, Top = t, Right = r, Bottom = b } end
local function addH(box, w, padL, valign)
    local s = box:AddChildToHorizontalBox(w)
    pcall(function()
        if padL then s:SetPadding(pad(padL, 0, 0, 0)) end
        s:SetVerticalAlignment(valign or VALIGN.Center)
    end)
    return s
end
local function addV(box, w, padT) local s = box:AddChildToVerticalBox(w); if padT then pcall(function() s:SetPadding(pad(0, padT, 0, 0)) end) end; return s end

local function clickable(c) c.lastColor = nil; c.wasPressed = false; table.insert(ui.clickables, c); return c end

-- icons: white PNGs in <mod>/icons, loaded at runtime with ImportFileAsTexture2D
local function absModDir()
    if MOD_DIR:match("^%a:") then return MOD_DIR end
    local p = io.popen("cd")
    local cwd = p and p:read("*l") or ""
    if p then p:close() end
    return cwd .. "\\" .. MOD_DIR
end
local function iconTexture(name)
    refs.icons = refs.icons or {}
    local t = refs.icons[name]
    if valid(t) then return t end
    local kr = C("/Script/Engine.Default__KismetRenderingLibrary")
    local ctx = getPC() or FindFirstOf("GameInstance")
    local path = (absModDir() .. "icons\\" .. name .. ".png"):gsub("/", "\\")
    local ok, tex = pcall(function() return kr:ImportFileAsTexture2D(ctx, path) end)
    if ok and valid(tex) then refs.icons[name] = tex; return tex end
    log("icon load failed: " .. path)
end

local function buildUI()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return false end
    fontObj = C("/Game/UI/Fonts/Labrada-Font.Labrada-Font")
    if not valid(fontObj) then fontObj = nil end
    ui.clickables, ui.rows, ui.tabs = {}, {}, {}
    local w = StaticConstructObject(C("/Script/UMG.UserWidget"), gi, uname("LortModMenu"))
    local tree = StaticConstructObject(C("/Script/UMG.WidgetTree"), w, uname("LortTree"))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(C("/Script/UMG.CanvasPanel"), tree, uname("LortCanvas"))
    tree.RootWidget = canvas

    -- frosted glass: background blur + translucent white tint + thin outline, all rounded
    local blur = StaticConstructObject(C("/Script/UMG.BackgroundBlur"), tree, uname("LortBlur"))
    safe("blur strength", function() blur.BlurStrength = 14; blur:SetBlurStrength(14) end)
    safe("blur corners", function() blur:SetCornerRadius({ X = 16, Y = 16, Z = 16, W = 16 }) end)
    safe("blur fallback", function()   -- used when the engine forces low-quality blur: smoky tint instead of nothing
        local fb = blur.LowQualityFallbackBrush
        roundBrush(fb, 16)
        fb.TintColor = slate(rgba(0.05, 0.07, 0.1, 0.55))
    end)
    safe("blur cvars", function()
        local ks = C("/Script/Engine.Default__KismetSystemLibrary")
        local ctx = getPC() or gi
        local lq = ks:GetConsoleVariableIntValue("Slate.ForceBackgroundBlurLowQuality")
        log(string.format("blur: strength=%.1f ForceBackgroundBlurLowQuality=%s", blur.BlurStrength, tostring(lq)))
        if lq and lq ~= 0 then
            ks:ExecuteConsoleCommand(ctx, "Slate.ForceBackgroundBlurLowQuality 0", getPC())
            log("blur: forced low quality off -> " .. tostring(ks:GetConsoleVariableIntValue("Slate.ForceBackgroundBlurLowQuality")))
        end
    end)
    local glass = border(tree, COL.glass, pad(0, 0, 0, 0), 16, nil, { width = 1, color = COL.outline })
    local frame = StaticConstructObject(C("/Script/UMG.Overlay"), tree, uname("LortFrame"))
    blur:SetContent(frame)
    local gs = frame:AddChildToOverlay(glass)
    pcall(function() gs:SetHorizontalAlignment(HALIGN.Fill); gs:SetVerticalAlignment(VALIGN.Fill) end)
    ui.frame = frame
    local pslot = canvas:AddChildToCanvas(blur)
    pslot:SetAutoSize(true)
    pslot:SetPosition(ui.pos)
    local layout = hbox(tree)
    glass:SetContent(layout)

    -- sidebar
    local side = border(tree, COL.side, pad(10, 12, 10, 12), 16, { 16, 0, 0, 16 })
    addH(layout, side, nil, VALIGN.Fill)
    local sideCol = vbox(tree)
    side:SetContent(sideCol)
    local brand = textBlock(tree, 17, COL.title, fontObj, 120)
    brand:SetText(FText("LORT  MENU"))
    local brandB = button(tree, brand, pad(6, 2, 6, 10), HALIGN.Left, 8)
    addV(sideCol, brandB)
    pcall(function() brandB:SetCursor(9) end)
    clickable({ btn = brandB, kind = "drag", color = function() return COL.none end })
    for i, name in ipairs(TABS) do
        local row = hbox(tree)
        local img = StaticConstructObject(C("/Script/UMG.Image"), tree, uname("LortIcon"))
        local tex = iconTexture(TAB_ICONS[name])
        if tex then img:SetBrushFromTexture(tex, false) end
        local isz = sizeBox(tree, 17, 17)
        isz:SetContent(img)
        addH(row, isz)
        local t = textBlock(tree, 13, COL.text, nil, 96)
        t:SetText(FText(TAB_TITLES[name]))
        addH(row, t, 9)
        local b = button(tree, row, pad(10, 7, 10, 7), HALIGN.Left, 10)
        addV(sideCol, b, 3)
        ui.tabs[i] = { btn = b, text = t, icon = img }
        clickable({ btn = b, kind = "tab", index = i, color = function(p, h)
            if ui.tab == i then return COL.navOn end
            return (h or p) and COL.navHover or COL.none
        end })
    end

    -- main column
    local main = border(tree, COL.none, pad(14, 10, 12, 8))
    addH(layout, main, nil, VALIGN.Fill)
    local col = vbox(tree)
    main:SetContent(col)

    local head = hbox(tree)
    ui.header = textBlock(tree, 20, COL.title, fontObj, nil)
    local headB = button(tree, ui.header, pad(6, 2, 6, 4), HALIGN.Left, 8)
    local headSlot = addH(head, headB)
    pcall(function() headSlot:SetSize({ SizeRule = 1, Value = 1 }) end)   -- fill: pushes X to the right edge
    pcall(function() headB:SetCursor(9) end)
    clickable({ btn = headB, kind = "drag", color = function() return COL.none end })
    local x = textBlock(tree, 10, COL.title, nil, 10); x:SetText(FText("X")); x:SetJustification(1)
    local closeB = button(tree, x, pad(6, 3, 6, 3), HALIGN.Center, "pill")
    addH(head, closeB, 6)
    clickable({ btn = closeB, kind = "close", color = function(p, h) return (h or p) and COL.closeHover or COL.close end })
    addV(col, head)

    -- rows (scrolling list)
    local rowsBox = vbox(tree)
    local listSize = StaticConstructObject(C("/Script/UMG.SizeBox"), tree, uname("LortListSize"))
    listSize:SetHeightOverride(PANEL_SIZE.H)
    ui.listSize = listSize
    local scroll = StaticConstructObject(C("/Script/UMG.ScrollBox"), tree, uname("LortScroll"))
    scroll:AddChild(rowsBox)
    listSize:SetContent(scroll)
    addV(col, listSize, 6)
    ui.scroll = scroll
    for i = 1, ROWS do
        local r = hbox(tree)
        local label = textBlock(tree, 14, COL.text, nil, nil)
        local rowB = button(tree, label, pad(9, 6, 6, 6), HALIGN.Left, 9)
        local rowSlot = addH(r, rowB)
        pcall(function() rowSlot:SetSize({ SizeRule = 1, Value = 1 }) end)   -- ESlateSizeRule::Fill
        local rowSize = sizeBox(tree, PANEL_SIZE.W, nil)
        rowSize:SetContent(r)
        local row = { box = rowSize, label = label }
        -- slider: [-] [bar] [value] [+]
        local mt = textBlock(tree, 14, COL.title, nil, 8); mt:SetText(FText("-")); mt:SetJustification(1)
        row.minus = button(tree, mt, pad(6, 1, 6, 2), HALIGN.Center, "pill")
        addH(r, row.minus, 6)
        local barBox = sizeBox(tree, BAR_W, 6)
        local track = border(tree, COL.track, pad(0, 0, 0, 0), "pill")
        pcall(function() track:SetHorizontalAlignment(HALIGN.Left); track:SetVerticalAlignment(VALIGN.Fill) end)
        barBox:SetContent(track)
        row.fillBox = sizeBox(tree, BAR_W, 6)
        row.fillBox:SetContent(border(tree, COL.fill, pad(0, 0, 0, 0), "pill"))
        track:SetContent(row.fillBox)
        row.bar = barBox
        addH(r, barBox, 7)
        row.valueText = textBlock(tree, 13, COL.text, nil, 54); row.valueText:SetJustification(1)
        addH(r, row.valueText, 4)
        local pt = textBlock(tree, 14, COL.title, nil, 8); pt:SetText(FText("+")); pt:SetJustification(1)
        row.plus = button(tree, pt, pad(6, 1, 6, 2), HALIGN.Center, "pill")
        addH(r, row.plus, 2)
        -- toggle switch: pill track with a white knob that slides left/right
        local knobBox = sizeBox(tree, 12, 12)
        knobBox:SetContent(border(tree, WHITE, pad(0, 0, 0, 0), "pill"))
        local sw, swSlot = button(tree, knobBox, pad(2, 2, 2, 2), HALIGN.Left, "pill")
        local swBox = sizeBox(tree, 32, 16)
        swBox:SetContent(sw)
        row.switch, row.switchSlot, row.switchBox = sw, swSlot, swBox
        addH(r, swBox, 8)
        -- pill: RUN for actions, the bound key for hotkey rows
        row.pillText = textBlock(tree, 12, COL.title, nil, 44); row.pillText:SetJustification(1)
        row.pill = button(tree, row.pillText, pad(12, 3, 12, 3), HALIGN.Center, "pill")
        addH(r, row.pill, 8)
        addV(rowsBox, rowSize, i > 1 and 2 or nil)
        ui.rows[i] = row
        clickable({ btn = rowB, kind = "row", index = i, color = function(p, h)
            if p or h then return COL.rowHover end
            return (ui.sel == i) and COL.rowSel or COL.none
        end })
        local pmColor = function(p, h) if p then return COL.pmPress end return h and COL.pmHover or COL.pm end
        clickable({ btn = row.minus, kind = "minus", index = i, color = pmColor, repeats = true })
        clickable({ btn = row.plus, kind = "plus", index = i, color = pmColor, repeats = true })
        clickable({ btn = sw, kind = "value", index = i, part = "switch", color = function(p, h)
            local it = row.item
            local on = it and it.kind == "toggle" and eff(it)
            local c = on and COL.on or COL.off
            if h then c = { R = math.min(1, c.R * 1.15), G = math.min(1, c.G * 1.15), B = math.min(1, c.B * 1.15), A = math.min(1, c.A + 0.1) } end
            return c
        end })
        clickable({ btn = row.pill, kind = "value", index = i, part = "pill", color = function(p, h)
            local it = row.item
            if it and it.kind == "keybind" then
                if ui.listen and ui.listen.item == it then return COL.listen end
                return (h or p) and COL.pmHover or COL.key
            end
            return (h or p) and COL.runHover or COL.run
        end })
    end

    -- footer: hint
    local foot = hbox(tree)
    ui.status = textBlock(tree, 10, COL.dim, nil, 300)
    addH(foot, ui.status)
    addV(col, foot, 6)

    -- window grab areas: top edge moves, other edges and all corners resize (with Windows resize cursors)
    local CUR = { LR = 3, UD = 4, SE = 5, SW = 6, MOVE = 9 }
    local HANDLES = {
        { "top",    HALIGN.Fill,  VALIGN.Top,    nil, 9,  0,  0, CUR.MOVE, "drag" },
        { "bottom", HALIGN.Fill,  VALIGN.Bottom, nil, 7,  0,  1, CUR.UD },
        { "left",   HALIGN.Left,  VALIGN.Fill,   7, nil, -1,  0, CUR.LR },
        { "right",  HALIGN.Right, VALIGN.Fill,   7, nil,  1,  0, CUR.LR },
        { "tl",     HALIGN.Left,  VALIGN.Top,   16, 16, -1, -1, CUR.SE },
        { "tr",     HALIGN.Right, VALIGN.Top,   16, 16,  1, -1, CUR.SW },
        { "bl",     HALIGN.Left,  VALIGN.Bottom, 16, 16, -1,  1, CUR.SW },
        { "br",     HALIGN.Right, VALIGN.Bottom, 16, 16,  1,  1, CUR.SE },
    }
    for _, hd in ipairs(HANDLES) do
        local box = sizeBox(tree, hd[4], hd[5])
        local hb = button(tree, box, pad(0, 0, 0, 0), HALIGN.Fill, (hd[4] and hd[5]) and 8 or 4)
        hb:SetBackgroundColor(COL.none)
        pcall(function() hb:SetCursor(hd[8]) end)
        local hs = frame:AddChildToOverlay(hb)
        pcall(function() hs:SetHorizontalAlignment(hd[2]); hs:SetVerticalAlignment(hd[3]) end)
        clickable({ btn = hb, kind = hd[9] or "resize", dx = hd[6], dy = hd[7], color = function() return COL.none end })
    end

    -- toast (also glass)
    local tb = border(tree, rgba(0, 0, 0, 0.45), pad(20, 8, 20, 8), "pill")
    local ts = canvas:AddChildToCanvas(tb)
    ts:SetAutoSize(true)
    ts:SetAnchors({ Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } })
    ts:SetAlignment({ X = 0.5, Y = 0.0 })
    ts:SetPosition({ X = 0, Y = 70 })
    local tt = textBlock(tree, 26, COL.title, fontObj)
    tb:SetContent(tt)

    w:SetVisibility(VIS.SelfHitTestInvisible)
    w:AddToViewport(900)
    ui.widget, ui.panel, ui.panelSlot, ui.toastBorder, ui.toastText = w, blur, pslot, tb, tt
    blur:SetRenderTransformPivot({ X = 0, Y = 0 })
    ui.appliedScale = nil
    ui.toastUntil = 0
    blur:SetVisibility(ui.open and VIS.Visible or VIS.Collapsed)
    tb:SetVisibility(VIS.Collapsed)
    log("UI built (frosted glass, " .. ROWS .. " rows)")
    return true
end

local function ensureUI()
    if valid(ui.widget) and valid(ui.panel) and valid(ui.toastText) then return true end
    local ok, res = safe("buildUI", buildUI)
    return ok and res
end

local function curItems() return tabItems[TABS[ui.tab]] end

local function valueText(it)
    if it.kind == "toggle" then return eff(it) and "ON" or "OFF", WHITE
    elseif it.kind == "slider" then
        local v = eff(it)
        local c = near(v, it.default) and COL.text or COL.changed
        if chaos.overrides[it.id] ~= nil then c = COL.chaos end
        return it.fmt(v), c
    elseif it.kind == "action" then return "RUN", WHITE
    elseif it.kind == "keybind" then
        if ui.listen and ui.listen.item == it then return "press...", COL.title end
        local k = (it.target == "menu") and MENU_KEY or HOTKEYS[it.target.hk]
        return k or "none", k and COL.title or COL.dim
    end
    return "", COL.text
end

function APPLY_SIZE()
    if not valid(ui.listSize) then return end
    ui.listSize:SetHeightOverride(PANEL_SIZE.H)
    for _, row in ipairs(ui.rows) do row.box:SetWidthOverride(PANEL_SIZE.W) end
end

local function applyScale()
    local sc = byId.menusize and byId.menusize.value or 1
    if valid(ui.panel) and (not ui.appliedScale or not near(ui.appliedScale, sc)) then
        ui.panel:SetRenderScale({ X = sc, Y = sc })
        ui.appliedScale = sc
    end
end

local function render()
    if not ui.open or not ensureUI() then return end
    applyScale()
    local list = curItems()
    if ui.sel > #list then ui.sel = #list end
    if ui.sel < 1 then ui.sel = 1 end
    ui.header:SetText(FText(TAB_TITLES[TABS[ui.tab]]))
    for i = 1, ROWS do
        local row = ui.rows[i]
        local it = list[i]
        row.item = it
        if not it then
            row.box:SetVisibility(VIS.Collapsed)
        else
            row.box:SetVisibility(VIS.Visible)
            local lbl = it.label
            local hk = it.hk and HOTKEYS[it.hk]
            if hk then lbl = lbl .. "   [" .. hk .. "]" end
            row.label:SetText(FText(lbl))
            row.label:SetColorAndOpacity(slate(ui.sel == i and COL.sel or COL.text))
            local isSlider, isToggle = it.kind == "slider", it.kind == "toggle"
            local isPill = it.kind == "action" or it.kind == "keybind"
            local sv = isSlider and VIS.Visible or VIS.Collapsed
            row.minus:SetVisibility(sv); row.plus:SetVisibility(sv); row.bar:SetVisibility(sv); row.valueText:SetVisibility(sv)
            row.switchBox:SetVisibility(isToggle and VIS.Visible or VIS.Collapsed)
            row.pill:SetVisibility(isPill and VIS.Visible or VIS.Collapsed)
            local vt, vc = valueText(it)
            if isSlider then
                row.valueText:SetText(FText(vt))
                row.valueText:SetColorAndOpacity(slate(vc))
                local v = eff(it)
                local frac = (it.hi > it.lo) and clamp((v - it.lo) / (it.hi - it.lo), 0, 1) or 0
                row.fillBox:SetWidthOverride(math.max(6, BAR_W * frac))
            elseif isToggle then
                pcall(function() row.switchSlot:SetHorizontalAlignment(eff(it) and HALIGN.Right or HALIGN.Left) end)
            elseif isPill then
                row.pillText:SetText(FText(vt))
                row.pillText:SetColorAndOpacity(slate(vc))
            end
        end
    end
    for i, t in ipairs(ui.tabs) do
        local on = ui.tab == i
        t.text:SetColorAndOpacity(slate(on and COL.dark or COL.text))
        pcall(function() t.icon:SetColorAndOpacity(on and COL.dark or WHITE) end)
    end
    local st = "drag top: move  -  drag edges / corners: resize  -  wheel scroll  -  " .. MENU_KEY .. " close"
    if chaos.on then st = "CHAOS: " .. (chaos.active or "waiting...") .. "   " .. st end
    ui.status:SetText(FText(st))
    -- only poll what's visible: hidden rows/controls are skipped (big win for drag smoothness)
    ui.active = {}
    for _, c in ipairs(ui.clickables) do
        c.lastColor = nil   -- force recolour
        local keep = true
        if c.index and (c.kind == "row" or c.kind == "minus" or c.kind == "plus" or c.kind == "value") then
            local it = ui.rows[c.index] and ui.rows[c.index].item
            if not it then keep = false
            elseif c.kind == "minus" or c.kind == "plus" then keep = it.kind == "slider"
            elseif c.part == "switch" then keep = it.kind == "toggle"
            elseif c.part == "pill" then keep = it.kind == "action" or it.kind == "keybind" end
        end
        if keep then ui.active[#ui.active + 1] = c end
    end
end

toast = function(text, seconds)
    if not ensureUI() then return end
    ui.toastText:SetText(FText(text))
    ui.toastBorder:SetVisibility(VIS.HitTestInvisible)
    ui.toastUntil = os.clock() + (seconds or 2)
    log("toast: " .. text)
end

-- mouse cursor + input mode while the menu is open
local function libs()
    if not valid(refs.wbl) then refs.wbl = C("/Script/UMG.Default__WidgetBlueprintLibrary") end
    if not valid(refs.wll) then refs.wll = C("/Script/UMG.Default__WidgetLayoutLibrary") end
    return refs.wbl, refs.wll
end

local function setMouseMode(on)
    local pc = getPC()
    if not pc then return end
    local wbl = libs()
    if on then
        safe("input mode UI", function() wbl:SetInputMode_GameAndUIEx(pc, ui.panel, 0, false, false) end)
        -- keep keyboard focus on the game viewport: otherwise the focused widget swallows every key and
        -- F1 / hotkeys / key capture (all read via PlayerController:IsInputKeyDown) stop working
        safe("focus game", function() wbl:SetFocusToGameViewport() end)
        pc.bShowMouseCursor = true
        safe("ignore look", function() pc:SetIgnoreLookInput(true) end)
    else
        safe("input mode game", function() wbl:SetInputMode_GameOnly(pc, false) end)
        pc.bShowMouseCursor = false
        safe("reset look", function() pc:ResetIgnoreLookInput() end)
    end
end

local function setOpen(open)
    ui.open = open
    if not ensureUI() then return end
    ui.panel:SetVisibility(open and VIS.Visible or VIS.Collapsed)
    setMouseMode(open)
    ui.dragging = nil
    if open then render() end
end

---------------------------------------------------------------------------------------------------
-- actions on items (shared by keyboard and mouse)
---------------------------------------------------------------------------------------------------
function RESET_PANEL()
    ui.pos = { X = 60, Y = 90 }
    PANEL_SIZE.W, PANEL_SIZE.H = 470, 390
    APPLY_SIZE()
    if byId.menusize then byId.menusize.value = 1 end
    ui.appliedScale = nil
    if valid(ui.panel) then ui.panel:SetRenderScale({ X = 1, Y = 1 }); ui.appliedScale = 1 end
    if valid(ui.panelSlot) then ui.panelSlot:SetPosition(ui.pos) end
    SAVE_ALL()
end
function SAVE_ALL() saveSettings(); local f = io.open(SETTINGS_FILE, "a"); if f then f:write(string.format("panelX=%.0f\npanelY=%.0f\npanelW=%.0f\npanelH=%.0f\n", ui.pos.X, ui.pos.Y, PANEL_SIZE.W, PANEL_SIZE.H)); f:close() end end
local function saveAll() saveSettings(); local f = io.open(SETTINGS_FILE, "a"); if f then f:write(string.format("panelX=%.0f\npanelY=%.0f\npanelW=%.0f\npanelH=%.0f\n", ui.pos.X, ui.pos.Y, PANEL_SIZE.W, PANEL_SIZE.H)); f:close() end end

local function change(it, dir)
    if not it then return end
    if it.kind == "slider" then
        it.value = clamp(math.floor((it.value + dir * it.step) / it.step + 0.5) * it.step, it.lo, it.hi)
        saveAll()
    elseif it.kind == "toggle" then
        it.value = not it.value
        saveAll()
        toast(it.label .. (it.value and ": ON" or ": off"), 1.5)
    end
end

local function activate(it)
    if not it then return end
    if it.kind == "keybind" then
        ui.listen = { item = it, armed = false, prev = {} }
        local what = (it.target == "menu") and "the menu" or it.target.label
        toast("Press a key for " .. what .. "   (Esc cancel, Backspace clear)", 4)
        return
    end
    if it.kind == "action" then safe("action " .. it.label, it.run)
    elseif it.kind == "toggle" then change(it, 1) end
end

local function resetItem(it)
    if it and it.kind == "keybind" and it.target ~= "menu" then
        HOTKEYS[it.target.hk] = nil; SAVE_ALL(); toast("Hotkey cleared: " .. it.target.label, 1.5); return
    end
    if it and it.default ~= nil then it.value = it.default; saveAll() end
end

local function selItem() return curItems()[ui.sel] end
local function scrollToSel()
    local row = ui.rows[ui.sel]
    if valid(ui.scroll) and row then pcall(function() ui.scroll:ScrollWidgetIntoView(row.box, false, 0, 4) end) end
end
local function moveSel(d) local n = #curItems(); if n > 0 then ui.sel = ((ui.sel - 1 + d) % n) + 1 end; scrollToSel() end
local function moveTab(d) ui.tab = ((ui.tab - 1 + d) % #TABS) + 1; ui.sel = 1; if valid(ui.scroll) then ui.scroll:ScrollToStart() end end

---------------------------------------------------------------------------------------------------
-- mouse polling
---------------------------------------------------------------------------------------------------
local POLL_MS = 33
local function sameColor(a, b) return b and near(a.R, b.R) and near(a.G, b.G) and near(a.B, b.B) and near(a.A, b.A) end

local function onClick(c)
    if c.kind == "tab" then ui.tab = c.index; ui.sel = 1; if valid(ui.scroll) then ui.scroll:ScrollToStart() end
    elseif c.kind == "close" then setOpen(false); return
    elseif c.kind == "row" then
        ui.sel = c.index
        local it = curItems()[c.index]
        if it and it.kind ~= "slider" then activate(it) end
    elseif c.kind == "value" then ui.sel = c.index; local it = curItems()[c.index]; if it and it.kind ~= "slider" then activate(it) end
    elseif c.kind == "minus" then ui.sel = c.index; change(curItems()[c.index], -1)
    elseif c.kind == "plus" then ui.sel = c.index; change(curItems()[c.index], 1)
    end
    render()
end

local function mousePos()
    local _, wll = libs()
    local pc = getPC()
    if not pc then return nil end
    local m = wll:GetMousePositionOnViewport(pc)
    return m.X, m.Y
end

-- In this build `widget:IsHovered()` resolves to a bool value instead of the UFunction, so read it
-- defensively; hover only drives highlight colours, clicks never depend on it.
local function hovered(btn)
    local ok, v = pcall(function() return btn.IsHovered end)
    if ok and type(v) == "boolean" then return v end
    if ok and type(v) == "function" then local ok2, r = pcall(v, btn); if ok2 then return r == true end end
    return false
end

local function pollMouse()
    if not ui.open or not valid(ui.panel) then return end
    local pc = getPC()
    if pc and not pc.bShowMouseCursor then pc.bShowMouseCursor = true end
    local now = os.clock()
    local list = ui.active or ui.clickables
    if ui.dragging then list = { ui.dragging.c } elseif ui.resizing then list = { ui.resizing.c } end
    for _, c in ipairs(list) do
        local p = c.btn:IsPressed() == true
        local h = (ui.dragging or ui.resizing) and true or hovered(c.btn)
        -- colour
        local col = c.color(p, h)
        if not sameColor(col, c.lastColor) then c.btn:SetBackgroundColor(col); c.lastColor = col end
        -- drag
        if c.kind == "resize" then
            if p and (not ui.resizing or ui.resizing.c == c) then
                local mx, my = mousePos()
                if mx then
                    if not ui.resizing then
                        ui.resizing = { c = c, mx = mx, my = my, w = PANEL_SIZE.W, h = PANEL_SIZE.H, x = ui.pos.X, y = ui.pos.Y }
                    else
                        local r = ui.resizing
                        local sc = byId.menusize and byId.menusize.value or 1
                        local ddx, ddy = (mx - r.mx) / sc, (my - r.my) / sc
                        local nw, nh = r.w, r.h
                        if c.dx ~= 0 then nw = clamp(r.w + c.dx * ddx, MIN_W, MAX_W) end
                        if c.dy ~= 0 then nh = clamp(r.h + c.dy * ddy, MIN_H, MAX_H) end
                        local nx = (c.dx < 0) and (r.x + (r.w - nw) * sc) or r.x
                        local ny = (c.dy < 0) and (r.y + (r.h - nh) * sc) or r.y
                        if not near(nw, PANEL_SIZE.W) or not near(nh, PANEL_SIZE.H) then
                            PANEL_SIZE.W, PANEL_SIZE.H = nw, nh
                            APPLY_SIZE()
                            ui.pos = { X = nx, Y = ny }
                            ui.panelSlot:SetPosition(ui.pos)
                        end
                    end
                end
            elseif not p and ui.resizing and ui.resizing.c == c then
                ui.resizing = nil
                SAVE_ALL()
            end
        elseif c.kind == "drag" then
            if p and (not ui.dragging or ui.dragging.c == c) then
                local mx, my = mousePos()
                if mx then
                    if not ui.dragging then
                        ui.dragging = { c = c, mx = mx, my = my, x = ui.pos.X, y = ui.pos.Y }
                    else
                        local d = ui.dragging
                        local _, wll = libs()
                        local vs = wll:GetViewportSize(pc)
                        local sc = wll:GetViewportScale(pc)
                        local maxX, maxY = vs.X / sc - 120, vs.Y / sc - 40
                        ui.pos = { X = clamp(d.x + mx - d.mx, -380, maxX), Y = clamp(d.y + my - d.my, 0, maxY) }
                        ui.panelSlot:SetPosition(ui.pos)
                    end
                end
            elseif not p and ui.dragging and ui.dragging.c == c then
                ui.dragging = nil
                saveAll()
            end
        else
            -- click on release while still hovered; arrows auto-repeat while held
            if p then
                if not c.pressStart then c.pressStart = now; c.lastRepeat = now
                elseif c.repeats and now - c.pressStart > 0.4 and now - c.lastRepeat > 0.07 then
                    c.lastRepeat = now; c.repeated = true; onClick(c)
                end
            else
                if c.wasPressed and not c.repeated then onClick(c) end
                c.pressStart, c.repeated = nil, nil
            end
        end
        c.wasPressed = p
    end
end


---------------------------------------------------------------------------------------------------
-- keyboard
---------------------------------------------------------------------------------------------------
-- keys are read on the game thread with PlayerController:IsInputKeyDown (edge-detected)
local KEYS = {
    { "F1", function() end, false, false, true },        -- [1] = menu key: handled by OS keybind (disabled here)
    { "Insert", function() end, false, false, true },    -- handled by OS keybind
    { "Up", function() moveSel(-1) end, true },
    { "Down", function() moveSel(1) end, true },
    { "Left", function() change(selItem(), -1) end, true, true },
    { "Right", function() change(selItem(), 1) end, true, true },
    { "PageUp", function() moveTab(-1) end, true },
    { "PageDown", function() moveTab(1) end, true },
    { "Enter", function() activate(selItem()) end, true },
    { "Delete", function() resetItem(selItem()) end, true },
    { "NumPadEight", function() moveSel(-1) end, true },
    { "NumPadTwo", function() moveSel(1) end, true },
    { "NumPadFour", function() change(selItem(), -1) end, true, true },
    { "NumPadSix", function() change(selItem(), 1) end, true, true },
    { "NumPadSeven", function() moveTab(-1) end, true },
    { "NumPadNine", function() moveTab(1) end, true },
    { "NumPadFive", function() activate(selItem()) end, true },
}
for _, k in ipairs(KEYS) do k.key = { KeyName = FName(k[1]) } end
-- OS-level keybinds for the menu key and key capture. PlayerController:IsInputKeyDown is blind while the
-- game's own UI owns input (main menu, CommonUI screens), so these use UE4SS RegisterKeyBind. The callback
-- only queues work onto the game thread (no game calls on UE4SS's thread), and fires once per key press.
local UE4SS_KEY = {
    Zero = "ZERO", One = "ONE", Two = "TWO", Three = "THREE", Four = "FOUR", Five = "FIVE", Six = "SIX",
    Seven = "SEVEN", Eight = "EIGHT", Nine = "NINE",
    NumPadZero = "NUM_ZERO", NumPadOne = "NUM_ONE", NumPadTwo = "NUM_TWO", NumPadThree = "NUM_THREE",
    NumPadFour = "NUM_FOUR", NumPadFive = "NUM_FIVE", NumPadSix = "NUM_SIX", NumPadSeven = "NUM_SEVEN",
    NumPadEight = "NUM_EIGHT", NumPadNine = "NUM_NINE",
    Insert = "INS", Home = "HOME", End = "END", PageUp = "PAGE_UP", PageDown = "PAGE_DOWN", Delete = "DEL",
    Tab = "TAB", CapsLock = "CAPS_LOCK", Escape = "ESCAPE", BackSpace = "BACKSPACE", Enter = "RETURN",
    Multiply = "MULTIPLY", Add = "ADD", Subtract = "SUBTRACT", Decimal = "DECIMAL", Divide = "DIVIDE",
    Tilde = "OEM_THREE", Hyphen = "OEM_MINUS", Equals = "OEM_PLUS", LeftBracket = "OEM_FOUR",
    RightBracket = "OEM_SIX", Semicolon = "OEM_ONE", Apostrophe = "OEM_SEVEN", Comma = "OEM_COMMA",
    Period = "OEM_PERIOD", Slash = "OEM_TWO", Backslash = "OEM_FIVE",
    MiddleMouseButton = "MIDDLE_MOUSE_BUTTON", ThumbMouseButton = "XBUTTON_ONE", ThumbMouseButton2 = "XBUTTON_TWO",
}
local function ue4ssKey(name)
    local k = UE4SS_KEY[name] or name   -- letters and F1..F12 have the same name
    return Key and Key[k]
end
local osHandlers = {}   -- FKey name -> list of handlers
local osRegistered = {}
local function onOsKey(name, fn)
    osHandlers[name] = osHandlers[name] or {}
    table.insert(osHandlers[name], fn)
    if osRegistered[name] then return end
    local k = ue4ssKey(name)
    if not k then return end
    osRegistered[name] = true
    RegisterKeyBind(k, function()
        ExecuteInGameThread(function()
            for _, h in ipairs(osHandlers[name] or {}) do safe("oskey " .. name, h, name) end
        end)
    end)
end

local lastMenuToggle = 0
local function menuKeyPressed(name)
    if name ~= MENU_KEY and name ~= "Insert" then return end
    if ui.listen then return end                       -- the press is being captured as a binding
    if os.clock() - lastMenuToggle < 0.25 then return end
    lastMenuToggle = os.clock()
    setOpen(not ui.open)
end

function APPLY_MENU_KEY()
    KEYS[1][1] = MENU_KEY; KEYS[1].key = { KeyName = FName(MENU_KEY) }
    onOsKey(MENU_KEY, menuKeyPressed)
end
onOsKey("Insert", menuKeyPressed)

-- keys that can be captured for the menu key / hotkeys
local CAPTURE = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do CAPTURE[#CAPTURE + 1] = c end
for _, n in ipairs({ "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }) do
    CAPTURE[#CAPTURE + 1] = n
    CAPTURE[#CAPTURE + 1] = "NumPad" .. n
end
for i = 1, 12 do CAPTURE[#CAPTURE + 1] = "F" .. i end
for _, n in ipairs({ "Insert", "Home", "End", "PageUp", "PageDown", "Delete", "Tab", "CapsLock", "LeftShift",
    "RightShift", "LeftAlt", "RightAlt", "LeftControl", "RightControl", "Tilde", "Hyphen", "Equals", "LeftBracket",
    "RightBracket", "Semicolon", "Apostrophe", "Comma", "Period", "Slash", "Backslash", "Multiply", "Add",
    "Subtract", "Decimal", "Divide", "MiddleMouseButton", "ThumbMouseButton", "ThumbMouseButton2",
    "Escape", "BackSpace" }) do CAPTURE[#CAPTURE + 1] = n end
local CAPTURE_KEYS = {}
local captureKey   -- forward
for i, n in ipairs(CAPTURE) do CAPTURE_KEYS[i] = { name = n, key = { KeyName = FName(n) } } end

captureKey = function(name)
    local l = ui.listen
    ui.listen = nil
    if name == "Escape" then toast("Cancelled", 1.2); return end
    if l.item.target == "menu" then
        if name == "BackSpace" then name = "F1" end
        MENU_KEY = name
        APPLY_MENU_KEY()
        toast("Menu key: " .. name, 2)
    else
        local b = l.item.target
        if name == "BackSpace" then HOTKEYS[b.hk] = nil; toast("Hotkey cleared: " .. b.label, 2)
        else
            for hk, k in pairs(HOTKEYS) do if k == name then HOTKEYS[hk] = nil end end   -- one feature per key
            HOTKEYS[b.hk] = name
            toast(b.label .. "  ->  [" .. name .. "]", 2)
        end
    end
    SAVE_ALL()
end

for _, n in ipairs(CAPTURE) do
    onOsKey(n, function(name)
        if ui.listen and ui.listen.armed then captureKey(name); render() end
    end)
end

local hkDown = {}
local hkKeyCache = {}
local function fireHotkey(it)
    if it.kind == "toggle" then
        it.value = not it.value
        SAVE_ALL()
        toast(it.label .. (it.value and ": ON" or ": off"), 1.5)
    elseif it.kind == "action" then safe("hotkey " .. it.label, it.run) end
end

local function pollKeys()
    local pc = getPC()
    if not pc then return end
    local now = os.clock()
    -- capturing a key for a binding: wait one frame so the click/Enter that started it isn't captured
    if ui.listen then
        local l = ui.listen
        for _, c in ipairs(CAPTURE_KEYS) do
            local down = pc:IsInputKeyDown(c.key) == true
            if down and l.armed and not l.prev[c.name] then captureKey(c.name); render(); return end
            l.prev[c.name] = down
        end
        l.armed = true
        return
    end
    -- feature hotkeys (work with the menu open or closed)
    for hk, keyName in pairs(HOTKEYS) do
        local it = hkItems[hk]
        if it then
            local kc = hkKeyCache[keyName]
            if not kc then kc = { KeyName = FName(keyName) }; hkKeyCache[keyName] = kc end
            local down = pc:IsInputKeyDown(kc) == true
            if down and not hkDown[hk] then fireHotkey(it); render() end
            hkDown[hk] = down
        end
    end
    for _, k in ipairs(KEYS) do
        if k[5] then goto continue end
        local down = pc:IsInputKeyDown(k.key) == true
        if down and (ui.open or not k[3]) then
            local fire = false
            if not k.down then fire = true; k.t0 = now; k.tr = now
            elseif k[4] and now - k.t0 > 0.4 and now - k.tr > 0.08 then fire = true; k.tr = now end
            if fire then safe("key " .. k[1], k[2]); render() end
        end
        k.down = down
        ::continue::
    end
end

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

-- one game-thread loop drives everything
local FRAME_MS = 16
local tickAcc = 0
local frames = 0
gameLoop(FRAME_MS, function()
    frames = frames + 1
    if frames == 480 then   -- test hook: open.flag opens the menu ~8 s after start, even at the main menu
        local of = io.open(MOD_DIR .. "open.flag", "r")
        if of then of:close(); if not ui.open then safe("open.flag", setOpen, true) end end
    end
    if frames % 2 == 1 or ui.listen then safe("keys", pollKeys) end
    if ui.open and (ui.dragging or ui.resizing or frames % 2 == 0) then safe("mouse", pollMouse) end
    safe("fly", flyStep, FRAME_MS)
    safe("anim", animStep)
    tickAcc = tickAcc + FRAME_MS
    if tickAcc >= TICK_MS then tickAcc = 0; safe("tick", tick) end
end)
log("scheduler: " .. (LoopInGameThreadWithDelay and "LoopInGameThreadWithDelay" or "LoopAsync fallback"))

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
        local of = io.open(MOD_DIR .. "open.flag", "r")
        if of then of:close(); setOpen(true) end
        local f = io.open(SELFTEST_FLAG, "r")
        if f then f:close(); later(2000, selfTest) end
    end)
end)

loadSettings()
APPLY_MENU_KEY()
math.randomseed(os.time())
log("loaded, " .. #items .. " menu items")
