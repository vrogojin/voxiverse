extends RefCounted
class_name LatticeNav
## COSMOS M3 — the lattice stencil abstraction (docs/COSMOS-PLANET-TOPOLOGY.md §4.4).
##
## Worldgen that samples NEIGHBOURING columns (the smoothing 3×3 height stencil, TreeGen's
## trunk scans, snow-drift checks) must be a pure function of the GLOBAL cell (§8.2). Near a
## face edge a neighbour column lives on ANOTHER face, reached through the exact edge remap
## (§4.2). `LatticeNav` is the one place that fold happens for worldgen: give it a face-local
## column `(face, i, j)` — possibly out of `[0, N)` because a stencil stepped across the edge —
## and it returns the TRUE global column `(face', i', j')`, then the unit direction d̂ of that
## true cell. The fast path (an in-range column) is the identity, so > 99.9 % of columns pay a
## single range check; only the edge strips fold (§4.4).
##
## Because the fold lands on the true global column, the 3D-noise domain d̂ is continuous across
## the seam by construction: a column just inside face A and its 1:1 neighbour just inside face B
## sample adjacent directions on the sphere, so height/biome/climate never cliff or gap at an
## edge (§4.1/§4.3 — the extended window is ONE rectilinear lattice). Corner quadrants (out of range in
## BOTH axes) now fold CANONICALLY (COSMOS-CORNER-CANONICAL #69): `fold_cell` still returns face −1
## (topological truth — no D4 fold), but `dir_of`/`fold_column`/`neighbor` route through
## `CubeSphere.fold_cell_canonical`, which resolves the wedge to the nearest REAL cell of its physical
## direction — position-only, home-face-independent, real terrain (§8.2). M5 later refines the corner's
## render PLACEMENT + edit policy.
##
## Pure/deterministic: no `randi()`/`Time`; every function is a pure function of its arguments.

## Fold a (possibly off-face) column to its true global column {face, i, j}. Thin wrapper over
## CubeSphere.fold_cell_canonical so worldgen expresses the fold through this named abstraction (§4.4) and
## the corner quadrant resolves to its nearest real cell (COSMOS-CORNER-CANONICAL #69), consistent with
## dir_of below — never face −1.
static func fold_column(face: int, i: int, j: int, n: int) -> Dictionary:
	return CubeSphere.fold_cell_canonical(face, i, j, n)

## The global column `stencil_step` cells away from `(face, i, j)` (di, dj in cells), folded to
## its true face across any edge it crosses. THE stencil primitive (§4.4): a worldgen pass that
## reads `neighbor(face, i, j, ±1, 0)` / `(0, ±1)` gets the correct across-seam column with no
## per-algorithm edge handling.
static func neighbor(face: int, i: int, j: int, di: int, dj: int, n: int) -> Dictionary:
	return CubeSphere.fold_cell_canonical(face, i + di, j + dj, n)

## The unit direction d̂ of the true global column that `(face, i, j)` denotes — folding across
## an edge first (§4.3/§4.4). THE noise-domain accessor the curved worldgen samples so 3D noise
## is seam-continuous. Corner quadrant (fold face −1): the raw off-face direction (M5 stub).
static func dir_of(face: int, i: int, j: int, n: int) -> CubeSphere.DVec3:
	# In-range fast path (COSMOS-AUDIT F4): >99.9 % of columns are in [0, N) and fold to the identity,
	# so skip CubeSphere.fold_cell entirely — no per-column Dictionary allocation. This is value-identical
	# (fold_cell returns {face, i, j} unchanged for an in-range column) and cuts the curved worker's
	# per-cell RefCounted/Dictionary churn (which, under extreme concurrent contention, was the residual
	# non-determinism source once the _active_face / nested-container races were removed).
	if i >= 0 and i < n and j >= 0 and j < n:
		return CubeSphere.face_cell_to_dir(face, float(i), float(j), n)
	# COSMOS-CORNER-CANONICAL (#69): fold to the CANONICAL true global cell — single-edge strips use the
	# exact D4 fold; the corner quadrant resolves to the nearest REAL cell of its physical direction
	# (position-only, home-face-INDEPENDENT), so the wedge samples real neighbour terrain instead of a
	# per-home-face gnomonic extrapolation. Never face −1, so the old raw-fallback branch is gone. The
	# noise domain d̂ is thereby a pure function of position → the same physical spot samples identically
	# from any home-face epoch (§8.2, docs/COSMOS-CORNER-CANONICAL §2).
	var g := CubeSphere.fold_cell_canonical(face, i, j, n)
	return CubeSphere.face_cell_to_dir(int(g["face"]), float(int(g["i"])), float(int(g["j"])), n)
