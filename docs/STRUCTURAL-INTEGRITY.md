# VOXIVERSE — Structural Integrity Model

> **⚠ Reconciled — read alongside `docs/INTEGRATION-DECISIONS.md`.**
> The §2.5 "pick an anchor triple" step is now driven by the **normative `(ρ,C,T)→(P,H,D)`
> converter** (INTEGRATION-DECISIONS §1.2 stress branch, §1.3 soil/cohesion branch; pinned
> constants βc=log₂(16/9), βt=log₃2, k_s=1.5, κ_brittle=⅓) — the (P,H,D) calibration here is
> unchanged and the converter reproduces it exactly. The §4 joint formulas gain a **participation
> factor `att_A·att_B`** on tension/shear/moment only (default 1.0 ⇒ calibration untouched;
> sand/gravel 0.0 ⇒ falling sand), and §4.3 contact-area/fill-fraction are re-keyed to the
> **modifier axis** (`density(LRID) × ShapeCodec.volume(modifier)`; VDS §13.3).

Design for replacing the pure-connectivity collapse pass
(`WorldManager._collapse_unsupported`) with a real load-bearing analysis:
per-material compressive strength, per-joint attachment (tension + shear +
bending), neighbour bracing, temperature-dependent attachment (read through
`PerVoxelEnvironment`), per-joint reinforcement, and a bounded structural
solver that decides which cells of an arbitrary structure stay put and which
detach as `VoxelBody` debris.

**Status: design only.** No engine code exists yet; §10 gives the phases.

---

## 1. Model overview

Every solid cell is a node; every pair of 6-adjacent solid cells shares a
**joint** (a 1 m² face). Gravity gives each cell a weight `w = m·g`
(`g = 9.81`, masses from `BlockCatalog`). A structure stands iff the weight of
every cell can be routed to the *foundation* (the untouched terrain bulk)
through a network of load paths whose elements stay within capacity:

| Load path | Physical meaning | Capacity |
|---|---|---|
| **down** through a cell | compression: the cell below carries you | the bearing cell's compressive capacity `σ_c_eff` (a *node* property) |
| **sideways** through a joint | shear: a cantilever/bridge hands weight to a pier | joint shear capacity `F_s` |
| **up** through a joint | tension: a block hangs from the block above | joint tensile capacity `F_t` |
| bending at an overhang's root | moment: the lever tries to peel the joint open | joint moment capacity `M₀` |

This is a *lower-bound (static) limit analysis*: if **any** equilibrium
distribution of forces exists with every element within capacity, the
structure is declared stable (lower-bound theorem of plasticity). Finding
"does such a distribution exist" is exactly a **max-flow feasibility**
problem (§5), and the min-cut of an infeasible flow is the physically
weakest break surface — the joints that snap and the cells that crush.

Three design invariants:

1. **Path-agnostic.** The solver reads cells only via
   `WorldManager.block_id_at(cell)` (architectural rule 1) and temperatures
   only via `PerVoxelEnvironment` (rule 2). It never touches geometry, so it
   is identical for the godot_voxel and fallback render paths.
2. **The three anchor numbers per material emerge** from three per-material
   strengths; they are not special-cased anywhere (§2).
3. **Never worse than today.** Pass 0 of the solver *is* today's
   connectivity flood; every later pass only finds *additional* failures.
   Tree-chop (canopy detach) is decided by pass 0 exactly as it is now.

---

## 2. Per-material parameters and calibration

### 2.1 The parameter set

Three per-material strengths, all in Newtons for a full 1 m² face / 1 m³
cell (see §4.3 for how they become stresses for partial sub-voxel blocks):

| Symbol | Name | Governs | VoxelState field |
|---|---|---|---|
| `σ_c` | compressive capacity | max weight routed *through* a cell before it crushes | `strength_compressive` |
| `σ_t` | attachment, tensile | joint pulled apart along its normal (dangling blocks) | `strength_tension` |
| `σ_s` | attachment, shear | joint loaded across its plane (horizontal lines, bridges) | `strength_shear` |

Plus one **derived** quantity (not a free parameter, see §2.4):

```
M₀ = σ_s · H / 2  =  σ_s² / (2·m·g)        # joint face moment capacity, N·m
```

### 2.2 Calibration: anchors → parameters (the inversion)

The anchors are, per material at surface temperature with no reinforcement:

* `P` — max pillar height above a block before the block crushes,
* `H` — max horizontal line length attached to a wall,
* `D` — max dangling column length hanging below an anchor.

Failure analysis of each canonical structure (block weight `w = m·g`):

* **Pillar.** A block with `N` blocks above it receives a routed-through
  load `N·w`. It stands iff `N·w ≤ σ_c`. Binding exactly at `N = P`:

  ```
  σ_c = P · m · g
  ```

* **Dangling column.** A chain of `N` blocks hanging below an anchor loads
  the *top* joint in pure tension with `N·w`. Binding at `N = D`:

  ```
  σ_t = D · m · g
  ```

* **Horizontal line.** A line of `N` blocks off a wall loads the root joint
  with shear `V = N·w` **and** moment `M = w·N²/2` (block `i` has its centre
  `i − ½` from the wall face; `Σ(i−½) = N²/2`). We require *both* checks to
  bind at `N = H` simultaneously:

  ```
  σ_s = H · m · g                       (shear binds at H)
  M₀  = m·g·H²/2 = σ_s·H/2              (moment binds at H too)
  ```

  Because `M₀` is pinned by the same anchor as `σ_s`, it is a derived
  quantity, not a fourth parameter. The moment check is redundant for the
  straight calibration line but adds real constraints for unbalanced
  structures the shear check alone would miss (§5.5).

Equivalently: **`(P, H, D)` are the material's dimensionless
strength-to-weight ratios** (capacities in units of own block weight), and
the absolute capacities are just `anchor × m × g`. This is the physical
signature the anchors encode: stone has enormous absolute strengths but a
*low* tensile strength-to-weight (4) — brittle masonry; wood is absolutely
weak but has high specific strength (16 in tension) — timber; dirt is weak
everywhere.

### 2.3 Why one "attachment strength" scalar is impossible

If a single tensile capacity `A` had to explain both anchors via a global
face lever arm `z` (`A = D·w` from dangling, `A·z = w·H²/2` from bending),
then `z = H²/(2D)` would have to be material-independent. It is not:
dirt → 2.0, wood → 18.0, stone → 4.5. Wood is disproportionately good at
cantilevers relative to its dangling strength. Hence attachment must split
into tension (`σ_t`) and shear (`σ_s`); the product owner's "attachment
strength" is realised as this pair (both averaged, both
temperature-scaled, both reinforced identically — so it still *behaves*
like one knob per joint).

### 2.4 Parameter table (calibrated, verified)

`g = 9.81`. Anchors for grass and leaf are assigned by archetype (§2.5).

| material | m (kg) | (P, H, D) | w (N) | σ_c (N) | σ_t (N) | σ_s (N) | M₀ (N·m) |
|---|---|---|---|---|---|---|---|
| dirt  | 900  | (4, 2, 1)   | 8 829   | 35 316   | 8 829  | 17 658 | 17 658 |
| grass | 750  | (4, 2, 1)   | 7 357.5 | 29 430   | 7 357.5| 14 715 | 14 715 |
| stone | 1500 | (64, 6, 4)  | 14 715  | 941 760  | 58 860 | 88 290 | 264 870 |
| wood  | 80   | (36, 24, 16)| 784.8   | 28 252.8 | 12 556.8| 18 835.2 | 226 022.4 |
| leaf  | 100  | (4, 3, 2)   | 981     | 3 924    | 1 962  | 2 943  | 4 414.5 |

Forward verification (numerically confirmed): for every row, a pillar of
`P` above stands and `P+1` crushes; a dangling column of `D` holds and
`D+1` snaps the top joint; a horizontal line of `H` passes both the shear
and moment checks and `H+1` fails both. **The model reproduces 4/2/1 (dirt),
36/24/16 (wood), 64/6/4 (stone) exactly.**

### 2.5 Deriving parameters for new materials (the self-serve method)

This is the contract the Minecraft-parity catalog workstream
(`docs/WORLDGEN-CATALOG.md`) consumes. For each new block:

1. Pick the block's mass `m` (kg per full voxel) as today.
2. Pick an **anchor triple `(P, H, D)`** — three small integers with direct
   in-game meaning ("how tall a pillar / long a shelf / deep a hanging
   chain"). Use the archetype table as a starting point and tune per block:

   | archetype | (P, H, D) guidance | examples |
   |---|---|---|
   | loose soil / granular | (3–5, 1–2, 0–1) | dirt, grass, sand (D=0: never hangs), gravel |
   | masonry / rock | (48–96, 4–8, 2–5) | stone, cobble, brick, obsidian (high P) |
   | timber / plants | (24–48, 16–32, 8–20) | wood, planks, bamboo |
   | foliage / soft | (2–6, 2–4, 1–3) | leaf, wool, snow layer |
   | metal | (128–256, 48–96, 32–64) | iron block, rails as attachments |
   | brittle sheet | (8–16, 2–4, 1–2) | glass, ice (plus φ curve, §4.1) |

3. Everything else is computed: `σ_c = P·m·g`, `σ_t = D·m·g`,
   `σ_s = H·m·g`, `M₀ = σ_s·H/2`.
4. Pick a **structural class** (`&"soil"`, `&"rock"`, `&"timber"`,
   `&"foliage"`, `&"metal"`, `&"brittle"`) selecting the temperature curve
   φ (§4.1).

Note the anchors are *per block*, not per density: a denser variant of the
same archetype keeps its `(P, H, D)` and its absolute strengths scale with
mass automatically — heavy materials are absolutely stronger but no better
relative to their own weight.

---

## 3. Neighbour bracing (compressive reinforcement)

Requirement 1: a block's durability increases with supporting neighbours.
Two mechanisms provide this, one explicit and one emergent:

* **Explicit bracing factor.** The effective compressive capacity of a cell:

  ```
  σ_c_eff = σ_c · (1 + β · N_lat),      β = 0.75
  N_lat   = count of the 4 lateral solid neighbours that are themselves
            column-supported (have their own unbroken path of solid cells
            straight down to foundation)
  ```

  Isolated pillar cell → ×1 (so the pillar anchors calibrate against the
  *unbraced* `σ_c` — the anchor structures are 1-wide by definition);
  fully embedded cell → ×4. A 2×2 pillar's cells each have 2 braced
  neighbours → ×2.5, so a 2×2 dirt pillar bears 10 courses instead of 4.
  The "column-supported" requirement stops two floating stubs from bracing
  each other. Physical basis: confined/laterally-restrained compression
  (soil confinement, masonry load spreading).

* **Emergent load sharing.** The flow solver (§5) routes weight through
  *all* available paths: a cell over a void sheds part of its load
  sideways through shear joints into neighbouring columns. Wide footings
  genuinely spread load — no extra rule needed.

* **Confined-bulk exemption.** A *pristine* cell (generated, unedited) with
  all 6 neighbours solid gets `σ_c_eff = ∞`. The untouched bulk is
  pre-equilibrated and fully confined; compression failure only initiates
  at free surfaces (cells with at least one air neighbour, which keep their
  normal braced capacity). Without this, the analytic column check would
  "discover" that 40 m of overburden crushes deep dirt — true for
  unconfined dirt, false for confined bulk, and fatal for gameplay.
  Consequence (intended, emergent): a 64-block stone pillar placed on
  grass **punches through the soil** — the exposed grass/dirt shell
  (braced capacity ≈ 118 kN) crushes under ≈ 956 kN, the pillar drops as a
  `VoxelBody` and comes to rest deeper (the stone layer, braced ≈ 3.8 MN,
  holds it). The stone pillar anchor is therefore verified on exposed
  *stone* ground (§8).

---

## 4. Joints: the attachment model

A joint exists between every pair of 6-adjacent solid cells. Its capacities:

```
F_t(joint) = a · [ ½·(σ_t,A·φ_A(T) + σ_t,B·φ_B(T)) · k_R + R_t·φ_R(T) ]
F_s(joint) = a · [ ½·(σ_s,A·φ_A(T) + σ_s,B·φ_B(T)) · k_R + R_s·φ_R(T) ]
M₀(joint)  = a^(3/2) · [ ½·(M₀,A·φ_A(T) + M₀,B·φ_B(T)) · k_R + R_s·φ_R(T)·½ ]
```

where:

* `A`, `B` — the two cells' materials. **Different-material joints use the
  arithmetic mean of the two per-material strengths** (requirement 2), with
  each side's temperature factor applied *before* averaging so a wood–stone
  joint in a fire fails on the wood side's collapse, not on an averaged
  fiction. For same-material joints the mean degenerates to the material
  value, so the §2 calibration is untouched.
* `T` — joint temperature = mean of `PerVoxelEnvironment.temperature()` at
  the two cell centres. `φ` — the temperature factor (§4.1).
* `k_R`, `R_t`, `R_s`, `φ_R` — reinforcement (§4.2). Unreinforced:
  `k_R = 1`, `R = 0`.
* `a` — contact area fraction ∈ [0, 1], full blocks `a = 1` (§4.3).

Worked mixed-joint example: a stone block hanging under a wood block.
`F_t = ½·(12 556.8 + 58 860) = 35 708 N`; one stone block weighs 14 715 N,
so **2** stone blocks can dangle under wood (29 430 ≤ 35 708) and a third
snaps the joint (44 145 > 35 708).

`break_force` on `VoxelState` is untouched: it remains the *tool-facing*
"how hard is this to mine" number, orthogonal to structural strength.

### 4.1 Temperature function φ(T)

Requirement: attachment strength is a function of environment temperature,
read through `PerVoxelEnvironment`; calibration must hold at standard
surface temperature. Design:

```
             ┌ φ_frost                                   T ≤ T_frost_full
             │ 1 + (φ_frost−1)·(T_cold_on−T)/(T_cold_on−T_frost_full)
     φ(T) =  ┤                                           T_frost_full < T < T_cold_on
             │ 1                                          T_cold_on ≤ T ≤ T_hot_on   (the plateau)
             │ max(φ_min, 1 − (T−T_hot_on)/(T_fail−T_hot_on))
             └                                            T > T_hot_on
```

* **The plateau maps to φ = 1, and for every class it covers at least
  `[0 °C, 35 °C]`** (`T_cold_on = 0 °C` globally; the per-class `T_hot_on`
  values below are all ≥ 50 °C). This is deliberate and load-bearing: the
  *entire current world* —
  air 21.5 °C, sun-warmed surface 23 °C, deep ground trending to 12 °C —
  sits inside the plateau, so the anchor numbers hold **everywhere** today
  (a dangling chain deep in a mine behaves identically to one at the
  surface). Temperature effects only appear once future content (lava, ice
  biomes, fire) pushes T outside the band. Zero behavioural risk now, real
  hook later.
* **Cold strengthens moisture-bearing materials** (ice cementation —
  permafrost is effectively rock): soils get `φ_frost = 3.0` ramping over
  `[−10 °C, 0 °C]`. Rock/metal/timber ≈ 1 when frozen (timber 1.05).
* **Heat weakens everything**, ramping linearly from the per-class
  `T_hot_on` down to the floor `φ_min = 0.05` at the per-class failure
  temperature `T_fail` (never exactly 0 — fully melting/charring is the
  state machine's job, `VoxelStateTransition`, not the structural model's):

  | class | φ_frost | T_hot_on (°C) | T_fail (°C) |
  |---|---|---|---|
  | soil (dirt, grass) | 3.0 | 150 | 800 |
  | rock (stone) | 1.0 | 600 | 1200 |
  | timber (wood) | 1.05 | 100 | 300 |
  | foliage (leaf) | 1.2 | 50 | 150 |
  | metal | 1.0 | 400 | 1200 |
  | brittle (glass, ice) | ice: melts — its φ curve *is* its identity: φ=1 below −5 °C, ramp to φ_min at 0 °C | | |

φ multiplies `σ_t`, `σ_s` and `M₀` (M₀ is derived from σ_s, so it scales
once, with σ_s). `σ_c` is temperature-independent in v1 (the requirement
names attachment only); flagged as a natural extension.

### 4.2 Reinforcement (glue, cement, weld, …)

Reinforcement is a **per-joint** modifier: `{k_mult, R_t, R_s, T_fail_R}` —
a multiplier on the averaged material term plus an additive term with its
*own* heat ramp `φ_R` (linear 1 → 0 over `[T_fail_R − 50, T_fail_R]`), so
glue softens long before the glued stone does. Default table:

| id | name | k_mult | R_t (N) | R_s (N) | T_fail_R (°C) | character |
|---|---|---|---|---|---|---|
| 1 | glue | 1.0 | +10 000 | +10 000 | 90 | cheap, strong until warm |
| 2 | cement | 1.0 | +40 000 | +40 000 | 500 | masonry: stone+cement line goes H = ⌊(88 290+40 000)/14 715⌋ = 8 |
| 3 | weld | 2.0 | 0 | 0 | 800 | metal-only (gated on class), scales with the base material |
| 4 | rebar spike | 1.5 | +15 000 | +15 000 | 600 | mixed |

Interaction with averaging (requirement 2): additive terms are
material-independent (a glue line's strength doesn't care what it glues);
multiplicative terms amplify the *averaged* base, so welding a strong-weak
pair helps less than welding two strong blocks — intended.

Storage: §7. One reinforcement per joint (placing a new one replaces the
old); breaking either block deletes the joint's entry.

### 4.3 Contact-area factor (sub-voxel seam)

Every joint capacity above carries the factor `a` = contact area fraction.
For today's full blocks `a = 1` always. The sub-voxel partial-fill
workstream (`docs/SUB-VOXEL-SMOOTHING.md`) plugs in here: partial cells have
mass `density × fill_fraction` (they already own that) and their joints get
`a` = the overlapping face area of the two partial shapes, with **`a = 0`
(zero overlap) meaning no joint at all**. Force capacities scale linearly
with `a`; moment capacity scales `a^(3/2)` (section modulus ∝ width×height²;
shrinking both dimensions by √a gives a^{3/2}). **Assumption flagged:** the
sub-voxel workstream exposes a
`contact_area(cell_a, cell_b) -> float` query; until it lands, the solver
hardcodes 1.0 behind one function.

---

## 5. The structural solver

`sim/structural_solver.gd`, invoked by `WorldManager` on **break and place**
(place is new — an over-tall pillar must crush on placement; today
`place_block` never runs any collapse pass). One bounded, event-driven,
deterministic solve; nothing runs per-frame.

### 5.1 Region

Base region: today's box (`_COLLAPSE_RADIUS = 5` columns, same y-bounds
logic). **Plus adaptive expansion:** the connected component of *edited*
cells (`_edits[c] > 0`) touching the base box is pulled in whole (flood
over the sparse `_edits` dict, capped at 4096 cells; over the cap →
degrade to today's connectivity-only behaviour for safety). This is
mandatory, not an optimisation: wood's anchors (24-long cantilevers,
16-deep chains) are far larger than radius 5, and without expansion the
box boundary would falsely "support" any player build bigger than the box
(the exact conservative-seeding rule that is right for infinite pristine
terrain is wrong for finite player structures). Pristine terrain keeps the
radius-5 box and boundary seeding unchanged.

**Foundation set** = solid cells on the pristine region boundary shell +
bottom row (exactly today's seed rule).

### 5.2 Pass 0 — connectivity (today's flood, unchanged)

Flood from the foundation through solid 6-neighbours. Components never
reached are floating → detach immediately (grouped and spawned exactly as
today). *This is what detaches a chopped tree's canopy — that behaviour is
decided here, before any strength math, so it cannot regress.* If the flood
reached everything **and** pass 1 is clean, the solve ends here — the
common flat-dig case stays O(region), same as today.

### 5.3 Pass 1 — column fast path (cheap screen)

One top-down scan per column, memoised:

* `column_supported(c)`: an unbroken chain of solid cells from `c` straight
  down to foundation (also feeds `N_lat` in §3).
* Accumulate the column load top-down; check `load ≤ σ_c_eff` at each cell.

If every solid cell is column-supported and no cell is over capacity:
**done, nothing falls.** This covers flat digging, walls, towers, all
ground-supported building — the overwhelming majority of edits never reach
pass 2. Both kinds of finding escalate to pass 2, not straight to
resolution: cells *without* column support (overhangs, hanging chains,
bridges) obviously need the flow, but so do **column overloads** — a
pillar leaning against a wall can legitimately shed its excess sideways
through shear joints, so only the flow's verdict crushes a cell (an
*isolated* over-tall pillar has no lateral joints, the flow fails, and the
P anchor still binds exactly). The flow graph is restricted to the
connected neighbourhood of the flagged cells.

### 5.4 Pass 2 — flow feasibility (the real solver)

Build a directed graph over the non-foundation solid cells of the affected
neighbourhood:

* **Node splitting** for crush: each cell becomes `in → out` with capacity
  `σ_c_eff` (∞ for confined pristine bulk, §3).
* **Edges** from `out(u)`:
  * to `in(below)` with capacity ∞ (compression is limited by the bearing
    *node*, not the face),
  * to `in(lateral)` with capacity `F_s(joint)` (§4),
  * to `in(above)` with capacity `F_t(joint)`.
* **Sources:** every cell injects its own weight `w_i` (plus, later,
  live loads — the player's ~700 N standing force is a cheap add here).
  **Sink:** the foundation. When the graph is the *restricted* pass-1
  neighbourhood, healthy supported columns on its rim enter as sink
  proxies with **residual** capacity `σ_c_eff − load already borne by the
  column` (from the pass-1 scan), so rerouted weight cannot overload a
  column that pass 1 already certified near its limit.

Run Dinic max-flow with integer capacities (Newtons rounded to int — keeps
the web build deterministic across float paths; iteration order sorted).
`max_flow == Σ w_i` → statically admissible → stable (subject to pass 3).
Otherwise the **min-cut is the break surface**: cut lateral/up edges are
joints that snap; cut `in→out` node edges are cells that **crush** (the
crushed cell itself becomes debris — it "crumbles" and joins the falling
cluster). Proceed to §5.5.

Anchor behaviours in flow terms: a dangling chain routes its whole weight
up through the top joint (tension binds at `D`); a horizontal line routes
sideways joint-by-joint, the root carrying `H·w` (shear binds at `H`); a
bridge between two piers splits its weight both ways, so a span of ~`2H`
stands — arch action for free.

### 5.5 Pass 3 — moment audit (bending of overhang lobes)

Force flow alone ignores torque. For each **lobe** — a connected component
of cells lacking column support, attached to the supported set through an
interface joint set `J`:

```
overturning:  M_g = | Σ_lobe w_i · d_i |    d_i = SIGNED horizontal distance of
                                            cell i from the interface centroid
                                            axis (far-side cells restore)
resisting:    M_r = Σ_J [ F_t(j)·arm(j) + M₀(j) ]
```

Axis: horizontal line through the interface centroid, perpendicular to the
horizontal offset between the lobe's centre of mass and the centroid (the
worst overturning direction); zero offset → no audit needed. `arm(j)` =
distance of joint `j` from the axis (a wide/tall interface resists with a
tension–compression couple across its own extent; a single-face interface
resists with `M₀` alone — which is exactly what the §2.2 calibration pinned:
straight cantilever, one root face, `M_g = w·H²/2 = M₀`, binds at `H`
together with shear). Failure → snap **all** of `J` (conservative: the
whole lobe detaches as one body) → §5.6. Refinement (v2): binary-trim the
lobe from its tip to find the smallest stable prefix.

### 5.6 Resolution — carve & spawn (today's machinery, reused)

Snapped joints + crushed cells are applied, then the *existing* pipeline
runs unchanged: re-flood connectivity, group the unreachable cells into
6-connected components, capture ids before carving, `_edits[c] = 0`,
`_paint_cell(c, 0)`, `VoxelBody.spawn_loose(...)` with the breaker-kick.
One solve per player edit; spawned bodies never re-trigger a solve (same
no-recursion guard as today — a landing `VoxelBody` is physics-side and
does not re-enter the structural model; documented limitation §9).

### 5.7 Complexity & web budget

* Pass 0/1: O(region cells) ≈ today's cost ×~1.5 (one extra column scan).
  This is the *only* cost on flat digs and ground-supported placement.
* Pass 2: Dinic on the overhang neighbourhood only — typically tens to a
  few hundred nodes, ≤ ~4k worst case; graphs are shallow and unit-ish, so
  well under a 10 ms event budget on desktop web. Hard cap: if the graph
  exceeds `MAX_FLOW_CELLS` (4096), fall back to connectivity-only for this
  event (never worse than the status quo).
* Single-threaded GDScript, event-driven (break/place only), no per-frame
  work — web-safe regardless of `module_in_web`.

---

## 6. Integration with the existing engine

* `WorldManager._collapse_unsupported(center, from_pos)` is **replaced** by
  `_structural_update(center, from_pos)` → `StructuralSolver.solve(...)`
  returning `{detached: Array[Dictionary], crushed: Array[Vector3i]}`;
  WorldManager keeps ownership of carving, `_paint_cell`, ground-collider
  rebuild and `VoxelBody.spawn_loose` (the solver only *decides*).
* `break_terrain` calls it as today; **`place_block` now also calls it**
  (with `from_pos = Vector3.INF` — no kick on placement collapses).
  Contract choice: the placement *succeeds and then the structure fails*
  (the block is placed, the solver detaches what can't hold) — more
  physical than rejecting the placement, and it keeps `place_block`'s
  return semantics.
* Tree chop: unchanged by construction (§5.2). The standing tree must also
  be *stable* under the new checks — verified: canopy cells above the trunk
  are column-supported through it; lateral leaf rings are lobes carrying
  ≤ 2 leaf-weights per shear chain (≤ 1 962 N vs leaf–leaf `F_s` 2 943 N)
  with near-zero COM offset (symmetric) → moment audit trivially passes.
* `VoxelBody` internals unchanged. Optional v2: apply the same joint model
  *inside* a body on `break_cell` (today bodies split purely by
  connectivity — acceptable: they are already loose debris).
* Break-side nicety (optional): when `break_force` handling matures, the
  crush event (`σ_c` exceeded) can route through the same damage pipeline.

---

## 7. Data storage changes

* **`VoxelState`** (giving the existing stubs real meaning):
  * new: `strength_anchors: Vector3i` — `(P, H, D)`; the σ's are computed,
    not stored (single source of truth = anchors + mass).
  * new: `structural_class: StringName` — selects the φ curve.
  * `attachment: float (0..1)` — redefined as the *joint participation
    multiplier* applied on top of the computed capacities (1.0 = normal;
    0.0 = never forms joints, e.g. future sand). Default 1.0 keeps all
    calibration intact.
  * `solidity < 1` cells contribute their solidity as a default contact
    area until the sub-voxel workstream provides a real query (§4.3).
  * `mass`, `density`, `break_force` unchanged in meaning.
* **`BlockCatalog._make(...)`** gains `(anchors: Vector3i, sclass:
  StringName)` args; the §2.4 table lives there — this is the one place the
  MC-parity catalog extends.
* **New `sim/structural_model.gd`** (static, pure): capacity formulas (§4),
  φ curves + class table (§4.1), reinforcement table (§4.2),
  `joint_capacity(id_a, id_b, T, reinforcement_id, area)` — the single
  query the solver and any future UI read.
* **New `sim/structural_solver.gd`**: §5.
* **`WorldManager._joint_mods: Dictionary`** — sparse per-joint
  reinforcement: canonical key `Vector4i(min_cell.x, .y, .z, axis)` (axis
  0/1/2; `min_cell` = the lexicographically smaller cell) → reinforcement
  id. New API `reinforce_joint(cell_a, cell_b, id) -> bool`. Serialized
  alongside `_edits`. **Streaming seam flagged:** the runtime
  material-streaming workstream must carry `strength_anchors`,
  `structural_class` and `attachment` in the serialized material payload
  (`docs/RUNTIME-MATERIAL-STREAMING.md`).

---

## 8. verify_feature.gd test plan

New `_test_structural_anchors()` (plus keeping every existing test green,
especially the tree-chop invariant). Pattern per material — the anchors
become executable assertions:

* **Pillar `P`**: on flat pristine grass (dirt/wood) or on exposed stone
  (stone — dig a shaft to `stone_top` first; on grass the 64-pillar
  correctly punches through instead, §3, which gets its own assertion):
  place a base block + `P` above → assert zero new `VoxelBody`, all cells
  still solid. Place the `P+1`-th → assert collapse (base cell air/crushed,
  ≥1 body spawned).
* **Horizontal `H`**: build a support tower (same material, tall enough for
  clearance), extend a line of `H` blocks sideways at height → stands;
  place the `H+1`-th → the beam detaches as one body (assert cells air +
  one body with `H+1` cells).
* **Dangling `D`**: from the tower, one arm block out, then place `D`
  blocks downward from its underside → stands; `D+1`-th → the chain snaps
  at the top joint (assert body with `D+1` cells).
* **Mixed joint**: wood anchor block, hang stone beneath: 2 hold, 3rd
  falls (35 708 N vs 44 145 N — exact numbers in §4).
* **Bracing**: 2×2 dirt pillar holds 10 courses, fails at 11.
* **Temperature plateau**: assert `φ = 1` at 12 °C, 21.5 °C, 23 °C (deep
  mine == surface behaviour); assert `φ_soil(−10) = 3.0`,
  `φ_timber(300) = φ_min` via direct `StructuralModel` calls (no world
  needed — pure functions).
* **Reinforcement**: stone line with cement joints reaches 8 (vs 6 bare).
* **Solver purity**: run the pillar test twice (both render paths if
  available) → identical detach sets (determinism / path-agnosticism).

All assertions use the exact integer-Newton capacities, so there is no
float-epsilon flakiness at the "exactly at capacity" boundary (`≤` on
integers).

---

## 9. Adversarial review — how it breaks (known limits)

1. **Whole-tower overturning is not modelled.** Pass 3 audits lobes
   (overhangs) but a column-supported tower with a huge one-sided arm
   passes: its ground interface is compression-only in the flow and never
   moment-audited, so a 1-wide tower with a 20-block one-sided wood arm
   stands where reality topples it. Mitigation path (v2): treat each
   placed structure's ground-contact patch as an interface and run the §5.5
   audit with the column's own gravity as the restoring moment. Accepted
   for v1: Minecraft-family players expect attached structures not to
   topple.
2. **No re-solve on body landing / chained settlement.** A crushed
   punch-through resolves one shell per event; a landing `VoxelBody` never
   re-stresses what it lands on. Bounded by the existing no-recursion
   guard; revisit with a deferred re-check queue if gameplay demands
   cascades.
3. **Min-cut physicality.** Max-flow finds *a* cheapest break surface; with
   ties, the cut location is determined by iteration order, not physics.
   Sorted deterministic order makes it reproducible, not "correct" — two
   equally weak necks break at the one the order prefers.
4. **Conservative lobe detachment.** A failed moment audit drops the whole
   lobe even when trimming its tip would save most of it (v2: binary trim).
5. **Region cap.** Player structures whose connected edited component
   exceeds 4096 cells silently degrade to connectivity-only for that event.
   Rare (that is a *large* build), but it means mega-builds lose crush
   checks at their fringes; log it in dev builds.
6. **Live loads are minimal.** Only gravity (+ optionally the standing
   player) enters; pushes from `VoxelBody` collisions never load the
   terrain graph.
7. **Anchor tests depend on terrain generation** (stone shaft depth, flat
   spots); the verify script must *search* for a suitable site like the
   tree test already does, not hardcode coordinates.
8. **`M₀ = σ_s·H/2` couples bending to shear calibration.** A future
   material wanting "long but shear-weak" shelves can't express it; if
   needed, promote `M₀` to an optional explicit override (4th number) —
   the storage format (§7) should leave room.

---

## 10. Implementation phases

1. **Model + data**: `structural_model.gd` (capacities, φ, reinforcement
   table), `VoxelState`/`BlockCatalog` anchor fields, §2.4 table; pure-math
   assertions in verify (φ plateau, capacity formulas, mixed-joint
   numbers). No behaviour change.
2. **Solver passes 0–1** replacing `_collapse_unsupported` + the new
   `place_block` hook: connectivity preserved bit-for-bit, pillar-crush
   (P anchors) live. Tree-chop regression gate.
3. **Pass 2 flow + min-cut + adaptive region**: dangling (D) and
   horizontal (H) anchors live; punch-through emerges.
4. **Pass 3 moment audit + reinforcement storage/API + temperature
   coupling** (plateau makes this a no-op in today's world).
5. **verify_feature anchor suite (§8) + docs cross-links** (a new
   SIM-MODEL.md section pointing here; a DESIGN.md decision-log entry).
