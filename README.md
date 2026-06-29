# Bureau of Acceptable Views

A lightweight camera addon for *The Elder Scrolls Online*. It gives you back
control over the third-person camera in situations where the game normally
takes it away, and layers a few optional cinematic touches on top. Dynamic FOV
and velocity-reactive FOV are on out of the box for an eased, speed-aware feel;
everything else stays out of your way until you turn it on.

> **Compatibility:** API: LIVE 101050 / PTS 101050 · Optional: LibAddonMenu-2.0 (>= 43)
> for the settings panel, and LibSprint (>= 20260522) for bind-independent sprint detection
> (used by the context-preset and shoulder-swap sprint trigger; velocity FOV does
> not need it).

---

## What it does

The core feature is **free zoom in restricted states**. ESO locks the camera
to a fixed distance (or forces first person) in certain situations. This addon
lets you zoom freely between maximum zoom and first person in those states,
with optional persistence so your framing survives zone changes and relogs.

On top of that, several **optional** systems can shape the camera further:

- **Dynamic FOV** *(on by default)* - field of view follows your zoom distance.
- **Velocity FOV** *(on by default)* - field of view widens with your movement
  speed.
- **Context presets** *(off by default)* - cinematic framing per gameplay state.
- **Over-the-shoulder swap** *(off by default)* - swing the camera to one side.

Every optional system is fully inert until it is on, and the two FOV effects do
nothing on clients where the FOV property is unsupported.

---

## Features

### Free zoom in restricted states
- Zoom anywhere between max zoom and first person while the game would normally
  lock the camera.
- Configurable persistence: keep your zoom across zone changes and logins, or
  let it reset - your choice.
- Controller input safely falls back to the game's default camera handling, so
  nothing breaks if you play on a gamepad.

### Dynamic FOV *(optional, on by default)*
- Ties your third-person field of view to the current zoom distance: tighter
  when zoomed in, wider when zoomed out, smoothly interpolated in between.
- Only recalculates when the zoom distance actually changes - there is no
  per-frame work - so the framing stays consistent without ever touching a hot
  path.
- When disabled, your manual FOV is left exactly as the game set it.

### Velocity FOV *(optional, on by default)*
- Widens the field of view the faster you actually move, then eases back as you
  slow - a cinematic sense of speed.
- Driven by your **real movement speed**, derived from how far you travel between
  samples (every 150 ms, never per frame). Because it reads speed rather than a
  state, it responds to *any* source - sprint, mount, swimming, and speed buffs
  like Major Expedition or the Steed mundus - with nothing per-state to configure
  and no dependency on LibSprint.
- A **sensitivity** slider scales how strongly speed widens the lens.
- Composes cleanly with the rest: the boost is *added on top of* dynamic FOV, and
  it works on its own when dynamic FOV is off. If a context preset pins the FOV
  for your current state, the preset wins and the boost pauses until you leave it.
- Robust against the usual pitfalls of position-derived speed: a zone change or
  teleport re-baselines instead of spiking, lag snaps are rejected, and only
  horizontal movement counts (jumps and falls do not inflate it).
- An optional **on-screen debug overlay** (off by default, never printed to chat)
  shows your live speed, boost, and position - handy for tuning the sensitivity.
- When disabled, your manual FOV is left exactly as the game set it.

### Over-the-shoulder swap *(optional, off by default)*
- Swings the third-person camera over one shoulder for a focused, cinematic
  frame, and returns it to centre when it should.
- One **mode** selector chooses how it triggers:
  - **Auto** - swings automatically while you are in any state you pick (combat,
    stealth, mounted, swimming, sprint) and recentres when you leave them.
  - **Manual** - swings on demand via the `/bav shoulder` command
    (`left`/`right`/`center`, or no argument to toggle); the automatic behaviour
    is off in this mode.
- A **shoulder offset** slider sets how far the camera swings.
- While shoulder swap is on it takes over the shoulder from the stealth context
  preset, so the two never fight over the same setting - exactly one owns it.
- Your pre-swing shoulder is snapshotted and **persisted**, so a `/reloadui`,
  logout, or crash mid-swing hands your real framing back next session.

### Context presets *(optional, off by default)*
- Applies a fixed cinematic camera bundle for the state you are in - combat,
  werewolf, stealth, interaction (dialogue), mounted, swimming, or sprinting -
  and restores your own framing when you leave it.
- Entering a state is instant, but leaving one is briefly damped: a rapid
  out-and-back (combat ending and restarting a moment later) keeps the cinematic
  framing instead of snapping the camera around, so the view never jitters.
- The interaction state is the exception: entering it is briefly delayed, so
  flicking through a merchant or quick quest turn-in never pecks the camera -
  only a conversation you actually stay in reframes the shot.
- Exactly one state is active at a time, resolved by priority
  (werewolf → combat → stealth → interaction → mounted → swimming → sprint), so
  states never fight each other.
- A single global **intensity** slider scales every bundle, and each state has
  its own style choice plus an individual **intensity** slider that scales that
  state on top of the global value (0% = no effect, 100% = full style strength).
- Your pre-preset camera is snapshotted the first time a preset takes over and
  **persisted**, so a `/reloadui`, logout, or crash while a preset is active
  hands your real camera back next session instead of baking the preset's
  offsets into your settings.
- Open the game's settings while a preset is active and your camera quietly
  reverts to your real values for editing, then the preset re-applies on top of
  your changes when you close it - so tweaking FOV or distance never fights the
  active preset or gets baked into your saved framing.
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

### Conflict resilience *(automatic safety net)*
- Because BAV hooks the game's own first-person toggle, another addon that
  drives that toggle can, in rare cases, fight it and make the view flicker
  between first and third person. BAV watches for that: if the view flips back
  and forth at a rate no human could produce, it **steps its own handling
  aside** (passes the toggle straight to the game) to break the loop.
- The backoff is fully **reversible** and touches none of your saved settings -
  it clears the moment you relog or use `/bav reset`.
- When it triggers, a single **neutral** chat notice explains what happened and
  suggests disabling addons one at a time to find the source. It never names or
  blames another addon - a hooked function cannot reliably know who called it,
  so guessing would be misleading.
- The notice can be turned off in **Settings → Diagnostics** (the safety step
  itself always runs; the toggle only controls the chat message). `/bav
  selfcheck` always reports the current backoff status.
- A related case: some game states (notably ZOS's reworked **werewolf**) take
  over the camera distance and **reject** BAV's writes. Combined with another
  addon measuring the camera by toggling first person twice in one frame, this
  used to leave the view stuck in first person - re-forced on every manual
  zoom-out. BAV no longer tries to recognize and unwind such toggle pairs by
  timing. Instead, in the states it manages, a toggle only records **where the
  camera should end up** and a single write on the next frame moves it there
  (see *Convergent toggle handling* below). A measurement addon's toggle-and-back
  pair cancels out to no net change on its own, with no dependence on frame
  timing, and a rejected write is retried a bounded number of times rather than
  leaving the view half-moved. A sustained run of rejected camera-distance
  writes is surfaced by `/bav selfcheck`.
- **Known interaction: camera-probing addons.** Some addons (notably *Miat's
  PvP* / PvpAlerts) measure the camera by toggling first person several times in
  a single frame. With older BAV builds this could briefly force or stick the
  view in first person. The convergent toggle handling above neutralizes it on
  BAV's side - the probe cancels out to no net change - so the two run together
  with no special configuration. If a view ever feels stuck, `/bav reset`
  returns control immediately. A proper upstream fix (the probe only firing when
  its result is actually needed) would remove the interaction at the source.

---

## Why it's built well

- **No surprises.** Context presets and over-the-shoulder swap stay off until you
  enable them, and any disabled module is fully inert - it registers no events,
  runs no polling, and never writes to the camera. The two FOV effects ship on,
  but a single toggle each returns the camera to exactly what the game set.
- **One source of truth for engine I/O.** All camera reads and writes go
  through a single `CameraSettings` layer that handles the engine's value
  formatting and verifies every write by reading it back. A future client
  change needs fixing in exactly one place.
- **No FOV tug-of-war.** A dedicated `FovArbiter` makes field-of-view
  precedence explicit, so dynamic FOV, the velocity boost, and context presets
  can never overwrite each other depending on load order or timing - the boost
  adds onto the dynamic base, and a preset hold cleanly overrides both.
- **One owner per contested setting.** Just as `FovArbiter` owns the FOV, shoulder
  swap takes sole ownership of the shoulder offset while it is on, so it and the
  stealth preset never write the same value out of turn.
- **Convergent toggle handling.** In the states BAV manages, a first-person
  toggle does not write the camera on the spot. A dedicated `ZoomReconciler`
  records *where the camera should settle* and performs a single write on the
  next frame. This is correct by construction: another addon's toggle-and-back
  measurement pair cancels out to the same intent it started from, so the view
  never desyncs - and it does not matter whether those two toggles land in the
  same frame or not. There is no frame-timing guesswork to break in edge cases
  like the world map or a transformed state.
- **Nothing on the per-frame path.** Work happens only in response to real
  events - a zoom change, a state transition - or a coarse 150 ms sample for the
  things ESO exposes no event for (sprint state, movement speed); never every
  frame. The transient FOV/shoulder glides tear their own updater down the moment
  they land.
- **Recovers gracefully.** The pre-preset camera snapshot and the pre-swing
  shoulder are persisted, so an interrupted session never leaves cinematic
  offsets or a one-sided camera baked into your settings.
- **Catches its own regressions.** A pull-based self-check validates internal
  invariants and watches the footprint of its own tables at quiet moments,
  turning silent bugs into a single readable warning - without adding any
  per-frame cost.
- **Plays nicely with others.** BAV shares the game's first-person toggle with
  any addon that uses it. The convergent handling above means the rapid
  toggle-and-back pairs other addons use to measure the camera cancel out
  cleanly, and if it ever detects a runaway view flicker it steps its own
  handling aside - a reversible safety net that needs no configuration and never
  blames another addon.
- **Localized** with English and Russian strings, and a clean LibAddonMenu
  settings panel.

---

## Architecture at a glance

The addon is split into layers with **one-way dependencies**: upper layers know
about lower ones, never the reverse. Two rules anchor the whole design - *only*
`CameraSettings` talks to the engine, and *only* `FovArbiter` decides who owns
the field of view. Everything else is a consumer of those two contracts.

```
            Settings.lua            UI + SavedVariables - wires everything
                 │ Configure(...)
   ┌──────────┬──────────┬──────────┬───────────┬──────────────┐
   ▼          ▼          ▼          ▼           ▼              ▼
DynamicFov VelocityFov ContextPresets ShoulderControl   Free-zoom core
   │          │          │  ▲         │ (owns shoulder)  (BureauOf…Views.lua)
   │          │          │  ╎ GetDiagnostics() - read-only   ┌──────────────┐
   │          │          │  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤  SelfCheck   │
   └────┬─────┘          │                                   └──────────────┘
        ▼                │                          passive observer · writes nothing
   FovArbiter            │  single owner of FOV precedence
        │                │
        ▼                ▼
    CameraSettings          the only verified engine I/O
        │
        ▼
   GetSetting / SetSetting  raw engine API
```

Both FOV effects flow through `FovArbiter`: `DynamicFov` computes the base FOV
from zoom, `VelocityFov` pushes a speed boost, and the arbiter composes
`base + boost` while letting a context-preset hold override both. `ShoulderControl`
is the single owner of the shoulder offset whenever it is on, so `ContextPresets`
cedes that one setting to it. `SelfCheck` deliberately sits *beside* the I/O
hierarchy: a read-only observer that never writes to the camera or settings. It
lazily polls the other modules' diagnostics accessors and counts the entries in
BAV-owned tables, so it depends on no one and its absence changes nothing.

---

## Module overview

| Module | Responsibility |
| --- | --- |
| `BureauOfAcceptableViews.lua` | Core: free-zoom logic, event wiring, saved-variable lifecycle, slash commands. |
| `CameraSettings.lua` | The single, verified access layer for every engine camera setting. |
| `DynamicFov.lua` | Optional zoom-dependent field of view; composes a velocity boost on top. |
| `VelocityFov.lua` | Optional speed-reactive FOV boost from real movement speed, routed through the arbiter. |
| `FovArbiter.lua` | Single owner of third-person FOV precedence (dynamic + velocity vs. preset holds). |
| `ContextPresets.lua` | State-driven cinematic bundles with snapshot/restore and persistence. |
| `ShoulderControl.lua` | Optional over-the-shoulder swap (auto-by-state or manual); single owner of the shoulder offset. |
| `SelfCheck.lua` | Passive, pull-based invariant and footprint diagnostics; warn-only by default. |
| `Settings.lua` | SavedVariables, defaults, and the LibAddonMenu panel. |

---

## How it works

A few small maps of the moving parts. None of this is required reading to *use*
the addon - it is here for the curious and for anyone reading the source.

### State priority - only one preset wins

Context presets never fight each other. At most **one** state is active at a
time, resolved top-down by priority and gated by each state's style choice:
the first state that is both physically active *and* set to a style other than
Off wins.

```
   physical state(s) active ──▶  resolve by priority  ──▶  one winner
                                 ┌───────────────────┐
   highest  │  werewolf    ─────▶│ first active state │
            │  combat      ─────▶│ with a non-Off     │
            │  stealth     ─────▶│ style wins; rest   │──▶ apply bundle
            │  interaction ─────▶│ are ignored        │
            │  mounted     ─────▶│                    │
            │  swimming    ─────▶│                    │──▶ none? → restore
   lowest   │  sprint      ─────▶│                    │      your framing
                                 └───────────────────┘
```

Werewolf deliberately outranks combat - a transformation should win even mid-fight.

### Dynamic + velocity FOV - zoom and speed drive the lens

Two effects feed the field of view, and both flow through `FovArbiter` so they
compose instead of fighting. Dynamic FOV sets a **base** from the zoom distance;
velocity FOV adds a **boost** scaled by how fast you are actually moving. The
final FOV is `base + boost`, and a context-preset hold overrides the whole thing
while it is active.

```
   zoom distance ─▶ DynamicFov ─▶ base FOV ┐
                                            ├─▶ FovArbiter ─▶ base + boost ─▶ FOV
   world-position ─▶ VelocityFov ─▶ boost ──┘        │
   delta (150ms)     (speed → degrees)               └─ unless a preset hold
                                                         owns FOV (then it wins)
```

Velocity FOV reads movement speed from how far you travel between 150 ms samples
(never per frame); it re-baselines across zone changes, rejects teleport/lag
spikes, and counts only horizontal travel. When dynamic FOV is off, the boost
rides on top of your manual FOV instead of a zoom-derived base.

### Over-the-shoulder - one owner for the shoulder

When shoulder swap is on it owns the shoulder offset outright. In **auto** mode it
swings while any chosen state is active and recentres when you leave them all; in
**manual** mode `/bav shoulder` drives it. Either way, `ContextPresets` cedes the
shoulder so the two never write it out of turn.

```
   mode = auto                              mode = manual
   ┌───────────────────────┐               ┌───────────────────────┐
   │ in a chosen state? ───▶│ swing to side │ /bav shoulder ───────▶│ swing / toggle
   │ left them all?    ───▶│ recentre      │ (left/right/center)    │
   └───────────────────────┘               └───────────────────────┘
        │ first swing: snapshot + persist your real shoulder ──▶ restored on
        │                                                        recentre / crash
        └─ ContextPresets.OwnsShoulder()? → stealth preset skips shoulder
```

### Snapshot & restore - surviving a crash

The first time a preset takes over, your real camera is snapshotted **and
persisted** to SavedVariables. So even a `/reloadui`, logout, or crash mid-preset
hands your genuine framing back next session - never the preset's offsets.

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

### Self-check - quiet until something's wrong

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
