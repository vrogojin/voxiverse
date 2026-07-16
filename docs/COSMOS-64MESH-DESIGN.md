# COSMOS — 64³ mesh blocks (Lever L4) — feasibility + patch design

**Status:** design only (no rebuild, no implementation). Branch `perf/voxiverse-64-mesh-block`.
**Verdict: FEASIBLE — trivial soft-cap raise. GO (flag-gated, measure the upload transient).**
The `mesh_block_size` cap of 32 is a **soft resource-usage constant + a hardcoded `switch`**,
**not** a 16-bit vertex-index limit. The blocky mesher already emits 32-bit indices.

---

## 1. Where the module source lives / how it is built

- godot_voxel is fetched at build time by `docker/engine/build-engine.sh`:
  `clone_pinned "https://github.com/Zylann/godot_voxel.git" "${SRC}/modules/voxel" v1.4.1`
  (ref pinned in `docker/engine/versions.env`, `VOXEL_REF=v1.4.1`).
- The warm cache checkout is at `docker/engine/cache/godot/modules/voxel/` (all evidence
  below cites that tree). `clone_pinned` does `git checkout -f <ref>` + `git clean -fdq`, so the
  tree is pristine each run, then patches are applied.
- Patches live in `docker/engine/patches/godot_voxel/*.patch`, applied in filename order by
  `build-engine.sh` (lines 76–91) via `git -C "${VOXEL_DIR}" apply --whitespace=nowarn`.
  **A failed apply is FATAL** (refuses to build a silently-unpatched engine). Existing series:
  `0001-native-waterlogging` … `0005-web-hardware-concurrency-clamp`. This patch = **`0006`**.
- VOXIVERSE uses **`VoxelTerrain`** (fixed-LOD), instantiated in `module_world.gd:343`. It does
  **not** use `VoxelLodTerrain` — that distinction matters (see §3).

## 2. The load-bearing question: WHY is 32 the cap? — answered with code

**It is a soft cap, enforced in exactly two places, with no overflow reason behind it.**

### 2a. The constant (the clamp ceiling)
`constants/voxel_constants.h:9-14`:
```cpp
// These constants are chosen so you don't accidentally blow up resource usage
static const unsigned int MIN_BLOCK_SIZE = 16;
static const unsigned int MAX_BLOCK_SIZE = 32;   // <-- the ceiling
```
The comment states the intent outright: it is a **resource-usage guardrail**, not a correctness
bound.

### 2b. The real gate — a hardcoded `switch` (`terrain/fixed_lod/voxel_terrain.cpp:209-224`)
```cpp
void VoxelTerrain::set_mesh_block_size(unsigned int mesh_block_size) {
    mesh_block_size = math::clamp(mesh_block_size, get_data_block_size(), constants::MAX_BLOCK_SIZE);
    unsigned int po2;
    switch (mesh_block_size) {
        case 16: po2 = 4; break;
        case 32: po2 = 5; break;
        default:                 // <-- ANY other value silently falls back to 16
            mesh_block_size = 16;
            po2 = 4;
            break;
    }
    ...
```
**Consequence:** raising `MAX_BLOCK_SIZE` alone is not enough — with the constant at 64 but the
switch untouched, `set_mesh_block_size(64)` passes the clamp then hits `default` → silently
becomes **16** (a catastrophic regression, not an error). **Both** sites must change.

### 2c. The 16-bit-index hypothesis is REFUTED by code
The blocky mesher uses **`int` (int32) indices and index-offsets end to end** — there is no
`uint16` anywhere in the index path:
- `meshers/blocky/voxel_mesher_blocky.cpp:33` `StdVector<int> &get_tls_index_offsets()`
- index accumulation is all `int` (`cindex_offset`, `index_offset`, `w[i++] = index_offset + …`),
  lines 205, 264-280, 447-572.
- final GPU array is **`PackedInt32Array indices`** (`voxel_mesher_blocky.cpp:858, 1114`) filled by
  `copy_to(indices, to_span_const(arrays.indices))` (line 1120).

Godot's `RenderingServer` then auto-selects the index format per surface: `uint16` when a surface
has < 65536 vertices, `uint32` otherwise. **gl_compatibility targets GLES3 / WebGL2, where 32-bit
element indices (`UNSIGNED_INT` / `OES_element_index_uint`) are core** — so an over-65535-vertex
surface renders correctly, it just uses the 32-bit index path.

**Decisive proof the cap is not an index limit:** a pathological (checkerboard) **32³** block already
produces ~16384 solid × 24 = ~393k vertices per surface — *already* far over the 65536 uint16
ceiling — and the module ships with 32 as its working maximum. If 32 were the "16-bit-safe" bound
it would itself be unsafe. It is not; the int32 path absorbs it. The 32 cap is therefore purely the
`voxel_constants.h:9` resource guardrail.

### 2d. No other block-size assumptions block 64
- **No fixed-size 32/34 stack buffers, no `& 31` / `% 32` / `<< 5` masking** in the blocky mesher
  or `mesh_block_task.cpp` hot path (grepped — none).
- **VoxelBuffer per-dimension limit is 65535** (`storage/voxel_buffer.h:95 MAX_SIZE = 65535`;
  asserted in `voxel_buffer.cpp:191`). The mesh-block work buffer is
  `padded_mesh_block_size = mesh_block_size + min_padding + max_padding` (`mesh_block_task.cpp:89`)
  → **66³** for a 64³ block — three orders of magnitude under the limit. Fine.
- **Data blocks are hard-decoupled and stay 16³.** `VoxelTerrain` has **no public
  `set_data_block_size`** (commented out, `voxel_terrain.h:58`) → data block po2 is fixed at
  `DEFAULT_BLOCK_SIZE_PO2 = 4` (16). The mesh/data relationship is
  `render_to_data_factor = mesh_block_size / data_block_size` (`voxel_terrain.cpp:423`, `:1280`);
  for 64/16 = **4** (integer), used only to size view boxes and iterate the 4³ = 64 data blocks a
  mesh block spans. Edit injection (bulk_inject groups by 16³ data block) is untouched.

## 3. Feasibility verdict: TRIVIAL SOFT-CAP RAISE

Two-line C++ change, LOW structural risk. `VoxelLodTerrain` also clamps to `MAX_BLOCK_SIZE` and
carries its own `is_valid_block_size` check (`voxel_lod_terrain.cpp:1164`, `:462`) that would reject
64 — **but VOXIVERSE never instantiates `VoxelLodTerrain`, so it needs no change.** Patching only
`fixed_lod` keeps the diff minimal and the blast radius contained to the class we use.

## 4. The patch — `docker/engine/patches/godot_voxel/0006-mesh-block-size-64.patch`

Drop-in unified diff (matches the existing series' `git apply` convention, paths relative to the
module root):

```diff
diff --git a/constants/voxel_constants.h b/constants/voxel_constants.h
--- a/constants/voxel_constants.h
+++ b/constants/voxel_constants.h
@@ -11,7 +11,10 @@ static const float MAXIMUM_LOD_DISTANCE = 128.f;
 
 static const unsigned int MIN_BLOCK_SIZE = 16;
-static const unsigned int MAX_BLOCK_SIZE = 32;
+// VOXIVERSE COSMOS L4: raise the mesh-block ceiling to 64 so VoxelTerrain (fixed-LOD) can use
+// 64³ mesh blocks (8× the ground per block → ~2× fewer draw calls on gl_compatibility). This is
+// a resource-usage guardrail, NOT a correctness bound — the blocky mesher emits int32 indices
+// (PackedInt32Array) and WebGL2 supports 32-bit element indices, so >65535-vertex surfaces are
+// fine. See docs/COSMOS-64MESH-DESIGN.md. Data blocks stay 16³ (no set_data_block_size on
+// VoxelTerrain), so edit injection is unaffected.
+static const unsigned int MAX_BLOCK_SIZE = 64;
 
 static const unsigned int MAX_BLOCK_COUNT_PER_REQUEST = 4 * 4 * 4;

diff --git a/terrain/fixed_lod/voxel_terrain.cpp b/terrain/fixed_lod/voxel_terrain.cpp
--- a/terrain/fixed_lod/voxel_terrain.cpp
+++ b/terrain/fixed_lod/voxel_terrain.cpp
@@ -214,6 +214,10 @@ void VoxelTerrain::set_mesh_block_size(unsigned int mesh_block_size) {
 		case 32:
 			po2 = 5;
 			break;
+		case 64:
+			// VOXIVERSE COSMOS L4 — 64³ mesh blocks. render_to_data_factor = 64/16 = 4.
+			po2 = 6;
+			break;
 		default:
 			mesh_block_size = 16;
 			po2 = 4;
 			break;
```

*(Exact hunk offsets/`index` lines are regenerated by `git diff` at authoring time; the two edits —
constant 32→64 and the new `case 64: po2 = 6;` — are the whole patch.)*

### GDScript wiring — flag `FP_MESH_BLOCK_64`, default OFF (byte-identical)

`module_world.gd` sets `mesh_block_size` at **four** sites: `:363` (active terrain), `:1586`
(frozen cover terrain), `:2101` (neighbour terrain), `:2202` (restream terrain). Gate all four on
one flag so behaviour is uniform:

```gdscript
# CubeSphere (or module_world const):
const FP_MESH_BLOCK_64 := false   # default OFF → mesh_block_size stays 32, FLAT byte-identical

# at each of the four sites, replace `32` with:
_set_if(_terrain, "mesh_block_size", 64 if CubeSphere.FP_MESH_BLOCK_64 else 32)
```
With the flag OFF the game requests 32 exactly as today → **FLAT 6035/0 and faceted gates are
byte-identical**, and the patched engine is behaviourally unchanged (64 is simply an option nothing
selects). Flip to `true` (after the rebuild) to A/B the 64³ path.

## 5. Rebuild scope & cost

**Yes — a full `scripts/build.sh` is required** (~24 min cold, minutes warm). The patch touches
compiled C++ in both the native editor and the Web export templates, so both the headless editor
(`docker/engine/bin/godot.linuxbsd.editor.x86_64`) and the web templates must be recompiled with
the module. `SKIP_LINUX=1` cannot be used (the verify/gate scripts need the native editor); the web
template rebuild is the deploy artifact. Version pins and emsdk are unchanged — no `versions.env`
edit.

## 6. Expected win

- **Draw calls: ~74–87 (post-atlas) → ~40.** A 64³ block covers 4× the *horizontal* footprint of a
  32³ block (surface terrain is near-2D), so near-field surface mesh blocks — the dominant, ~40–50
  of the current 74–87 — drop ~4×, to ~11; the far-ring LOD facets, sky, water and HUD draws are
  unchanged. Net ≈ 40 draws, matching Fable's L4 estimate. Stacks with L3.
- **fps rung:** ~40 draws is the "robust 60 fps on Intel-class gl_compatibility" rung; the
  structural end-state short of the L7 (4.6/WebGPU) migration.

## 7. Risks & NEVER-OOM

- **Total mesh memory ≈ neutral.** The same terrain exposes the same faces → roughly the same total
  vertex data; 64³ just groups it into ~4–8× fewer, larger surfaces. Not a new OOM surface.
- **Remesh-per-edit cost ×8 (accepted).** An edit remeshes its whole mesh block; a 64³ block is 8×
  the volume of a 32³. But this runs on the voxel worker, edits are rare, and the main-thread apply
  is capped (`voxel/threads/main/time_budget_ms=4`). Not a frame stall.
- **Upload transient — the one to MEASURE (not a proven dealbreaker).** Each mesh apply is an
  *indivisible* `RenderingServer` surface upload. A 64³ block's surface is ~4–8× bigger (~2–3 MB,
  up to ~50–65k verts) than a 32³ block's. Total upload bytes across a crossing are unchanged, but
  the pacer's granularity is coarser: with 32³ the apply queue is chunked into 8× more, 8× smaller
  applies that `time_budget_ms=4` spreads across frames; with 64³, a single apply can overrun the
  4 ms budget in one atomic chunk. **This is the direct tension with the crossing smoothness just
  won** (fixed-frame keystone + far-ring re-emit fix). Expected magnitude is a *single-frame*
  ~4–8 ms budget overrun per big apply — an order of magnitude smaller than the 157–381 ms
  far-ring spikes being separately removed — so likely acceptable, **but it must be validated on
  the live real-GPU loop**: A/B the crossing/streaming worst-frame with `FP_MESH_BLOCK_64` on vs
  off. If a crossing worst-frame regresses materially, the mitigation is to keep 64³ only for the
  *steady-state* active facet and stream neighbours at 32³ (revert sites `:2101`/`:2202` to 32),
  or hold at 32 and take the win from L3 alone.

## 8. GO / NO-GO

**GO — flag-gated, default OFF.** The feasibility gate (the 16-bit-index question) is cleanly
passed: the cap is a soft constant + a hardcoded switch, the mesher is already int32, WebGL2 has
32-bit indices, and no coordinate/buffer math assumes ≤32. The patch is two C++ lines + a
one-flag GDScript wiring. Cost is one ~24-min `scripts/build.sh`. The only open question is the
upload-transient's effect on crossing smoothness, which is *measurable* on the deploy-measure loop
and *mitigable* (active-facet-only 64³) if it regresses — it is not a structural blocker. Recommend:
build, deploy, A/B worst-frame on vs off, keep OFF if the crossing regresses.
