# COSMOS-AUDIT — Adversarial audit of the curved-planet subsystem (concurrency + soundness)

Status: **INDEPENDENT AUDIT** (read-only; no code changed). Scope: the COSMOS curved path
(M0–M3) as committed at **HEAD = f6db772**, plus the in-flight pass-2 working-tree diff
(`cube_sphere.gd`, `terrain_config.gd`, the `repro_percell.gd`/`repro_sv_race.gd` harnesses),
read against `docs/COSMOS-ARCHITECTURE.md` and `docs/COSMOS-PLANET-TOPOLOGY.md`.
All `terrain_config.gd`/`cube_sphere.gd` line numbers cite the **HEAD** versions
(the working tree is mid-edit); working-tree changes are cited as "pass-2 WIP".

**Locked constraint honoured throughout:** multithreaded worldgen is a hard requirement.
Serializing generation and per-cell locking are evaluated only to disqualify them; the
recommended design is fully parallel and thread-safe by construction.

---

## 0. Executive verdict

1. **The race is NOT a fundamental architectural flaw — but it is also not "one bug".**
   The M0–M3 *topology* architecture (cube-sphere lattice, equal-angle warp, D4 edge remaps,
   integer floating-origin chart, y ↦ r physics) is sound and, remarkably, already *shaped*
   for parallelism: the math kernel is pure f64, the remap tables are freeze-once, the module
   generator owns a per-task `pcache`. What is missing is a **concurrency model**: neither
   COSMOS doc says one word about which code runs on godot_voxel's worker pool, and the
   implementation enforces worker-purity by *scattered conventions* (comments, a
   `pcache == null && _on_main_thread()` guard replicated at ~6 call sites, "setup/verify
   only, never the voxel worker" comments with no guard at all). TOPOLOGY §8.2 specifies
   **value**-determinism ("pure function of (SEED, body, face, i, j, r)") but never
   **implementation** purity (zero writes to shared state on the worker path). The curved
   path then violated both: a mutable global (`_active_face`) sits on the per-column hot
   path of every worker, and (pre-pass-1) a lazily-built static table (`_edge_cache`) was
   first-touched on workers.

2. **Pre-warming is inherently incomplete — the whack-a-mole is structural, not bad luck.**
   Prewarm fixes exactly one class (lazy init). It cannot fix (a) state *designed* to mutate
   at runtime (`_active_face`, the chart, the module's lazy ARID appends), (b) the next
   feature's next `static var` cache (terrain_config alone has 15+), or (c) a missed guard.
   Two fix passes have each asserted a different empirical mechanism; pass-2's central claim
   (concurrent *reads* of a frozen `const` Array corrupt) is **inconsistent with the flat
   path's own stability** — the flat worker reads the identical `_ORE_YMIN`/`_STRATA_SEQ`
   tables per underground cell today, at scale, without incident — and pass-2 itself leaves
   `BODY_N.get(...)` (a const Dictionary read, executed per curved column,
   `terrain_config.gd:539-540`) untouched. Root cause has therefore **not been pinned**;
   `repro_sv_race.gd` is the right experiment and its result must gate the design (see §5 Q1).

3. **Single most important recommendation:** stop patching read sites and adopt a
   **frozen-epoch, pure-generator contract**: every table built and frozen on the main
   thread *before* any worker exists; the per-cell generator becomes
   `f(global_cell, GenContext, SEED) → packed` where `GenContext` (face, N, R, per-task memo)
   is an **immutable snapshot passed as a parameter** — `_active_face` never read from a
   worker; per-column memos structurally unreachable from the generator. This is a
   **bounded, mechanical refactor of ~5 files** (§3), it is *required anyway* as a
   prerequisite for the M4 dual-window handoff (two live generators homed on two faces
   cannot share one `_active_face` global), and it *also* fixes a separate, non-concurrency
   correctness bug this audit found: **the module worker generates seam-strip cells in
   unfolded home-face coordinates while the analytic path uses folded true-global
   coordinates, so ores/strata/bedrock/trees/smoothing shapes diverge render-vs-physics
   within ~256 cells of every face edge** (§4, F2).

**Verdict in one line:** architecture sound, concurrency model absent; fix the disease with
a bounded purity refactor (no rethink of M0–M3), and do not ship another spot fix until the
actual memory-corruption mechanism is pinned by the repro harnesses.

---

## 1. Ground truth: what actually runs on worker threads

- godot_voxel invokes `VoxelGeneratorScript._generate_block` on its task pool. The web build
  runs **2 worker threads, not 1**: `project.godot:63` (`threads/count/minimum=2`, with the
  comment block at `project.godot:50-62` explaining the deliberate choice). Both COSMOS docs
  assert "ONE voxel thread on web" (COSMOS-ARCHITECTURE §0 R2 and §2 render-paths row;
  COSMOS-PLANET-TOPOLOGY §8.1 table "1 worker"). **Doc/code drift** — and it matters:
  worker↔worker races are possible, not just main↔worker.
- The worker executes, per block (`module_world.gd:1393-1597`):
  `TerrainConfig.column_profile(ox+x, oz+z, pcache)` (`:1445`) →
  `TerrainConfig.resolve_cell(wx, oy+y, wz, …, pcache)` (`:1467`) → inside those:
  `_curved_profile` → `LatticeNav.dir_of` → `CubeSphere.fold_cell` → `edge_remap`;
  `TreeGen.block_at`; the smoothing/slope/snow stencils; the FastNoiseLite statics; the
  frozen ARID tables published via `gen.set(...)` (`module_world.gd:1607-1625`).
- Concurrently, the **main thread** runs the same TerrainConfig entry points continuously:
  the analytic physics (`floor_under`/`blocked`/DDA → `cell_value_at`,
  `world_manager.gd:186-196`), `GroundCollider` rebuilds, `PerVoxelEnvironment`/HUD
  (`per_voxel_environment.gd:89-99`), FarTerrain sampling — plus the runtime *mutations*:
  the shape memo (`terrain_config.gd:1193-1196`), `set_active_face` on flip
  (`terrain_config.gd:525-529`, driven from `player.gd:188` → 
  `world_manager.gd:788-812`), and the module's lazy ARID appends (`module_world.gd:415-428,
  448-464`).
- The flat path is the proof that "safe" is achievable here: the module generator's frozen
  tables (`module_world.gd:186-190` — baked and frozen *before* the generator is wired at
  `:195`), the per-task `pcache` (`:1442`, "LOCAL to this _generate_block frame … never
  shared across threads"), and the memo's dual guard (`terrain_config.gd:1141-1146` "THREAD
  SAFETY — READ THIS … Do NOT remove the pcache==null + main-thread guards") — all
  correct, all *conventions*.

---

## 2. Q1 — Root cause: the shared-mutable-state inventory (worker-reachable, curved mode)

Classification: **[FROZEN]** = safe after prewarm (built once on main before workers, never
mutated again); **[RACY]** = genuinely mutated while workers run; **[MAIN-ONLY]** = workers
structurally or conventionally never reach it; **[CONST]** = read-only container.

| # | State | Location | Mutated when | Worker reads it? | Class |
|---|---|---|---|---|---|
| 1 | Noise stack `_hills/_detail/_continent/_temperature/_humidity/_mountain` | `terrain_config.gd:203-208` | `warm_up()` only (`:323-334`) | every column | **[FROZEN]** |
| 2 | `_ids_ready` + `_ID_*` + `_STRATA_SEQ/_BAND_SEQ/_ORE_STONE/_ORE_DEEP` | `terrain_config.gd:211-230` | `warm_up()`; dormant lazy re-entry `resolve_cell:614`, `generated_cell_global:594` | every cell | **[FROZEN]** (lazy fallback is a landmine if warm-up order ever changes) |
| 3 | TreeGen `_sp_ready` + species ids | `tree_gen.gd:42-58` | `warm_up()`; **dormant lazy fallback on the worker** `tree_gen.gd:142-146` (`if not _sp_ready: warm_up()`) | per tree cell | **[FROZEN]** (same landmine, explicitly wired to fire on a worker) |
| 4 | `CubeSphere._edge_cache` (Dictionary → Array of Dictionaries of Arrays) | `cube_sphere.gd:102, 356-364` | prewarmed for `n_for(HOME_BODY)` (`warm_edge_tables:366-374`, called from `terrain_config.gd:333-334`); still lazily mutable for any *other* `n` | per seam-strip column (`fold_cell:287-310`) | **[FROZEN]** today; open-set by key — this was the real, confirmed pass-1 race (worker first-touch of the lazy build concurrent with main-thread folds) |
| 5 | **`TerrainConfig._active_face`** | `terrain_config.gd:515` | **runtime**: `set_active_face` on chart install and on every home-face flip (`world_manager.gd:92, 757, 806`) | **every curved column** — `height_at:421-422`, `column_profile:479-484` | **[RACY]** — the one mutable global on the per-column worker hot path |
| 6 | `_shape_memo` | `terrain_config.gd:1149` | constantly on main (`_shape_entry:1193-1196`; cleared by flip `:529` and at `_MEMO_MAX:1193`) | no — guarded at `:872, :1078, :1092, :1208, :1228` | **[MAIN-ONLY]** by a guard replicated at every consulting site; one missed guard = Dictionary race |
| 7 | Module `_cube_arid` / `_arid_by_key` / `_next_arid` / library models | `module_world.gd:37-39, 415-428, 448-464` | **runtime** main-thread lazy append when an edit carries an unseen (mat, modifier) (`set_cell:236-246` → `arid_for:396-428`) | worker reads `cube_arid` per cell (shared PackedInt32Array, `gen.set:1607`) | **[RACY-latent]** — manifest completeness makes it ~never fire, but nothing *prevents* it; present in flat mode too |
| 8 | Frozen ARID tables `_gen_arid/_snow_arid/_layer_arid/_comp_*/_slope_*/_surface_arid/_gen_twin_arid` | `module_world.gd:51-123` | frozen at setup **before** the generator exists (`:186-195`) | per cell | **[FROZEN]** — the model to copy |
| 9 | `_chart` (`face`, `i_org`, `j_org`) | `world_manager.gd:32`; mutated by `maybe_reanchor:771-786` and `maybe_flip_home_face:788-812` | runtime, main | **no** — the module generator receives raw voxel coords which *are* face-index coords, so re-anchors are invisible to workers (a genuinely elegant property of the §3.2 integer-origin design) | **[MAIN-ONLY]**; but the flip is a non-atomic multi-step (chart → `set_active_face` → indices → restream) with **no worker quiesce** — in-flight tasks straddle it |
| 10 | `const` container tables (`FACE_N/U/V` `cube_sphere.gd:41-49`, `_ORE_YMIN…` `terrain_config.gd:192-195`, `BODY_N/BODY_R` dicts `:60-71`) | — | never (GDScript consts are read-only) | per cell | **[CONST]** — safe under Godot's documented model ("reads from multiple threads are safe if nothing writes"); see §5 Q1 for why pass-2's contrary claim must be settled by experiment, not assumed |
| 11 | Setup-only caches `_emitted_mods/_cold_pairs/_shore_pairs_by_kind/_mountains_cache/_slope_payloads/_slope_pairs` | `terrain_config.gd:1361-1362, 1720, 1794-95, 1863, 1969-70, 2015-16` | lazy, main-thread setup/verify | never — **by comment only**, zero guards | **[MAIN-ONLY]** by convention; unguarded |
| 12 | `CosmosBend` shader statics, `PerVoxelEnvironment._chart`, `_edits/_meta/_edit_columns/_placed_top` | various | main | never | **[MAIN-ONLY]** |
| 13 | `pcache`, `profs`, `VoxelBuffer` | `module_world.gd:1432-1442` | per-task | own copy | **local — safe** |

### The design-level root cause

Three compounding facts, none of them a single line bug:

1. **The curved path put runtime-mutable state (#5) and a lazily-built table (#4) onto the
   worker hot path**, in a codebase whose flat-path safety was *conventional*, not
   structural. The flat module generator is effectively pure (frozen tables + pcache); the
   curved additions broke that purity without anyone noticing because **no document or
   mechanism states the invariant "the worker path takes zero writes to shared state"**.
   TOPOLOGY §8.2's determinism invariant is about output values; it is silent on
   implementation effects, and the M0–M3 build order (§9) never names threading as a risk
   (M4's "2 nodes on 1 web worker" is a *throughput* worry, not a safety one).
2. **The 2-arg query API (`height_at(x,z)` / `column_profile(x,z)`) + `_active_face` is a
   hidden global parameter to generation.** The choke-point design (fold at
   `cell_value_at`/`_write_cell`, TOPOLOGY §3.1) was correct for *storage*, but generation
   has a third entry — the worker callback — which was *supposed* to fold
   (TOPOLOGY §3.1: "plus the generator callback") and does not (§4, F2).
3. **The guard pattern does not compose.** Every new query family (snow, slope, caps) had to
   re-implement the `pcache==null && _on_main_thread()` dance (`terrain_config.gd:872, 1078,
   1092, 1208, 1228`); every new feature added statics; nothing fails loudly when a
   convention is missed — the OOB fence (`module_world.gd:1588-1596`) then silently converts
   corrupted table lookups into plausible cubes.

**Is prewarm a complete strategy? No — provably.** Items #5, #7, #9 are *runtime* mutations
that no amount of prewarming addresses; items #3, #4 keep dormant lazy paths that reactivate
if call order changes; item #11 is unguarded convention. Prewarm is a necessary boot-phase
step of the correct design (freeze-then-spawn), but as a *bug-fixing strategy* it is
whack-a-mole by construction: it patches instances of a class while the class keeps growing.

### Assessment of the two fix passes

- **Pass 1** (2214f05: prewarm `_edge_cache`; f6db772: OOB fence, bake trim) — the
  `_edge_cache` lazy-build race was real and correctly killed
  (`cube_sphere.gd:366-374` documents it precisely). Right fix, wrong level: it froze one
  table instead of instituting the freeze phase.
- **Pass 2 (WIP)** — three moves: (a) `FACE_N/U/V` → `match`-of-literals `Vector3i`
  accessors; (b) `_ORE_*` → `match`-of-literals; (c) a **Mutex around `edge_remap`** that
  copies each entry into a fresh per-call Dictionary. (a)/(b) are harmless and even good
  hygiene (container-free per-cell reads), but the justifying mechanism ("reading a frozen
  const Array COW-refs unsafely, ~1e-5 corruption") is unproven and contradicted by flat-path
  stability; if it *were* true, `BODY_N.get()` per curved column and every Dictionary the
  fold still returns would be equally doomed — the fix is not even self-consistent.
  (c) is worse than harmless: **it puts a lock + two Dictionary allocations on the per-column
  path of every seam-strip column** — exactly the face-crossing restream moment when the
  worker must mesh ~1,600 blocks fast (TOPOLOGY §8.1) — and per the locked constraint,
  per-cell locking on the hot path is disqualified. The frozen-table alternative (§3.2)
  achieves the same safety with zero locks and zero allocation.

---

## 3. Q2 — The thread-safe-by-construction design (fully parallel, no hot-path locks)

### 3.1 The contract (one paragraph that belongs in COSMOS-PLANET-TOPOLOGY as §8.3)

> **Generation epoch contract.** All generation-visible tables are built and frozen on the
> main thread before any voxel worker exists (a one-time init lock here is fine). The
> per-cell generator is a pure function `f(global_cell, ctx, SEED) → packed` where `ctx` is
> an immutable per-generator snapshot (body, face, N, R, frozen table refs) plus a per-task
> scratch memo. The worker path performs **zero writes** to any `static var` or shared
> container, and reads **no** mutable global. Any state that must change at runtime (home
> face, chart origin, ARID growth) changes only by **creating a new epoch** (a new generator
> snapshot + restream), never by mutating the one workers hold.

### 3.2 Concrete changes (in dependency order)

1. **Freeze phase, made structural** (`terrain_config.gd`, `cube_sphere.gd`,
   `module_world.gd`): keep `warm_up()` as is, then set a `_frozen := true` latch; in debug
   builds, assert-on-write in the lazy fallbacks (`_ensure_ids`, `TreeGen.warm_up`'s
   `block_at` fallback at `tree_gen.gd:142-146`, `_ensure_edge_table`) so a violated freeze
   fails loudly in verify instead of corrupting in a browser. Convert `_edge_cache` from
   Dictionary-of-Array-of-Dictionary-of-Arrays to a **flat `PackedInt32Array`**
   (24 entries × 7 ints: `b, m00, m01, m10, m11, t0, t1`), built once in `warm_up`, read by
   index arithmetic — container-free, lock-free, allocation-free `fold_cell`. This subsumes
   pass-2's mutex with zero hot-path cost. (Pass-2's `match`-literal axis/ore accessors are
   compatible and can stay.)
2. **Kill `_active_face` on the worker path** (`terrain_config.gd`, `module_world.gd`):
   the generator snapshot carries the face. Mechanically: `_make_generator()` already
   publishes frozen state via `gen.set(...)` — add `gen.set("gen_face", face)` and thread it
   as a parameter: `column_profile(x, z, pcache)` grows a curved twin
   `column_profile_on(face, i, j, ctx)`; `resolve_cell` and the stencil helpers already take
   `pcache` everywhere — generalize that parameter to a small `GenContext` (face + memo
   Dictionary), which makes the plumbing a find-and-extend of the existing `pcache`
   signatures rather than new architecture. `_active_face` remains as a *main-thread-only*
   convenience for the analytic 2-arg wrappers (or better, those route through `_chart`,
   which main already owns).
3. **Fold once per column in the worker generator** (`module_world.gd:1443-1446`): compute
   `gcol = LatticeNav.fold_column(gen_face, ox+x, oz+z, n)` and use the **true**
   `(gcol.face, gcol.i, gcol.j)` for the profile, `resolve_cell`'s hashes, and
   `TreeGen.block_at`, while writing into the buffer at local coords. Fast path (in-range) is
   one range check — >99.9 % of columns (TOPOLOGY §4.4). This simultaneously fixes finding
   F2 (render/physics divergence in seam strips) and completes the fold the design already
   required of "the generator callback" (TOPOLOGY §3.1).
4. **Epoch flip instead of mutate-under-workers** (`world_manager.gd:788-812`,
   `module_world.gd`): `maybe_flip_home_face` builds a **new generator** (new face snapshot),
   swaps it onto the terrain, and performs the hard restream (which the module path must
   actually implement — today `restream()` exists only on the fallback,
   `chunk_streamer.gd:100`; see F3). In-flight blocks from the old epoch are keyed to the old
   generator's face and get dropped with the restream — no torn batches. This is *exactly*
   the shape M4's dual-window handoff needs (two generators, two faces, concurrently), so
   the work is not throwaway.
5. **Memos structurally main-thread** (`terrain_config.gd:1122-1197`): move `_shape_memo` +
   `_shape_entry` + the memo-consulting fast paths out of the static TerrainConfig namespace
   into a main-thread-owned object (e.g. a `ShapeCache` instance held by WorldManager,
   consulted by the analytic wrappers). TerrainConfig's static API becomes pure. Then
   "the worker never reaches the memo" is true because the generator has no reference to
   it — not because six guards all held.
6. **Instrument the OOB fence** (`module_world.gd:1588-1596`): count clamps and surface the
   counter (PerfHUD/console). Today a raced or stale ARID silently becomes a cube; the fence
   must stay (web must not crash) but silence is how "count-clean, material-corrupt" worlds
   ship.

### 3.3 Options compared

| Option | Verdict | Why |
|---|---|---|
| **(a) Purify the gen path (above)** | **Recommended** | Fully parallel (locked constraint satisfied); bounded (~5 files: `terrain_config.gd`, `module_world.gd`, `cube_sphere.gd`, `world_manager.gd`, `tree_gen.gd` + `lattice_nav.gd` touch); no M0–M3 interface change — the topology, keys, remaps, chart, warp are untouched; prerequisite for M4 anyway; also fixes F2/F3 |
| (b) Serialize / move curved gen off the pool | **Disqualified** by the locked constraint — and it would not even work: capping the pool to 1 still leaves main↔worker concurrency (the analytic queries share the same code), so you would have to run generation *on the main thread* to truly serialize — unacceptable on the web frame budget; and it halves the throughput the face-crossing restream budget (TOPOLOGY §8.1) depends on |
| Per-cell mutex (pass-2's `edge_remap` lock generalized) | **Disqualified** — contends precisely at the restream burst; allocates per fold; and it protects only the sites someone remembered to lock — the same convention fragility with extra latency |
| (c) Different planet-gen approach (offline per-face bakes; GPU gen; C++ module generator) | Not now | GPU/compute is unavailable on WebGL2 (COSMOS §2 deploy row); offline bakes break the infinite-detail edit model; a C++ `VoxelGeneratorScript` port is a legitimate *later* perf/safety hardening (the custom engine build makes it possible) but is weeks of toolchain work and unnecessary once (a) lands — unless the repro harness proves engine-level container-read corruption (§5 Q1), in which case container-free GDScript (already implied by (a)) or C++ becomes mandatory rather than optional |

**Scope estimate:** the refactor is parameter-plumbing, not redesign — `pcache` already flows
through every relevant signature, `generated_cell_global(face, …)` already has the right
outer shape (`terrain_config.gd:591-597`), and the module already publishes frozen state to
the generator. Call it days, not weeks, plus a curved verify gate (§4 F5). M1–M3 docs need
no interface amendment; TOPOLOGY gains the §8.3 threading contract and corrects the
"1 worker" claims.

---

## 4. Q3 + Q4 — Findings, ranked by severity

**F1 — `_active_face` is read by workers while the main thread mutates it (HIGH).**
Answer to Q3 precisely: `set_active_face` is **never called from generation** — its only
runtime callers are main-thread (`world_manager.gd:92` in `_ready`, `:757` in
`install_chart`, `:806` in `maybe_flip_home_face`, driven from `player.gd:188`). But every
curved worker column reads it (`terrain_config.gd:422, 484`), and the flip performs **no
worker quiesce/epoch handshake**, so in-flight `_generate_block` tasks mix face-A and face-B
content within one batch, and a block queued pre-flip completes post-flip generating the
wrong face's content at its coordinates. As a bare int it is not the memory-corruption
vector (a torn read still yields old-or-new), but it is a determinism race, it violates
TOPOLOGY §8.2 ("the window never enters generation" — here the *window's home face* is a
global input), and it is a hard blocker for M4 (two concurrent generators cannot share it).
The companion mutation `_shape_memo.clear()` inside `set_active_face`
(`terrain_config.gd:529`) is main-thread-safe but confirms the design smell: the 2-arg query
layer is window-relative by construction.

**F2 — Module worker generates seam strips in unfolded coordinates: render ≠ physics near
every face edge (HIGH; independent of the race).**
The analytic path folds first: `cell_value_at` → `_chart.to_global(cell)` →
`generated_cell_global(true_face, true_i, true_j, r)` (`world_manager.gd:186-196`). The
worker path does not: `_generate_block` feeds raw home-face-continued coords into
`column_profile(ox+x, oz+z)` and `resolve_cell(wx, oy+y, wz, …)`
(`module_world.gd:1445, 1467`), and `generated_cell_global` itself passes its *unfolded*
`(i, j)` into `resolve_cell` (`terrain_config.gd:596-597`) — only the *profile* folds
(via `LatticeNav.dir_of` inside `_curved_profile:537-553`). Heights/biomes therefore agree
across the seam (which is exactly what `verify_cosmos_m3.gd:95-127` pins — it compares
`_curved_profile` only), but every **position-hashed** feature diverges in the extension
strips: `_bedrock_at`/strata/ore lattices hash raw `(x, y, z)`
(`terrain_config.gd:338-342, 1453-1459`), `TreeGen`'s G=10 grid and P-patch grid divide raw
indices (`tree_gen.gd:123-125, 94-99`), and the smoothing/slope corner order rotates under
the D4 remap. Consequences: within ~256 cells of a seam, the rendered world (worker,
A-continued hashes) and the collided/broken world (analytic, true-global hashes) disagree —
invisible-but-solid or visible-but-passable tree blocks, ore veins that break into a
different material than shown, rotated ramp shapes vs collider planes; and after a home-face
flip the restreamed strip *reshuffles* (trees pop, ores move), contradicting TOPOLOGY §4.4's
"a tree whose trunk stands on face A grows the same canopy cells into face B from every
window" and §8.2. Fix = §3.2 item 3 (fold-once-per-column) plus a window-independent grid
rule for TreeGen (minimum: fold the query column before grid division — deterministic canopy
clipping at seams from every window; better, later: base-face-owned grid via unfold).

**F3 — Home-face flip on the module path does not restream at all (HIGH).**
`WorldManager._restream()` calls `_module_world.restream()` only `if has_method`
(`world_manager.gd:843-849`) — and `module_world.gd` has **no `restream()` method** (only the
fallback does, `chunk_streamer.gd:100`). On the web build a flip therefore: mutates
`_active_face` + chart, rebuilds collider indices — and leaves **all face-A meshes standing**
while physics and new streaming use face B. The world_manager comment ("module keeps the
analytic far field as cover during the drop", `:797`) describes a drop that never happens.
M3 was declared fallback-grade (TOPOLOGY §9 M3), but the code *claims* module coverage it
does not have. Must be implemented as part of the epoch flip (§3.2 item 4).

**F4 — Unpinned corruption mechanism; fix passes are steering by folklore (HIGH, process).**
Pass-1's `_edge_cache` race was real. Pass-2's "frozen const Array reads corrupt" claim
contradicts flat-path evidence and Godot's documented model (reads of never-written
containers are safe; `Array`'s refcount is atomic). The `array.cpp:61 _ref` flood +
`vox_blocks=0` + worker OOB is equally consistent with *any* residual write to a shared
container under read (e.g. #4 pre-pass-1; #7 if an unseen-pair edit fires; an unnoticed
lazy build) — or, worst case, with a wasm-build engine defect in container refcounting.
`repro_sv_race.gd` (pure concurrent reads of a `static var` Array + const Dictionary) and
`repro_percell.gd` (per-block hash under 6 workers + main-thread fold storm) are exactly the
right instruments. **Decision rule:** if `repro_sv_race` shows corruption on pure reads,
that is an engine bug — file it against the custom build, and make the worker path
container-free (flat Packed arrays + match-literals + Vector3i — §3.2 already implies this)
or move it to C++; if it shows none, then a mutation site is still live and the per-cell
hash harness should bisect it *before* any further read-site rewrites are trusted.

**F5 — `FLAT_WORLD` as a compile const makes the curved path untestable by default (MEDIUM).**
The safety rationale (byte-identical flat world, one flip point, `cube_sphere.gd:74-82`) is
sound, and a *const* lets the GDScript compiler treat flat branches as dead — but the cost
is that `verify_feature.gd` (the CI gate, 6027/0) exercises **only** the flat path;
`verify_cosmos_m2/m3` deliberately inject charts "without flipping the FLAT_WORLD const"
(`world_manager.gd:750-753`), so the curved *worldgen* + threading paths run **nowhere**
except a hand-edited build in a browser — which is precisely where the races surfaced.
Keep the const for the shipping flat build if desired, but (a) add a curved verify suite
that runs in CI against a curved-const build (the repro harnesses are the seed), and
(b) prefer a boot-time-frozen runtime config (read once in `warm_up`, before workers) over a
source edit — same safety (never mutates after freeze), testable both ways in one binary.

**F6 — Docs claim 1 web voxel worker; the build runs 2 (MEDIUM, doc drift).**
`project.godot:63` vs COSMOS-ARCHITECTURE §0 R2/§2 and TOPOLOGY §8.1. All R2 budget
arithmetic and the M4 heap/threading risk assessment should be re-checked against 2 workers
(more throughput, more concurrency).

**F7 — Latent mutable-under-worker states (LOW-MEDIUM).**
(i) `_cube_arid`/`_arid_by_key`/library lazy append on main during `set_cell` with an unseen
pair (`module_world.gd:415-428, 448-464`) mutates a PackedInt32Array the workers read —
today suppressed by manifest completeness, not by design; the epoch contract should freeze
these too (unseen pairs → cube fallback + log, never a runtime append while workers live).
(ii) `TreeGen.block_at`'s on-worker lazy `warm_up()` fallback (`tree_gen.gd:142-146`).
(iii) `_edge_cache` remains lazily growable for a foreign `n`. (iv) The setup-only caches
(#11) have no guard. All cheap to close under §3.2 item 1.

**F8 — OOB fence masks corruption silently (LOW as a bug, MEDIUM as diagnosability).**
`module_world.gd:1588-1596` clamps without counting. Keep; add telemetry (§3.2 item 6).
Note the fence also *hid* part of the race's signature — "count-clean but material-corrupt"
worlds render plausibly.

**F9 — The curved-samples-flat-worldgen adapter is sound (INFO).**
Sampling the flat noise stack at `R·d̂` with unchanged frequencies
(`terrain_config.gd:537-553, 573-584`) preserves flat feature scales at face centres; the
equal-angle metric means features compress up to 29 % in *index* space near edge midpoints
(TOPOLOGY §2.2's [0.707, 1.0] bound) — rendered as uniform cubes this is the already-locked
metric lie, invisible locally. Latitude climate via `1 − 2|d.z|` (`:563-567`) is monotonic
and pinned. Sea level as `r = 0`, bedrock at `r = −64` map 1:1. No distortion problem beyond
what TOPOLOGY §2.2/§4.6 already documents and accepts. Determinism is SEED-pure **except**
via F1/F2 (the home-face and unfolded-hash dependencies), and the documented f32
quantization at the noise boundary (TOPOLOGY §8.2) is intact.

**F10 — M4 dual-window: current structure cannot express it (INFO, forward-looking).**
Beyond `_active_face` (F1), the single `_chart`, the 2-arg analytic wrappers, and the
generator's implicit-face design all assume one window. The §3 refactor (generator-owned
face snapshots, epoch swap) is the minimal shape that makes M4's two concurrent
`VoxelTerrain`+generator pairs expressible at all. Plan it as the M4 prerequisite, not as
optional hygiene.

---

## 5. Q5 — Direct answers

**Q1 — fundamental flaw or incidental bug?** Neither pole. It is a **systemic
implementation-class defect**: the architecture's own invariant (§8.2 purity) was never
extended to implementation effects, so the curved additions legally (by the letter of the
docs) put shared-mutable state on a multithreaded path. Nothing in the cube-sphere/chart/
fold/y↦r design *requires* shared mutation — every input the worker needs is computable
from `(SEED, body, face, i, j, r)` plus frozen tables, which is the definition of fixable.
Pre-warming alone is inherently incomplete (runtime mutations #5/#7/#9; unguarded
conventions; growing static-cache surface). And the true low-level corruption mechanism is
**still unpinned** — settle it with `repro_sv_race`/`repro_percell` before trusting any
further spot fix.

**Q2 — the safer design:** the frozen-epoch pure-generator contract of §3: freeze
everything before workers spawn (one-time init lock acceptable); pure
`f(global_cell, GenContext, SEED)`; face/origin as immutable per-generator snapshots
(epoch swap on flip, never mutate-under-workers); memos structurally main-thread-only;
edge tables as flat PackedInt32Array (no locks, no per-fold allocation). Rejecting
serialization and per-cell locks per the locked constraint — both throttle the exact burst
(face-crossing restream) the design budgeted, and locks re-create the convention problem.

**Q3 —** `set_active_face` is main-thread-only in callers, but it *is* a shared mutation
executed **under** live worker generation with no handshake, read per-column by workers
(F1). Flag: `terrain_config.gd:515/525-529` written from `world_manager.gd:806` (player
tick) while `module_world.gd:1445` → `terrain_config.gd:484` reads it on the pool.

**Q4 —** see F2–F9. The most consequential non-race findings are F2 (seam strips: worker
generates unfolded — render/physics divergence today) and F3 (module flip never restreams).

**Q5 — verdict:** **The COSMOS curved architecture is fundamentally sound.** M0's math
kernel, the equal-angle lattice, the D4 remap algebra, the integer floating-origin chart,
and the y↦r physics identity survive adversarial review intact — several properties
(re-anchor invisibility to workers, frozen ARID manifests, per-task pcache) are already
thread-safety assets. What needs replacing is the **concurrency model of the generation
data flow**, and that is a bounded, mostly mechanical refactor (§3.2: ~5 files —
`terrain_config.gd` face/ctx plumbing + memo extraction, `module_world.gd` generator
snapshot + fold-per-column + restream, `cube_sphere.gd` flat edge tables, `world_manager.gd`
epoch flip, `tree_gen.gd` folded grids), not a rethink of M0–M3. The reuse of
terrain_config's worldgen is salvageable **as the pure value pipeline it mostly already
is** — what is not salvageable is its implicit-global parameterization (`_active_face`,
2-arg wrappers) on the worker path. Do the refactor before M4; M4 is impossible without it.

---

## 6. Open questions

1. **What does `repro_sv_race` actually show on the custom wasm build?** (The decision rule
   in F4 hinges on it.) If pure reads corrupt, escalate to an engine-level investigation of
   the custom 4.4.1+godot_voxel build's container refcounting under Emscripten pthreads
   before writing more GDScript workarounds.
2. **Where exactly did the post-pass-1 crash fire?** If `repro_percell` reproduces a
   per-block hash mismatch *with* the pass-2 rewrites reverted but `_edge_cache` prewarmed,
   the live mutation site is still unidentified — candidates worth bisecting: #7 (an edit
   during streaming), a missed lazy path, or main-thread `Dictionary` reads handed a dying
   inner Array from an unnoticed writer.
3. **TreeGen's window-independent grid rule near seams** (F2): fold-before-grid (cheap,
   deterministic clipping) vs base-face-owned unfold (correct canopies) — needs a small
   design note; interacts with the M5 corner fill rule.
4. **Should `FLAT_WORLD` become a boot-frozen runtime config** so one binary can run both
   verify suites (F5)? Recommended, but it must be demonstrably read-once-before-workers.
5. **Re-derive the R2/M4 budgets for 2 workers** (F6) and decide whether M4's transient
   dual-terrain phase keeps `minimum=2` or drops to 1 during the handoff.
6. **Does godot_voxel tolerate a generator swap on a live `VoxelTerrain`** (epoch flip,
   §3.2 item 4), or does the flip require terrain node recreation? (Same spike TOPOLOGY §11.5
   already files for M4 — fold the two questions together.)
