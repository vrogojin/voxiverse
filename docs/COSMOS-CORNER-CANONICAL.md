# COSMOS-CORNER-CANONICAL — the terrain-preserving §8.2 corner-quadrant fix

Status: **LOCKED DESIGN (Fable) → Opus implements.** Fixes the corner-quadrant §8.2 violation
diagnosed in `docs/COSMOS-SEAM-METRIC.md` — the user's "I really get different blocks when
returning to the original face" — by replacing the per-home-face lattice extrapolation of the
corner wedge with a **canonical, position-only fold**: every corner-quadrant column resolves
to the nearest TRUE global cell of its physical direction, and generates *that* cell's
content. Real terrain is preserved (no `CORNER_SEA` ocean mask), spawn does not move, and the
render placement (the §4.6 metric lie, SEAM-METRIC §2's ~24-block corner shear) is explicitly
**out of scope** — a separate, later decision.

Read together with: `docs/COSMOS-SEAM-METRIC.md` (the diagnosis + measured crack/shear
tables), `docs/COSMOS-PLANET-TOPOLOGY.md` §5 (corner topology; §5.3's ocean-mask/edit-lock
design is *partially superseded* here — §8), `docs/COSMOS-AUDIT.md` F2 (the fold-the-key
purity contract this extends), `cube_sphere.gd` (`fold_cell` 348, `dir_to_face_cell` 224,
`face_cell_to_dir` 199), `lattice_nav.gd` (`dir_of` 39), `terrain_config.gd`
(`worker_fold_column` 700, `column_profile` 490), `cosmos_chart.gd` (`to_global_column` 59,
`flip` 151).

---

## 0. The locked decision (user-chosen fork)

> **Locked:** the corner quadrant keeps its real terrain and becomes **path-independent**
> (§8.2): the same physical spot shows the same blocks no matter which home-face epoch
> generated it. Not chosen: the SEAM-METRIC §5 ocean mask (erases terrain) and the
> face-centre spawn relocation (avoids rather than fixes). Explicitly deferred, do not
> bundle: the corner render *placement* shear (~0.74·ρ, SEAM-METRIC §2) — this fix changes
> **what** the wedge shows, not **where** the window draws it.

## 1. The defect, precisely

For a window column out of range in **both** axes, `fold_cell` returns face −1 (the corner
quadrant has no single-edge D4 fold — `cube_sphere.gd:352-354`), and all three consumers fall
back to the **raw home-face coordinates**:

- `worker_fold_column` (terrain_config.gd:704-707) → column key `(gen_face, vx, vz)`;
- `CosmosChart.to_global_column` (cosmos_chart.gd:61-62) → key `{home face, raw i, j}`;
- `LatticeNav.dir_of` (lattice_nav.gd:49-53) → the raw gnomonic overshoot direction.

Two consequences, only the first of which is the reported bug:

1. **The lattice-keyed feature stack is home-face-dependent.** Trees, ores, strata, bedrock,
   smoothing/slope stencils and snow-state hashes all key on the folded column
   (the audit-F2 contract) — which in the wedge is `(A, raw)` when homed on face A and
   `(B, raw′)` when homed on B, for the *same physical region*. Different hashes → different
   trees, veins, shapes: **blocks genuinely change when the home face changes.** This is the
   §8.2 violation.
2. The height/biome *noise field* is already position-pure — `_curved_profile` samples 3D
   noise at `d̂·R` (terrain_config.gd:586-591) — but the wedge's *direction field* is each
   home face's own gnomonic extrapolation, so even heights re-sample on a different grid per
   epoch (±1-block re-quantisation jitter on top of consequence 1).

The fix must make the wedge's **column identity** a pure function of physical position, so
the whole F2-folded feature stack downstream becomes canonical for free.

### 1.1 The fringe (2b), sharpened: already path-independent — divergence is 2a only

SEAM-METRIC §7 flagged a second suspect zone: a *strip* cell whose smoothing/slope/tree
stencil neighbour lands in the quadrant. Code inspection resolves it: the architecture is
**fold-first** — both entry points fold the column to its TRUE face *before* `resolve_cell`
(`worker_fold_column` sets `ctx.face` to the folded face and returns folded coords;
`generated_cell_global` receives chart-folded coords), and every stencil read
(`_corner_targets`, `column_profile(x±1, z±1, pcache)` — terrain_config.gd:1010-1152) runs
in that TRUE face's frame through the GenCtx. A strip cell near a corner therefore does its
double-out stencil fallback *from the true face*, identically from any home-face epoch —
**the fringe is already §8.2-consistent today**; the measured/expected divergence is
strictly confined to double-out window columns (the quadrant proper, 2a). Prediction for
the acceptance repro: strip cells byte-equal across epochs even at corner-adjacent
positions; only quadrant columns diverge.

Corollary of the fix (must be reflected in verify): canonicalising `dir_of`'s fallback also
changes the fringe's stencil *inputs* — a true cell within ≤ 2 cells of a cube corner whose
stencil steps double-out now reads the real neighbour cell's profile instead of a raw
extrapolation. That is a **one-time, deterministic content change** for a handful of columns
at each of the 8 corners (path-independent before and after; the *value* changes once at the
fix). The acceptance gates compare post-fix path vs post-fix path — never pre vs post — and
(c5)'s byte-identity claim is FLAT-only.

## 2. The canonical position fold

### 2.1 Definition

For a double-out column `(face, i, j)`:

```
d̂    = face_cell_to_dir(face, i, j, n)          # raw gnomonic overshoot — UNCHANGED, f64
cell = dir_to_face_cell(d̂, n)                   # the M0 inverse: nearest TRUE global cell
     → {face′, i′, j′},  i′/j′ clamped to [0, n−1]
```

and the column generates **that true cell's content** — full stack, exactly as if the cell
were read in-range on its own face: `column_profile(i′, j′, ctx(face′))`, hashes on
`(face′, i′, j′)`, stencil neighbours folded from `(face′, i′±1, j′±1)`.

The physical position of the window column (`d̂`, and hence everything about *placement*) is
untouched — the same direction the shipped code already renders at. Only the **content key**
changes: from "home face's imaginary overshoot cell" to "the real cell that actually lives
in that direction".

### 2.2 Path-independence proof

Content at a physical direction is now `stack(dir_to_face_cell(d̂))` — a composition of two
pure functions of `d̂` with **no home-face argument**. Two windows homed on different faces
parameterise the wedge by different lattices `d̂_A(i,j)` vs `d̂_B(i′,j′)`, but wherever those
parameterisations reach the same physical direction they produce the same canonical cell and
therefore byte-identical blocks. §8.2 is restored in the sense the user experiences: *the
same place has the same content on return.* (The M0 property suite already pins
`dir_to_face_cell ∘ face_cell_to_dir` as an exact round-trip for real cells; here it is used
as a nearest-cell projection for off-face directions.)

### 2.3 Well-definedness (the three edge cases)

- **The canonical face is always one of the two corner-adjacent neighbours, never the home
  face:** a double-out column has `|u|, |v| > 1` while the home normal's coefficient is 1,
  so `face_of_dir`'s argmax picks the û- or v̂-axis face (sign-selected toward the overshoot).
  Exact component ties (the wedge diagonal) resolve deterministically by `face_of_dir`'s
  fixed x≥y≥z ordering (cube_sphere.gd:262-273) — pure, platform-independent f64.
- **In-range by construction, clamped for the boundary measure-zero:** the chosen face is
  argmax, so the recovered `a, b ∈ [−1, 1]`; `roundi((a+1)·n/2 − 0.5)` lands in `[0, n−1]`
  except exactly at `a = ±1`, where it can produce `n` — the canonical helper clamps to
  `[0, n−1]` and counts the clamp on an F8-style fence (a real out-of-range must never pass
  silently).
- **Gnomonic validity:** `tan(a·π/4)` wraps at `|a| = 2`. The deepest reachable overshoot is
  the far field's `R_FAR = 3,072` blocks ≈ `2·3072/n ≈ 0.61` beyond the edge → `|a| ≤ 1.62`,
  inside the valid branch with margin. The fence also trips on `|a| ≥ 2` (never in practice).

### 2.4 Cost

The canonical branch replaces one Dictionary construction with one `face_cell_to_dir` + one
`dir_to_face_cell` (f64 arithmetic + one `tan` pair / two `atan` — the same cost class as the
`_curved_profile` direction the column pays anyway), executed **only for double-out columns**
(blocks overlapping a corner quadrant; zero cost everywhere else), and memoised per column by
the existing `ctx.memo` keyed on the canonical `(face′, i′, j′)`. No measurable web
throughput change; the in-range fast path (lattice_nav.gd:45-46, >99.9 % of columns) is
untouched.

## 3. What the wedge shows after the fix

The wedge now literally displays the **neighbour faces' real cells** — the same mountains,
coasts, trees, ore veins and snow that the player finds in-range after flipping onto those
faces, byte-identical by construction (it is the same `(face′, i′, j′)` through the same F2
pipeline). Returning to a face re-shows the same content at the same physical spots. Heights
along the wedge boundary move by at most one cell's worth of slope relative to today
(nearest-cell sampling vs raw-direction sampling differ by ≤ 1 cell), so the SEAM-METRIC §2
boundary-continuity envelope (dh ≈ 0–2 blocks near the corner) is preserved — "reasonable
continuity" is met at today's measured level or better, with real features instead of
extrapolated ones.

## 4. Honest residuals (documented, accepted, all corner-local)

1. **Placement is unchanged** — the ~0.74·ρ corner shear and the wedge-boundary *position*
   gap (SEAM-METRIC §2 tables) remain exactly as shipped. Out of scope by the §0 lock; the
   full M5 multichart render is the vehicle for that decision.
2. **Sampling aliasing:** the window's 90° corner quadrant covers the true 120° wedge, so the
   window→true-cell map is expansive (~4/3): each window shows a sampling of the wedge that
   **skips ~a quarter of true columns**, and different home faces skip different ones — a
   tree can be visible from one window and unsampled from another. Bounded, cosmetic,
   corner-only; retired by M5. (The map being expansive also means key collisions —
   two window cells, one canonical cell — are rare rather than systematic.)
3. **Edits in the wedge** now key to canonical true cells via `to_global_key` → a wedge edit
   *survives* re-anchors and flips (an upgrade over today's unfindable raw keys). Two
   listing-side quirks remain: `unfold_to_window` still returns `found = false` for the
   quadrant (cosmos_chart.gd — unchanged), so the fallback mesher's `placed_cells_window`
   and the M4 edit re-mirror skip wedge edits (point queries via `cell_value_at` resolve
   them correctly). **Recommended companion (separate commit, team-lead may cut):** the
   TOPOLOGY §5.3 *edit-lock* — refuse `_write_cell` for double-out window cells — which is
   already the locked M5 design and erases the quirk class entirely.
4. The snowfall sim still mutates snow over time everywhere (SEAM-METRIC §7 mechanism 3) —
   time-dependence, not path-dependence; unrelated and untouched.

## 5. Bounded fix vs full M5 multichart

| | canonical position fold (this doc) | full M5 multichart |
|---|---|---|
| restores §8.2 content | yes, exactly | yes |
| fixes corner placement shear | no (out of scope) | yes |
| touches render model / bend | no | yes (§3.4 + per-face windows) |
| scope | ~60 lines, 4 files + verify | weeks; render + streaming redesign |
| web risk | negligible (pure f64 branch) | high until proven |

**Locked: the bounded fix now; multichart remains the M5 placement decision.**

## 6. Implementation plan (Opus: edit-by-edit)

1. **`cube_sphere.gd` — the kernel primitive.** Add
   `static func fold_cell_canonical(face: int, i: int, j: int, n: int) -> Dictionary`:
   in-range → identity; single-out → exact `fold_cell` D4 branch (delegate); double-out →
   the §2.1 canonicalisation (`face_cell_to_dir` → `dir_to_face_cell` → `clampi` both axes
   to `[0, n−1]`), returning `{face, i, j}` — never −1. Add a fence counter
   (`corner_fence_seen()` — the F8 `oob_seen` discipline) incremented when the clamp fires
   or `|a| ≥ 2`. Pure, no shared mutable state, frozen tables only — worker-safe under the
   frozen-epoch contract. **`fold_cell` itself is untouched** (M0 contract; −1 remains the
   sentinel where refusal semantics are wanted).
2. **`lattice_nav.gd`.** `dir_of` (line 39): replace the −1 raw-fallback branch (49-53) with
   the canonical cell's direction (call `fold_cell_canonical` in place of `fold_cell` at
   :47; the `gf < 0` branch disappears). `fold_column` (:27) and `neighbor` (:34) switch to
   `fold_cell_canonical` (no live callers today, but the abstraction must stay consistent
   with `dir_of`). Rewrite the header's §5.3 stub paragraph (lines 17-20): the corner
   quadrant now folds canonically per this doc; M5 refines placement + edit policy.
3. **`terrain_config.gd` `worker_fold_column` (700-707):** call `fold_cell_canonical`; the
   `tf < 0` branch disappears (`ctx.face` = the canonical face always). Fix the :703
   comment (no ocean mask exists; cite this doc).
4. **`cosmos_chart.gd` `to_global_column` (59-63):** corner branch → `fold_cell_canonical`
   result instead of the raw fallback (`to_global`, `to_global_key`, `to_region_key`,
   `world_point_of` inherit canonical behaviour automatically). **`flip` (:154) keeps plain
   `fold_cell`** — a flip attempted inside the corner quadrant must still be REFUSED
   (`{ok:false}`, the M5 hysteresis guard). Fix the :52 comment.
5. **Comment sweep:** every remaining "deep-ocean-masked" claim
   (grep `deep-ocean`) → "canonical position fold (COSMOS-CORNER-CANONICAL); M5 refines".
6. **New verify suite `godot/src/tools/verify_cosmos_corner.gd`** — §7 gates.
7. **Extend the full-block path-independence gate** (the 24-edge suite) with a
   corner-quadrant band: for each of the 8 corners, from each of its 3 adjacent home faces,
   full packed `generated_cell_global` over a wedge band must agree wherever the canonical
   cells coincide (see gate (c2)).
8. *(Optional companion, separate commit, per §4.3):* the §5.3 edit-lock — one double-out
   guard in `WorldManager._write_cell` + a refusal gate.

## 7. Verification

Headless gates (`verify_cosmos_corner.gd`):

- **(c1) well-defined:** for a sweep of double-out columns around all 8 corners from every
  adjacent face (± both signs, depths 1..96): `fold_cell_canonical` returns an **in-range**
  cell on one of that corner's three faces; the fence stays zero over the sweep;
  deterministic (two calls byte-equal).
- **(c2) §8.2 in the wedge — THE gate:** for wedge columns from home face A and home face B
  whose canonical cells coincide (build the correspondence by canonicalising both sweeps and
  joining on the canonical key): full packed `generated_cell_global` over r ∈ a vertical
  band is **byte-identical** — and equals the true face's own in-range generation of that
  cell (three-way equality: A-window path == B-window path == native).
- **(c3) continuity regression:** across the wedge-boundary rows (strip row 0 vs wedge row
  −1, depths 1..48), |dh| ≤ 4 blocks (pins today's measured 0–2 envelope with margin — a
  regression guard, not a geometric theorem).
- **(c4) edits:** a `_write_cell` through a wedge window cell stores under the canonical
  true-cell key; `cell_value_at` reads it back through the same window; `chart.flip` inside
  the quadrant still returns `ok:false`.
- **(c5) FLAT_WORLD byte-identity:** all changes sit behind `CubeSphere.FLAT_WORLD == false`
  call paths (chart-only / curved-profile-only); the flat generator output over a reference
  region is byte-identical pre/post (existing verify_feature suite stays green).
- **(c6) worker parity:** `worker_fold_column` and `chart.to_global_column` produce the same
  canonical column for the same window column (render == physics in the wedge — rule 1).
- **(c7) fringe path-independence (the 2b gate):** for TRUE cells within 2 cells of each of
  the 8 corners (in-range on their own face, stencils stepping double-out), full packed
  generation is byte-identical when reached from every home-face epoch that can reach them —
  asserted both as a pre-fix baseline (§1.1 predicts it already passes) and post-fix (the
  canonical `dir_of` must not introduce epoch-dependence). Do NOT diff these cells' content
  pre-fix vs post-fix — §1.1's corollary changes it once, deterministically.

Live checklist (curved web build): stand at the spawn corner, note a distinctive wedge
feature (mountain silhouette / coastline / tree cluster); cross any border, return — the
same features are present at the same spots (modulo §4.2's documented per-window sampling
skips); no worker crash streaming corner blocks (the race suite's Phase A extended to a
corner-straddling viewer position); PERF unchanged vs pre-fix at the same spot.

## 8. Deviations

1. **From SEAM-METRIC §5 (items 1–2):** the ocean mask and face-centre spawn are **not**
   implemented — user decision: keep the corner terrain and fix its identity instead. The
   SEAM-METRIC §5 verify gate list is superseded by §7 here; its §3 (no frame surgery) and
   §2 measurements stand.
2. **From TOPOLOGY §5.3 (locked corner design):** §5.3's *deterministic ocean mask* is
   dropped (this fix makes it unnecessary for §8.2; the corner keeps real terrain). §5.3's
   *edit-lock* is retained as the recommended companion (§6 step 8). §5.3's corner-zone
   *placement* commentary is unaffected (M5).
3. **The −1 sentinel survives** at exactly one semantic site (`chart.flip` refusal) — the
   kernel keeps both `fold_cell` (topological truth: the quadrant has no D4 fold) and
   `fold_cell_canonical` (content/key resolution: every direction has a nearest real cell).
   Callers choose by need; the doc-comments must make the split explicit.
