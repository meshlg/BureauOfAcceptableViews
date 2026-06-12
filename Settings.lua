local addon = BureauOfAcceptableViews
addon.Settings = addon.Settings or {}

local Settings = addon.Settings
local private = addon.private

local constants = private.constants or {}
local ZOOM_MAX = constants.ZOOM_MAX or 10.0
local ZOOM_MIN_MOUNTED = constants.ZOOM_MIN_MOUNTED or 2.0
local LASTZOOM_THRESHOLD = constants.LASTZOOM_THRESHOLD or 2.0
local ZOOM_FPV = constants.ZOOM_FPV or 0.0
local ZOOM_STEP = constants.ZOOM_STEP or 0.35
local PRESERVE_FPV_BETWEEN_ZONES = constants.PRESERVE_FPV_BETWEEN_ZONES
local ZOOM_STEP_MIN = constants.ZOOM_STEP_MIN or 0.05
local ZOOM_STEP_MAX = constants.ZOOM_STEP_MAX or 5.0
local CONFIG_MIN_THIRD_PERSON_ZOOM = constants.CONFIG_MIN_THIRD_PERSON_ZOOM or 0.10

-- Single source of truth for context-preset states: drives the SavedVariables
-- defaults, the SetPresetState validity guard, and the settings-panel checkbox
-- grid. Order here is the order shown in the UI. Adding a new state means
-- adding one row here (plus its localized name/tooltip strings).
local PRESET_STATE_DEFINITIONS = {
    { id = "combat",   nameKey = SI_BAV_SETTING_PRESET_STATE_COMBAT_NAME,   tooltipKey = SI_BAV_SETTING_PRESET_STATE_COMBAT_TOOLTIP,   reference = "BAVSettingsPresetStateCombat" },
    { id = "werewolf", nameKey = SI_BAV_SETTING_PRESET_STATE_WEREWOLF_NAME, tooltipKey = SI_BAV_SETTING_PRESET_STATE_WEREWOLF_TOOLTIP, reference = "BAVSettingsPresetStateWerewolf" },
    { id = "stealth",  nameKey = SI_BAV_SETTING_PRESET_STATE_STEALTH_NAME,  tooltipKey = SI_BAV_SETTING_PRESET_STATE_STEALTH_TOOLTIP,  reference = "BAVSettingsPresetStateStealth" },
    { id = "mounted",  nameKey = SI_BAV_SETTING_PRESET_STATE_MOUNTED_NAME,  tooltipKey = SI_BAV_SETTING_PRESET_STATE_MOUNTED_TOOLTIP,  reference = "BAVSettingsPresetStateMounted" },
    { id = "sprint",   nameKey = SI_BAV_SETTING_PRESET_STATE_SPRINT_NAME,   tooltipKey = SI_BAV_SETTING_PRESET_STATE_SPRINT_TOOLTIP,   reference = "BAVSettingsPresetStateSprint" },
}

-- Valid context-preset state ids, used to guard SetPresetState against stale UI
-- references writing junk keys into SavedVariables. Derived from the definitions
-- above so the two can never drift apart.
local PRESET_STATE_IDS = {}
for _, def in ipairs(PRESET_STATE_DEFINITIONS) do
    PRESET_STATE_IDS[def.id] = true
end

-- Style id meaning "this state does nothing". Kept as a literal here (rather
-- than calling ContextPresets.GetOffStyleId at file-parse time) so the defaults
-- table below can be built regardless of module load order; it is asserted to
-- match the controller's value the first time styles are normalized.
local PRESET_STYLE_OFF = "off"

-- Maps a style id to the localized string constant for its display name, used
-- to label the per-state dropdown choices. Kept here next to the state list so
-- adding a style is a one-line change. Unknown ids fall back to the raw id text
-- so a newly-added controller style is still selectable before its string lands.
local PRESET_STYLE_NAME_KEYS = {
    off       = SI_BAV_SETTING_PRESET_STYLE_OFF_NAME,
    subtle    = SI_BAV_SETTING_PRESET_STYLE_SUBTLE_NAME,
    cinematic = SI_BAV_SETTING_PRESET_STYLE_CINEMATIC_NAME,
    action    = SI_BAV_SETTING_PRESET_STYLE_ACTION_NAME,
}

local function StyleNameKey(styleId)
    return PRESET_STYLE_NAME_KEYS[styleId] or tostring(styleId)
end

if PRESERVE_FPV_BETWEEN_ZONES == nil then
    PRESERVE_FPV_BETWEEN_ZONES = true
end

---@class BAVSavedVars
---@field currentZoom number
---@field lastThirdPersonZoom number
---@field zoomStep number
---@field lastZoomThreshold number
---@field zoomMinMounted number
---@field preserveFpvBetweenZones boolean
---@field zoom number|nil
---@field dynamicFovEnabled boolean
---@field dynamicFovNear number|nil
---@field dynamicFovFar number|nil
---@field dynamicFovSmooth boolean
---@field presetsEnabled boolean
---@field presetIntensity number
---@field presetSmoothTransitions boolean
---@field presetStates table<string, string>
---@field presetRestoreSnapshot table|nil

---@type BAVSavedVars
local DEFAULT_SAVED_VARS = {
    currentZoom = ZOOM_MIN_MOUNTED,
    lastThirdPersonZoom = ZOOM_MIN_MOUNTED,
    zoomStep = ZOOM_STEP,
    lastZoomThreshold = LASTZOOM_THRESHOLD,
    zoomMinMounted = ZOOM_MIN_MOUNTED,
    preserveFpvBetweenZones = PRESERVE_FPV_BETWEEN_ZONES,
    -- Optional camera features. Dynamic FOV ships ON by default (with smoothing)
    -- so a fresh install gets the eased zoom feel out of the box; it still does
    -- nothing on clients where the FOV property is unsupported. Context presets
    -- stay OFF by default -- a disabled module registers no events.
    dynamicFovEnabled = true,
    dynamicFovNear = nil,   -- nil => DynamicFov resolves to the engine FOV range
    dynamicFovFar = nil,
    dynamicFovSmooth = true,  -- glide FOV between zoom steps instead of snapping
    presetsEnabled = false,
    presetIntensity = 1.0,
    -- Ease context-preset state changes (spatial framing + FOV) over a short
    -- glide instead of snapping. Defaults ON, matching the Dynamic FOV smoothing
    -- precedent; turning it off restores instant transitions.
    presetSmoothTransitions = true,
    -- Each state holds a STYLE id (not a boolean): "off" disables the state,
    -- other ids ("subtle"/"cinematic"/"action") pick how strong its framing is.
    -- All default to "off" so a fresh install applies nothing until the user
    -- both enables presets and picks a style per state.
    presetStates = {
        combat = PRESET_STYLE_OFF,
        werewolf = PRESET_STYLE_OFF,
        stealth = PRESET_STYLE_OFF,
        mounted = PRESET_STYLE_OFF,
        sprint = PRESET_STYLE_OFF,
    },
    -- Runtime recovery (NOT a user setting): the player's own camera captured
    -- the moment a context preset first overrode it. Persisted so a /reloadui,
    -- logout, or crash WHILE a preset is active can hand the real camera back
    -- next session instead of leaving the preset's offsets baked into the
    -- player's settings (and then re-snapshotting those dirty values, which
    -- compounds every session). nil whenever no preset is overriding the camera.
    presetRestoreSnapshot = nil,
}

---@type BAVSavedVars|nil (accessible via private.savedVars after initialization)

local function GetSavedVarsOrDefaults()
    return private.savedVars or DEFAULT_SAVED_VARS
end

local function NormalizeBoolean(value, defaultValue)
    if value == nil then
        return defaultValue
    end
    if value == true or value == false then
        return value
    end

    value = string.lower(tostring(value))
    if value == "1" or value == "true" or value == "on" or value == "yes" then
        return true
    end
    if value == "0" or value == "false" or value == "off" or value == "no" then
        return false
    end

    return defaultValue
end

local function ParseBooleanArgument(value)
    if value == nil then
        return nil
    end

    return NormalizeBoolean(value, nil)
end

function Settings.GetSavedVars()
    return private.savedVars
end

function Settings.InitializeSavedVariables()
    private.savedVars = ZO_SavedVars:NewAccountWide(
        addon.savedVariablesName,
        1,
        nil,
        DEFAULT_SAVED_VARS
    )

    local legacyZoom = tonumber(private.savedVars.zoom)
    if private.IsValidZoom(legacyZoom) then
        private.savedVars.currentZoom = legacyZoom
        if private.IsValidThirdPersonZoom(legacyZoom) then
            private.savedVars.lastThirdPersonZoom = legacyZoom
        end
        private.savedVars.zoom = nil
        private.LogInfo(SI_BAV_LOG_MIGRATED_LEGACY_ZOOM, legacyZoom)
    end

    Settings.NormalizeSavedSettings()
    return private.savedVars
end

function Settings.GetConfiguredZoomStep()
    local vars = GetSavedVarsOrDefaults()
    return private.NormalizeZoomNumber(
        private.ClampNumber(tonumber(vars.zoomStep) or ZOOM_STEP, ZOOM_STEP_MIN, ZOOM_STEP_MAX),
        ZOOM_STEP
    )
end

function Settings.GetConfiguredLastZoomThreshold()
    local vars = GetSavedVarsOrDefaults()
    return private.NormalizeZoomNumber(
        private.ClampNumber(tonumber(vars.lastZoomThreshold) or LASTZOOM_THRESHOLD, ZOOM_FPV, ZOOM_MAX),
        LASTZOOM_THRESHOLD
    )
end

function Settings.GetConfiguredMinMountedZoom()
    local vars = GetSavedVarsOrDefaults()
    return private.NormalizeZoomNumber(
        private.ClampNumber(tonumber(vars.zoomMinMounted) or ZOOM_MIN_MOUNTED, CONFIG_MIN_THIRD_PERSON_ZOOM, ZOOM_MAX),
        ZOOM_MIN_MOUNTED
    )
end

function Settings.ShouldPersistFPVBetweenZones()
    local vars = GetSavedVarsOrDefaults()
    return NormalizeBoolean(vars.preserveFpvBetweenZones, PRESERVE_FPV_BETWEEN_ZONES)
end

-- ---------------------------------------------------------------------------
-- Optional feature getters (Dynamic FOV + Context Presets)
-- ---------------------------------------------------------------------------

function Settings.IsDynamicFovEnabled()
    local vars = GetSavedVarsOrDefaults()
    return NormalizeBoolean(vars.dynamicFovEnabled, true)
end

-- Whether FOV changes between zoom steps should glide rather than snap. Purely
-- cosmetic; defaults on, matching the shipped Dynamic FOV default. The nil
-- fallback here only matters if the key is somehow absent.
function Settings.IsDynamicFovSmooth()
    local vars = GetSavedVarsOrDefaults()
    return NormalizeBoolean(vars.dynamicFovSmooth, true)
end

-- nil near/far are intentional: DynamicFov.Configure resolves them to the
-- engine FOV range, so we don't hardcode FOV limits in two places.
function Settings.GetDynamicFovNear()
    local vars = GetSavedVarsOrDefaults()
    return tonumber(vars.dynamicFovNear)
end

function Settings.GetDynamicFovFar()
    local vars = GetSavedVarsOrDefaults()
    return tonumber(vars.dynamicFovFar)
end

-- Engine third-person FOV range, used as both the slider bounds and the
-- fallback for unset near/far values. We read it from CameraSettings (the
-- single source of truth for the clamp limits) and only fall back to the
-- documented 35..65 literals when the property cannot be resolved on this
-- client build, so the two never silently drift apart.
local DYNAMIC_FOV_RANGE_FALLBACK_MIN = 35
local DYNAMIC_FOV_RANGE_FALLBACK_MAX = 65

function Settings.GetDynamicFovRange()
    local CameraSettings = addon.CameraSettings
    if CameraSettings and CameraSettings.GetRange then
        local minFov, maxFov, decimals = CameraSettings.GetRange("thirdPersonFov")
        if minFov and maxFov then
            return minFov, maxFov, decimals or 2
        end
    end
    return DYNAMIC_FOV_RANGE_FALLBACK_MIN, DYNAMIC_FOV_RANGE_FALLBACK_MAX, 2
end

-- Slider-friendly accessors: resolve an unset (nil) near/far to the engine FOV
-- range endpoints so the control always shows a concrete value. nearFov maps to
-- the closest zoom, farFov to the farthest -- mirroring DynamicFov's own model.
function Settings.GetDynamicFovNearResolved()
    local minFov, maxFov = Settings.GetDynamicFovRange()
    local value = Settings.GetDynamicFovNear() or minFov
    return private.ClampNumber(value, minFov, maxFov)
end

function Settings.GetDynamicFovFarResolved()
    local minFov, maxFov = Settings.GetDynamicFovRange()
    local value = Settings.GetDynamicFovFar() or maxFov
    return private.ClampNumber(value, minFov, maxFov)
end

function Settings.ArePresetsEnabled()
    local vars = GetSavedVarsOrDefaults()
    return NormalizeBoolean(vars.presetsEnabled, false)
end

function Settings.GetPresetIntensity()
    local vars = GetSavedVarsOrDefaults()
    return private.ClampNumber(tonumber(vars.presetIntensity) or 1.0, 0, 1)
end

-- Whether context-preset state changes should glide rather than snap. Cosmetic;
-- defaults on, mirroring Settings.IsDynamicFovSmooth. The nil fallback only
-- matters if the key is somehow absent.
function Settings.ArePresetTransitionsSmooth()
    local vars = GetSavedVarsOrDefaults()
    return NormalizeBoolean(vars.presetSmoothTransitions, true)
end

-- Lazily-built lookup of valid style ids -> true, plus the resolved off/default
-- ids, sourced from ContextPresets so Settings never hardcodes the style list.
-- Built on first use (not at file load) because ContextPresets may not be
-- available yet at parse time depending on manifest order.
local presetStyleLookup       -- { [styleId] = true } or nil until built
local presetStyleOffId        -- resolved "off" id
local presetStyleDefaultId    -- resolved default ("on") id

local function EnsurePresetStyleInfo()
    if presetStyleLookup then
        return
    end
    presetStyleLookup = {}
    presetStyleOffId = PRESET_STYLE_OFF
    presetStyleDefaultId = PRESET_STYLE_OFF

    local cp = addon.ContextPresets
    if cp and cp.GetStyleIds then
        for _, id in ipairs(cp.GetStyleIds()) do
            presetStyleLookup[id] = true
        end
        presetStyleOffId = cp.GetOffStyleId and cp.GetOffStyleId() or PRESET_STYLE_OFF
        presetStyleDefaultId = cp.GetDefaultStyleId and cp.GetDefaultStyleId() or presetStyleOffId
    else
        -- Fallback if the module isn't loaded: only the off id is known-valid.
        presetStyleLookup[PRESET_STYLE_OFF] = true
    end
end

-- Coerce a stored value into a valid style id. Accepts legacy booleans for the
-- old toggle format: true -> the default style, false -> off. Anything unknown
-- (nil, junk string, removed style) falls back to off so a state never applies
-- an undefined profile.
local function NormalizePresetStyle(value)
    EnsurePresetStyleInfo()
    if value == true then
        return presetStyleDefaultId
    elseif value == false or value == nil then
        return presetStyleOffId
    elseif type(value) == "string" and presetStyleLookup[value] then
        return value
    end
    return presetStyleOffId
end

-- Returns the per-state style map with every state present (defaults to the off
-- style), so callers and ContextPresets.Configure get a complete table. Legacy
-- boolean values are migrated to style ids on read.
function Settings.GetPresetStates()
    local vars = GetSavedVarsOrDefaults()
    local saved = type(vars.presetStates) == "table" and vars.presetStates or {}
    return {
        combat   = NormalizePresetStyle(saved.combat),
        werewolf = NormalizePresetStyle(saved.werewolf),
        stealth  = NormalizePresetStyle(saved.stealth),
        mounted  = NormalizePresetStyle(saved.mounted),
        sprint   = NormalizePresetStyle(saved.sprint),
    }
end

-- Returns a single preset state's style id (defaults to the off style). Used by
-- the per-state dropdowns so each getFunc avoids allocating the full table.
function Settings.GetPresetState(stateId)
    local vars = GetSavedVarsOrDefaults()
    local saved = type(vars.presetStates) == "table" and vars.presetStates or nil
    return NormalizePresetStyle(saved ~= nil and saved[stateId] or nil)
end

-- Set a single preset state's style id and push the change to the module.
-- Unknown state ids are ignored so a stale UI reference can't corrupt savedvars;
-- the value is normalized so only valid style ids are ever stored.
function Settings.SetPresetState(stateId, style)
    local vars = Settings.GetSavedVars()
    if not vars then
        return
    end
    if type(vars.presetStates) ~= "table" then
        vars.presetStates = {}
    end
    if vars.presetStates[stateId] == nil and not PRESET_STATE_IDS[stateId] then
        return
    end
    vars.presetStates[stateId] = NormalizePresetStyle(style)
    Settings.ApplyOptionalFeatureConfig()
end

-- ---------------------------------------------------------------------------
-- Preset restore-snapshot persistence (recovery, not a user setting)
-- ---------------------------------------------------------------------------
-- ContextPresets owns WHAT goes in the snapshot; Settings owns persistence.
-- These two functions are the whole contract: the controller pushes its
-- in-memory snapshot here whenever it captures or clears it, and reads it back
-- once on load to recover a camera that a preset was overriding when the
-- session ended. Storing nil clears it.

-- Returns the persisted restore snapshot (a plain camera-values table) or nil.
function Settings.GetPresetRestoreSnapshot()
    local vars = GetSavedVarsOrDefaults()
    local snapshot = vars.presetRestoreSnapshot
    if type(snapshot) ~= "table" then
        return nil
    end
    return snapshot
end

-- Persist (or clear, when snapshot is nil) the restore snapshot. A non-table,
-- non-nil argument is rejected so a bad caller cannot poison savedvars.
function Settings.SetPresetRestoreSnapshot(snapshot)
    local vars = Settings.GetSavedVars()
    if not vars then
        return
    end
    if snapshot == nil then
        vars.presetRestoreSnapshot = nil
        return
    end
    if type(snapshot) ~= "table" then
        return
    end
    vars.presetRestoreSnapshot = snapshot
end

function Settings.NormalizeSavedSettings()
    local savedVars = private.savedVars
    if not savedVars then
        return
    end

    savedVars.zoomStep = Settings.GetConfiguredZoomStep()
    savedVars.lastZoomThreshold = Settings.GetConfiguredLastZoomThreshold()
    savedVars.zoomMinMounted = Settings.GetConfiguredMinMountedZoom()
    savedVars.preserveFpvBetweenZones = Settings.ShouldPersistFPVBetweenZones()
end

function Settings.SetDebugMode(level, suppressOutput)
    level = tonumber(level) or 0
    if level >= 0 and level <= 4 then
        addon.debugMode = level
        if not suppressOutput then
            private.ChatInfo(SI_BAV_MSG_DEBUG_MODE_SET, private.GetDebugLevelName(level), level)
        end
        return true
    end

    if not suppressOutput then
        private.ChatError(SI_BAV_MSG_INVALID_DEBUG_LEVEL)
    end
    return false
end

function Settings.PrintConfiguration()
    private.ChatInfo(SI_BAV_MSG_CONFIG_SUMMARY,
        Settings.GetConfiguredZoomStep(), Settings.GetConfiguredLastZoomThreshold(), Settings.GetConfiguredMinMountedZoom(),
        private.GetLocalizedBoolean(Settings.ShouldPersistFPVBetweenZones()))
end

-- Push the optional-feature settings (Dynamic FOV + Context Presets) into their
-- modules. Centralized here so both the load path and any settings change go
-- through one place. Safe when a module is absent (load-order guard).
function Settings.ApplyOptionalFeatureConfig()
    local addon = BureauOfAcceptableViews

    if addon.DynamicFov and addon.DynamicFov.Configure then
        addon.DynamicFov.Configure({
            enabled = Settings.IsDynamicFovEnabled(),
            nearFov = Settings.GetDynamicFovNear(),
            farFov  = Settings.GetDynamicFovFar(),
            smooth  = Settings.IsDynamicFovSmooth(),
        })
    end

    if addon.ContextPresets and addon.ContextPresets.Configure then
        addon.ContextPresets.Configure({
            enabled   = Settings.ArePresetsEnabled(),
            intensity = Settings.GetPresetIntensity(),
            smooth    = Settings.ArePresetTransitionsSmooth(),
            states    = Settings.GetPresetStates(),
        })
    end
end

function Settings.ApplyConfigurationChanges()
    Settings.NormalizeSavedSettings()

    if not private.IsValidThirdPersonZoom(private.GetLastZoom()) then
        private.SetLastZoom(Settings.GetConfiguredMinMountedZoom())
    end

    private.NormalizeSavedCurrentZoom()
    private.SaveCameraState()

    Settings.ApplyOptionalFeatureConfig()
end

function Settings.ResetConfigurationToDefaults(suppressOutput)
    local savedVars = private.savedVars
    if not savedVars then
        return
    end

    savedVars.zoomStep = ZOOM_STEP
    savedVars.lastZoomThreshold = LASTZOOM_THRESHOLD
    savedVars.zoomMinMounted = ZOOM_MIN_MOUNTED
    savedVars.preserveFpvBetweenZones = PRESERVE_FPV_BETWEEN_ZONES
    -- Reset deliberately switches the optional features OFF (an inert, neutral
    -- camera) rather than restoring the shipped "on" defaults: a reset is the
    -- user's escape hatch back to vanilla behavior. dynamicFovSmooth is left
    -- untouched -- it's greyed out and irrelevant while Dynamic FOV is off.
    savedVars.dynamicFovEnabled = false
    savedVars.dynamicFovNear = nil
    savedVars.dynamicFovFar = nil
    savedVars.presetsEnabled = false
    savedVars.presetIntensity = 1.0
    savedVars.presetStates = {
        combat = false, werewolf = false, stealth = false, mounted = false, sprint = false,
    }
    Settings.ApplyConfigurationChanges()

    if not suppressOutput then
        private.ChatInfo(SI_BAV_MSG_CONFIG_RESET)
        Settings.PrintConfiguration()
    end
end

function Settings.HandleConfigCommand(args)
    local savedVars = private.savedVars
    if not savedVars then
        return
    end

    local option = args[2]
    local value = args[3]

    if not option or option == "show" or option == "list" then
        Settings.PrintConfiguration()
        private.ChatInfo(SI_BAV_MSG_CONFIG_USAGE)
        return
    end

    if option == "reset" then
        Settings.ResetConfigurationToDefaults()
        return
    end

    if option == "step" then
        local numericValue = tonumber(value)
        if not numericValue then
            private.ChatError(SI_BAV_MSG_USAGE_CONFIG_STEP)
            return
        end
        savedVars.zoomStep = numericValue
        Settings.ApplyConfigurationChanges()
        private.ChatInfo(SI_BAV_MSG_CONFIG_STEP_SET, Settings.GetConfiguredZoomStep())
        Settings.PrintConfiguration()
        return
    end

    if option == "threshold" then
        local numericValue = tonumber(value)
        if not numericValue then
            private.ChatError(SI_BAV_MSG_USAGE_CONFIG_THRESHOLD)
            return
        end
        savedVars.lastZoomThreshold = numericValue
        Settings.ApplyConfigurationChanges()
        private.ChatInfo(SI_BAV_MSG_CONFIG_THRESHOLD_SET, Settings.GetConfiguredLastZoomThreshold())
        Settings.PrintConfiguration()
        return
    end

    if option == "minmounted" or option == "mountedmin" or option == "min" then
        local numericValue = tonumber(value)
        if not numericValue then
            private.ChatError(SI_BAV_MSG_USAGE_CONFIG_MINMOUNTED)
            return
        end
        savedVars.zoomMinMounted = numericValue
        Settings.ApplyConfigurationChanges()
        private.ChatInfo(SI_BAV_MSG_CONFIG_MINMOUNTED_SET, Settings.GetConfiguredMinMountedZoom())
        Settings.PrintConfiguration()
        return
    end

    if option == "preservefpv" or option == "persistfpv" then
        local booleanValue = ParseBooleanArgument(value)
        if booleanValue == nil then
            private.ChatError(SI_BAV_MSG_USAGE_CONFIG_PRESERVEFPV)
            return
        end
        savedVars.preserveFpvBetweenZones = booleanValue
        Settings.ApplyConfigurationChanges()
        private.ChatInfo(SI_BAV_MSG_CONFIG_PRESERVE_SET,
            private.GetLocalizedBoolean(Settings.ShouldPersistFPVBetweenZones()))
        Settings.PrintConfiguration()
        return
    end

    private.ChatError(SI_BAV_MSG_CONFIG_UNKNOWN_OPTION)
end

function Settings.RegisterSettingsPanel()
    local lam = LibAddonMenu2
    if not lam then
        private.LogWarn(SI_BAV_LOG_LAM_MISSING)
        return
    end

    local panelIdentifier = addon.name .. "_Settings"
    local debugChoices = {
        private.GetDebugLevelName(0),
        private.GetDebugLevelName(1),
        private.GetDebugLevelName(2),
        private.GetDebugLevelName(3),
        private.GetDebugLevelName(4),
    }

    -- Resolve the engine FOV range once for the Dynamic FOV sliders so their
    -- bounds always match what the engine will actually accept (35..65 today),
    -- and the user can never push the values outside acceptable limits.
    local dynamicFovMin, dynamicFovMax = Settings.GetDynamicFovRange()

    local function PresetsDisabled()
        return not Settings.ArePresetsEnabled()
    end

    local function DynamicFovDisabled()
        return not Settings.IsDynamicFovEnabled()
    end

    -- Build the per-state preset dropdowns from PRESET_STATE_DEFINITIONS so the
    -- state list stays a single source of truth. Each state picks a STYLE (Off /
    -- Subtle / Cinematic / Action) rather than a plain on/off toggle. Returned as
    -- a flat list that is spliced directly into the Context Presets submenu below.
    local function BuildPresetStateControls()
        local controls = {
            {
                type = "description",
                text = GetString(SI_BAV_LABEL_PRESET_STATES),
                width = "full",
                disabled = PresetsDisabled,
                reference = "BAVSettingsPresetStatesLabel",
            },
        }

        -- Style id list + parallel display-name list, shared by every dropdown.
        -- Built once here from ContextPresets so the choices always match the
        -- styles the controller actually understands.
        local cp = addon.ContextPresets
        local styleIds = (cp and cp.GetStyleIds)
            and cp.GetStyleIds() or { PRESET_STYLE_OFF }
        local styleNames = {}
        for i = 1, #styleIds do
            styleNames[i] = GetString(StyleNameKey(styleIds[i]))
        end

        for _, def in ipairs(PRESET_STATE_DEFINITIONS) do
            local stateId = def.id
            controls[#controls + 1] = {
                type = "dropdown",
                name = GetString(def.nameKey),
                tooltip = GetString(def.tooltipKey),
                choices = styleNames,
                choicesValues = styleIds,
                getFunc = function() return Settings.GetPresetState(stateId) end,
                setFunc = function(value) Settings.SetPresetState(stateId, value) end,
                width = "half",
                default = PRESET_STYLE_OFF,
                disabled = PresetsDisabled,
                reference = def.reference,
            }
        end
        return controls
    end

    local panelData = {
        type = "panel",
        name = GetString(SI_BAV_PANEL_NAME),
        displayName = GetString(SI_BAV_PANEL_DISPLAY_NAME),
        author = "meshlg",
        version = addon.version,
        registerForRefresh = true,
        registerForDefaults = false,
    }

    local optionsData = {
        {
            type = "description",
            text = GetString(SI_BAV_PANEL_INTRO),
            width = "full",
        },
        {
            type = "description",
            text = GetString(SI_BAV_PANEL_OVERVIEW),
            width = "full",
        },
        {
            type = "description",
            text = GetString(SI_BAV_SLASH_HINT),
            width = "full",
        },
        {
            type = "header",
            name = GetString(SI_BAV_HEADER_CAMERA),
        },
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_CAMERA_DESCRIPTION),
            width = "full",
        },
        {
            type = "slider",
            name = GetString(SI_BAV_SETTING_ZOOM_STEP_NAME),
            tooltip = GetString(SI_BAV_SETTING_ZOOM_STEP_TOOLTIP),
            min = ZOOM_STEP_MIN,
            max = ZOOM_STEP_MAX,
            step = 0.05,
            decimals = 2,
            getFunc = function() return Settings.GetConfiguredZoomStep() end,
            setFunc = function(value)
                local vars = private.savedVars
                if not vars then
                    return
                end

                vars.zoomStep = value
                Settings.ApplyConfigurationChanges()
            end,
            default = ZOOM_STEP,
            width = "full",
            reference = "BAVSettingsZoomStep",
        },
        {
            type = "slider",
            name = GetString(SI_BAV_SETTING_THRESHOLD_NAME),
            tooltip = GetString(SI_BAV_SETTING_THRESHOLD_TOOLTIP),
            min = ZOOM_FPV,
            max = ZOOM_MAX,
            step = 0.05,
            decimals = 2,
            getFunc = function() return Settings.GetConfiguredLastZoomThreshold() end,
            setFunc = function(value)
                local vars = private.savedVars
                if not vars then
                    return
                end

                vars.lastZoomThreshold = value
                Settings.ApplyConfigurationChanges()
            end,
            default = LASTZOOM_THRESHOLD,
            width = "full",
            reference = "BAVSettingsThreshold",
        },
        {
            type = "slider",
            name = GetString(SI_BAV_SETTING_MIN_MOUNTED_NAME),
            tooltip = GetString(SI_BAV_SETTING_MIN_MOUNTED_TOOLTIP),
            min = CONFIG_MIN_THIRD_PERSON_ZOOM,
            max = ZOOM_MAX,
            step = 0.05,
            decimals = 2,
            getFunc = function() return Settings.GetConfiguredMinMountedZoom() end,
            setFunc = function(value)
                local vars = private.savedVars
                if not vars then
                    return
                end

                vars.zoomMinMounted = value
                Settings.ApplyConfigurationChanges()
            end,
            default = ZOOM_MIN_MOUNTED,
            width = "full",
            reference = "BAVSettingsMountedFallback",
        },
        {
            type = "header",
            name = GetString(SI_BAV_HEADER_BEHAVIOR),
        },
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_BEHAVIOR_DESCRIPTION),
            width = "full",
        },
        {
            type = "checkbox",
            name = GetString(SI_BAV_SETTING_PRESERVE_FPV_NAME),
            tooltip = GetString(SI_BAV_SETTING_PRESERVE_FPV_TOOLTIP),
            getFunc = function() return Settings.ShouldPersistFPVBetweenZones() end,
            setFunc = function(value)
                local vars = private.savedVars
                if not vars then
                    return
                end

                vars.preserveFpvBetweenZones = value
                Settings.ApplyConfigurationChanges()
            end,
            default = PRESERVE_FPV_BETWEEN_ZONES,
            width = "full",
            reference = "BAVSettingsPreserveFPV",
        },
        {
            type = "submenu",
            name = GetString(SI_BAV_HEADER_DYNAMIC_FOV),
            tooltip = GetString(SI_BAV_SECTION_DYNAMIC_FOV_DESCRIPTION),
            controls = {
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_DYNAMIC_FOV_DESCRIPTION),
            width = "full",
        },
        {
            type = "checkbox",
            name = GetString(SI_BAV_SETTING_DYNAMIC_FOV_ENABLED_NAME),
            tooltip = GetString(SI_BAV_SETTING_DYNAMIC_FOV_ENABLED_TOOLTIP),
            getFunc = function() return Settings.IsDynamicFovEnabled() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.dynamicFovEnabled = value and true or false end
                Settings.ApplyOptionalFeatureConfig()
            end,
            width = "full",
            default = true,
            reference = "BAVSettingsDynamicFovEnabled",
        },
        {
            -- Purely cosmetic glide between zoom steps. Greyed out unless the
            -- feature itself is on, matching the near/far sliders below.
            type = "checkbox",
            name = GetString(SI_BAV_SETTING_DYNAMIC_FOV_SMOOTH_NAME),
            tooltip = GetString(SI_BAV_SETTING_DYNAMIC_FOV_SMOOTH_TOOLTIP),
            getFunc = function() return Settings.IsDynamicFovSmooth() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.dynamicFovSmooth = value and true or false end
                Settings.ApplyOptionalFeatureConfig()
            end,
            disabled = DynamicFovDisabled,
            width = "full",
            default = true,
            reference = "BAVSettingsDynamicFovSmooth",
        },
        {
            -- FOV applied when zoomed all the way in. Bounds come from the
            -- engine FOV range, so the value can never leave acceptable limits.
            -- Disabled (greyed) unless the feature itself is on.
            type = "slider",
            name = GetString(SI_BAV_SETTING_DYNAMIC_FOV_NEAR_NAME),
            tooltip = GetString(SI_BAV_SETTING_DYNAMIC_FOV_NEAR_TOOLTIP),
            min = dynamicFovMin,
            max = dynamicFovMax,
            step = 1,
            decimals = 0,
            getFunc = function() return Settings.GetDynamicFovNearResolved() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.dynamicFovNear = value end
                Settings.ApplyOptionalFeatureConfig()
            end,
            default = dynamicFovMin,
            disabled = DynamicFovDisabled,
            width = "full",
            reference = "BAVSettingsDynamicFovNear",
        },
        {
            -- FOV applied when zoomed all the way out. Same engine-bounded range
            -- as the near value; spreading the two apart strengthens the effect,
            -- bringing them together softens it, equal values flatten it.
            type = "slider",
            name = GetString(SI_BAV_SETTING_DYNAMIC_FOV_FAR_NAME),
            tooltip = GetString(SI_BAV_SETTING_DYNAMIC_FOV_FAR_TOOLTIP),
            min = dynamicFovMin,
            max = dynamicFovMax,
            step = 1,
            decimals = 0,
            getFunc = function() return Settings.GetDynamicFovFarResolved() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.dynamicFovFar = value end
                Settings.ApplyOptionalFeatureConfig()
            end,
            default = dynamicFovMax,
            disabled = DynamicFovDisabled,
            width = "full",
            reference = "BAVSettingsDynamicFovFar",
        },
        {
            -- One-tap return to the engine endpoints (the widest, most neutral
            -- spread). Clears the saved overrides so near/far fall back to the
            -- resolved range again.
            type = "button",
            name = GetString(SI_BAV_SETTING_DYNAMIC_FOV_RESET_NAME),
            tooltip = GetString(SI_BAV_SETTING_DYNAMIC_FOV_RESET_TOOLTIP),
            func = function()
                local vars = Settings.GetSavedVars()
                if vars then
                    vars.dynamicFovNear = nil
                    vars.dynamicFovFar = nil
                end
                Settings.ApplyOptionalFeatureConfig()
            end,
            disabled = DynamicFovDisabled,
            width = "half",
            reference = "BAVSettingsDynamicFovReset",
        },
            },
        },
        {
            type = "submenu",
            name = GetString(SI_BAV_HEADER_CONTEXT_PRESETS),
            tooltip = GetString(SI_BAV_SECTION_CONTEXT_PRESETS_DESCRIPTION),
            controls = {
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_CONTEXT_PRESETS_DESCRIPTION),
            width = "full",
        },
        {
            type = "checkbox",
            name = GetString(SI_BAV_SETTING_PRESETS_ENABLED_NAME),
            tooltip = GetString(SI_BAV_SETTING_PRESETS_ENABLED_TOOLTIP),
            getFunc = function() return Settings.ArePresetsEnabled() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.presetsEnabled = value and true or false end
                Settings.ApplyOptionalFeatureConfig()
            end,
            width = "full",
            default = false,
            reference = "BAVSettingsPresetsEnabled",
        },
        {
            type = "slider",
            name = GetString(SI_BAV_SETTING_PRESET_INTENSITY_NAME),
            tooltip = GetString(SI_BAV_SETTING_PRESET_INTENSITY_TOOLTIP),
            min = 0,
            max = 100,
            step = 5,
            getFunc = function() return zo_round(Settings.GetPresetIntensity() * 100) end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.presetIntensity = private.ClampNumber(value / 100, 0, 1) end
                Settings.ApplyOptionalFeatureConfig()
            end,
            width = "full",
            default = 100,
            disabled = function() return not Settings.ArePresetsEnabled() end,
            reference = "BAVSettingsPresetIntensity",
        },
        {
            -- Purely cosmetic: ease state changes (spatial framing + FOV) over a
            -- short glide instead of snapping. Greyed out unless presets are on,
            -- mirroring the Dynamic FOV smoothing toggle above.
            type = "checkbox",
            name = GetString(SI_BAV_SETTING_PRESET_SMOOTH_NAME),
            tooltip = GetString(SI_BAV_SETTING_PRESET_SMOOTH_TOOLTIP),
            getFunc = function() return Settings.ArePresetTransitionsSmooth() end,
            setFunc = function(value)
                local vars = Settings.GetSavedVars()
                if vars then vars.presetSmoothTransitions = value and true or false end
                Settings.ApplyOptionalFeatureConfig()
            end,
            disabled = function() return not Settings.ArePresetsEnabled() end,
            width = "full",
            default = true,
            reference = "BAVSettingsPresetSmooth",
        },
            },
        },
        {
            type = "header",
            name = GetString(SI_BAV_HEADER_ACTIONS),
        },
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_ACTIONS_DESCRIPTION),
            width = "full",
        },
        {
            type = "button",
            name = GetString(SI_BAV_SETTING_PRINT_CONFIG_NAME),
            tooltip = GetString(SI_BAV_SETTING_PRINT_CONFIG_TOOLTIP),
            func = function() Settings.PrintConfiguration() end,
            width = "full",
            reference = "BAVSettingsPrintConfig",
        },
        {
            type = "button",
            name = GetString(SI_BAV_SETTING_RESET_CONFIG_NAME),
            tooltip = GetString(SI_BAV_SETTING_RESET_CONFIG_TOOLTIP),
            func = function() Settings.ResetConfigurationToDefaults() end,
            width = "half",
            isDangerous = true,
            warning = GetString(SI_BAV_SETTING_RESET_CONFIG_CONFIRM),
            reference = "BAVSettingsResetConfig",
        },
        {
            type = "button",
            name = GetString(SI_BAV_SETTING_RESET_CAMERA_NAME),
            tooltip = GetString(SI_BAV_SETTING_RESET_CAMERA_TOOLTIP),
            func = function() private.ResetCameraState() end,
            width = "half",
            isDangerous = true,
            warning = GetString(SI_BAV_SETTING_RESET_CAMERA_CONFIRM),
            reference = "BAVSettingsResetCamera",
        },
        {
            type = "description",
            text = GetString(SI_BAV_SETTING_RESET_CAMERA_NOTE),
            width = "full",
            reference = "BAVSettingsResetCameraNote",
        },
        {
            type = "submenu",
            name = GetString(SI_BAV_HEADER_DEBUG),
            tooltip = GetString(SI_BAV_SECTION_DEBUG_DESCRIPTION),
            controls = {
        {
            type = "description",
            text = GetString(SI_BAV_SECTION_DEBUG_DESCRIPTION),
            width = "full",
        },
        {
            type = "dropdown",
            name = GetString(SI_BAV_SETTING_DEBUG_MODE_NAME),
            tooltip = GetString(SI_BAV_SETTING_DEBUG_MODE_TOOLTIP),
            choices = debugChoices,
            choicesValues = {0, 1, 2, 3, 4},
            getFunc = function() return addon.debugMode end,
            setFunc = function(value) Settings.SetDebugMode(value, true) end,
            default = 0,
            width = "full",
            reference = "BAVSettingsDebugMode",
        },
            },
        },
        {
            type = "description",
            text = GetString(SI_BAV_PANEL_FOOTER),
            width = "full",
        },
    }

    -- Splice the per-state preset checkboxes into the Context Presets submenu,
    -- right after the intensity slider, so the panel layout stays declarative
    -- while the state list (PRESET_STATE_DEFINITIONS) remains a single source of
    -- truth. We locate the submenu by the intensity slider it contains rather
    -- than by position, so reordering sections above can't break it.
    for _, control in ipairs(optionsData) do
        if control.type == "submenu" and control.controls then
            local hasIntensity = false
            for _, child in ipairs(control.controls) do
                if child.reference == "BAVSettingsPresetIntensity" then
                    hasIntensity = true
                    break
                end
            end
            if hasIntensity then
                for _, stateControl in ipairs(BuildPresetStateControls()) do
                    control.controls[#control.controls + 1] = stateControl
                end
                break
            end
        end
    end

    local panel = lam:RegisterAddonPanel(panelIdentifier, panelData)
    lam:RegisterOptionControls(panelIdentifier, optionsData)
    Settings.panel = panel
end

-- Opens the settings panel programmatically (used by the `/bav settings`
-- slash sub-command). Returns true when the panel was opened, false when the
-- LibAddonMenu dependency is unavailable so the caller can report it.
function Settings.OpenPanel()
    local lam = LibAddonMenu2
    if not lam or not Settings.panel then
        return false
    end

    lam:OpenToPanel(Settings.panel)
    return true
end

addon.SetDebugMode = Settings.SetDebugMode
addon.PrintConfiguration = Settings.PrintConfiguration
addon.HandleConfigCommand = Settings.HandleConfigCommand
addon.RegisterSettingsPanel = Settings.RegisterSettingsPanel
addon.OpenSettingsPanel = Settings.OpenPanel
