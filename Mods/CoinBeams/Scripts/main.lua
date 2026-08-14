-- CoinBeams: Borderlands/Diablo-style vertical loot beams over rare (gold) and
-- epic (purple) package loot spots. Short, subtle shafts of light rising a few
-- inches above the coin - visible across a room without dominating the scene.
-- Grain Rot ("Helden", UE 5.7) + UE4SS experimental.
--
-- Visual design:
--   * Beam = engine cylinder mesh (/Engine/BasicShapes/Cylinder, confirmed loaded
--     in shipping) scaled to a thin column, attached to the loot spot root.
--   * Material = the game's own M_FakeLight (translucent fake-light-shaft family;
--     the pre-tinted MI_FakeLight_White/Orange/Red instances prove it takes a
--     color parameter). We build a MaterialInstanceDynamic per rarity and tint it
--     HDR-boosted so bloom gives the beam a soft glow core.
--   * Color parameter name is DISCOVERED at runtime by reading the tinted
--     instances' VectorParameterValues (plain reflected TArray - safe, unlike the
--     Niagara parameter store). Unknown names no-op safely, so we also spray a
--     list of common candidates.
--
-- Perf design: identical to LootBeacon - NO polling. NotifyOnNewObject queues new
-- spots, a per-frame anim-BP hook drains one per frame, one catch-up FindAllOf
-- sweep per level. Beams are plain static meshes: zero per-frame cost once placed.
--
-- Landmines respected (see GripAndFlip/LootBeacon/BaseGuard notes):
--   * NO K2_SetRelativeLocation / K2_SetActorLocationAndRotation / anything with
--     an FHitResult out-param (confirmed EXCEPTION_ACCESS_VIOLATION). Position is
--     written to the RelativeLocation property BEFORE attach; the attach +
--     SetRelativeScale3D calls (both FHitResult-free) recompute the transform.
--   * No LoopAsync/ExecuteWithDelay timers, no FKey APIs, BP hooks registered
--     lazily, pcall + error cap everywhere.

local CFG = {
    -- Beam profile: concentric additive cylinders generated below (CFG.LAYERS),
    -- all centered on the coin (about half of each height shows above it).
    -- Overlap stacks additive brightness near the coin; taller+thinner layers
    -- carry the fading tip. Tuned per user feedback: tight, soft, smooth.
    LAYER_COUNT = 81,    -- more layers = smoother taper
    BASE_W = 2.8,        -- cm: widest (bottom halo) layer diameter
    TIP_W  = 0.55,       -- cm: thinnest (core) layer diameter
    -- layers are bottom-anchored at the coin now (nothing hidden below), so
    -- these are FULL visible heights - halved from the centered-era values to
    -- keep the beam the same height on screen
    BASE_H = 9,          -- cm: shortest layer length
    TIP_H  = 32,         -- cm: tallest layer length (sets overall beam height)
    -- brightness per layer scales inversely with layer count so the overall
    -- glow stays where v14 (9 layers, 0.20-1.10) had it
    BOOST_LO = 0.0265,   -- HDR tint multiplier of the soft outer layer (+15%)
    BOOST_HI = 0.141,    -- HDR tint multiplier of the hot core (+15%)
    -- living sparkles: the game's own loot glitter attached per coin, tinted
    -- to the beam color, stretched tall so its rising particles climb the beam
    FX_SCALE   = 0.22,   -- sparkle cloud width (halved: the white core orb was
                         -- overpowering the beam color)
    FX_SCALE_Z = 0.75,   -- vertical stretch - subtle rise, no floating orb band
    FX_SPEED   = 0.75,   -- time dilation: slightly slow, dreamy drift
    FX_LIFT    = 2,      -- cm relative to the coin. Calibrated from two in-game
                         -- observations (+5 put the glow ~15cm high, -9 put it
                         -- ~35cm low): the offset does not map 1:1 to world cm,
                         -- and ~+2 lands the glow on the coin
    HDR_BOOST   = 2.5,   -- HDR multiplier on beam color; v10's x10 (plus the
                         -- Intensity push) likely blew the additive out to white
    COLOR_RARE  = { R = 1.00, G = 0.72, B = 0.12, A = 1.0 },  -- gold
    COLOR_EPIC  = { R = 0.60, G = 0.18, B = 1.00, A = 1.0 },  -- purple
    QUEUE_DELAY = 30,    -- frames to wait after spawn before touching a new spot
    SWEEP_WARMUP = 120,  -- frames after level start before the catch-up sweep
    MATERIAL_INDEX = 2,  -- 0 = auto (first loadable candidate); 1..n = force that entry
                         -- currently forced to 2 (engine BasicShapeMaterial, opaque,
                         -- cannot be invisible) to isolate geometry vs material issues
    RESWEEP_FRAMES = 1800, -- ~15s: periodic re-sweep for late-activating coins
    BRIGHTNESS  = 10.0,  -- value pushed into any discovered/likely scalar brightness param
}

-- Generate the smooth layer stack from the profile above. Width narrows
-- exponentially (reads as a soft edge), height and boost ramp linearly.
CFG.LAYERS = {}
for i = 1, CFG.LAYER_COUNT do
    local t = (i - 1) / (CFG.LAYER_COUNT - 1)
    table.insert(CFG.LAYERS, {
        w = CFG.BASE_W * (CFG.TIP_W / CFG.BASE_W) ^ t,
        h = CFG.BASE_H + (CFG.TIP_H - CFG.BASE_H) * t,
        boost = CFG.BOOST_LO + (CFG.BOOST_HI - CFG.BOOST_LO) * t,
    })
end

local CYLINDER_PATH = "/Engine/BasicShapes/Cylinder.Cylinder"  -- 100cm tall, centered pivot
local SMC_CLASS_PATH = "/Script/Engine.StaticMeshComponent"

-- Beam material. NOTE: M_FakeLight looked ideal but is a procedural billboard
-- glow (its 'Size' vector param gives it away) - it renders INVISIBLY on real
-- 3D geometry (confirmed in-game: 64 beams built, nothing on screen). The
-- emissive lamp-material family is made for actual meshes, so it leads now.
-- CFG.MATERIAL_INDEX above forces a specific entry for quick isolation.
local MATERIAL_CANDIDATES = {
    "/Game/Materials/Emissive/Lights/MI_Emissive_Light_Additive.MI_Emissive_Light_Additive",
    "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial",
    "/Game/Materials/Effects/FakeLights/M_FakeLight.M_FakeLight",
    "/Game/Materials/Emissive/M_Emissive_Master.M_Emissive_Master",
}

-- Tinted material instances - read their override lists to learn the real
-- parameter names of their shared masters.
local PARAM_DONOR_PATHS = {
    "/Game/Materials/Emissive/Lights/MI_Emissive_Light_Additive.MI_Emissive_Light_Additive",
    "/Game/Materials/Emissive/Lights/MI_Light_Warm_01.MI_Light_Warm_01",
    "/Game/Materials/Emissive/Lights/MI_LIght_Hell_Bulb.MI_LIght_Hell_Bulb",
    "/Game/Materials/Effects/FakeLights/MI_FakeLight_Orange_01.MI_FakeLight_Orange_01",
    "/Game/Materials/Emissive/MI_Emissive_Hell_Red.MI_Emissive_Hell_Red",
    "/Game/Materials/Emissive/MI_Emissive_WhiteSky_LessBright.MI_Emissive_WhiteSky_LessBright",
}

-- Applied on top of whatever discovery finds; wrong names are safe no-ops.
local COLOR_PARAM_CANDIDATES = {
    "Color", "Tint", "TintColor", "LightColor", "EmissiveColor", "Emissive", "GlowColor",
}
local SCALAR_PARAM_CANDIDATES = {
    "Brightness", "Intensity", "EmissivePower", "EmissiveStrength", "Power", "Glow",
}

-- The actual gold/purple coins are AHeldenPhysicsCoin blueprints (confirmed via
-- GameSettings.GoldCoinActorClass / ArtifactCoinActorClass). The PackageLootSpot
-- classes we targeted first never exist as world actors in a dungeon run.
-- Per-rarity beam material: the coins' OWN pre-tinted materials (the artifact
-- one has a visible purple glow in-game). Assigned directly with SetMaterial -
-- no MaterialInstanceDynamic, no parameter writes (both proved unreliable from
-- Lua in this build: MID params silently didn't land, beams stayed gray).
local MAT_COIN_GOLD     = "/Game/Materials/Effects/Coins/MI_Coin_Gold.MI_Coin_Gold"
local MAT_COIN_ARTIFACT = "/Game/Materials/Effects/Coins/MI_Coin_Artifact.MI_Coin_Artifact"

local SPOT_CLASSES = {
    { path = "/Game/Gameplay/Dispensor/BP_Coin_Gold_01.BP_Coin_Gold_01_C",
      color = CFG.COLOR_RARE, mat = MAT_COIN_GOLD },
    { path = "/Game/Gameplay/Dispensor/BP_Coin_Gold_DungLoot_02.BP_Coin_Gold_DungLoot_02_C",
      color = CFG.COLOR_RARE, mat = MAT_COIN_GOLD },
    { path = "/Game/Gameplay/Dispensor/BP_Coin_Artifact_01.BP_Coin_Artifact_01_C",
      color = CFG.COLOR_EPIC, mat = MAT_COIN_ARTIFACT },
    { path = "/Game/Gameplay/Dispensor/BP_Coin_Artifact_DungLoot_02.BP_Coin_Artifact_DungLoot_02_C",
      color = CFG.COLOR_EPIC, mat = MAT_COIN_ARTIFACT },
}

local function Log(msg) print("[CoinBeams] " .. tostring(msg) .. "\n") end

local S = {
    frame = 0,
    errCount = 0,
    processed = {},      -- spot full-name -> true, cleared on level change
    queue = {},          -- { spot = UObject, color = table, readyFrame = n }
    sweepDone = false,
    paramNames = nil,    -- discovered color param names (lazy, once)
    beamCount = 0,
}

-- Read the tinted MI siblings' VectorParameterValues to find the real color
-- parameter name(s). Runs once; merges results with the candidate list.
local function DiscoverParams()
    if S.paramNames then return end
    local names, seen = {}, {}
    local scalars, seenS = {}, {}
    for _, donorPath in ipairs(PARAM_DONOR_PATHS) do
        local donor = donorPath:match("([%w_]+)$")
        pcall(function()
            local mi = StaticFindObject(donorPath)
            if not mi or not mi:IsValid() then return end
            local arr = mi.VectorParameterValues
            for i = 1, #arr do
                local n = arr[i].ParameterInfo.Name:ToString()
                if n and n ~= "" and not seen[n] then
                    seen[n] = true
                    table.insert(names, n)
                    Log("discovered color param '" .. n .. "' on " .. donor)
                end
            end
            local sarr = mi.ScalarParameterValues
            for i = 1, #sarr do
                local n = sarr[i].ParameterInfo.Name:ToString()
                if n and n ~= "" and not seenS[n] then
                    seenS[n] = true
                    table.insert(scalars, n)
                    Log("discovered scalar param '" .. n .. "' on " .. donor)
                end
            end
        end)
    end
    for _, n in ipairs(COLOR_PARAM_CANDIDATES) do
        if not seen[n] then table.insert(names, n) end
    end
    for _, n in ipairs(SCALAR_PARAM_CANDIDATES) do
        if not seenS[n] then table.insert(scalars, n) end
    end
    S.paramNames = names
    S.scalarNames = scalars
end

local function GetColorParamNames()
    DiscoverParams()
    return S.paramNames
end

local function FindBeamMaterial()
    if CFG.MATERIAL_INDEX > 0 then
        local path = MATERIAL_CANDIDATES[CFG.MATERIAL_INDEX]
        if path then
            local m = StaticFindObject(path)
            if m and m:IsValid() then return m, path end
        end
        return nil
    end
    for _, path in ipairs(MATERIAL_CANDIDATES) do
        local m = StaticFindObject(path)
        if m and m:IsValid() then return m, path end
    end
    return nil
end

-- One-shot deep dump of the materials we lean on: parent chain + every stored
-- override. Tells us the REAL tintable parameter names (a stored 'Color' on our
-- MID proves nothing if the shader never samples 'Color').
local function DumpMaterialDiagnostics()
    if S.matDumpDone then return end
    S.matDumpDone = true
    local targets = {
        "/Game/Materials/Emissive/Lights/MI_Emissive_Light_Additive.MI_Emissive_Light_Additive",
        "/Game/Materials/Emissive/MI_Emissive_Hell_Red.MI_Emissive_Hell_Red",
        "/Game/Materials/Emissive/Lights/MI_Light_Warm_01.MI_Light_Warm_01",
    }
    for _, path in ipairs(targets) do
        local short = path:match("([%w_]+)$")
        pcall(function()
            local mi = StaticFindObject(path)
            if not mi or not mi:IsValid() then
                pcall(LoadAsset, path)
                mi = StaticFindObject(path)
            end
            if not mi or not mi:IsValid() then
                Log("matdump " .. short .. ": NOT LOADED")
                return
            end
            pcall(function()
                Log("matdump " .. short .. " parent: " .. mi.Parent:GetFullName())
            end)
            pcall(function()
                local arr = mi.VectorParameterValues
                for i = 1, #arr do
                    local p = arr[i]
                    local v = p.ParameterValue
                    Log(string.format("matdump %s vec '%s' = (%.2f, %.2f, %.2f, %.2f)",
                        short, p.ParameterInfo.Name:ToString(), v.R, v.G, v.B, v.A))
                end
            end)
            pcall(function()
                local arr = mi.ScalarParameterValues
                for i = 1, #arr do
                    local p = arr[i]
                    Log(string.format("matdump %s scalar '%s' = %.3f",
                        short, p.ParameterInfo.Name:ToString(), p.ParameterValue))
                end
            end)
        end)
    end
end

-- Build a one-line diagnostic of a beam we just placed (world pos proves the
-- transform landed where we think it did).
local function DescribeBeam(comp)
    local desc = "?"
    pcall(function()
        local p = comp:K2_GetComponentLocation()
        desc = string.format("world (%.0f, %.0f, %.0f)", p.X, p.Y, p.Z)
    end)
    return desc
end

-- Find our anchor on this spot's root: the only StaticMeshComponent child with
-- NO mesh assigned (the game's own components all carry meshes). Doubles as
-- the reprocess guard.
local function FindAnchor(root)
    local found = nil
    pcall(function()
        local kids = root.AttachChildren
        for i = 1, #kids do
            local kid = kids[i]
            if kid:IsValid() and kid:IsA(SMC_CLASS_PATH) then
                local mesh = kid.StaticMesh
                if not mesh or not mesh:IsValid() then
                    found = kid
                    return
                end
            end
        end
    end)
    return found
end

-- Find all existing beam layers on this spot's root (reprocess guard -
-- AttachChildren is a plain reflected TArray, safe to read).
local function FindBeams(root)
    local found = {}
    pcall(function()
        local kids = root.AttachChildren
        for i = 1, #kids do
            local kid = kids[i]
            if kid:IsValid() and kid:IsA(SMC_CLASS_PATH) then
                local mesh = kid.StaticMesh
                if mesh and mesh:IsValid()
                   and mesh:GetFullName():find("BasicShapes/Cylinder") then
                    table.insert(found, kid)
                end
            end
        end
    end)
    return found
end

-- Build one beam on one loot spot. Returns true when fully applied.
local function ProcessSpot(spot, color, rarityMatPath)
    -- skip CDOs / template objects the sweep may hand us
    local spotName = spot:GetFullName()
    if spotName:find("Default__") or spotName:find("GEN_VARIABLE") then return true end

    local root = spot:K2_GetRootComponent()
    if not root or not root:IsValid() then
        -- collected coins linger rootless in memory forever - handled quietly
        -- by the retry/give-up logic in TryProcess
        return false
    end

    local beamMesh = StaticFindObject(CYLINDER_PATH)
    local smcClass = StaticFindObject(SMC_CLASS_PATH)
    if not beamMesh or not beamMesh:IsValid()
       or not smcClass or not smcClass:IsValid() then
        return false
    end
    -- v7 proved SetMaterial(0, <asset>) DOES render (gold pillars on screen).
    -- For the see-through loot-beam look we want the game's additive bulb-glow
    -- material: additive = adds light over what's behind it, inherently
    -- lookthroughable. Rarity color: try a lib-built MID tinted with the coin
    -- color; if the tint params don't land (suspected from v6), fall back to
    -- the plain additive asset, then to the coin's own material.
    -- v8 lesson: after a fresh boot this material is NOT loaded (v8's beams all
    -- fell back to coin-material). LoadAsset pulls it in; safe on game thread.
    local ADD_MAT_PATH =
        "/Game/Materials/Emissive/Lights/MI_Emissive_Light_Additive.MI_Emissive_Light_Additive"
    local addMat = StaticFindObject(ADD_MAT_PATH)
    if not addMat or not addMat:IsValid() then
        pcall(LoadAsset, ADD_MAT_PATH)
        addMat = StaticFindObject(ADD_MAT_PATH)
    end
    local coinMat = rarityMatPath and StaticFindObject(rarityMatPath) or nil

    -- ---- layered beam: concentric additive cylinders on an upright anchor.
    -- The anchor is an empty component at the coin's center whose rotation is
    -- absolute (world-locked): its local +Z is always true up, however the
    -- coin lies or tumbles. Layers hang off it with a +Z offset of half their
    -- height, so each cylinder's BOTTOM sits at the coin and the beam extends
    -- upward only (v16 centered them, which pushed light through floors).
    if FindAnchor(root) then return true end
    for _, old in ipairs(FindBeams(root)) do
        -- leftovers from pre-anchor builds: clear and rebuild
        pcall(function() old:K2_DestroyComponent(old) end)
    end

    local identity = {
        Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 0 },
        Scale3D     = { X = 1, Y = 1, Z = 1 },
    }
    local anchor = spot:AddComponentByClass(smcClass, false, identity, false)
    if not anchor or not anchor:IsValid() then
        Log("AddComponentByClass returned no component")
        return false
    end
    anchor:SetMobility(2)
    anchor:SetCollisionEnabled(0)
    local okAbs = pcall(function() anchor:SetAbsolute(false, true, false) end)
    if not okAbs then pcall(function() anchor.bAbsoluteRotation = true end) end
    -- CRITICAL: SetAbsolute PRESERVES the current world rotation - a coin lying
    -- tilted at build time froze its beam tilted forever (seen on chest coins).
    -- With absolute rotation on, RelativeRotation IS world rotation: zero it,
    -- then poke the transform so the change takes.
    pcall(function() anchor.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } end)
    anchor:SetRelativeScale3D({ X = 1, Y = 1, Z = 1 })

    local attachWorks = true
    local lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    for _, layer in ipairs(CFG.LAYERS) do
        local comp = spot:AddComponentByClass(smcClass, false, identity, false)
        if not comp or not comp:IsValid() then
            Log("AddComponentByClass returned no component")
            return false
        end
        comp:SetMobility(2)             -- Movable (class default is Static)
        comp:SetCollisionEnabled(0)     -- NoCollision - never block grabs/physics
        comp:SetCastShadow(false)

        -- hang the layer off the upright anchor, bottom at the coin
        local okAtt = attachWorks and pcall(function()
            comp:K2_AttachToComponent(anchor, FName("None"), 0, 0, 0, false)  -- KeepRelative x3
        end)
        if okAtt then
            pcall(function() comp.RelativeLocation = { X = 0, Y = 0, Z = layer.h * 0.5 } end)
        else
            -- attach API unavailable: fall back to v16 centered-upright beams
            if attachWorks then
                attachWorks = false
                Log("K2_AttachToComponent failed - falling back to centered beams")
            end
            pcall(function() comp:SetAbsolute(false, true, false) end)
        end

        comp:SetStaticMesh(beamMesh)
        comp:SetRelativeScale3D({
            X = layer.w / 100.0,
            Y = layer.w / 100.0,
            Z = layer.h / 100.0,
        })

        -- per-layer tinted MID (4-arg UE5.7 signature); fall back untinted,
        -- then to the coin's own material
        local mid = nil
        if addMat and addMat:IsValid() and lib and lib:IsValid() then
            pcall(function()
                mid = lib:CreateDynamicMaterialInstance(spot, addMat, FName("None"), 0)
            end)
        end
        if mid and mid:IsValid() then
            local boosted = { R = color.R * layer.boost, G = color.G * layer.boost,
                              B = color.B * layer.boost, A = 1.0 }
            pcall(function()
                mid:SetVectorParameterValue(FName("Color"), boosted)
                mid:SetVectorParameterValue(FName("EmissiveColor"), boosted)
                mid:SetScalarParameterValue(FName("DisabledOpacity"), 1.0)
            end)
            for _, name in ipairs(GetColorParamNames()) do
                local l = name:lower()
                if l:find("color") or l:find("tint") or l:find("glow") or l:find("emissive") then
                    pcall(function() mid:SetVectorParameterValue(FName(name), boosted) end)
                end
            end
            pcall(function() comp:SetMaterial(0, mid) end)
        elseif addMat and addMat:IsValid() then
            pcall(function() comp:SetMaterial(0, addMat) end)
        elseif coinMat and coinMat:IsValid() then
            pcall(function() comp:SetMaterial(0, coinMat) end)
        end
    end

    -- Living sparkles: one copy of the game's loot glitter per coin (its
    -- 'Rising' emitter floats particles upward). Attached to the root with a
    -- Niagara-child guard so reprocessing never stacks extra systems.
    -- Landmines respected: no param-store iteration, no ReinitializeSystem;
    -- SetNiagaraVariableLinearColor on unknown names no-ops safely.
    -- (no duplicate guard needed: this block only runs when the anchor was
    -- just created - FindAnchor short-circuits reprocessing above)
    pcall(function()
        local FX_PATH = "/Game/Effects/ParticleSystems/Loot/NS_Loot_01.NS_Loot_01"
        local sys = StaticFindObject(FX_PATH)
        if not sys or not sys:IsValid() then
            pcall(LoadAsset, FX_PATH)
            sys = StaticFindObject(FX_PATH)
        end
        local nlib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not sys or not sys:IsValid() or not nlib or not nlib:IsValid() then return end
        -- attach to the upright anchor, lifted into the beam body, so the
        -- sparkle cloud rises along the beam instead of sitting half underfloor
        local fx = nlib:SpawnSystemAttached(sys, anchor, FName("None"),
            { X = 0, Y = 0, Z = CFG.FX_LIFT }, { Pitch = 0, Yaw = 0, Roll = 0 },
            3, false, true, 0, false)
        if not fx or not fx:IsValid() then return end
        pcall(function() fx:SetAbsolute(false, true, false) end)  -- rise straight up
        fx:SetRelativeScale3D({ X = CFG.FX_SCALE, Y = CFG.FX_SCALE, Z = CFG.FX_SCALE_Z })
        fx:SetCustomTimeDilation(CFG.FX_SPEED)
        local fxColor = { R = color.R * 2.0, G = color.G * 2.0, B = color.B * 2.0, A = 1.0 }
        for _, name in ipairs({ "Color", "User.Color", "VFXColor", "User.VFXColor" }) do
            pcall(function() fx:SetNiagaraVariableLinearColor(name, fxColor) end)
        end
    end)

    S.beamCount = S.beamCount + 1
    Log(string.format("beam #%d on %s | %d layers",
        S.beamCount, spotName:match("^([%w_]+)") or "spot", #CFG.LAYERS))
    return true
end

local function TryProcess(entry)
    local spot = entry.spot
    if not spot or not spot:IsValid() then return end
    local key = spot:GetFullName()
    if S.processed[key] then return end
    -- NB: ok = "didn't throw", done = ProcessSpot's actual verdict. Collapsing
    -- them (select(2, ...)) silently marked crashed spots as processed.
    local ok, done = pcall(ProcessSpot, spot, entry.color, entry.mat)
    if not ok then
        if S.errCount < 8 then
            S.errCount = S.errCount + 1
            Log("build error (" .. S.errCount .. "/8): " .. tostring(done))
        end
        done = false
    end
    if done then
        S.processed[key] = true
    else
        -- spot mid-setup: retry before giving up. Level-generated coins (chest
        -- contents etc.) can stay rootless for a long while before activating,
        -- so be patient - the periodic re-sweep also re-queues them later.
        entry.tries = (entry.tries or 0) + 1
        if entry.tries < 12 then
            entry.readyFrame = S.frame + CFG.QUEUE_DELAY
            table.insert(S.queue, entry)
        else
            -- permanently blacklist: rootless "coins" are collected ones
            -- lingering in memory - without this, every re-sweep re-queued
            -- them and the log drowned in retries (v7 spam bug)
            S.processed[key] = true
        end
    end
end

-- One-off catch-up for spots that existed before our notify hooks were live
-- (mod load mid-session, hot reload). Queued, drained one per frame.
local function CatchUpSweep()
    local counts = {}
    local newSpots = 0
    for _, sc in ipairs(SPOT_CLASSES) do
        local shortName = sc.path:match("([%w_]+)$")
        local ok, spots = pcall(FindAllOf, shortName)
        local n = 0
        if ok and spots then
            for _, spot in ipairs(spots) do
                n = n + 1
                -- only queue spots we haven't finished (re-sweeps run forever)
                local done = false
                pcall(function() done = S.processed[spot:GetFullName()] end)
                if not done then
                    newSpots = newSpots + 1
                    table.insert(S.queue,
                        { spot = spot, color = sc.color, mat = sc.mat,
                          readyFrame = S.frame + CFG.QUEUE_DELAY })
                end
            end
        end
        table.insert(counts, shortName .. "=" .. n)
    end
    -- periodic re-sweeps stay quiet unless they actually found new coins
    if not S.sweepLogged or newSpots > 0 then
        S.sweepLogged = true
        Log("sweep: " .. table.concat(counts, ", ") .. " (" .. newSpots .. " new)")
    end
end

-- Event-driven intake.
for _, sc in ipairs(SPOT_CLASSES) do
    pcall(function()
        NotifyOnNewObject(sc.path, function(spot)
            table.insert(S.queue,
                { spot = spot, color = sc.color, mat = sc.mat,
                  readyFrame = S.frame + CFG.QUEUE_DELAY })
        end)
    end)
end

-- Per-frame driver: known-good BP hook (runs on game thread).
local Hooked = false
local function TryRegisterHook()
    RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
        function(self, DeltaTimeX)
            if S.errCount >= 8 then return end
            S.frame = S.frame + 1

            -- initial sweep after warmup, then a slow periodic re-sweep to catch
            -- level-generated coins that had no root when first seen. Kept rare
            -- (~15s) - LootBeacon showed 1.5s FindAllOf polling causes visible
            -- latency in this game.
            if (not S.sweepDone and S.frame >= CFG.SWEEP_WARMUP)
               or (S.sweepDone and S.frame % CFG.RESWEEP_FRAMES == 0) then
                S.sweepDone = true
                local ok, err = pcall(CatchUpSweep)
                if not ok then
                    S.errCount = S.errCount + 1
                    Log("sweep error (" .. S.errCount .. "/8): " .. tostring(err))
                end
            end

            if #S.queue > 0 and S.queue[1].readyFrame <= S.frame then
                local entry = table.remove(S.queue, 1)
                local ok, err = pcall(TryProcess, entry)
                if not ok then
                    S.errCount = S.errCount + 1
                    Log("process error (" .. S.errCount .. "/8): " .. tostring(err))
                end
            end
        end)
end

local function EnsureHook()
    if Hooked then return end
    local ok, err = pcall(TryRegisterHook)
    if ok then
        Hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry on respawn): " .. tostring(err))
    end
end

EnsureHook()

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        EnsureHook()
        S.processed = {}
        S.queue = {}
        S.errCount = 0
        S.sweepDone = false
        S.frame = 0
        S.beamCount = 0
    end)
end)

Log(string.format("loaded v20 (zeroed anchor rotation, recalibrated sparkle height; %d layers, %.0fcm tall)",
    #CFG.LAYERS, CFG.LAYERS[#CFG.LAYERS].h))
