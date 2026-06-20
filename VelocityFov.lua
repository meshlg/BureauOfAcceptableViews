-- ===========================================================================
-- VelocityFov.lua
-- ---------------------------------------------------------------------------
-- Optional velocity-reactive field of view.
--
-- When enabled, the third-person FOV widens the faster the player is actually
-- MOVING, for a cinematic sense of speed, and eases back as they slow. The speed
-- signal is the player's real movement speed, derived from the change in world
-- position between samples -- not a discrete movement state. This means the effect
-- responds continuously to ANY source of speed (sprint, mount, swimming, speed
-- buffs like Major Expedition, the Steed mundus, potions) without caring which,
-- and without depending on LibSprint.
--
-- Why position sampling is safe here: ESO exposes no per-frame speed query, but we
-- do NOT sample per frame. We sample on a 150ms timer (the same cadence the rest of
-- the addon uses for sprint polling) only while the feature is enabled, so the cost
-- profile is identical to the old state-poll model -- nothing on the per-frame path.
--
-- The three classic pitfalls of position-derived speed are handled explicitly:
--   * Zone change / teleport / load screen -> GetUnitWorldPosition also returns the
--     zoneId; when it changes we re-baseline and skip the sample (no false spike).
--     A same-zone jump above a plausible-speed ceiling (wayshrine, lag snap) is also
--     skipped rather than fed into the boost.
--   * Rubber-banding / lag jitter -> the raw per-sample speed is smoothed with a
--     light exponential moving average before it maps to a boost, and the boost
--     itself eases via the ramp, so a brief network wobble does not jiggle the FOV.
--   * Axes -> ESO world position is (x, y, z) with y vertical. We measure HORIZONTAL
--     distance from x/z only, so jumping, falling, slopes, and swimming up/down do
--     not inflate the speed; only real ground movement does.
--
-- Composition / ownership:
--   * This module NEVER writes FOV directly. It computes a boost (degrees) and
--     pushes it through FovArbiter.SetVelocityBoost, which adds it on top of the
--     base FOV DynamicFov computes (zoom-interpolated, or the player's manual FOV
--     when zoom-based FOV is off). Routing through the arbiter means a context
--     preset that pins FOV automatically suppresses the boost, with no fighting.
--   * ON by default, but inert until you move fast: a stationary or walking player
--     gets no boost, and a single toggle turns it off (a disabled module registers
--     nothing, polls nothing, and pushes no boost, so FOV is left exactly as the
--     game / other modules set it).
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.VelocityFov = addon.VelocityFov or {}
local VelocityFov = addon.VelocityFov

-- Hot-path / library globals bound to locals once at load.
local tonumber = tonumber
local mathabs  = math.abs
local mathsqrt = math.sqrt
local stringformat = string.format
local EVENT_MANAGER           = EVENT_MANAGER
local GetGameTimeMilliseconds = GetGameTimeMilliseconds
local GetUnitWorldPosition    = GetUnitWorldPosition
local WINDOW_MANAGER          = WINDOW_MANAGER

-- Logging helpers are generated in the core file and exported on private.
-- Resolve them lazily so load order between files cannot break us.
local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

-- ---------------------------------------------------------------------------
-- Tuning constants
-- ---------------------------------------------------------------------------
-- Maximum boost (degrees) at sensitivity 1.0 and full speed. The engine clamps
-- third-person FOV to 35..65, so ~12 is plenty to read as "wider" without slamming
-- the ceiling on every base FOV. Sensitivity (0..1) scales this linearly.
local MAX_BOOST_DEGREES = 12

-- Speed sampling cadence (ms). Matches the sprint-poll cadence used elsewhere; the
-- boost ramp smooths between samples so this need not be fine-grained.
local POLL_MS = 150

-- Speed-to-boost mapping (cm/s; GetUnitWorldPosition is in centimetres). Below MIN
-- there is no boost (walking / jogging stays neutral); at/above MAX the boost is
-- full. Between, it scales linearly. These are reasonable defaults -- real ESO
-- speeds are surfaced in /bav dump so they can be calibrated in-game if needed.
local SPEED_MIN_CMS = 500
local SPEED_MAX_CMS = 1000

-- A single sample faster than this is not real locomotion (a teleport, wayshrine,
-- or a lag snap); it is skipped rather than fed into the boost.
local MAX_PLAUSIBLE_SPEED_CMS = 5000

-- Exponential-moving-average factor for the raw per-sample speed (0..1): higher
-- reacts faster, lower smooths harder. 0.5 takes the edge off lag jitter while
-- still feeling responsive within a couple of samples.
local SPEED_SMOOTHING = 0.5

-- Total time (ms) for the boost to ease toward its target. Time-based (not a fixed
-- per-frame step) so the ease feels identical regardless of frame rate, matching
-- the glide discipline DynamicFov / FovArbiter / ContextPresets use. A retarget
-- mid-ease restarts from the live boost over this same window.
local RAMP_DURATION_MS = 350

-- Two boosts closer than this are treated as identical, so the ramp settles and
-- stops pushing writes. Matches DynamicFov's FOV precision slack.
local BOOST_EPSILON = 0.05

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
-- All inert until Configure{enabled=true}. sampling/optionsOpen gate the speed
-- timer and the options-window suspension. lastZoneId/lastX/lastZ/lastSampleMs are
-- the previous position sample (nil until the first sample baselines them).
-- smoothedSpeed is the EMA-filtered speed (cm/s). currentBoost is what we last
-- pushed; targetBoost is where the ramp is heading. debug toggles the on-screen
-- readout (which keeps the sampler running even when the boost itself is off).
local controller = {
    enabled       = true,
    sensitivity   = 0.75,
    debug         = false,
    currentBoost  = 0,
    targetBoost   = 0,
    sampling      = false,
    optionsOpen   = false,
    rampActive    = false,
    rampFromBoost = 0,
    rampStartMs   = nil,
    -- Position-sampling state for speed derivation.
    lastZoneId    = nil,
    lastX         = nil,
    lastZ         = nil,
    lastSampleMs  = nil,
    smoothedSpeed = 0,
}

local EVENT_NAMESPACE = "BAV_VelocityFov"
local SAMPLE_NAME     = "BAV_VelocityFov_Sample"
local RAMP_NAME       = "BAV_VelocityFov_Ramp"

-- ---------------------------------------------------------------------------
-- Boost target + push
-- ---------------------------------------------------------------------------

-- Map a smoothed speed (cm/s) to a boost target (degrees). Below SPEED_MIN_CMS the
-- boost is 0 (walking/jogging stays neutral); at/above SPEED_MAX_CMS it is the full
-- sensitivity-scaled boost; linear in between. Returns 0 while disabled or while the
-- options window is open (the player may be editing FOV).
local function ResolveTargetBoost()
    if not controller.enabled or controller.optionsOpen then
        return 0
    end

    local speed = controller.smoothedSpeed
    if speed <= SPEED_MIN_CMS then
        return 0
    end

    local span = SPEED_MAX_CMS - SPEED_MIN_CMS
    local t = (span > 0) and ((speed - SPEED_MIN_CMS) / span) or 1
    if t > 1 then t = 1 end

    return MAX_BOOST_DEGREES * controller.sensitivity * t
end

-- Push the current boost to the FOV arbiter (which composes base + boost and obeys
-- preset holds). Lazy/guarded so a missing arbiter just means no boost is applied.
local function PushBoost()
    local arbiter = addon.FovArbiter
    if arbiter and arbiter.SetVelocityBoost then
        arbiter.SetVelocityBoost(controller.currentBoost)
    end
end

-- ---------------------------------------------------------------------------
-- Boost ramp (self-tearing-down updater)
-- ---------------------------------------------------------------------------
-- Eases currentBoost from rampFromBoost toward targetBoost over RAMP_DURATION_MS,
-- pushing each interpolated value. Time-based (not a fixed step per frame) so the
-- ease feels identical at any frame rate. On the final frame it lands exactly and
-- unregisters itself, so an idle module carries no per-frame cost.

local function StopRamp()
    if controller.rampActive then
        EVENT_MANAGER:UnregisterForUpdate(RAMP_NAME)
        controller.rampActive = false
    end
    controller.rampStartMs = nil
end

local function OnRampUpdate()
    if not controller.rampActive or controller.rampStartMs == nil then
        StopRamp()
        return
    end

    local t = (GetGameTimeMilliseconds() - controller.rampStartMs) / RAMP_DURATION_MS
    if t < 0 then t = 0 end

    if t >= 1 then
        -- Final frame: land exactly on the target and stop ramping.
        controller.currentBoost = controller.targetBoost
        StopRamp()
        PushBoost()
        return
    end

    controller.currentBoost = controller.rampFromBoost
        + (controller.targetBoost - controller.rampFromBoost) * t
    PushBoost()
end

-- Retarget the ramp toward a new boost. Snaps instantly (no updater) when already
-- within an epsilon; otherwise (re)starts the temporary ramp updater, easing from
-- the LIVE currentBoost over a fresh window so a re-target never snaps back.
local function RampTo(target)
    controller.targetBoost = target

    if mathabs(target - controller.currentBoost) <= BOOST_EPSILON then
        StopRamp()
        controller.currentBoost = target
        PushBoost()
        return
    end

    controller.rampFromBoost = controller.currentBoost
    controller.rampStartMs = GetGameTimeMilliseconds()
    if not controller.rampActive then
        controller.rampActive = true
        EVENT_MANAGER:RegisterForUpdate(RAMP_NAME, 0, OnRampUpdate)
    end
end

-- ---------------------------------------------------------------------------
-- Speed sampling
-- ---------------------------------------------------------------------------
-- Derives horizontal movement speed from the change in world position between two
-- samples, guarding against the three classic pitfalls (zone change, teleport/lag
-- snap, vertical motion -- see the file header), then smooths it and re-targets the
-- boost. Runs on the SAMPLE timer while the feature OR the debug overlay is on.

-- Forward declaration: OnSampleSpeed refreshes the debug overlay, which is defined
-- below it (it needs the sampling helpers). Declared local here so the assignment
-- further down fills this upvalue rather than creating a global.
local UpdateOverlay

-- Reset the position baseline so the NEXT sample establishes a fresh reference
-- without producing a speed reading. Used on enable, zone change, and resume.
local function ResetSampleBaseline()
    controller.lastZoneId   = nil
    controller.lastX        = nil
    controller.lastZ        = nil
    controller.lastSampleMs = nil
end

local function OnSampleSpeed()
    local nowMs = GetGameTimeMilliseconds()
    -- GetUnitWorldPosition returns absolute centimetres: zoneId, x, y, z (y up).
    local zoneId, x, _y, z = GetUnitWorldPosition("player")

    -- First sample, or a zone change / teleport: (re)baseline and read no speed
    -- this tick. A changed zoneId means the coordinates are not comparable, so any
    -- delta would be a meaningless spike.
    if controller.lastSampleMs == nil or controller.lastZoneId ~= zoneId then
        controller.lastZoneId   = zoneId
        controller.lastX        = x
        controller.lastZ        = z
        controller.lastSampleMs = nowMs
        return
    end

    local dtMs = nowMs - controller.lastSampleMs
    -- Update the baseline regardless of how we treat this sample, so a skipped
    -- sample does not compound into the next delta.
    local dx = x - controller.lastX
    local dz = z - controller.lastZ
    controller.lastX        = x
    controller.lastZ        = z
    controller.lastSampleMs = nowMs

    if dtMs <= 0 then
        return
    end

    -- Horizontal distance only (x/z); y is vertical, so jumps/falls/slopes do not
    -- inflate speed. Distance (cm) / time (s) -> cm/s.
    local distance = mathsqrt(dx * dx + dz * dz)
    local rawSpeed = distance / (dtMs / 1000)

    -- A single implausibly fast sample is a teleport / wayshrine / lag snap, not
    -- locomotion: skip it (leave smoothedSpeed as-is) so it never spikes the FOV.
    if rawSpeed > MAX_PLAUSIBLE_SPEED_CMS then
        return
    end

    -- Light EMA to take the edge off rubber-banding jitter before mapping to boost.
    controller.smoothedSpeed = controller.smoothedSpeed
        + (rawSpeed - controller.smoothedSpeed) * SPEED_SMOOTHING

    RampTo(ResolveTargetBoost())
    UpdateOverlay()
end

-- ---------------------------------------------------------------------------
-- Debug overlay (opt-in, on-screen, never chat)
-- ---------------------------------------------------------------------------
-- A small on-screen readout of the live speed/position/boost, for calibrating the
-- speed thresholds and as a general diagnostic. OFF by default. It draws to a
-- top-level window (NOT chat, so it never spams), is created lazily the first time
-- it is shown, and only updates on the existing sample tick -- no extra timer.
local overlayWindow = nil
local overlayLabel  = nil

-- Build the overlay controls once, on first use. Anchored top-left, click-through,
-- with a translucent backdrop so the text stays readable over the world.
local function EnsureOverlay()
    if overlayWindow then
        return
    end

    local tlw = WINDOW_MANAGER:CreateTopLevelWindow("BAV_VelocityFovOverlay")
    tlw:SetDimensions(380, 110)
    tlw:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, 24, 240)
    tlw:SetMouseEnabled(false)
    tlw:SetMovable(false)
    tlw:SetHidden(true)

    local bg = WINDOW_MANAGER:CreateControl("$(parent)BG", tlw, CT_BACKDROP)
    bg:SetAnchorFill(tlw)
    bg:SetCenterColor(0, 0, 0, 0.55)
    bg:SetEdgeColor(0, 0, 0, 0)

    local label = WINDOW_MANAGER:CreateControl("$(parent)Label", tlw, CT_LABEL)
    label:SetFont("ZoFontGameLarge")
    label:SetColor(0.44, 0.80, 0.62, 1)
    label:SetAnchor(TOPLEFT, tlw, TOPLEFT, 12, 10)
    label:SetAnchor(BOTTOMRIGHT, tlw, BOTTOMRIGHT, -12, -10)
    label:SetVerticalAlignment(TEXT_ALIGN_TOP)

    overlayWindow = tlw
    overlayLabel  = label
end

-- Refresh (or hide) the overlay. Called from the sample tick and whenever debug is
-- toggled. Builds the controls lazily so a user who never enables debug pays nothing.
-- Assigns the forward-declared local (above) rather than creating a global.
function UpdateOverlay()
    if not controller.debug then
        if overlayWindow then
            overlayWindow:SetHidden(true)
        end
        return
    end

    EnsureOverlay()
    -- EnsureOverlay creates both controls together, so this guard is belt-and-braces
    -- (and keeps static analysis happy about the control handles being non-nil).
    if not (overlayWindow and overlayLabel) then
        return
    end
    overlayWindow:SetHidden(false)
    overlayLabel:SetText(stringformat(
        "|cB0CBA0BAV Velocity FOV (debug)|r\n" ..
        "speed: %d cm/s  (raw map %d..%d)\n" ..
        "boost: %.2f / %.2f  (max %d, sens %d%%)\n" ..
        "zone %s  x %d  z %d  sampling %s",
        controller.smoothedSpeed, SPEED_MIN_CMS, SPEED_MAX_CMS,
        controller.currentBoost, controller.targetBoost,
        MAX_BOOST_DEGREES, math.floor(controller.sensitivity * 100 + 0.5),
        tostring(controller.lastZoneId or "?"),
        controller.lastX or 0, controller.lastZ or 0,
        tostring(controller.sampling)))
end

-- Whether the speed sampler should be running: while the FEATURE is on (to drive
-- the boost) OR while the DEBUG overlay is on (to populate the readout for
-- calibration even when the boost itself is off).
local function ShouldSample()
    return controller.enabled or controller.debug
end

-- Register the sample timer. Resets the baseline so the first tick references
-- cleanly rather than reading a stale position from a previous run.
local function StartSampling()
    if controller.sampling then
        return
    end
    controller.sampling = true
    ResetSampleBaseline()
    controller.smoothedSpeed = 0
    EVENT_MANAGER:RegisterForUpdate(SAMPLE_NAME, POLL_MS, OnSampleSpeed)
end

local function StopSampling()
    if not controller.sampling then
        return
    end
    controller.sampling = false
    EVENT_MANAGER:UnregisterForUpdate(SAMPLE_NAME)
    ResetSampleBaseline()
    controller.smoothedSpeed = 0
end

-- Start or stop the sampler to match ShouldSample(). The single gate both the
-- feature and the debug overlay go through, so neither can leave the timer running
-- when the other is also off.
local function SyncSampling()
    if ShouldSample() then
        StartSampling()
    else
        StopSampling()
    end
end

-- ---------------------------------------------------------------------------
-- Zone-change baseline reset
-- ---------------------------------------------------------------------------
-- EVENT_PLAYER_ACTIVATED fires after every load screen. The world position is
-- discontinuous across it, so drop the baseline (the next sample re-references) to
-- be doubly safe even within the same nominal zoneId.
local function OnPlayerActivated()
    if controller.sampling then
        ResetSampleBaseline()
    end
end

local function RegisterStateEvents()
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_ACTIVATED, OnPlayerActivated)
end

local function UnregisterStateEvents()
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_ACTIVATED)
end

-- ---------------------------------------------------------------------------
-- Options-window coordination
-- ---------------------------------------------------------------------------
-- While the ESO settings window is open the player may edit the real FOV. Like
-- ContextPresets, we suspend (push boost 0) so we are not adding a boost on top of
-- the value they are editing, then re-evaluate on close.
local OPTIONS_FRAGMENT = OPTIONS_WINDOW_FRAGMENT

local function OnOptionsOpened()
    if not controller.enabled or controller.optionsOpen then
        return
    end
    controller.optionsOpen = true
    RampTo(ResolveTargetBoost())  -- target resolves to 0 while options are open
end

local function OnOptionsClosed()
    if not controller.optionsOpen then
        return
    end
    controller.optionsOpen = false
    if controller.enabled then
        RampTo(ResolveTargetBoost())
    end
end

local function OnOptionsFragmentStateChange(_, newState)
    if newState == SCENE_FRAGMENT_SHOWN then
        OnOptionsOpened()
    elseif newState == SCENE_FRAGMENT_HIDDEN then
        OnOptionsClosed()
    end
end

local function RegisterOptionsEvents()
    if OPTIONS_FRAGMENT and OPTIONS_FRAGMENT.RegisterCallback then
        OPTIONS_FRAGMENT:RegisterCallback("StateChange", OnOptionsFragmentStateChange)
    end
end

local function UnregisterOptionsEvents()
    if OPTIONS_FRAGMENT and OPTIONS_FRAGMENT.UnregisterCallback then
        OPTIONS_FRAGMENT:UnregisterCallback("StateChange", OnOptionsFragmentStateChange)
    end
    controller.optionsOpen = false
end

-- ---------------------------------------------------------------------------
-- Enable / disable
-- ---------------------------------------------------------------------------

local function SetEnabled(enabled)
    enabled = enabled and true or false
    if enabled == controller.enabled then
        return
    end

    if enabled then
        controller.enabled = true
        RegisterStateEvents()
        RegisterOptionsEvents()
        SyncSampling()  -- starts the sampler (also covers the debug-only case)
        -- No boost until the first speed reading; nothing to apply yet.
    else
        controller.enabled = false
        StopRamp()
        -- Hand FOV back: push boost 0 so the arbiter restores the base and drops any
        -- borrowed manual FOV. Directly (not via ramp) so disabling is instant.
        controller.targetBoost = 0
        controller.currentBoost = 0
        PushBoost()
        -- Tear down events/sampler only if debug is not still keeping them alive.
        if not controller.debug then
            UnregisterStateEvents()
            UnregisterOptionsEvents()
            SyncSampling()  -- stops the sampler now that neither feature nor debug wants it
        end
    end
end

-- Toggle the debug overlay. It keeps the speed sampler running even when the boost
-- is off (so the readout is useful for calibration), and registers the zone-change
-- baseline reset so a teleport mid-debug does not show a bogus speed. Tearing down
-- defers to whether the feature is still on.
local function SetDebug(debug)
    debug = debug and true or false
    if debug == controller.debug then
        return
    end
    controller.debug = debug

    if debug then
        RegisterStateEvents()  -- idempotent if the feature already registered them
        SyncSampling()
    else
        if not controller.enabled then
            UnregisterStateEvents()
            SyncSampling()
        end
    end
    UpdateOverlay()
end

-- ---------------------------------------------------------------------------
-- Public API (wired to SavedVariables by Settings.lua)
-- ---------------------------------------------------------------------------

-- Apply a configuration table, typically mirrored from SavedVariables:
--   enabled      boolean
--   sensitivity  number 0..1 (scales how strongly speed widens the FOV)
--   debug        boolean -- show the on-screen speed/boost readout (never chat)
-- Unspecified fields are left unchanged. Safe to call repeatedly.
function VelocityFov.Configure(options)
    options = options or {}

    if options.sensitivity ~= nil then
        local s = tonumber(options.sensitivity) or controller.sensitivity
        if s < 0 then s = 0 elseif s > 1 then s = 1 end
        controller.sensitivity = s
    end

    if options.debug ~= nil then
        SetDebug(options.debug)
    end

    if options.enabled ~= nil then
        SetEnabled(options.enabled)
    elseif controller.enabled then
        -- Live reconfiguration (sensitivity change): re-target from the current
        -- smoothed speed so the new strength applies immediately.
        RampTo(ResolveTargetBoost())
    end

    LogDebug("VelocityFov.Configure: enabled=%s sensitivity=%.2f debug=%s",
        tostring(controller.enabled), controller.sensitivity, tostring(controller.debug))
end

-- Emergency recovery: force the boost to 0 immediately and stop all timers, so the
-- panic restore (/bav reset) hands FOV back cleanly. Does NOT change the user's
-- saved settings -- it recovers the camera, then normal sampling resumes. Returns
-- true if a boost was actually being applied.
function VelocityFov.EmergencyRestore()
    local didSomething = controller.currentBoost ~= 0 or controller.rampActive

    StopRamp()
    controller.targetBoost = 0
    controller.currentBoost = 0
    controller.smoothedSpeed = 0
    ResetSampleBaseline()
    PushBoost()

    return didSomething
end

-- Read-only snapshot of internal state, for SelfCheck invariants and dumps. Returns
-- a fresh flat table so callers cannot mutate runtime state.
--   enabled        feature is on
--   sampling       speed-sample timer is registered
--   currentBoost   boost currently applied (degrees)
--   targetBoost    boost the ramp is heading toward
--   ramping        the ramp updater is registered
--   speed          current smoothed speed (cm/s), surfaced for in-game calibration
--   debug          the on-screen debug overlay is showing
--   optionsOpen    the ESO options window is open (boost suspended)
function VelocityFov.GetDiagnostics()
    return {
        enabled      = controller.enabled,
        sampling     = controller.sampling,
        currentBoost = controller.currentBoost,
        targetBoost  = controller.targetBoost,
        ramping      = controller.rampActive,
        speed        = controller.smoothedSpeed,
        debug        = controller.debug,
        optionsOpen  = controller.optionsOpen,
    }
end