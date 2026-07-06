# VOXIVERSE — Integration Decisions (cross-workstream reconciliation)

Status: **DECISION RECORD — authoritative.** Branch `feat/voxiverse-sim-extensions`.
Author: integration lead, 2026-07-05.

Six design docs were produced in parallel, blind to each other:
`VOXEL-DATA-STRUCTURE.md` (newest, most authoritative), `STRUCTURAL-INTEGRITY.md`,
`WORLDGEN-CATALOG.md`, `SUB-VOXEL-SMOOTHING.md`, `RUNTIME-MATERIAL-STREAMING.md`,
`TEXTURES.md`. This record makes the remaining cross-cutting decisions, records
the ratifications already implied by `VOXEL-DATA-STRUCTURE.md` §13, and ends with
one **consolidated edit list** (§5) so applying the reconciliation to the six
docs is purely mechanical, plus the recommended implementation order (§6).

Notation: VDS = VOXEL-DATA-STRUCTURE.md, SI = STRUCTURAL-INTEGRITY.md,
WGC = WORLDGEN-CATALOG.md, SVS = SUB-VOXEL-SMOOTHING.md,
RMS = RUNTIME-MATERIAL-STREAMING.md, TEX = TEXTURES.md.

| # | Decision | One line |
|---|---|---|
| A | Material-parameter currency | Anchor triple `(P,H,D)` + `structural_class` stored on `VoxelState` is the truth; catalog priors `(ρ,C,T | cohesion)` feed a pinned converter that *proposes* anchors; the scalar `attachment` column is superseded (§1.4) |
| B | 16-bit TYPE-channel double-claim | VDS §8.1 ARIDs ratified; SVS `lib_id` product formula and RMS "reserved upper band" are retired |
| C | Analytic-physics contract | One merged contract: material solidity gates, modifier shapes — composed signatures + evaluation order in §3 |
| D | Texture pipeline | Static for this milestone; `tex:sha256` + async `TextureStore` is a forward seam owned by the textures workstream |

---

## 1. Decision A — the material-parameter authoring currency and the converter

### 1.1 The authoring rule (source of truth)

**Adopted:** the anchor triple **`(P, H, D)`** — max pillar height, max horizontal
shelf, max dangling depth, three small integers with direct in-game meaning —
plus a **`structural_class`** StringName, stored per material on `VoxelState`
(`strength_anchors: Vector3i`, exactly SI §7), is the **gameplay-facing truth**.
The catalog's physical priors `(analog, ρ, C [MPa], T [MPa])` for stress-governed
materials and `cohesion c [kPa]` for soils are an **authoring derivation aid**:
they feed the converter below, which *proposes* anchors; a designer may override
any proposal; the shipped value is always the (possibly tuned) anchor triple.

What gets **stored** (blocks.json record / material document / VoxelState):
`strength_anchors: [P, H, D]` (ints), `structural_class`, `mass`, and the
`priors` block (retained as provenance so anchors can be re-proposed when mass
is rebalanced). `attachment` is stored only when ≠ 1.0, with the §1.4 semantics.

What gets **computed**, never stored: `σ_c = P·m·g`, `σ_t = D·m·g`,
`σ_s = H·m·g`, `M₀ = σ_s·H/2`, and every joint capacity (SI §2/§4). Single
source of truth = anchors + mass.

What gets **discarded**: WGC §3.4's scalar `attachment A` column (§1.4), and the
*structural* reading of WGC §3.2's provisional `D` formulas — those formulas are
retained **only** as the derivation of `break_force`, the tool-facing "how hard
to mine" number, which SI §4 already declares orthogonal to structural strength.
(The letter *D* is henceforth reserved for the dangle anchor; the catalog column
is renamed `break_force` — edit list D-21.)

**Where the converter runs: authoring/tooling time, not runtime.** The generated
`blocks.json` carries explicit anchors; `verify_feature.gd` gains a **drift
gate**: for every record not marked `"anchors_override": true`,
`StructuralModel.propose_anchors(priors, class) == stored anchors` — so priors
and anchors can never silently diverge, while hand-tuning stays first-class.

*Why this way round and not priors-as-truth:* the anchors are what the solver
calibrates against, what the verify suite asserts (SI §8 builds literal pillars
of `P` and `P+1`), and what a designer reasons about ("how long a wooden shelf").
Priors-as-truth would force every balance tweak through a physics-unit detour
and would leave the soil family (no meaningful C) permanently special-cased.
The priors' real value — grounding the *relative* spread of 77+ materials in
reality — is fully captured by the proposal+drift-gate arrangement.

### 1.2 The converter `(ρ, C, T) → (P, H, D)` — stress branch

The pinned laws (power laws; two calibration materials pin two constants each):

```
P̂ = κ_class · 64 · (C / 100 MPa)^βc          βc = log₂(16/9) = 0.830075
D̂ =            4 · (T /  10 MPa)^βt          βt = log₃(2)    = 0.630930
Ĥ = 1.5 · D̂                                  k_s = 1.5 (shear:tension ratio)
```

Rounding/clamps (in this order): round half-up (`floori(x + 0.5)`, GDScript
`roundi` semantics); `P = max(1, round(P̂))` for any solid;
`D = max(1, round(D̂))` when `T ≥ 0.05 MPa`, else `round(D̂)`;
`H = max(D, round(Ĥ), 1)`. σ's and `M₀` always derive from the **rounded**
stored ints (integer-Newton determinism, SI §8).

`κ_class` = 1.0 for every class except **brittle** = **1/3** (flaw-governed
design strength — engineering practice rates glass/ice at ~⅓ of lab compressive
strength; it is also what lands glass inside SI §2.5's brittle-sheet archetype
band). Note real density ρ appears in **no** formula: gameplay mass `m` is
already derived from ρ by WGC §3.2's family factors, and `(P,H,D)` are
strength-to-*weight* ratios by SI §2.2 — absolute capacities scale with mass
automatically (`σ = anchor·m·g`), which is exactly SI §2.5's "denser variant
keeps its anchors" rule.

**Why these constants** — they are not free; each is pinned by two anchors:

* `βc`: stone (C=100 → P=64) and wood (C=50 → P=36):
  `βc = ln(64/36)/ln(100/50) = ln(16/9)/ln 2`. Check: 64·(0.5)^0.830075 =
  64·0.56246 = **35.997 → 36** ✓; 64·1^βc = **64** ✓.
* `βt`: stone (T=10 → D=4) and wood (T=90, the WGC-committed ∥-grain prior →
  D=16): `βt = ln(16/4)/ln(90/10) = ln4/ln9 = log₃2`. Check: 4·9^0.630930 =
  4·4.0000 = **16.000 → 16** ✓; 4·1^βt = **4** ✓.
* `k_s = 1.5`: pinned by the H:D ratio of *both* stress anchors — stone
  6 = 1.5·4, wood 24 = 1.5·16 (and SI's hand-assigned leaf (4,3,2) obeys it
  too). Physical reading: joint shear capacity is governed by the same bond
  population as tension with a geometric factor ~1.5 — the common brittle/
  bonded-joint rule of thumb. SI §9.8's "long but shear-weak material" caveat
  stands: if a material ever needs an independent H, it is a per-material
  override, not a new constant.

**Species logs:** WGC commits numeric C per species but only "high ∥" for T.
Committed default: `T = 1.8 · C` (pinned by oak: 90 = 1.8·50), overridable.

**Calibration verification (executed numerically, not by eye):**

| anchor | inputs | P̂, D̂, Ĥ (raw) | rounded (P,H,D) | target |
|---|---|---|---|---|
| stone | C=100, T=10, rock | 64.00, 4.00, 6.00 | **(64, 6, 4)** | (64, 6, 4) ✓ |
| wood/oak | C=50, T=90, timber | 36.00, 16.00, 24.00 | **(36, 24, 16)** | (36, 24, 16) ✓ |
| dirt | c=25 kPa, soil (§1.3) | 4.00, 1.00, 1.50 | **(4, 2, 1)** | (4, 2, 1) ✓ |
| grass | c=30 kPa, soil (§1.3) | 4.38, 1.10, 1.64 | **(4, 2, 1)** | matches SI §2.4 ✓ |

(The dirt H case is why round-half-up is normative: 1.5 → 2.)

**Proposed anchors across the WGC §3.4 spread** (converter output; the stored
value may be hand-tuned — tuning notes inline):

| material | inputs | class | κ | (P, H, D) | sanity |
|---|---|---|---|---|---|
| stone | C100 T10 | rock | 1 | (64, 6, 4) | anchor |
| deepslate | C150 T15 | rock | 1 | (90, 8, 5) | > stone on every axis ✓; top of SI masonry band (48–96, 4–8, 2–5) ✓ |
| granite | C130 T8 | rock | 1 | (80, 5, 3) | taller pillars, slightly worse tension than stone ✓ |
| diorite / andesite | C120 T8 | rock | 1 | (74, 5, 3) | |
| tuff | C30 T2 | rock | 1 | (24, 2, 1) | weak rock ✓ |
| calcite | C50 T4 | rock | 1 | (36, 3, 2) | |
| sandstone / red_sandstone | C60 T4 | rock | 1 | (42, 3, 2) | |
| terracotta family | C25 T3 | rock (fired masonry) | 1 | (20, 3, 2) | |
| obsidian | C300 T5 | rock | 1 | **(159, 4, 3)** | toughest pillar in the game by far ✓ (mining toughness stays in `break_force` = 5700) |
| amethyst_block | C80 T5 | rock | 1 | (53, 4, 3) | |
| glass / stained | C50 T1 | brittle | ⅓ | **(12, 1, 1)** | κ=⅓ lands P exactly at 12 — mid brittle-sheet band (8–16); barely shelves, barely hangs ✓ |
| tinted_glass | C55 T1 | brittle | ⅓ | (13, 1, 1) | |
| ice | C8 T3 | brittle | ⅓ | (3, 3, 2) | fragile; sheet strength comes from bracing + confined bulk, see §1.5 risk 3 |
| packed_ice | C10 T3.5 | brittle | ⅓ | (3, 3, 2) | |
| blue_ice | C12 T4 | brittle | ⅓ | (4, 3, 2) | |
| snow_block | C1 T0.1 | soft | 1 | (1, 1, 1) | floor-clamped; recommend hand-tune to (3, 2, 1) (SI foliage/soft archetype) |
| oak (wood) | C50 T90 | timber | 1 | (36, 24, 16) | anchor |
| spruce_log | C40 T72 | timber | 1 | (30, 21, 14) | m=50: absolutely weak, best strength-to-weight after oak ✓ |
| birch_log / cherry_log | C45 T81 | timber | 1 | (33, 22, 15) | |
| jungle_log | C52 T94 | timber | 1 | (37, 25, 16) | |
| dark_oak_log | C58 T104 | timber | 1 | (41, 26, 18) | |
| acacia_log | C60 T108 | timber | 1 | (42, 27, 18) | strongest timber ✓ |
| *_ore / deepslate_*_ore | — | host's class | — | **inherit host anchors** (64,6,4)/(90,8,5); higher mass ⇒ absolutely stronger joints automatically; `break_force` keeps the +10 % | |
| leaf / *_leaves | no priors | foliage | — | hand-authored **(4, 3, 2)** (= SI §2.4; obeys k_s) | |
| bedrock | C=∞ | `&"bedrock"` | — | capacities ∞ (sentinel class, no anchors) | unbreakable by decree ✓ |
| water / lava / powder_snow | fluid / solidity < 0.5 | `&"fluid"` / non-solid | — | **no anchors — outside the solver** (§3: not `cell_solid`) | ✓ |
| dirt | c=25 | soil | — | (4, 2, 1) | anchor |
| grass | c=30 | soil | — | (4, 2, 1) | matches SI ✓ |
| coarse_dirt / podzol / mycelium | c=20 | soil | — | (4, 1, 1) | |
| mud | c=10 | soil | — | (3, 1, 1) | weaker than dirt ✓ |
| clay | c=100 | soil | — | (8, 3, 2) | stiff clay ✓ |
| sand / red_sand | c≈0 | granular | — | **(3, 1, 0) + participation 0** | falling sand — see §1.3/§1.4 |
| gravel | c≈2 | granular | — | (3, 1, 0) + participation 0 | |

### 1.3 The soil / cohesion branch (the gap both agents flagged)

Soils have no meaningful compressive prior (cohesion-dominated), and the stress
branch's exponents — calibrated across 50–300 MPa — collapse to P≈0 when fed
kPa-scale strengths (dirt's unconfined C ≈ 2c = 0.05 MPa → P̂ = 0.12). So the
soil family gets its **own branch**, selected by `structural_class`
(`&"soil"` / `&"granular"`), never by input magnitude:

```
cohesive soil  (c ≥ c_min = 5 kPa):
    P̂ = 4 · sqrt(c / 25 kPa)      D̂ = sqrt(c / 25 kPa)      Ĥ = 1.5 · D̂
    round half-up; floors P,H,D ≥ 1 (a cohesive soil always bonds a little)

granular / cohesionless  (c < 5 kPa — sand, gravel):
    (P, H, D) = (3, 1, 0)   AND   attachment participation = 0.0   (§1.4)
```

Pinned by the **dirt** anchor (c = 25 kPa → exactly (4.00, 1.50, 1.00) →
(4, 2, 1) ✓). The √ exponent is the one design freedom of the branch (one
anchor, one exponent); it is validated by: grass c=30 → (4, 2, 1), exactly SI
§2.4's archetype assignment ✓; clay c=100 → (8, 3, 2) and mud c=10 → (3, 1, 1),
both matching the loose-soil archetype band and the obvious ordering
mud < dirt < clay ✓. Soil-mechanics grounding: unconfined strength `q_u = 2c`,
tensile ≈ c/2, shear ≈ c — all *proportional to c*, so one law in c with a
mild exponent is the honest model; the √ keeps clay from towering absurdly.

The branch requires WGC to **commit numeric cohesion values** (it currently
writes the word "cohesion" for several rows): grass 30, dirt 25,
coarse_dirt/podzol/mycelium 20, mud 10, clay 100, sand 0, gravel 2 kPa
(edit list D-21). Validation rule: `c > 200 kPa` is a loud warning — that is
soft-rock territory and should be authored through the stress branch instead
(the two branches are separate calibrations for separate regimes; they do
**not** meet continuously at any boundary, by design, and no material may sit
on the boundary because the branch is class-keyed).

**Why sand is `(3, 1, 0)` *plus* participation 0 — the falling-sand audit.**
D = 0 alone (σ_t = 0: nothing hangs) is necessary but **not sufficient**, and
neither is H = 0. Worked failure, using SI §4's arithmetic-mean joint rule as
written: a single sand block side-attached to a stone wall, undercut. Its
sand–stone joint would get `F_s = ½·(σ_s,sand + σ_s,stone) = ½·(0 + 88 290) =
44 145 N` against a sand weight of `890·9.81 = 8 731 N` — the overhang **stays
glued to the wall nine times over**, and the same mean gives `F_t = 29 430 N`,
so sand would *dangle three deep under stone*. The mean rule (which is correct
for two bonding materials and must stay — SI's mixed-joint calibration and
worked example depend on it) fundamentally cannot express "this material does
not bond". SI §7 already invented the right knob and even named sand as its
use case: `attachment` redefined as the **joint participation multiplier**.
Decision: the joint capacities (SI §4) gain the factor `att_A · att_B`
multiplying the whole bracketed term of `F_t`, `F_s`, `M₀` — **never** the
compression path (down-edges stay capacity-∞; bearing is the node's σ_c).
Sand/gravel ship `attachment = 0.0`; every other v1 material ships 1.0, so the
entire SI calibration is untouched. Result: undercut sand falls even against a
stone wall; sand heaps still stand (pure compression routing); a sand column
still crushes at P = 3. H = 1 is retained as the *documented* shear ratio for
future re-enabling (e.g. wet/frozen sand) but is inert while participation
is 0. Residual flagged: frost (`φ_soil(−10 °C) = 3`) multiplies capacities but
`3 × 0 = 0` — permafrost-cementing granular materials would need a
participation-vs-temperature curve; explicitly out of v1 scope.

### 1.4 The scalar `attachment A` — superseded, field repurposed

SI §2.3 proves one scalar cannot encode attachment (the required lever arm
`z = H²/2D` is material-dependent: dirt 2.0, wood 18.0, stone 4.5) — attachment
*is* the (σ_t, σ_s) pair, i.e. the (D, H) anchors. Therefore:

1. **WGC §3.4's `A` column (0..1) is superseded and deleted.** Its intended
   semantics are fully absorbed: "sand A=0.05 ⇒ falls" → D=0 + participation 0;
   "glass A=0.1 ⇒ fragile" → (12, 1, 1); "granite A=0.8 < stone 1.0" → the
   T-derived D anchors. No consumer ever read it (WGC §3.2 itself notes it is
   unread today). Nothing replaces it column-for-column; the anchors table does.
2. **The `VoxelState.attachment: float` field is kept** with SI §7's exact
   redefinition: *joint participation multiplier*, default 1.0, composed as
   `att_A · att_B` on tension/shear/moment capacities only (§1.3). It is **not**
   a strength, **not** authored from priors, and in v1 is non-1.0 only for
   sand/gravel (0.0). RMS's document schema documents the key accordingly
   (edit C-16). No orphaned semantics remain.

### 1.5 Residual risks (adversarial notes on the converter itself)

1. **Rounding is load-bearing.** Dirt's H exists only because 1.5 rounds up;
   verify must pin the rounding helper (one shared `_round_half_up`), and the
   drift gate (§1.1) catches any refactor that changes it.
2. **The branch discontinuity** (soil vs stress laws differ by orders of
   magnitude at equal nominal strength) is intentional but must never be
   crossed silently — hence the class-keyed selection + the c > 200 kPa warning.
3. **Frozen-sea ice is currently impossible** — a genuine cross-doc bug this
   review caught: WGC §6.7 generates walkable sea ice in snowy biomes, but
   `PerVoxelEnvironment` today reports ~21.5 °C air everywhere, and SI §4.1's
   brittle-ice curve (φ = 1 below −5 °C, ramping to φ_min = 0.05 at 0 °C) makes
   that ice structurally tissue paper (σ_s·φ ≈ 750 N < one ice block's 5 kN):
   breaking one block would shed the surrounding sheet each event. **Required
   ordering constraint:** biome-keyed surface temperature (snowy < −5 °C) lands
   in `PerVoxelEnvironment` with WGC Phase 2, *before* SI pass 2 goes live —
   or ice worldgen ships after it does. (Edits D-24, E-30; order §6.)
4. **Hand-tuned values drift from intuition, not from priors** — the
   `anchors_override` flag keeps the drift gate honest while allowing tuning
   (snow_block is the first expected override).

---

## 2. Decision B — Gap #1 ratified: ARIDs own the TYPE channel

**Ratified as decided:** VDS §8.1's **ARID** (Appearance Render ID) resolves the
16-bit TYPE-channel double-claim. The TYPE channel is a render mirror carrying
session-local, append-only, lazily allocated appearance ids — one per
(LRID, modifier, state & visual_mask) combination actually in use, with
`add_model() index == ARID` asserted and cube-ARID == LRID for the bootstrap
set only. Consequences, already itemized by VDS §13 and merely consolidated
here into the edit list (§5):

* SVS §4.1's static `lib_id(mat, shape) = 1 + (mat−1)·162 + shape` product
  formula, its ~404-material cap, and the 162-models-per-material pre-bake are
  **retired** (edits B-5).
* RMS §4.5/§9.5's "reserved upper band of the library" wording is **retired**;
  shape/visual-state models interleave in the one append-only model space under
  the ARID discipline (edits C-12), and `can_render_id` generalizes to the
  composed appearance (C-13). ARIDs never serialize; material identity
  (GMID ⇄ LRID) is untouched.

---

## 3. Decision C — Gap #4: the merged analytic-physics contract

WGC §6.3 rewrites `cell_solid`/`floor_under`/`blocked`/`aimed_voxel` to be
**material-aware** (solidity threshold; water/lava pass-through) and adds
`occludes_face`. SVS §5 rewrites the same functions to be **shape-aware**
(ramps as continuous floors, occupancy intervals, in-cell ray tests). They must
be implemented **once**, as one contract:

> **The composition rule: material solidity gates; modifier shapes.**
> A cell contributes collision geometry iff its *material* passes the solidity
> gate; *where* inside the cell it collides is then given by its modifier's
> occupancy. A non-solid material's modifier is ignored everywhere.

Effective occupancy of a cell value `v` (packed per VDS §3.3) at footprint
`(fx, fz)`:

```gdscript
# WorldManager — the ONE composition helper both workstreams implement against.
# Returns the filled vertical interval (lo, hi) at the footprint; (0,0) = empty.
func _occ_span(v: int, fx: float, fz: float) -> Vector2:
    if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:   # 1) MATERIAL GATE
        return Vector2.ZERO            # air / water / lava / powder_snow: no occupancy
    return ShapeCodec.span(CellCodec.modifier(v), fx, fz)  # 2) SHAPE (modifier 0 -> (0,1))
```

Composed signatures and per-function evaluation order (each function resolves
the packed value **once** via `cell_value_at`, applies the material gate, then
the shape test — in that order, always):

| function | contract |
|---|---|
| `cell_solid(cell) -> bool` | **Material-only**: `solidity_of(block_id_at(cell)) >= 0.5`. A ramp cell IS solid — partial geometry is expressed by the interval functions, never by this boolean. (WGC's semantics win; SVS's `!= AIR` body is revised — edit B-9.) |
| `floor_under(x, z, feet_y) -> float` | Downward scan (SVS §5.1 shape logic) where the per-cell test is `_occ_span`: non-solid materials yield the empty span and are scanned **through** (water → seafloor, WGC's behaviour), solid shaped cells yield `local_top` (ramps → continuous floors, SVS's behaviour). Headroom via spans of overlapping cells (non-solid ⇒ empty). |
| `blocked(x, z, feet_y) -> bool` | SVS §5.2 verbatim (`STEP_MAX = 0.55`, floor-then-headroom) on top of the merged `floor_under`/spans. Water doesn't block (empty span); a full cube still does; ramps auto-step. |
| `aimed_voxel(origin, dir, max) -> Dictionary` | DDA cell walk unchanged. Per cell: material gate first — non-solid ⇒ **skip** (targets through water, WGC); then modifier 0 ⇒ boundary hit (today's fast path); else SVS §5.3's in-cell surface test. |
| `GroundCollider` | Boxes for solid-material modifier-0 cells; ≤ 2 convex prisms (SVS §4.3) for solid shaped cells; **nothing** for non-solid materials. |
| collapse / structural solver | Graph nodes = `cell_solid` cells (so SI's "every solid cell" formally means solidity ≥ 0.5 — powder_snow, water, lava never enter the graph); joint contact factor `a = ShapeCodec.contact_area(modifier_a, modifier_b, axis)` per VDS §13.3, ×participation ×temperature per §1.3/SI §4. |
| `occludes_face(nb, my_group) -> bool` (render-only) | WGC §5.2's cull-group rule composed with shape: neighbour occludes iff (material occludes per the transparency-index rule) **and** its facing side profile fully covers the shared face (`side_profile == full`; modifier 0 ⇒ trivially full — today's fast path). Module path: unchanged config (transparency_index) — godot_voxel's baked side-pattern matching already provides the shape half. |

Canonicalization addendum (goes in `CellCodec.canonical`, VDS §3.3's validation
hook): **`modifier != 0` requires `solidity_of(mat) ≥ 0.5`** — a "ramp of
water" strips to modifier 0 with a logged validation error (VDS §3.1's "fails
validation, not encoding", made concrete). This guarantees the material gate
may soundly ignore modifiers on non-solid cells.

Perf note: for modifier-0, solid, opaque worlds every function above reduces
branch-for-branch to today's code (one extra `solidity_of` array read per
cell), preserving VDS §6's budgets and WGC §8's audit.

---

## 4. Decision D — Gap #3: textures are static this milestone

`TEXTURES.md`'s pipeline (CC0 pack → deterministic enhancement bake → committed
`pack/<name>.png` → `BlockTextures.TILES`) **stands as-is for the current
milestone**, including for the WGC catalog's new blocks (its §6 recipe + the
Appendix-A 77-name list are the contract). RMS §5.3's content-addressed
`tex:sha256:` asset ids and the async `TextureStore`
(`request`/`ready`/`get_if_loaded`) are **future work owned by the textures
workstream** — a forward seam, not a conflict: the stable material-name file
keys TEX already uses are exactly what a content-addressed store will hash, and
RMS's swap-into-the-same-Material-instance mechanism needs no change to today's
`BlockMaterials` contract. No doc edits beyond two pointers (edits F-33/34) and
the note in RMS (C-18).

---

## 5. Consolidated edit list

Apply in this order (authoritative doc first; then per doc). Tags:
**[S]** supersession pointer (add a note that section X is superseded by doc Y
§Z; keep the original text struck-through or boxed), **[V]** value/content
change, **[X]** cross-link fix. Line numbers are as of this record's date.

**A — VOXEL-DATA-STRUCTURE.md** (authoritative; minimal touch-up)

1. [X] §17.2 (line 950): "BLOCK-CATALOG-MC" → "WORLDGEN-CATALOG
   (`docs/WORLDGEN-CATALOG.md`)".
2. [V] §13.3: append one sentence — `attachment` on VoxelState is the joint
   participation multiplier per INTEGRATION-DECISIONS §1.4; the catalog's
   scalar A column is superseded.

**B — SUB-VOXEL-SMOOTHING.md** (VDS §13.1 + Decision C + cross-links)

3. [V] §3.1: replace the bit layout — shape+anchor move from cell-int bits
   16..24 to modifier-axis bits 0..8; the cell value is VDS §3.3's
   `mat | modifier<<16 | state<<32`. Canonicalization rules survive verbatim on
   the modifier field. Add supersession banner pointing to VDS §3/§13.1.
4. [V] §3.1 API block: `ShapeCodec` splits — `mat/shape/pack/canonical/is_full`
   migrate to `CellCodec`; geometry/physics math (`volume`, `local_top`,
   `occupied`, `span`, `side_profile`, `contact_area`, `surface_tris`, LUTs)
   stays in `ShapeCodec`, re-keyed to a 16-bit modifier (VDS §13.1.2).
5. [V] §4.1: delete `lib_id(mat, shape) = 1 + (mat−1)·S + shape`, the
   404-material cap, and the 162-models-per-material pre-bake; replace with
   lazy ARID allocation (VDS §8.1); retarget the roundtrip asserts to
   `add_model index == ARID`. Delete the §4.1 SEAM paragraph (TYPE channel
   product) — resolved by ARIDs. [Decision B]
6. [V] §3.1 reserved-bits note: future shape families use modifier bit 15
   (FAM); scalar per-cell stats (damage, growth) go to the **state axis**;
   per-joint reinforcement stays in `_joint_mods` (VDS §13.1.4).
7. [S] §3.2 streaming SEAM: resolved — material id space never forks; ARIDs
   carry appearance; delete the ">16-bit ids shifts the shape field"
   contingency (VDS §13.1.5).
8. [V] §10 verify items 1 and 6: retarget to `CellCodec`/ARID roundtrips; §9's
   `comp_ids` capture now includes the state axis (VDS §13.1.6).
9. [V] §3.1's `cell_solid` snippet (`!= BlockCatalog.AIR`) and all §5
   functions: revise to the merged contract — material solidity gate
   (`solidity_of ≥ 0.5`) precedes every shape test; add pointer to
   INTEGRATION-DECISIONS §3 as the normative composition. [Decision C]
10. [V] §3.1 canonicalization: add "modifier ≠ 0 requires
    solidity_of(mat) ≥ 0.5; violation strips to modifier 0 + logged error".
    [Decision C]
11. [X] Header sibling list (line 20) and §8.1 SEAM (line 603):
    `docs/BLOCK-CATALOG-MC.md` / "BLOCK-CATALOG-MC" →
    `docs/WORLDGEN-CATALOG.md`.

**C — RUNTIME-MATERIAL-STREAMING.md** (VDS §13.2 + Decisions A/B/D + links)

12. [S] §4.5 second bullet, §9.5, and §12's "reserved-upper-band rule" mention:
    superseded by the ARID table (VDS §8.1); invariant becomes
    `add_model() == ARID`, `cube ARID == LRID` asserted for bootstrap only
    (VDS §13.2.1). [Decision B]
13. [V] §3.1: `can_render_id(lrid)` generalizes to `can_render(arid)` /
    `can_render_cell(mat, modifier, vstate)`; the `_paint_cell` gate checks the
    composed appearance (VDS §13.2.2).
14. [V] §6.5: the generator manifest extends from a material set to an
    **appearance set** — (material, modifier) pairs registered + baked before
    path activation (VDS §13.2.3).
15. [V] §2.6: container payloads adopt ZoneChunk layers (VDS §5); chunk
    material palettes are the container-local ids (one palette per chunk);
    id-map header unchanged (VDS §13.2.4).
16. [V] §5.2 document schema: add VDS §10.3's `state_layout` / `visual_mask` /
    `has_block_entity`, **and** Decision A's `strength_anchors: [P,H,D]`,
    `structural_class`, optional `anchors_override`, `priors` block; document
    the `attachment` key as the joint participation multiplier, default 1.0
    (§1.4). Physics-block example updated accordingly.
17. [V] Decision log #4: amend per VDS §13.2.6 (append+batched-bake mechanics
    unchanged, now also covering ARID model appends).
18. [S] §5.3 + §9.4: add note — the texture pipeline is static for the current
    milestone (TEXTURES.md); `tex:sha256` + async TextureStore is future work
    owned by the textures workstream. [Decision D]
19. [X] `BLOCK-CATALOG-MC(.md)` → `WORLDGEN-CATALOG.md` at lines 13, 68, 107,
    163, 499, 503, 590; `SUBVOXEL-SMOOTHING.md` → `SUB-VOXEL-SMOOTHING.md` at
    lines 71, 319, 611.

**D — WORLDGEN-CATALOG.md** (Decision A value changes + C pointer + links)

20. [V] §3.2: delete the provisional **structural** reading of the D/A rules.
    Retain the `D` power-law formulas *renamed as the `break_force`
    derivation* (tool-facing mining effort only — SI §4 orthogonality). State
    that structural anchors come from INTEGRATION-DECISIONS §1.2/§1.3's
    converter; delete "flag to the sibling…soil branch" (delivered).
21. [V] §3.4: (a) rename column `D` → `break_force`; (b) **delete column `A`**
    (superseded, §1.4); (c) add columns `class` and `(P,H,D)` from the §1.2
    table (or a pointer to it); (d) commit numeric cohesion values: grass 30,
    dirt 25, coarse_dirt/podzol/mycelium 20, mud 10, clay 100, sand 0,
    gravel 2 kPa; (e) commit species-log tensile default `T = 1.8·C` (oak
    anchor 90); (f) note sand/gravel additionally carry
    `attachment = 0.0` (participation).
22. [V] §4 blocks.json schema: replace `"attachment": 0.10` in the example
    with `"anchors": [12, 1, 1], "structural_class": "brittle"`; keep
    `"priors"`; `attachment` appears only when ≠ 1.0 (sand/gravel `0.0`);
    add the VDS §10.3 keys as forward-compatible optionals.
23. [S] §6.3: add pointer — this section is layer 1 (the material gate) of the
    merged analytic-physics contract in INTEGRATION-DECISIONS §3; the
    sub-voxel workstream's shape tests are layer 2; one implementation.
24. [V] §6.7 + §11.9: new ⚠SEAM — frozen-sea ice requires biome-keyed surface
    temperature in `PerVoxelEnvironment` (snowy < −5 °C) before SI pass 2
    lands, else φ_brittle(21 °C) = 0.05 makes generated sea ice structurally
    tissue paper (INTEGRATION-DECISIONS §1.5 risk 3).
25. [X] Header sibling table (line 23) + §9 SEAM bullet:
    `docs/SUBVOXEL-SMOOTHING.md` → `docs/SUB-VOXEL-SMOOTHING.md`. Add a
    one-line alias note under the title: "referenced in earlier sibling docs
    as `BLOCK-CATALOG-MC.md` — same workstream, this file."

**E — STRUCTURAL-INTEGRITY.md**

26. [S] §2.5: the archetype table becomes *guidance*; the normative proposal
    method is INTEGRATION-DECISIONS §1.2 (stress branch) / §1.3 (soil branch)
    with the pinned constants βc = log₂(16/9), βt = log₃2, k_s = 1.5,
    κ_brittle = ⅓; step 2 "pick an anchor triple" becomes "accept or tune the
    converter's proposal".
27. [V] §4 joint formulas: multiply the bracketed term of `F_t`, `F_s`, `M₀`
    by the participation factor `att_A · att_B` (never the compression path).
    Default 1.0 → calibration untouched; sand/gravel 0.0 → closes the
    mixed-joint falling-sand hole (worked failure in INTEGRATION-DECISIONS
    §1.3). The arithmetic-mean rule itself is unchanged.
28. [V] §7: ratified as written (`strength_anchors: Vector3i`,
    `structural_class`, `attachment` = participation multiplier) + add: the
    solver's "solid cell" predicate is `WorldManager.cell_solid`
    (solidity ≥ 0.5, Decision C) — powder_snow/water/lava never enter the
    graph; delete the interim "`solidity < 1` contributes solidity as default
    contact area" line (superseded by the modifier-axis contact query, VDS
    §13.3).
29. [V] §4.3: re-key to the modifier axis per VDS §13.3 — partial mass =
    `density(LRID) × ShapeCodec.volume(modifier)`;
    `contact_area(cell_a, cell_b, axis)` reads `modifier_at` through the
    composed query. `_joint_mods` stays outside the four axes (unchanged).
30. [V] §4.1 brittle-ice row: add the frozen-sea dependency note (edit D-24) —
    ice-sheet content is gated on biome temperature landing in
    `PerVoxelEnvironment`.
31. [X] §2.5 (line 150): `docs/BLOCK-CATALOG-MC.md` →
    `docs/WORLDGEN-CATALOG.md`; §4.3 (line 326): `docs/SUBVOXEL-SMOOTHING.md`
    → `docs/SUB-VOXEL-SMOOTHING.md`.
32. [V] §8 verify plan: add (a) the converter **drift gate**
    (`propose_anchors(priors, class) == stored anchors` for every
    non-overridden record); (b) falling-sand asserts — undercut sand falls
    even when side-attached to stone (the participation test), sand heap on
    solid ground stands, sand column of 4 crushes its base (P = 3);
    (c) the §1.2 calibration table's three anchors as pure-math asserts.

**F — TEXTURES.md**

33. [S] §7 Known follow-ups: add — content-addressed `tex:<algo>:<hash>` asset
    ids + the async `TextureStore` contract (RMS §5.3/§9.4) are this
    workstream's future deliverable; the static pipeline stands for the
    current milestone. [Decision D]
34. [X] Lines 24 and 143: `docs/BLOCK-CATALOG-MC.md` →
    `docs/WORLDGEN-CATALOG.md`.

**34 edits: 8 supersession pointers, 19 value changes, 7 cross-link fixes.**

---

## 6. Recommended implementation order

```
P0  VDS P0 — CellCodec + packed overlay + _write_cell choke point (no behaviour change)
P1  WGC Phase 0 + Decision-A data — blocks.json (frozen 6 first), VoxelState
    anchors/class fields, the converter as offline tooling + drift gate
P2  Decision-C merged physics contract — cell_solid / floor_under / blocked /
    aimed_voxel / occludes_face implemented ONCE (shape hooks trivially full-cube)
P3  WGC Phases 1–2 — depth (bedrock/deepslate/ores), biomes/sea/translucency,
    biome-keyed surface temperature in PerVoxelEnvironment (unblocks ice, §1.5)
P4  SI Phases 1–4 — structural model, passes 0–1, flow solver, moment audit
    (contact_area hardcoded 1.0 behind its one function — SI §4.3's own seam)
P5  SVS P1–P3 + VDS P3 — ShapeCodec math, smoothing, ShapeMesh, ARIDs
    (joint render PR; live-site gate); plugs real contact_area into P4's seam
P6  VDS P1–P2 + RMS Phases 1–5 — metadata store, ZoneChunk container,
    dynamic catalog, id-map containers, zone bundles
TEX independent — static pipeline; new-block tiles land alongside P3
```

Dependency reasoning:

* **VDS P0 first** — every other workstream's code reads the packed cell value
  and the write choke point; it is a pure refactor with a green-tests gate, and
  retrofitting it later would rewrite everyone's diffs.
* **Catalog data before structural** — SI Phase 1 is "model + data"; the
  anchors/class fields and the converter are that data. Doing the JSON loader
  with only the frozen 6 first (WGC's own Phase 0) keeps this small.
* **Decision C before both WGC Phase 2 and SVS P2** — three workstreams edit
  the same four functions; implementing the merged contract once (with the
  shape hooks returning full-cube) means WGC's solidity semantics and SVS's
  interval physics land as *fillings of an existing contract*, not as competing
  rewrites. This is the single highest-collision-risk seam in the program.
* **Structural (P4) before sub-voxel (P5)** — SI explicitly ships with
  `contact_area = 1.0` behind one function, so it needs nothing from SVS,
  and it delivers the visible gameplay wins (falling sand, pillar crush,
  punch-through) as soon as WGC's anchors exist. The reverse order also works
  but couples SI's landing to the heaviest render PR (ARIDs + ShapeMesh).
* **P3 before P4 for one hard reason** — the frozen-sea/φ ordering constraint
  (§1.5 risk 3): biome temperature must exist before the temperature-coupled
  solver judges generated ice.
* **Streaming and ZoneChunks last** — RMS's own header says the drivers
  (p2p, persistence, thousands of materials) are "not needed yet, designed for
  now"; its §13.2 revisions additionally depend on ARIDs (P5) being real.
  Nothing upstream blocks on it: the dense-id world keeps working throughout.
* **Textures independent** — Decision D; new tiles are additive data.
