# COSMOS LEAF-CUTOUT-PERF — restoring playable fps for the near-leaf cutout

Status: DESIGN (perf redesign of task #116). Flag: `FP_LEAF_CUTOUT` (default **false** —
byte-identical off; SEMANTICS CHANGE vs db916fd, see §6.1).
Author: Fable architect session 2026-08-12. Supersedes the approach-selection section (§3)
of `COSMOS-NEAR-LEAF-CUTOUT-DESIGN.md`; everything else in that doc (the leaf-id family,
the stipple alpha source, the side-effect audit) still holds and is reused verbatim.

## 1. The problem — the live A/B FAILED

`FP_LEAF_CUTOUT` as committed (db916fd, **not merged**) implements approach (b) of the
original design: the 7 leaf ids split OFF the one shared atlas material onto a separate
transparent-cutout twin (`block_atlas.gd:55` `leaf_material`, built at `:310`, routed in
`module_world.gd:3189-3191`, honoured by `_add_cube` at `:3241-3248`). The look is right —
the user loves it. The live forest A/B is not:

| state | draw calls (same spot) | fps |
|---|---|---|
| flag off (baseline) | 58 | ~57 |
| db916fd twin | **190** | **~28** |

fps HALVED. That fails the ≤ 10 % in-forest budget by an order of magnitude.

## 2. Root cause of the regression — the DRAW SPLIT, not the discard

**The +132 draws are structural, not incidental.** VoxelMesherBlocky emits one surface
(= one draw call) per distinct material per 32³ mesh block — that is the entire reason
`FP_ATLAS_MATERIAL` exists (`block_atlas.gd:5-11`). The twin *un-merges* every
leaf-containing mesh block back into two surfaces. Measured: **+132 draws** in the forest
view — 2-6× the original design's 20-60 estimate (§4 of the old doc under-counted leafy
blocks in a dense forest, where the canopy layer clips through dozens of 32³ blocks).

**Why +132 draws halves fps on this stack.** Two multipliers the old design under-weighed:

- **Web draw calls are CPU-expensive.** Every draw goes WASM → Emscripten GL → JS → ANGLE
  → driver, with Godot gl_compat per-draw uniform/state setup on top. This project's own
  history says draw count is THE web cost axis ([[voxiverse-web-perf-architecture]]: the
  far-ring re-emit bomb; FP_ATLAS_MATERIAL Stage 1 bought its fps precisely by merging
  per-material surfaces).
- **The gl_compat vsync ladder amplifies any budget miss.** 57 fps ≈ 60-vsync with
  occasional misses; 28 ≈ a 30-lock. The true regression is "the frame crossed 16.7 ms",
  after which the ladder snaps the visible fps to half. Corollary: winning back even a few
  ms restores the full 57, and conversely ANY approach that costs more than ~1-2 ms in the
  forest risks the 30-lock again. The budget is razor-thin; the design below spends ~0.

The discard/fill cost is the *minor* term: the twin's fragments are an unshaded
one-fetch shader over a mesher-culled canopy shell (≈ 2 layers), the same recipe the
far-card layer already ships planet-wide at ~40 fps (`facet_far_trees.gd:141`).

## 3. THE deciding question — does a gated discard kill early-Z for the whole terrain?

The original design rejected putting `alpha_scissor` on the ONE shared material because
"a fragment shader containing `discard` disables early-Z for every draw using that
shader" (old doc §3a). That claim needs to be split in two, because only half of it is
true — and the half that is true is cheap:

**(i) Static, per-program — a branch guard does NOT help.** Early-Z policy is decided at
shader compile time from the *textual presence* of `discard`. `if (is_leaf && a < 0.5)
discard;` marks the whole program "may kill fragments" regardless of which fragments take
the branch. No per-fragment re-enable exists on any GLES3/WebGL2-class hardware. So yes:
merging the discard into the shared shader applies the discard *policy* to the entire
near terrain.

**(ii) What that policy actually costs — early WRITE is lost, early TEST survives.** The
conservative-correctness argument: a discard can only *remove* fragments, never make a
depth-failing fragment pass. Therefore testing an incoming fragment early against
already-committed depth stays exactly correct — only the fragment's own depth *write*
must wait until the shader proves it doesn't discard. This is how all modern GPUs
implement it:

- Desktop IMRs (NVIDIA, AMD, Intel — the project's stated target through ANGLE→D3D11/
  Metal): early depth **test** with **late write** ("re-Z" on AMD) for discard programs.
- ARM Mali (documented in the Mali best-practices guide): `discard` forces **late-ZS
  update**; the **early-ZS test still runs**.
- Qualcomm Adreno: early test runs; the LRZ (coarse) buffer stops being *written* by
  discard draws.

The dense-voxel-scene win — a near chunk drawn earlier occluding a far chunk drawn later,
fragment rejected before shading — is the early depth **TEST** across draws, and it
**survives**. What degrades: (a) the fragment's own depth commits late, so overlapping
fragments *in flight within the same pipelined window* can't be culled against it, and
(b) coarse-Z (Hi-Z/LRZ) buffers may go stale for the frame. Both effects scale with the
fragment shader's cost — and this shader is `render_mode unshaded` with **one texture
fetch + ~6 ALU** (`block_atlas.gd:63-84`, `:92-104`, `:111-130`). Even the absolute
worst case — a hypothetical driver disabling early test entirely — caps at
(overdraw−1) × screen × trivial-shader ≈ 2-4 M extra fragments at 1080p ≈ **0.5-1.5 ms
integrated, well under 0.5 ms discrete**. The realistic case (test kept, write late) is a
fraction of that.

**In-project empirical anchors.** The identical `if (t.a < 0.5) discard;` recipe already
runs live on this exact gl_compat/WebGL2 stack at planet scale: the far tree cards
(`facet_far_trees.gd:141`), the far-tree MESH tail (`:166`), and FP_FAR_TREES_FADE's
per-fragment **dither discard** (`:167`, `:260`) — none produced a measured cliff. The
measured cliff appeared exactly when the *draw count* tripled. The cost model on this
stack is draws, not the early-Z policy.

**Verdict: the old design optimized the wrong variable.** It protected a sub-millisecond
early-Z-write property and paid +132 draws (~17 ms with the vsync snap) for it.

## 4. Approaches weighed

| # | approach | Δ draws | Δ GPU | verdict |
|---|---|---|---|---|
| 1 | **shared material + gated discard** (V2, §5) | **0** | early-write loss on a 1-fetch unshaded shader ≈ ≤ 0.3-1.5 ms worst | **RECOMMENDED** |
| 2 | mesher-baked geometric holes | 0 | vertex + culling blowup | reject |
| 3 | distance-capped twin (dither cross-fade) | +132 unchanged | — | reject — solves the wrong term |
| 4 | cross-chunk batching of leaf surfaces | ~+1 total | — | reject — engine patch, disproportionate |

**(2) Mesher-level holes** (perforated leaf cube models, opaque, no discard): a
VoxelBlockyModel side is culled against a neighbour only when the neighbour's side
*pattern occludes it*; a perforated side is not a full square, so leaf-vs-leaf interior
faces stop culling — the canopy renders ALL interior faces instead of its ~2-layer shell,
and the perforated face itself needs ≥ 16 quads/face to read as stipple. Thousands of
leaf cells × 6 faces × 16 quads + un-culled interiors = a vertex/overdraw explosion that
destroys the load-bearing overdraw cap. Texel-scale stipple (2 px on a 64 px cell) is
geometrically infeasible outright. Reject.

**(3) Distance cap** (cutout only for the nearest N leafy chunks, dither cross-fade to
solid): materials are bound **per-model-id** in the one shared `VoxelBlockyLibrary`
(`module_world.gd:3244-3248`); `VoxelTerrain` exposes no per-chunk material override to
GDScript, so a distance-*switched material* is unimplementable without C++. The
implementable variant — a distance-gated discard *inside the twin's shader* — keeps all
+132 draws, because **the material split, not the discard, is the cost** (§2). The
cross-fade idea is sound (the far-trees fade proves dither discard is fine) but it has
nothing to fix here once the split is gone. Reject.

**(4) Batch the leaf surfaces across chunks**: `VoxelTerrain` owns its per-mesh-block
`MeshInstance`s in C++; merging surfaces across blocks (or extracting them into one
MultiMesh) means patching the mesher/renderer and re-extracting on every block update.
The project does carry engine patches (L5a cppgen), but a mesher/render-path patch to
save what a one-line shader splice saves for free is disproportionate. Reject.

## 5. RECOMMENDED — V2: leaves stay on the ONE shared material; the shared shader gains one gated discard

Everything from the original design is kept EXCEPT the material split:

- The stipple hole-punch into the leaf atlas cells' existing alpha plane — unchanged
  (`block_atlas.gd:298-303`, `_punch_leaf_holes` `:445`, `_stipple_hash01` `:456`).
- The leaf key-namespace so a punched cell is never shared with a non-leaf id — unchanged
  (`block_atlas.gd:238-247`), and `BlockCatalog.is_leaf_id` (`block_catalog.gd:586-594`).
- The shader change collapses to: splice `\tif (t.a < LEAF_SCISSOR) discard;\n` after the
  existing `\tvec4 t = texture(atlas_tex, UV);\n` fetch (`_LEAF_FETCH_LINE`,
  `block_atlas.gd:148`) **into whichever near-daylight variant is live** — the same
  string-splice db916fd already ships (`leaf_shader_code`, `:153-157`), now applied to
  the ONE shared program instead of a twin.

Why the semantics stay correct with ONE material:

- **Non-leaf texels can never discard**: every non-leaf cell is min-alpha 255 by
  construction (gate-enforced, `verify_leaf_cutout.gd:154`), and the namespace guard
  makes leaf-cell sharing impossible. The branch is data-gated by the atlas itself — no
  per-cell uniform or vertex flag needed; `t.a` is **already fetched** by the shipped
  shader (`:78`, `:100`, `:127`), so the added per-fragment cost is one compare.
- **Zero look delta vs the loved twin**: the shared shader is ALREADY `render_mode
  unshaded, cull_disabled` (`block_atlas.gd:64`) — the same double-sidedness the twin had
  (`_make_leaf_material` sets `CULL_DISABLED`, `:426`), so a hole still shows the inner
  back shell of the canopy; discard still runs before the shade multiply, so kept texels
  take the identical `voxi_shade`/shipped shade-law path; the sun_dir/planet_centre
  uniform feeds now reach leaves for free (one material — the twin-feed extensions at
  `:477-479`/`:492-494` become dead and are removed).
- **Overdraw cap intact**: leaf models keep `transparency_index 0`; leaf-leaf interior
  faces stay mesher-culled (unchanged from db916fd).

### Perf estimate (against §1's measured numbers)

| | draws (forest spot) | programs | per-fragment | early-Z | expected forest fps |
|---|---|---|---|---|---|
| baseline | 58 | n | 1 fetch + ~6 ALU | full | ~57 |
| db916fd twin | 190 | n+1 | same + discard (leaf only) | terrain full, leaf late-write | **28 measured** |
| **V2 shared** | **58** | **n** | same + 1 compare | terrain early-TEST kept, late write | **~53-57** (≥ 50 target) |

The +132 draws and the extra program vanish — the entire measured regression term goes to
zero. The only new cost is the early-write policy on a one-fetch unshaded shader:
≤ ~0.3-1.5 ms absolute worst (§3), i.e. within the ≤ 10 % frame-time budget even if the
target GPU is the pathological case. There is no cheaper way to keep the look: V2 adds
zero draws, zero programs, zero vertices, zero resident bytes, and one ALU op.

## 6. Implementation plan (exact delta from db916fd)

### 6.1 Flag

Reuse **`FP_LEAF_CUTOUT`** (`cube_sphere.gd:2968`) — db916fd is unmerged, so redefining
its mechanism is clean; the flag's *meaning* to the user ("near leaves are see-through")
is unchanged. Rewrite the doc comment (`:2954-2967`) to the V2 mechanism and drop the
"approach (b)" rationale. `LEAF_HOLE_P` (`:2972`) and `LEAF_SCISSOR` (`:2976`) keep their
values and comments. No `FP_LEAF_CUTOUT_V2`: the twin variant is already measured (28 fps
— we don't need to export it again), and a mode const would double every gate's state
matrix for a path we intend to delete. The twin stays resurrectable from git (db916fd).

### 6.2 `block_atlas.gd`

REMOVE (the twin apparatus):
- `var leaf_material` (`:50-55`); the `leaf_material = _make_leaf_material(texture)`
  build step (`:308-310`); `_make_leaf_material` (`:403-433`); `leaf_shader_code`
  (`:149-157`); the twin uniform-feed extensions in `set_near_daylight_sun_dir`
  (`:477-479`) and `set_near_daylight_planet_centre` (`:492-494`).

KEEP unchanged: `_LEAF_FETCH_LINE` (`:148`), the leaf key namespace (`:238-247`,
`:260-261`), the punch loop (`:298-303`), `_punch_leaf_holes` (`:445`),
`_stipple_hash01` (`:456`).

ADD:
- `near_daylight_shader_code(unified, centre_fix, cutout := CubeSphere.FP_LEAF_CUTOUT)`
  — third default-flag parameter; when `cutout`, return
  `base.replace(_LEAF_FETCH_LINE, _LEAF_FETCH_LINE + discard_line)` (the db916fd splice,
  `:156-157`, relocated); when off, the shipped strings VERBATIM — byte-identity by
  construction. Exposed static as today, so gates build every variant without toggling
  consts.
- `_make_material` StandardMaterial path (`:393-401`): under the flag,
  `transparency = TRANSPARENCY_ALPHA_SCISSOR; alpha_scissor_threshold =
  CubeSphere.LEAF_SCISSOR` — the headless/FLAT-parity path (live always ships the
  ShaderMaterial twin), same two properties the twin used (`:431-432`).

### 6.3 `module_world.gd` — pure REVERT to shipped

Remove the `leaf_mat` routing block (`:3186-3191`) and the fifth argument at
`:3198`/`:3200`; restore `_add_cube`'s shipped signature and the unconditional
`_atlas.material` force (`:3221-3248` back to the pre-db916fd ternary). Leaf cubes ride
the shared material + `set_tile` exactly like stone — the mesher merges them into the
same per-chunk surface as baseline.

### 6.4 `block_catalog.gd`

`is_leaf_id` (`:586-594`) — keep verbatim (drives the punch, the namespace, and gates).

### 6.5 Byte-identical OFF (same discipline as db916fd, gate-checked)

Flag off ⇒ no namespaced keys, no punch (atlas image byte-identical), 
`near_daylight_shader_code()` returns the shipped strings verbatim, `_make_material`
untouched, `module_world` routing textually restored to shipped. Nothing is built,
routed, or compiled differently.

### 6.6 Gates (`verify_leaf_cutout.gd` rework + `verify_atlas.gd` simplification)

- **G-LEAF-OFF** — as today (`:103-120`) minus the twin assertion: leaf cells min-alpha
  255; every leaf model on the ONE shared material; `near_daylight_shader_code()`
  byte-equal to the shipped source; shared StandardMaterial has `TRANSPARENCY_DISABLED`.
- **G-LEAF-CELL** — unchanged (`:123-157`): punch fraction ∈ [0.22, 0.40] per leaf cell
  at mip 0, non-leaf cells min-alpha 255, no leaf/non-leaf cell sharing.
- **G-LEAF-SHARED** (replaces G-LEAF-MAT `:160-197`): ALL opaque cube ids — leaf AND
  non-leaf — are on the ONE shared atlas material instance (stronger than baseline's
  gate: the flag no longer creates a second material at all); the shared shader source ==
  `near_daylight_shader_code(cutout = true)` == shipped variant + EXACTLY one discard
  line (string-diff); on the StandardMaterial path, `ALPHA_SCISSOR` at `LEAF_SCISSOR`;
  leaf models' `transparency_index` still 0.
- **G-LEAF-SHADE** — simplifies: the sun_dir/planet_centre feed sites are the shipped
  ones (`:470-475`, `:485-491`, now twin-free); assert the shared material still receives
  them (uniform read-back after a fed frame).
- **`verify_atlas.gd`** — the db916fd flag-aware split of G-ATLAS-MAT REVERTS: "every
  opaque cube on the ONE material" now holds in BOTH flag states.
- Full suite as db916fd ran it: FLAT `verify_feature`, `verify_faceted`,
  `verify_far_trees`, both flag states of `verify_leaf_cutout` + `verify_atlas`.

## 7. Live perf A/B plan (the ship gate)

Same forest spot as the failed A/B, remote-controlled, via the view-state telemetry:

1. **Draw-call discriminator (binary, frame 1):** V2 draw calls == baseline (58 vs 58).
   Any delta means a leaf surface failed to merge — abort before looking at fps.
2. **Forest fps:** flag-off vs V2 at the spot, p90 frame time. PASS: **fps ≥ 50**
   (≤ 10 % frame-time cost vs ~57 baseline). This is the direct empirical answer to the
   early-Z question on the user's actual GPU.
3. **Open-terrain control:** ~0 regression away from trees (the discard policy is
   terrain-wide, so this is the honest whole-scene check, not a formality).
4. **Look check:** user eyeball vs the loved db916fd screenshots (expected identical —
   same cull, same shade, same stipple, §5).

Knobs and their honest limits: `LEAF_HOLE_P`/`LEAF_SCISSOR` tune the LOOK only — they
cannot buy back early-Z (the policy is static, §3(i)). **If V2 fails step 2 or 3, there
is no cheaper variant to retreat to** — every other direction (§4) costs more. The
fallback is the project non-negotiable: ship `FP_LEAF_CUTOUT := false` by default
(playability outranks feature depth), keeping the feature bakeable-ON for high-end
exports. Do NOT resurrect the twin as a fallback — it is measured-failed (28 fps).

## 8. Risks

| Risk | Likelihood | Containment |
|---|---|---|
| Target GPU disables early depth TEST (not just write) on discard programs | low (desktop-through-ANGLE keeps the test; §3) | worst case ≤ ~1.5 ms on this 1-fetch unshaded shader; caught by A/B step 3; fallback flag-off |
| Mip alpha bleed across cell borders at tiny mips dips a non-leaf texel < 0.5 | very low (neighbour averaging of 1.0-and-≈0.7 stays ≥ 0.85; near field never reaches sub-8px mips) | G-LEAF-CELL mip-0 check; LEAF_SCISSOR 0.5 → 0.4 knob |
| Look delta vs the approved twin | ~nil (same cull_disabled, shade path, stipple; §5) | A/B step 4 eyeball |
| Gate drift (verify_atlas revert) | certain | shipped in the same commit, both flag states run |
