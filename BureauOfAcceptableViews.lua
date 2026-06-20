-- Addon namespace
local ADDON_NAME = "BureauOfAcceptableViews"
local SAVED_VARIABLES_NAME = "BureauOfAcceptableViews_SavedVariables"

BureauOfAcceptableViews = {
    name = ADDON_NAME,
    savedVariablesName = SAVED_VARIABLES_NAME,
    version = "1.7.20062010",
    debugMode = 1,  -- 0=off, 1=errors, 2=warnings, 3=info, 4=verbose
}

local private = {}
BureauOfAcceptableViews.private = private

-- Hot-path global caching
-- ---------------------------------------------------------------------------
-- In Lua, every reference to a global is a hash lookup in _G. Camera zoom
-- helpers run on every zoom/toggle input, so the ESO API and standard library
-- functions they touch are bound to locals (upvalues) once at load time. This
-- turns repeated global lookups into cheap upvalue reads without changing
-- behaviour. Keep this block above the first function definition so the
-- closures below capture these locals.
local GetSetting    = GetSetting
local SetSetting    = SetSetting
local GetString     = GetString
local d             = d
local pcall         = pcall
local tonumber      = tonumber
local select        = select
local type          = type
local stringformat  = string.format
local stringgmatch  = string.gmatch
local stringlower   = string.lower
local tableinsert   = table.insert
local mathmax       = math.max
local mathmin       = math.min
local GetFrameTimeMilliseconds = GetFrameTimeMilliseconds

-- Localization/chat helpers
local CHAT_PREFIX = "|c6FCB9F[Bureau Of Acceptable Views]|r: "
local CHAT_ERROR_PREFIX = "|cFF0000[Bureau Of Acceptable Views]|r: "

local DEBUG_LEVEL_STRING_IDS = {
    SI_BAV_DEBUG_LEVEL_OFF,
    SI_BAV_DEBUG_LEVEL_ERRORS,
    SI_BAV_DEBUG_LEVEL_WARNINGS,
    SI_BAV_DEBUG_LEVEL_INFO,
    SI_BAV_DEBUG_LEVEL_VERBOSE,
}

local SOURCE_STRING_IDS = {
    ToggleFPV = SI_BAV_SOURCE_TOGGLE_FPV,
    ZoomIn = SI_BAV_SOURCE_ZOOM_IN,
    ZoomOut = SI_BAV_SOURCE_ZOOM_OUT,
}

local function ResolveLocalizedText(message)
    if type(message) == "number" then
        return GetString(message)
    end

    return tostring(message)
end

local function FormatLocalizedText(message, ...)
    local localizedText = ResolveLocalizedText(message)
    if select("#", ...) > 0 then
        return stringformat(localizedText, ...)
    end
    return localizedText
end

local function GetLocalizedBoolean(value)
    return GetString(value and SI_BAV_BOOL_TRUE or SI_BAV_BOOL_FALSE)
end

local function GetDebugLevelName(level)
    level = mathmax(0, mathmin(4, tonumber(level) or 0))
    return GetString(DEBUG_LEVEL_STRING_IDS[level + 1] or DEBUG_LEVEL_STRING_IDS[1])
end

local function GetLocalizedSourceName(sourceName)
    local stringId = SOURCE_STRING_IDS[sourceName]
    if stringId then
        return GetString(stringId)
    end
    return tostring(sourceName)
end

local function ChatInfo(message, ...)
    d(CHAT_PREFIX .. FormatLocalizedText(message, ...))
end

local function ChatError(message, ...)
    d(CHAT_ERROR_PREFIX .. FormatLocalizedText(message, ...))
end

-- Debug logging system
-- ---------------------------------------------------------------------------
-- Log levels are defined once here. The numeric values double as the
-- debugMode thresholds (emit when debugMode >= level), so this enum is the
-- single source of truth for both the public debugMode contract and the
-- generated Log* helpers below.
local LOG_LEVEL = {
    ERROR = 1,
    WARN  = 2,
    INFO  = 3,
    DEBUG = 4,
}

-- String id per level. Kept as ids (not resolved strings) so GetString is
-- only ever called at log time -- this file stays independent of the
-- localization load order.
local LOG_LEVEL_STRING_IDS = {
    [LOG_LEVEL.ERROR] = SI_BAV_LOG_LEVEL_ERROR,
    [LOG_LEVEL.WARN]  = SI_BAV_LOG_LEVEL_WARN,
    [LOG_LEVEL.INFO]  = SI_BAV_LOG_LEVEL_INFO,
    [LOG_LEVEL.DEBUG] = SI_BAV_LOG_LEVEL_DEBUG,
}

local function Log(level, message, ...)
    if BureauOfAcceptableViews.debugMode < level then
        return
    end

    local stringId = LOG_LEVEL_STRING_IDS[level]
    local prefix = stringId and (GetString(stringId) .. " ") or ""
    d(CHAT_PREFIX .. prefix .. FormatLocalizedText(message, ...))
end

-- Level-specific helpers (LogError/LogWarn/LogInfo/LogDebug) are generated
-- from LOG_LEVEL so adding a level needs no extra boilerplate. They are
-- forward-declared as locals first, so closures defined later in the file
-- capture them as upvalues and tooling still resolves each name.
local LogError, LogWarn, LogInfo, LogDebug
do
    local generated = {}
    for name, level in pairs(LOG_LEVEL) do
        generated[name] = function(...) Log(level, ...) end
    end
    LogError = generated.ERROR
    LogWarn  = generated.WARN
    LogInfo  = generated.INFO
    LogDebug = generated.DEBUG
end

-- Default constants (user-configurable values are stored in SavedVariables)
local ZOOM_MAX                     = 10.0  -- Maximum zoom distance
local ZOOM_MIN_MOUNTED             = 2.0   -- Default fallback zoom when mounted/werewolf/swimming
local LASTZOOM_THRESHOLD           = 2.0   -- Default minimum zoom value to save as lastZoom
local ZOOM_FPV                     = 0.0   -- First person view zoom
local ZOOM_STEP                    = 0.3   -- Default zoom step size
local PRESERVE_FPV_BETWEEN_ZONES   = true  -- Default behavior: keep FPV across relogs and zone changes
local ZOOM_STEP_MIN                = 0.05  -- Minimum configurable zoom step
local ZOOM_STEP_MAX                = 2.25   -- Maximum configurable zoom step
local CONFIG_MIN_THIRD_PERSON_ZOOM = 0.10  -- Lowest sensible configurable third-person fallback zoom

private.constants = {
    ZOOM_MAX = ZOOM_MAX,
    ZOOM_MIN_MOUNTED = ZOOM_MIN_MOUNTED,
    LASTZOOM_THRESHOLD = LASTZOOM_THRESHOLD,
    ZOOM_FPV = ZOOM_FPV,
    ZOOM_STEP = ZOOM_STEP,
    PRESERVE_FPV_BETWEEN_ZONES = PRESERVE_FPV_BETWEEN_ZONES,
    ZOOM_STEP_MIN = ZOOM_STEP_MIN,
    ZOOM_STEP_MAX = ZOOM_STEP_MAX,
    CONFIG_MIN_THIRD_PERSON_ZOOM = CONFIG_MIN_THIRD_PERSON_ZOOM,
}

-- These defaults are a shared contract consumed by Settings.lua and must not
-- drift at runtime. A __newindex guard turns any accidental write into a clear
-- error instead of a silent, hard-to-trace state change. Field reads and
-- pairs() iteration are unaffected, since the values live directly in the table.
setmetatable(private.constants, {
    __newindex = function(_, key, _value)
        error(stringformat("BAV: attempt to modify read-only constant '%s'", tostring(key)), 2)
    end,
})

-- Local variables
local savedVars = {}
local lastZoom = ZOOM_MIN_MOUNTED -- Default to minimum zoom, not 0
local saveQueued = false
local SAVE_DELAY_MS = 1000
local SAVE_TIMER_NAME = ADDON_NAME .. "_QueuedSave"


-- Re-entrancy + programmatic-pair protection for the FPV toggle.
-- ---------------------------------------------------------------------------
-- isTogglingFPV guards true re-entrancy (our own SetCameraZoom re-entering the
-- hook synchronously). The frame-pair fields below handle a DIFFERENT case: an
-- addon (e.g. PvpAlerts) that calls ToggleGameCameraFirstPerson() twice in the
-- SAME rendered frame to measure the camera, expecting the pair to net to no
-- visible change. A human can physically toggle at most once per frame, so a
-- second toggle within one frame is always programmatic; we use that invariant
-- (not any addon-specific check) to keep such pairs balanced for ANY caller.
local isTogglingFPV = false          -- Flag to prevent re-entrant calls
local lastToggleFrameMs = nil        -- frame time of the toggle we last processed
local lastToggleBlocked = false      -- did we handle (block the engine on) it?
local lastTogglePrevZoom = nil       -- zoom before our change, for same-frame undo

-- Runaway-oscillation detector + reversible backoff.
-- ---------------------------------------------------------------------------
-- A safety net for FUTURE, unknown addon conflicts (the PvpAlerts case is
-- already fixed by the same-frame pairing above). If something drives the view
-- to flip first-person<->third-person at a rate no human could produce, we stop
-- OUR hook from participating: it goes passive (pass every call straight to the
-- engine = vanilla behavior), breaking our side of the loop. This is purely a
-- session-local runtime flag -- it touches no SavedVariables and is undone by a
-- relog or `/bav reset`. We deliberately do NOT name or blame any addon (a
-- ZO_PreHook cannot know its caller) and we only count REAL view flips we
-- observe through our own hook -- never a timer/poll, honoring the addon's
-- event-driven contract.
local OSCILLATION_WINDOW_MS       = 3000  -- sliding window for counting view flips
local OSCILLATION_FLIP_THRESHOLD  = 8     -- flips within the window that trip backoff

local viewFlipTimestamps = {}    -- sliding window of observed real-flip times (ms)
local lastObservedFpv    = nil   -- last observed FPV-ness, to detect a real flip
local togglePassive      = false -- backoff: when true, our FPV hook is a no-op
local oscillationWarned  = false -- session throttle for the advisory message

-- Helper function to check if zoom value is valid
local function IsValidZoom(zoom)
    return type(zoom) == "number" and zoom >= ZOOM_FPV and zoom <= ZOOM_MAX
end

-- Helper function to check if zoom value is a valid third-person distance
local function IsValidThirdPersonZoom(zoom)
    return IsValidZoom(zoom) and zoom > ZOOM_FPV
end

-- Camera setting API coupling
-- ---------------------------------------------------------------------------
-- The raw camera distance I/O (the string-based GetSetting/SetSetting contract
-- on SETTING_TYPE_CAMERA / CAMERA_SETTING_DISTANCE) now lives in the shared
-- CameraSettings layer. What remains here is zoom-precision rounding: the
-- camera distance setting carries two decimals, and several call sites compare
-- and persist zoom values, so we round consistently to that precision via
-- EncodeCameraZoom / NormalizeZoomValue.
local CAMERA_ZOOM_DECIMALS  = 2                                      -- Precision used by the camera distance setting
local CAMERA_ZOOM_FORMAT    = "%." .. CAMERA_ZOOM_DECIMALS .. "f"    -- Format string used to round zoom to that precision

-- Round a numeric zoom to the camera distance precision, as a string.
-- Returns nil when the value is not numeric.
local function EncodeCameraZoom(zoom)
    zoom = tonumber(zoom)
    if not zoom then
        return nil
    end

    return stringformat(CAMERA_ZOOM_FORMAT, zoom)
end

-- Helper to round zoom-like values to the precision used by the camera setting
local function NormalizeZoomValue(zoom)
    local encodedZoom = EncodeCameraZoom(zoom)
    if not encodedZoom then
        return nil
    end

    return tonumber(encodedZoom)
end

-- Helper to normalize a zoom-like value to a guaranteed number using a fallback
local function NormalizeZoomNumber(zoom, fallback)
    local normalizedZoom = NormalizeZoomValue(zoom)
    if normalizedZoom == nil then
        return fallback
    end

    return normalizedZoom
end

-- Helper to clamp numeric configuration values
local function ClampNumber(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function GetSettingsModule()
    return BureauOfAcceptableViews.Settings
end

local function GetConfiguredZoomStep()
    return GetSettingsModule().GetConfiguredZoomStep()
end

local function GetConfiguredLastZoomThreshold()
    return GetSettingsModule().GetConfiguredLastZoomThreshold()
end

local function GetConfiguredMinMountedZoom()
    return GetSettingsModule().GetConfiguredMinMountedZoom()
end

local function ShouldPersistFPVBetweenZones()
    return GetSettingsModule().ShouldPersistFPVBetweenZones()
end

-- Read the raw camera zoom from the settings API and decode it to a number.
-- Returns the decoded zoom and a success flag; the value is nil on failure.
local function ReadCameraZoomSetting()
    -- Engine I/O is delegated to the shared CameraSettings layer, which owns the
    -- string-based GetSetting contract. We keep the zoom-specific normalization
    -- so callers continue to receive values rounded to the zoom precision.
    local rawZoom, success = BureauOfAcceptableViews.CameraSettings.Get("distance")
    if not success then
        return nil, false
    end

    local zoom = NormalizeZoomValue(rawZoom)
    if zoom == nil then
        return nil, false
    end

    return zoom, true
end

-- Helper function to get current zoom with nil protection and error handling
-- Returns zoom and whether the value was read successfully
local function GetCameraZoom()
    local zoom, success = ReadCameraZoomSetting()
    if success and zoom and zoom >= 0 then
        return zoom, true
    end
    return GetConfiguredMinMountedZoom(), false
end

-- Helper to resolve which current zoom should be persisted across relogs and zones
local function GetPersistedCurrentZoom(currentZoom)
    currentZoom = NormalizeZoomNumber(currentZoom, GetConfiguredMinMountedZoom())

    if currentZoom > ZOOM_FPV or ShouldPersistFPVBetweenZones() then
        return currentZoom
    end

    if IsValidThirdPersonZoom(lastZoom) then
        return NormalizeZoomValue(lastZoom)
    end

    local savedLastThirdPersonZoom = NormalizeZoomValue(savedVars.lastThirdPersonZoom)
    if IsValidThirdPersonZoom(savedLastThirdPersonZoom) then
        return savedLastThirdPersonZoom
    end

    return GetConfiguredMinMountedZoom()
end

-- Helper to normalize persisted current zoom against the active persistence policy
local function NormalizeSavedCurrentZoom()
    local normalizedCurrentZoom = NormalizeZoomValue(savedVars.currentZoom)
    local savedLastThirdPersonZoom = NormalizeZoomValue(savedVars.lastThirdPersonZoom)

    if IsValidThirdPersonZoom(savedLastThirdPersonZoom) then
        savedVars.lastThirdPersonZoom = savedLastThirdPersonZoom
    elseif IsValidThirdPersonZoom(lastZoom) then
        savedVars.lastThirdPersonZoom = NormalizeZoomValue(lastZoom)
    else
        savedVars.lastThirdPersonZoom = GetConfiguredMinMountedZoom()
    end

    if IsValidZoom(normalizedCurrentZoom) then
        savedVars.currentZoom = GetPersistedCurrentZoom(normalizedCurrentZoom)
    elseif IsValidThirdPersonZoom(savedVars.lastThirdPersonZoom) then
        savedVars.currentZoom = savedVars.lastThirdPersonZoom
    else
        savedVars.currentZoom = GetConfiguredMinMountedZoom()
    end
end

-- Helper function to save camera state to SavedVariables
-- Persists both the active zoom and the last valid third-person zoom
local function SaveCameraState(currentZoom)
    if currentZoom == nil then
        currentZoom = GetCameraZoom()
    end
    currentZoom = NormalizeZoomNumber(currentZoom, GetConfiguredMinMountedZoom())
    if not IsValidZoom(currentZoom) then
        currentZoom = GetConfiguredMinMountedZoom()
    end

    local storedCurrentZoom = GetPersistedCurrentZoom(currentZoom)
    local storedLastZoom = NormalizeZoomNumber(lastZoom, GetConfiguredMinMountedZoom())

    if savedVars.currentZoom ~= storedCurrentZoom then
        savedVars.currentZoom = storedCurrentZoom
    end

    if IsValidThirdPersonZoom(storedLastZoom) and savedVars.lastThirdPersonZoom ~= storedLastZoom then
        savedVars.lastThirdPersonZoom = storedLastZoom
    end
end

-- Throttled save to prevent excessive disk writes
-- Saves at most once per second, and only on the final camera state
local function QueueSave()
    if not saveQueued then
        saveQueued = true
        EVENT_MANAGER:RegisterForUpdate(SAVE_TIMER_NAME, SAVE_DELAY_MS, function()
            EVENT_MANAGER:UnregisterForUpdate(SAVE_TIMER_NAME)
            SaveCameraState()
            saveQueued = false
        end)
    end
end

-- Save immediately on player deactivation (logout/zone change)
local function SaveImmediately()
    if saveQueued then
        EVENT_MANAGER:UnregisterForUpdate(SAVE_TIMER_NAME)
        saveQueued = false
    end
    SaveCameraState()
end

-- Helper function to set camera zoom using the shared CameraSettings layer.
-- Zoom-specific validation stays here; the encode/SetSetting/verify contract is
-- owned by CameraSettings.Set (which verifies the applied value within epsilon).
local function SetCameraZoom(zoom)
    zoom = NormalizeZoomValue(zoom)
    if not IsValidZoom(zoom) then
        LogWarn(SI_BAV_LOG_INVALID_ZOOM, tostring(zoom))
        return false
    end

    -- The write-verify tolerance is owned by CameraSettings (its default
    -- VERIFY_EPSILON); we no longer keep a second copy of that 0.05 here. Omit
    -- the epsilon argument so there is a single source of truth for it.
    local applied = BureauOfAcceptableViews.CameraSettings.Set("distance", zoom)
    if not applied then
        LogWarn(SI_BAV_LOG_SET_APPLY_FAILED, zoom)
        return false
    end

    -- Keep zoom-dependent FOV in sync. This is the single verified zoom-write
    -- point, so it is the natural place to re-evaluate dynamic FOV. Route through
    -- the FOV arbiter rather than calling DynamicFov directly: while a preset
    -- holds FOV, the arbiter suppresses this dynamic write so the pinned FOV is
    -- not stomped on the next zoom change. With no hold (and DynamicFov off by
    -- default) this is a no-op, so default behaviour (FOV untouched) is preserved.
    if BureauOfAcceptableViews.FovArbiter then
        BureauOfAcceptableViews.FovArbiter.RequestDynamic(zoom)
    elseif BureauOfAcceptableViews.DynamicFov then
        BureauOfAcceptableViews.DynamicFov.Apply(zoom)
    end

    LogDebug(SI_BAV_LOG_SET_APPLIED, zoom)
    return true
end

-- Check if player is in a state where zoom is normally limited
local function IsZoomLimited()
    return IsMounted() or IsWerewolf() or IsUnitSwimming("player")
end

-- Emit the conflict advisory once per session. Reads the user toggle lazily (no
-- push needed): when the advisory is off we stay silent in chat but still log at
-- warn level, so /bav selfcheck can surface the backoff either way.
local function RaiseOscillationAdvisory()
    local settings = BureauOfAcceptableViews.Settings
    local advisoryOn = not (settings and settings.IsConflictAdvisoryEnabled)
        or settings.IsConflictAdvisoryEnabled()

    if advisoryOn and not oscillationWarned then
        ChatInfo(SI_BAV_MSG_CONFLICT_ADVISORY)
        oscillationWarned = true
    end
    LogWarn(SI_BAV_LOG_OSCILLATION_BACKOFF)
end

-- Record a REAL view flip (FPV<->third person) observed through our own hook and
-- trip the reversible backoff if flips exceed the threshold within the sliding
-- window. Counts only genuine state changes -- never raw hook calls -- so the
-- balanced same-frame measurement pairs other addons make do not register. No
-- timer/poll: this runs only when the engine already called the toggle.
local function NoteViewStateAndCheckOscillation(nowMs)
    local isFpv = GetCameraZoom() <= ZOOM_FPV
    if lastObservedFpv == nil then
        lastObservedFpv = isFpv
        return
    end
    if isFpv == lastObservedFpv then
        return  -- no actual flip; nothing to record
    end
    lastObservedFpv = isFpv

    -- Append this flip, then drop any timestamps that fell out of the window.
    viewFlipTimestamps[#viewFlipTimestamps + 1] = nowMs
    local cutoff = nowMs - OSCILLATION_WINDOW_MS
    local kept = {}
    for i = 1, #viewFlipTimestamps do
        if viewFlipTimestamps[i] >= cutoff then
            kept[#kept + 1] = viewFlipTimestamps[i]
        end
    end
    viewFlipTimestamps = kept

    if not togglePassive and #viewFlipTimestamps >= OSCILLATION_FLIP_THRESHOLD then
        togglePassive = true
        RaiseOscillationAdvisory()
    end
end

-- Pre-hook for ToggleGameCameraFirstPerson
-- Returns true to block original function, false/nil to allow it
local function PreHookToggleGameCameraFirstPerson()
    local sourceName = GetLocalizedSourceName("ToggleFPV")
    LogDebug(SI_BAV_LOG_SOURCE_CALLED, sourceName)

    -- Backoff: once runaway oscillation has been detected this session, our hook
    -- stays out of the way entirely (vanilla pass-through) until /bav reset or a
    -- relog clears it. Checked first so we add zero behavior while backed off.
    if togglePassive then
        return false
    end

    -- True re-entrancy: our own SetCameraZoom must never recurse into this hook.
    -- Pass through (don't block) so we never break a caller's toggle.
    if isTogglingFPV then
        LogDebug(SI_BAV_LOG_TOGGLE_BLOCKED_REENTRANT)
        return false
    end

    -- Same-frame programmatic pair handling.
    -- ---------------------------------------------------------------------------
    -- A second toggle within the SAME rendered frame can only be programmatic (a
    -- human toggles at most once per frame). An addon like PvpAlerts toggles FPV
    -- and immediately back in one frame to measure the camera, expecting the pair
    -- to net to zero. We must not leave the camera desynced after such a pair:
    --   * If we PASSED the first toggle to the engine (normal third person), pass
    --     the second too -- the engine's own pair balances.
    --   * If we HANDLED the first (limited state / FPV: we changed zoom and blocked
    --     the engine), the engine never moved, so the partner toggle would now
    --     desync the view. Undo our zoom change, block the engine again, and the
    --     frame ends exactly where it started.
    local frameMs = GetFrameTimeMilliseconds()
    if lastToggleFrameMs == frameMs then
        if lastToggleBlocked and lastTogglePrevZoom ~= nil then
            LogDebug(SI_BAV_LOG_TOGGLE_PAIR_UNDO)
            SetCameraZoom(lastTogglePrevZoom)
            -- Consume the undo so a (pathological) third same-frame toggle is
            -- treated as a fresh first toggle rather than undoing again.
            lastToggleBlocked = false
            lastTogglePrevZoom = nil
            return true  -- keep the engine out; our undo restored the start state
        end
        LogDebug(SI_BAV_LOG_TOGGLE_PAIR_PASS)
        return false  -- first toggle was passed through; let the engine balance
    end

    -- Genuine (non-paired) toggle for this frame: fold it into the runaway
    -- detector. This may trip backoff; if so, go passive immediately and pass
    -- this call straight through to the engine.
    NoteViewStateAndCheckOscillation(GetGameTimeMilliseconds())
    if togglePassive then
        return false
    end

    -- Don't interfere with siege weapons - let original function handle it
    if IsGameCameraSiegeControlled() then
        LogInfo(SI_BAV_LOG_TOGGLE_SIEGE_PASS)
        return false  -- Allow original function to execute
    end
    
    -- Set re-entrancy flag and remember the zoom BEFORE we touch anything, so a
    -- same-frame partner toggle can undo our change exactly.
    isTogglingFPV = true
    local prevZoom = GetCameraZoom()

    local function HandleToggle()
        local zoom = GetCameraZoom()
        local isLimited = IsZoomLimited()
        local handled = false

        LogDebug(SI_BAV_LOG_TOGGLE_STATE,
            zoom, GetLocalizedBoolean(isLimited), lastZoom)

        if isLimited or zoom <= ZOOM_FPV then
            local setSucceeded = false

            if zoom <= ZOOM_FPV then
                -- Switching from FPV to third person
                local targetZoom = (IsValidZoom(lastZoom) and lastZoom > ZOOM_FPV) and lastZoom or GetConfiguredMinMountedZoom()
                LogInfo(SI_BAV_LOG_TOGGLE_TO_THIRD, targetZoom)
                setSucceeded = SetCameraZoom(targetZoom)
            else
                -- Switching to FPV
                if zoom > GetConfiguredLastZoomThreshold() then
                    lastZoom = zoom
                    LogDebug(SI_BAV_LOG_SOURCE_UPDATED_LASTZOOM, sourceName, lastZoom)
                end
                LogInfo(SI_BAV_LOG_TOGGLE_TO_FPV, zoom)
                setSucceeded = SetCameraZoom(ZOOM_FPV)
            end

            if setSucceeded then
                QueueSave()
                handled = true
            else
                LogWarn(SI_BAV_LOG_SOURCE_SET_FAILED, sourceName)
            end
        end

        if handled then
            LogDebug(SI_BAV_LOG_TOGGLE_HANDLED)
            return true  -- Block original function - we handled it
        end

        LogDebug(SI_BAV_LOG_TOGGLE_PASSING)
        return false  -- Zoom is not limited, allow original function to execute
    end

    local ok, result = pcall(HandleToggle)
    isTogglingFPV = false

    if not ok then
        LogError(SI_BAV_LOG_TOGGLE_UNHANDLED_ERROR, tostring(result))
        -- Record this frame so a same-frame partner toggle is recognized, but mark
        -- it as not-blocked: an errored handler did not reliably change zoom, so
        -- there is nothing to undo and we let the engine handle the partner.
        lastToggleFrameMs = frameMs
        lastToggleBlocked = false
        lastTogglePrevZoom = nil
        return false
    end

    -- Remember what this toggle did so a second toggle in the SAME frame can keep
    -- the pair balanced: if we blocked the engine (result == true) we stash the
    -- pre-change zoom so the partner can undo it; if we passed through, the partner
    -- passes through too.
    lastToggleFrameMs = frameMs
    lastToggleBlocked = result and true or false
    lastTogglePrevZoom = result and prevZoom or nil

    return result
end

-- Shared handler for zooming in (reducing camera distance)
local function HandleZoomIn(sourceName)
    local localizedSourceName = GetLocalizedSourceName(sourceName)
    LogDebug(SI_BAV_LOG_SOURCE_CALLED, localizedSourceName)
    
    -- Don't interfere with siege weapons
    if IsGameCameraSiegeControlled() then
        LogInfo(SI_BAV_LOG_SOURCE_SIEGE_PASS, localizedSourceName)
        return false  -- Allow original function to execute
    end
    
    local zoom = GetCameraZoom()
    
    -- Already at FPV minimum - block original function to prevent game's default behavior
    if zoom <= ZOOM_FPV then
        LogDebug(SI_BAV_LOG_SOURCE_ALREADY_AT_FPV, localizedSourceName, zoom)
        return true  -- Block original function - stay at FPV
    end
    
    local zoomStep = GetConfiguredZoomStep()
    local lastZoomThreshold = GetConfiguredLastZoomThreshold()
    local newZoom = NormalizeZoomNumber(mathmax(ZOOM_FPV, zoom - zoomStep), ZOOM_FPV)
    
    LogInfo(SI_BAV_LOG_SOURCE_TRANSITION, localizedSourceName, zoom, newZoom)
    if not SetCameraZoom(newZoom) then
        LogWarn(SI_BAV_LOG_SOURCE_SET_FAILED, localizedSourceName)
        return false  -- Let the original function handle the input if our set failed
    end
    
    -- Remember zoom for FPV toggle only if it's a "normal" zoom (> configured threshold)
    if newZoom > lastZoomThreshold then
        lastZoom = newZoom
        LogDebug(SI_BAV_LOG_SOURCE_UPDATED_LASTZOOM, localizedSourceName, lastZoom)
    elseif newZoom <= lastZoomThreshold and lastZoom > lastZoomThreshold then
        LogDebug(SI_BAV_LOG_SOURCE_PRESERVING_LASTZOOM, localizedSourceName, lastZoom)
    end
    QueueSave()
    return true  -- Block original function only after verified addon handling
end

-- Shared handler for zooming out (increasing camera distance)
local function HandleZoomOut(sourceName)
    local localizedSourceName = GetLocalizedSourceName(sourceName)
    LogDebug(SI_BAV_LOG_SOURCE_CALLED, localizedSourceName)
    
    -- Don't interfere with siege weapons
    if IsGameCameraSiegeControlled() then
        LogInfo(SI_BAV_LOG_SOURCE_SIEGE_PASS, localizedSourceName)
        return false  -- Allow original function to execute
    end
    
    local zoom = GetCameraZoom()
    
    -- Already at maximum - block original function to prevent game's default behavior
    if zoom >= ZOOM_MAX then
        LogDebug(SI_BAV_LOG_SOURCE_ALREADY_AT_MAX, localizedSourceName, zoom)
        return true  -- Block original function - stay at max
    end
    
    local zoomStep = GetConfiguredZoomStep()
    local lastZoomThreshold = GetConfiguredLastZoomThreshold()
    local newZoom = NormalizeZoomNumber(mathmin(ZOOM_MAX, zoom + zoomStep), ZOOM_MAX)
    
    LogInfo(SI_BAV_LOG_SOURCE_TRANSITION, localizedSourceName, zoom, newZoom)
    if not SetCameraZoom(newZoom) then
        LogWarn(SI_BAV_LOG_SOURCE_SET_FAILED, localizedSourceName)
        return false  -- Let the original function handle the input if our set failed
    end
    
    -- Remember zoom for FPV toggle only if it's a "normal" zoom (> configured threshold)
    if newZoom > lastZoomThreshold then
        lastZoom = newZoom
        LogDebug(SI_BAV_LOG_SOURCE_UPDATED_LASTZOOM, localizedSourceName, lastZoom)
    end
    QueueSave()
    return true  -- Block original function only after verified addon handling
end

-- Pre-hook for CameraZoomIn
-- Returns true to block original function, false/nil to allow it
local function PreHookCameraZoomIn()
    return HandleZoomIn("ZoomIn")
end

-- Pre-hook for CameraZoomOut
-- Returns true to block original function, false/nil to allow it
local function PreHookCameraZoomOut()
    return HandleZoomOut("ZoomOut")
end

-- Helper to resolve the best persisted current zoom for reapplication in the world
local function GetRestoredCurrentZoom()
    if IsValidZoom(savedVars.currentZoom) then
        return savedVars.currentZoom
    end

    if IsValidThirdPersonZoom(savedVars.lastThirdPersonZoom) then
        LogWarn(SI_BAV_LOG_INVALID_SAVED_CURRENT_FALLBACK,
            tostring(savedVars.currentZoom))
        return savedVars.lastThirdPersonZoom
    end

    return nil
end

-- Helper to initialize the preferred third-person zoom from persisted state
local function InitializeLastZoom(currentZoom)
    if IsValidThirdPersonZoom(savedVars.lastThirdPersonZoom) then
        lastZoom = NormalizeZoomNumber(savedVars.lastThirdPersonZoom, GetConfiguredMinMountedZoom())
        LogDebug(SI_BAV_LOG_INITIALIZE_LAST_FROM_SAVED_TP, lastZoom)
    elseif IsValidThirdPersonZoom(currentZoom) then
        lastZoom = NormalizeZoomNumber(currentZoom, GetConfiguredMinMountedZoom())
        LogDebug(SI_BAV_LOG_INITIALIZE_LAST_FROM_CURRENT, lastZoom)
    elseif IsValidThirdPersonZoom(savedVars.currentZoom) then
        lastZoom = NormalizeZoomNumber(savedVars.currentZoom, GetConfiguredMinMountedZoom())
        LogDebug(SI_BAV_LOG_INITIALIZE_LAST_FROM_SAVED_CURRENT, lastZoom)
    else
        lastZoom = GetConfiguredMinMountedZoom()
        LogDebug(SI_BAV_LOG_INITIALIZE_LAST_DEFAULT, lastZoom)
    end
end

-- Event handler for EVENT_PLAYER_ACTIVATED
-- Reapplies the saved camera state after login and zone changes
local function OnPlayerActivated(event)
    LogDebug(SI_BAV_LOG_ONPLAYERACTIVATED_REAPPLY)

    -- Recover a camera that a context preset was overriding when the previous
    -- session ended (reloadui/logout/crash mid-preset). Runs once per session,
    -- before the preset controller can capture anything, and before the zoom
    -- restore below so the player's saved zoom has the final say on distance
    -- while FOV/shoulder/vertical come back from the recovered snapshot. No-op
    -- in the normal case (nothing persisted) and when the module is absent.
    local presets = BureauOfAcceptableViews.ContextPresets
    if presets and presets.RecoverPersistedSnapshot then
        presets.RecoverPersistedSnapshot()
    end

    -- Same recovery for the shoulder swap: if the previous session ended while the
    -- camera was swung over a shoulder, the engine still holds the swung value and
    -- Settings has the player's real base. Recover it once per session, before the
    -- module is allowed to capture anything as its new base.
    local shoulder = BureauOfAcceptableViews.ShoulderControl
    if shoulder and shoulder.RecoverPersistedSnapshot then
        shoulder.RecoverPersistedSnapshot()
    end

    local targetZoom = GetRestoredCurrentZoom()
    if targetZoom then
        LogInfo(SI_BAV_LOG_APPLYING_SAVED_STATE,
            targetZoom, lastZoom)
        if not SetCameraZoom(targetZoom) then
            LogWarn(SI_BAV_LOG_FAILED_APPLY_SAVED_STATE, targetZoom)
        end
    else
        LogWarn(SI_BAV_LOG_INVALID_SAVED_STATE,
            tostring(savedVars.currentZoom), tostring(savedVars.lastThirdPersonZoom))
    end

    -- EVENT_PLAYER_ACTIVATED also fires on every zone change, and the engine
    -- resets the camera across the load screen. The physical state flags survive
    -- a zone change without re-firing their events, so a preset that was active
    -- before the load (e.g. combat) never re-runs on its own and the zoom restore
    -- above would leave its framing stomped. Hand distance/FOV/offsets back to the
    -- active preset so its framing survives the zone change. No-op when presets
    -- are off or idle at the default state, so default behaviour is unchanged.
    if presets and presets.ReassertActive then
        presets.ReassertActive()
    end

    -- The engine also reset the shoulder offset across the load screen, and the
    -- shoulder swap's trigger flags survive a zone change without re-firing their
    -- events, so re-assert the active swing here too. No-op when shoulder swap is
    -- off or already centered.
    if shoulder and shoulder.ReassertActive then
        shoulder.ReassertActive()
    end

    -- Passive reliability pass at a naturally-quiet moment (post-load screen,
    -- camera already settled). Warn-only: silent unless an invariant is broken
    -- or our owned-table footprint grew. RunAuto self-skips while in combat, so
    -- this never adds work to a busy moment. No-op when the module is absent.
    local selfCheck = BureauOfAcceptableViews.SelfCheck
    if selfCheck and selfCheck.RunAuto then
        selfCheck.RunAuto()
    end
end

-- Event handler for EVENT_PLAYER_DEACTIVATED (logout/zone change)
local function OnPlayerDeactivated(event)
    LogDebug(SI_BAV_LOG_ONPLAYERDEACTIVATED_SAVING)
    -- Save immediately when player logs out or changes zone
    SaveImmediately()
end

-- Event handler for EVENT_ADD_ON_LOADED
local function OnAddonLoaded(event, addonName)
    if addonName ~= BureauOfAcceptableViews.name then
        return
    end

    EVENT_MANAGER:UnregisterForEvent(BureauOfAcceptableViews.name, EVENT_ADD_ON_LOADED)
    LogInfo(SI_BAV_LOG_ONADDONLOADED_LOADING, BureauOfAcceptableViews.version)
    
    -- Initialize the settings module and SavedVariables
    savedVars = GetSettingsModule().InitializeSavedVariables()
    private.savedVars = savedVars

    -- Initialize lastZoom from persisted third-person preference or current setting
    local currentZoom = GetCameraZoom()
    LogDebug(SI_BAV_LOG_CURRENT_GAME_ZOOM, currentZoom)
    InitializeLastZoom(currentZoom)
    NormalizeSavedCurrentZoom()

    LogDebug(SI_BAV_LOG_SAVEDVARS_INITIALIZED,
        savedVars.currentZoom or 0, savedVars.lastThirdPersonZoom or 0)
    LogDebug(SI_BAV_LOG_CONFIG_INITIALIZED,
        GetConfiguredZoomStep(), GetConfiguredLastZoomThreshold(), GetConfiguredMinMountedZoom(),
        GetLocalizedBoolean(ShouldPersistFPVBetweenZones()))
    
    -- Register pre-hooks for camera functions
    ZO_PreHook("ToggleGameCameraFirstPerson", PreHookToggleGameCameraFirstPerson)
    ZO_PreHook("CameraZoomIn", PreHookCameraZoomIn)
    ZO_PreHook("CameraZoomOut", PreHookCameraZoomOut)

    -- NOTE:
    -- GameCameraGamepadZoomDown/GameCameraGamepadZoomUp are private in the current client build.
    -- Accessing those symbols directly from insecure addon code taints the callstack and throws.
    -- Keep the controller fallback logic and diagnostics, but do not touch the private functions here.
    LogInfo(SI_BAV_LOG_GAMEPAD_DOWN_UNAVAILABLE)
    LogInfo(SI_BAV_LOG_GAMEPAD_UP_UNAVAILABLE)

    LogInfo(SI_BAV_LOG_HOOKS_REGISTERED)
    
    -- Register world reapplication and save events
    EVENT_MANAGER:RegisterForEvent(BureauOfAcceptableViews.name, EVENT_PLAYER_ACTIVATED, OnPlayerActivated)
    EVENT_MANAGER:RegisterForEvent(BureauOfAcceptableViews.name, EVENT_PLAYER_DEACTIVATED, OnPlayerDeactivated)

    BureauOfAcceptableViews.RegisterSettingsPanel()

    -- Push saved optional-feature config (Dynamic FOV + Context Presets) into the
    -- modules now that SavedVariables and the modules themselves are available.
    -- Safe if a module is missing: ApplyOptionalFeatureConfig guards each one.
    GetSettingsModule().ApplyOptionalFeatureConfig()

    LogInfo(SI_BAV_LOG_ADDON_LOADED)
end

-- Register add-on load event
EVENT_MANAGER:RegisterForEvent(BureauOfAcceptableViews.name, EVENT_ADD_ON_LOADED, OnAddonLoaded)

-- Diagnostic helper functions
local function GetStateDescription()
    local zoom = GetCameraZoom()
    local state = {
        isFPV = zoom <= ZOOM_FPV,
        isMounted = IsMounted(),
        isWerewolf = IsWerewolf(),
        isSwimming = IsUnitSwimming("player"),
        isSiege = IsGameCameraSiegeControlled(),
        isLimited = IsZoomLimited(),
    }
    return state
end

local function DumpFullState()
    local zoom = GetCameraZoom()
    local state = GetStateDescription()
    
    ChatInfo(SI_BAV_MSG_FULL_STATE_DUMP)
    ChatInfo(SI_BAV_MSG_VERSION_DEBUG,
        BureauOfAcceptableViews.version, GetDebugLevelName(BureauOfAcceptableViews.debugMode), BureauOfAcceptableViews.debugMode)
    ChatInfo(SI_BAV_MSG_ZOOM_VALUES)
    ChatInfo(SI_BAV_MSG_CURRENT_SAVED,
        zoom, lastZoom, savedVars.currentZoom or 0, savedVars.lastThirdPersonZoom or 0)
    ChatInfo(SI_BAV_MSG_LIMITS, ZOOM_FPV, ZOOM_MAX, GetConfiguredZoomStep())
    ChatInfo(SI_BAV_MSG_BEHAVIOR_CONFIG,
        GetConfiguredMinMountedZoom(), GetConfiguredLastZoomThreshold(),
        GetLocalizedBoolean(ShouldPersistFPVBetweenZones()))
    ChatInfo(SI_BAV_MSG_PLAYER_STATE)
    ChatInfo(SI_BAV_MSG_PLAYER_STATE_VALUES,
        GetLocalizedBoolean(state.isFPV), GetLocalizedBoolean(state.isMounted),
        GetLocalizedBoolean(state.isWerewolf), GetLocalizedBoolean(state.isSwimming),
        GetLocalizedBoolean(state.isSiege))
    ChatInfo(SI_BAV_MSG_ZOOM_LIMITED, GetLocalizedBoolean(state.isLimited))
    ChatInfo(SI_BAV_MSG_PROTECTION_FLAGS)
    ChatInfo(SI_BAV_MSG_PROTECTION_FLAGS_VALUES,
        GetLocalizedBoolean(isTogglingFPV), GetLocalizedBoolean(saveQueued))
end

local function SimulateScenario(scenario)
    local zoom = GetCameraZoom()
    local state = GetStateDescription()
    
    ChatInfo(SI_BAV_MSG_SCENARIO, scenario)
    
    if scenario == GetString(SI_BAV_SCENARIO_TOGGLE_FPV) then
        ChatInfo(SI_BAV_MSG_CURRENT_ZOOM_FPV, zoom, GetLocalizedBoolean(zoom <= ZOOM_FPV))
        if zoom <= ZOOM_FPV then
            ChatInfo(SI_BAV_MSG_WOULD_RESTORE_TO, lastZoom)
        else
            ChatInfo(SI_BAV_MSG_WOULD_SAVE_LASTZOOM, zoom)
            ChatInfo(SI_BAV_MSG_WOULD_SET_ZOOM_TO_FPV, ZOOM_FPV)
        end
        
    elseif scenario == GetString(SI_BAV_SCENARIO_ZOOM_IN) then
        local zoomStep = GetConfiguredZoomStep()
        local lastZoomThreshold = GetConfiguredLastZoomThreshold()
        local newZoom = NormalizeZoomValue(mathmax(ZOOM_FPV, zoom - zoomStep))
        ChatInfo(SI_BAV_MSG_ZOOM_TRANSITION, zoom, newZoom)
        ChatInfo(SI_BAV_MSG_WOULD_UPDATE_LASTZOOM,
            GetLocalizedBoolean(newZoom > lastZoomThreshold))
        if zoom <= ZOOM_FPV then
            ChatInfo(SI_BAV_MSG_ALREADY_AT_FPV)
        end
        
    elseif scenario == GetString(SI_BAV_SCENARIO_ZOOM_OUT) then
        local zoomStep = GetConfiguredZoomStep()
        local newZoom = NormalizeZoomValue(mathmin(ZOOM_MAX, zoom + zoomStep))
        ChatInfo(SI_BAV_MSG_ZOOM_TRANSITION, zoom, newZoom)
        if zoom >= ZOOM_MAX then
            ChatInfo(SI_BAV_MSG_ALREADY_AT_MAX)
        end

    elseif scenario == GetString(SI_BAV_SCENARIO_MOUNTED_TOGGLE) then
        ChatInfo(SI_BAV_MSG_IS_MOUNTED, GetLocalizedBoolean(state.isMounted))
        ChatInfo(SI_BAV_MSG_IS_LIMITED, GetLocalizedBoolean(state.isLimited))
        if state.isLimited then
            ChatInfo(SI_BAV_MSG_TOGGLE_HANDLED)
        else
            ChatInfo(SI_BAV_MSG_TOGGLE_GAME)
        end
        
    elseif scenario == GetString(SI_BAV_SCENARIO_FPV_RECOVERY) then
        ChatInfo(SI_BAV_MSG_FPV_RECOVERY, lastZoom)
        ChatInfo(SI_BAV_MSG_LASTZOOM_VALIDITY,
            GetLocalizedBoolean(IsValidZoom(lastZoom)), GetLocalizedBoolean(lastZoom > ZOOM_FPV))

    elseif scenario == GetString(SI_BAV_SCENARIO_RELOG_FPV) then
        local persistedCurrentZoom = GetPersistedCurrentZoom(zoom)
        ChatInfo(SI_BAV_MSG_PRESERVE_FPV_STATE,
            GetLocalizedBoolean(ShouldPersistFPVBetweenZones()))
        ChatInfo(SI_BAV_MSG_CURRENTZOOM_WOULD_BECOME, persistedCurrentZoom)
        if zoom <= ZOOM_FPV and not ShouldPersistFPVBetweenZones() then
            ChatInfo(SI_BAV_MSG_FPV_REPLACED_ON_RELOG)
        end
            
    else
        ChatError(SI_BAV_MSG_UNKNOWN_SCENARIO)
    end
end

local function SetDebugMode(level, suppressOutput)
    return GetSettingsModule().SetDebugMode(level, suppressOutput)
end

local function ResetCameraState(suppressOutput)
    -- First hand the camera back from any optional feature that might be holding
    -- it: a stuck velocity FOV boost, a swung shoulder, a stuck FOV hold, or an
    -- un-restored context-preset snapshot. Order matters: clear the velocity boost
    -- and shoulder swing first, then the preset hold/snapshot, so the zoom reset
    -- below lands on a neutral, un-boosted, un-held, un-swung camera. Each is a
    -- no-op when its feature is off or idle.
    local VelocityFov = BureauOfAcceptableViews.VelocityFov
    if VelocityFov and VelocityFov.EmergencyRestore then
        VelocityFov.EmergencyRestore()
    end

    local ShoulderControl = BureauOfAcceptableViews.ShoulderControl
    if ShoulderControl and ShoulderControl.EmergencyRestore then
        ShoulderControl.EmergencyRestore()
    end

    local ContextPresets = BureauOfAcceptableViews.ContextPresets
    if ContextPresets and ContextPresets.EmergencyRestore then
        ContextPresets.EmergencyRestore()
    end

    -- Clear the oscillation backoff: /bav reset is the explicit recovery point, so
    -- the FPV hook resumes normal handling and the detector starts fresh.
    togglePassive = false
    oscillationWarned = false
    viewFlipTimestamps = {}
    lastObservedFpv = nil

    local resetZoom = GetConfiguredMinMountedZoom()
    lastZoom = resetZoom

    if SetCameraZoom(resetZoom) then
        local appliedZoom = GetCameraZoom()
        SaveCameraState(appliedZoom)
        if not suppressOutput then
            ChatInfo(SI_BAV_MSG_RESET_SUCCESS, appliedZoom)
        end
        return true
    end

    SaveCameraState(resetZoom)
    if not suppressOutput then
        ChatError(SI_BAV_MSG_RESET_FAILED_SYNCED, resetZoom)
    end
    return false
end

local function GetLastZoomValue()
    return lastZoom
end

local function SetLastZoomValue(value)
    lastZoom = value
end

private.ChatInfo = ChatInfo
private.ChatError = ChatError
private.GetLocalizedBoolean = GetLocalizedBoolean
private.GetDebugLevelName = GetDebugLevelName
private.LogInfo = LogInfo
private.LogWarn = LogWarn
private.NormalizeZoomNumber = NormalizeZoomNumber
private.ClampNumber = ClampNumber
private.IsValidZoom = IsValidZoom
private.IsValidThirdPersonZoom = IsValidThirdPersonZoom
private.GetLastZoom = GetLastZoomValue
private.SetLastZoom = SetLastZoomValue
private.GetCameraZoom = GetCameraZoom
private.NormalizeSavedCurrentZoom = NormalizeSavedCurrentZoom
private.SaveCameraState = SaveCameraState
private.ResetCameraState = ResetCameraState
private.DumpFullState = DumpFullState

-- Read-only conflict/backoff diagnostics for SelfCheck and /bav dump. Returns a
-- fresh flat table so callers cannot mutate detector state.
function private.GetConflictDiagnostics()
    return {
        togglePassive   = togglePassive,
        flipsInWindow   = #viewFlipTimestamps,
        oscillationWarned = oscillationWarned,
    }
end

local function HandleConfigCommand(args)
    return GetSettingsModule().HandleConfigCommand(args)
end

local function OpenSettingsPanel()
    return GetSettingsModule().OpenPanel()
end

function BureauOfAcceptableViews.RegisterSettingsPanel()
    return GetSettingsModule().RegisterSettingsPanel()
end

local function ForceSetZoom(value)
    value = NormalizeZoomValue(value)
    if not value then
        ChatError(SI_BAV_MSG_USAGE_SET)
        return
    end
    
    if SetCameraZoom(value) then
        local appliedZoom = GetCameraZoom()
        ChatInfo(SI_BAV_MSG_ZOOM_SET, appliedZoom)
        if appliedZoom > GetConfiguredLastZoomThreshold() then
            lastZoom = appliedZoom
            ChatInfo(SI_BAV_MSG_LASTZOOM_UPDATED, lastZoom)
        end
        SaveCameraState(appliedZoom)
    else
        ChatError(SI_BAV_MSG_SET_FAILED, value, ZOOM_FPV, ZOOM_MAX)
    end
end

-- Comprehensive slash command
-- ---------------------------------------------------------------------------
-- Sub-commands are looked up in a dispatch table instead of an if/elseif
-- ladder: adding a command is a single table entry, lookup is O(1), and each
-- handler receives the parsed, lower-cased argument list. Unknown actions fall
-- through to the shared error handler.
local SLASH_HELP_STRING_IDS = {
    SI_BAV_MSG_HELP_TITLE,
    SI_BAV_MSG_HELP_STATUS,
    SI_BAV_MSG_HELP_SETTINGS,
    SI_BAV_MSG_HELP_DUMP,
    SI_BAV_MSG_HELP_DEBUG,
    SI_BAV_MSG_HELP_SET,
    SI_BAV_MSG_HELP_CONFIG,
    SI_BAV_MSG_HELP_CONFIG_STEP,
    SI_BAV_MSG_HELP_CONFIG_THRESHOLD,
    SI_BAV_MSG_HELP_CONFIG_MINMOUNTED,
    SI_BAV_MSG_HELP_CONFIG_PRESERVEFPV,
    SI_BAV_MSG_HELP_CONFIG_RESET,
    SI_BAV_MSG_HELP_SIMULATE,
    SI_BAV_MSG_HELP_RESET,
    SI_BAV_MSG_HELP_SHOULDER,
    SI_BAV_MSG_HELP_SCENARIOS,
    SI_BAV_MSG_HELP_SELFCHECK,
}

local SLASH_COMMAND_HANDLERS = {
    status = function(args)
        local zoom = GetCameraZoom()
        ChatInfo(SI_BAV_MSG_STATUS,
            zoom, lastZoom, savedVars.currentZoom or 0, savedVars.lastThirdPersonZoom or 0,
            GetDebugLevelName(BureauOfAcceptableViews.debugMode), BureauOfAcceptableViews.debugMode)
    end,
    dump = function(args)
        DumpFullState()
    end,
    debug = function(args)
        SetDebugMode(args[2])
    end,
    set = function(args)
        ForceSetZoom(args[2])
    end,
    config = function(args)
        HandleConfigCommand(args)
    end,
    settings = function(args)
        if not OpenSettingsPanel() then
            ChatError(SI_BAV_MSG_SETTINGS_UNAVAILABLE)
        end
    end,
    simulate = function(args)
        SimulateScenario(args[2] or "unknown")
    end,
    reset = function(args)
        ResetCameraState()
    end,
    shoulder = function(args)
        -- Manual-mode over-the-shoulder control. The two active shoulder modes are
        -- mutually exclusive: this command is only meaningful in Manual mode, so in
        -- Off/Auto we print a notice instead of silently doing nothing.
        local settings = GetSettingsModule()
        if settings.GetShoulderMode() ~= "manual" then
            ChatInfo(SI_BAV_MSG_SHOULDER_NOT_MANUAL)
            return
        end

        local shoulder = BureauOfAcceptableViews.ShoulderControl
        if not (shoulder and shoulder.SetManualSide) then
            return
        end

        -- args[2] (already lower-cased) may be left/right/center; absent toggles.
        local requested = args[2]
        if requested ~= "left" and requested ~= "right" and requested ~= "center" then
            requested = nil  -- toggle
        end

        local ok, side = shoulder.SetManualSide(requested or "toggle")
        if ok then
            local SIDE_STRING_IDS = {
                left   = SI_BAV_SETTING_SHOULDER_SIDE_LEFT,
                right  = SI_BAV_SETTING_SHOULDER_SIDE_RIGHT,
                center = SI_BAV_SETTING_SHOULDER_SIDE_CENTER,
            }
            local sideId = SIDE_STRING_IDS[side]
            ChatInfo(SI_BAV_MSG_SHOULDER_SET, sideId and GetString(sideId) or side)
        end
    end,
    selfcheck = function(args)
        if BureauOfAcceptableViews.SelfCheck then
            BureauOfAcceptableViews.SelfCheck.Run(true)
        end
    end,
    help = function(args)
        for index = 1, #SLASH_HELP_STRING_IDS do
            ChatInfo(SLASH_HELP_STRING_IDS[index])
        end
    end,
}

-- Convenience aliases so `/bav ui` and `/bav panel` also open the settings
-- window, mirroring the primary `settings` sub-command.
SLASH_COMMAND_HANDLERS.ui = SLASH_COMMAND_HANDLERS.settings
SLASH_COMMAND_HANDLERS.panel = SLASH_COMMAND_HANDLERS.settings

SLASH_COMMANDS["/bav"] = function(cmd)
    local args = {}
    for word in stringgmatch(cmd, "%S+") do
        tableinsert(args, stringlower(word))
    end

    local action = args[1] or "status"
    local handler = SLASH_COMMAND_HANDLERS[action]
    if handler then
        handler(args)
    else
        ChatError(SI_BAV_MSG_UNKNOWN_COMMAND)
    end
end
