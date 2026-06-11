-- ===========================================================================
-- ContextPresets.lua
-- ---------------------------------------------------------------------------
-- Named bundles of camera settings, plus snapshot/restore.
--
-- A "preset" is a plain table of camera property values keyed by the same
-- internal names CameraSettings uses (distance, thirdPersonFov, shoulder, ...).
-- This module can:
--   * Snapshot()  -- read the current camera into a fresh preset table.
--   * Apply()     -- write a preset's values back onto the camera.
--   * Capture()/Restore() a single named "scratch" preset, used by callers
--     that want to stash the live camera, change it, then put it back exactly
--     (e.g. a temporary cinematic framing, or the emergency restore button).
--
-- Design notes:
--   * All engine I/O goes through CameraSettings; this module never touches
--     GetSetting/SetSetting directly, and unsupported properties are silently
--     skipped so an unexpected client build degrades instead of crashing.
--   * A preset only carries the keys it actually has a value for. Apply() only
--     writes those keys, so a partial preset (e.g. "just FOV and shoulder")
--     leaves every other camera property untouched.
--   * Nothing here is enabled by default or wired to SavedVariables; Settings.lua
--     owns persistence and decides when to call these.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.ContextPresets = addon.ContextPresets or {}
local ContextPresets = addon.ContextPresets

local CameraSettings = addon.CameraSettings

-- Hot-path / library globals bound to locals once at load.
local ipairs  = ipairs
local pairs   = pairs
local type    = type

-- Logging helpers are generated in the core file and exported on private.
-- Resolve them lazily so load order between files cannot break us.
local function LogWarn(...)
    if private.LogWarn then private.LogWarn(...) end
end

local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

local function LogInfo(...)
    if private.LogInfo then private.LogInfo(...) end
end

-- ---------------------------------------------------------------------------
-- Preset shape
-- ---------------------------------------------------------------------------
-- The ordered list of camera properties a preset may carry. Order is fixed so
-- Apply() writes deterministically (distance first, framing after) and so two
-- snapshots iterate identically. Keys must exist as CameraSettings descriptors;
-- anything CameraSettings does not support on this client is skipped at runtime.
local PRESET_KEYS = {
    "distance",
    "thirdPersonFov",
    "firstPersonFov",
    "horizontalOffset",
    "verticalOffset",
    "shoulder",
    "headBob",
    "screenShake",
}

-- Keys with special arbitration handling, named once to avoid stringly-typed
-- comparisons in Apply. FOV is owned by FovArbiter; distance changes here bypass
-- the zoom hook and so must trigger a dynamic-FOV reassert.
local FOV_KEY      = "thirdPersonFov"
local DISTANCE_KEY = "distance"

-- ---------------------------------------------------------------------------
-- Snapshot / Apply
-- ---------------------------------------------------------------------------

-- Read the current camera into a fresh preset table. Only properties that are
-- supported on this client AND read back successfully are included, so the
-- result is always a faithful, replayable subset of the live camera state.
function ContextPresets.Snapshot()
    local preset = {}
    for _, key in ipairs(PRESET_KEYS) do
        if CameraSettings.IsSupported(key) then
            local value, ok = CameraSettings.Get(key)
            if ok then
                preset[key] = value
            end
        end
    end
    return preset
end

-- Write a preset's values back onto the camera. Iterates PRESET_KEYS (not the
-- table) so writes are deterministic and unknown/extra keys in the preset are
-- ignored. Only keys the preset actually carries are written, leaving every
-- other camera property untouched. Returns the number of properties applied and
-- the number that failed, so callers can decide whether a partial apply matters.
--
-- isRestore distinguishes the two FOV semantics:
--   * false/nil (applying a preset bundle): FOV is *pinned* through an arbiter
--     hold so a later zoom tick cannot stomp the preset's framing.
--   * true (restoring the player's own snapshot): FOV is handed back to its
--     normal owner -- written directly, then any hold we took is released and
--     dynamic FOV reasserted -- so restoring never leaks a hold. A snapshot
--     always carries thirdPersonFov, so without this the FOV key would re-pin
--     on every preset->default exit and dynamic FOV would stay suppressed until
--     a /reloadui.
function ContextPresets.Apply(preset, isRestore)
    if type(preset) ~= "table" then
        LogWarn("ContextPresets.Apply: expected a table, got %s", type(preset))
        return 0, 0
    end

    local arbiter = addon.FovArbiter
    local applied, failed = 0, 0

    for _, key in ipairs(PRESET_KEYS) do
        local value = preset[key]
        if value ~= nil and CameraSettings.IsSupported(key) then
            if key == FOV_KEY and arbiter and not isRestore then
                -- FOV is arbitrated: pin it through a hold so a subsequent zoom
                -- change cannot stomp the preset's framing. The hold pins the
                -- value, so we do not also write it directly here.
                if arbiter.BeginHold("ContextPresets", value) then
                    applied = applied + 1
                else
                    failed = failed + 1
                end
            elseif CameraSettings.Set(key, value) then
                applied = applied + 1
            else
                failed = failed + 1
            end
        end
    end

    -- Reconcile FOV ownership:
    --   * Restore, or a preset that omits FOV -> release any hold we previously
    --     took so dynamic FOV resumes, then (when the distance is known)
    --     reassert it at the restored/new distance. This is the path that keeps
    --     a leaked hold from killing dynamic FOV after a preset clears.
    --   * A preset that pins FOV -> the BeginHold above already owns it; done.
    if arbiter and (isRestore or preset[FOV_KEY] == nil) then
        arbiter.EndHold("ContextPresets")
        if preset[DISTANCE_KEY] ~= nil then
            arbiter.RequestDynamic(preset[DISTANCE_KEY])
        end
    end

    LogDebug("ContextPresets.Apply: applied=%d, failed=%d", applied, failed)
    return applied, failed
end

-- ---------------------------------------------------------------------------
-- Named scratch slots (capture / restore)
-- ---------------------------------------------------------------------------
-- A small registry of named snapshots, for the "stash the live camera, change
-- it, then put it back" pattern. Each slot holds exactly one preset; capturing
-- again overwrites it. Kept in-memory only -- persistence is Settings.lua's job.
local slots = {}

-- Snapshot the current camera into the named slot, overwriting any previous
-- capture under that name. Returns the captured preset so callers can inspect
-- or persist it. The name is required; a nil/empty name is rejected.
function ContextPresets.Capture(name)
    if type(name) ~= "string" or name == "" then
        LogWarn("ContextPresets.Capture: a non-empty slot name is required")
        return nil
    end

    local preset = ContextPresets.Snapshot()
    slots[name] = preset
    LogDebug("ContextPresets.Capture: stored slot '%s'", name)
    return preset
end

-- Returns true if a capture exists under the given name.
function ContextPresets.HasCapture(name)
    return slots[name] ~= nil
end

-- Re-apply a previously captured slot onto the camera. Returns false when the
-- slot does not exist; otherwise returns Apply's (applied, failed) counts so a
-- partial restore is observable. The capture is left in place after a restore,
-- so the same stash can be restored more than once.
function ContextPresets.Restore(name)
    local preset = slots[name]
    if preset == nil then
        LogWarn("ContextPresets.Restore: no capture named '%s'", tostring(name))
        return false
    end

    LogDebug("ContextPresets.Restore: restoring slot '%s'", name)
    return ContextPresets.Apply(preset, true)
end

-- Forget a captured slot. Safe to call when the slot does not exist.
function ContextPresets.ClearCapture(name)
    slots[name] = nil
end

-- ===========================================================================
-- State-driven controller
-- ---------------------------------------------------------------------------
-- Everything above is the stateless primitive layer. The controller below adds
-- the actual feature: it watches the player's state (combat/werewolf/stealth/
-- mounted/sprint), picks the highest-priority ACTIVE state that the user has
-- enabled, and applies that state's cinematic bundle -- snapshotting the live
-- camera the first time it changes anything so it can be restored exactly when
-- the player returns to the default state or the feature is switched off.
--
-- Design rules:
--   * OFF by default. Until Configure{enabled=true} runs, the controller
--     registers no events, starts no polling, and never touches the camera.
--   * Bundles are FIXED named constants (not per-state sliders) scaled by a
--     single global intensity multiplier, so the UI stays small but the values
--     can be expanded later without touching callers.
--   * Exactly one state is active at a time (highest priority wins). There is
--     no per-frame fighting: we only re-apply when the resolved state changes.
-- ===========================================================================

-- State identifiers. STATE_DEFAULT is the implicit "nothing special" state and
-- has no bundle (its "bundle" is the restored original snapshot).
local STATE_DEFAULT  = "default"
local STATE_COMBAT   = "combat"
local STATE_WEREWOLF = "werewolf"
local STATE_STEALTH  = "stealth"
local STATE_MOUNTED  = "mounted"
local STATE_SPRINT   = "sprint"

-- Resolution order, highest priority first. The first state in this list that
-- is both physically active AND enabled by the user becomes the active state.
-- NOTE: the approved spec listed combat > stealth > mounted > sprint and did
-- not place werewolf. Per user decision, werewolf sits ABOVE combat: it is a
-- special full-body transform the player can be in even outside of combat, so
-- its framing must win whenever active. Placing it below combat would let the
-- combat preset override the werewolf framing during fights, which is not the
-- intended behavior.
local STATE_PRIORITY = {
    STATE_WEREWOLF,
    STATE_COMBAT,
    STATE_STEALTH,
    STATE_MOUNTED,
    STATE_SPRINT,
}

-- Fixed cinematic bundles, expressed as OFFSETS from the player's own camera
-- (snapshotted at activation), not absolute values, so they layer on top of
-- whatever the player already runs. Offsets are scaled by the global intensity
-- multiplier before being applied. Absolute-only keys (e.g. FOV) use a target
-- that intensity blends toward from the snapshot.
local STATE_BUNDLES = {
    [STATE_COMBAT] = {
        fovTarget        = 60,    -- widen slightly for situational awareness
        distanceOffset   = 0.6,   -- pull back a touch
        verticalOffset   = 0.05,
    },
    [STATE_WEREWOLF] = {
        fovTarget        = 63,
        distanceOffset   = 1.2,   -- big beast, pull back more
        verticalOffset   = 0.10,
    },
    [STATE_STEALTH] = {
        fovTarget        = 50,    -- tighten in for a focused, sneaky feel
        distanceOffset   = -0.4,
        shoulderTarget   = 0.65,  -- over-the-shoulder framing
    },
    [STATE_MOUNTED] = {
        fovTarget        = 58,
        distanceOffset   = 1.0,   -- show the mount
    },
    [STATE_SPRINT] = {
        fovTarget        = 61,    -- subtle speed-sense widening
        distanceOffset   = 0.3,
    },
}

-- ---------------------------------------------------------------------------
-- Controller runtime state
-- ---------------------------------------------------------------------------
-- All inert until Configure{enabled=true}. enabledStates is the per-state user
-- toggle map; intensity scales every bundle (0 = no effect, 1 = full bundle).
local controller = {
    enabled       = false,
    intensity     = 1.0,
    enabledStates = {},      -- [stateId] = true/false
    activeState   = STATE_DEFAULT,
    physical      = {},      -- [stateId] = true while physically in that state
    restoreSlot   = "ContextPresets.controllerRestore",
    polling       = false,
    recovered     = false,   -- load-time snapshot recovery runs once per session
}

-- The named scratch slot used to stash the player's pre-preset camera. Reusing
-- the Capture/Restore machinery above keeps a single restore path.
local RESTORE_SLOT = controller.restoreSlot

-- Mirror the in-memory restore snapshot into persistent storage (owned by
-- Settings) so a /reloadui, logout, or crash WHILE a preset is overriding the
-- camera can hand the player's real camera back next session instead of leaving
-- the preset's offsets baked into their settings. Resolved lazily so file load
-- order between Settings and this module cannot matter. Passing nil clears the
-- persisted copy. Best-effort: if Settings is unavailable the in-memory snapshot
-- still works for the current session.
local function PersistRestoreSnapshot(snapshot)
    local settings = addon.Settings
    if settings and settings.SetPresetRestoreSnapshot then
        settings.SetPresetRestoreSnapshot(snapshot)
    end
end

-- Capture the live camera into the restore slot (once) and persist it. No-op if
-- a capture already exists, so the snapshot always reflects the player's own
-- framing from the first departure off default -- never another state's bundle.
local function CaptureRestore()
    if not ContextPresets.HasCapture(RESTORE_SLOT) then
        PersistRestoreSnapshot(ContextPresets.Capture(RESTORE_SLOT))
    end
end

-- Hand the camera back to the captured snapshot and forget it everywhere: the
-- in-memory slot AND the persisted copy. Safe to call when nothing is captured
-- (still clears any stale persisted copy, which is the desired post-condition).
local function RestoreAndForget()
    if ContextPresets.HasCapture(RESTORE_SLOT) then
        ContextPresets.Restore(RESTORE_SLOT)
        ContextPresets.ClearCapture(RESTORE_SLOT)
    end
    PersistRestoreSnapshot(nil)
end

-- Clamp helper (kept local; mirrors DynamicFov's tiny local clamp so the module
-- has no hard dependency on private.ClampNumber across load order).
local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- Build the concrete preset to apply for a state, given the live snapshot and
-- the current intensity. Offsets are added to the snapshot and scaled by
-- intensity; *Target values blend from the snapshot toward the target by
-- intensity. Returns a fresh preset table carrying only the keys it sets.
local function ResolveBundle(stateId, snapshot)
    local bundle = STATE_BUNDLES[stateId]
    if not bundle or type(snapshot) ~= "table" then
        return nil
    end

    local k = Clamp(controller.intensity, 0, 1)
    local preset = {}

    if bundle.distanceOffset ~= nil and snapshot.distance ~= nil then
        preset.distance = snapshot.distance + bundle.distanceOffset * k
    end
    if bundle.fovTarget ~= nil and snapshot.thirdPersonFov ~= nil then
        preset.thirdPersonFov = snapshot.thirdPersonFov
            + (bundle.fovTarget - snapshot.thirdPersonFov) * k
    end
    if bundle.shoulderTarget ~= nil and snapshot.shoulder ~= nil then
        preset.shoulder = snapshot.shoulder
            + (bundle.shoulderTarget - snapshot.shoulder) * k
    end
    if bundle.verticalOffset ~= nil and snapshot.verticalOffset ~= nil then
        preset.verticalOffset = snapshot.verticalOffset + bundle.verticalOffset * k
    end

    return preset
end

-- ---------------------------------------------------------------------------
-- State resolution + transitions
-- ---------------------------------------------------------------------------

-- Pick the highest-priority state that is both physically active and enabled by
-- the user. Falls back to STATE_DEFAULT when nothing qualifies.
local function ResolveActiveState()
    for _, stateId in ipairs(STATE_PRIORITY) do
        if controller.physical[stateId] and controller.enabledStates[stateId] then
            return stateId
        end
    end
    return STATE_DEFAULT
end

-- Transition from the current active state to a newly resolved one. Snapshots
-- the live camera on the first departure from default, applies the new state's
-- bundle, and restores the snapshot when returning to default.
local function ApplyState(stateId)
    if stateId == controller.activeState then
        return
    end

    LogDebug("ContextPresets: state %s -> %s", controller.activeState, stateId)

    if stateId == STATE_DEFAULT then
        -- Returning to baseline: put the original camera back exactly and drop
        -- the snapshot (in-memory and persisted) -- no preset overrides now.
        RestoreAndForget()
        controller.activeState = STATE_DEFAULT
        return
    end

    -- Entering (or switching between) a special state. Snapshot once, on the
    -- first transition away from default, so restore returns the player's own
    -- framing rather than another state's bundle. Persisted so a session that
    -- ends mid-preset can recover the camera next load.
    CaptureRestore()

    local snapshot = slots[RESTORE_SLOT]
    local preset = ResolveBundle(stateId, snapshot)
    if preset then
        ContextPresets.Apply(preset)
    end
    controller.activeState = stateId
end

-- Recompute the active state from current inputs and apply if it changed.
local function Reevaluate()
    if not controller.enabled then
        return
    end
    ApplyState(ResolveActiveState())
end

-- ---------------------------------------------------------------------------
-- Engine state inputs (events + sprint polling)
-- ---------------------------------------------------------------------------
local EVENT_NAMESPACE = "BAV_ContextPresets"
local SPRINT_POLL_NAME = "BAV_ContextPresets_Sprint"
local SPRINT_POLL_MS = 150

-- Generic setter: record a physical state flag and re-evaluate if it flipped.
local function SetPhysical(stateId, active)
    active = active and true or false
    if controller.physical[stateId] == active then
        return
    end
    controller.physical[stateId] = active
    Reevaluate()
end

local function OnCombatState(_, inCombat)
    SetPhysical(STATE_COMBAT, inCombat)
end

local function OnStealthState(_, unitTag, stealthState)
    if unitTag ~= "player" then
        return
    end
    -- Treat both "hidden" and "will-be-seen" as stealthed for framing purposes.
    local stealthed = (stealthState == STEALTH_STATE_HIDDEN)
        or (stealthState == STEALTH_STATE_HIDDEN_ALMOST_DETECTED)
    SetPhysical(STATE_STEALTH, stealthed)
end

local function OnMountedState(_, mounted)
    SetPhysical(STATE_MOUNTED, mounted)
end

local function OnWerewolfState(_, werewolf)
    SetPhysical(STATE_WEREWOLF, werewolf)
end

-- Sprint has no dedicated event, so we poll while the feature is enabled AND
-- the sprint state is one the user actually toggled on -- otherwise we never
-- start the timer, keeping overhead at zero for users who don't use it.
-- DETECTION: the client exposes no reliable "is sprinting" query, so we follow
-- the common addon approach and read the Shift key (ESO's default sprint bind)
-- via IsShiftKeyDown(), gated on IsPlayerMoving() so that holding Shift while
-- standing still or in menus does not trigger the sprint preset.
-- NOTE: this assumes the player kept sprint on the default Shift bind; if they
-- rebound it, detection will not match. Acceptable per user decision.
local function PollSprint()
    local sprinting = IsShiftKeyDown() and IsPlayerMoving()
    SetPhysical(STATE_SPRINT, sprinting)
end

local function StartSprintPolling()
    if controller.polling then
        return
    end
    controller.polling = true
    EVENT_MANAGER:RegisterForUpdate(SPRINT_POLL_NAME, SPRINT_POLL_MS, PollSprint)
end

local function StopSprintPolling()
    if not controller.polling then
        return
    end
    controller.polling = false
    EVENT_MANAGER:UnregisterForUpdate(SPRINT_POLL_NAME)
    SetPhysical(STATE_SPRINT, false)
end

-- Subscribe to all state events. Idempotent: EVENT_MANAGER replaces an existing
-- registration for the same (namespace, event) pair, so double-calling is safe.
local function RegisterStateEvents()
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_COMBAT_STATE, OnCombatState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_STEALTH_STATE_CHANGED, OnStealthState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_MOUNTED_STATE_CHANGED, OnMountedState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_WEREWOLF_STATE_CHANGED, OnWerewolfState)
end

local function UnregisterStateEvents()
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_COMBAT_STATE)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_STEALTH_STATE_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_MOUNTED_STATE_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_WEREWOLF_STATE_CHANGED)
end

-- ---------------------------------------------------------------------------
-- Public controller API (wired to SavedVariables by Settings.lua)
-- ---------------------------------------------------------------------------

-- Returns true while the controller is actively managing the camera.
function ContextPresets.IsEnabled()
    return controller.enabled
end

-- Returns the currently active state id (STATE_DEFAULT when idle/disabled).
function ContextPresets.GetActiveState()
    return controller.activeState
end

-- Turn the whole feature on or off. Turning OFF unregisters every event, stops
-- sprint polling, restores the player's snapshot, and clears runtime state so
-- the module touches nothing further. Turning ON registers events and does an
-- immediate evaluation so the correct bundle applies without waiting for the
-- next state change.
local function SetEnabled(enabled)
    enabled = enabled and true or false
    if enabled == controller.enabled then
        return
    end

    if enabled then
        controller.enabled = true
        RegisterStateEvents()
        -- Sprint polling only runs when sprint is one of the enabled states.
        if controller.enabledStates[STATE_SPRINT] then
            StartSprintPolling()
        end
        Reevaluate()
    else
        -- Tear down in the reverse order, then put the camera back.
        UnregisterStateEvents()
        StopSprintPolling()
        ApplyState(STATE_DEFAULT)
        controller.physical = {}
        controller.enabled = false
    end
end

-- Apply a configuration table, typically mirrored from SavedVariables:
--   enabled       boolean
--   intensity     number 0..1
--   states        { combat=bool, werewolf=bool, stealth=bool, mounted=bool, sprint=bool }
-- Unspecified fields are left unchanged. Safe to call repeatedly; it diffs and
-- only re-evaluates when something that affects the active state changed.
function ContextPresets.Configure(options)
    options = options or {}

    if options.intensity ~= nil then
        controller.intensity = Clamp(tonumber(options.intensity) or controller.intensity, 0, 1)
    end

    if type(options.states) == "table" then
        for _, stateId in ipairs(STATE_PRIORITY) do
            if options.states[stateId] ~= nil then
                controller.enabledStates[stateId] = options.states[stateId] and true or false
            end
        end
        -- Sprint polling must follow the sprint toggle while already enabled.
        if controller.enabled then
            if controller.enabledStates[STATE_SPRINT] then
                StartSprintPolling()
            else
                StopSprintPolling()
            end
        end
    end

    if options.enabled ~= nil then
        SetEnabled(options.enabled)
    elseif controller.enabled then
        -- Re-apply with possibly-new intensity / toggles.
        controller.activeState = STATE_DEFAULT  -- force ApplyState to recompute
        RestoreAndForget()
        Reevaluate()
    end

    LogDebug("ContextPresets.Configure: enabled=%s intensity=%.2f",
        tostring(controller.enabled), controller.intensity)
end

-- Emergency recovery: forcibly hand the camera back to the player, no matter
-- what state the module is in. This is the LAM "restore camera" panic button,
-- meant for the case where a preset or FOV hold got stuck (e.g. a failed apply,
-- an orphaned hold, or a state event the client never fired the "off" side of).
--
-- Steps, ordered so the camera ends up under the player's control:
--   1. Force-release any FOV hold, ignoring ownership, so dynamic/manual FOV is
--      free again even if the owning source never released it.
--   2. Restore the player's captured pre-preset snapshot if one exists, putting
--      their own framing back exactly; then forget the slot.
--   3. Reset runtime state to default so the next Reevaluate starts clean.
--
-- It deliberately does NOT change the user's saved toggles or disable the
-- feature: it recovers the camera, then lets normal evaluation resume. Returns
-- true if it had anything to undo (a hold or a stored snapshot), false if the
-- camera was already in the player's hands.
function ContextPresets.EmergencyRestore()
    local didSomething = false

    local arbiter = addon.FovArbiter
    if arbiter and arbiter.ForceRelease() then
        didSomething = true
    end

    if ContextPresets.HasCapture(RESTORE_SLOT) then
        ContextPresets.Restore(RESTORE_SLOT)
        ContextPresets.ClearCapture(RESTORE_SLOT)
        didSomething = true
    end
    -- Always drop the persisted snapshot too: after a panic restore no preset is
    -- overriding the camera, so leaving a stored copy could resurrect it on the
    -- next load. Cheap and idempotent when there was nothing stored.
    PersistRestoreSnapshot(nil)

    -- Drop runtime state so a still-enabled controller re-applies from scratch
    -- rather than thinking it is mid-transition.
    controller.activeState = STATE_DEFAULT
    controller.physical = {}

    LogInfo("ContextPresets.EmergencyRestore: camera handed back to player (changed=%s)",
        tostring(didSomething))

    -- If the feature is still on, let it re-evaluate so any genuinely-active
    -- state re-applies cleanly on the next engine event.
    if controller.enabled then
        Reevaluate()
    end

    return didSomething
end

-- ---------------------------------------------------------------------------
-- Load-time recovery
-- ---------------------------------------------------------------------------
-- Call ONCE after the player is in the world (EVENT_PLAYER_ACTIVATED), BEFORE
-- the controller is allowed to capture anything. If the previous session ended
-- while a preset was overriding the camera, the engine settings still hold the
-- preset's values and Settings has the player's real pre-preset snapshot. Write
-- that snapshot straight back (isRestore=true: direct write, no FOV re-pin),
-- then clear the persisted copy so a clean session starts from the player's own
-- framing. Without this, the controller would snapshot the dirty values and
-- treat them as the new baseline -- the offsets would compound every session.
--
-- No-op when nothing was persisted (the normal case). One-shot per session:
-- guarded by controller.recovered so a later zone change (which also fires
-- EVENT_PLAYER_ACTIVATED) cannot tear down a preset that legitimately became
-- active during THIS session and re-persisted its own snapshot.
function ContextPresets.RecoverPersistedSnapshot()
    if controller.recovered then
        return false
    end
    controller.recovered = true

    local settings = addon.Settings
    if not (settings and settings.GetPresetRestoreSnapshot) then
        return false
    end

    local snapshot = settings.GetPresetRestoreSnapshot()
    if type(snapshot) ~= "table" then
        return false
    end

    LogInfo("ContextPresets.RecoverPersistedSnapshot: restoring camera left overridden by a preset last session")
    ContextPresets.Apply(snapshot, true)

    -- Forget it everywhere: the in-memory slot must not start out thinking it
    -- holds a capture, and the persisted copy has served its purpose.
    ContextPresets.ClearCapture(RESTORE_SLOT)
    PersistRestoreSnapshot(nil)
    return true
end

-- ---------------------------------------------------------------------------
-- Diagnostics accessor
-- ---------------------------------------------------------------------------
-- Read-only snapshot of internal controller state, for the SelfCheck module to
-- validate invariants without reaching into module-locals. Returns a fresh flat
-- table (never the live controller) so a caller cannot mutate runtime state.
--   enabled         controller is actively managing the camera
--   activeState     currently resolved state id
--   hasRestoreSnapshot  a pre-preset snapshot is currently captured
--   slotCount       number of live scratch slots (should stay tiny; growth = leak)
--   sprintPolling   sprint OnUpdate timer is currently registered
--   sprintEnabled   sprint is among the user-enabled states
function ContextPresets.GetDiagnostics()
    local slotCount = 0
    for _ in pairs(slots) do
        slotCount = slotCount + 1
    end

    return {
        enabled            = controller.enabled,
        activeState        = controller.activeState,
        hasRestoreSnapshot = ContextPresets.HasCapture(RESTORE_SLOT),
        slotCount          = slotCount,
        sprintPolling      = controller.polling,
        sprintEnabled      = controller.enabledStates[STATE_SPRINT] and true or false,
    }
end
