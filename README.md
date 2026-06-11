# Bureau of Acceptable Views

A lightweight camera addon for *The Elder Scrolls Online*. It gives you back
control over the third-person camera in situations where the game normally
takes it away, and layers a few optional cinematic touches on top. Dynamic FOV
is on out of the box for an eased zoom feel; everything else stays out of your
way until you turn it on.

> **Compatibility:** API: LIVE 101050 / PTS 101050 · Optional: LibAddonMenu-2.0 (>= 43)
> for the settings panel.

---

## What it does

The core feature is **free zoom in restricted states**. ESO locks the camera
to a fixed distance (or forces first person) in certain situations. This addon
lets you zoom freely between maximum zoom and first person in those states,
with optional persistence so your framing survives zone changes and relogs.

On top of that, two **optional** systems can shape the camera further. Dynamic
FOV is enabled by default (it does nothing on clients where the FOV property is
unsupported); context presets stay disabled until you switch them on.

---

## Features

### Free zoom in restricted states
- Zoom anywhere between max zoom and first person while the game would normally
  lock the camera.
- Configurable persistence: keep your zoom across zone changes and logins, or
  let it reset — your choice.
- Controller input safely falls back to the game's default camera handling, so
  nothing breaks if you play on a gamepad.

### Dynamic FOV *(optional, on by default)*
- Ties your third-person field of view to the current zoom distance: tighter
  when zoomed in, wider when zoomed out, smoothly interpolated in between.
- Only recalculates when the zoom distance actually changes — there is no
  per-frame work — so the framing stays consistent without ever touching a hot
  path.
- When disabled, your manual FOV is left exactly as the game set it.

### Context presets *(optional, off by default)*
- Applies a fixed cinematic camera bundle for the state you are in — combat,
  werewolf, stealth, mounted, or sprinting — and restores your own framing the
  moment you leave it.
- Exactly one state is active at a time, resolved by priority
  (werewolf → combat → stealth → mounted → sprint), so states never fight each
  other.
- A single global **intensity** slider scales every bundle, and each state has
  its own enable toggle.
- Your pre-preset camera is snapshotted the first time a preset takes over and
  **persisted**, so a `/reloadui`, logout, or crash while a preset is active
  hands your real camera back next session instead of baking the preset's
  offsets into your settings.
- An **emergency restore** button in the settings panel instantly returns the
  camera to your control if anything ever feels stuck.

### Self-check diagnostics
- A passive reliability layer that validates the addon's own invariants and
  watches the footprint of BAV-owned tables for runaway growth, so a silent
  regression surfaces as a one-line warning instead of a mystery bug report.
- Costs nothing during play: it never runs per frame and never polls. Checks
  fire only at naturally-quiet moments (load, zone change) or on demand via
  `/bav selfcheck`, and the automatic pass stays completely silent unless
  something is actually wrong.
- Skips itself entirely while you are in combat, so a check never lands on a
  busy moment.

---

## Why it's built well

- **No surprises.** Context presets stay off until you enable them, and any
  disabled module is fully inert — it registers no events, runs no polling, and
  never writes to the camera. Dynamic FOV ships on, but a single toggle returns
  the camera to exactly what the game set.
- **One source of truth for engine I/O.** All camera reads and writes go
  through a single `CameraSettings` layer that handles the engine's value
  formatting and verifies every write by reading it back. A future client
  change needs fixing in exactly one place.
- **No FOV tug-of-war.** A dedicated `FovArbiter` makes field-of-view
  precedence explicit, so dynamic FOV and context presets can never overwrite
  each other depending on load order or timing.
- **Nothing on the per-frame path.** Work happens only in response to real
  events — a zoom change, a state transition — never every frame.
- **Recovers gracefully.** The pre-preset camera snapshot is persisted, so an
  interrupted session never leaves cinematic offsets baked into your settings.
- **Catches its own regressions.** A pull-based self-check validates internal
  invariants and watches the footprint of its own tables at quiet moments,
  turning silent bugs into a single readable warning — without adding any
  per-frame cost.
- **Localized** with English and Russian strings, and a clean LibAddonMenu
  settings panel.

---

## Architecture at a glance

The addon is split into layers with **one-way dependencies**: upper layers know
about lower ones, never the reverse. Two rules anchor the whole design — *only*
`CameraSettings` talks to the engine, and *only* `FovArbiter` decides who owns
the field of view. Everything else is a consumer of those two contracts.

```
            Settings.lua            UI + SavedVariables — wires everything
                 │ Configure(...)
   ┌─────────────┼────────────────┐
   ▼             ▼                ▼
DynamicFov   ContextPresets   Free-zoom core (BureauOfAcceptableViews.lua)
   │             │  ▲
   │             │  ╎ GetDiagnostics() — read-only    ┌──────────────┐
   │             │  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤  SelfCheck   │
   └──────┬──────┘                                    └──────────────┘
          ▼                                       passive observer · writes nothing
      FovArbiter            single owner of FOV precedence
          │
          ▼
    CameraSettings          the only verified engine I/O
          │
          ▼
   GetSetting / SetSetting  raw engine API
```

`SelfCheck` deliberately sits *beside* the I/O hierarchy: it is a read-only
observer that never writes to the camera or settings. It lazily polls the other
modules' diagnostics accessors and counts the entries in BAV-owned tables, so it
depends on no one and its absence changes nothing.

---

## Module overview

| Module | Responsibility |
| --- | --- |
| `BureauOfAcceptableViews.lua` | Core: free-zoom logic, event wiring, saved-variable lifecycle, slash commands. |
| `CameraSettings.lua` | The single, verified access layer for every engine camera setting. |
| `DynamicFov.lua` | Optional zoom-dependent field of view. |
| `FovArbiter.lua` | Single owner of third-person FOV precedence. |
| `ContextPresets.lua` | State-driven cinematic bundles with snapshot/restore and persistence. |
| `SelfCheck.lua` | Passive, pull-based invariant and heap diagnostics; warn-only by default. |
| `Settings.lua` | SavedVariables, defaults, and the LibAddonMenu panel. |

---

## How it works

A few small maps of the moving parts. None of this is required reading to *use*
the addon — it is here for the curious and for anyone reading the source.

### State priority — only one preset wins

Context presets never fight each other. At most **one** state is active at a
time, resolved top-down by priority and gated by each state's enable toggle:
the first state that is both physically active *and* enabled wins.

```
   physical state(s) active ──▶  resolve by priority  ──▶  one winner
                                 ┌───────────────────┐
   highest  │  werewolf  ───────▶│ first active &     │
            │  combat    ───────▶│ enabled state      │──▶ apply bundle
            │  stealth   ───────▶│ wins; the rest     │
            │  mounted   ───────▶│ are ignored        │
   lowest   │  sprint    ───────▶│                    │──▶ none? → restore
                                 └───────────────────┘      your framing
```

Werewolf deliberately outranks combat — a transformation should win even mid-fight.

### Dynamic FOV — zoom drives the lens

When enabled, your field of view tracks the zoom distance: tight when zoomed in,
wide when zoomed out, linearly interpolated between. It recalculates **only when
the distance actually changes** — never per frame — and yields to a preset hold.

```
   zoom in  ◀─────────────── distance ───────────────▶  zoom out
   │                                                            │
   ▼                                                            ▼
 narrow FOV ◀───── linear interpolation (near ↔ far) ─────▶ wide FOV
   │                                                            │
   └──────────────▶ request to FovArbiter ◀────────────────────┘
                    (applied only if no preset hold owns FOV)
```

### Snapshot & restore — surviving a crash

The first time a preset takes over, your real camera is snapshotted **and
persisted** to SavedVariables. So even a `/reloadui`, logout, or crash mid-preset
hands your genuine framing back next session — never the preset's offsets.

```
  preset takes over          session ends abruptly         next login
  ┌──────────────┐           ┌──────────────────┐          ┌──────────────┐
  │ snapshot live│           │ /reloadui · crash│          │ recover from │
  │ camera  ─────┼──persist──▶│ logout while a   │──saved──▶│ persisted    │
  │ to SavedVars │           │ preset is active │          │ snapshot,    │
  └──────────────┘           └──────────────────┘          │ then clear it│
        │                                                   └──────────────┘
        └─ back to default in-session ──▶ restore + clear ─────────┘
```

This breaks the drift cycle where a dirty (offset) camera would otherwise be
saved as the new baseline.

### Self-check — quiet until something's wrong

A pull-based reliability pass: it runs at load and zone change (or on demand via
`/bav selfcheck`), validates internal invariants, samples the footprint of
BAV-owned tables, and stays **completely silent** unless something is actually
broken. It skips itself in combat and never touches the camera.

```
   trigger (PULL only)            checks (read-only)            output
   ┌────────────────────┐        ┌────────────────────┐
   │ load / zone change  │        │ orphaned FOV hold  │       healthy
   │   → in combat? skip │───────▶│ snapshot coherence │──────▶  silence
   │ /bav selfcheck      │        │ sprint-poll leak   │
   │   → verbose report  │        │ slot leak          │       problem
   └────────────────────┘        │ footprint growth   │──────▶  one-line
                                  └────────────────────┘         warning
```

Verbose mode (`/bav selfcheck`) additionally prints footprint figures and an
explicit "all invariants OK".

---

## A note on AI assistance

During the development of this addon, the AI assistant Claude Opus 4.8 was
utilized in a strictly technical capacity. Its role was limited to debugging,
Lua optimization, performance tuning, and preventing potential memory leaks or
unsafe code practices. All AI-assisted code has been manually reviewed, tested,
and verified by the developer.

**P.S.** If the mere mention of AI makes you panic, this addon might not be for
you. Otherwise, rest assured: stability and performance are polished to the
highest standard, ensuring zero noticeable impact on your FPS or game memory.
