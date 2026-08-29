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
    COLOR_RARE  = { R = 1.00, G = 0.72, B = 0.12, A = 1.0 },  -- gold
    COLOR_EPIC  = { R = 0.60, G = 0.18, B = 1.00, A = 1.0 },  -- purple
    QUEUE_DELAY = 30,    -- frames to wait after spawn before touching a new spot
    -- v23.1: raised 120 -> 420. At 120 the first sweep landed roughly a second
    -- after load, i.e. while the level was still streaming actors in, and that
    -- is when the intermittent crash-on-load happened. Everything this mod does
    -- is cosmetic, so it now waits for the world to settle. This single gate
    -- covers beams, lights and sparkle work (FX_SETTLE_FRAMES matches it).
    SWEEP_WARMUP = 420,  -- frames after level start before the catch-up sweep
    RESWEEP_FRAMES = 1800, -- ~15s: periodic re-sweep for late-activating coins
    RESWEEP_FAST = 240,  -- ~2-4s: used while sweeps keep finding coins the
                         -- NotifyOnNewObject path missed (some UE4SS builds,
                         -- e.g. the shimloader/manager one, never fire it)
    BRIGHTNESS  = 10.0,  -- value pushed into any discovered/likely scalar brightness param

    -- ---- v21: rarity outlines -------------------------------------------
    -- The real fix for "I can't tell what's valuable at a glance". Coins get
    -- beams; the carryable VALUABLES (AHeldenPhysTreasure) got nothing but the
    -- game's sparse sparkle, so you had to fly into the sparkle and inspect the
    -- item to learn its rarity. These paint a constant rarity-colored glow
    -- shell over the whole item via UMeshComponent:SetOverlayMaterial - always
    -- on, readable across a room, no particle timing involved.
    OUTLINE_ENABLED  = true,
    OUTLINE_MIN_QUALITY = 0,  -- EHeldenConstructQuality: 0 Common, 1 Rare, 2 Epic.
                              -- 0 = everything valuable, including the white-
                              -- sparkle commons (set 1 for Rare+ only)

    -- v21.2: rarity marker on valuables - ONE cylinder, not the coin beam.
    -- v21.1 reused the 81-layer coin beam here and crashed the game twice on
    -- load: 18 valuables x 82 components each = ~1500 new components (plus 36
    -- Niagara systems), built 82-per-frame, on top of a level already carrying
    -- 4111 physics actors. A single additive cylinder reads just as clearly at
    -- a distance for ~2 components per item.
    -- v22: OFF by default. Beams assume "up from a thing standing on the floor",
    -- which is wrong for the wall-mounted valuables (pictures, signs) - the shaft
    -- sprouts out of the frame instead of framing it. The sparkle boost + rarity
    -- light below have no orientation to get wrong, so they work on every item.
    ITEM_BEAMS     = false,
    -- Sized from the v21.1 screenshot at -65%: that beam was 192cm tall and
    -- 16.8cm wide at the base, which punched through ceilings.
    ITEM_MARKER_H      = 67,  -- cm: beam height
    ITEM_MARKER_W      = 5.9, -- cm: outer halo width
    ITEM_MARKER_CORE_W = 2.2, -- cm: inner bright core width
    -- No particles on item beams. The white ring and glitter in the v21.1
    -- screenshot came from the coin beam's attached NS_Loot_01 (its 'RIngs'
    -- and glitter emitters); item beams are pure geometry now, which also
    -- removes 2 live particle systems per item.
    MAX_ITEM_MARKERS = 48,    -- hard ceiling per level. Beyond this, valuables
                              -- are left unmarked rather than risking the level
    ITEM_BUILD_INTERVAL = 3,  -- frames between marker builds - spreads the cost
                              -- so a loot-dense room cannot spike one frame

    -- ---- v22: enhance the game's OWN item sparkle ------------------------
    -- The item sparkle is NS_RareProp_01 (found in the user's own RotProfiler
    -- census: "NS_RareProp_01 x10" active). Every previous version boosted
    -- NS_Loot_01 - the COIN/loot-spot effect - which is why none of it ever
    -- touched the sparkles on furniture, plants or pictures.
    --
    -- NS_RareProp_01 is one sprite emitter (Glitter_01) whose spawn script uses
    -- a StaticMesh data interface: it scatters particles across the item's own
    -- mesh surface. That is why it hugs a wall picture correctly - and why it is
    -- the right thing to amplify instead of bolting geometry on.
    --
    -- It has NO light renderer (unlike NS_Loot_01, which owns a Core_Light
    -- emitter), so the sparkles emit zero actual light - the core reason they
    -- read as faint specks rather than glow. Hence the rarity light below.
    SPARKLE_ENABLED   = true,
    -- Renderer-level fixes, patched once on the shared asset (zero per-item
    -- cost, affects every sparkle in the level):
    -- (v23.1 removed the sprite-renderer WRITES entirely. The diagnostic proved
    -- they were no-ops - the game already ships distanceCulling=false,
    -- max=100000, pixelCoverage=Disabled - and writing to a live renderer the
    -- render thread reads is real risk for zero gain. ReportSparkleRenderer
    -- still logs those values once, in case a game update changes them.)
    -- Frames after level load before ANY sparkle work runs. The intermittent
    -- crash-on-load happened while the level was still streaming in; nothing
    -- here is urgent, so wait until the world has settled.
    FX_SETTLE_FRAMES  = 420,
    -- Run the Niagara-component pass on every Nth sweep. The sweep itself runs
    -- every ~4s while it is still finding things, and walking ~250 components
    -- that often buys nothing once the level's props are already boosted.
    FX_SWEEP_EVERY    = 3,
    -- Per-component boosts on the live sparkle systems:
    -- v32: 2.5 -> 1.0. This never actually ran before (see the bRegistered
    -- bugfix), and now that it does, scaling the component is the wrong lever:
    -- this emitter samples the item's own mesh surface, so scaling it would
    -- drag the sparkles off the item instead of enlarging them. Sparkle size
    -- comes from the emitter size curve instead, which is already boosted.
    SPARKLE_SCALE     = 1.0,   -- component scale. NOTE (v23): this does NOT
                               -- change sprite size here - the emitter is not in
                               -- local space, so component scale never reaches
                               -- the sprites. Kept because it costs nothing;
                               -- SPARKLE_SIZE_MULT below is the real size lever.
    SPARKLE_SPEED     = 3.2,   -- time dilation - sparkle more often (this is what
                               -- produced the frequency improvement in v22)

    -- v23 SIZE: the sprite renderer has no size property - particle size comes
    -- from a curve baked into the emitter's update script. Those curves live on
    -- UNiagaraDataInterfaceCurve objects whose `ShaderLUT` is a plain reflected
    -- TArray<float> we can scale in place. NS_RareProp_01's update script owns
    -- three scalar curves; we only scale ones whose values look like sizes
    -- (max > 1.5) so alpha/opacity curves (0..1) are left alone.
    SPARKLE_SIZE_MULT = 2.2,
    SPARKLE_SIZE_CURVE_MIN = 1.5, -- a curve peaking above this is treated as size

    -- v23 COUNT: extra copies of the game's own sparkle system per valuable.
    -- NS_RareProp_01 samples the item's mesh through a StaticMesh data interface
    -- in AttachParent-style resolution, so an attached copy scatters over the
    -- same item correctly - including wall pictures.
    -- v32: OFF. A copy spawned from the shared asset carries its default
    -- (purple) look, and setting the Color parameter on the copy does NOT
    -- override it - the probe can read Color back but writing it changes
    -- nothing visible, which is why white and blue items kept showing purple
    -- sparkles through v29-v31. Wrong colors are worse than fewer sparkles, so
    -- density now comes only from the game's own correctly-colored sparkle.
    SPARKLE_COPIES    = 0,     -- extra systems per item, for a REFERENCE-sized
                               -- prop (0 = off). Scaled per item below.
    -- v24: even out sparkle density across items. NS_RareProp_01 scatters its
    -- particles over the item's MESH SURFACE (its spawn script drives a static
    -- mesh data interface), so one system spread across a big table reads far
    -- sparser than the same system on a small trinket - which is exactly the
    -- "some items flicker less than others" report. Copies are now proportional
    -- to the item's actual size, measured from its bounds at mark time.
    SPARKLE_REF_EXTENT = 20,   -- cm: box extent of a "normal" prop = base copies.
                               -- v25: 35 -> 20. At 35 a table measured close to
                               -- the reference and got the flat 2 copies, so
                               -- large props stayed visibly sparser than small ones.
    SPARKLE_COPIES_MAX = 8,    -- per-item ceiling (v25: 5 -> 8), so a wardrobe
                               -- can actually reach small-prop density
    SPARKLE_SPEED_MAX_MULT = 3.0, -- ceiling on the size-driven spawn-rate boost
    MAX_SPARKLE_COPIES = 48,   -- hard ceiling per level (component budget).
                               -- Raised from 24 in v24: with size-scaling a big
                               -- item can claim up to 5, so 24 was exhausted by
                               -- about five items and later loot got nothing.

    -- ---- v22: rarity light ----------------------------------------------
    -- A small colored point light at the item. This is the "glowy" part and the
    -- one thing that cannot misalign: it has no shape and no up-vector, so it
    -- works identically on a floor prop, a hanging picture, or a tumbling item.
    -- One component each, never shadow-casting (shadowed lights are the
    -- expensive kind), capped hard after the v21.1 component-budget crash.
    -- v31: treat any actor the game attaches its rarity sparkle to as a
    -- valuable. Without this only AHeldenPhysTreasure actors were marked, so
    -- sellable furniture - chairs, tables, paintings - got no light at all.
    MARK_SPARKLING_ACTORS = true,
    ITEM_LIGHT        = true,
    -- 350 lit whole rooms; 200 still threw a ~2m pool across the floorboards;
    -- 170 was closer. v28: halved again to 85 - the glow now sits on the item
    -- rather than pooling on the floor around it.
    ITEM_LIGHT_RADIUS = 64,    -- cm falloff
    -- History, because the numbers here are misleading on their own: the
    -- original 12/24cd looked like "no glow" only because the light was
    -- registering as Static and contributing no lighting whatsoever (fixed via
    -- deferred creation below). v25 then over-corrected to 400cd, which lit
    -- entire rooms AND blew every rarity color out to white - a light that
    -- clips its channels has no hue left. v30: 14 -> 3.5cd (another -75%). Well
    -- below the original 12cd now; this is a faint tint on the item rather than
    -- a light source, which is what repeated tuning has converged on.
    ITEM_LIGHT_INTENSITY = 1.75,
    MAX_ITEM_LIGHTS   = 64,

    OUTLINE_OPACITY  = 0.85,  -- pushed into the glow material's own opacity param
    OUTLINE_HDR      = 4.0,   -- HDR multiplier on the tint, so bloom picks it up
    -- Colors follow the sparkle colors the game already uses for rarity.
    -- v26: saturated harder. These now drive a real light, and a light washes
    -- toward white far more readily than a particle tint does, so the hues need
    -- more headroom between channels to stay legible.
    OUTLINE_COMMON = { R = 0.90, G = 0.92, B = 1.00, A = 1.0 },  -- white
    OUTLINE_RARE   = { R = 0.02, G = 0.30, B = 1.00, A = 1.0 },  -- blue
    OUTLINE_EPIC   = { R = 0.55, G = 0.03, B = 1.00, A = 1.0 },  -- purple
    -- v35: the fourth tier. EHeldenConstructQuality has exactly four values and
    -- the SDK dump names #3 "BuiltConstruct", which read like player-placed
    -- furniture - so every version until now threw it away. It is actually a
    -- real loot tier: the game inspect panel calls it "Excellent" and gives it
    -- its own pale-blue sparkle, distinct from Rare's blue. Matched here.
    OUTLINE_EXCELLENT = { R = 0.45, G = 0.85, B = 1.00, A = 1.0 },  -- pale cyan-blue
    -- Highest quality value that still counts as loot. 3 = include Excellent.
    OUTLINE_MAX_QUALITY = 3,

    -- sparkle density: extra copies of the glitter system per coin, desynced
    FX_LAYERS  = 2,
}

-- v21: sparkles pushed up again per user feedback (still hard to notice at a
-- glance). v20 had halved FX_SCALE because the system's white core orb washed
-- out the beam tint - this is the compromise point, so if beams start reading
-- white at the base, walk FX_SCALE back toward 0.22 rather than the speed.
CFG.FX_SCALE = 0.40
CFG.FX_SPEED = 1.15

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

-- Material note kept for future work: M_FakeLight looked ideal for beams but is
-- a procedural billboard glow - it renders INVISIBLY on real 3D geometry
-- (confirmed in-game: 64 beams built, nothing on screen). MI_Emissive_Light_Additive
-- is the one proven to draw on static meshes, and is used directly below.

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

-- Forward declarations: the rarity-outline module is defined further down (it
-- needs MAT_COIN_* and the shared config), but CatchUpSweep and the per-frame
-- hook call into it. Without these the calls would compile as global lookups
-- and silently resolve to nil.
local OutlineSweep, OutlineDrain

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
-- sizeMul (optional, default 1) scales the whole beam. Coins pass nothing.
-- Valuables no longer use this builder at all - see MarkValuable, which draws a
-- 3-component beam instead of this 82-component one.
local function ProcessSpot(spot, color, rarityMatPath, sizeMul)
    local sm = sizeMul or 1.0
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
            pcall(function() comp.RelativeLocation = { X = 0, Y = 0, Z = layer.h * 0.5 * sm } end)
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
            X = layer.w / 100.0 * sm,
            Y = layer.w / 100.0 * sm,
            Z = layer.h / 100.0 * sm,
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
        local fxColor = { R = color.R * 2.0, G = color.G * 2.0, B = color.B * 2.0, A = 1.0 }
        -- v21: FX_LAYERS copies instead of one. Extra layers run narrower and
        -- faster so they interleave as visibly more sparkles rather than one
        -- brighter blob pulsing in lockstep.
        for layerIdx = 1, (CFG.FX_LAYERS or 1) do
            local fx = nlib:SpawnSystemAttached(sys, anchor, FName("None"),
                { X = 0, Y = 0, Z = CFG.FX_LIFT }, { Pitch = 0, Yaw = 0, Roll = 0 },
                3, false, true, 0, false)
            if fx and fx:IsValid() then
                pcall(function() fx:SetAbsolute(false, true, false) end)  -- rise straight up
                local widthMul = 1.0 - 0.15 * (layerIdx - 1)
                fx:SetRelativeScale3D({
                    X = CFG.FX_SCALE * widthMul,
                    Y = CFG.FX_SCALE * widthMul,
                    Z = CFG.FX_SCALE_Z,
                })
                fx:SetCustomTimeDilation(CFG.FX_SPEED * (1.0 + 0.35 * (layerIdx - 1)))
                for _, name in ipairs({ "Color", "User.Color", "VFXColor", "User.VFXColor" }) do
                    pcall(function() fx:SetNiagaraVariableLinearColor(name, fxColor) end)
                end
            end
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
    -- valuables ride the same sweep cadence (they are level-generated too, and
    -- on the shimloader UE4SS build NotifyOnNewObject often never fires at all)
    pcall(OutlineSweep)
    -- periodic re-sweeps stay quiet unless they actually found new coins
    if not S.sweepLogged or newSpots > 0 then
        S.sweepLogged = true
        Log("sweep: " .. table.concat(counts, ", ") .. " (" .. newSpots .. " new)")
    end
    -- adaptive cadence: sweeps finding coins means the NotifyOnNewObject
    -- instant path is not firing on this UE4SS build - sweep fast so beams
    -- appear within a couple of seconds. Three clean sweeps in a row means
    -- notifications are doing their job - back off to the calm cadence.
    if newSpots > 0 then
        S.cleanSweeps = 0
        if S.sweepInterval ~= CFG.RESWEEP_FAST then
            S.sweepInterval = CFG.RESWEEP_FAST
            Log("notify path quiet - fast sweep mode (~3s)")
        end
    else
        S.cleanSweeps = (S.cleanSweeps or 0) + 1
        if S.cleanSweeps >= 3 and S.sweepInterval ~= CFG.RESWEEP_FRAMES then
            S.sweepInterval = CFG.RESWEEP_FRAMES
            Log("notify path healthy - calm sweep mode")
        end
    end
end

-- ======================================================================
-- RARITY OUTLINES
-- ======================================================================
-- What the game actually does (mapped from the SDK dump, 2026-08-16):
--   * Every physics object carries `ConstructQuality` (EHeldenConstructQuality:
--     Common 0 / Rare 1 / Epic 2 / BuiltConstruct 3) on AHeldenPhysicsActor.
--   * The carryable dungeon valuables are AHeldenPhysTreasure. There are only
--     two blueprints (BP_DefaultPhysTreasure, BP_PhysTreasure_Voodoo) because
--     the mesh + stats come from a UHeldenConstructAsset applied at spawn -
--     which is why per-item VFX is thin: rarity is data, not a distinct actor.
--   * The rarity palette lives in UHeldenDataSingleton.LootColor, a
--     TMap<EHeldenConstructQuality, FLinearColor>. NOT read at runtime: TMap
--     traversal from Lua is the same shape of API that froze the game in
--     LootBeacon, so the colors are plain config above instead.
--   * The game already owns a mesh-overlay glow system - FHeldenMeshOverlayEffect
--     {OverlayMaterial, OpacityParamterName, FadeIn/OutDuration}, used for the
--     character spark glow. We reuse its material the same way it does.
-- Mechanism: UMeshComponent:SetOverlayMaterial renders the item's mesh a second
-- time with our material. Constant, no particles, no per-frame work once set.
local TREASURE_CLASSES = {
    -- Native base first: FindAllOf matches subclasses, so this catches any
    -- treasure blueprint including the per-construct ClassOverride ones we
    -- have not enumerated. The two known blueprints follow as a safety net in
    -- case the native lookup returns nothing on some build. Overlap is free -
    -- the drain dedupes on full name.
    "/Script/Helden.HeldenPhysTreasure",
    "/Game/Gameplay/Physics/Treasure/BP_DefaultPhysTreasure.BP_DefaultPhysTreasure_C",
    "/Game/Gameplay/Physics/Treasure/BP_PhysTreasure_Voodoo.BP_PhysTreasure_Voodoo_C",
}

-- Overlay materials in descending order of preference.
-- v21.1 REORDERED after the first live test: the game's own GlowOverlayEffect
-- material resolved and applied cleanly (log confirmed 18 items outlined) but
-- was INVISIBLE in game. It is authored for the player's SKELETAL mesh, and a
-- material whose shader permutations were never compiled for the static-mesh
-- vertex factory simply does not draw on one. The additive lamp material is the
-- one this mod already proved renders on static meshes (it is what the beam
-- cylinders use), so it leads now.
local GLOW_MATERIAL_PATHS = {
    "/Game/Materials/Emissive/Lights/MI_Emissive_Light_Additive.MI_Emissive_Light_Additive",
    "/Game/Materials/Emissive/M_Emissive_Master.M_Emissive_Master",
    "/Game/Effects/Materials/Overlay/M_CharacterGlow.M_CharacterGlow",
}
-- Last-resort per-rarity PRE-TINTED assets. No MID, no parameter writes - the
-- one path in this game that has never failed to render (v7 beams).
local GLOW_FALLBACK_TINTED = {
    [1] = MAT_COIN_GOLD,
    [2] = MAT_COIN_ARTIFACT,
}

local G = {
    queue = {},        -- { actor = UObject, readyFrame = n, tries = k }
    done = {},         -- full-name -> true
    count = 0,
    glowMat = nil,     -- resolved parent material
    glowSrc = nil,
    opacityParam = nil,-- discovered from the game's own overlay effect struct
    resolved = false,
    logged = {},
    fx = {},           -- sparkle component full-name -> already boosted
    fxCount = 0,
    lightCount = 0,
    copyCount = 0,
    rendererReported = false,  -- process-scoped: renderer values never change
    fxSweepTick = 0,           -- staggers the Niagara sweep off the main cadence
}

local function OutlineColorFor(quality)
    if quality == 3 then return CFG.OUTLINE_EXCELLENT end
    if quality == 2 then return CFG.OUTLINE_EPIC end
    if quality == 1 then return CFG.OUTLINE_RARE end
    return CFG.OUTLINE_COMMON
end

local QUALITY_NAMES = { [0] = "Common", [1] = "Rare", [2] = "Epic", [3] = "Excellent" }
local function QualityName(q)
    return QUALITY_NAMES[q] or ("q" .. tostring(q))
end

-- Resolve the overlay material once. Preference: whatever the game itself
-- points its own glow effect at (that also hands us the real opacity parameter
-- name), then the known-good asset paths.
local function ResolveGlowMaterial()
    if G.resolved then return end
    G.resolved = true
    -- The game's own glow effect is still worth reading for its opacity
    -- PARAMETER NAME (confirmed "Opacity" live), but deliberately NOT for its
    -- material - see the note on GLOW_MATERIAL_PATHS above.
    pcall(function()
        local settings = FindFirstOf("HeldenCharacterSettings")
        if settings and settings:IsValid() then
            local pn = settings.GlowOverlayEffect.OpacityParamterName:ToString()
            if pn and pn ~= "" and pn ~= "None" then G.opacityParam = pn end
        end
    end)
    if not G.glowMat then
        for _, path in ipairs(GLOW_MATERIAL_PATHS) do
            local ok = pcall(function()
                local m = StaticFindObject(path)
                if not (m and m:IsValid()) then
                    pcall(LoadAsset, path)
                    m = StaticFindObject(path)
                end
                if m and m:IsValid() then
                    G.glowMat = m
                    G.glowSrc = path:match("([%w_]+)$")
                end
            end)
            if ok and G.glowMat then break end
        end
    end
    Log("outline material: " .. tostring(G.glowSrc or "NONE - using per-rarity tinted assets")
        .. ", opacity param: " .. tostring(G.opacityParam or "(none discovered)"))
end

-- Build the overlay material for one item. Per-actor MID so its lifetime is
-- tied to the actor that uses it (a shared cached MID would be GC'd with
-- whichever actor happened to create it, while others still referenced it).
local function BuildOverlayMaterial(actor, quality)
    local color = OutlineColorFor(quality)
    local boosted = {
        R = color.R * CFG.OUTLINE_HDR,
        G = color.G * CFG.OUTLINE_HDR,
        B = color.B * CFG.OUTLINE_HDR,
        A = 1.0,
    }
    local mid = nil
    local lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if G.glowMat and G.glowMat:IsValid() and lib and lib:IsValid() then
        pcall(function()
            -- 4-arg form: the 3-arg one throws "expected 4 parameters" in UE5.7
            mid = lib:CreateDynamicMaterialInstance(actor, G.glowMat, FName("None"), 0)
        end)
    end
    if mid and mid:IsValid() then
        for _, name in ipairs(COLOR_PARAM_CANDIDATES) do
            pcall(function() mid:SetVectorParameterValue(FName(name), boosted) end)
        end
        if G.opacityParam then
            pcall(function()
                mid:SetScalarParameterValue(FName(G.opacityParam), CFG.OUTLINE_OPACITY)
            end)
        end
        for _, name in ipairs({ "Opacity", "Alpha", "OverlayOpacity" }) do
            pcall(function() mid:SetScalarParameterValue(FName(name), CFG.OUTLINE_OPACITY) end)
        end
        for _, name in ipairs(SCALAR_PARAM_CANDIDATES) do
            pcall(function() mid:SetScalarParameterValue(FName(name), CFG.BRIGHTNESS) end)
        end
        return mid
    end
    -- MID route unavailable: pre-tinted rarity asset, guaranteed to render
    local path = GLOW_FALLBACK_TINTED[quality]
    if path then
        local m = StaticFindObject(path)
        if not (m and m:IsValid()) then
            pcall(LoadAsset, path)
            m = StaticFindObject(path)
        end
        if m and m:IsValid() then return m end
    end
    return nil
end

-- One lightweight upright marker on a valuable: an invisible world-up anchor
-- plus a single additive cylinder. Same anchor trick as the coin beams (the
-- item can lie tilted or tumble; the marker must still point at the sky), but
-- two components instead of eighty-two.
local function MarkValuable(actor, mat)
    local root = actor:K2_GetRootComponent()
    if not (root and root:IsValid()) then return false end
    if FindAnchor(root) then return true end   -- already marked

    local smcClass = StaticFindObject(SMC_CLASS_PATH)
    local beamMesh = StaticFindObject(CYLINDER_PATH)
    if not (smcClass and smcClass:IsValid()) then return false end
    if not (beamMesh and beamMesh:IsValid()) then return false end

    local identity = {
        Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 0 },
        Scale3D     = { X = 1, Y = 1, Z = 1 },
    }

    local anchor = actor:AddComponentByClass(smcClass, false, identity, false)
    if not (anchor and anchor:IsValid()) then return false end
    anchor:SetMobility(2)
    anchor:SetCollisionEnabled(0)
    local okAbs = pcall(function() anchor:SetAbsolute(false, true, false) end)
    if not okAbs then pcall(function() anchor.bAbsoluteRotation = true end) end
    -- SetAbsolute preserves current world rotation - zero it, then poke the
    -- transform so the change takes (same landmine as the coin beams)
    pcall(function() anchor.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } end)
    anchor:SetRelativeScale3D({ X = 1, Y = 1, Z = 1 })

    -- Two concentric additive cylinders: a soft halo and a brighter core. That
    -- is what gives the beam a glow edge instead of looking like a plastic
    -- tube, at 3 components per item instead of the coin beam's 82.
    for _, w in ipairs({ CFG.ITEM_MARKER_W, CFG.ITEM_MARKER_CORE_W }) do
        local comp = actor:AddComponentByClass(smcClass, false, identity, false)
        if not (comp and comp:IsValid()) then return false end
        comp:SetMobility(2)
        comp:SetCollisionEnabled(0)      -- never block grabs or physics
        comp:SetCastShadow(false)
        local okAtt = pcall(function()
            comp:K2_AttachToComponent(anchor, FName("None"), 0, 0, 0, false)
        end)
        if okAtt then
            -- bottom of the cylinder sits at the item, so it rises, never sinks
            pcall(function()
                comp.RelativeLocation = { X = 0, Y = 0, Z = CFG.ITEM_MARKER_H * 0.5 }
            end)
        else
            pcall(function() comp:SetAbsolute(false, true, false) end)
        end
        comp:SetStaticMesh(beamMesh)     -- engine cylinder: 100cm tall, centered
        comp:SetRelativeScale3D({
            X = w / 100.0,
            Y = w / 100.0,
            Z = CFG.ITEM_MARKER_H / 100.0,
        })
        if mat then pcall(function() comp:SetMaterial(0, mat) end) end
    end
    return true
end

-- Apply the outline to one valuable. Returns true when finished with this actor
-- (including "correctly skipped"), false to retry later.
-- ======================================================================
-- SPARKLE ENHANCEMENT (the game's own NS_RareProp_01)
-- ======================================================================
local RAREPROP_SPRITE_RENDERER =
    "/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01:Glitter_01_0.NiagaraSpriteRendererProperties_0"
local SPARKLE_SYSTEM_NAMES = { "NS_RareProp_01", "NS_Loot_Glitter_01" }

-- Read-only report of the shared sprite renderer's visibility settings, once per
-- session. This used to WRITE those settings; the log proved the game already
-- ships them at the values we wanted (culling off, max distance 100000, pixel
-- coverage Disabled), so the writes were pure risk for no gain and are gone.
-- Kept as a diagnostic because a game update could change these under us.
local function ReportSparkleRenderer()
    if G.rendererReported then return end
    local sr = StaticFindObject(RAREPROP_SPRITE_RENDERER)
    if not (sr and sr:IsValid()) then return end   -- not loaded yet; try next sweep
    G.rendererReported = true
    pcall(function()
        Log(string.format("sparkle renderer: distanceCulling=%s min=%.0f max=%.0f pixelCoverage=%s",
            tostring(sr.bEnableCameraDistanceCulling), sr.MinCameraDistance,
            sr.MaxCameraDistance, tostring(sr.PixelCoverageMode)))
    end)
end

-- v23: scale the sparkle SIZE curves. These live on the emitter's update script
-- as UNiagaraDataInterfaceCurve objects; `ShaderLUT` is the baked sample table
-- the sim actually reads, and it is a plain reflected float array.
--
-- CRITICAL: this multiplies in place, so it must run exactly ONCE per process.
-- The guard is deliberately NOT cleared on level change (unlike the renderer
-- patch, whose values are absolute) - re-running would compound 2.2x each time
-- and balloon the sparkles into blobs after a few dungeons.
local RAREPROP_CURVES = {
    "/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01:Glitter_01_0.UpdateScript.NiagaraDataInterfaceCurve_0",
    "/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01:Glitter_01_0.UpdateScript.NiagaraDataInterfaceCurve_1",
    "/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01:Glitter_01_0.UpdateScript.NiagaraDataInterfaceCurve_2",
}

local function ScaleSparkleSizeCurves()
    if G.curvesScaled then return end
    if not CFG.SPARKLE_ENABLED or CFG.SPARKLE_SIZE_MULT == 1.0 then return end
    local anyFound = false
    for idx, path in ipairs(RAREPROP_CURVES) do
        pcall(function()
            local di = StaticFindObject(path)
            if not (di and di:IsValid()) then return end
            anyFound = true
            local lut = di.ShaderLUT
            local n = #lut
            if n == 0 then
                Log(string.format("size curve %d: empty LUT (bUseLUT=%s) - skipped",
                    idx - 1, tostring(di.bUseLUT)))
                return
            end
            -- inspect first: a size curve carries real units, alpha curves are 0..1
            local lo, hi = math.huge, -math.huge
            for i = 1, n do
                local v = lut[i]
                if v < lo then lo = v end
                if v > hi then hi = v end
            end
            if hi <= CFG.SPARKLE_SIZE_CURVE_MIN then
                Log(string.format("size curve %d: range %.3f..%.3f - looks like alpha, left alone",
                    idx - 1, lo, hi))
                return
            end
            for i = 1, n do
                lut[i] = lut[i] * CFG.SPARKLE_SIZE_MULT
            end
            Log(string.format("size curve %d: range %.2f..%.2f scaled x%.1f (%d samples)",
                idx - 1, lo, hi, CFG.SPARKLE_SIZE_MULT, n))
        end)
    end
    if anyFound then G.curvesScaled = true end
end

-- v29: rarity tint for the sparkle copies.
--
-- The bug this fixes: a spawned copy of NS_RareProp_01 carries the SYSTEM
-- DEFAULT color, which is the purple/Epic look. The game tints each item's own
-- sparkle to its rarity, so Epic items looked correct by luck while Rare items
-- got purple sparkles mixed into their blue, and Common items got purple/blue
-- mixed into their white.
--
-- Rather than guess the rarity color from our own palette, read it off the
-- item's EXISTING sparkle with UNiagaraComponent:GetVariableColor - that
-- returns whatever the game itself set, so the copies match exactly even where
-- our palette would not. The parameter name is data (FHeldenEffectColorParam is
-- a generic Name/Value pair), so probe a candidate list once and remember the
-- name that answers.
local SPARKLE_COLOR_PARAMS = {
    "Color", "User.Color", "VFXColor", "User.VFXColor",
    "Tint", "User.Tint", "LootColor", "User.LootColor",
    "SparkleColor", "User.SparkleColor", "RarityColor", "User.RarityColor",
}

-- Find the game's own sparkle component on this actor (never one of ours -
-- our copies are recorded in G.fx as they are created).
local function FindOriginalSparkle(actor, mesh)
    local found = nil
    local function scan(parent)
        if found or not (parent and parent:IsValid()) then return end
        pcall(function()
            local kids = parent.AttachChildren
            for i = 1, #kids do
                local kid = kids[i]
                if kid:IsValid() and kid:IsA("/Script/Niagara.NiagaraComponent") then
                    local asset = kid.Asset
                    if asset and asset:IsValid()
                       and asset:GetFullName():find("NS_RareProp_01", 1, true)
                       and not G.fx[kid:GetFullName()] then
                        found = kid
                        return
                    end
                end
            end
        end)
    end
    scan(mesh)
    if not found then pcall(function() scan(actor:K2_GetRootComponent()) end) end
    return found
end

-- Returns paramName, colorTable read from the game's own sparkle, or nil.
--
-- v30: the v29 probe required the bIsValid out-param to come back true and
-- nothing ever did, so every item silently fell through to the palette spray -
-- which uses the same unknown names and therefore did nothing either. Two
-- changes: accept a name when it returns a non-black color even if the flag
-- never lands (an unset Niagara parameter reads back as black), and LOG what
-- every candidate actually returned so the real name is identifiable instead
-- of guessed at.
local function ReadSparkleRarityColor(original)
    if not (original and original:IsValid()) then return nil end
    -- once we know which parameter the game uses, stop probing the rest
    local names = SPARKLE_COLOR_PARAMS
    if G.sparkleColorParam then names = { G.sparkleColorParam } end
    local report = {}
    for _, n in ipairs(names) do
        local col, valid = nil, nil
        pcall(function()
            -- out-param bIsValid: UE4SS lands out values in the FIRST table
            -- passed, keyed by parameter name. It may also simply not land.
            local flag = {}
            col = original:GetVariableColor(FName(n), flag)
            valid = flag.bIsValid
        end)
        if col then
            local r, g, b = col.R or 0, col.G or 0, col.B or 0
            table.insert(report, string.format("%s=%.2f/%.2f/%.2f%s",
                n, r, g, b, valid and "(valid)" or ""))
            if valid or (r + g + b) > 0.01 then
                return n, col, report
            end
        else
            table.insert(report, n .. "=nil")
        end
    end
    return nil, nil, report
end

-- v23: extra copies of the game's own sparkle system on one item, for density.
local function AddSparkleCopies(actor, quality)
    if (CFG.SPARKLE_COPIES or 0) < 1 then return end
    if (G.copyCount or 0) >= CFG.MAX_SPARKLE_COPIES then return end
    -- same settle gate as the rest of the sparkle work: never spawn systems
    -- into a level that is still streaming in
    if S.frame < CFG.FX_SETTLE_FRAMES then return end
    local mesh = actor.RootMesh
    if not (mesh and mesh:IsValid()) then return end

    local sys = StaticFindObject("/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01")
    if not (sys and sys:IsValid()) then
        pcall(LoadAsset, "/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01")
        sys = StaticFindObject("/Game/Effects/ParticleSystems/Loot/NS_RareProp_01.NS_RareProp_01")
    end
    local nlib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not (sys and sys:IsValid()) or not (nlib and nlib:IsValid()) then return end

    -- Size-proportional copy count. Bigger mesh = more surface for the emitter
    -- to spread the same particles over = needs more systems to read as dense.
    -- v26: measured off the STATIC MESH ASSET, not GetActorBounds. The actor
    -- call is an out-param function and its values never landed in the Lua
    -- tables (v25 logged "MEASURE FAILED" for every single item, so every item
    -- silently kept the flat count - which is why big furniture never got the
    -- extra sparkles). UStaticMesh.ExtendedBounds is a plain struct property:
    -- a straight read, no out-params involved.
    local copies = CFG.SPARKLE_COPIES
    local measured = nil
    pcall(function()
        local sm = mesh.StaticMesh
        if not (sm and sm:IsValid()) then return end
        local e = sm.ExtendedBounds.BoxExtent
        if not e then return end
        -- asset bounds are in the mesh's own space - apply the component scale
        -- so a scaled-up prop counts as the size it actually appears on screen
        local sc = mesh:K2_GetComponentScale()
        local sx = math.abs((sc and sc.X) or 1)
        local sy = math.abs((sc and sc.Y) or 1)
        local sz = math.abs((sc and sc.Z) or 1)
        -- average of the two largest axes: a wide flat picture and a tall thin
        -- vase both read as "big surface", while max alone over-rewards one axis
        local a, b, c = math.abs(e.X or 0) * sx, math.abs(e.Y or 0) * sy,
                        math.abs(e.Z or 0) * sz
        local hi1 = math.max(a, math.max(b, c))
        local lo1 = math.min(a, math.min(b, c))
        local mid = (a + b + c) - hi1 - lo1
        local size = (hi1 + mid) * 0.5
        if size <= 0 then return end
        measured = size
        local scaled = CFG.SPARKLE_COPIES * (size / CFG.SPARKLE_REF_EXTENT)
        copies = math.floor(scaled + 0.5)
        if copies < 1 then copies = 1 end
        if copies > CFG.SPARKLE_COPIES_MAX then copies = CFG.SPARKLE_COPIES_MAX end
    end)

    -- Per-item diagnostic for the first few. `measured=nil` means the bounds
    -- read failed and every item silently fell back to the flat count - the
    -- exact failure mode that made v24 look like it had done nothing.
    G.sizeLogged = (G.sizeLogged or 0) + 1
    if G.sizeLogged <= 8 then
        Log(string.format("sparkle sizing: %s extent=%s -> %d copies, speed x%.1f",
            (actor:GetFullName():match("^([%w_]+)") or "item"),
            measured and string.format("%.0fcm", measured) or "MEASURE FAILED",
            copies, CFG.SPARKLE_SPEED * (measured
                and math.min(CFG.SPARKLE_SPEED_MAX_MULT,
                             math.max(1.0, measured / CFG.SPARKLE_REF_EXTENT))
                or 1.0)))
    end

    -- Big items also twinkle SLOWER to the eye: the same spawn rate spread over
    -- more surface means any given spot on a wardrobe lights up far less often
    -- than on a candlestick. Scale the spawn rate with size too, not just count.
    local speedMult = 1.0
    if measured then
        speedMult = math.max(1.0, measured / CFG.SPARKLE_REF_EXTENT)
        if speedMult > CFG.SPARKLE_SPEED_MAX_MULT then
            speedMult = CFG.SPARKLE_SPEED_MAX_MULT
        end
    end

    -- Rarity tint, read off this item's OWN sparkle so the copies match the game
    -- exactly. Falls back to our palette only if the read fails.
    local original = FindOriginalSparkle(actor, mesh)
    local paramName, tint, report = ReadSparkleRarityColor(original)
    if paramName and not G.sparkleColorParam then
        G.sparkleColorParam = paramName   -- same name on every item; probe once
        Log(string.format("sparkle color param discovered: '%s' = %.2f/%.2f/%.2f",
            paramName, tint.R or 0, tint.G or 0, tint.B or 0))
    end

    -- CORRECTNESS GATE: a copy spawned from the shared asset carries the system
    -- default, which is the purple/Epic look. If we cannot tint it, adding it
    -- would put purple sparkles on white and blue items - the exact bug being
    -- fixed. Fewer sparkles is the better failure, so bail out instead.
    if not paramName then
        if not G.logged.tintFallback then
            G.logged.tintFallback = true
            Log("sparkle tint: cannot set the copies' color - skipping extra copies "
                .. "so white/blue items keep their own sparkle color. "
                .. "Only the game's own (correctly colored) sparkle is boosted.")
            Log("sparkle color probe (original component): "
                .. table.concat(report or {}, "  "))
            if original and original:IsValid() then
                pcall(function()
                    Log("sparkle probe source: " .. original.Asset:GetFullName())
                end)
            else
                Log("sparkle probe source: NO original sparkle component found on the item"
                    .. " - that alone would explain the failed read")
            end
        end
        return
    end

    for i = 1, copies do
        -- stop mid-item if the level budget runs out
        if (G.copyCount or 0) >= CFG.MAX_SPARKLE_COPIES then break end
        local fx = nlib:SpawnSystemAttached(sys, mesh, FName("None"),
            { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 },
            3, false, true, 0, false)
        if fx and fx:IsValid() then
            -- Tint FIRST: a spawned copy carries the system default (purple),
            -- which is what contaminated white and blue items before v29.
            -- paramName is guaranteed non-nil here - the gate above returns
            -- early rather than spawning a copy we cannot color.
            pcall(function() fx:SetNiagaraVariableLinearColor(paramName, tint) end)
            -- desync so the copies twinkle independently instead of in lockstep
            pcall(function()
                fx:SetCustomTimeDilation(CFG.SPARKLE_SPEED * speedMult * (1.0 + 0.3 * i))
            end)
            G.copyCount = (G.copyCount or 0) + 1
            G.fx[fx:GetFullName()] = true  -- don't re-boost our own copies
        end
    end
    if not G.logged.sizeSample then
        G.logged.sizeSample = true
        Log("sparkle density: first item got " .. copies .. " copies (size-scaled)")
    end
end

-- Boost the live sparkle components. Cheap: reads Asset name off each Niagara
-- component, touches only the two loot-glitter systems.
local function BoostSparkleComponents()
    if not CFG.SPARKLE_ENABLED then return end
    local ok, comps = pcall(FindAllOf, "NiagaraComponent")
    -- v33 instrumentation: "sparkle systems boosted" has never appeared in any
    -- log, through two attempted fixes, so the failure is somewhere in this
    -- filter chain rather than in one specific test. Count every drop-out stage
    -- and sample the asset names actually present, then report once per level.
    local D = { found = 0, junk = 0, noasset = 0, nomatch = 0, unreg = 0, dormant = 0,
                noowner = 0, defowner = 0, boosted = 0, names = {}, nameN = 0 }
    if not ok or not comps then
        if not G.logged.sweepDiag then
            G.logged.sweepDiag = true
            Log("sparkle sweep: FindAllOf('NiagaraComponent') returned nothing"
                .. " (ok=" .. tostring(ok) .. ") - no components to boost at all")
        end
        return
    end
    local boosted = 0
    for _, c in ipairs(comps) do
        pcall(function()
            if not c:IsValid() then return end
            local key = c:GetFullName()
            D.found = D.found + 1
            if G.fx[key] then return end

            -- HARDENING (v23.1 - this pass caused intermittent load crashes).
            -- FindAllOf returns every object of the class, which includes things
            -- that are NOT live world components: class defaults, blueprint
            -- archetypes (..._C:NS_Loot_01_GEN_VARIABLE), and the sequence-owned
            -- copy inside LS_OpenBall_01. Calling component setters on those has
            -- no valid world/scene behind it. Whether they are resident at sweep
            -- time depends on load order, which is why it crashed on some loads
            -- and not others. Mark them consumed so we never retry them.
            if key:find("Default__") or key:find("GEN_VARIABLE")
               or key:find("ArchetypeObject") or key:find("MovieScene")
               or key:find("LS_", 1, true) then
                D.junk = D.junk + 1
                G.fx[key] = true
                return
            end

            local asset = c.Asset
            if not (asset and asset:IsValid()) then D.noasset = D.noasset + 1 return end
            local an = asset:GetFullName()
            local match = false
            for _, n in ipairs(SPARKLE_SYSTEM_NAMES) do
                if an:find(n, 1, true) then match = true; break end
            end
            if D.nameN < 10 then
                D.nameN = D.nameN + 1
                D.names[D.nameN] = an:match("([^/%.]+)%.[^%.]+$") or an
            end

            if not match then
                D.nomatch = D.nomatch + 1
                G.fx[key] = true   -- wrong system: never look at it again
                return
            end

            -- Must be owned by a real, live actor.
            --
            -- v34: the old `bRegistered` gate is GONE. It rejected every single
            -- matching component from v23.1 to v33 (the v33 census read
            -- "unregistered=38, boosted=0" - those 38 were the real item
            -- sparkles). The reason: bRegistered is NOT a reflected property -
            -- it does not appear anywhere in the SDK dump - so the read returned
            -- nil and no comparison against it could ever be true. v32's
            -- "1 == true" theory was wrong; the value was never readable at all.
            --
            -- The crash hardening it was supposed to provide is actually done by
            -- the junk-name filter above plus the owner checks below: class
            -- defaults, archetypes and sequence templates have no live owner.
            -- IsActive() is a soft extra check - if it is unavailable the pcall
            -- leaves `active` true and we fall through to the owner test.
            -- v37: the IsActive() gate is GONE.
            --
            -- It rejected 20-22 components on every sweep while `boosted` sat
            -- stuck at 11. Niagara deactivates systems the player is not near,
            -- so a sparkle on an unapproached item reads as inactive - and that
            -- item then never got queued for a glow. It is exactly why a bench
            -- stayed dark until it was grabbed: handling it woke the system, the
            -- next sweep finally saw it, and the light appeared seconds later.
            --
            -- Dormant is not the same as invalid: these are real registered
            -- world components. The junk-name filter above and the owner checks
            -- below are what actually keep archetypes and templates out.
            D.dormant = D.dormant + 1  -- counted for the census, no longer skipped
            local owner = c:GetOwner()
            if not (owner and owner:IsValid()) then D.noowner = D.noowner + 1 return end
            local oname = owner:GetFullName()

            if oname:find("Default__") or oname:find("GEN_VARIABLE")

               or oname:find("ArchetypeObject") then
                G.fx[key] = true
                return
            end

            G.fx[key] = true
            -- NB: scale only. No ReinitializeSystem (froze the game once), no
            -- parameter-store iteration (froze it the same day).
            c:SetRelativeScale3D({ X = CFG.SPARKLE_SCALE, Y = CFG.SPARKLE_SCALE,
                                   Z = CFG.SPARKLE_SCALE })
            c:SetCustomTimeDilation(CFG.SPARKLE_SPEED)
            boosted = boosted + 1

            -- v31: mark this component's OWNER as a valuable.
            --
            -- Chairs, tables and paintings never got a rarity light because the
            -- actor sweep only looked for AHeldenPhysTreasure - but most sellable
            -- dungeon furniture is a plain construct actor, so it was never even
            -- considered. Rather than widen the sweep to every construct in the
            -- level (thousands, most of them scenery, and the caps would be spent
            -- on whatever was found first), use the game's OWN signal: it attaches
            -- this sparkle to exactly the props that are worth something. If it
            -- sparkles, it is loot, so queue it. ApplyOutline still does the
            -- quality checks and the caps still apply.
            if CFG.MARK_SPARKLING_ACTORS then
                local oKey = owner:GetFullName()
                if not G.done[oKey] then
                    table.insert(G.queue,
                        { actor = owner, readyFrame = S.frame + CFG.QUEUE_DELAY })
                    G.sparkOwners = (G.sparkOwners or 0) + 1
                end
            end
        end)
    end
    if boosted > 0 then
        G.fxCount = (G.fxCount or 0) + boosted
        if not G.logged.fx or G.fxCount % 25 == 0 then
            G.logged.fx = true
            Log(string.format("sparkle systems boosted: %d total, %d sparkling actors queued",
                G.fxCount, G.sparkOwners or 0))
        end
    end

    -- v35: what rarities does this level actually contain? Confirms Excellent
    -- (quality 3) items are now being marked instead of silently dropped.
    if G.qHist and not G.logged.qHist and (G.count or 0) >= 8 then
        G.logged.qHist = true
        local parts = {}
        for q = 0, 3 do
            if G.qHist[q] then
                table.insert(parts, QualityName(q) .. "=" .. G.qHist[q])
            end
        end
        Log("rarities marked so far: " .. table.concat(parts, ", "))
    end

    -- v33: report the filter chain once per level. Whichever number is large is
    -- the stage that has been silently eating every component since v23.1.
    if not G.logged.sweepDiag and D.found > 0 then
        G.logged.sweepDiag = true
        Log(string.format(
            "sparkle sweep census: seen=%d junk=%d noasset=%d wrongsystem=%d dormant-but-kept=%d noowner=%d boosted=%d",
            D.found, D.junk, D.noasset, D.nomatch, D.dormant, D.noowner, boosted))
        if D.nameN > 0 then
            Log("sparkle sweep saw these systems: " .. table.concat(D.names, ", ", 1, D.nameN))
        end
    end
end

-- A rarity-colored point light on the item. No geometry, no orientation, so it
-- behaves the same on a wall picture as on a floor prop.
local function AddRarityLight(actor, quality)
    if not CFG.ITEM_LIGHT then return end
    if (G.lightCount or 0) >= CFG.MAX_ITEM_LIGHTS then return end

    local lightClass = StaticFindObject("/Script/Engine.PointLightComponent")
    if not (lightClass and lightClass:IsValid()) then return end

    -- reprocess guard: a point light child means we already did this actor
    -- v36: dedupe on OUR OWN registry, not "does this actor own a point light".
    --
    -- The old test asked whether the actor already had any PointLightComponent
    -- child and bailed if so. That is true for anything that is itself a lamp -
    -- a Floor Light owns a point light for its bulb - so every light-emitting
    -- valuable was skipped and never got a rarity glow, while the chair beside
    -- it did. Lamps, TVs, candles and braziers were all affected.
    --
    -- Actors are destroyed and rebuilt on level travel and this registry is
    -- cleared alongside the rest of the per-level state, so it cannot go stale.
    local akey = actor:GetFullName()
    G.litActors = G.litActors or {}
    if G.litActors[akey] then return end
    G.litActors[akey] = true

    local identity = {
        Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 0 },
        Scale3D     = { X = 1, Y = 1, Z = 1 },
    }
    -- DEFERRED creation is the whole trick here. A light component registers on
    -- creation, and a component created at runtime lands on Static mobility -
    -- a Static light with no baked lightmap contributes exactly nothing, which
    -- is why v24's lights were built successfully and still lit nothing.
    -- bDeferredFinish=true lets us set mobility and all the light properties
    -- BEFORE registration, then FinishAddComponent registers it for real.
    local light = actor:AddComponentByClass(lightClass, true, identity, true)
    -- v37: some actors return nothing from the deferred path. Retry immediately
    -- with the simple non-deferred form before giving up - a light that is
    -- Static-by-default is still far better than no light at all, and the
    -- mobility write below is attempted either way.
    local deferred = true
    if not (light and light:IsValid()) then
        deferred = false
        pcall(function()
            light = actor:AddComponentByClass(lightClass, false, identity, false)
        end)
    end
    if not (light and light:IsValid()) then
        -- log per CLASS, not once globally, so we can see which item types
        -- refuse a runtime light (small tables, paintings and beds are the
        -- reported offenders)
        local cls = akey:match("^([%w_]+)") or "item"
        G.lightFailClasses = G.lightFailClasses or {}
        if not G.lightFailClasses[cls] then
            G.lightFailClasses[cls] = true
            Log("RARITY LIGHT FAILED on " .. cls
                .. " - both deferred and immediate AddComponentByClass returned nothing")
        end
        return
    end

    -- mobility first, by property write (SetMobility is refused once registered)
    pcall(function() light.Mobility = 2 end)            -- EComponentMobility::Movable
    pcall(function() light:SetMobility(2) end)          -- belt and braces

    local c = OutlineColorFor(quality)
    pcall(function() light.IntensityUnits = 1 end)      -- ELightUnits::Candelas
    pcall(function() light.Intensity = CFG.ITEM_LIGHT_INTENSITY end)
    pcall(function() light.AttenuationRadius = CFG.ITEM_LIGHT_RADIUS end)
    pcall(function() light.LightColor = {
        R = math.floor(math.min(1, c.R) * 255),
        G = math.floor(math.min(1, c.G) * 255),
        B = math.floor(math.min(1, c.B) * 255), A = 255 } end)
    pcall(function() light.CastShadows = false end)
    pcall(function() light.bAffectsWorld = true end)

    -- register it. Only the deferred path needs finishing - the fallback above
    -- was created already-registered, and calling Finish on it would be wrong.
    local finished = true
    if deferred then
        finished = pcall(function()
            actor:FinishAddComponent(light, false, identity)
        end)
    end

    -- post-registration setters: these are the ones that mark the render state
    -- dirty, so the values above actually reach the renderer
    pcall(function() light:SetCastShadows(false) end)
    pcall(function() light:SetAttenuationRadius(CFG.ITEM_LIGHT_RADIUS) end)
    pcall(function() light:SetIntensity(CFG.ITEM_LIGHT_INTENSITY) end)
    -- bSRGB=FALSE. SetLightColor runs the value through ToFColor(bSRGB), and
    -- with sRGB encoding on, dark channels get lifted enormously (0.10 linear
    -- becomes ~0.35), which desaturates every rarity toward white - that plus
    -- 400cd of channel clipping is why v25 lit everything plain white.
    -- Only ONE call: the old second, single-arg call re-ran the same function
    -- with a garbage/defaulted flag and could undo the first.
    pcall(function() light:SetLightColor(c, false) end)
    pcall(function() light:SetVisibility(true, false) end)

    G.lightCount = (G.lightCount or 0) + 1

    -- verify by reading the values back off the live component
    if G.lightCount <= 10 or G.lightCount % 20 == 0 then
        local mob, inten, rad, vis, col = "?", "?", "?", "?", "?"
        pcall(function() mob = tostring(light.Mobility) end)
        pcall(function() inten = tostring(light.Intensity) end)
        pcall(function() rad = tostring(light.AttenuationRadius) end)
        pcall(function() vis = tostring(light.bVisible) end)
        -- read the color back: if this comes back as 255/255/255 on a Rare or
        -- Epic item, the tint is not landing and the palette is not the problem
        pcall(function()
            local lc = light.LightColor
            col = string.format("%d/%d/%d", lc.R, lc.G, lc.B)
        end)
        local qname = QualityName(quality)
        Log(string.format(
            "RARITY LIGHT #%d %s on %s (finished=%s): mobility=%s (2=Movable) intensity=%s radius=%s visible=%s color=%s",
            G.lightCount, qname, (akey:match("^([%w_]+)") or "item"), tostring(finished), mob, inten, rad, vis, col))
    end
end

local function ApplyOutline(actor)
    local name = actor:GetFullName()
    if name:find("Default__") or name:find("GEN_VARIABLE") then return true end

    local mesh = actor.RootMesh
    if not (mesh and mesh:IsValid()) then return false end  -- still spawning

    -- uint8 enum: UE4SS hands these back as plain numbers, but coerce anyway so
    -- a wrapper type can never blow up the comparisons below
    local quality = nil
    pcall(function() quality = tonumber(actor.ConstructQuality) end)
    if quality == nil then return true end          -- not a quality-bearing actor
    -- v35: was `quality >= 3 then return`. That silently dropped every
    -- "Excellent" item - the fourth tier, which the SDK dump mislabels
    -- BuiltConstruct. A floor light that inspects as Excellent and carries pale
    -- blue sparkles got no glow purely because of this line.
    if quality > CFG.OUTLINE_MAX_QUALITY then return true end
    if quality < CFG.OUTLINE_MIN_QUALITY then return true end
    -- record what qualities actually exist in the level, for verification
    G.qHist = G.qHist or {}
    G.qHist[quality] = (G.qHist[quality] or 0) + 1

    -- the rarity light is the primary marker in v22 - cheap and alignment-proof
    pcall(AddRarityLight, actor, quality)
    -- v23: extra copies of the game's own sparkle for density on this item
    pcall(AddSparkleCopies, actor, quality)

    -- hard ceiling: leave the rest unmarked rather than risk the level
    if G.count >= CFG.MAX_ITEM_MARKERS then
        if not G.logged.capped then
            G.logged.capped = true
            Log("marker cap reached (" .. CFG.MAX_ITEM_MARKERS
                .. ") - further valuables left unmarked")
        end
        return true
    end

    ResolveGlowMaterial()
    local mat = BuildOverlayMaterial(actor, quality)

    -- Layer 1: the upright rarity beam (3 components, no particles).
    -- NB: capture BOTH pcall returns. `ok` only means "did not throw"; the
    -- second is the verdict (false = actor still mid-spawn, retry later).
    -- Collapsing them silently marked unbuilt items as done in an earlier build.
    local markOk = true
    if CFG.ITEM_BEAMS then
        local okCall, built = pcall(MarkValuable, actor, mat)
        markOk = okCall and built
    end

    -- Layer 2: overlay glow shell on the item's own mesh. Costs no components,
    -- best-effort - if the material will not draw as an overlay, the beam above
    -- still carries the feature.
    local alreadyOverlaid = false
    pcall(function()
        local om = mesh.OverlayMaterial
        alreadyOverlaid = om and om:IsValid()
    end)
    if not alreadyOverlaid and mat then
        pcall(function() mesh:SetOverlayMaterial(mat) end)
    end

    if not markOk then return false end

    G.count = G.count + 1
    local qname = QualityName(quality)
    if G.count <= 8 or G.count % 25 == 0 then
        Log(string.format("valuable #%d: %s marked on %s",
            G.count, qname, name:match("^([%w_]+)") or "item"))
    end
    return true
end

OutlineSweep = function()
    -- the game's own sparkles first: one shared-asset patch plus a pass over
    -- live sparkle components. Runs even when the outline feature is off.
    -- Sparkle work is deliberately gated behind a settle delay: touching Niagara
    -- components while the level is still streaming caused intermittent
    -- crash-on-load (reported 2026-08-17). None of this is time-critical.
    if CFG.SPARKLE_ENABLED and S.frame >= CFG.FX_SETTLE_FRAMES then
        pcall(ReportSparkleRenderer)
        pcall(ScaleSparkleSizeCurves)
        -- The Niagara pass walks every UNiagaraComponent in the level (~250 of
        -- them). New sparkle systems only appear when new props stream in, so
        -- running it on every sweep is wasted work - stagger it.
        G.fxSweepTick = (G.fxSweepTick or 0) + 1
        if G.fxSweepTick % CFG.FX_SWEEP_EVERY == 0 then
            pcall(BoostSparkleComponents)
        end
    end
    if not CFG.OUTLINE_ENABLED then return end
    local found = 0
    for _, classPath in ipairs(TREASURE_CLASSES) do
        local shortName = classPath:match("([%w_]+)$")
        local ok, actors = pcall(FindAllOf, shortName)
        if ok and actors then
            for _, a in ipairs(actors) do
                local queued = false
                pcall(function()
                    if not G.done[a:GetFullName()] then
                        found = found + 1
                        queued = true
                    end
                end)
                if queued then
                    table.insert(G.queue, { actor = a, readyFrame = S.frame + CFG.QUEUE_DELAY })
                end
            end
        end
    end
    if found > 0 and not G.logged.first then
        G.logged.first = true
        Log("outline sweep: " .. found .. " valuable(s) queued")
    end
end

-- Drained one per frame alongside the beam queue.
OutlineDrain = function()
    if #G.queue == 0 or G.queue[1].readyFrame > S.frame then return end
    -- spread builds out: a loot-dense room must never spike a single frame
    if S.frame % CFG.ITEM_BUILD_INTERVAL ~= 0 then return end
    local entry = table.remove(G.queue, 1)
    local a = entry.actor
    if not (a and a:IsValid()) then return end
    local key
    local okKey = pcall(function() key = a:GetFullName() end)
    if not okKey or not key or G.done[key] then return end

    local ok, finished = pcall(ApplyOutline, a)
    if ok and finished then
        G.done[key] = true
    else
        entry.tries = (entry.tries or 0) + 1
        if entry.tries < 12 then
            entry.readyFrame = S.frame + CFG.QUEUE_DELAY
            table.insert(G.queue, entry)
        else
            G.done[key] = true  -- give up quietly (collected/rootless leftovers)
        end
    end
end

-- Event-driven intake. NotifyOnNewObject binds to the class OBJECT, which
-- gets reinstanced on level travel - a registration from the previous level
-- silently never fires again (diagnosed 2026-08-15: dropped coins only
-- appeared via the 3s catch-up sweeps after the first map change). Track the
-- class address and re-register whenever it changes (called at load and from
-- the ClientRestart hook). Duplicate queue entries are harmless: the drain
-- skips spots already in S.processed.
local NotifyAddr = {}
local function RegisterNotifies()
    for _, sc in ipairs(SPOT_CLASSES) do
        pcall(function()
            local cls = StaticFindObject(sc.path)
            if not (cls and cls:IsValid()) then return end
            local addr = cls:GetAddress()
            if NotifyAddr[sc.path] == addr then return end
            NotifyAddr[sc.path] = addr
            NotifyOnNewObject(sc.path, function(spot)
                table.insert(S.queue,
                    { spot = spot, color = sc.color, mat = sc.mat,
                      readyFrame = S.frame + CFG.QUEUE_DELAY })
            end)
            Log("notify (re)registered for " .. sc.path:match("([%w_]+)$"))
        end)
    end
end
RegisterNotifies()

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
               or (S.sweepDone and S.frame % (S.sweepInterval or CFG.RESWEEP_FRAMES) == 0) then
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

            -- rarity outlines: same one-per-frame budget as the beam queue
            local okG, errG = pcall(OutlineDrain)
            if not okG then
                S.errCount = S.errCount + 1
                Log("outline error (" .. S.errCount .. "/8): " .. tostring(errG))
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
        pcall(RegisterNotifies) -- rebind if the coin classes were reinstanced
        S.processed = {}
        S.queue = {}
        S.errCount = 0
        S.sweepDone = false
        S.frame = 0
        S.beamCount = 0
        -- outlines: new level means new valuables; drop the seen-set and let the
        -- sweep re-find them. Material resolution is level-independent, so it is
        -- deliberately NOT reset (re-resolving would just re-log the same line).
        G.queue = {}
        G.done = {}
        G.count = 0
        G.logged = {}
        -- sparkle components and lights belong to the old level's actors
        G.fx = {}
        G.fxCount = 0
        G.lightCount = 0
        G.sparkOwners = 0

        G.qHist = {}


        G.litActors = {}
        G.copyCount = 0
        -- NB: G.curvesScaled is deliberately NOT reset. The size curves are
        -- multiplied in place on a shared asset that survives level travel;
        -- re-running would compound the multiplier every dungeon.
        G.fxSweepTick = 0
        -- NB: G.rendererReported is NOT reset - it is a read-only diagnostic of
        -- a shared asset, and re-logging it every level is just noise.
    end)
end)

Log(string.format(
    "loaded v37 (dormant sparkles kept + light fallback; copies off; settle gate %d frames; NS_RareProp size curve x%.1f, speed x%.1f, copies size-scaled %d@%.0fcm max %d/item cap %d; rarity light %s i=%.0fcd r=%.0f cap %d, deferred-Movable; item beams %s; min quality %d)",
    CFG.SWEEP_WARMUP,
    CFG.SPARKLE_SIZE_MULT, CFG.SPARKLE_SPEED,
    CFG.SPARKLE_COPIES, CFG.SPARKLE_REF_EXTENT, CFG.SPARKLE_COPIES_MAX,
    CFG.MAX_SPARKLE_COPIES,
    CFG.ITEM_LIGHT and "ON" or "off", CFG.ITEM_LIGHT_INTENSITY,
    CFG.ITEM_LIGHT_RADIUS, CFG.MAX_ITEM_LIGHTS,
    CFG.ITEM_BEAMS and "ON" or "off", CFG.OUTLINE_MIN_QUALITY))
