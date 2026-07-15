# GODOT-MIGRATION-ASSESSMENT — should VOXIVERSE move off Godot 4.4.1, to what, and when?

Status: **architecture decision assessment** (Fable, 2026-07-14). Scope: the migration
*decision* — the reasoning, the renderer crux, cost/risk, and sequencing. Exhaustive
fact tables (per-version breaking changes, patch-by-patch diffs, Compatibility feature
matrices) live in the parallel research docs this synthesizes alongside; where those
disagree with a load-bearing claim here, re-verify the primary source before acting.

All version facts below were verified against primary sources on 2026-07-14
(godotengine.org release pages, godotengine/godot tags and CI workflows,
Zylann/godot_voxel releases and changelog, godot-proposals).

---

## 0. Executive summary and recommendation

**Go — but not now, not for visuals, and not to the version you'd guess.**

1. **Migrate: yes.** Target **Godot 4.6.x + godot_voxel 1.6** (the newest
   *paired* stable–stable combination), with a check at migration start whether
   Zylann has cut a 4.7-paired voxel release (4.7-stable shipped 2026-06-18; if a
   paired 1.7 exists by then, hop straight to 4.7). Do **not** pair Godot 4.7 with
   godot_voxel master — an unreleased module against a month-old engine is two
   moving parts where we currently have zero.
2. **When: after FP-M2 ships and stabilizes.** FP-M2e (heap A/B + soak +
   default-ON deploy) and its steelman are in flight. Migrating under it would
   invalidate every measured baseline the deploy gate depends on (browser heap,
   worst-frame, thread tuning) while changing the compiler (emsdk 3.1.64 → 4.0.x),
   the engine, and the module at once. Migrate in the first quiet window after the
   FP-M2 flag-ON deploy has soaked in production. Estimated effort: **~1–2 focused
   weeks**, dominated by re-validation and one hard patch rebase (§4).
3. **Visuals verdict — the user's prior is half right and the half matters.**
   "Great visuals (HDR/reflections/GI) later" is **not** gated by the Godot
   version on our primary target. It is gated by the **renderer**, and on web
   the renderer is gated by **WebGPU**, which as of July 2026 is an open
   *proposal* in Godot with no committed timeline — web export is
   Compatibility/WebGL2-only on every official version through 4.7 (§3). No
   migration we can do today buys Forward+ visuals in the browser.
   **The route to great visuals today is a dual-target build**: Forward+ on a
   native desktop export (works on any modern 4.x, one project, per-platform
   rendering method), Compatibility on web for reach. Migration to 4.6/4.7
   modestly improves that *native* tier (4.6 rewrote SSR; 4.7 added HDR output
   and AreaLight3D) — that is a real but secondary migration benefit.
4. **What migration actually buys us now:** retiring 1–2 of our 6 engine patches
   (the web pthread-pool patch is obsoleted by an upstream runtime knob in 4.6+;
   the hardware-concurrency clamp can likely move from engine patch to shell JS),
   a maintained engine (4.4.x stopped receiving fixes), a modern emsdk (4.0.x),
   and — strategically — **staying within one minor of current**, which keeps the
   *eventual* WebGPU migration (the visuals unlock) a short hop instead of a
   multi-version leap.
5. **What migration does NOT buy:** nothing in godot_voxel 1.5/1.6 replaces any
   of the faceted-planet work — no blocky-terrain LOD, no rotated multi-terrain
   assembly, no junction carving, no native waterlogging. Our architecture is
   orthogonal to the engine version (§2). FP-M2 would be hand-rolled on 4.7
   exactly as it was on 4.4.1.

**Trigger policy** (§5): migrate to 4.6/4.7 at the post-FP-M2 quiet window;
re-assess *renderer* strategy the day official WebGPU-on-web lands in a dev
snapshot (watch godot-proposals #4806 and 4.8 dev notes) — that event, not any
4.x minor, is what changes the visuals answer.

---

## 1. Ground truth (verified 2026-07-14)

### 1.1 Our stack

- Godot **4.4.1-stable** custom module build + **godot_voxel v1.4.1**
  (`docker/engine/versions.env`), emsdk **3.1.64** (pinned to 4.4.1's CI),
  threaded WASM, WebGL2/Compatibility renderer, COOP/COEP + SharedArrayBuffer.
- **Six** maintained patches (`docker/engine/patches/`):

  | # | Patch | Size | What it touches |
  |---|---|---|---|
  | G-0001 | web pthread-pool-size SCons option | 2 KB | `platform/web/detect.py` |
  | V-0001 | native waterlogging | 21 KB | blocky baked library + mesher internals |
  | V-0002 | `VoxelBlockyLibrary::bake()` early-out | 1 KB | `voxel_blocky_library.cpp` |
  | V-0003 | cosmos true-place near bake | 16 KB | new `cosmos_bake.h` + mesher hooks |
  | V-0004 | faceted junction carve | 25 KB | new `facet_carve.h` + mesher hooks |
  | V-0005 | web hardware-concurrency clamp | 2 KB | web platform JS |

- In flight: FP-M2 (FacetLodMesher: off-pool LOD builds, SSE selector,
  load-adaptive budgeter, Z1-hybrid pool policy) at stage M2e — heap A/B, soak,
  default-ON deploy — plus a steelman review. Gates: FLAT byte-identity 6027/0,
  the faceted/FP gate suite, live web telemetry baselines.

### 1.2 The version landscape

| Godot | Stable date | Paired godot_voxel | Web emsdk pin | Notes relevant to us |
|---|---|---|---|---|
| 4.4.1 (ours) | Apr 2025 | v1.4.1 | 3.1.64 | end of maintenance |
| 4.5 | Sep 2025 | v1.5 (2025-09-16) | (4.x era begins) | voxel: blocky tint mode, manual thread-count control |
| 4.6 | 2026-01-26 | v1.6 (2026-02-04) | **4.0.11** | Jolt default (new projects), SSR rewrite, LibGodot; **runtime `Module['emscriptenPoolSize']` pthread-pool knob** |
| 4.7 | 2026-06-18 | none yet (master) | 4.0.x | HDR *output*, AreaLight3D, shader workflow; 4.7.1 RC out |
| 4.8 | dev | — | — | cycle just opened |

- Zylann pairs a voxel release with each Godot minor within ~1–2 weeks of
  stable (1.5↔4.5 same week; 1.6↔4.6 nine days after). A 4.7-paired release is
  plausible soon but **did not exist** at assessment time.
- **Web export is Compatibility/WebGL2-only on every official version through
  4.7** (Godot docs, 4.7 branch). WebGPU remains an open proposal
  (godot-proposals #4806 / #6646); `RenderingDevice` abstracts
  Vulkan/D3D12/Metal "with WebGPU planned", no committed schedule. A
  *community fork* ("Godot WebGPU", beta 2026-05-10, based on 4.6.2) exists —
  interesting signal, not a production path for a custom-module threaded build
  (unknown module/pthread story, single-maintainer risk).
- Browser-side WebGPU is now universal (Safari 26, Sept 2025, closed the last
  gap) — the *platform* is ready; the *engine* is the missing piece.

---

## 2. Would migrating simplify our feature development? — **No.**

This is the question that would most justify an urgent migration, so it got the
adversarial treatment: I read the godot_voxel 1.5 and 1.6 changelogs looking for
anything that obsoletes work we did or are doing by hand.

**What we hand-rolled, and whether any newer engine/module provides it:**

| Hand-rolled subsystem | Native in 4.5–4.7 / voxel 1.5–1.6? |
|---|---|
| FP-M2 FacetLodMesher (blocky LOD meshes at SSE-selected tiers, off-pool builds) | **No.** `VoxelLodTerrain` remains smooth/Transvoxel-only; blocky `VoxelTerrain` has no LOD in any release. 1.6's LOD entries are debug flags and instance-multimesh distance fixes. |
| Planet Assembly (pooled *rotated* VoxelTerrains, re-designation crossing) | **No.** Nothing upstream addresses multiple coordinated terrain instances or terrain-under-rotation lattices. |
| Facet junction carve (V-0004), cosmos near bake (V-0003) | **No** — these encode *our* planet topology; they will never be upstream. |
| Waterlogging (V-0001) | **No.** Upstream fluids (`VoxelBlockyModelFluid`) still model fluid-only voxels; no solid+fluid co-occupancy. Upstream fluid code *is evolving* (collision fixes on master) — which makes this patch a growing rebase liability, an argument for migrating *sooner* rather than later, but not a simplification. |
| Analytic physics, sim layer, edit overlay | Engine-version-orthogonal by design. |
| bake() early-out (V-0002) | **Not upstream** (verified master `voxel_blocky_library.cpp`: no `_needs_baking` guard at top of `bake()`). Still needed. **Recommend upstreaming as a PR** — it's small, safe, and generally useful; if accepted it retires itself. |
| Web pthread pool (G-0001) | **Yes — obsoleted at 4.6.** Upstream now links `-sPTHREAD_POOL_SIZE="Module['emscriptenPoolSize']||8"` (verified 4.6-stable and 4.7-stable `detect.py`): a *runtime* knob set from shell JS. Strictly better than our build-time option — pool size can follow the visitor's actual core count. |
| HW-concurrency clamp (V-0005) | Not upstream, but on 4.6+ the same policy can likely live in **our shell JS** (compute `Module.emscriptenPoolSize` from `navigator.hardwareConcurrency`) instead of an engine patch. Engine-patch count potentially drops from 6 to 4. |

**Conclusion:** our architecture is genuinely orthogonal to the engine version.
The decoupled sim layer, the analytic physics, and the facet machinery neither
gain nor lose from 4.5/4.6/4.7. Migration is *maintenance positioning*, not
feature leverage. Nobody should sell this migration internally as "it makes
FP-M3 easier" — it doesn't, beyond the two patches it retires.

One genuine forward-looking exception: godot_voxel 1.5 added build options to
*disable module features* in custom builds — potentially smaller WASM, which is
real currency under NEVER-OOM. Worth measuring during migration, not a driver.

---

## 3. The crux: the visuals goal vs the web renderer

The user's prior — "most probably worth it, we want great visuals
(HDR/shaders/reflections/GI) later" — deserves a straight answer, because as
stated it aims the migration at a target migration cannot hit.

### 3.1 The gate is the renderer, and on web the renderer is frozen

Godot's high-end visuals (Forward+: SDFGI/VoxelGI, SSR, SSAO/SSIL, volumetric
fog, full HDR pipeline) require the `RenderingDevice` renderers. On web, every
official Godot through 4.7 runs **only** the Compatibility renderer on WebGL2.
This is not a version knob, an export flag, or a build option we can patch
around — it is a missing rendering backend (WebGPU), tracked as an open
proposal with no assignee and no roadmap commitment. Upgrading 4.4.1 → 4.7
changes our browser pixels approximately not at all.

So: **on our primary, non-negotiable target (the live web demo), the visuals
dream is WebGPU-gated, and WebGPU-on-web has no official ETA.** Anyone
budgeting the migration as "step one toward HDR in the browser" is buying a
ticket for a train that hasn't been scheduled.

### 3.2 The honest web visual ceiling (any 4.x, today)

Compatibility/WebGL2 still leaves real headroom above where we are — none of it
requires migrating, though later versions polish some of it:

- **Custom shaders everywhere** — full `gdshader` support. Stylized water,
  atmosphere/sky scattering, animated foliage, distance fog tuned per-biome:
  all available now, and honestly where a voxel aesthetic gets the most
  visual return per millisecond anyway.
- **Baked and probe-based lighting** — lightmaps and reflection probes at
  Compatibility tier (exact feature coverage per version is in the peer
  visuals doc). For voxel worlds with runtime-modifiable geometry, baked GI is
  awkward anyway — our per-voxel light/temperature sim layer is arguably the
  more coherent path to "lighting that feels alive" than engine GI.
- **Post stack** — glow/bloom-class effects and tonemapping exist at
  Compatibility tier; screen-space effects that need the depth-prepass
  (SSR/SSAO) do not.

That ceiling is respectable — Minecraft-with-good-shaders territory, not
Cyberpunk. If that ceiling is unacceptable for the web build, the answer is
still not "migrate Godot"; it is §3.3 or waiting on §3.4.

### 3.3 The strategic option that actually delivers the visuals: dual-target

One Godot project can export per-platform with different rendering methods:
**Forward+ desktop build** (max visuals: SSR, GI, HDR output on 4.7) + **Compatibility
web build** (reach, the current gate). Our architecture is unusually
well-positioned for this:

- Physics is analytic and render-path-agnostic; the sim layer never reads
  geometry; gameplay is already proven identical across two render paths
  (module vs GDScript fallback). A third *visual* tier reuses that discipline.
- We already build the Linux editor binary in the same Docker pipeline — a
  desktop export template is incremental toolchain work, not a new pipeline.

Costs are real but bounded: materials/environment authored once with a
quality-tier switch, double visual QA, and desktop distribution. **This is the
only route to the user's stated visuals that exists today**, and it is
engine-version-mostly-independent (though 4.6's SSR rewrite and 4.7's HDR
output make the desktop tier meaningfully nicer — the one place where
migration and visuals genuinely connect).

Recommendation within the recommendation: treat dual-target as its own
post-migration milestone decision, not a migration rider. The web demo remains
the gate (DESIGN §7); a desktop tier must never fork gameplay.

### 3.4 If/when WebGPU-on-web lands

The event to watch. When official Godot ships WebGPU web export (dev snapshot
level), everything above re-opens: Forward+ in the browser, and a fresh look at
threading (WebGPU + pthreads + SharedArrayBuffer interplay will have its own
gotchas, likely a new COOP/COEP-class story). Being on 4.6/4.7 when that
happens turns "adopt WebGPU" into a one-minor hop with our patch set already
rebased once and slimmed to ~4. Being on 4.4.1 would make it a three-plus-minor
leap with six stale patches and a dead emsdk. **That is the strongest single
argument for migrating in the near term despite visuals not moving:** we are
buying a short runway to the thing we actually want.

The community WebGPU fork (4.6.2-based, beta May 2026) is worth a
time-boxed *spike* someday precisely because we'd be on 4.6 — but it is not a
deployment path: single-maintainer, beta, and our build is a threaded custom
C++ module build, the hardest possible client.

---

## 4. Cost and risk of migrating

### 4.1 Work items (to 4.6 + voxel 1.6)

| Item | Effort | Risk |
|---|---|---|
| `versions.env` bump + emsdk 3.1.64 → 4.0.11 + Docker toolchain rebuild | ~1 day (pipeline is parameterized for exactly this) | **Medium** — emsdk 4.x is a major compiler jump; expect WASM size/behavior drift, worker startup timing changes. Mitigated by re-running heap A/B + soak (below). |
| Drop G-0001; move pool-size (and likely V-0005) policy into shell JS via `Module.emscriptenPoolSize` | ~½ day | Low; must re-verify FP-M1b thread arithmetic (voxel ≤10 + WTP 2 + spare ≤3 ≤ pool) on the new runtime knob. |
| Rebase V-0001 waterlogging (21 KB) onto voxel 1.6 | **1–3 days** | **Highest.** Upstream blocky/fluid internals moved (1.5 tint mode touched the mesher; master has fluid fixes). Needs careful re-derivation, not mechanical rebase. |
| Rebase V-0002 early-out; open upstream PR in parallel | hours | Low. |
| Re-anchor V-0003/V-0004 (mostly new files + mesher hooks) | ~1 day | Low-medium — pure-arithmetic headers are untouched; only the `VoxelMesherBlocky` hook points and Parameters-lock snapshotting need re-anchoring against 1.6's mesher. |
| GDScript sweep 4.4 → 4.6 | 1–2 days | Low-medium — historically small per-minor breakage, but the codebase is large; the gate suite is the real safety net. |
| Physics default check | hours | Low — Jolt is default *for new projects* only; our terrain physics is analytic. Explicitly pin the physics engine setting; smoke-test `VoxelBody` rigid bodies. |
| Full re-validation: verify_feature 6027/0, faceted/FP gates, Tier A rendered soak, Tier B web soak, heap A/B **re-baseline** | **2–4 days** | This is the long pole and non-negotiable: the emsdk jump alone invalidates the NEVER-OOM baselines. |

**Total: ~1–2 focused weeks.** The distribution matters: two-thirds of it is
validation we'd want anyway, and it re-certifies the entire pipeline on a
maintained toolchain.

### 4.2 Risks worth naming

1. **Silent WASM regressions from emsdk 4.x** — memory-growth behavior, pthread
   startup, `hardwareConcurrency` interaction. Mitigation: the A/B + soak
   harnesses we just built (tasks #104/#105) exist for exactly this; migration
   is their first big customer.
2. **Waterlogging rebase introduces a subtle mesher bug** — mitigations: the
   patch's own gates, plus FLAT byte-identity which pins the whole mesher
   output. Byte-identity across an *engine* migration may legitimately break
   (float/codegen drift); if it does, re-pin the golden data on the new engine
   *after* visual + gate verification, as a deliberate, documented step — do
   not weaken the gate to pass it.
3. **godot_voxel 1.6 internal behavior changes** beyond changelog (threading,
   streaming cadence) shifting FP-M1c/FP-M2 tuning constants (`POOL_D_WARM`,
   ramp budgets, controller setpoints). Mitigation: the load controller is
   closed-loop by design — it should absorb moderate drift; the soak gate
   catches the rest.
4. **Opportunity cost** — 1–2 weeks not spent on FP-M3/orbit. This is the real
   price; it is why the trigger is "post-FP-M2 quiet window" and not "now".

---

## 5. Sequencing and trigger

**Do not migrate before FP-M2 ships.** Three compounding reasons:

1. FP-M2e's deploy gate is *measurement-based* (browser heap A/B, worst-frame
   soak). Changing engine+module+compiler underneath it makes every measurement
   uninterpretable — you can no longer attribute a regression to the feature
   or the migration.
2. The steelman (#102) is reviewing code written against 4.4.1/v1.4.1
   semantics. Land its findings first.
3. A migration is itself a destabilization event best done on a *quiet* tree,
   with all gates green and a production baseline to diff against.

**Recommended schedule:**

- **T0 (now):** nothing. Finish FP-M2e, deploy flag-ON, let it soak live
  (1–2 weeks of production telemetry).
- **T1 (first quiet window after FP-M2 is stable in production):** the
  migration, as its own milestone branch with the §4 work items and the full
  gate ladder. Target Godot 4.6.x + voxel 1.6; **at T1 start, check for a
  Zylann 4.7-paired release** — if it exists and is ≥ a few weeks old, target
  4.7.x instead (it additionally brings HDR output/AreaLight3D for a future
  desktop tier; the pthread knob is already in 4.6). Never pair with voxel
  master.
- **T2 (standing watch, re-evaluate quarterly):** official WebGPU-on-web
  progress (godot-proposals #4806, 4.8+ dev snapshots). The day it reaches a
  dev snapshot, open a renderer-strategy assessment — that is the visuals
  unlock and may justify tracking a dev branch early.
- **Cadence going forward:** adopt "stay within one minor of current, migrating
  in the quiet window after each Godot minor + paired voxel release" as
  standing policy, so no future migration is ever this large again.

---

## 6. Where this reasoning could be wrong

Adversarial pass on my own conclusions:

1. **"Visuals are WebGPU-gated" could be too absolute.** A determined
   shader-level effort on WebGL2 (screen-space-lite effects in `gdshader`,
   MRT tricks within Compatibility's limits) can fake more of the dream than
   §3.2 credits. If the peer visuals research finds Compatibility-tier
   SSR-like or GI-like techniques shipping in real web games, the ceiling is
   higher than stated — though the *conclusion* (migration doesn't move it)
   still holds, since those are shader work on any version.
2. **WebGPU could land faster than "no ETA" implies.** Browser support went
   universal in late 2025; community pressure (and a working fork to crib
   from) can compress engine timelines. If official WebGPU web export appears
   in a 4.8 dev snapshot this year, the right move might be to *skip* the 4.6
   hop and do one migration straight to the WebGPU version. Counter-argument:
   a first-cut WebGPU backend will be Compatibility-default with experimental
   flags for a cycle or two, and our threaded-module build will be the last
   configuration it stabilizes for — the 4.6 hop is unlikely to be wasted.
   The T1/T2 split above hedges exactly this: T1 is cheap enough to not
   regret, T2 re-opens the question on evidence.
3. **The waterlogging rebase could be worse than budgeted.** If upstream's
   fluid rework (visible on master) restructures `BakedModel`, V-0001 becomes
   a re-implementation, not a rebase — the 1–3 day estimate could triple. A
   ½-day *pre-flight probe* (apply all six patches to voxel 1.6 in a scratch
   build, count rejects) at T1 start converts this unknown into a number
   before committing the window.
4. **"No simplification" could age badly.** Zylann has an active roadmap;
   if a future voxel release lands blocky LOD or multi-terrain coordination,
   the FP-M2/M3 calculus changes and a migration could retire real code. The
   changelog check that produced §2 is cheap — re-run it each Godot minor.
5. **The emsdk 3.1.64 pin is a slow-burning fuse either way.** Staying on
   4.4.1 means an EOL engine on an EOL compiler serving a live threaded WASM
   site; browser regressions against old Emscripten pthread runtimes have
   happened before and would hit us with no upstream fix available. I weighted
   this as a "maintenance positioning" benefit; it could equally be read as a
   *forcing* risk that argues for T1 sooner. If a browser update ever breaks
   the live demo, T1 becomes immediate regardless of FP-M3 plans.
6. **Dual-target could quietly fork the project.** §3.3 leans on our two-render-
   path discipline, but a visuals-max desktop tier creates pressure for
   desktop-only features (real GI interplay with the sim layer, higher view
   distances) that erode "one behaviour". If the team can't hold that line,
   the honest choice is *not* building the desktop tier — reach beats pixels
   for this project (DESIGN §7 already says so).

---

## Sources

- Godot 4.6 release — https://godotengine.org/releases/4.6/
- Godot 4.7-stable (2026-06-18) — https://github.com/godotengine/godot/releases/tag/4.7-stable ; 4.7.1 RC1 — https://godotengine.org/article/release-candidate-godot-4-7-1-rc-1/
- Web export = Compatibility/WebGL2 only (4.7 docs) — https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_web.html
- WebGPU proposal (open, uncommitted) — https://github.com/godotengine/godot-proposals/discussions/4806 ; https://github.com/godotengine/godot-proposals/issues/6646
- Community WebGPU fork (4.6.2-based, beta 2026-05-10) — https://godotwebgpu.com/
- godot_voxel releases (1.5↔4.5, 1.6↔4.6) — https://github.com/Zylann/godot_voxel/releases ; changelog — https://github.com/Zylann/godot_voxel/blob/master/doc/source/changelog.md
- Godot 4.6-stable web CI emsdk pin (`EM_VERSION: 4.0.11`) — https://github.com/godotengine/godot/blob/4.6-stable/.github/workflows/web_builds.yml
- Runtime pthread-pool knob in 4.6/4.7 (`Module['emscriptenPoolSize']||8`) — https://github.com/godotengine/godot/blob/4.6-stable/platform/web/detect.py ; same in 4.7-stable
- godot_voxel master `VoxelBlockyLibrary::bake()` (no early-out upstream) — https://github.com/Zylann/godot_voxel/blob/master/meshers/blocky/voxel_blocky_library.cpp
