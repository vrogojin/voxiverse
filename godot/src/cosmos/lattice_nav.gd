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
## edge (§4.1/§4.3 — the extended window is ONE rectilinear lattice). Corner quadrants (out of
## range in BOTH axes) are the M5 stub (§5.3): `fold_cell` returns face −1 there and `dir_of`
## falls back to the raw off-face gnomonic direction (deterministic + pure; the corner zone is
## deep-ocean-masked and edit-locked in M5, so nothing walks or builds there).
##
## Pure/deterministic: no `randi()`/`Time`; every function is a pure function of its arguments.

## Fold a (possibly off-face) column to its true global column {face, i, j}. Thin wrapper over
## CubeSphere.fold_cell so worldgen expresses the fold through this named abstraction (§4.4).
static func fold_column(face: int, i: int, j: int, n: int) -> Dictionary:
	return CubeSphere.fold_cell(face, i, j, n)

## The global column `stencil_step` cells away from `(face, i, j)` (di, dj in cells), folded to
## its true face across any edge it crosses. THE stencil primitive (§4.4): a worldgen pass that
## reads `neighbor(face, i, j, ±1, 0)` / `(0, ±1)` gets the correct across-seam column with no
## per-algorithm edge handling.
static func neighbor(face: int, i: int, j: int, di: int, dj: int, n: int) -> Dictionary:
	return CubeSphere.fold_cell(face, i + di, j + dj, n)

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
	var g := CubeSphere.fold_cell(face, i, j, n)
	var gf: int = g["face"]
	if gf < 0:
		# Corner quadrant (out of range in BOTH axes) — §5.3 M5 stub. Deterministic fallback to
		# the raw off-face gnomonic extrapolation so worldgen never crashes; the corner zone is
		# forced deep ocean + edit-locked in M5, so this direction is never walked or built on.
		return CubeSphere.face_cell_to_dir(face, float(i), float(j), n)
	return CubeSphere.face_cell_to_dir(gf, float(g["i"]), float(g["j"]), n)
