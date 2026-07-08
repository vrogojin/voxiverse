# COSMOS-M4-HANDOFF — the seam-cross near-field handoff (kill the flip blink)

Status: **LOCKED DESIGN (milestone M4 of COSMOS-PLANET-TOPOLOGY §9), revision 3 — SHIP BOTH,
memory-safe by default.** Revision 1 locked a frozen-in-place second `VoxelTerrain` as the
near cover; revision 2 replaced it with a far-LOD-only bridge under the §0 never-OOM
constraint. Revision 3 is the user's final verdict on that fork: **ship both**. The far-LOD
bridge is the always-on baseline (zero extra near-voxel memory — the literal honoring of
never-OOM); the freeze-in-place near cover is fully implemented **but gated OFF by default**
behind a one-line flag, promotable to production only through the §9.3 live A/B gate. The two
bridges **compose**: the far bridge runs at every flip regardless of the flag, so even with
the cover enabled it is the safety net behind it.

Read together with: `docs/COSMOS-PLANET-TOPOLOGY.md` (§3.2 re-anchor, §4.5 flip, §8.1
budgets), `docs/COSMOS-AUDIT.md` (§3.2 frozen-epoch contract, F3), `docs/LOD-DESIGN.md` (far
layer), and the M3 far-cover implementation both bridges build on (`far_terrain.gd:160-209`).

Line numbers cite branch `feat/voxiverse-cosmos-m0` at the time of writing:
`world_manager.gd` = `godot/src/world/world_manager.gd`, `module_world.gd` =
`godot/src/world/voxel_module/module_world.gd`, `far_terrain.gd` =
`godot/src/world/far/far_terrain.gd`. Engine-source citations are the pinned build checkout
`docker/engine/cache/godot/modules/voxel` (godot_voxel @ `903d1fb`, the exact code compiled
into the live editor + web templates).

---

## 0. The never-OOM invariant (locked, non-negotiable)

> **Locked decision (user-issued hard constraint):** the web build must **never risk an
> out-of-memory**, even where that makes the seam-cross visual bridge briefer, coarser, or
> less complete. Memory safety outranks bridge quality. Concretely:
>
> 1. **The shipped default holds exactly one near voxel volume at all times.**
>    `NEAR_COVER_ENABLED := false` is the checked-in state; the baseline bridge (§2) adds
>    zero near-voxel memory.
> 2. **The opt-in near cover (§3) may only be enabled in production through the §9.3 A/B
>    gate** — measured heap flatness on the low-end target, the single-cover invariant, and
>    clean retirement telemetry are the go criteria. Absent that evidence, the flag stays off.
> 3. **Every bridge structure carries an explicit ceiling** (count/triangle caps or a
>    single-instance invariant enforced in code) *and* a hard lifetime cap — whichever frees
>    first.
> 4. **Degradation is ordered memory safety first, visual completeness second** (§7); the
>    never-OOM rule is the selector.

---

## 1. The problem, and the insight that makes it cheap

### 1.1 What happens today at a flip

When the player walks `FLIP_HYST = 64` cells past a cube-face edge,
`WorldManager.maybe_flip_home_face()` (`world_manager.gd:809`) fires:

1. `chart.flip()` (`cosmos_chart.gd:151`) re-bases the window onto the neighbour face. The
   player's WORLD position is continuous (bit-exact, verify M3 gate (d)), but the integer
   origin `(i_org, j_org)` jumps by ~a face width `n` (`cosmos_chart.gd:163`).
2. WorldManager sets `_module_world.position` to the NEW frame, then calls `set_home_face`
   (`world_manager.gd:827-830`).
3. `module_world.set_home_face()` (`module_world.gd:1070`) installs a new frozen-epoch
   generator and `restream()`s (`module_world.gd:1080`): the whole `VoxelTerrain` is destroyed
   and rebuilt from `RAMP_START_BLOCKS = 48` outward over `RAMP_SECONDS = 1.5` (+ a few
   seconds of meshing on the 2–3 web workers).

That teardown is the blink. Live PERF log at a flip: `draws 75→18, prims 236036→12808,
vox_gen 2270→5723`. The only bridge is the far layer: `far_terrain.rebase_to()`
(`far_terrain.gd:167`) stashes still-world-correct tiles as the `FarStaleCover`, but keeps
only tiles **fully inside the old face** (`_tile_fully_in_face`, `far_terrain.gd:312` — the
bug-B fix; edge-straddling tiles were placed by the old unfold convention and would render
displaced). At a seam crossing the tiles *around the player straddle the edge*, so almost the
entire near-to-mid distance is freed → the near-total void the player sees, until new-frame
tiles rebuild under a 3 ms/frame budget and the near field refills behind them.

### 1.2 The deterministic-content insight

Worldgen is deterministic per **global** cell (TOPOLOGY §8.2, enforced by the audit's
frozen-epoch pure-generator contract), and the far tiles sample the *same*
`TerrainConfig.height_at`/`column_profile` the near field derives from (LOD-DESIGN §3), with
bend parity in curved mode (Stage 3). Three consequences the design exploits:

- New-frame far tiles and the new near field **agree with each other and with everything the
  player saw before the flip** — a far tile built in the new frame is a correct coarse
  stand-in for the near terrain at that spot, immediately. This powers the **baseline** (§2).
- The old near meshes are **byte-identical in content** to what the new frame will rebuild;
  only the coordinate *labels* jump by ~`n`. Held at their old world position they are
  visually correct — this powers the **opt-in cover** (§3).
- The blink is therefore a *fill-rate* problem, not a content problem; both bridges are pure
  render-side patience mechanisms over identical ground truth.

> **Locked decision:** M4 is **render-only** in both modes. Physics is analytic through
> `WorldManager.block_id_at` (CLAUDE.md rule 1) and is already correct through the flip
> (`_rebuild_window_indices` + `GroundCollider.rebuild_now`); nothing here touches gameplay,
> edits-as-truth, or the sim layer.

---

## 2. The BASELINE (always-on, ships first): the far-first bridge

### 2.1 The mechanism in one paragraph

At a flip, the old near `VoxelTerrain` is freed immediately (today's behaviour,
`module_world.gd:1096-1099` — with the flag off, byte-for-byte) and three bounded mechanisms
overlap so the player sees coarse terrain instead of void: (i) the **existing far stale
cover** holds the old-face horizon (unchanged, `far_terrain.gd:167-209`); (ii) a new,
time-boxed **handoff turbo** in the far layer raises the tile build budget and commit rate
and keeps the nearest-first ordering, so the new-frame ring-0 tiles under and around the
player commit within the first ~0.2–0.5 s — coarse (4 m cells) but aligned and correct
(§1.2), biased 1.5 blocks under the walk surface exactly as in steady state; (iii) the near
`VoxelTerrain` restreams behind them exactly as today (frozen-epoch swap +
`RAMP_START_BLOCKS → 128` ramp), replacing coarse with full detail from the player outward.
When the near ramp completes, WorldManager re-mirrors player edits into the fresh terrain
(§5.4) and ends the turbo. Zero near-voxel memory is duplicated; the entire bridge lives
inside the far layer's existing hard caps.

### 2.2 Why "re-render the far LOD fast" means turbo, not an inner-hole drop

A correction to the locked sketch, discovered while deriving this baseline: TOPOLOGY §4.5.2
proposed bridging by *dropping the far inner hole* ("192 toward ~32"). With the shipped ring
table that is a **no-op**: `_compute_desired` excludes a tile only when it lies *entirely*
inside the hole (`maxd <= hole`, `far_terrain.gd:260-261`), and a ring-0 tile is 256 m — its
farthest corner is ≥ 128√2 ≈ 181 m from any interior point, so no ring-0 tile is ever
entirely inside the 112-block curved hole. **The tile under the player is already in the
desired set today.** The void is not a selection gap; it is a *throughput* gap: after
`rebase_to` drops the edge-straddling tiles, replacements build at `FAR_BUILD_BUDGET_MS =
3.0` ms/frame, `MAX_COMMITS_PER_FRAME = 1` (`far_terrain.gd:47-48`). The levers that close
it — this is the concrete form of the brief's "far inner-hole drop / fast re-render":

- **Priority** — nearest-first while bridging: already shipped (the `cover_active` sort,
  `far_terrain.gd:227-234`, the bug-B follow-up). Extended to stay active for the whole
  handoff window, not just while the stale cover lives.
- **Throughput** — the turbo: while the handoff window is open, `_drain` runs with
  `HANDOFF_BUDGET_MS := 8.0` and `HANDOFF_COMMITS := 2` instead of 3.0/1. Cost is
  main-thread *milliseconds* (a bounded, brief fps dip), **zero memory**: the desired set,
  tile caps, and per-tile geometry are unchanged — the same tiles simply exist sooner.
  Sizing: a ring-0 tile is a 64×64 lattice ≈ 4.2k columns; at 8 ms/frame of curved
  `height_at` sampling plus ≤ 2 ArrayMesh uploads/frame, the 4–9 tiles nearest the player
  commit in ~0.2–0.5 s (vs ~1–2 s today), and the full 89-tile far set in a few seconds.

> **Locked decision:** the far bridge (stale cover + turbo + nearest-first) runs at **every**
> flip **regardless of `NEAR_COVER_ENABLED`** — with the cover on it is the safety net behind
> it (a cover that vanishes or misbehaves degrades to the baseline view, never to void).

### 2.3 Frame math + world continuity (baseline)

The baseline adds **no new frame arithmetic**. The far layer already owns the flip re-base:
new tiles are built in the new global frame under `position = (−i_org, 0, −j_org)`
(`world_manager.gd:834-835`), the stale cover is pinned world-fixed by
`cover.position = old_pos − new_pos` with the exactness proof at `far_terrain.gd:181-185`
(origins are integer-valued, |value| ≤ ~`n` = 10,016 ≪ 2²⁴ → the f32 compensation is
bit-exact), and a re-anchor during the handoff shifts the far node — cover riding along as a
child — by the same `−Δ` as every other render node (`world_manager.gd:792-796`). Verify M3
gate (d) (player world point bit-identical across the flip) remains the continuity anchor.

### 2.4 Optional stretch (only if live testing demands it): the pre-flip prime

The flip trigger is perfectly predictable (`flip_needed`, `cosmos_chart.gd:140-143`). If the
baseline's ~0.2–0.5 s coarse void is still objectionable *and* the cover stays no-go'd, a
separable follow-up: when the player is ≥ `FLIP_HYST − 16` cells past the edge, compute the
would-be new frame (pure math, `CubeSphere.fold_cell` — no state change) and pre-build **at
most `PRIME_MAX_TILES := 4`** ring-0 tiles in that frame, hidden, adopted instantly at the
flip. Ceiling ≤ 4 tiles ≈ ~2 MB, freed on adoption / band exit / 30 s — §0-compliant. **Not
on the M4 critical path.**

---

## 3. The OPT-IN UPGRADE (default OFF): the frozen-in-place near cover

### 3.1 The flag contract

```gdscript
# module_world.gd, beside RAMP_* (lines 42-46)
const NEAR_COVER_ENABLED := false        # DEFAULT OFF (§0). One-line production flip.
var cover_enabled := NEAR_COVER_ENABLED  # instance mirror: verify overrides it per-instance
                                         # to assert BOTH states headless; prod never writes it
```

> **Locked decision (one-line flip):** flipping the const is the **only** difference between
> the two shipped behaviours. To guarantee that, the surrounding plumbing is **always** built:
> WorldManager always captures and passes the old wrapper position (§3.2), `restream()` always
> receives it — and only the `cover_enabled` test decides *cover vs free-immediately*. Off →
> the old terrain is freed exactly as today; on → the full bridge below. No other code path
> may consult the flag.

### 3.2 Frame math / timing (the capture WorldManager must add)

The wrapper's position is already the NEW frame by the time `restream()` runs
(`world_manager.gd:828` runs before `:830`), so the OLD frame is captured and passed
unconditionally:

- `maybe_flip_home_face` captures `old_mod_pos := _module_world.position` **before** line
  828, then calls `set_home_face(_chart.face, old_mod_pos)`; `set_home_face` forwards it to
  `restream(old_mod_pos)`. (Default parameter `Vector3.INF` = "no old frame supplied" keeps
  the 1-arg call in `verify_cosmos_race.gd:125` valid — it takes the free-immediately path.)
- In `restream`, with `self.position` (the wrapper) already `P_new` and the old terrain's
  current local position `t` (zero in practice; preserved symbolically):

  ```
  old_terrain.position = t + (old_mod_pos − self.position)      # = t + P_old − P_new
  ```

**World-continuity proof** (mirrors `far_terrain.gd:181-185`): before the flip the old
terrain's world origin is `P_old + t`. After the wrapper moves to `P_new` and the
compensation is applied, it is `P_new + (t + P_old − P_new) = P_old + t` — its original world
spot, so every mesh stays exactly where the player saw it last frame. The arithmetic is
**exact**: `P_old`, `P_new` are integer-valued (`i_org`, `j_org` ∈ ℤ, |value| ≤ ~`n` =
10,016 ≪ 2²⁴), so the f32 subtraction and re-addition are bit-exact — zero sub-pixel creep.
The fresh terrain must **not** inherit the compensation: capture
`base_pos := old_terrain.position` *before* compensating and use it where line 1097 copies
the old position.

**Re-anchor during the cover's life is automatically correct.** `maybe_reanchor`
(`world_manager.gd:786-787`) shifts the *wrapper* by `−Δ` while the player and every other
render node shift by the same `−Δ` — a uniform scene-frame translation. The cover is a child
of the wrapper, so it rides along, exactly as the far cover rides `_far.position -= shift`.
No cover-specific re-anchor code is needed.

### 3.3 Freeze-in-place — why neither reparent nor harvest

| | Mechanism | Verdict |
|---|---|---|
| A | Reparent the whole `VoxelTerrain` into a world-fixed cover `Node3D` | Rejected: needless risk |
| B | Harvest only its built mesh instances; free the terrain immediately | **Infeasible — verified against pinned source** |
| C | Keep the terrain in place; compensate its local position; freeze | **Locked (as the opt-in)** |

**The harvest verification (B), against godot_voxel @ `903d1fb` — the exact pinned build:**
a `VoxelTerrain`'s built meshes live in `VoxelMeshBlockVT`/`VoxelMeshBlock` objects whose
render instance is `zylann::godot::DirectMeshInstance _mesh_instance`
(`modules/voxel/terrain/voxel_mesh_block.h:92`) — a thin RenderingServer-instance wrapper,
**never a scene-tree `MeshInstance3D`** (`get_children()` returns only user-added nodes).
`VoxelMeshBlock` is a plain `NonCopyable` C++ class (`voxel_mesh_block.h:24`) — no `GDCLASS`,
never ClassDB-registered — structurally unreachable from script. `get_mesh()` exists C++-side
(`voxel_mesh_block.h:44`, used internally at `voxel_terrain.cpp:588`) but none of
`VoxelTerrain`'s 44 bindings exposes mesh blocks, meshes, or RS instances
(`voxel_terrain.cpp:2300-2380`); RS offers no `instance_get_base`, closing the server route.
The only script-reachable "harvest" is re-meshing buffers on the main thread — the stall M4
exists to kill. Should a future engine bump bind mesh access, B becomes the preferred cover
implementation (a static snapshot with a kept-tri ceiling) slotting into §8 without redesign.

**Why C beats A.** A and C freeze the same node; they differ only in whether it crosses the
tree. Reparenting fires `EXIT_TREE`/`EXIT_WORLD` + re-entry on a live streaming C++ node —
semantics invisible from script. Position compensation avoids the question: **moving a
`VoxelTerrain`'s world transform is already exercised live on every origin re-anchor**
(`world_manager.gd:786-787`; the meshes follow), so C's only *new* engine behaviour is
`PROCESS_MODE_DISABLED` — a stock Godot node property gating process/internal-process
notifications (where godot_voxel streams, unloads, and applies task results) while leaving
rendering and transform notifications untouched. Order matters: **compensate the position
first, then disable processing** (the transform notification is applied immediately,
independent of process mode).

**Freeze semantics.** Frozen means: no new block requests, no unloading as the player's
engine-global `VoxelViewer` moves away, no application of late worker results (the handful of
in-flight tasks at freeze time complete against the old frozen-epoch generator — pure,
race-free by the audit F3 contract — and their results sit undelivered until the node is
freed, exactly as today's `queue_free()` path already discards them). The frozen cover keeps
its own old-face generator alive — precisely the "two generators, two frozen faces,
concurrently" shape `module_world.gd:1067` anticipates. The one untestable-until-live risk —
an engine assumption that a registered terrain always processes — is exactly what the §9.3
A/B gate exists to observe before any production enablement.

> **Locked decision:** the module keeps its strings/ClassDB-only discipline — the cover uses
> `Node` properties (`position`, `process_mode`) and the existing string-driven
> `is_area_meshed`, so `module_world.gd` still loads when the module is absent.

---

## 4. Memory accounting (the §0 ceiling, made explicit, both modes)

| Structure | Mode | Peak delta | Ceiling (code-enforced) | Lifetime cap |
|---|---|---|---|---|
| New near `VoxelTerrain` | both | one near field (~18 MB data + ~25–30 MB mesh) | the only *live* near volume | steady state |
| Far stale cover (existing M3) | both | old-face tiles already built — no new builds | `FAR_MAX_TILES = 120` / `FAR_MAX_TRIS = 600k` / `FAR_MAX_DRAWS = 96`, trimmed in `_apply_caps` (`far_terrain.gd:271-290`) | `COVER_MAX_SECONDS = 12` (`far_terrain.gd:93`) |
| Handoff turbo (new) | both | **0 bytes** — same desired set, built sooner; main-thread ms only | same far caps | `HANDOFF_MAX_SECONDS := 10.0` backstop |
| Edit re-mirror (new, §5.4) | both | transient Dictionary of near-radius edits | sparse (edit count), one-shot | freed on return |
| **Frozen near cover** | **flag ON only** | **≈ +50 MB transient** (~18 MB data + ~25–30 MB mesh, static — frozen ⇒ non-growing) | **single-cover invariant** (§5.2: a new flip frees the prior cover first; ≤ 1 frozen + 1 live volume ever) | `NEAR_COVER_MAX_SECONDS := 10.0`, early-retired on meshed (§5.1) |
| Pre-flip prime (optional §2.4) | both (stretch) | ≤ 4 ring-0 tiles ≈ ~2 MB | `PRIME_MAX_TILES = 4` | adoption / 30 s |

Default mode's worst instantaneous total is **one** near field + the far layer at its
existing caps — the same envelope as ordinary post-load play, which *is* the §0 guarantee by
construction. Flag-on mode adds exactly one bounded, non-growing, twice-capped transient; §9.3
is the evidence bar it must clear before production.

New constants: `HANDOFF_*` live in `far_terrain.gd` beside the budget constants they override
(`far_terrain.gd:47-48`); `NEAR_COVER_*` live in `module_world.gd` beside `RAMP_*`
(`module_world.gd:42-46`):

```gdscript
# far_terrain.gd
const HANDOFF_ENABLED := true        # §7 rung 2 kill-switch (diagnostic-toggle discipline)
const HANDOFF_BUDGET_MS := 8.0       # _drain sampling budget while the handoff window is open
const HANDOFF_COMMITS := 2           # ArrayMesh uploads per frame while open
const HANDOFF_MAX_SECONDS := 10.0    # hard close of the window (starvation backstop)

# module_world.gd
const NEAR_COVER_ENABLED := false    # §3.1 — DEFAULT OFF; the one-line production flip
const NEAR_COVER_MAX_SECONDS := 10.0 # hard transient bound (≤ far COVER_MAX_SECONDS = 12)
const NEAR_COVER_MESHED_HALF := Vector3(96.0, 32.0, 96.0)  # retirement is_area_meshed box
```

`NEAR_COVER_MESHED_HALF` checks a 96-block half-extent, not the full 128 disk: one laggard
outer mesh block must not pin the cover to its timeout, and the 96→128 annulus sits behind
the far layer's curved inner hole (`INNER_HOLE_CURVED = 112`) plus fog — retiring there is
invisible.

---

## 5. Lifecycle, composition, re-entrancy, FLAT_WORLD — and the edit re-mirror

### 5.1 One lifecycle, two modes (the flag only adds the cover branch)

```
flip (maybe_flip_home_face):
    _far.rebase_to(new_frame)                  existing — far stale cover + recompute
    _far.begin_handoff()                       NEW, both modes — opens the turbo window
    old_mod_pos captured; set_home_face(face, old_mod_pos) → restream(old_mod_pos):
        free prior near cover if any ("superseded")            flag ON only ever has one
        cover_enabled? → old terrain pinned+frozen (§3.2/§3.3) : freed immediately (today)
        new terrain built + ramp starts        existing, both modes
    _flip_settling = true                      NEW — WorldManager latch, both modes

WorldManager.update_streaming (each frame while _flip_settling):
    when module ramp_done():                   (fallback path / no module: immediately)
        _remirror_module_edits(player_pos)     §5.4 — REQUIRED IN BOTH MODES
        _far.end_handoff()
        _module_world.release_cover()          no-op when no cover exists
        _flip_settling = false

module_world._process (runs while ramp or cover active):
    ramp step (unchanged)
    if cover: _cover_age += delta
        retire when (_cover_released and ramp done and _new_field_meshed())   ("meshed")
               or _cover_age ≥ NEAR_COVER_MAX_SECONDS                        ("timeout")

far_terrain._process:
    handoff window self-closes at HANDOFF_MAX_SECONDS (backstop; headless never handshakes)
```

Sequencing note the ship-both verdict asked to confirm: the edit re-mirror is keyed on
**`ramp_done()` only** — it has no dependency on any cover. With `NEAR_COVER_ENABLED = false`
there is simply no `release_cover` effect and the re-mirror fires right after the fresh
terrain's ramp completes (near data blocks loaded ⇒ `bulk_inject` lands). With the flag on,
the same handshake additionally releases the cover, and because the re-mirror runs **before**
`release_cover`, the frame the cover disappears the new field already shows every edit — no
pop-out of player builds. `_new_field_meshed()` = `is_area_meshed` over
`NEAR_COVER_MESHED_HALF` centred on the viewer **converted into the new terrain's local voxel
frame** (`viewer.global_position − self.global_position`; do not reuse `area_meshed()`
(`module_world.gd:1368`), whose raw-world centre is a FLAT-only convention). Cover teardown
paths, exhaustively: meshed+released / timeout / superseded by the next flip / module
teardown (child ⇒ freed with the wrapper) / flag off (branch never taken). Each prints one
telemetry line (`[module_world] near cover retired (<reason>) after %.1fs`) — §9.3 watches
these.

### 5.2 Re-entrancy (second flip while bridges are open)

Far side: `rebase_to` already frees a prior far cover first (`far_terrain.gd:172-175`);
`begin_handoff` on an open window resets the clock — nothing stacks. Near side (flag on): a
border-runner can flip again within the cover's life (64 back + 64 past ≈ 14 s at sprint);
`restream()` therefore frees any existing cover **first**, then converts the *current live*
terrain (never itself a cover) into the new one. Invariant, machine-checked (§9.1): **≤ 2
`VoxelTerrain` nodes ever** (1 live + ≤ 1 frozen); flag off: **exactly 1**.

### 5.3 FLAT_WORLD stays byte-identical

`rebase_to`/`begin_handoff`/`restream` are reached only from `maybe_flip_home_face` (gated on
`_chart != null`); FLAT_WORLD never installs a chart, never flips, never restreams. The turbo
branch tests a flag never set in flat play; the cover branch sits inside `restream`. No new
code runs in the flat frame loop. Verified as gate (v6).

### 5.4 The edit re-mirror (a latent M3 gap; REQUIRED in both modes)

Today, after a module restream, player edits are **not re-injected into the render**: the
fresh `VoxelTerrain` regenerates pure worldgen, and `_edits` reaches the module render only at
edit time (`_paint_cell`, `world_manager.gd:745`) or bundle load (`bulk_inject`,
`world_manager.gd:1092-1096`). Gameplay/collision stay correct (rule-1 overlay), but the
render silently drops player builds at every flip — hidden inside today's blink, *visible* in
both M4 modes (baseline: builds would stay missing after the near field refills; cover mode:
they would pop out at retirement). M4 adds:

- `WorldManager._remirror_module_edits(player_pos)`: iterate `_edits`, unfold each global key
  into the current window (`window_of_global`, the `_rebuild_window_indices` pattern,
  `world_manager.gd:846-860`), keep cells within `TerrainConfig.near_render_radius()` of the
  player horizontally (avoids set-voxel-on-unloaded-block error spam), and hand the
  window-cell → packed dict to `bulk_inject` — dug-to-air cells (packed 0) included, so holes
  re-carve too.
- Called once per flip at `ramp_done()` (§5.1). Edits beyond the near radius re-mirror the
  way they always have: when their region is next edited/loaded (unchanged, documented).
- The fallback render path needs none of this — `ChunkStreamer` re-reads the overlay when
  meshing, so its hard restream is already edit-correct.

---

## 6. Z-fighting / double-draw

**Baseline (far ↔ near):** none by construction — far tiles sit `BIAS_LAND = 1.5` blocks
below the walk surface (`far_terrain.gd:43-44`) precisely so the near field wins cleanly
where both exist; the 112–128 overlap ring renders this way through all ordinary play today.
The handoff merely makes more of that proven overlap exist sooner. **Locked: no bias changes.**

**Flag on (cover ↔ new near):** the overlap region renders byte-identical *content* through
two vertex paths differing by an exactly-compensated integer translation, so world positions
agree to f32 round-off (sub-mm at |coord| ≤ ~10⁴; CosmosBend displaces as a function of those
world positions, agreeing to the same order). Depth values interleave per-pixel — textbook
z-fighting — **but both surfaces carry identical materials, textures and vertex colours**, so
whichever fragment wins, the pixel is the same. **Locked: accept, no bias.** `render_priority`
would not help (it orders only the transparent pass) and a depth offset means touching every
material in a live baked `VoxelBlockyLibrary`. One honest cosmetic residue: **translucent**
cells (water/glass/ice) double-blend in the overlap ring for the cover's few seconds (slightly
denser-looking water) — accepted, and one of the §9.3 A/B observation points.

---

## 7. Configuration matrix + degrade ladder (selector: the §0 invariant)

Two independent flags compose; the shipped default is row 1:

| `NEAR_COVER_ENABLED` | `HANDOFF_ENABLED` | Behaviour |
|---|---|---|
| **false (default)** | **true (default)** | **Baseline (§2): far bridge + edit re-mirror. Ships first.** |
| true (via §9.3 gate only) | true | Full bridge: frozen near cover in front, far bridge behind it as the safety net |
| false | false | Rung 2: today's M3 byte-for-byte (+ the §5.4 re-mirror, which stays at every rung) |

Degradation, per-symptom and downward only:

- **Rung 0 — the default row.** Memory: far caps only.
- **Rung 1 — turbo constants back to 3.0 ms / 1 commit.** Trigger: the 8 ms budget dips
  low-end web fps unacceptably. The window/handshake machinery, nearest-first sort and
  re-mirror all stay.
- **Rung 2 — `HANDOFF_ENABLED = false`.** Trigger: any instability attributable to the
  handoff window. Today's behaviour except the re-mirror (a correctness fix, never degraded
  away).
- The cover is **not on this ladder** — it is an upgrade above the default, entered only
  through §9.3 and exited by flipping its flag back (which lands exactly on the default row —
  the §3.1 one-line contract).

---

## 8. Implementation plan (Opus: follow edit-by-edit, in this build order)

**Stage 1 = the baseline (ships first); Stage 2 = the flag-gated cover on top.** After each
stage, the named suites must pass headless
(`docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script <suite>`).

### Stage 1 — far-LOD boost + edit re-mirror (always-on baseline)

1. **`far_terrain.gd` — the handoff window.** Add `HANDOFF_ENABLED/BUDGET_MS/COMMITS/
   MAX_SECONDS` (§4) beside lines 47-48 + state `var _handoff_left := 0.0`. Add
   `begin_handoff()` (sets `_handoff_left = HANDOFF_MAX_SECONDS` iff `ENABLED and
   HANDOFF_ENABLED`), `end_handoff()` (zeroes it), `handoff_active() -> bool`. In `_process`
   (line 355): decay `_handoff_left`; `_drain(HANDOFF_BUDGET_MS if handoff_active() else
   FAR_BUILD_BUDGET_MS)`. In `_drain` (line 371): commit limit `HANDOFF_COMMITS if
   handoff_active() else MAX_COMMITS_PER_FRAME`.
2. **`far_terrain.gd` — sort condition.** In `_recompute` (line 227):
   `var cover_active := _cover != null or handoff_active()` (nearest-first for the whole
   window). Desired-set computation, caps, far-cover lifecycle untouched.
3. **`module_world.gd` — accessor.** `func ramp_done() -> bool: return not _ramp_active`
   (beside `gen_home_face`, line 1118).
4. **`world_manager.gd` `maybe_flip_home_face` (lines 827-837).** Add
   `_far.begin_handoff()` after the existing `rebase_to` call (both render paths); after the
   module branch set `_flip_settling = true` (declare `var _flip_settling := false` in the
   M2/M3 state block). *(The `old_mod_pos` capture is Stage 2 — Stage 1 keeps the 1-arg
   `set_home_face` call.)*
5. **`world_manager.gd` `update_streaming` (lines 164-173).** Append the §5.1 settle step:
   when `_flip_settling` and (`_module_world == null` or `ramp_done()`), run
   `_remirror_module_edits(player_pos)`, `_far.end_handoff()`, clear the latch. *(The
   `release_cover()` call is added in Stage 2.)*
6. **`world_manager.gd` — `_remirror_module_edits(player_pos)`** per §5.4 (place after
   `_rebuild_window_indices`, line 846; guard `_chart == null or _module_world == null`).
7. **Verify:** new `godot/src/tools/verify_cosmos_m4.gd` gates (v1)–(v3), (v6), (v7 baseline
   half); existing M3 + race suites still green. Telemetry: flip print gains ` handoff=on`;
   `[far] handoff window closed (<handshake|timeout>) after %.1fs`.

### Stage 2 — the flag-gated freeze-in-place cover (default OFF)

8. **`module_world.gd` — flag + state + constants** (§3.1/§4, beside `RAMP_*`):
   `NEAR_COVER_ENABLED := false`, `var cover_enabled := NEAR_COVER_ENABLED`,
   `NEAR_COVER_MAX_SECONDS`, `NEAR_COVER_MESHED_HALF`, and
   `var _cover_terrain: Node3D = null`, `var _cover_age := 0.0`,
   `var _cover_released := false`.
9. **`set_home_face` (line 1070):**
   `func set_home_face(face: int, old_wrapper_pos: Vector3 = Vector3.INF) -> void:` →
   forward to `restream(old_wrapper_pos)`. (Default keeps `verify_cosmos_race.gd:125` valid.)
10. **`restream` (lines 1080-1110):** signature gains the same defaulted parameter. In order:
    `_free_cover("superseded")` first; capture `base_pos := old_terrain.position` (use it for
    the fresh terrain where line 1097 copied the old position); then
    ```gdscript
    if old_terrain != null:
        if cover_enabled and old_wrapper_pos.is_finite() and old_wrapper_pos != position:
            _cover_terrain = old_terrain
            _cover_age = 0.0
            _cover_released = false
            old_terrain.position += old_wrapper_pos - position   # pin (§3.2) …
            old_terrain.process_mode = Node.PROCESS_MODE_DISABLED  # … THEN freeze (§3.3)
        else:
            remove_child(old_terrain)
            old_terrain.queue_free()                             # today's path, byte-for-byte
    ```
    End of function: `set_process(_ramp_active or _cover_terrain != null)`.
11. **`module_world.gd` `_process` (lines 262-272):** ramp step unchanged; then the §5.1
    cover aging/retirement block; final `set_process(...)` per step 10.
12. **New helpers** (near `area_meshed`, line 1368): `_new_field_meshed()` (viewer-centred,
    frame-converted `is_area_meshed` per §5.1), `_free_cover(reason)` (null-safe free + §5.1
    telemetry), `cover_active() -> bool`, `release_cover()` (sets `_cover_released`).
13. **`world_manager.gd`:** in `maybe_flip_home_face`, capture
    `var old_mod_pos: Vector3 = _module_world.position` before line 828 and pass it:
    `set_home_face(_chart.face, old_mod_pos)`. In the step-5 settle block, add
    `_module_world.call("release_cover")` after the re-mirror (no-op when no cover).
14. **Verify:** `verify_cosmos_m4.gd` gates (v4), (v5), (v7 cover half) — the cover gates run
    with `cover_enabled = true` set on the instance (the §3.1 override discipline; the const
    stays false). `verify_cosmos_race.gd`: add a 2-arg flip pass with `cover_enabled = true`
    asserting no worker crash + blocks streaming with the frozen cover alive, plus the §3.3
    probe (old terrain has zero `MeshInstance3D` children — documents harvest-infeasibility
    against the running engine). Flip print gains ` cover=<yes|no>`.
15. **Docs:** cross-link this file from `docs/COSMOS-PLANET-TOPOLOGY.md` §4.5 (M4 landed;
    §4.5.1 superseded per §10) — one-line pointer, no restructuring.

---

## 9. Verification

### 9.1 Headless gates (`verify_cosmos_m4.gd`; module engine, real pool where noted)

- **(v1) turbo is selection-neutral:** for a fixed eval point, the desired set with the
  window open == closed (the turbo changes *when*, never *what*), and `_apply_caps` respects
  `FAR_MAX_TILES/TRIS/DRAWS` in both states.
- **(v2) window lifecycle:** begin → active; end → inactive; `_process(HANDOFF_MAX_SECONDS
  + 0.1)` alone → inactive (backstop); re-begin resets, never stacks; `HANDOFF_ENABLED =
  false` short-circuits.
- **(v3) nearest-first while open:** `drain_for_test` commit order ascends `min_dist` — the
  under-player tile first.
- **(v4) cover mechanics (instance `cover_enabled = true`; real pool):** after an emulated
  flip (wrapper moved to `P_new`, `set_home_face(face_b, P_old)`):
  `wrapper.position + cover.position == P_old` **bit-exact** (§3.2); cover
  `process_mode == PROCESS_MODE_DISABLED`; new terrain streams blocks and `oob_seen()` stays
  false with the cover alive; a second flip frees the prior cover ("superseded") — ≤ 2
  `VoxelTerrain` children ever; `_process(NEAR_COVER_MAX_SECONDS + 0.1)` alone frees it
  ("timeout"); `release_cover()` + pumping until `_new_field_meshed()` frees it ("meshed")
  before the cap.
- **(v5) default-flag byte-identity:** with `cover_enabled` left at the shipped `false` (and
  on the 1-arg call path), a flip frees the old terrain immediately, `cover_active()` is
  false throughout, module `_process` runs only during the ramp, and exactly **one**
  `VoxelTerrain` child exists across the flip — i.e. the default differs from today's
  teardown *only* by the far boost + re-mirror.
- **(v6) FLAT_WORLD byte-identity:** a chartless WorldManager lifecycle never opens a
  window, never latches `_flip_settling`, never creates a cover; `_drain` runs at stock
  3.0 ms/1-commit throughout.
- **(v7) edit re-mirror, both modes:** with an injected chart + recording stub module (M3
  discipline): a pre-flip in-near-radius edit and a dug-to-air cell arrive in one
  `bulk_inject` after `ramp_done()`, keyed by the correct NEW-window cells; out-of-radius
  edits do not; in cover mode the `bulk_inject` is recorded **before** `release_cover`; M3
  gate (d) still passes unchanged.

### 9.2 Live checklist — baseline (the shipped default)

1. Walk and sprint across a face edge: coarse terrain replaces the old view within
   ~0.2–0.5 s everywhere in frame (no void), full near detail within ~2–5 s; PERF `draws`
   never collapses toward single digits (vs today's 75→18).
2. **Memory — the §0 gate:** browser heap across a ≥ 2 min flip storm is flat, no wasm-heap
   growth trend, no OOM. Outranks every visual gate.
3. Turbo fps dip bounded and brief on the low-end target (else rung 1).
4. Window closes by handshake in ~2–5 s; `timeout` closures are the anomaly signal.
5. Edits: pillar + dug hole near the seam reappear when near detail arrives and persist;
   collision correct throughout (analytic, unchanged).
6. Re-anchor during the window (run 256+ cells post-flip): far cover, fresh tiles, near field
   shift together — no tear.
7. Rung rehearsal: `HANDOFF_ENABLED = false` restores today's visuals byte-for-byte.

### 9.3 The cover A/B procedure + production go/no-go (the ONLY road to flag-on)

**Enable (A/B build):** flip the one line — `NEAR_COVER_ENABLED := true` in
`module_world.gd` — re-export (`scripts/export-web.sh`), redeploy (`scripts/deploy.sh`).
Nothing else changes (§3.1 contract; gate (v5) proves the off-state, (v4) the on-state).

**What to watch, per flip and across a ≥ 2 min flip storm on the low-end target:**

- **Wasm heap trend** (Chrome task manager / `performance.memory`, sampled at each flip):
  flat between flips; the cover transient (~+50 MB) fully returns at each retirement; no
  ratchet.
- **Single-cover invariant via telemetry:** every `near cover retired (…)` line pairs 1:1
  with a flip; a "superseded" retire always precedes a new cover; never two covers implied.
- **Retirement reasons:** ≥ ~95 % `(meshed)` within ~6 s; recurring `(timeout)` means the
  meshed box or cap needs retuning — investigate before any go.
- **Freeze render sanity (§3.3's live-only risk):** frozen meshes stay visible and pinned
  (zero drift against the new field — any creep falsifies §3.2's exactness), no godot_voxel
  errors on freeze/free, no vanished-mesh flashes.
- **Cosmetics:** overlap-ring water density (§6) acceptable; edits show no pop-out at
  retirement (they must already be re-mirrored — (v7) sequencing).

**Go criterion (production `true`):** all of — zero OOM / zero heap ratchet over the storm
test on the low-end target; single-cover invariant unviolated; ≥ 95 % meshed-retirements
within 6 s; no freeze-render anomalies; §9.2 baseline gates still green with the flag on (the
far safety net must remain intact behind the cover). **No-go:** any miss → flag stays/returns
`false`; the baseline is the shipped quality bar, and the far bridge remains the answer.

---

## 10. Deviations

1. **Revision history (the fork the user resolved):** rev 1 locked the frozen-in-place cover
   as the primary; rev 2, under the §0 constraint, banned it and shipped far-only; rev 3
   (this document) is the user's verdict — **ship both**: far-first as the always-on default,
   the cover as a flag-gated, A/B-gated upgrade. The cover's ~+50 MB transient is thereby
   never present in a shipped build without the §9.3 evidence.
2. **From TOPOLOGY §4.5.1 (dual-window prestream):** still rejected — it runs a second *live*
   near volume with worker contention on the 2–3 web threads and trigger churn along seams;
   the frozen cover achieves its pixel-goal without a second live stream, and the baseline
   achieves §0 without any second volume at all.
3. **Numeric correction to TOPOLOGY §4.5.2** (flagged; no interface change): "the far field's
   inner radius drops from 192 toward ~32 during the gap" is a **no-op** as tile *selection* —
   ring-0 tiles (256 m) are never entirely inside the 112-block hole, so the under-player
   tiles are already desired (`far_terrain.gd:260-261`). What that sketch reached for is
   delivered by build **priority** (nearest-first, shipped with bug-B) and **throughput**
   (the §2.2 turbo).
4. **From the M4 task brief's harvest-meshes-only path:** verified infeasible against the
   pinned engine source — `VoxelMeshBlock` is an unregistered `NonCopyable` C++ class holding
   an RS-level `DirectMeshInstance` (`modules/voxel/terrain/voxel_mesh_block.h:24,92` @
   `903d1fb`), no ClassDB binding exposes mesh blocks/meshes (`voxel_terrain.cpp:2300-2380`).
   The freeze-in-place cover is the reachable stand-in; if a future engine bump binds mesh
   access, a capped static mesh snapshot becomes the preferred cover implementation and slots
   into §8 Stage 2 without redesign.
5. **From the far-cover precedent (`far_terrain.rebase_to`):** the near cover does not
   reparent (§3.3) and needs no `_tile_fully_in_face` filtering — far tiles straddling an
   edge were placed by the old *unfold convention* (bug-B), whereas every near mesh was
   generated per **global** cell through the M3 extended-window fold, so the whole disk stays
   world-correct and is kept.
