-- ===========================================================================
-- FovArbiter.lua
-- ---------------------------------------------------------------------------
-- Single owner of third-person FOV precedence.
--
-- Two features want to drive thirdPersonFov:
--   * DynamicFov  -- continuous, zoom-dependent FOV.
--   * ContextPresets -- discrete bundles that may pin a specific FOV.
-- Left uncoordinated they fight: a preset sets an FOV, then the next zoom tick
-- from DynamicFov overwrites it (or vice versa). This module makes the
-- precedence explicit instead of letting load order / call timing decide.
--
-- Model: a single optional "hold". While a hold is active, that source owns FOV
-- and lower-priority writers are suppressed. Releasing the hold hands control
-- back and reasserts the next-lower source at the current zoom, so FOV never
-- ends up stale after a preset is cleared.
--
-- Priority (high wins):
--   HOLD_PRESET  -- an explicit preset/cinematic FOV pin.
--   (none)       -- DynamicFov drives freely.
--
-- Routing:
--   * DynamicFov calls RequestDynamic(zoom); the arbiter applies it only when no
--     higher hold is active.
--   * ContextPresets calls BeginHold()/EndHold() around a preset that pins FOV.
--
-- Nothing here is enabled by default: with DynamicFov off and no preset holds,
-- every entry point is a no-op and FOV is never touched.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.FovArbiter = addon.FovArbiter or {}
local FovArbiter = addon.FovArbiter

local CameraSettings = addon.CameraSettings

-- Hot-path / library globals bound to locals once at load.
local tonumber = tonumber
local type     = type

-- Logging resolved lazily so file load order cannot break us.
local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

local function LogWarn(...)
    if private.LogWarn then private.LogWarn(...) end
end

-- ---------------------------------------------------------------------------
-- Hold state
-- ---------------------------------------------------------------------------
-- At most one hold is active at a time. We track which source owns it so a
-- mismatched EndHold (e.g. a stale caller) cannot release someone else's hold.
local FOV_KEY = "thirdPersonFov"

-- Active hold source name, or nil when DynamicFov is free to drive.
local holdSource = nil

-- The last zoom DynamicFov told us about, remembered so that releasing a hold
-- can reassert dynamic FOV at the correct distance without waiting for the next
-- zoom change. nil until DynamicFov reports a zoom at least once.
local lastDynamicZoom = nil

-- Forward declaration: EndHold (defined below) calls Reassert, which is defined
-- further down. Declaring the local up front keeps it in scope for both.
local Reassert

-- ---------------------------------------------------------------------------
-- Holds (preset precedence)
-- ---------------------------------------------------------------------------

-- Returns true while any hold is active.
function FovArbiter.IsHeld()
    return holdSource ~= nil
end

-- Begin a hold under the given source name and optionally pin an FOV value.
-- While held, RequestDynamic is suppressed so the pinned FOV stays put. A hold
-- is exclusive: starting one while another is active is rejected (returns false)
-- rather than silently stealing ownership, which keeps begin/end balanced.
function FovArbiter.BeginHold(source, fov)
    if type(source) ~= "string" or source == "" then
        LogWarn("FovArbiter.BeginHold: a non-empty source name is required")
        return false
    end

    if holdSource ~= nil and holdSource ~= source then
        LogWarn("FovArbiter.BeginHold: '%s' rejected, '%s' already holds FOV",
            source, holdSource)
        return false
    end

    holdSource = source

    -- Pin an explicit FOV if one was supplied; otherwise the hold simply freezes
    -- whatever FOV is currently set by suppressing dynamic writes.
    if fov ~= nil and CameraSettings.IsSupported(FOV_KEY) then
        if not CameraSettings.Set(FOV_KEY, fov) then
            LogWarn("FovArbiter.BeginHold: failed to pin FOV=%s", tostring(fov))
        end
    end

    LogDebug("FovArbiter.BeginHold: source='%s', fov=%s", source, tostring(fov))
    return true
end

-- Release a hold. Only the source that started the hold may end it; a mismatched
-- or absent source is ignored (returns false). On a successful release, dynamic
-- FOV is reasserted at the last known zoom so control hands back cleanly.
function FovArbiter.EndHold(source)
    if holdSource == nil then
        return false
    end

    if holdSource ~= source then
        LogWarn("FovArbiter.EndHold: '%s' cannot release hold owned by '%s'",
            tostring(source), holdSource)
        return false
    end

    holdSource = nil
    LogDebug("FovArbiter.EndHold: source='%s' released", tostring(source))

    -- Hand control back to DynamicFov at the current distance, if we know it.
    Reassert()
    return true
end

-- ---------------------------------------------------------------------------
-- Dynamic FOV routing
-- ---------------------------------------------------------------------------

-- Entry point for DynamicFov. Records the zoom (so a later hold-release can
-- reassert at the right distance) and applies dynamic FOV only when no hold is
-- active. Returns true when a dynamic write actually happened. When a hold is
-- active the zoom is still remembered but no write occurs, so the held FOV
-- stays pinned and dynamic resumes seamlessly once the hold ends.
function FovArbiter.RequestDynamic(zoom)
    zoom = tonumber(zoom)
    if zoom ~= nil then
        lastDynamicZoom = zoom
    end

    if holdSource ~= nil then
        LogDebug("FovArbiter.RequestDynamic: suppressed by hold '%s'", holdSource)
        return false
    end

    if not addon.DynamicFov then
        return false
    end

    return addon.DynamicFov.Apply(lastDynamicZoom) and true or false
end

-- Reassert the active FOV owner at the last known zoom. With no hold active this
-- re-runs dynamic FOV (used after a hold is released). Defined here and assigned
-- to the forward-declared local so EndHold can reach it.
function Reassert()
    if holdSource ~= nil then
        -- A hold owns FOV; nothing to reassert.
        return false
    end

    if lastDynamicZoom == nil then
        -- DynamicFov never reported a zoom, so there is nothing to restore. Fall
        -- back to the live camera zoom if the core exports it.
        if private.GetCameraZoom then
            local zoom, ok = private.GetCameraZoom()
            if ok then
                lastDynamicZoom = zoom
            end
        end
    end

    if lastDynamicZoom == nil or not addon.DynamicFov then
        return false
    end

    LogDebug("FovArbiter.Reassert: dynamic FOV at zoom=%.2f", lastDynamicZoom)
    return addon.DynamicFov.Apply(lastDynamicZoom) and true or false
end

-- ---------------------------------------------------------------------------
-- Emergency recovery
-- ---------------------------------------------------------------------------

-- Unconditionally drop any active hold, ignoring ownership. Unlike EndHold this
-- never checks who owns the hold -- it exists for the emergency restore path,
-- where the goal is to recover from a stuck or orphaned hold (e.g. a preset that
-- failed to release) no matter which source took it. Returns true if a hold was
-- actually cleared. Does NOT reassert dynamic FOV: the emergency caller is about
-- to overwrite the camera wholesale, so reasserting here would be wasted work.
function FovArbiter.ForceRelease()
    if holdSource == nil then
        return false
    end

    LogWarn("FovArbiter.ForceRelease: forcibly clearing hold owned by '%s'", holdSource)
    holdSource = nil
    return true
end
