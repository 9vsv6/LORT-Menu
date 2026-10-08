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
-- ATTACK SIZE
-- Projectiles: every ABWProjectile (arrows, orbs, daggers, bombs, mines...) fired by the player gets its actor
-- scaled (collider + mesh + fx) and its explosion DamageRadius scaled to match.
local projDone = {}          -- projectile address -> true (already scaled)
local projSweep = 0
function projectileStep()
    local v = byId.projsize and eff(byId.projsize) or 1
    if v == 1 then return end
    local pawn = getPawn()
    if not pawn then return end
    local pa, pc = addr(pawn), addr(getPC())
    projSweep = projSweep + 1
    if projSweep > 600 then projDone = {}; projSweep = 0 end
    for _, pr in ipairs(FindAllOf("BWProjectile") or {}) do
        local a = addr(pr)
        if a ~= 0 and not projDone[a] then
            projDone[a] = true
            pcall(function()
                local mine = false
                pcall(function() mine = addr(pr:GetInstigator()) == pa end)
                if not mine then pcall(function() local o = pr:GetOwner(); mine = addr(o) == pa or addr(o) == pc end) end
                if mine and not pr:GetFullName():find("Default__", 1, true) then
                    local sc = pr:GetActorScale3D()
                    pr:SetActorScale3D({ X = sc.X * v, Y = sc.Y * v, Z = sc.Z * v })
                    pcall(function() if pr.DamageRadius and pr.DamageRadius > 0 then pr.DamageRadius = pr.DamageRadius * v end end)
                end
            end)
        end
    end
end
slider("projsize", "Projectile Size", 1, 1, 5, 0.25, fmtX, nil)

-- Melee: player swings are UBWAnimNotify_MeleeAttack notifies (enemies use BWAnimNotify_NPCMeleeAttack),
-- each with an FBWDamageShape. Scale radius / box / arc / offset from the stored originals.
local meleeOrig = {}
slider("meleesize", "Melee Range", 1, 1, 4, 0.25, fmtX, function(it)
    local v = eff(it)
    for _, n in ipairs(FindAllOf("BWAnimNotify_MeleeAttack") or {}) do
        local a = addr(n)
        if a ~= 0 then
            pcall(function()
                local sh = n.DamageShape
                local o = meleeOrig[a]
                if not o then
                    if v == 1 then return end
                    o = { r = sh.Radius, hh = sh.HalfHeight, ar = sh.ArcRadius, af = sh.ArcForwardOffset,
                          bx = sh.BoxExtent.X, by = sh.BoxExtent.Y, bz = sh.BoxExtent.Z,
                          lx = sh.RelativeLocationOffset.X, ly = sh.RelativeLocationOffset.Y, lz = sh.RelativeLocationOffset.Z, v = 1 }
                    meleeOrig[a] = o
                end
                if near(o.v, v) then return end
                sh.Radius = o.r * v; sh.HalfHeight = o.hh * v; sh.ArcRadius = o.ar * v; sh.ArcForwardOffset = o.af * v
                sh.BoxExtent = { X = o.bx * v, Y = o.by * v, Z = o.bz * v }
                sh.RelativeLocationOffset = { X = o.lx * v, Y = o.ly * v, Z = o.lz * v }
                o.v = v
            end)
        end
    end
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
-- FOV: PlayerController:FOV(angle) locks the camera manager's FOV (overrides the game camera); FOV(0) unlocks.
local fovState = { applied = nil, pc = 0 }
toggle("fovon", "Custom FOV", function(it)
    local pc = getPC()
    if not pc then return end
    local want = eff(it) and math.floor(byId.fov.value + 0.5) or 0
    if fovState.pc ~= addr(pc) then fovState.pc = addr(pc); fovState.applied = nil end
    if want == 0 and (fovState.applied == nil or fovState.applied == 0) then fovState.applied = 0; return end
    if fovState.applied ~= want then
        pc:FOV(want)
        fovState.applied = want
    end
end)
slider("fov", "FOV Angle", 100, 60, 150, 5, function(v) return string.format("%d", math.floor(v + 0.5)) end, nil)

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
-- BIG HEAD: ABP_Player has FAnimNode_ModifyBone nodes. Point one at the "Head" bone with a replace-scale,
-- then bounce the mesh LOD so the anim graph re-caches its bone references (CacheBones -> InitializeBoneReferences).
local bigHead = { applied = nil, ai = 0, orig = nil, lodStep = 0 }
local function headNode(ai)
    local n
    pcall(function() n = ai.AnimGraphNode_ModifyBone_1 end)
    return n
end
local function bigHeadStep(on, scale)
    local pawn = getPawn()
    if not pawn then return end
    local mesh = pawn.Mesh
    if not valid(mesh) then return end
    local ai = mesh:GetAnimInstance()
    if not valid(ai) then return end
    local node = headNode(ai)
    if not node then return end
    if bigHead.ai ~= addr(ai) then
        bigHead.ai = addr(ai); bigHead.applied = nil
        bigHead.orig = {
            bone = node.BoneToModify.BoneName:ToString(), sx = node.Scale.X, sy = node.Scale.Y, sz = node.Scale.Z,
            mode = node.ScaleMode, space = node.ScaleSpace, alphaType = node.AlphaInputType, alpha = node.Alpha,
        }
        log(string.format("bighead: node bone=%s scale=%.2f mode=%s space=%s alpha=%.2f", bigHead.orig.bone, bigHead.orig.sx,
            tostring(bigHead.orig.mode), tostring(bigHead.orig.space), bigHead.orig.alpha))
    end
    local want = on and scale or 0
    if bigHead.applied == want then
        if bigHead.lodStep == 1 then mesh:SetForcedLOD(0); bigHead.lodStep = 0 end   -- second half of the LOD bounce
        return
    end
    local o = bigHead.orig
    if on then
        node.BoneToModify.BoneName = FName("Head")
        node.Scale = { X = scale, Y = scale, Z = scale }
        node.ScaleMode = 1          -- BMM_Replace
        node.ScaleSpace = 3         -- BCS_BoneSpace
        node.AlphaInputType = 0     -- Float
        node.Alpha = 1
    else
        node.BoneToModify.BoneName = FName(o.bone)
        node.Scale = { X = o.sx, Y = o.sy, Z = o.sz }
        node.ScaleMode = o.mode; node.ScaleSpace = o.space
        node.AlphaInputType = o.alphaType; node.Alpha = o.alpha
    end
    mesh:SetForcedLOD(2)            -- LOD change -> required bones recalculated -> node bone index re-cached
    bigHead.lodStep = 1
    bigHead.applied = want
end
toggle("bighead", "Big Head Mode", function(it)
    bigHeadStep(eff(it), byId.headsize and byId.headsize.value or 2.5)
end)
slider("headsize", "Head Size", 2.5, 1.5, 5, 0.25, fmtX, nil)

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

-- SPAWNER: give any weapon / powerup / item. IDs are the row names of the game's DataTables
-- (PlayerItems_Equipment, PowerupsTable, PlayerItems_*), read from memory with tools/rowdump.py.
local SPAWN_WEAPONS = {
    "Weapon_Crossbow",
    "Weapon_Broadsword",
    "Weapon_Sledgehammer",
    "Weapon_Spinhammer",
    "Weapon_ArcaneStaff",
    "Weapon_LightningWand",
    "Weapon_MagicSword",
    "Weapon_Swiftbow",
    "Weapon_Strongbow",
    "Weapon_Blinkblades",
    "Weapon_Pistol",
    "Weapon_ClubShield",
    "Weapon_AssaultRifle",
    "Weapon_BaseballBat",
    "Weapon_SwordShield",
    "Weapon_Monsterhammer",
    "Weapon_Katana",
    "Weapon_ThrowingDaggers",
    "Weapon_HolyClaymore",
    "Weapon_VoidCrossbow",
    "Weapon_VoidWand",
    "Weapon_VoidStaff",
}
local SPAWN_POWERUPS = {
    "powerup_strength",
    "powerup_agility",
    "powerup_intelligence",
    "powerup_attackspeed",
    "powerup_damageboost",
    "powerup_increasedhealth",
    "powerup_increasedmovementspeed",
    "powerup_jumpheight",
    "powerup_thorns",
    "powerup_bulwark",
    "powerup_critchance",
    "powerup_parrychance",
    "powerup_armor",
    "powerup_magicresist",
    "powerup_cooldownrate",
    "powerup_healingreceived",
    "powerup_damage_stunned",
    "powerup_lifesteal",
    "powerup_healonkill",
    "powerup_extraskillcharge",
    "powerup_healoncrit",
    "powerup_maxhealthonkill",
    "powerup_burningonhit",
    "powerup_stunonhit",
    "powerup_slowonhit",
    "powerup_healthregen",
    "powerup_knockback",
    "powerup_critdamage",
    "powerup_spawngoldonhit",
    "powerup_block",
    "powerup_increasedamagelowhealth",
    "powerup_bigdamage",
    "powerup_increasedamageclose",
    "powerup_healcharge",
    "powerup_increasedsprintspeed",
    "powerup_spawngoldoncrit",
    "powerup_spawngoldondmgreceived",
    "powerup_bonustohighhpenemies",
    "powerup_bonusdmgtoboss",
    "powerup_secondchance",
    "powerup_bonusdmgtofactiongoblin",
    "powerup_bonusdmgtofactionskeleton",
    "powerup_bonusdmgtofactionslime",
    "powerup_increasedrunandsprint",
    "powerup_clapback",
    "powerup_critchancecritdmg",
    "powerup_magicdamageboost",
    "powerup_physicaldamageboost",
    "powerup_bleedonhit",
    "powerup_maxphysresistonhurt",
    "powerup_increasedmgonkill",
    "powerup_increaseatkspeedonkill",
    "powerup_electricityonhit",
    "powerup_buffchanceonhitatkspeed",
    "powerup_buffchanceonhitmovementspeed",
    "powerup_bonusdmgduringnight",
    "powerup_bonusdmgduringday",
    "powerup_damageonkillexplosion",
    "powerup_healonkillaoe",
    "powerup_slowonhurt",
    "powerup_buffchanceonabilityhitcritdamage",
    "powerup_buffchanceonabilityhitparry",
    "powerup_damageonhitaoe",
    "powerup_cursedcritchancecritdamage",
    "powerup_increasestatusduration",
    "powerup_pinball",
    "powerup_pingpongslow",
    "powerup_pingpongfire",
    "powerup_spawnpickuponkillhealth",
    "powerup_spawnpickuponkillmovespeed",
    "powerup_spawnpickuponkillcrit",
    "powerup_lightningstrike",
    "powerup_bigcritdamage",
    "powerup_bigcooldownrate",
    "powerup_explodeonhit",
    "powerup_sunder",
    "powerup_bigtank",
    "powerup_aura_pulsedamage",
    "powerup_aura_tickdamage",
    "powerup_aura_armorbuff",
    "powerup_aura_movespeedliferegen",
    "powerup_aura_lifesteal",
    "powerup_bonusdmgtobeards",
    "powerup_bonusdmgtowearinghats",
    "powerup_bonusdmgtocasters",
    "powerup_bonusdmgtofighters",
    "powerup_bigcritchance",
    "powerup_bonustohighhpenemiesbig",
    "powerup_hybriddamageboost",
    "powerup_increasedhealthmedium",
    "powerup_increasedhealthbig",
    "powerup_buffchanceonhitmagicalphysical",
    "powerup_healthregencurse",
    "powerup_increasedamageability",
    "powerup_increasedamageovertime",
    "powerup_damageonkillburning",
    "powerup_dodgecharge",
    "powerup_magicalsunder",
    "powerup_poisononhit",
    "powerup_buffonability_movementspeed",
    "powerup_mediumdamageproc",
    "powerup_aoedamageoncrit",
    "powerup_spawnmineonability",
    "powerup_lilcritdamage",
    "powerup_lilcooldownrate",
}
local SPAWN_ITEMS = {
    "Item_Key_POI_Foot",
    "Item_Key_WeaponChest",
    "Item_Key_POI_MushroomTower",
    "Item_Key_POI_MushroomMadness",
    "Item_Key_POI_Labyrinth",
    "item_tooter_bone",
    "item_tooter_grand",
    "Quest_Minibosses_Onion",
    "Quest_Ingredient",
    "Quest_EggEgg",
    "Quest_EndingThing_Incomplete",
    "Quest_RangerPictures_01",
    "Quest_RangerPictures_02",
    "Quest_RangerPictures_03",
    "Quest_RangerPictures_04",
    "item_trash_rottenegg",
    "item_trash_rock",
    "item_trash_brick",
    "item_trash_beatpad",
    "item_trash_football",
    "item_trash_soccerball",
    "item_trash_basketball",
    "item_trash_volleyball",
}

-- powerup ids are run-together lowercase words: split them greedily with a small game dictionary
local WORDS = {}
for w in ([[bonus dmg damage to faction goblin skeleton slime boss beards wearing hats casters fighters
    high hp enemies enemy big lil medium increase increased max health on hit kill crit chance critical
    speed attack atk move movement sprint run and jump height heal healing received
    regen life steal thorns bulwark parry armor magic magical physical hybrid resist resistance
    hurt cooldown rate extra skill block low close stunned stun slow burning burn bleed poison electricity
    lightning strike explode explosion knockback spawn gold pickup second clap back cursed
    curse status duration pinball ping pong fire sunder tank aura pulse tick buff ability over time night
    day mine proc aoe strength agility intelligence boost dodge during ingredient trash rotten egg
    rock brick beat pad football soccer ball basketball volleyball tooter bone grand key poi foot weapon
    chest mushroom tower madness labyrinth minibosses onion ending thing incomplete ranger pictures]]):gmatch("%a+") do
    WORDS[w] = true
end
local function splitWords(t)
    -- optimal split: known words cost 1, each unknown letter costs 4 (fewest unknown letters wins)
    local n = #t
    local cost, prev = { [0] = 0 }, {}
    for i = 1, n do
        cost[i] = cost[i - 1] + 4; prev[i] = i - 1
        for j = 1, i do
            if WORDS[t:sub(j, i)] and cost[j - 1] + 1 < cost[i] then cost[i] = cost[j - 1] + 1; prev[i] = j - 1 end
        end
    end
    local parts, i, buf = {}, n, ""
    while i > 0 do
        local j = prev[i]
        local w = t:sub(j + 1, i)
        if i - j == 1 and not WORDS[w] then buf = w .. buf
        else
            if buf ~= "" then table.insert(parts, 1, buf); buf = "" end
            table.insert(parts, 1, w)
        end
        i = j
    end
    if buf ~= "" then table.insert(parts, 1, buf) end
    return table.concat(parts, " ")
end

local function prettyId(id)
    local t = id:gsub("^Weapon_", ""):gsub("^powerup_", ""):gsub("^[Ii]tem_", ""):gsub("^Quest_", "Quest ")
    t = t:gsub("(%l)(%u)", "%1 %2")
    local parts = {}
    for w in t:gmatch("[^_%s]+") do
        parts[#parts + 1] = (w:match("^%l+$") and splitWords(w) or w)
    end
    t = table.concat(parts, " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
    return (t:gsub("%f[%a]Hp%f[%A]", "HP"):gsub("%f[%a]Aoe%f[%A]", "AoE"):gsub("%f[%a]Poi%f[%A]", "POI"))
end

local function giveItem(id, count)
    local lvl = math.floor(byId.spawnlevel and byId.spawnlevel.value or 1)
    cheat("player"):AddItemToInventory(FName(id), count or 1, lvl)
end
local function givePowerup(id) cheat("gameplay"):GivePowerup(id) end

local SPAWN_MONSTERS = {
    "boss_ranger",
    "boss_forestsoul",
    "boss_stomper",
    "boss_necromancer",
    "Boss_Lich",
    "Boss_Stewart",
    "GoblinTreasure_Gold",
    "GoblinTreasure_Powerup",
    "GoblinTreasure_RuneJuice",
    "GoblinTreasure_Weapon",
    "GoblinMage",
    "GoblinPeasant",
    "GoblinTrapper",
    "GoblinArcher",
    "GoblinFighter",
    "GoblinBrawler",
    "GoblinLobber",
    "GoblinSlimecaller",
    "GoblinThief",
    "GoblinWarchief",
    "GoblinBomber",
    "GoblinPoacher",
    "GoblinWizard",
    "GoblinArbalest",
    "GoblinShield",
    "GoblinWarrior",
    "GoblinDefender",
    "GoblinSlimemancer",
    "GoblinSharpshooter",
    "GoblinSmusher",
    "GoblinWarlord",
    "Slime",
    "SlimeBoss",
    "SlimeFire",
    "SlimeViking",
    "SpiritBalaclava",
    "SpiritSquidhelmet",
    "trailerman",
    "wraith",
    "Ghost",
    "Goblin",
    "GoblinLieutenantMap1",
    "SlimeKing",
    "GoblinSniper",
    "GoblinChampion",
    "GoblinMedic",
    "GoblinBubbler",
    "GoblinRifleman",
    "GoblinFisherman",
    "InsectMosquito",
    "SpiritSnowball",
    "SlimeForest",
    "GoblinSkeletonFodder",
    "GoblinLieutenantFodder",
    "SpiritFodder",
    "TrollSapper",
}
local function spawnMonster(id)
    local n = math.floor(byId.spawncount and byId.spawncount.value or 1)
    cheat("gameplay"):Spawn(id, n)
end

-- tile grids shown under a section's rows: GRIDS[tab] = { { title, list, onClick(id) }, ... }
GRIDS = {
    MODEL = { { "Character models loaded right now  (click to wear; enter a run for more enemies)", {}, nil, dynamic = true } },
    WEAPONS = { { "All weapons  (click to get one)", SPAWN_WEAPONS, function(id) giveItem(id, 1); toast("Gave: " .. prettyId(id), 1.4) end } },
    ITEMS = {
        { "Powerups", SPAWN_POWERUPS, function(id) givePowerup(id); toast("Powerup: " .. prettyId(id), 1.4) end },
        { "Items", SPAWN_ITEMS, function(id) giveItem(id, 1); toast("Gave: " .. prettyId(id), 1.4) end },
    },
    MONSTERS = { { "Monsters & bosses  (spawned near you)", SPAWN_MONSTERS, function(id)
        spawnMonster(id)
        toast("Spawned " .. math.floor(byId.spawncount.value) .. "x " .. prettyId(id), 1.6)
    end } },
}

header("WEAPONS")
slider("spawnlevel", "Item Level", 1, 1, 30, 1, fmtInt, nil)
action("Give All Weapons", function()
    for _, id in ipairs(SPAWN_WEAPONS) do safe("give " .. id, giveItem, id, 1) end
    toast("All " .. #SPAWN_WEAPONS .. " weapons given", 2)
end)
action("Random Weapon", function()
    local id = SPAWN_WEAPONS[math.random(#SPAWN_WEAPONS)]
    giveItem(id, 1); toast("Random weapon: " .. prettyId(id), 2)
end)

header("ITEMS")
action("Random Powerup", function()
    local id = SPAWN_POWERUPS[math.random(#SPAWN_POWERUPS)]
    givePowerup(id); toast("Random powerup: " .. prettyId(id), 2)
end)
action("Give 5 Random Powerups", function()
    for _ = 1, 5 do safe("powerup", givePowerup, SPAWN_POWERUPS[math.random(#SPAWN_POWERUPS)]) end
    toast("5 random powerups!", 2)
end)
action("Give Every Powerup ", function() cheat("gameplay"):GiveEveryPowerup(); toast("ALL the powerups") end)

header("MONSTERS")
slider("spawncount", "Spawn Count", 1, 1, 20, 1, fmtInt, nil)
action("Spawn Random Boss", function()
    local bosses = {}
    for _, id in ipairs(SPAWN_MONSTERS) do if id:lower():find("boss") or id:find("King") then bosses[#bosses + 1] = id end end
    local id = bosses[math.random(#bosses)]
    spawnMonster(id); toast("BOSS: " .. prettyId(id), 2)
end)
action("Kill Everything ", function()
    local pawn, d = getPawn(), damageStatics()
    if not pawn or not valid(d) then return end
    local n = 0
    for _, e in ipairs(enemies()) do
        safe("kill", function() d:ApplyDamage(pawn, e, 999999.0, 99999.0, 4, 0, 0, { X = 0, Y = 0, Z = 0 }, pawn) end)
        n = n + 1
    end
    toast("Smited " .. n .. " enemies")
end)

-- MODEL: wear any character model the game has loaded (USkeletalMeshComponent::SetSkeletalMeshAsset).
-- Hero meshes are loaded on demand; everything else = whatever is in memory right now (camp NPCs, enemies near you).
local HERO_MESHES = {
    { "Wizard", "/Game/Art/Characters/Wizard/SK_Player_Wizard.SK_Player_Wizard" },
    { "Warrior", "/Game/Art/Characters/Warrior/SK_Player_Warrior.SK_Player_Warrior" },
    { "Ranger", "/Game/Art/Characters/Ranger/SK_Player_Ranger.SK_Player_Ranger" },
    { "Rogue", "/Game/Art/Characters/Rogue/SK_Player_Rogue_01.SK_Player_Rogue_01" },
    { "Paladin", "/Game/Art/Characters/Paladin/SK_Player_Paladin.SK_Player_Paladin" },
}
local modelState = { orig = nil }
MODEL_ENTRIES = {}

local function loadMesh(path)
    local m = StaticFindObject(path)
    if not valid(m) and LoadAsset then pcall(function() m = LoadAsset(path) end) end
    if valid(m) then return m end
end

local function meshLabel(name)
    local t = name:gsub("^SK_", ""):gsub("^LORT_", ""):gsub("^Player_", ""):gsub("_0%d$", "")
    return (t:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"))
end

function LIST_MODELS()
    local list, seen = {}, {}
    local function add(mesh, label, hero)
        local key = mesh:GetFullName()
        if seen[key] then return end
        seen[key] = true
        list[#list + 1] = { key = key, mesh = mesh, label = label, hero = hero }
    end
    for _, h in ipairs(HERO_MESHES) do
        local m = loadMesh(h[2])
        if m then add(m, h[1] .. " (hero)", true) end
    end
    for _, m in ipairs(FindAllOf("SkeletalMesh") or {}) do
        if valid(m) then
            local full = m:GetFullName()
            if full:find("/Game/Art/Characters/", 1, true) and not full:find("Default__", 1, true) then
                add(m, meshLabel(m:GetFName():ToString()), false)
            end
        end
    end
    -- remember which animation setup each model's real owner uses (for "Use Model's Own Animations")
    for _, c in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
        pcall(function()
            local a = c:GetSkeletalMeshAsset()
            if valid(a) then
                local key = a:GetFullName()
                for _, e in ipairs(list) do
                    if e.key == key and not e.animClass then
                        local ai = c:GetAnimInstance()
                        if valid(ai) then e.animClass = ai:GetClass() end
                    end
                end
            end
        end)
    end
    MODEL_ENTRIES = {}
    for _, e in ipairs(list) do MODEL_ENTRIES[e.key] = e end
    return list
end

-- The worn model is a second SkeletalMeshComponent that copies the hero's pose every frame
-- (SetLeaderPoseComponent, bones matched by name). The real hero mesh keeps animating but is hidden, so every
-- model moves with the selected hero's animations, and weapons stay attached to the hero's hand bones.
local function heroMesh(pawn) return pawn.Mesh end

local function ensureFollower(pawn)
    local f = modelState.follower
    if valid(f) and modelState.followerPawn == addr(pawn) then return f end
    local cls = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    f = pawn:AddComponentByClass(cls, true, { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    if not valid(f) then return nil end
    f:K2_AttachToComponent(heroMesh(pawn), FName("None"), 2, 2, 2, false)   -- SnapToTarget for location/rotation/scale
    modelState.follower, modelState.followerPawn = f, addr(pawn)
    return f
end

function WEAR_MODEL(key)
    local e = MODEL_ENTRIES[key]
    local pawn = getPawn()
    if not e or not pawn or not valid(e.mesh) then return end
    local hero = heroMesh(pawn)
    local f = ensureFollower(pawn)
    if not f then toast("Couldn't create the model", 2); return end
    f:SetSkeletalMeshAsset(e.mesh)
    pcall(function()
        local mats = e.mesh.Materials
        for i = 1, #mats do
            local mi = mats[i].MaterialInterface
            if valid(mi) then f:SetMaterial(i - 1, mi) end
        end
    end)
    f:SetLeaderPoseComponent(hero, true, false)
    hero.VisibilityBasedAnimTickOption = 0      -- AlwaysTickPoseAndRefreshBones: keep animating while hidden
    hero:SetVisibility(false, false)            -- hide the hero body only (not weapons / attachments)
    f:SetVisibility(true, false)
    modelState.wearing = e.key
    toast("Now wearing: " .. e.label, 1.8)
    log("model -> " .. e.key)
end

-- re-wear the chosen model after respawn / level change (new pawn = new hero mesh)
function MODEL_KEEP(apply)
    if not modelState.wearing then return false end
    if apply then
        modelState.follower = nil
        local key = modelState.wearing
        if not MODEL_ENTRIES[key] then LIST_MODELS() end
        WEAR_MODEL(key)
    end
    return true
end

local function resetModel()
    local pawn = getPawn()
    if not pawn then return end
    local f = modelState.follower
    if valid(f) then pcall(function() f:SetVisibility(false, false); f:K2_DestroyComponent(f) end) end
    modelState.follower = nil
    heroMesh(pawn):SetVisibility(true, false)
    modelState.wearing = nil
    toast("Back to your hero", 1.6)
end

header("MODEL")
action("Back To My Hero", resetModel)
action("Wear Random Model", function()
    local list = LIST_MODELS()
    if #list > 0 then WEAR_MODEL(list[math.random(#list)].key) end
end)
action("Refresh Model List", function() if REFRESH_MODELS then REFRESH_MODELS() end; toast("Model list refreshed", 1.2) end)

header("RUN")
action("Next Level", function() cheat("player"):DepartLevel(FName("")); toast("Leaving level...", 2) end)
slider("skiplevel", "Skip To Level", 2, 1, 8, 1, fmtInt, nil)
action("Go To That Level", function()
    local n = math.floor(byId.skiplevel.value)
    cheat("gameplay"):SkipToLevel(n); toast("Skipping to level " .. n, 2)
end)
action("Teleport: Boss ", function() cheat("player"):Tele2Boss(); toast("To the boss!") end)
action("Teleport: Exit ", function() cheat("player"):Tele2Exit(); toast("To the exit") end)
action("Teleport: Shop ", function() cheat("player"):Tele2Shop(); toast("To the shop") end)
action("Complete Landmark", function() cheat("gameplay"):CompleteLandmark(); toast("Landmark completed") end)
action("End Run (extract)", function() cheat("gameplay"):StartExtraction(); toast("Extraction started", 2) end)
action("Restart (die)", function() cheat("player"):KillSelf(); toast("Respawning...", 2) end)

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
local TABS = { "PLAYER", "COMBAT", "FUN", "MODEL", "ACTIONS", "RUN", "WEAPONS", "ITEMS", "MONSTERS", "ACHIEVEMENTS", "SETTINGS" }
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
local TAB_TITLES = { PLAYER = "Player", COMBAT = "Combat", FUN = "Fun", ACTIONS = "Actions", MODEL = "Model", RUN = "Run", WEAPONS = "Weapons", ITEMS = "Items", MONSTERS = "Monsters", ACHIEVEMENTS = "Achievements", SETTINGS = "Settings" }
local TAB_ICONS = { PLAYER = "player", COMBAT = "combat", FUN = "fun", ACTIONS = "actions", MODEL = "model", RUN = "run", WEAPONS = "weapons", ITEMS = "spawner", MONSTERS = "monsters", ACHIEVEMENTS = "achievements", SETTINGS = "settings" }
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
        local barBox = sizeBox(tree, BAR_W, 6)          -- the visible track (also used for hit geometry)
        local track = border(tree, COL.track, pad(0, 0, 0, 0), "pill")
        pcall(function() track:SetHorizontalAlignment(HALIGN.Left); track:SetVerticalAlignment(VALIGN.Fill) end)
        barBox:SetContent(track)
        row.fillBox = sizeBox(tree, BAR_W, 6)
        row.fillBox:SetContent(border(tree, COL.fill, pad(0, 0, 0, 0), "pill"))
        track:SetContent(row.fillBox)
        local hitHolder = border(tree, COL.none, pad(0, 0, 0, 0))
        pcall(function() hitHolder:SetVerticalAlignment(VALIGN.Center); hitHolder:SetHorizontalAlignment(HALIGN.Fill) end)
        hitHolder:SetContent(barBox)
        local hitBox = sizeBox(tree, BAR_W, 20)          -- taller invisible click area
        hitBox:SetContent(hitHolder)
        local barBtn = button(tree, hitBox, pad(0, 0, 0, 0), HALIGN.Fill, 4)
        barBtn:SetBackgroundColor(COL.none)
        row.bar, row.track = barBtn, barBox
        addH(r, barBtn, 7)
        clickable({ btn = barBtn, kind = "bar", index = i, color = function() return COL.none end })
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

    -- tile grids (Weapons / Items / Monsters). Tiles get their hover/press look from the button's own
    -- state tints (no per-frame hover polling), so 100+ tiles stay cheap.
    ui.grids, ui.gridBoxes, ui.dynGrids = {}, {}, {}
    ui.tree = tree
    for _, tabName in ipairs(TABS) do
        local defs = GRIDS[tabName]
        if defs then
            local sec = vbox(tree)
            for gi2, g in ipairs(defs) do
                local ht = textBlock(tree, 13, COL.dim, nil, nil)
                ht:SetText(FText(g[1]))
                addV(sec, ht, gi2 == 1 and 10 or 14)
                local wb = StaticConstructObject(C("/Script/UMG.WrapBox"), tree, uname("LortGrid"))
                pcall(function() wb:SetInnerSlotPadding({ X = 6, Y = 6 }) end)
                local wsize = sizeBox(tree, PANEL_SIZE.W, nil)
                wsize:SetContent(wb)
                ui.gridBoxes[#ui.gridBoxes + 1] = wsize
                addV(sec, wsize, 6)
                if g.dynamic then ui.dynGrids = ui.dynGrids or {}; ui.dynGrids[tabName] = wb end
                for _, id in ipairs(g[2]) do
                    local tt = textBlock(tree, 12, COL.text, nil, nil)
                    tt:SetText(FText(prettyId(id)))
                    local tb2 = button(tree, tt, pad(10, 6, 10, 6), HALIGN.Center, 8)
                    local st = tb2.WidgetStyle
                    st.Hovered.TintColor = slate(rgba(1.9, 1.9, 1.9, 1.9))
                    st.Pressed.TintColor = slate(rgba(3.2, 3.2, 3.2, 3.2))
                    tb2:SetBackgroundColor(rgba(1, 1, 1, 0.12))
                    wb:AddChildToWrapBox(tb2)
                    local onTile = g[3]
                    clickable({ btn = tb2, kind = "tile", tab = tabName, id = id, run = function() onTile(id) end,
                        noHover = true, color = function() return rgba(1, 1, 1, 0.12) end })
                end
            end
            addV(rowsBox, sec, 4)
            sec:SetVisibility(VIS.Collapsed)
            ui.grids[tabName] = sec
        end
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

function REFRESH_MODELS()
    local wb = ui.dynGrids and ui.dynGrids.MODEL
    if not valid(wb) or not valid(ui.tree) then return end
    wb:ClearChildren()
    local keep = {}
    for _, c in ipairs(ui.clickables) do if not (c.kind == "tile" and c.tab == "MODEL") then keep[#keep + 1] = c end end
    ui.clickables = keep
    local list = LIST_MODELS()
    for _, e in ipairs(list) do
        local tt = textBlock(ui.tree, 12, COL.text, nil, nil)
        tt:SetText(FText(e.label))
        local tb2 = button(ui.tree, tt, pad(10, 6, 10, 6), HALIGN.Center, 8)
        local st = tb2.WidgetStyle
        st.Hovered.TintColor = slate(rgba(1.9, 1.9, 1.9, 1.9))
        st.Pressed.TintColor = slate(rgba(3.2, 3.2, 3.2, 3.2))
        tb2:SetBackgroundColor(e.hero and rgba(0.55, 0.85, 1, 0.22) or rgba(1, 1, 1, 0.12))
        wb:AddChildToWrapBox(tb2)
        local key = e.key
        clickable({ btn = tb2, kind = "tile", tab = "MODEL", id = e.label, run = function() WEAR_MODEL(key) end,
            noHover = true, color = function() return e.hero and rgba(0.55, 0.85, 1, 0.22) or rgba(1, 1, 1, 0.12) end })
    end
    log("model list: " .. #list .. " models")
    if RENDER then RENDER() end
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
    for _, gb in ipairs(ui.gridBoxes or {}) do gb:SetWidthOverride(PANEL_SIZE.W) end
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
            local isPill = it.kind == "action" or it.kind == "keybind" or it.picker
            local sv = isSlider and VIS.Visible or VIS.Collapsed
            row.minus:SetVisibility(sv); row.plus:SetVisibility(sv); row.valueText:SetVisibility(sv)
            row.bar:SetVisibility((isSlider and not it.picker) and VIS.Visible or VIS.Collapsed)
            row.switchBox:SetVisibility(isToggle and VIS.Visible or VIS.Collapsed)
            row.pill:SetVisibility(isPill and VIS.Visible or VIS.Collapsed)
            local vt, vc = valueText(it)
            if it.picker then
                row.pillText:SetText(FText("GIVE"))
                row.pillText:SetColorAndOpacity(slate(WHITE))
            end
            if isSlider then
                row.valueText:SetText(FText(vt))
                row.valueText:SetColorAndOpacity(slate(vc))
                local v = eff(it)
                local frac = (it.hi > it.lo) and clamp((v - it.lo) / (it.hi - it.lo), 0, 1) or 0
                row.fillBox:SetWidthOverride(math.max(6, BAR_W * frac))
            elseif isToggle then
                pcall(function() row.switchSlot:SetHorizontalAlignment(eff(it) and HALIGN.Right or HALIGN.Left) end)
            elseif isPill and not it.picker then
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
    for tabName, sec in pairs(ui.grids or {}) do
        sec:SetVisibility(tabName == TABS[ui.tab] and VIS.Visible or VIS.Collapsed)
    end
    -- only poll what's visible: hidden rows/controls are skipped (big win for drag smoothness)
    ui.active = {}
    for _, c in ipairs(ui.clickables) do
        c.lastColor = nil   -- force recolour
        local keep = true
        if c.index and (c.kind == "row" or c.kind == "minus" or c.kind == "plus" or c.kind == "value" or c.kind == "bar") then
            local it = ui.rows[c.index] and ui.rows[c.index].item
            if not it then keep = false
            elseif c.kind == "minus" or c.kind == "plus" then keep = it.kind == "slider"
            elseif c.kind == "bar" then keep = it.kind == "slider" and not it.picker
            elseif c.part == "switch" then keep = it.kind == "toggle"
            elseif c.part == "pill" then keep = it.kind == "action" or it.kind == "keybind" or it.picker == true end
        end
        if c.kind == "tile" then keep = (c.tab == TABS[ui.tab]) end
        if keep then ui.active[#ui.active + 1] = c end
    end
end

RENDER = render

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
    if it.picker then safe("give", it.give); return end
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
local function moveTab(d) ui.tab = ((ui.tab - 1 + d) % #TABS) + 1; ui.sel = 1; if TABS[ui.tab] == "MODEL" then safe("models", REFRESH_MODELS) end; if valid(ui.scroll) then ui.scroll:ScrollToStart() end end

---------------------------------------------------------------------------------------------------
-- mouse polling
---------------------------------------------------------------------------------------------------
local POLL_MS = 33
local function sameColor(a, b) return b and near(a.R, b.R) and near(a.G, b.G) and near(a.B, b.B) and near(a.A, b.A) end

local function onClick(c)
    if c.kind == "tile" then safe("tile " .. c.id, c.run); return end
    if c.kind == "tab" then ui.tab = c.index; ui.sel = 1; if TABS[ui.tab] == "MODEL" then safe("models", REFRESH_MODELS) end; if valid(ui.scroll) then ui.scroll:ScrollToStart() end
    elseif c.kind == "close" then setOpen(false); return
    elseif c.kind == "row" then
        ui.sel = c.index
        local it = curItems()[c.index]
        if it and it.kind ~= "slider" then activate(it) end
    elseif c.kind == "value" then ui.sel = c.index; local it = curItems()[c.index]; if it and (it.kind ~= "slider" or (it.picker and c.part == "pill")) then activate(it) end
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
    if ui.dragging then list = { ui.dragging.c } elseif ui.resizing then list = { ui.resizing.c }
    elseif ui.barDrag then list = { ui.barDrag.c } end
    for _, c in ipairs(list) do
        local p = c.btn:IsPressed() == true
        local h = (ui.dragging or ui.resizing or c.noHover) and true or hovered(c.btn)
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
        elseif c.kind == "bar" then
            if p and (not ui.barDrag or ui.barDrag.c == c) then
                ui.barDrag = ui.barDrag or { c = c }
                local row = ui.rows[c.index]
                local it = row and row.item
                if it and it.kind == "slider" then
                    local frac
                    local okg = pcall(function()
                        local sbl = refs.sbl
                        if not valid(sbl) then sbl = C("/Script/UMG.Default__SlateBlueprintLibrary"); refs.sbl = sbl end
                        local _, wll = libs()
                        local first = not refs.barChecked
                        if first then log("bar: geometry") end
                        local g = row.track:GetCachedGeometry()
                        if first then log("bar: mouse") end
                        local m = wll:GetMousePositionOnPlatform()
                        if first then log("bar: AbsoluteToLocal") end
                        local loc = sbl:AbsoluteToLocal(g, m)
                        local size = sbl:GetLocalSize(g)
                        if first then refs.barChecked = true; log(string.format("bar: ok local=%.1f size=%.1f", loc.X, size.X)) end
                        if size.X > 1 then frac = clamp(loc.X / size.X, 0, 1) end
                    end)
                    if okg and frac then
                        local v = it.lo + frac * (it.hi - it.lo)
                        v = clamp(math.floor(v / it.step + 0.5) * it.step, it.lo, it.hi)
                        if not near(v, it.value) then it.value = v; ui.sel = c.index; render() end
                    end
                end
            elseif not p and ui.barDrag and ui.barDrag.c == c then
                ui.barDrag = nil
                saveAll()
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
        if MODEL_KEEP and MODEL_KEEP() then later(1500, function() MODEL_KEEP(true) end) end
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
    if ui.open and (ui.dragging or ui.resizing or ui.barDrag or frames % 2 == 0) then safe("mouse", pollMouse) end
    safe("fly", flyStep, FRAME_MS)
    safe("anim", animStep)
    if frames % 2 == 1 then safe("projectiles", projectileStep) end
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
