-- ===========================================================================
-- ZoomReconciler.lua
-- ---------------------------------------------------------------------------
-- Single owner of "where should the camera converge after an FPV toggle we
-- handle ourselves".
--
-- The addon pre-hooks ToggleGameCameraFirstPerson. In states where the engine
-- would refuse a proper third-person/FPV transition (mounted, werewolf,
-- swimming) -- or when leaving FPV -- BAV takes ownership and drives the camera
-- distance itself. The hard part is that other addons (notably PvpAlerts /
-- Miat's PvP) call ToggleGameCameraFirstPerson() TWICE in one rendered frame to
-- probe the camera, expecting the pair to net to zero visible change.
--
-- The old approach tried to RECOGNISE such a pair by frame timestamp and undo
-- our zoom synchronously on the second call. That heuristic was fragile: it
-- broke differently in Cyrodiil (oscillation), as a werewolf (stuck FPV after a
-- port), and on the world map (forced FPV) -- one bug per state, because the
-- "two calls share a frame" assumption does not hold everywhere.
--
-- Model here: INTENT + COALESCING DEFERRED RECONCILE. We never inspect frame
-- timing. An owned toggle only FLIPS a persistent `desiredZoom` intent relative
-- to its OWN value (FPV <-> third person) and schedules a single next-frame
-- reconcile that writes `desiredZoom` exactly once. A probe pair is two flips,
-- so `desiredZoom` returns to where it started and the one reconcile writes the
-- original value -- net zero, regardless of whether the two probes shared a
-- frame. If the engine rejects the write (a state that owns its own distance),
-- we retry a bounded number of times rather than leaving the camera half-moved.
--
-- Scope is deliberately NARROW: this only engages where BAV already blocks the
-- engine (limited state, or leaving FPV). The normal third-person->FPV path is
-- left as a passthrough so the engine runs its native transition and other
-- addons can still measure the ordinary case -- HandleToggle returns false there
-- and the hook lets the original function run.
--
-- Nothing here touches SavedVariables directly; it routes verified writes
-- through the main file's SetCameraZoom (which owns the write-failure metric)
-- and persistence through QueueSave.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.ZoomReconciler = addon.ZoomReconciler or {}
local ZoomReconciler = addon.ZoomReconciler

-- Library globals bound to locals once at load.
local EVENT_MANAGER = EVENT_MANAGER

-- ZOOM_FPV is the shared first-person sentinel (camera distance 0.0). Read it
-- from the main file's constant contract so there is a single source of truth.
local ZOOM_FPV = (private.constants and private.constants.ZOOM_FPV) or 0.0

-- Logging resolved lazily so file load order cannot break us (same discipline as
-- FovArbiter / ContextPresets). LogDebug is not exposed via private, so guard it.
local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

local function LogWarn(...)
    if private.LogWarn then private.LogWarn(...) end
end

-- ---------------------------------------------------------------------------
-- Reconcile state
-- ---------------------------------------------------------------------------
-- desiredZoom -- persistent intent: the distance an owned toggle wants the
--                camera to settle at. nil until the first owned toggle seeds it
--                from the live camera, so a stale intent can never survive the
--                EVENT_PLAYER_ACTIVATED restore (the main file clears it there).
-- pending     -- gates the one-shot updater (mirror of ContextPresets coalesce).
-- retries     -- bounded reschedule counter for a rejected write.
local desiredZoom = nil
local pending     = false
local retries     = 0

-- Unique to this module; must not collide with the main file's save timer or the
-- other modules' update timers.
local RECONCILE_UPDATE_NAME = "BAV_ZoomReconcile"
-- Aligns with SelfCheck's ZOOM_WRITE_FAILURE_WARN (3): if the engine rejects the
-- write this many times in a row we stop retrying, and the self-check surfaces
-- the matching consecutiveZoomWriteFailures run.
local RECONCILE_MAX_RETRIES = 3

local Schedule  -- forward declaration (OnReconcileUpdate reschedules through it)

-- Resolve the third-person distance a "leave FPV" intent should target. Mirrors
-- the expression the old synchronous handler used: prefer the remembered
-- third-person zoom, else the configured limited-state fallback.
local function ResolveThirdPersonTarget()
    local lastZoom = private.GetLastZoom()
    if private.IsValidZoom(lastZoom) and lastZoom > ZOOM_FPV then
        return lastZoom
    end
    return private.GetConfiguredMinMountedZoom()
end

-- Tear down the reconcile timer AND clear the intent. Idempotent. This is the
-- external cancel used on /bav reset and across load screens: a fresh slate
-- where the next owned toggle re-seeds desiredZoom from the live camera.
function ZoomReconciler.Cancel()
    if pending then
        EVENT_MANAGER:UnregisterForUpdate(RECONCILE_UPDATE_NAME)
        pending = false
    end
    desiredZoom = nil
    retries = 0
end

-- One-shot updater: the single point that actually writes the camera.
local function OnReconcileUpdate()
    -- Self-tear the timer FIRST, but DO NOT clear desiredZoom here -- unlike the
    -- external Cancel(), this teardown must preserve the intent we are about to
    -- apply (and may need to keep for a retry). Hence the inline unregister
    -- rather than calling Cancel().
    if pending then
        EVENT_MANAGER:UnregisterForUpdate(RECONCILE_UPDATE_NAME)
        pending = false
    end

    if desiredZoom == nil then
        return
    end

    -- The one verified write. SetCameraZoom owns the write-failure metric
    -- (consecutiveZoomWriteFailures), so we just react to its boolean result.
    -- Raise the re-entrancy guard around it so a write that somehow re-triggers
    -- the FPV toggle is passed through by the hook instead of recursing here.
    if private.SetTogglingFPV then private.SetTogglingFPV(true) end
    local ok = private.SetCameraZoom(desiredZoom)
    if private.SetTogglingFPV then private.SetTogglingFPV(false) end
    if ok then
        retries = 0
        private.QueueSave()
    elseif retries < RECONCILE_MAX_RETRIES then
        -- Engine rejected the write (e.g. a state that owns its own distance).
        -- Try again next frame rather than leaving the camera half-applied.
        retries = retries + 1
        LogDebug(SI_BAV_LOG_SET_APPLY_FAILED, desiredZoom)
        Schedule()
    else
        -- Give up after a bounded run; the self-check surfaces the failure run.
        retries = 0
        LogWarn(SI_BAV_LOG_TOGGLE_PAIR_UNDO_FAILED)
    end
end

-- Arm the next-frame reconcile, unless one is already pending. The pending guard
-- is what collapses a same-frame probe PAIR to a single write: the second
-- toggle's Schedule() is a no-op, so only one reconcile fires for the pair.
Schedule = function()
    if pending then
        return
    end
    pending = true
    EVENT_MANAGER:RegisterForUpdate(RECONCILE_UPDATE_NAME, 0, OnReconcileUpdate)
end

-- Decide ownership for this toggle and, when owned, flip the intent + schedule.
-- Returns true when we took ownership (the hook should block the engine), false
-- to pass through to the engine's native handling (the normal third->FPV case).
function ZoomReconciler.HandleToggle()
    local zoom = private.GetCameraZoom()
    local owned = private.IsZoomLimited() or zoom <= ZOOM_FPV
    if not owned then
        -- Normal third-person -> FPV: let the engine run its native transition.
        -- Other addons' in-frame measurement of this ordinary case keeps working.
        LogDebug(SI_BAV_LOG_TOGGLE_PASSING)
        return false
    end

    -- Flip the intent relative to its OWN value, never the live camera: two
    -- flips (a probe pair) return desiredZoom to its start, so a probe that
    -- never rendered cannot corrupt the result or the remembered third zoom.
    if desiredZoom == nil then
        -- First owned toggle: seed straight to the opposite of the live view.
        desiredZoom = (zoom <= ZOOM_FPV) and ResolveThirdPersonTarget() or ZOOM_FPV
    elseif desiredZoom <= ZOOM_FPV then
        desiredZoom = ResolveThirdPersonTarget()   -- FPV -> third person
        LogDebug(SI_BAV_LOG_TOGGLE_TO_THIRD, desiredZoom)
    else
        -- third person -> FPV: remember the third-person distance first (only if
        -- it is a "normal" zoom past the threshold), mirroring the old handler.
        if desiredZoom > private.GetConfiguredLastZoomThreshold() then
            private.SetLastZoom(desiredZoom)
        end
        desiredZoom = ZOOM_FPV
        LogDebug(SI_BAV_LOG_TOGGLE_TO_FPV, zoom)
    end

    -- NOTE: a probe pair SPLIT across two frames while in a limited state can
    -- produce a single frame of FPV before the next reconcile restores the
    -- third-person intent. That one-frame flicker is strictly better than the
    -- old stuck-FPV bug and only occurs in the owned/limited state.
    Schedule()
    LogDebug(SI_BAV_LOG_TOGGLE_HANDLED)
    return true
end

-- Read-only snapshot for /bav dump and the self-check. Fresh table so callers
-- cannot mutate our state.
function ZoomReconciler.GetDiagnostics()
    return {
        desiredZoom = desiredZoom,
        pending     = pending,
        retries     = retries,
    }
end