-- ===========================================================================
-- ShoulderControl.lua
-- ---------------------------------------------------------------------------
-- Optional over-the-shoulder (OTS) camera control.
--
-- The third-person camera's horizontal shoulder offset (CameraSettings "shoulder",
-- range -1..1) is swung to one side for a focused, cinematic OTS framing. Three
-- mutually-exclusive modes (the user picks one in settings):
--   * off    -- inert. Registers nothing, writes nothing.
--   * auto   -- swing to the chosen side automatically while in any selected state
--               (combat/stealth/mounted/swimming/sprint); restore on leave.
--   * manual -- swing on demand via the `/bav shoulder` slash command; the auto
--               behavior is disabled. (No keybinding layer exists yet, so manual =
--               slash command for now.)
--
-- Ownership / coexistence with ContextPresets:
--   `shoulder` is otherwise written only by the ContextPresets stealth bundle (and
--   carried in its snapshot/restore). To avoid two writers fighting, ShoulderControl
--   TAKES OWNERSHIP whenever it is enabled (auto or manual): ContextPresets queries
--   OwnsShoulder() and, while true, skips shoulder in both its Snapshot() and its
--   stealth bundle -- so exactly one module touches shoulder at any time. Everything
--   else about the stealth preset (FOV, distance, shake, headBob) is unchanged.
--
-- Recovery (mirrors ContextPresets): the player's pre-swap shoulder is captured the
-- first time we override it and PERSISTED, so a /reloadui, logout, or crash while
-- swung hands the real shoulder back next session instead of baking the swing in.
-- ===========================================================================

local addon = BureauOfAcceptableViews
local private = addon.private

addon.ShoulderControl = addon.ShoulderControl or {}
local ShoulderControl = addon.ShoulderControl

local CameraSettings = addon.CameraSettings

-- Hot-path / library globals bound to locals once at load.
local tonumber = tonumber
local pairs    = pairs
local type     = type
local EVENT_MANAGER = EVENT_MANAGER

local function LogDebug(...)
    if private.LogDebug then private.LogDebug(...) end
end

local function LogInfo(...)
    if private.LogInfo then private.LogInfo(...) end
end

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local MODE_OFF    = "off"
local MODE_AUTO   = "auto"
local MODE_MANUAL = "manual"

local SIDE_LEFT   = "left"
local SIDE_RIGHT  = "right"
local SIDE_CENTER = "center"

local SHOULDER_KEY = "shoulder"

-- The auto-trigger states ShoulderControl can react to. Reuses the same engine
-- states the rest of the addon tracks; "any active trigger" swings the camera (a
-- binary swap needs no priority resolution, unlike ContextPresets' bundles).
local AUTO_STATES = { "combat", "stealth", "mounted", "swimming", "sprint" }

-- Sprint sample cadence, matching ContextPresets / VelocityFov.
local POLL_MS = 150

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
-- All inert until Configure sets a non-off mode. baseShoulder is the captured
-- pre-swap value (nil when we are not overriding). activeSide is what we last
-- applied. recovered gates the first apply until load-time snapshot recovery has
-- run, so we never capture a dirty (still-swung) shoulder from a crashed session as
-- the new base.
local controller = {
    mode        = MODE_OFF,
    offset      = 0.00,
    autoSide    = SIDE_RIGHT,
    manualSide  = SIDE_RIGHT,
    triggers    = { combat = false, stealth = false, mounted = false, swimming = false, sprint = false },
    physical    = { combat = false, stealth = false, mounted = false, swimming = false, sprint = false },
    baseShoulder = nil,
    activeSide  = SIDE_CENTER,
    polling     = false,
    optionsOpen = false,
    recovered   = false,
}

local EVENT_NAMESPACE = "BAV_ShoulderControl"
local POLL_NAME       = "BAV_ShoulderControl_Sprint"

-- ---------------------------------------------------------------------------
-- Base capture / restore (persisted recovery)
-- ---------------------------------------------------------------------------

-- Mirror the in-memory base into persistent storage (owned by Settings) so a
-- session that ends while swung can hand the real shoulder back next load. Resolved
-- lazily so file load order cannot matter. Passing nil clears the persisted copy.
local function PersistBase(value)
    local settings = addon.Settings
    if settings and settings.SetShoulderBaseSnapshot then
        settings.SetShoulderBaseSnapshot(value)
    end
end

-- Capture the live shoulder as the neutral base (once) and persist it. No-op if a
-- base is already captured, so the base always reflects the player's own framing
-- from the first swing -- never a previously-applied OTS value.
local function CaptureBase()
    if controller.baseShoulder ~= nil then
        return
    end
    if not CameraSettings.IsSupported(SHOULDER_KEY) then
        return
    end
    local value, ok = CameraSettings.Get(SHOULDER_KEY)
    if ok and value ~= nil then
        controller.baseShoulder = value
        PersistBase(value)
        LogDebug("ShoulderControl.CaptureBase: base=%.2f", value)
    end
end

-- Write the captured base back and forget it everywhere (in-memory + persisted).
-- Safe when nothing is captured (still clears any stale persisted copy).
local function RestoreBase()
    if controller.baseShoulder ~= nil then
        CameraSettings.Set(SHOULDER_KEY, controller.baseShoulder)
        LogDebug("ShoulderControl.RestoreBase: restored=%.2f", controller.baseShoulder)
        controller.baseShoulder = nil
    end
    PersistBase(nil)
end

-- ---------------------------------------------------------------------------
-- Side resolution + application
-- ---------------------------------------------------------------------------

-- The shoulder value for a side: absolute +/- offset for left/right; the captured
-- base for center (handled separately by RestoreBase). offset is the OTS magnitude.
local function ShoulderValueForSide(side)
    if side == SIDE_RIGHT then
        return controller.offset
    elseif side == SIDE_LEFT then
        return -controller.offset
    end
    return nil  -- center has no absolute value; it restores the base
end

-- Apply a side to the camera. center restores (and clears) the base; left/right
-- capture the base once, then write the absolute OTS value. No-op if the side is
-- already active, so repeated evaluations do not re-write.
local function ApplySide(side)
    if side == controller.activeSide then
        return
    end

    if side == SIDE_CENTER then
        RestoreBase()
    else
        CaptureBase()
        local value = ShoulderValueForSide(side)
        if value ~= nil then
            CameraSettings.Set(SHOULDER_KEY, value)
        end
    end

    controller.activeSide = side
    LogDebug("ShoulderControl.ApplySide: %s", side)
end

-- Returns true if any enabled auto-trigger state is physically active.
local function AnyTriggerActive()
    for _, stateId in pairs(AUTO_STATES) do
        if controller.triggers[stateId] and controller.physical[stateId] then
            return true
        end
    end
    return false
end

-- Resolve the side that SHOULD be applied right now, given mode and state. Returns
-- center while options are open (the player may be editing shoulder), disabled, or
-- before load-time recovery has run.
local function ResolveSide()
    if controller.mode == MODE_OFF or controller.optionsOpen or not controller.recovered then
        return SIDE_CENTER
    end

    if controller.mode == MODE_MANUAL then
        return controller.manualSide
    end

    -- Auto: swing to the chosen side while any trigger is active, else center.
    if AnyTriggerActive() then
        return controller.autoSide
    end
    return SIDE_CENTER
end

-- Recompute the desired side and apply it.
local function Reevaluate()
    ApplySide(ResolveSide())
end

-- ---------------------------------------------------------------------------
-- Auto-mode state inputs (events + sprint polling)
-- ---------------------------------------------------------------------------

local function SetPhysical(stateId, active)
    active = active and true or false
    if controller.physical[stateId] == active then
        return
    end
    controller.physical[stateId] = active
    Reevaluate()
end

local function OnCombatState(_, inCombat)
    SetPhysical("combat", inCombat)
end

local function OnStealthState(_, unitTag, stealthState)
    if unitTag ~= "player" then
        return
    end
    local stealthed = (stealthState == STEALTH_STATE_HIDDEN)
        or (stealthState == STEALTH_STATE_HIDDEN_ALMOST_DETECTED)
    SetPhysical("stealth", stealthed)
end

local function OnMountedState(_, mounted)
    SetPhysical("mounted", mounted)
end

local function OnSwimmingState(_)
    SetPhysical("swimming", true)
end

local function OnNotSwimmingState(_)
    SetPhysical("swimming", false)
end

-- Sprint detection mirrors ContextPresets.IsPlayerSprinting / VelocityFov so all
-- three agree on what "sprinting" means.
local function IsPlayerSprinting()
    local lib = LibSprint
    if lib ~= nil and lib.isPlayerSprinting ~= nil then
        return lib.isPlayerSprinting and true or false
    end
    if IsGameCameraUIModeActive and IsGameCameraUIModeActive() then
        return false
    end
    return IsShiftKeyDown() and IsPlayerMoving()
end

local function PollSprint()
    SetPhysical("sprint", IsPlayerSprinting())
end

local function StartSprintPolling()
    if controller.polling then
        return
    end
    controller.polling = true
    EVENT_MANAGER:RegisterForUpdate(POLL_NAME, POLL_MS, PollSprint)
end

local function StopSprintPolling()
    if not controller.polling then
        return
    end
    controller.polling = false
    EVENT_MANAGER:UnregisterForUpdate(POLL_NAME)
    SetPhysical("sprint", false)
end

-- Sprint polling runs only in AUTO mode with sprint as an enabled trigger, so it is
-- off entirely for manual mode and for users who do not swing on sprint.
local function SyncSprintPolling()
    if controller.mode == MODE_AUTO and controller.triggers.sprint then
        StartSprintPolling()
    else
        StopSprintPolling()
    end
end

local function RegisterStateEvents()
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_COMBAT_STATE, OnCombatState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_STEALTH_STATE_CHANGED, OnStealthState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_MOUNTED_STATE_CHANGED, OnMountedState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_SWIMMING, OnSwimmingState)
    EVENT_MANAGER:RegisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_NOT_SWIMMING, OnNotSwimmingState)
end

local function UnregisterStateEvents()
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_COMBAT_STATE)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_STEALTH_STATE_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_MOUNTED_STATE_CHANGED)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_SWIMMING)
    EVENT_MANAGER:UnregisterForEvent(EVENT_NAMESPACE, EVENT_PLAYER_NOT_SWIMMING)
end

-- ---------------------------------------------------------------------------
-- Options-window coordination
-- ---------------------------------------------------------------------------
-- While the ESO settings window is open the player may edit the real shoulder
-- setting. Hand it back (restore base) and suspend evaluation, then re-apply on
-- close -- mirroring ContextPresets' options handling.
local OPTIONS_FRAGMENT = OPTIONS_WINDOW_FRAGMENT

local function OnOptionsOpened()
    if controller.mode == MODE_OFF or controller.optionsOpen then
        return
    end
    controller.optionsOpen = true
    -- ResolveSide returns center while optionsOpen, so this restores the base.
    Reevaluate()
end

local function OnOptionsClosed()
    if not controller.optionsOpen then
        return
    end
    controller.optionsOpen = false
    if controller.mode ~= MODE_OFF then
        -- The player may have edited their shoulder; the old base is stale. We are
        -- back at center (base restored on open), so a fresh swing re-captures the
        -- edited value as the new base on the next ApplySide.
        Reevaluate()
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
-- Mode transitions
-- ---------------------------------------------------------------------------
-- Set the active mode, wiring up exactly the machinery that mode needs:
--   off    -> tear everything down and restore the base.
--   manual -> options callback only (no state events, no poll).
--   auto   -> state events + options + sprint poll (when sprint is a trigger).
local function SetMode(newMode)
    if newMode ~= MODE_OFF and newMode ~= MODE_AUTO and newMode ~= MODE_MANUAL then
        newMode = MODE_OFF
    end

    local oldMode = controller.mode
    if newMode == oldMode then
        return
    end

    -- Tear down the old mode's wiring.
    if oldMode == MODE_AUTO then
        UnregisterStateEvents()
        StopSprintPolling()
    end
    if oldMode ~= MODE_OFF then
        UnregisterOptionsEvents()
    end

    -- Leaving an enabled mode entirely: hand the shoulder back to the player.
    if newMode == MODE_OFF then
        ApplySide(SIDE_CENTER)  -- restores + clears the base
        controller.physical = { combat = false, stealth = false, mounted = false, swimming = false, sprint = false }
        controller.mode = MODE_OFF
        return
    end

    controller.mode = newMode

    -- Set up the new mode's wiring.
    RegisterOptionsEvents()
    if newMode == MODE_AUTO then
        RegisterStateEvents()
        SyncSprintPolling()
    end

    -- Apply now (or defer until recovery has run at load -- ResolveSide returns
    -- center until controller.recovered is set).
    Reevaluate()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- True while ShoulderControl owns the shoulder property (any enabled mode), so
-- ContextPresets cedes it. Lazily consulted by ContextPresets.
function ShoulderControl.OwnsShoulder()
    return controller.mode ~= MODE_OFF
end

-- Apply configuration mirrored from SavedVariables:
--   mode        "off" | "auto" | "manual"
--   offset      number 0..1 (OTS magnitude)
--   autoSide    "left" | "right" (auto swing side)
--   manualSide  "left" | "right" | "center" (current manual side)
--   autoStates  { combat=bool, stealth=bool, mounted=bool, swimming=bool, sprint=bool }
-- Unspecified fields are left unchanged.
function ShoulderControl.Configure(options)
    options = options or {}

    if options.offset ~= nil then
        local o = tonumber(options.offset) or controller.offset
        if o < 0 then o = 0 elseif o > 1 then o = 1 end
        controller.offset = o
    end

    if options.autoSide == SIDE_LEFT or options.autoSide == SIDE_RIGHT then
        controller.autoSide = options.autoSide
    end

    if options.manualSide == SIDE_LEFT or options.manualSide == SIDE_RIGHT
        or options.manualSide == SIDE_CENTER then
        controller.manualSide = options.manualSide
    end

    if type(options.autoStates) == "table" then
        for _, stateId in pairs(AUTO_STATES) do
            local v = options.autoStates[stateId]
            if v ~= nil then
                controller.triggers[stateId] = v and true or false
            end
        end
    end

    if options.mode ~= nil then
        SetMode(options.mode)
    elseif controller.mode ~= MODE_OFF then
        -- Live reconfiguration (offset/side/trigger change) without a mode switch:
        -- keep the sprint poll in sync and re-apply so changes take effect now. To
        -- pick up a changed offset even when the active side is unchanged, force a
        -- re-write by dropping the cached active side first.
        SyncSprintPolling()
        controller.activeSide = nil
        Reevaluate()
    end

    LogDebug("ShoulderControl.Configure: mode=%s offset=%.2f", controller.mode, controller.offset)
end

-- Manual-mode entry point for the `/bav shoulder` command. Sets the manual side and
-- applies it. Ignored unless in manual mode (the caller checks the mode and prints a
-- notice). side: "left" | "right" | "center"; nil/"toggle" flips left<->right.
function ShoulderControl.SetManualSide(side)
    if controller.mode ~= MODE_MANUAL then
        return false
    end

    if side == nil or side == "toggle" then
        side = (controller.manualSide == SIDE_RIGHT) and SIDE_LEFT or SIDE_RIGHT
    elseif side ~= SIDE_LEFT and side ~= SIDE_RIGHT and side ~= SIDE_CENTER then
        return false
    end

    controller.manualSide = side
    -- Persist via Settings so the side survives a reload.
    local settings = addon.Settings
    if settings and settings.SetShoulderManualSide then
        settings.SetShoulderManualSide(side)
    end
    Reevaluate()
    return true, side
end

-- The current manual side, for the slash handler's feedback message.
function ShoulderControl.GetManualSide()
    return controller.manualSide
end

-- Emergency recovery: force the camera back to the player's shoulder, no matter the
-- mode. Restores + clears the base, stops the poll, resets runtime state. Does NOT
-- change saved settings -- normal evaluation resumes after. Returns true if it had
-- anything to undo.
function ShoulderControl.EmergencyRestore()
    local didSomething = controller.baseShoulder ~= nil

    StopSprintPolling()
    if controller.baseShoulder ~= nil then
        CameraSettings.Set(SHOULDER_KEY, controller.baseShoulder)
        controller.baseShoulder = nil
    end
    PersistBase(nil)
    controller.activeSide = SIDE_CENTER
    controller.physical = { combat = false, stealth = false, mounted = false, swimming = false, sprint = false }

    LogInfo("ShoulderControl.EmergencyRestore: shoulder handed back (changed=%s)",
        tostring(didSomething))

    -- Re-arm the poll if auto+sprint is still configured, so a genuinely-active
    -- state re-applies on the next event.
    if controller.mode ~= MODE_OFF then
        SyncSprintPolling()
        Reevaluate()
    end
    return didSomething
end

-- Load-time recovery (call ONCE per session from OnPlayerActivated, BEFORE the first
-- apply). If the previous session ended while swung, the engine shoulder still holds
-- the OTS value and Settings has the player's real base; write it straight back and
-- clear the persisted copy. Then mark recovered so subsequent applies are allowed.
-- Guarded once-per-session like ContextPresets so a later zone change cannot tear
-- down a swing that legitimately became active this session.
function ShoulderControl.RecoverPersistedSnapshot()
    if controller.recovered then
        return false
    end
    controller.recovered = true

    local settings = addon.Settings
    if settings and settings.GetShoulderBaseSnapshot then
        local base = settings.GetShoulderBaseSnapshot()
        if base ~= nil and CameraSettings.IsSupported(SHOULDER_KEY) then
            LogInfo("ShoulderControl.RecoverPersistedSnapshot: restoring shoulder left swung last session")
            CameraSettings.Set(SHOULDER_KEY, base)
        end
        PersistBase(nil)
        controller.baseShoulder = nil
    end
    return true
end

-- Re-apply the active swing after EVENT_PLAYER_ACTIVATED (a zone change resets the
-- camera; the physical trigger flags survive without re-firing their events, so the
-- swing must be re-asserted). Also serves as the first real apply after recovery.
-- No-op when disabled or already centered.
function ShoulderControl.ReassertActive()
    if controller.mode == MODE_OFF then
        return false
    end
    -- The engine reset shoulder across the load screen, so force a re-write even if
    -- our cached activeSide matches.
    controller.activeSide = nil
    Reevaluate()
    return true
end

-- Read-only snapshot of internal state, for SelfCheck invariants and dumps.
--   enabled         a non-off mode is active (owns shoulder)
--   mode            current mode id
--   owns            same as enabled (ContextPresets cedes shoulder when true)
--   hasBase         a pre-swing base is currently captured
--   activeSide      the side currently applied
--   sprintPolling   sprint poll timer is registered
--   optionsOpen     the ESO options window is open (swing reverted for editing)
function ShoulderControl.GetDiagnostics()
    return {
        enabled       = controller.mode ~= MODE_OFF,
        mode          = controller.mode,
        owns          = controller.mode ~= MODE_OFF,
        hasBase       = controller.baseShoulder ~= nil,
        activeSide    = controller.activeSide,
        sprintPolling = controller.polling,
        optionsOpen   = controller.optionsOpen,
    }
end