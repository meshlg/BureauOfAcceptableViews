-- ===========================================================================
-- DynamicFov.lua
-- ---------------------------------------------------------------------------
-- Optional zoom-dependent field of view.
--
-- When enabled, the third-person FOV is driven by the current camera zoom
-- distance: zoomed all the way in uses one FOV, zoomed all the way out uses
-- another, and everything in between is linearly interpolated. This keeps the
-- framing feeling consistent as the player zooms, without them having to touch
-- the FOV slider.
--
-- Design notes:
--   * All engine I/O goes through the shared CameraSettings layer; this module
--     never touches GetSetting/SetSetting directly.
--   * The feature is OFF by default and does nothing until Configure() is
--     called with enabled = true (Settings.lua owns the SavedVars and wires
--     that up). When disabled, Apply() is a no-op, so the player's manual FOV
--     is left exactly as the game left it.
--   * Nothing here is on a per-frame path: Apply() is called only when the
--     zoom distance actually changes, so a linear interpolation is plenty.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.DynamicFov = addon.DynamicFov or {}
local DynamicFov = addon.DynamicFov

-- Hot-path globals bound to locals once at load (mirrors the core file style).
local tonumber = tonumber
local mathabs  = math.abs

-- Engine handles for the optional smoothing animation. The animation is the one
-- place this module steps outside the addon's PULL/event-only rule, and it does
-- so the same way the core's save timer already does: a *temporary*
-- RegisterForUpdate that unregisters itself the moment the transition finishes,
-- so there is no standing per-frame cost when FOV is not actively moving.
local EVENT_MANAGER             = EVENT_MANAGER
local GetGameTimeMilliseconds   = GetGameTimeMilliseconds
local ANIM_UPDATE_NAME          = "BAV_DynamicFovSmoothing"

-- Total time (ms) for a smoothed FOV transition. Short enough to feel immediate,
-- long enough to read as a glide rather than a snap. Each zoom step restarts the
-- animation from the live FOV, so overlapping steps chain smoothly.
local ANIM_DURATION_MS          = 150

-- Logging helpers are generated in the core file and exported on private.
-- Resolve them lazily so load order between files cannot break us.
local function LogWarn(...)
    if private.LogWarn then private.LogWarn(...) end
end

local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

-- ---------------------------------------------------------------------------
-- Configuration / state
-- ---------------------------------------------------------------------------
-- Runtime configuration, mirrored from SavedVariables by Configure(). Defaults
-- are intentionally inert: enabled = false means the module changes nothing.
-- nearFov applies at the closest (zoomMin) distance, farFov at the farthest
-- (zoomMax) distance. The zoom bounds are resolved from the CameraSettings
-- "distance" range so we never duplicate the engine's clamp limits here.
local config = {
    enabled = false,
    nearFov = nil,   -- resolved to the FOV range min on first Configure()
    farFov  = nil,   -- resolved to the FOV range max on first Configure()
    smooth  = false, -- when true, FOV glides to its target instead of snapping
    -- Velocity-reactive FOV boost (degrees) added on top of the base FOV. Owned by
    -- the VelocityFov module and pushed in via SetVelocityBoost (through FovArbiter).
    -- 0 means no boost. This module composes base + boost so a single writer
    -- (DynamicFov, gated by FovArbiter) produces the final FOV either way.
    velocityBoost = 0,
}

-- When zoom-based FOV is OFF but a velocity boost is active, there is no zoom
-- interpolation to form a base FOV from -- the base is the player's own manual
-- FOV. We capture it lazily the first time a boost becomes non-zero, so the boost
-- adds on top of whatever the player set, and restore it when the boost clears.
-- nil whenever we are not borrowing the manual FOV as a base.
local manualBaseFov = nil

-- The last FOV we wrote, so we can skip redundant CameraSettings.Set calls when
-- the interpolated value has not meaningfully changed since the last apply.
local lastAppliedFov = nil

-- Smoothing animation state. All nil/false while no transition is running, so a
-- disabled or idle module carries no animation bookkeeping. animActive gates the
-- temporary RegisterForUpdate; the rest describe the in-flight glide.
local animActive    = false
local animFromFov   = nil   -- FOV at the moment the current glide started
local animToFov     = nil   -- FOV the current glide is heading toward
local animStartMs   = nil   -- GetGameTimeMilliseconds() when the glide started

-- Two writes closer than this are treated as identical (matches the FOV
-- setting's two-decimal precision with a little slack).
local FOV_EPSILON = 0.05

-- ---------------------------------------------------------------------------
-- Range resolution
-- ---------------------------------------------------------------------------
-- We drive the third-person FOV, so both the FOV clamp range and the zoom
-- distance range come straight from CameraSettings (the single source of truth
-- for engine limits). Resolved lazily and cached, because the CAMERA_SETTING_*
-- constants are only meaningful once the client has loaded.
local CameraSettings = addon.CameraSettings

local FOV_KEY  = "thirdPersonFov"
local ZOOM_KEY = "distance"

-- Returns (min, max) FOV for the third-person camera, or nil when the property
-- is unavailable on this client build.
local function GetFovRange()
    return CameraSettings.GetRange(FOV_KEY)
end

-- Returns (min, max) camera zoom distance, or nil when unavailable.
local function GetZoomRange()
    return CameraSettings.GetRange(ZOOM_KEY)
end

-- ---------------------------------------------------------------------------
-- Interpolation
-- ---------------------------------------------------------------------------

-- Clamp helper local to this module (kept tiny rather than reaching into the
-- core file, so DynamicFov has no hard dependency on private.ClampNumber).
local function Clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

-- Map a zoom distance to the FOV it should produce.
-- nearFov applies at zoomMin (closest), farFov at zoomMax (farthest); points in
-- between are linearly interpolated. The zoom is clamped to its range first, so
-- out-of-range inputs saturate at the endpoints instead of extrapolating.
-- Returns nil when either range is unavailable or the zoom span is degenerate.
local function InterpolateFov(zoom, zoomMin, zoomMax, nearFov, farFov)
    local span = zoomMax - zoomMin
    if span <= 0 then
        return nil
    end

    zoom = Clamp(zoom, zoomMin, zoomMax)
    local t = (zoom - zoomMin) / span
    return nearFov + (farFov - nearFov) * t
end

-- ---------------------------------------------------------------------------
-- Smoothing animation
-- ---------------------------------------------------------------------------
-- The glide is driven by a temporary RegisterForUpdate that tears itself down
-- when the transition completes. This mirrors the core save timer's lifecycle:
-- nothing runs per-frame unless a transition is actually in progress.

-- Tear down the per-frame updater and clear animation state. Safe to call when
-- no animation is running (idempotent), so it doubles as the "cancel" path used
-- when the feature is turned off or reconfigured.
local function StopAnimation()
    if animActive then
        EVENT_MANAGER:UnregisterForUpdate(ANIM_UPDATE_NAME)
    end
    animActive  = false
    animFromFov = nil
    animToFov   = nil
    animStartMs = nil
end

-- Write an FOV value through CameraSettings and update the dedup cache. Returns
-- true only on a verified write. Centralized so both the instant and animated
-- paths share identical write/verify/caching behavior.
local function WriteFov(fov)
    if not CameraSettings.Set(FOV_KEY, fov) then
        return false
    end
    lastAppliedFov = fov
    return true
end

-- Per-frame step of the glide. Interpolates from animFromFov to animToFov over
-- ANIM_DURATION_MS, writing the intermediate FOV each frame. On the final frame
-- it pins the exact target and unregisters itself, so the updater only lives for
-- the duration of the transition.
local function OnAnimationUpdate()
    if not animActive or animStartMs == nil then
        StopAnimation()
        return
    end

    local elapsed = GetGameTimeMilliseconds() - animStartMs
    local t = elapsed / ANIM_DURATION_MS
    if t < 0 then t = 0 end

    if t >= 1 then
        -- Final frame: land exactly on the target and stop.
        WriteFov(animToFov)
        StopAnimation()
        return
    end

    local current = animFromFov + (animToFov - animFromFov) * t
    WriteFov(current)
end

-- Begin (or retarget) a glide toward targetFov. The start point is the live FOV
-- so an in-flight glide retargets smoothly from wherever it currently is rather
-- than jumping back to a stale value. Registers the temporary updater only when
-- one is not already running. Returns true if a glide is now in progress.
local function StartAnimation(targetFov)
    local startFov = lastAppliedFov
    if startFov == nil then
        local current, ok = CameraSettings.Get(FOV_KEY)
        startFov = ok and current or targetFov
    end

    -- Already there: nothing to animate.
    if mathabs(targetFov - startFov) <= FOV_EPSILON then
        StopAnimation()
        return WriteFov(targetFov)
    end

    animFromFov = startFov
    animToFov   = targetFov
    animStartMs = GetGameTimeMilliseconds()

    if not animActive then
        animActive = true
        EVENT_MANAGER:RegisterForUpdate(ANIM_UPDATE_NAME, 0, OnAnimationUpdate)
    end
    return true
end

-- Returns true if zoom-based dynamic FOV is switched on (and supported). This is
-- the user-facing "Dynamic FOV" semantics used by the settings getters/UI; it does
-- NOT account for a velocity boost (see IsEngaged for the write-path guard).
function DynamicFov.IsEnabled()
    return config.enabled and CameraSettings.IsSupported(FOV_KEY)
end

-- Returns true if this module should be driving FOV at all: either zoom-based FOV
-- is on, OR a velocity boost is active. Used as the Apply() guard so velocity FOV
-- works even when the zoom-based feature is off. When neither is active, Apply is a
-- no-op and the player's manual FOV is left exactly as the game set it.
function DynamicFov.IsEngaged()
    return (config.enabled or config.velocityBoost ~= 0) and CameraSettings.IsSupported(FOV_KEY)
end

-- Compute the BASE FOV (before any velocity boost) for a zoom distance.
--   * Zoom-based FOV on  -> interpolate between near/far across the zoom range.
--   * Zoom-based FOV off -> the borrowed manual base FOV, if we captured one.
-- Returns nil when no base can be formed (ranges unavailable, or off with nothing
-- captured), so callers can skip the write.
local function ComputeBaseFov(zoom)
    if config.enabled then
        local nearFov, farFov = config.nearFov, config.farFov
        if nearFov == nil or farFov == nil then
            return nil
        end

        local zoomMin, zoomMax = GetZoomRange()
        if zoomMin == nil or zoomMax == nil then
            return nil
        end

        return InterpolateFov(zoom, zoomMin, zoomMax, nearFov, farFov)
    end

    -- Zoom-based FOV is off: the base is the player's manual FOV we borrowed when
    -- the boost first engaged. nil when we have not borrowed one.
    return manualBaseFov
end

-- Apply runtime configuration, typically mirrored from SavedVariables by
-- Settings.lua. Unspecified near/far FOV values default to (and are clamped to)
-- the engine FOV range, so a minimal Configure{ enabled = true } is valid.
-- Calling this resets the "last applied" cache so the next Apply() always
-- writes, and -- when the feature is being turned off -- does not touch FOV,
-- leaving whatever value the player or another module last set.
function DynamicFov.Configure(options)
    options = options or {}
    config.enabled = options.enabled and true or false
    config.smooth  = options.smooth and true or false

    local fovMin, fovMax = GetFovRange()
    if fovMin and fovMax then
        local near = tonumber(options.nearFov) or config.nearFov or fovMin
        local far  = tonumber(options.farFov)  or config.farFov  or fovMax
        config.nearFov = Clamp(near, fovMin, fovMax)
        config.farFov  = Clamp(far,  fovMin, fovMax)
    else
        -- FOV unavailable on this client; keep whatever was passed so the values
        -- survive a later client where the property does resolve.
        config.nearFov = tonumber(options.nearFov) or config.nearFov
        config.farFov  = tonumber(options.farFov)  or config.farFov
    end

    -- When zoom-based FOV is ON the base comes from interpolation, so any borrowed
    -- manual base (used only in velocity-only mode) is irrelevant -- drop it. The
    -- borrow's whole lifecycle otherwise lives in SetVelocityBoost / ReleaseManualBase.
    if config.enabled then
        manualBaseFov = nil
    end

    lastAppliedFov = nil
    -- Any reconfiguration (including being turned off) cancels an in-flight
    -- glide so we never animate toward a now-stale target.
    StopAnimation()
    LogDebug("DynamicFov.Configure: enabled=%s, smooth=%s, nearFov=%s, farFov=%s",
        tostring(config.enabled), tostring(config.smooth),
        tostring(config.nearFov), tostring(config.farFov))
end

-- Set the velocity-reactive FOV boost (degrees) added on top of the base FOV. This
-- is the entry point VelocityFov uses, always routed through FovArbiter so the
-- boost is suppressed while a preset holds FOV. This function ONLY updates state;
-- FovArbiter re-renders via Apply() afterward (when no hold is active) and calls
-- ReleaseManualBase() once the boost has cleared.
--
-- Manual-base borrow (velocity FOV with zoom-based FOV off): on the first non-zero
-- boost we capture the player's current FOV as the base, so the boost adds on top of
-- their own FOV. The borrow is restored to the camera by FovArbiter's follow-up
-- Apply (base + 0) and then dropped via ReleaseManualBase, so it never lingers.
-- Returns true if the boost value actually changed.
function DynamicFov.SetVelocityBoost(boost)
    boost = tonumber(boost) or 0
    if boost == config.velocityBoost then
        return false
    end

    -- Borrow the live FOV as a base the first time a boost engages while zoom-based
    -- FOV is off (nothing else forms a base in that mode).
    if config.velocityBoost == 0 and boost ~= 0
        and not config.enabled and manualBaseFov == nil
        and CameraSettings.IsSupported(FOV_KEY) then
        local current, ok = CameraSettings.Get(FOV_KEY)
        if ok and current ~= nil then
            manualBaseFov = current
        end
    end

    config.velocityBoost = boost
    lastAppliedFov = nil  -- force the next Apply to write the recomposed FOV
    LogDebug("DynamicFov.SetVelocityBoost: boost=%.2f (zoomFov=%s)",
        boost, tostring(config.enabled))
    return true
end

-- Drop a borrowed manual base FOV WITHOUT writing it back. Called by FovArbiter
-- when the boost clears while a preset hold owns FOV: the preset restores FOV from
-- its own snapshot, so writing here would fight it -- we only forget the borrow so
-- it does not linger and trip the self-check. No-op when nothing is borrowed.
function DynamicFov.ReleaseManualBase()
    manualBaseFov = nil
end

-- Restore a borrowed manual base FOV to the camera, then drop it. Called by
-- FovArbiter when the boost clears with no hold active AND zoom-based FOV is off:
-- in that mode IsEngaged() has just become false, so Apply() no longer writes, and
-- the borrowed base must be written back here so the camera returns to the player's
-- own FOV instead of staying at the last boosted value. Returns true if it wrote.
-- No-op (and no write) when nothing is borrowed -- e.g. zoom-based FOV is on, where
-- Apply already rendered the interpolated base.
function DynamicFov.RestoreManualBase()
    if manualBaseFov == nil then
        return false
    end
    local wrote = WriteFov(manualBaseFov)
    manualBaseFov = nil
    return wrote
end

-- Read-only snapshot of FOV-driver state, for SelfCheck invariants and dumps.
-- Returns a fresh flat table so callers cannot mutate runtime state.
--   zoomEnabled        zoom-based dynamic FOV is on
--   engaged            this module is driving FOV (zoom on OR a boost is active)
--   velocityBoost      current boost in degrees (0 = none)
--   manualBaseCaptured a manual base FOV is borrowed (velocity-only mode)
--   animating          the smoothing glide updater is currently registered
function DynamicFov.GetDiagnostics()
    return {
        zoomEnabled        = config.enabled,
        engaged            = DynamicFov.IsEngaged(),
        velocityBoost      = config.velocityBoost,
        manualBaseCaptured = manualBaseFov ~= nil,
        animating          = animActive,
    }
end

-- Recompute and apply the FOV for the given zoom distance. Called whenever the
-- zoom actually changes (never per-frame), and whenever the velocity boost changes
-- (routed through FovArbiter). The final FOV is base + velocityBoost, where the
-- base comes from zoom interpolation (zoom-based FOV on) or the borrowed manual FOV
-- (zoom-based FOV off, boost only). No-op when neither is engaged, unavailable, not
-- yet configured, or when the new FOV is within FOV_EPSILON of the last value we
-- wrote. Returns true only on a verified write.
function DynamicFov.Apply(zoom)
    if not DynamicFov.IsEngaged() then
        return false
    end

    zoom = tonumber(zoom)

    -- Zoom-based FOV needs a valid zoom to interpolate; the velocity-only path
    -- (zoom-based off) ignores zoom and bases off the captured manual FOV.
    if config.enabled and zoom == nil then
        return false
    end

    local baseFov = ComputeBaseFov(zoom)
    if baseFov == nil then
        return false
    end

    local targetFov = baseFov + config.velocityBoost

    if lastAppliedFov ~= nil and mathabs(targetFov - lastAppliedFov) <= FOV_EPSILON then
        return false
    end

    -- Smoothing on: glide toward the target over a few frames via the temporary
    -- updater. Off: write immediately, preserving the original snap behavior and
    -- the addon's event-only execution model when the option is not in use.
    if config.smooth then
        return StartAnimation(targetFov)
    end

    if not WriteFov(targetFov) then
        LogWarn("DynamicFov.Apply: failed to set FOV=%.2f (base=%.2f, boost=%.2f)",
            targetFov, baseFov, config.velocityBoost)
        return false
    end

    LogDebug("DynamicFov.Apply: base=%.2f, boost=%.2f -> FOV=%.2f",
        baseFov, config.velocityBoost, targetFov)
    return true
end
