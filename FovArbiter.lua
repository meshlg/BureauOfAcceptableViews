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
local EVENT_MANAGER          = EVENT_MANAGER
local GetGameTimeMilliseconds = GetGameTimeMilliseconds

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

-- ---------------------------------------------------------------------------
-- FOV glide state (self-tearing-down updater)
-- ---------------------------------------------------------------------------
-- A hold may optionally EASE the pinned FOV toward its target instead of
-- snapping. The glide lives HERE, in the sole owner of FOV, rather than in
-- ContextPresets: while a hold is active RequestDynamic is suppressed, so no
-- dynamic zoom tick can fight the animation. The updater is temporary -- it
-- registers on glide start and unregisters itself on the final frame -- so an
-- idle arbiter carries no per-frame cost. Mirrors the discipline ContextPresets
-- uses for its spatial glide.
local GLIDE_UPDATE_NAME = "BAV_FovArbiter_Glide"

-- All nil/false while no glide runs. active gates the temporary updater; the
-- rest describe the in-flight ease and the exact landing value.
local glide = {
    active  = false,
    startMs = nil,
    from    = nil,
    to      = nil,
    durMs   = nil,
}

-- Forward declaration: StopGlide is used by BeginHold/EndHold/ForceRelease,
-- which are defined before the glide machinery further down.
local StopGlide
local StartGlide

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

-- Returns true while a FOV glide is easing toward its target. Exposed so the
-- self-check can flag an orphaned updater (gliding while nothing should own
-- FOV) and so diagnostics can report it.
function FovArbiter.IsGliding()
    return glide.active
end

-- Begin a hold under the given source name and optionally pin an FOV value.
-- While held, RequestDynamic is suppressed so the pinned FOV stays put. A hold
-- is exclusive: starting one while another is active is rejected (returns false)
-- rather than silently stealing ownership, which keeps begin/end balanced.
--
-- durationMs controls HOW the pinned FOV is reached:
--   * nil / <= 0  -> instant pin (the original, default semantics).
--   * > 0         -> ease from the live FOV to `fov` over that many ms via a
--                    self-tearing updater. Falls back to an instant pin if the
--                    live FOV cannot be read, so a glide is never half-applied.
-- Re-calling BeginHold for the SAME source retargets: any in-flight glide is
-- cancelled and a fresh one starts from the LIVE FOV, never a stale start.
function FovArbiter.BeginHold(source, fov, durationMs)
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
        durationMs = tonumber(durationMs)
        if durationMs ~= nil and durationMs > 0 and StartGlide(fov, durationMs) then
            LogDebug("FovArbiter.BeginHold: gliding to FOV=%s over %dms",
                tostring(fov), durationMs)
        else
            -- Instant pin: cancel any in-flight glide so its updater cannot write
            -- a stale frame after this, then set the exact value.
            StopGlide()
            if not CameraSettings.Set(FOV_KEY, fov) then
                LogWarn("FovArbiter.BeginHold: failed to pin FOV=%s", tostring(fov))
            end
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

    -- A glide pins FOV only while its hold owns it; releasing the hold must also
    -- stop the updater, or it would keep writing FOV after dynamic resumes.
    StopGlide()

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
-- Velocity-reactive FOV boost routing
-- ---------------------------------------------------------------------------

-- Entry point for VelocityFov. The boost (degrees) is added on top of whatever
-- base FOV DynamicFov computes (zoom interpolation, or the player's manual FOV when
-- zoom-based FOV is off). Routing it through the arbiter means it obeys the same
-- single-owner precedence as the dynamic path: while a hold is active the boost is
-- stored but NOT applied, so a preset's pinned FOV is never stomped; when the hold
-- ends, EndHold -> Reassert re-renders base + boost. Returns true when a write
-- actually happened.
function FovArbiter.SetVelocityBoost(boost)
    if not addon.DynamicFov or not addon.DynamicFov.SetVelocityBoost then
        return false
    end

    local changed = addon.DynamicFov.SetVelocityBoost(boost)
    local boostCleared = changed and (tonumber(boost) or 0) == 0

    if holdSource ~= nil then
        -- A hold owns FOV; the new boost is remembered and applied when it ends.
        -- If the boost cleared, drop any borrowed manual base now: the hold's owner
        -- (a preset) restores FOV from its own snapshot when it releases, so the
        -- borrow is moot and must not linger (it would trip the self-check).
        if boostCleared and addon.DynamicFov.ReleaseManualBase then
            addon.DynamicFov.ReleaseManualBase()
        end
        LogDebug("FovArbiter.SetVelocityBoost: stored under hold '%s'", holdSource)
        return false
    end

    -- No hold: render the recomposed FOV now. lastDynamicZoom may be nil in
    -- velocity-only mode (zoom-based FOV off) -- Apply ignores zoom in that case.
    local wrote = addon.DynamicFov.Apply(lastDynamicZoom) and true or false

    -- The boost just cleared. In velocity-only mode (zoom-based FOV off) the module
    -- is no longer engaged, so the Apply above wrote nothing -- the borrowed manual
    -- base must be written back explicitly here so FOV returns to the player's own
    -- value instead of staying at the last boosted one. RestoreManualBase writes +
    -- clears; it is a no-op when nothing is borrowed (e.g. zoom-based FOV is on,
    -- where Apply already rendered the interpolated base), so this is safe either way.
    if boostCleared and addon.DynamicFov.RestoreManualBase then
        if addon.DynamicFov.RestoreManualBase() then
            wrote = true
        end
    end

    return wrote
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
    -- Kill any in-flight glide too, so its updater cannot survive the hold it
    -- belonged to and keep writing FOV after an emergency recovery.
    StopGlide()
    return true
end

-- ---------------------------------------------------------------------------
-- FOV glide machinery
-- ---------------------------------------------------------------------------
-- Defined after the public hold API so it can stay file-local, and assigned to
-- the forward-declared StopGlide/StartGlide locals that BeginHold/EndHold/
-- ForceRelease already reference.

-- Tear down the per-frame updater and clear glide state. Idempotent, so it also
-- serves as the cancel path when a hold ends or retargets mid-glide. Assigned to
-- the forward-declared local rather than declared fresh.
function StopGlide()
    if glide.active then
        EVENT_MANAGER:UnregisterForUpdate(GLIDE_UPDATE_NAME)
    end
    glide.active  = false
    glide.startMs = nil
    glide.from    = nil
    glide.to      = nil
    glide.durMs   = nil
end

-- Per-frame step of the glide. Eases linearly from glide.from to glide.to over
-- glide.durMs, writing the intermediate FOV each frame. On the final frame it
-- pins the exact target and unregisters itself, so the updater only lives for
-- the duration of the transition. A failed write mid-glide is non-fatal: the
-- next frame retries and the final frame writes the exact target regardless.
local function OnGlideUpdate()
    if not glide.active or glide.startMs == nil then
        StopGlide()
        return
    end

    -- A glide is only meaningful while its hold owns FOV. If the hold vanished
    -- (it should have called StopGlide, but be defensive), abandon the glide
    -- rather than fighting whatever now drives FOV.
    if holdSource == nil then
        StopGlide()
        return
    end

    local elapsed = GetGameTimeMilliseconds() - glide.startMs
    local t = elapsed / glide.durMs
    if t < 0 then t = 0 end

    if t >= 1 then
        -- Final frame: land exactly on the target and stop.
        CameraSettings.Set(FOV_KEY, glide.to)
        StopGlide()
        return
    end

    local current = glide.from + (glide.to - glide.from) * t
    CameraSettings.Set(FOV_KEY, current)
end

-- Begin (or retarget) a glide toward targetFov over durationMs. The start point
-- is the LIVE FOV, so retargeting an in-flight glide eases from wherever it
-- currently is rather than snapping back to an old start. Returns false (so the
-- caller can fall back to an instant pin) when the live FOV cannot be read or
-- the start already equals the target -- in either case a glide would be
-- pointless or impossible. Assigned to the forward-declared local.
function StartGlide(targetFov, durationMs)
    targetFov = tonumber(targetFov)
    if targetFov == nil then
        return false
    end

    local fromFov, ok = CameraSettings.Get(FOV_KEY)
    if not ok or fromFov == nil then
        -- Cannot read the starting FOV; let the caller pin instantly instead.
        return false
    end

    -- Cancel any in-flight glide before starting a fresh one, so only one
    -- updater is ever registered under GLIDE_UPDATE_NAME.
    StopGlide()

    if fromFov == targetFov then
        -- Already there; nothing to ease. Treat as "no glide needed" so the
        -- caller pins exactly (cheap and avoids a one-frame updater).
        return false
    end

    glide.active  = true
    glide.startMs = GetGameTimeMilliseconds()
    glide.from    = fromFov
    glide.to      = targetFov
    glide.durMs   = durationMs

    EVENT_MANAGER:RegisterForUpdate(GLIDE_UPDATE_NAME, 0, OnGlideUpdate)
    return true
end
