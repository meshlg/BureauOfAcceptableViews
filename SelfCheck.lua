-- ===========================================================================
-- SelfCheck.lua
-- ---------------------------------------------------------------------------
-- A passive reliability layer. It never runs in the frame loop and never
-- profiles CPU; instead it validates the addon's own invariants and samples the
-- footprint of BAV-owned tables at rare, naturally-quiet moments (load, zone
-- change, on demand) so a silent regression -- an orphaned FOV hold, a leaked
-- snapshot, a runaway timer, or our own state growing without bound -- surfaces
-- as a one-line warning instead of a mystery bug report.
--
-- Design rules (mirror the rest of the addon):
--   * PULL, never PUSH. No RegisterForUpdate, no polling. Checks run only when
--     something already happened (OnPlayerActivated / OnPlayerDeactivated) or
--     when the player asks (/bav selfcheck). Zero cost during play.
--   * Read-only. It inspects state through public diagnostics accessors and
--     never mutates camera, settings, or controller state.
--   * WARN-ONLY by default. Silent while healthy; it speaks up only when an
--     invariant is violated or our owned-table footprint grows past a threshold
--     between samples.
--   * Lazy dependency resolution so manifest load order cannot break it.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.SelfCheck = addon.SelfCheck or {}
local SelfCheck = addon.SelfCheck

-- Hot-path / library globals bound to locals once at load.
local ipairs         = ipairs
local pairs          = pairs
local type           = type
local tostring       = tostring

-- Logging + chat resolved lazily so file load order cannot break us.
local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

local function LogWarn(...)
    if private.LogWarn then private.LogWarn(...) end
end

local function ChatError(message, ...)
    if private.ChatError then private.ChatError(message, ...) end
end

local function ChatInfo(message, ...)
    if private.ChatInfo then private.ChatInfo(message, ...) end
end

-- ---------------------------------------------------------------------------
-- Footprint sampling (BAV-owned tables only)
-- ---------------------------------------------------------------------------
-- The engine offers no per-addon memory figure: collectgarbage("count") is the
-- WHOLE Lua VM (every addon + the game UI) and GetAddOnManager exposes no byte
-- count. So instead of guessing at heap bytes we cannot attribute, we measure
-- the one thing we genuinely own: the number of live entries in our own tables
-- (saved variables + runtime structures). If that count climbs without bound
-- between samples, *that* is a real BAV leak -- our own state growing -- which
-- is exactly what the player asked us to watch, and nothing else.
--
-- We keep a baseline (first sample this session) and the previous sample, and
-- only warn when our entry count grows by more than FOOTPRINT_GROWTH_WARN
-- between two consecutive samples, the shape a genuine leak makes. Routine
-- variation from normal play stays quiet.
local FOOTPRINT_GROWTH_WARN = 256  -- entries added between samples worth a look

-- Recursion depth cap so a pathological/cyclic table can never make counting
-- itself the performance problem we are trying to detect.
local FOOTPRINT_MAX_DEPTH = 8

local footprint = {
    baselineEntries = nil,  -- first sample this session
    lastEntries     = nil,  -- previous sample
}

-- Count entries in a table we own, recursively, guarding against cycles (via a
-- seen set) and runaway depth. Returns the running total. Only nested *tables*
-- recurse; scalar values each count as one entry. Non-table inputs count as 0.
local function CountEntries(value, seen, depth)
    if type(value) ~= "table" or depth > FOOTPRINT_MAX_DEPTH then
        return 0
    end
    if seen[value] then
        return 0  -- already counted; avoids double-count and cycles
    end
    seen[value] = true

    local count = 0
    for _, v in pairs(value) do
        count = count + 1
        if type(v) == "table" then
            count = count + CountEntries(v, seen, depth + 1)
        end
    end
    return count
end

-- Sum the live entry count across every table BAV owns. Saved variables are our
-- persistent data tree; the controller's scratch-slot count is our largest
-- runtime structure and is already exposed read-only via GetDiagnostics. Both
-- are resolved lazily and defensively so a not-yet-loaded module just counts 0.
local function CountOwnedEntries()
    local total = 0
    local seen = {}

    -- Saved variables: the data we persist and own outright.
    local settings = addon.Settings
    if settings and settings.GetSavedVars then
        total = total + CountEntries(settings.GetSavedVars(), seen, 0)
    end

    -- Controller runtime structures surfaced through diagnostics.
    local presets = addon.ContextPresets
    if presets and presets.GetDiagnostics then
        local diag = presets.GetDiagnostics()
        if diag and diag.slotCount then
            total = total + diag.slotCount
        end
    end

    return total
end

-- Take a footprint sample. Returns currentEntries, growthSinceLast,
-- growthSinceBase. The two growth figures are nil on the very first sample.
local function SampleFootprint()
    local currentEntries = CountOwnedEntries()

    local growthSinceLast, growthSinceBase
    if footprint.lastEntries ~= nil then
        growthSinceLast = currentEntries - footprint.lastEntries
    end
    if footprint.baselineEntries ~= nil then
        growthSinceBase = currentEntries - footprint.baselineEntries
    else
        footprint.baselineEntries = currentEntries
    end

    footprint.lastEntries = currentEntries
    return currentEntries, growthSinceLast, growthSinceBase
end

-- ---------------------------------------------------------------------------
-- Invariant checks
-- ---------------------------------------------------------------------------
-- Each check returns a localized problem string when it finds a violation, or
-- nil when healthy. They only read public diagnostics accessors, so a missing
-- module (feature disabled / not loaded) simply means that check is skipped.

-- The scratch-slot registry should hold at most a couple of entries (the single
-- controller restore slot, plus any transient capture). A larger count means
-- slots are being captured without being cleared -- a table leak.
local SLOT_COUNT_WARN = 4

-- Orphaned FOV hold: the arbiter is pinning FOV, but the preset controller is
-- back at the default state and so should own nothing. This is the "stuck hold"
-- that previously could only be cleared by the EmergencyRestore panic button.
local function CheckOrphanedFovHold()
    local arbiter = addon.FovArbiter
    local presets = addon.ContextPresets
    if not (arbiter and arbiter.IsHeld and presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if arbiter.IsHeld() and diag.activeState == "default" then
        return GetString(SI_BAV_SELFCHECK_ORPHANED_HOLD)
    end
    return nil
end

-- Snapshot/state coherence: a pre-preset snapshot is captured but the controller
-- is at default (nothing should be overriding the camera), or a non-default
-- state is active with no snapshot to restore from. Either way ApplyState's
-- contract -- snapshot exists iff a preset is overriding -- has been broken.
local function CheckSnapshotCoherence()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.hasRestoreSnapshot and diag.activeState == "default" then
        return GetString(SI_BAV_SELFCHECK_SNAPSHOT_AT_DEFAULT)
    end
    if not diag.hasRestoreSnapshot and diag.activeState ~= "default" then
        return GetString(SI_BAV_SELFCHECK_MISSING_SNAPSHOT)
    end
    return nil
end

-- Sprint polling should run only while the controller is enabled AND sprint is a
-- user-enabled state. A timer left registered otherwise is wasted per-frame work
-- -- exactly the kind of background cost this addon promises not to incur.
local function CheckSprintPolling()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.sprintPolling and not (diag.enabled and diag.sprintEnabled) then
        return GetString(SI_BAV_SELFCHECK_SPRINT_POLL_LEAK)
    end
    return nil
end

-- The scratch-slot registry should stay tiny; unbounded growth signals captures
-- that never got cleared.
local function CheckSlotLeak()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.slotCount and diag.slotCount > SLOT_COUNT_WARN then
        return zo_strformat(GetString(SI_BAV_SELFCHECK_SLOT_LEAK), diag.slotCount)
    end
    return nil
end

-- The transition-glide updater is temporary: it must unregister itself the moment
-- a transition lands. If a glide is still flagged active while the controller is
-- disabled, the self-tearing updater leaked -- the same class of standing
-- per-frame cost the sprint-poll check guards against.
local function CheckTransitionLeak()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.transitioning and not diag.enabled then
        return GetString(SI_BAV_SELFCHECK_TRANSITION_LEAK)
    end
    return nil
end

-- A transition FOV glide is driven by the arbiter and must stop the instant its
-- transition lands (the controller pins the exact target and ends the hold). If
-- a glide is still running while the controller is disabled, the glide updater
-- leaked -- the same standing per-frame cost the transition-leak check guards.
local function CheckFovGlideLeak()
    local arbiter = addon.FovArbiter
    local presets = addon.ContextPresets
    if not (arbiter and arbiter.IsGliding and presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if arbiter.IsGliding() and not diag.enabled then
        return GetString(SI_BAV_SELFCHECK_FOV_GLIDE_LEAK)
    end
    return nil
end

-- The coalesce timer is a one-shot that re-resolves the active state after a
-- burst of rapid state changes settles. It must unregister itself when it fires
-- and is cancelled on disable. If it is still armed while the controller is
-- disabled, the timer leaked -- the same standing cost the other timer checks
-- guard against.
local function CheckCoalesceLeak()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.coalescePending and not diag.enabled then
        return GetString(SI_BAV_SELFCHECK_COALESCE_LEAK)
    end
    return nil
end

-- The options-window flag tracks whether the ESO settings window is open, during
-- which the controller reverts the camera for editing and suspends evaluation. It
-- is cleared on options-close and on disable. If it is still set while the
-- controller is disabled, the flag leaked -- the controller would wrongly believe
-- the menu is up and suppress evaluation if re-enabled.
local function CheckOptionsOpenLeak()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.optionsOpen and not diag.enabled then
        return GetString(SI_BAV_SELFCHECK_OPTIONS_OPEN_LEAK)
    end
    return nil
end

-- The interaction entry-debounce timer is a one-shot that commits the interaction
-- state after a brief delay (so quick merchant clicks do not peck the camera). It
-- unregisters itself when it fires and is cancelled on chatter-end, disable, and
-- emergency restore. If it is still armed while the controller is disabled, the
-- timer leaked -- the same standing per-frame cost the other timer checks guard.
local function CheckInteractionEntryLeak()
    local presets = addon.ContextPresets
    if not (presets and presets.GetDiagnostics) then
        return nil
    end

    local diag = presets.GetDiagnostics()
    if diag.interactionEntryPending and not diag.enabled then
        return GetString(SI_BAV_SELFCHECK_INTERACTION_ENTRY_LEAK)
    end
    return nil
end

-- Ordered list of invariant checks. Add an entry and it is automatically part of
-- every run and report.
local INVARIANT_CHECKS = {
    CheckOrphanedFovHold,
    CheckSnapshotCoherence,
    CheckSprintPolling,
    CheckSlotLeak,
    CheckTransitionLeak,
    CheckFovGlideLeak,
    CheckCoalesceLeak,
    CheckOptionsOpenLeak,
    CheckInteractionEntryLeak,
}

-- Run every invariant check, returning a list of localized problem strings (empty
-- when everything is healthy).
local function RunInvariants()
    local problems = {}
    for _, check in ipairs(INVARIANT_CHECKS) do
        local problem = check()
        if problem then
            problems[#problems + 1] = problem
        end
    end
    return problems
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Run a self-check pass.
--   verbose = false/nil  -> WARN-ONLY: print nothing when healthy; print only
--                           invariant violations and an over-threshold growth in
--                           our owned-table footprint. This is the automatic
--                           path (OnPlayerActivated etc).
--   verbose = true        -> full report: footprint figures plus an explicit
--                           "all invariants OK" line. This is the /bav selfcheck
--                           path.
-- Returns problemCount, currentOwnedEntries so callers can fold the result into
-- a larger dump if they want. Cheap enough to call at any quiet moment; never
-- call it from a per-frame handler.
function SelfCheck.Run(verbose)
    local currentEntries, growthSinceLast, growthSinceBase = SampleFootprint()
    local problems = RunInvariants()

    -- Invariant violations always surface, in both modes: they are rare and
    -- important. Warn level so they ride the existing chat error styling.
    for _, problem in ipairs(problems) do
        ChatError(SI_BAV_SELFCHECK_PROBLEM, problem)
        LogWarn("SelfCheck: invariant violation: %s", problem)
    end

    -- Footprint: this counts only BAV-owned entries (our saved variables and
    -- runtime structures), so an over-threshold jump IS attributable to us --
    -- our own state grew without bound. Unlike the old whole-VM heap figure,
    -- this is a real BAV leak signal, so we surface it in chat on both paths.
    local footprintGrew = growthSinceLast ~= nil and growthSinceLast > FOOTPRINT_GROWTH_WARN
    if footprintGrew then
        ChatError(SI_BAV_SELFCHECK_FOOTPRINT_GROWTH, growthSinceLast, currentEntries)
        LogWarn("SelfCheck: BAV-owned entries grew by %d between samples (now %d)",
            growthSinceLast, currentEntries)
    end

    if verbose then
        ChatInfo(SI_BAV_SELFCHECK_FOOTPRINT_REPORT,
            currentEntries, growthSinceBase or 0, growthSinceLast or 0)

        -- Report-only backoff status: the detector itself owns the chat advisory,
        -- so here we just surface whether the FPV hook is currently backed off.
        if private.GetConflictDiagnostics then
            local conflict = private.GetConflictDiagnostics()
            if conflict.togglePassive then
                ChatInfo(SI_BAV_SELFCHECK_BACKOFF_ACTIVE, conflict.flipsInWindow)
            else
                ChatInfo(SI_BAV_SELFCHECK_BACKOFF_INACTIVE)
            end
        end

        if #problems == 0 then
            ChatInfo(SI_BAV_SELFCHECK_ALL_OK)
        end
    end

    LogDebug("SelfCheck.Run: problems=%d, ownedEntries=%d", #problems, currentEntries)
    return #problems, currentEntries
end

-- The automatic, quiet entry point wired to engine events. Skips entirely while
-- the player is in combat so a self-check never adds work to a busy moment, and
-- runs warn-only so a healthy addon stays silent. Best-effort: any missing query
-- just means we run anyway.
function SelfCheck.RunAuto()
    if IsUnitInCombat and IsUnitInCombat("player") then
        LogDebug("SelfCheck.RunAuto: skipped (player in combat)")
        return
    end
    SelfCheck.Run(false)
end
