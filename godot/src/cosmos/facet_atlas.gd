class_name FacetAtlas
extends RefCounted
## COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §2) — the FacetAtlas kernel. Built ONCE at warm_up: for each of
## the 6·K² facets of the piecewise-flat planet it computes a PLANARIZED square patch (§2.1), its rigid
## lattice→planet frame (§2.2, forced right-handed), a per-facet decorrelation offset O (§2.3), and the local
## polygon + lattice domain (§2.4). Faceted worldgen samples the real sphere terrain at each facet cell's true
## direction (cell_dir → TerrainConfig.profile_at_dir). ALL kernel math is f64 (scalars / CubeSphere.DVec3) —
## NEVER route a direction/anchor through Vector3 (f32) before the final placement (pitfall #1). Pure/immutable
## after warm_up (read-only-after-freeze, like the noise singletons), so voxel workers may read it. Generation
## is a pure function of (SEED, fid, x, z) — stronger than the curved frozen-epoch contract (no window state).

const K := 24                    # faceting resolution: 6·K² = 3456 facets — LOCKED at 24 (user taste-test, FP0 k=8/16/24)
const R_BLOCKS := 3072.0         # planet radius, blocks. Facet edge = (π/2·R)/K ≈ 200 blocks — R tracks K so a facet
                                 # stays a ~200-block playable patch (facet size is the only thing R×K couple; scale-invariant math)
const MARGIN_CELLS := 8          # lattice cells kept beyond the facet polygon (streaming slack)
const STRIP_CELLS := 2           # per-side seam strip width (FP2+)
const SPAWN_EDGE_MIN := 48       # spawn scan stays ≥ this many cells from the facet boundary

# ---------------------------------------------------------------------------------------
# COSMOS ORBITAL O4a (docs/COSMOS-ORBITAL-O1O4-DESIGN.md Part B §3.1) — the GLOBAL FID NAMESPACE.
# Facet ids are a single namespace across ALL bodies: each registered body owns a contiguous fid
# block [fid_base(body) .. fid_base(body) + 6·k_body² − 1]. BODY_TABLE is APPEND-ONLY, never
# re-ordered, and a body's k/r NEVER change after content exists on it (fids encode into persisted
# edits + future portal anchors — §3.1 fact 5). In O4a the table holds ONLY Earth at fid_base 0 with
# k == K (24) / r == R_BLOCKS (3072) → every per-fid accessor is bit-for-bit what the shipped
# single-body atlas returned (k_of ≡ 24, r_of ≡ 3072, body_of_fid ≡ 0, facet_count ≡ 3456), proven by
# the G-O4-EQ gate (verify_multibody.gd). The Moon (k=14/r=1737) is APPENDED in O4b behind
# CubeSphere.MULTI_BODY — nothing here changes until then. Earth's `k`/`r` MUST equal K/R_BLOCKS or
# the (still const-based) build math in _build_facet/_build_seam would disagree with the accessors.
## O4b: the Moon is APPENDED (never inserted/re-ordered — fact 5). k=14 ⇒ 6·14² = 1176 facets at
## fid_base 3456, r=1737 (real lunar radius in blocks; Earth stays the SHIPPED 3072 — the O3 D1
## resize to 6371 is a LATER stage and is NOT pre-empted here). Facet edge = (π/2·1737)/14 ≈ 195
## blocks — the same ~200-block playable patch Earth's k=24/R=3072 gives, so the Moon's facets feel
## like Earth's rather than being a differently-scaled grid. Built ONLY under CubeSphere.MULTI_BODY
## (default false ⇒ body_count()==1 ⇒ no Moon rows ⇒ byte-identical to O4a, proven by G-O4-EQ/OFF).
## The Moon ships DARK in O4b: no spawn facet, no SOI, unreachable in-game (O4c wires it up).
const BODY_TABLE := [
	{"name": "earth", "k": 24, "r": 3072.0},   # fid_base 0
	{"name": "moon",  "k": 14, "r": 1737.0},   # fid_base 3456  (MULTI_BODY only)
]

static var _ready := false
static var _nf := 0
static var _frame := PackedFloat64Array()   # 12/fid: c0'(3) ê_u(3) n̂(3) ê_w(3)
static var _off := PackedInt32Array()        # 2/fid: O.x O.z
static var _poly := PackedFloat64Array()     # 8/fid: local q0..q3 as (x,y)
static var _dom := PackedInt32Array()        # 4/fid: minx minz maxx maxz
static var _spawn_fid := -1

# COSMOS FACETED FP2 (§2.5) — per-facet seam table. Every facet has EXACTLY 4 grid-edge neighbours (the K×K×6
# facet grid is closed via CubeSphere.fold_cell at n=K), one per slot E/W/N/S. Each slot stores THIS facet's
# OWN-side ridge plane in its LATTICE frame — own(x,y,z)=A·x+B·y+C·z+D ≥ 0 is the interior half-space — plus the
# welded ring (world) and the world ridge normal m̂. The plane, the FP2 domain mask, the junction clip, and the
# exact physics all read the SAME (A,B,C,D), so render == collision == mask by construction (§3.5).
const S_EAST := 0    # +a
const S_WEST := 1    # −a
const S_NORTH := 2   # +b
const S_SOUTH := 3   # −b
static var _seam_plane := PackedFloat64Array()   # 16/fid: 4 slots × (A,B,C,D) — own-side plane in lattice coords
static var _seam_neigh := PackedInt32Array()     # 4/fid: neighbour fid per slot
static var _seam_ring := PackedFloat64Array()    # 24/fid: 4 slots × (r0.xyz, r1.xyz) welded ring (world)
static var _seam_mhat := PackedFloat64Array()    # 12/fid: 4 slots × m̂.xyz (world ridge normal, toward this facet)

# ------- O4a body registry (pure functions of BODY_TABLE + CubeSphere.MULTI_BODY; pre-warm safe) -------
# Every accessor derives from the const BODY_TABLE, so it is valid before AND after warm_up (mirroring
# facet_count()'s shipped pre-warm property).
#
# O4b — the FROZEN SLOT TABLES (O4a caveat 4). `body_of_fid`/`k_of`/`r_of` are worker-hot: facet_profile
# calls them PER COLUMN. Derived straight from BODY_TABLE they are a range search whose every step reads a
# const Dictionary (fid_base_slot re-summing 6·k² per call, then BODY_TABLE[slot]["r"]) — fine at one body
# where the loop never runs, wasteful at two. So warm_up FREEZES the ≤N-body registry into three tiny Packed
# arrays (one row per BODY, not per fid — ~40 B total, so Earth's memory ledger is unmoved and G-O4-OFF's
# array-size pins still hold). After warm_up every accessor is 1-2 Packed reads over never-mutated arrays
# (worker-safe by the same frozen-epoch argument as the atlas rows). Before warm_up they fall back to the
# BODY_TABLE derivation, so the pre-warm property the gates rely on survives.
static var _slot_base := PackedInt32Array()     # per built body: first fid  (slot 0 == 0 always)
static var _slot_k := PackedInt32Array()        # per built body: faceting resolution k
static var _slot_r := PackedFloat64Array()      # per built body: radius in blocks

## Freeze the registry slot tables (main thread, warm_up only; idempotent).
static func _freeze_registry() -> void:
	var nb := body_count()
	var sb := PackedInt32Array(); var sk := PackedInt32Array(); var sr := PackedFloat64Array()
	sb.resize(nb); sk.resize(nb); sr.resize(nb)
	var base := 0
	for s in range(nb):
		var k := int(BODY_TABLE[s]["k"])
		sb[s] = base
		sk[s] = k
		sr[s] = float(BODY_TABLE[s]["r"])
		base += 6 * k * k
	# publish fully-built (same discipline as CubeSphere._edge_flat): data arrays first, then _slot_base
	# — _slot_base.size() is what switches every accessor onto the frozen path.
	_slot_k = sk
	_slot_r = sr
	_slot_base = sb

## Number of bodies actually BUILT into the atlas: Earth always, any body beyond it iff MULTI_BODY.
## O4a: BODY_TABLE has one entry, so this is 1 either way.
static func body_count() -> int:
	if CubeSphere.MULTI_BODY:
		return BODY_TABLE.size()
	return 1

## First fid of built-body slot `slot` (= Σ 6·k² over earlier slots). Slot 0 (Earth) == 0 always.
static func fid_base_slot(slot: int) -> int:
	var base := 0
	for s in range(slot):
		var k := int(BODY_TABLE[s]["k"])
		base += 6 * k * k
	return base

## Registry slot index of a body name (-1 if absent). Earth == 0.
static func body_slot(body: String) -> int:
	for s in range(BODY_TABLE.size()):
		if String(BODY_TABLE[s]["name"]) == body:
			return s
	return -1

## First fid owned by `body`. fid_base("earth") == 0.
static func fid_base(body: String) -> int:
	return fid_base_slot(body_slot(body))

## Facet count of a single body = 6·k². body_facet_count("earth") == 3456.
static func body_facet_count(body: String) -> int:
	var k := int(BODY_TABLE[body_slot(body)]["k"])
	return 6 * k * k

## Which built body owns `fid` (slot index). Earth-only ⇒ 0 for every valid fid; 2-body ⇒ one compare.
## Post-warm this is a Packed scan (worker-safe); pre-warm it derives from BODY_TABLE.
static func body_of_fid(fid: int) -> int:
	var nb := _slot_base.size()
	if nb > 0:                                   # frozen path (post-warm_up)
		var s := nb - 1
		while s > 0 and fid < _slot_base[s]:
			s -= 1
		return s
	var slot := body_count() - 1                 # pre-warm fallback (main thread only)
	while slot > 0 and fid < fid_base_slot(slot):
		slot -= 1
	return slot

## Faceting resolution k for BUILT-body slot `slot` — the frozen per-slot read the build/dispatch paths
## use once they have resolved the slot (no repeated body_of_fid).
static func k_of_slot(slot: int) -> int:
	if _slot_k.size() > 0:
		return _slot_k[slot]
	return int(BODY_TABLE[slot]["k"])

## Planet radius (blocks) for BUILT-body slot `slot`. Earth 3072 (SHIPPED — NOT the O3 6371), Moon 1737.
static func r_of_slot(slot: int) -> float:
	if _slot_r.size() > 0:
		return _slot_r[slot]
	return float(BODY_TABLE[slot]["r"])

## Faceting resolution K for the body owning `fid`. Earth ≡ 24, Moon ≡ 14.
static func k_of(fid: int) -> int:
	return k_of_slot(body_of_fid(fid))

## Planet radius (blocks) for the body owning `fid`. Earth ≡ 3072.0, Moon ≡ 1737.0.
static func r_of(fid: int) -> float:
	return r_of_slot(body_of_fid(fid))

## TOTAL facets across all BUILT bodies (the global fid range [0, facet_count())). O4a ≡ 6·K² ≡ 3456
## (byte-identical to the shipped `6 * K * K`). Pure over BODY_TABLE → valid before warm_up.
static func facet_count() -> int:
	var total := 0
	for s in range(body_count()):
		var k := int(BODY_TABLE[s]["k"])
		total += 6 * k * k
	return total

# ---------------------------------------------------------------------------------------
# The FACETED global edit key (COSMOS-FP-M1-DESIGN §6.2 / FACETED-IMPL §6.2). Under FACETED an
# edit is bound to its FACET + LATTICE CELL forever, independent of which facet is active: when the
# active facet changes at a crossing the same world cell maps to a DIFFERENT active-lattice Vector3i,
# so a Vector3i key would silently re-interpret in the new lattice (corruption). The (fid, cell) int
# is that permanent identity — pure/static, so it is worker-safe and mirrors CubeSphere.edit_key's
# role for curved mode.
#
#   key = ((fid·2^18 + (x + 131072))·2^18 + (z + 131072))·2^11 + (y + 512)
#   12 bits fid | 18 bits (x+2^17) | 18 bits (z+2^17) | 11 bits (y+512)  -> 59 bits, a plain int64.
#
# Ranges (every term is non-negative, so the packed key is always positive → GDScript /,% are exact):
#   fid  — the GLOBAL multi-body fid (O4a §3.1 fact 4). The multiplicative pack is key ≈ fid·2^47, so a
#          plain int64 (< 2^63) holds fid to ~65,000 — FAR beyond any registered body count (Earth 3456
#          today; Earth+Moon at the O3 K=50 resize is 15,000 + 1,176 = 16,176). The old "fid < 4096" was
#          the single-body K=24 facet count, NOT a packing limit; the gate asserts pack/unpack round-trip
#          over the full registered fid range.
#   x,z  ∈ [−131072, 131071]  — the decorrelation offset O ∈ [−32768, 32767] (_build_facet:107-108)
#                               pushes |lattice| to ~3·10⁴; 2^17 centring gives ~4× headroom.
#   y    ∈ [−512, 1535]       — the worldgen vertical envelope (bedrock −64 … tallest surface+tree).
# ---------------------------------------------------------------------------------------
const _EK_XZ_OFF := 131072            # 2^17 lateral centring offset
const _EK_XZ_SPAN := 262144           # 2^18 lateral field width
const _EK_Y_OFF := 512                # y centring offset
const _EK_Y_SPAN := 2048              # 2^11 y field width

static func edit_key(fid: int, cell: Vector3i) -> int:
	return ((fid * _EK_XZ_SPAN + (cell.x + _EK_XZ_OFF)) * _EK_XZ_SPAN + (cell.z + _EK_XZ_OFF)) * _EK_Y_SPAN + (cell.y + _EK_Y_OFF)

## Inverse of edit_key: returns [fid: int, cell: Vector3i]. Total bijection over the documented ranges.
static func edit_key_unpack(key: int) -> Array:
	var y := (key % _EK_Y_SPAN) - _EK_Y_OFF
	var rest := key / _EK_Y_SPAN
	var z := (rest % _EK_XZ_SPAN) - _EK_XZ_OFF
	rest /= _EK_XZ_SPAN
	var x := (rest % _EK_XZ_SPAN) - _EK_XZ_OFF
	var fid := rest / _EK_XZ_SPAN
	return [fid, Vector3i(x, y, z)]

## The facet-id half of a key WITHOUT allocating the Vector3i (hot-path filter for index rebuilds).
static func edit_key_fid(key: int) -> int:
	return key / (_EK_Y_SPAN * _EK_XZ_SPAN * _EK_XZ_SPAN)

## Build the whole atlas once (main thread). Call AFTER TerrainConfig.warm_up (spawn pick reads worldgen).
static func warm_up() -> void:
	if _ready:
		return
	# O4b: each built body's facets are appended contiguously at its fid_base, built with ITS OWN k/r
	# (threaded through _corner/_build_facet/_build_seam — the O4a const-K/R build math would have
	# produced Earth-shaped geometry at Moon fids). For Earth (slot 0, base 0, k == K, r == R_BLOCKS)
	# `base + (face·k+a)·k+b` is TEXTUALLY the shipped `(face·K+a)·K+b` and every threaded value equals
	# the const it replaced, so Earth still builds byte-identically — G-O4-EQ pins exactly that.
	_freeze_registry()
	# COSMOS ORBITAL O4b — THE DUAL-K FOLD WARM (§3.1 fact 2 / risk #3, "the project's worst race
	# class"). _build_seam folds each body's facet grid at that body's k (CubeSphere.fold_cell(…, k)),
	# and facet_of_dir classifies at k too. An unwarmed k falls through fold_cell's frozen fast path
	# into the LAZY `_ensure_edge_table` Dictionary build — which, first-touched by a voxel worker
	# while the main thread folds, is the corruption class the frozen-epoch contract exists to kill.
	# So warm EVERY built body's k HERE: main thread, before the seam loop below (the first folder),
	# and long before any worker exists (warm_up runs in module setup, before the generator attaches).
	# warm_edge_tables is append-only per n, so K=24 and K=14 COEXIST — neither evicts the other.
	for slot in range(body_count()):
		CubeSphere.warm_edge_tables(k_of_slot(slot))
	_nf = facet_count()
	_frame.resize(_nf * 12)
	_off.resize(_nf * 2)
	_poly.resize(_nf * 8)
	_dom.resize(_nf * 4)
	for slot in range(body_count()):
		var base := _slot_base[slot]
		var k := k_of_slot(slot)
		var r := r_of_slot(slot)
		for face in range(6):
			for a in range(k):
				for b in range(k):
					_build_facet(base + (face * k + a) * k + b, face, a, b, k, r)
	# seams need every facet's frame built first (each seam reads BOTH facets' planes)
	_seam_plane.resize(_nf * 16)
	_seam_neigh.resize(_nf * 4)
	_seam_ring.resize(_nf * 24)
	_seam_mhat.resize(_nf * 12)
	for slot in range(body_count()):
		var base := _slot_base[slot]
		var k := k_of_slot(slot)
		var r := r_of_slot(slot)
		for face in range(6):
			for a in range(k):
				for b in range(k):
					var fid := base + (face * k + a) * k + b
					for seam_slot in range(4):
						_build_seam(fid, face, a, b, seam_slot, base, k, r)
	_spawn_fid = _pick_spawn_facet()
	# Risk #3, asserted rather than trusted: EVERY built body's fold table is frozen before warm_up
	# returns (i.e. before setup returns, before any worker). A miss here is a latent worker race, so
	# it is a hard failure, not a warning.
	for slot in range(body_count()):
		assert(CubeSphere.edge_tables_warm(k_of_slot(slot)),
			"FacetAtlas.warm_up: fold/edge table NOT warmed for body slot %d (k=%d) — worker race (risk #3)" % [slot, k_of_slot(slot)])
	_ready = true

static func is_ready() -> bool:
	return _ready

# ------- construction (f64) -------

## O4b: `k`/`r` are the OWNING BODY's faceting resolution / radius (threaded from warm_up's per-body
## loop), not the Earth consts. Called with (K, R_BLOCKS) for Earth ⇒ byte-identical to the shipped form.
static func _corner(face: int, i: int, j: int, k: int, r: float) -> Array:
	var d := CosmosFacet.vertex_dir(face, i, j, k)   # f64 DVec3 unit
	return [d.x * r, d.y * r, d.z * r]

static func _cross(a: Array, b: Array) -> Array:
	return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]

static func _norm(a: Array) -> Array:
	var l: float = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
	if l == 0.0:
		return [0.0, 0.0, 0.0]
	return [a[0] / l, a[1] / l, a[2] / l]

static func _build_facet(fid: int, face: int, a: int, b: int, k: int, r: float) -> void:
	var c: Array = [_corner(face, a, b, k, r), _corner(face, a + 1, b, k, r), _corner(face, a + 1, b + 1, k, r), _corner(face, a, b + 1, k, r)]
	var mx: float = (c[0][0] + c[1][0] + c[2][0] + c[3][0]) / 4.0
	var my: float = (c[0][1] + c[1][1] + c[2][1] + c[3][1]) / 4.0
	var mz: float = (c[0][2] + c[1][2] + c[2][2] + c[3][2]) / 4.0
	# mean-plane normal = normalize((c2−c0) × (c3−c1)), oriented OUTWARD (radial side)
	var d1: Array = [c[2][0] - c[0][0], c[2][1] - c[0][1], c[2][2] - c[0][2]]
	var d2: Array = [c[3][0] - c[1][0], c[3][1] - c[1][1], c[3][2] - c[1][2]]
	var n: Array = _norm(_cross(d1, d2))
	if n[0] * mx + n[1] * my + n[2] * mz < 0.0:
		n = [-n[0], -n[1], -n[2]]
	# project corners onto the mean plane
	var cp: Array = []
	for i in range(4):
		var s: float = (c[i][0] - mx) * n[0] + (c[i][1] - my) * n[1] + (c[i][2] - mz) * n[2]
		cp.append([c[i][0] - s * n[0], c[i][1] - s * n[1], c[i][2] - s * n[2]])
	var eu: Array = _norm([cp[1][0] - cp[0][0], cp[1][1] - cp[0][1], cp[1][2] - cp[0][2]])
	var ew: Array = _cross(eu, n)          # ê_u × n̂ — FORCED right-handed (X×Y=Z), never from the c3 edge
	var ox := int(floor(TerrainConfig._hash01_3d(fid, 11, 0, 751) * 65536.0)) - 32768
	var oz := int(floor(TerrainConfig._hash01_3d(fid, 23, 0, 757) * 65536.0)) - 32768
	var f := fid * 12
	_frame[f + 0] = cp[0][0]; _frame[f + 1] = cp[0][1]; _frame[f + 2] = cp[0][2]
	_frame[f + 3] = eu[0]; _frame[f + 4] = eu[1]; _frame[f + 5] = eu[2]
	_frame[f + 6] = n[0]; _frame[f + 7] = n[1]; _frame[f + 8] = n[2]
	_frame[f + 9] = ew[0]; _frame[f + 10] = ew[1]; _frame[f + 11] = ew[2]
	_off[fid * 2] = ox; _off[fid * 2 + 1] = oz
	var minx := 1.0e18; var minz := 1.0e18; var maxx := -1.0e18; var maxz := -1.0e18
	for i in range(4):
		var dvx: float = cp[i][0] - cp[0][0]
		var dvy: float = cp[i][1] - cp[0][1]
		var dvz: float = cp[i][2] - cp[0][2]
		var qx: float = dvx * eu[0] + dvy * eu[1] + dvz * eu[2]
		var qy: float = dvx * ew[0] + dvy * ew[1] + dvz * ew[2]
		_poly[fid * 8 + i * 2] = qx; _poly[fid * 8 + i * 2 + 1] = qy
		minx = minf(minx, qx); minz = minf(minz, qy); maxx = maxf(maxx, qx); maxz = maxf(maxz, qy)
	_dom[fid * 4 + 0] = ox + int(floor(minx)) - MARGIN_CELLS
	_dom[fid * 4 + 1] = oz + int(floor(minz)) - MARGIN_CELLS
	_dom[fid * 4 + 2] = ox + int(ceil(maxx)) + MARGIN_CELLS
	_dom[fid * 4 + 3] = oz + int(ceil(maxz)) + MARGIN_CELLS

# ------- seams (§2.5, f64) -------

# The raw neighbour facet grid index (a±1 / b±1; may be out of [0,K) → fold_cell resolves it cross-face).
static func _neigh_ab(a: int, b: int, slot: int) -> Vector2i:
	match slot:
		S_EAST: return Vector2i(a + 1, b)
		S_WEST: return Vector2i(a - 1, b)
		S_NORTH: return Vector2i(a, b + 1)
		_: return Vector2i(a, b - 1)

# The two shared true-corner VERTEX (i,j) indices of this slot's grid edge, in THIS facet's face indexing.
static func _seam_edge_ij(a: int, b: int, slot: int) -> Array:
	match slot:
		S_EAST: return [a + 1, b, a + 1, b + 1]
		S_WEST: return [a, b, a, b + 1]
		S_NORTH: return [a, b + 1, a + 1, b + 1]
		_: return [a, b, a + 1, b]     # S_SOUTH

static func _proj_plane(p: Array, c0: Array, n: Array) -> Array:
	var s: float = (p[0] - c0[0]) * n[0] + (p[1] - c0[1]) * n[1] + (p[2] - c0[2]) * n[2]
	return [p[0] - s * n[0], p[1] - s * n[1], p[2] - s * n[2]]

static func _facet_world_centroid(fid: int) -> Array:
	var f := fid * 12
	var p := fid * 8
	var qcx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var qcy: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	return [_frame[f + 0] + qcx * _frame[f + 3] + qcy * _frame[f + 9],
		_frame[f + 1] + qcx * _frame[f + 4] + qcy * _frame[f + 10],
		_frame[f + 2] + qcx * _frame[f + 5] + qcy * _frame[f + 11]]

## O4b: `base`/`k`/`r` are the OWNING BODY's fid_base / faceting resolution / radius. Seams NEVER cross
## bodies (§3.1 fact 3): the fold runs within this body's own 6·k² face grid and the neighbour fid is
## re-based to `base`, so each body's facet graph is closed and every neighbour fid stays in-range by
## construction. Earth passes (0, K, R_BLOCKS) ⇒ textually the shipped math.
static func _build_seam(fid: int, face: int, a: int, b: int, slot: int, base: int, k: int, r: float) -> void:
	var fA := fid * 12
	var c0A: Array = [_frame[fA + 0], _frame[fA + 1], _frame[fA + 2]]
	var euA: Array = [_frame[fA + 3], _frame[fA + 4], _frame[fA + 5]]
	var nA: Array = [_frame[fA + 6], _frame[fA + 7], _frame[fA + 8]]
	var ewA: Array = [_frame[fA + 9], _frame[fA + 10], _frame[fA + 11]]
	# neighbour facet via fold_cell at THIS BODY's grid resolution k (single-edge fold — a facet is
	# never double-out). The table for k is frozen by warm_up's dual-K warm above (risk #3).
	var nb := _neigh_ab(a, b, slot)
	var fold: Dictionary = CubeSphere.fold_cell(face, nb.x, nb.y, k)
	var fidB := base + (int(fold["face"]) * k + int(fold["i"])) * k + int(fold["j"])
	var fB := fidB * 12
	var c0B: Array = [_frame[fB + 0], _frame[fB + 1], _frame[fB + 2]]
	var nB: Array = [_frame[fB + 6], _frame[fB + 7], _frame[fB + 8]]
	# shared true edge endpoints (·R, un-planarized), projected onto BOTH facet planes and averaged = welded ring
	var ev := _seam_edge_ij(a, b, slot)
	var e0 := _corner(face, ev[0], ev[1], k, r)
	var e1 := _corner(face, ev[2], ev[3], k, r)
	var pA0 := _proj_plane(e0, c0A, nA); var pB0 := _proj_plane(e0, c0B, nB)
	var pA1 := _proj_plane(e1, c0A, nA); var pB1 := _proj_plane(e1, c0B, nB)
	var r0: Array = [(pA0[0] + pB0[0]) / 2.0, (pA0[1] + pB0[1]) / 2.0, (pA0[2] + pB0[2]) / 2.0]
	var r1: Array = [(pA1[0] + pB1[0]) / 2.0, (pA1[1] + pB1[1]) / 2.0, (pA1[2] + pB1[2]) / 2.0]
	# ridge (bisector) plane: normal m̂ = normalize(t̂ × ĥ), oriented toward THIS facet's centroid
	var that := _norm([r1[0] - r0[0], r1[1] - r0[1], r1[2] - r0[2]])
	var hhat := _norm([nA[0] + nB[0], nA[1] + nB[1], nA[2] + nB[2]])
	var mhat := _norm(_cross(that, hhat))
	var mc := _facet_world_centroid(fid)
	if mhat[0] * (mc[0] - r0[0]) + mhat[1] * (mc[1] - r0[1]) + mhat[2] * (mc[2] - r0[2]) < 0.0:
		mhat = [-mhat[0], -mhat[1], -mhat[2]]
	# express own-side half-space in THIS facet's lattice frame: own(x,y,z) = A·x + B·y + C·z + D ≥ 0
	var A: float = mhat[0] * euA[0] + mhat[1] * euA[1] + mhat[2] * euA[2]
	var Bc: float = mhat[0] * nA[0] + mhat[1] * nA[1] + mhat[2] * nA[2]
	var C: float = mhat[0] * ewA[0] + mhat[1] * ewA[1] + mhat[2] * ewA[2]
	var ox := float(_off[fid * 2]); var oz := float(_off[fid * 2 + 1])
	var D: float = (mhat[0] * (c0A[0] - r0[0]) + mhat[1] * (c0A[1] - r0[1]) + mhat[2] * (c0A[2] - r0[2])) - A * ox - C * oz
	var sp := fid * 16 + slot * 4
	_seam_plane[sp + 0] = A; _seam_plane[sp + 1] = Bc; _seam_plane[sp + 2] = C; _seam_plane[sp + 3] = D
	_seam_neigh[fid * 4 + slot] = fidB
	var sr := fid * 24 + slot * 6
	_seam_ring[sr + 0] = r0[0]; _seam_ring[sr + 1] = r0[1]; _seam_ring[sr + 2] = r0[2]
	_seam_ring[sr + 3] = r1[0]; _seam_ring[sr + 4] = r1[1]; _seam_ring[sr + 5] = r1[2]
	var sm := fid * 12 + slot * 3
	_seam_mhat[sm + 0] = mhat[0]; _seam_mhat[sm + 1] = mhat[1]; _seam_mhat[sm + 2] = mhat[2]

# ------- runtime (f64; the ONE map both sampling and placement use) -------

## Facet cell (x,z) → its true sphere direction (f64). Column d̂ at the plane point y=0 (§3.2): a facet column
## is straight along n̂ so all its cells share one d̂. Sampling shares this map with placement → they can't disagree.
static func cell_dir(fid: int, x: int, z: int) -> CubeSphere.DVec3:
	var f := fid * 12
	var fx := float(x) - float(_off[fid * 2]) + 0.5
	var fz := float(z) - float(_off[fid * 2 + 1]) + 0.5
	return CubeSphere.DVec3.new(
		_frame[f + 0] + fx * _frame[f + 3] + fz * _frame[f + 9],
		_frame[f + 1] + fx * _frame[f + 4] + fz * _frame[f + 10],
		_frame[f + 2] + fx * _frame[f + 5] + fz * _frame[f + 11]).normalized()

## f64 lattice→world: world point of lattice coords (x,y,z) via W_fid (§2.2). Returns [wx,wy,wz] (f64 scalars —
## never routed through f32 Vector3). The exact placement map; its inverse is world_to_lattice64.
static func lattice_to_world64(fid: int, x: float, y: float, z: float) -> Array:
	var f := fid * 12
	var fx := x - float(_off[fid * 2])
	var fz := z - float(_off[fid * 2 + 1])
	return [_frame[f + 0] + fx * _frame[f + 3] + y * _frame[f + 6] + fz * _frame[f + 9],
		_frame[f + 1] + fx * _frame[f + 4] + y * _frame[f + 7] + fz * _frame[f + 10],
		_frame[f + 2] + fx * _frame[f + 5] + y * _frame[f + 8] + fz * _frame[f + 11]]

## f64 world→lattice: inverse of W_fid (orthonormal basis ⇒ transpose). Returns [x,y,z].
static func world_to_lattice64(fid: int, wx: float, wy: float, wz: float) -> Array:
	var f := fid * 12
	var dx := wx - _frame[f + 0]; var dy := wy - _frame[f + 1]; var dz := wz - _frame[f + 2]
	return [dx * _frame[f + 3] + dy * _frame[f + 4] + dz * _frame[f + 5] + float(_off[fid * 2]),
		dx * _frame[f + 6] + dy * _frame[f + 7] + dz * _frame[f + 8],
		dx * _frame[f + 9] + dy * _frame[f + 10] + dz * _frame[f + 11] + float(_off[fid * 2 + 1])]

## The world position of facet `fid`'s planarized corner `ci` (0..3, CCW) — c0' + q_ci·(ê_u, ê_w). f64 [x,y,z].
## The SAME planar frames the near voxel world uses, so the far ring meets the near facet cleanly at ridges.
static func facet_planar_corner(fid: int, ci: int) -> Array:
	var f := fid * 12
	var p := fid * 8
	var qx := _poly[p + ci * 2]; var qz := _poly[p + ci * 2 + 1]
	return [_frame[f + 0] + qx * _frame[f + 3] + qz * _frame[f + 9],
		_frame[f + 1] + qx * _frame[f + 4] + qz * _frame[f + 10],
		_frame[f + 2] + qx * _frame[f + 5] + qz * _frame[f + 11]]

# ------- FP3 crossing reframe (§6.1) -------

## f64 EXACT reframe of a lattice point from facet `from_fid`'s frame into facet `to_fid`'s frame — the same
## physical planet point, re-expressed. = world_to_lattice64(to, lattice_to_world64(from, p)). Position-critical
## (the player's new coords), so it stays in f64; Δ_AB·Δ_BA = identity to f64. The velocity/look basis uses
## crossing_basis (rotation only, f32-safe).
static func reframe_position64(from_fid: int, to_fid: int, x: float, y: float, z: float) -> Array:
	var w := lattice_to_world64(from_fid, x, y, z)
	return world_to_lattice64(to_fid, w[0], w[1], w[2])

## The rotation taking a DIRECTION from facet `from_fid`'s lattice frame into `to_fid`'s (orthonormal → the
## dihedral turn). Used for the player velocity/look and debris angular velocity re-frame at a crossing.
static func crossing_basis(from_fid: int, to_fid: int) -> Basis:
	return frame_basis(to_fid).transposed() * frame_basis(from_fid)

## The full rigid crossing transform Δ = T_to⁻¹·T_from (from-lattice → to-lattice), as a Transform3D. Used to
## re-place static nodes (debris) at a crossing; the far ring instead re-sets its node to T_active⁻¹ (§5.2).
static func crossing_transform(from_fid: int, to_fid: int) -> Transform3D:
	return facet_transform(to_fid).affine_inverse() * facet_transform(from_fid)

## Facet `fid`'s outward normal n̂ in world coords (f64 [x,y,z]) — for back-face culling the far ring.
static func facet_normal64(fid: int) -> Array:
	var f := fid * 12
	return [_frame[f + 6], _frame[f + 7], _frame[f + 8]]

## The rigid placement Transform3D (FP2+ node placement; FP1 renders in the local frame and never needs it).
static func facet_transform(fid: int) -> Transform3D:
	var f := fid * 12
	var eu := Vector3(_frame[f + 3], _frame[f + 4], _frame[f + 5])
	var ny := Vector3(_frame[f + 6], _frame[f + 7], _frame[f + 8])
	var ew := Vector3(_frame[f + 9], _frame[f + 10], _frame[f + 11])
	var c0 := Vector3(_frame[f + 0], _frame[f + 1], _frame[f + 2])
	var ox := float(_off[fid * 2]); var oz := float(_off[fid * 2 + 1])
	return Transform3D(Basis(eu, ny, ew), c0 - ox * eu - oz * ew)

## True iff facet cell (x,z) is inside the facet polygon dilated by `grow` cells (convex quad, 4 half-planes).
## `grow` is OUTWARD dilation: grow=0 is the exact polygon, grow>0 admits points up to `grow` cells OUTSIDE an
## edge (FP2 ring overlap), grow<0 requires points at least |grow| cells INSIDE (spawn margin). Winding-robust:
## the polygon centroid fixes the interior sign, so it works regardless of the (eu, ew) handedness (which is
## CW because ê_w = ê_u × n̂ ⇒ ê_u × ê_w = −n̂ — a left-handed 2D frame viewed from outside).
static func in_polygon(fid: int, x: int, z: int, grow: float) -> bool:
	var px := float(x) - float(_off[fid * 2]) + 0.5
	var pz := float(z) - float(_off[fid * 2 + 1]) + 0.5
	var p := fid * 8
	var cx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var cz: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	for e in range(4):
		var ax := _poly[p + e * 2]; var ay := _poly[p + e * 2 + 1]
		var bx := _poly[p + ((e + 1) % 4) * 2]; var by := _poly[p + ((e + 1) % 4) * 2 + 1]
		var ex := bx - ax; var ey := by - ay
		var elen: float = sqrt(ex * ex + ey * ey)
		if elen == 0.0:
			continue
		var cp: float = ex * (pz - ay) - ey * (px - ax)     # 2× signed area of (a,b,p): sign = which side
		var cc: float = ex * (cz - ay) - ey * (cx - ax)     # centroid is interior → its sign IS the interior side
		var inward: float = (cp if cc >= 0.0 else -cp) / elen   # distance from the edge INTO the interior
		if inward < -grow:
			return false
	return true

# ------- seams & junction clip (§2.5, §3.5 — runtime, all f64) -------

const SEAM_EPS := 1.0e-6

## The neighbour facet across `slot` (E/W/N/S) — the fid that shares this ridge.
static func seam_neighbour(fid: int, slot: int) -> int:
	return _seam_neigh[fid * 4 + slot]
## This facet's own-side ridge plane in its LATTICE frame: own(x,y,z)=A·x+B·y+C·z+D ≥ 0 is interior.
static func seam_plane(fid: int, slot: int) -> Vector4:
	var b := fid * 16 + slot * 4
	return Vector4(_seam_plane[b], _seam_plane[b + 1], _seam_plane[b + 2], _seam_plane[b + 3])
## The welded ring endpoints (world coords) — r0, r1.
static func seam_ring(fid: int, slot: int) -> Array:
	var b := fid * 24 + slot * 6
	return [Vector3(_seam_ring[b + 0], _seam_ring[b + 1], _seam_ring[b + 2]),
		Vector3(_seam_ring[b + 3], _seam_ring[b + 4], _seam_ring[b + 5])]
## The world ridge normal m̂ (points toward THIS facet's interior).
static func seam_mhat(fid: int, slot: int) -> Vector3:
	var b := fid * 12 + slot * 3
	return Vector3(_seam_mhat[b + 0], _seam_mhat[b + 1], _seam_mhat[b + 2])

## Signed own-side distance of the LATTICE POINT (x,y,z) to this facet's ridge plane `slot` (≥0 interior).
static func own_dist(fid: int, slot: int, x: float, y: float, z: float) -> float:
	var b := fid * 16 + slot * 4
	return _seam_plane[b] * x + _seam_plane[b + 1] * y + _seam_plane[b + 2] * z + _seam_plane[b + 3]

## COSMOS FP-CARVE — the 4 own-side ridge planes of `fid` as a raw f64 16-slice: slot 0..3 × (A,B,C,D),
## LATTICE coords (own(x,y,z) = A·x + B·y + C·z + D ≥ 0 interior). The f64 accessor the carve mesher blob
## needs — seam_plane() returns a Vector4 (f32) that loses ~2e-4 at |lattice| ~ 3e4 (the decorrelation
## offset O ∈ [−32768, 32768] pushes |D| ~ 3e4). Pure/frozen atlas data → worker-safe.
static func seam_planes_f64(fid: int) -> PackedFloat64Array:
	return _seam_plane.slice(fid * 16, fid * 16 + 16)

## Classify the unit CELL (integer x,y,z) against this facet's 4 ridge planes (§3.5.1). Returns
## {"air": bool, "straddle": PackedInt32Array of slots}. air ⇒ the cube lies wholly beyond some ridge (the FP2
## domain mask); empty straddle & not air ⇒ interior full cell; non-empty straddle ⇒ a junction cell clipped by
## those seams. Exact min/max over the 8 cube corners (the plane is affine, extrema are at corners).
static func cell_seam_state(fid: int, x: int, y: int, z: int) -> Dictionary:
	var straddle := PackedInt32Array()
	for slot in range(4):
		var b := fid * 16 + slot * 4
		var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]
		var base := A * float(x) + B * float(y) + C * float(z) + _seam_plane[b + 3]
		var lo := base + minf(0.0, A) + minf(0.0, B) + minf(0.0, C)
		var hi := base + maxf(0.0, A) + maxf(0.0, B) + maxf(0.0, C)
		if hi <= SEAM_EPS:
			return {"air": true, "straddle": PackedInt32Array()}   # wholly beyond this ridge → masked
		if lo < -SEAM_EPS:
			straddle.append(slot)
	return {"air": false, "straddle": straddle}

## The clipped unit-cube vertex cloud (LOCAL cell coords u∈[0,1]³) for a junction cell = cube ∩ (own-side of
## every straddling ridge). A convex point set (ConvexPolygonShape3D hulls it; the mesher builds faces from the
## same clip). Empty if masked; the 8 corners if interior. Shared by render AND collision → identical geometry.
static func junction_prism_verts(fid: int, x: int, y: int, z: int) -> PackedVector3Array:
	var st := cell_seam_state(fid, x, y, z)
	if st["air"]:
		return PackedVector3Array()
	var slots: PackedInt32Array = st["straddle"]
	if slots.is_empty():
		var full := PackedVector3Array()
		for i in range(8):
			full.append(_cube_corner(i))
		return full
	# local planes: own_local(u) = A·ux + B·uy + C·uz + base ≥ 0, base = own_dist at the cell-origin corner
	var planes: Array = []
	for slot in slots:
		var b := fid * 16 + slot * 4
		var base := _seam_plane[b] * float(x) + _seam_plane[b + 1] * float(y) + _seam_plane[b + 2] * float(z) + _seam_plane[b + 3]
		planes.append([_seam_plane[b], _seam_plane[b + 1], _seam_plane[b + 2], base])
	return _clip_cube_points(planes)

static func _cube_corner(i: int) -> Vector3:
	return Vector3(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1))

static func _own_local(pl: Array, u: Vector3) -> float:
	return pl[0] * u.x + pl[1] * u.y + pl[2] * u.z + pl[3]

static func _inside_all(planes: Array, u: Vector3, eps: float) -> bool:
	for pl in planes:
		if _own_local(pl, u) < -eps:
			return false
	return true

# The 12 edges of the unit cube as corner-index pairs (indices differ in exactly one bit).
const _CUBE_EDGES := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3], [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]

# Vertices of the cube clipped to the intersection of the given half-spaces (own_local ≥ 0). Generous point
# collection — kept corners, edge∩plane crossings, and (for corner cells) face∩plane∩plane triple points — then
# filtered to the region; a convex hull downstream tidies duplicates. Exact for 1 plane, correct for ≤3.
static func _clip_cube_points(planes: Array) -> PackedVector3Array:
	var eps := 1.0e-6
	var pts := PackedVector3Array()
	for i in range(8):
		var u := _cube_corner(i)
		if _inside_all(planes, u, eps):
			pts.append(u)
	for e in _CUBE_EDGES:
		var u0 := _cube_corner(e[0]); var u1 := _cube_corner(e[1])
		for pl in planes:
			var f0 := _own_local(pl, u0); var f1 := _own_local(pl, u1)
			if (f0 < -eps and f1 > eps) or (f0 > eps and f1 < -eps):
				var t := f0 / (f0 - f1)
				var u := u0.lerp(u1, t)
				if _inside_all(planes, u, eps * 100.0):
					pts.append(u)
	# corner cells: triple points face∩plane_i∩plane_j (a cube face fixes one axis; solve the 2×2 in the rest)
	if planes.size() >= 2:
		for i in range(planes.size()):
			for j in range(i + 1, planes.size()):
				_face_plane_plane_points(planes[i], planes[j], planes, pts, eps)
	return pts

# For each of the 6 axis-aligned cube faces, solve the point satisfying both planes on that face; keep it if it
# lies in the unit square and inside every half-space. Covers the vertex where two ridge planes meet (corner cells).
static func _face_plane_plane_points(p: Array, q: Array, planes: Array, pts: PackedVector3Array, eps: float) -> void:
	for axis in range(3):
		for fixed in [0.0, 1.0]:
			# axis coord = fixed; the two free axes (a1,a2) solve [p,q] linear system
			var a1 := (axis + 1) % 3
			var a2 := (axis + 2) % 3
			var pa: float = p[a1]; var pb: float = p[a2]; var pc: float = p[axis] * fixed + p[3]
			var qa: float = q[a1]; var qb: float = q[a2]; var qc: float = q[axis] * fixed + q[3]
			var det: float = pa * qb - pb * qa
			if absf(det) < 1e-12:
				continue
			var s1: float = (-pc * qb + qc * pb) / det
			var s2: float = (-pa * qc + qa * pc) / det
			if s1 < -eps or s1 > 1.0 + eps or s2 < -eps or s2 > 1.0 + eps:
				continue
			var u := Vector3.ZERO
			u[axis] = fixed; u[a1] = clampf(s1, 0.0, 1.0); u[a2] = clampf(s2, 0.0, 1.0)
			if _inside_all(planes, u, eps * 100.0):
				pts.append(u)

# ------- junction encoding authority (§3.5.4) -------

## Length of the ridge-plane gradient (A,B,C) for a seam — converts own_dist to a true perpendicular distance.
static func seam_grad_len(fid: int, slot: int) -> float:
	var b := fid * 16 + slot * 4
	return sqrt(_seam_plane[b] * _seam_plane[b] + _seam_plane[b + 1] * _seam_plane[b + 1] + _seam_plane[b + 2] * _seam_plane[b + 2])

## The QUANTIZED model plane [A,B,C,base] for a baked junction shape (fid, slot, q). Reconstructs the cut plane
## from the facet's EXACT per-seam orientation (A,B,C) + the offset q (cell-centre perpendicular distance =
## q/16 − 1). base is chosen so the plane sits ≥ the exact plane (outward) — the render reaches at least to P.
## NOTE: the geometry is genuinely per-facet — seam orientations vary up to ~53° across facets (the cube-sphere
## warp shears facets differently), so a single reference manifest does NOT work; per-facet bevels-on-crossing
## would need a per-facet re-bake, which godot_voxel makes all-or-nothing (~13s). Hence set_facet clears the
## manifest on a crossing (safe lip) rather than reuse it.
static func junction_model_plane(fid: int, slot: int, q: int) -> Array:
	var b := fid * 16 + slot * 4
	var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]
	var grad := sqrt(A * A + B * B + C * C)
	var dq := float(q) / 16.0 - 1.0
	var base := dq * grad - (A + B + C) / 2.0
	return [A, B, C, base]

## The quantized model's clipped unit-cube vertex cloud (LOCAL u∈[0,1]³) — the render geometry for (slot,q).
static func junction_model_verts(fid: int, slot: int, q: int) -> PackedVector3Array:
	return _clip_cube_points([junction_model_plane(fid, slot, q)])

## The outward-rounded cut offset q (0..31) for a junction cell — the cell-centre perpendicular distance to
## the ridge quantized to 1/16 block over [−1,+1), rounded UP so the rendered partial reaches at least to P.
static func junction_q_of(fid: int, slot: int, x: int, y: int, z: int) -> int:
	var dc := own_dist(fid, slot, float(x) + 0.5, float(y) + 0.5, float(z) + 0.5) / seam_grad_len(fid, slot)
	return clampi(int(ceil((dc + 1.0) * 16.0)), 0, 31)

## THE emission authority (§3.5.4) — the ONLY producer of junction cells, called at the two window exits
## (module worker buffer-write, WM.cell_value_at faceted path). Returns AIR for a cube wholly beyond a ridge
## (the FP2 domain mask), `v` unchanged for an interior cell, or `v`'s material carrying the kind-2 junction
## modifier for a straddling cell. The straddling seam encoded is the one whose cut is closest to the cell
## centre; corner cells (2 ridges) render single-plane (exact collision still uses junction_prism_verts) and
## are polished by FP5. Pure: a function of frozen atlas data only → worker-safe.
static func junction_modify(fid: int, cell: Vector3i, v: int) -> int:
	# Inlined + allocation-free (this runs on the voxel worker hot path — no Dictionary/Array per cell, so no
	# COW-refcount race and no GC churn). Reads only frozen atlas data → worker-safe.
	var fx := float(cell.x); var fy := float(cell.y); var fz := float(cell.z)
	var best_slot := -1
	var best_abs := 1.0e18
	for slot in range(4):
		var b := fid * 16 + slot * 4
		var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]
		var base := A * fx + B * fy + C * fz + _seam_plane[b + 3]
		var hi := base + maxf(0.0, A) + maxf(0.0, B) + maxf(0.0, C)
		if hi <= SEAM_EPS:
			return 0                                 # wholly beyond this ridge → AIR (the domain mask)
		var lo := base + minf(0.0, A) + minf(0.0, B) + minf(0.0, C)
		if lo < -SEAM_EPS:                            # straddles this ridge → a junction cell
			var grad := sqrt(A * A + B * B + C * C)
			var dc := absf(A * (fx + 0.5) + B * (fy + 0.5) + C * (fz + 0.5) + _seam_plane[b + 3]) / grad
			if dc < best_abs:
				best_abs = dc; best_slot = slot
	if best_slot < 0:
		return v                                      # interior full cell — unchanged
	var q := junction_q_of(fid, best_slot, cell.x, cell.y, cell.z)
	return CellCodec.pack(CellCodec.mat(v), CellCodec.make_junction(best_slot, q), CellCodec.state(v), CellCodec.liquid_field(v))

# domain accessors (gates / FP2 streaming bounds)
static func dom_min(fid: int) -> Vector2i:
	return Vector2i(_dom[fid * 4 + 0], _dom[fid * 4 + 1])
static func dom_max(fid: int) -> Vector2i:
	return Vector2i(_dom[fid * 4 + 2], _dom[fid * 4 + 3])

## FP-S1(b) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §5(a)/§8) — BLOCK-level facet-domain early-out. Each facet's
## near box overlaps FOREIGN territory that junction_modify() masks to AIR one cell at a time; that still pays the
## full per-column profile pass first. This answers, in ~16 flops, "does the ENTIRE lattice block lie wholly beyond
## one of `fid`'s four ridge planes → would junction_modify mask EVERY cell in it to AIR?" — letting the generator
## skip the column work and leave the buffer default (air).
##
## The block spans cell-ORIGINS ox,ox+st,… (up to ox+(sx-1)*st) in x, likewise y/z; each cell footprint is the unit
## cube [wx,wx+1] — EXACTLY junction_modify's per-cell model. For a ridge (A,B,C,D), junction_modify masks a cell to
## AIR iff its `hi = A·wx+B·wy+C·wz+D + max(0,A)+max(0,B)+max(0,C) ≤ SEAM_EPS`. `hi` is affine and separable, so its
## MAXIMUM over every cell in the block is at the block corner that maximizes each term. If even that maximum ≤ EPS
## for ANY single ridge, every cell is beyond that ridge → the whole block is AIR. This is the exact per-cell test's
## supremum, so it NEVER reports true for a block holding any interior/straddle cell (conservative — err to generate;
## a block masked only by two ridges JOINTLY is not skipped, just not optimised). Pure/frozen atlas data → worker-safe.
static func block_all_air(fid: int, ox: int, oy: int, oz: int, sx: int, sy: int, sz: int, st: int) -> bool:
	if sx <= 0 or sy <= 0 or sz <= 0:
		return false
	var x0 := float(ox); var x1 := float(ox + (sx - 1) * st)
	var y0 := float(oy); var y1 := float(oy + (sy - 1) * st)
	var z0 := float(oz); var z1 := float(oz + (sz - 1) * st)
	for slot in range(4):
		var b := fid * 16 + slot * 4
		var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]; var D := _seam_plane[b + 3]
		# max over cell-origins of A·wx + B·wy + C·wz (affine → at the block corner picking the larger coord per +coef)
		var base_max := (A * x1 if A > 0.0 else A * x0) + (B * y1 if B > 0.0 else B * y0) + (C * z1 if C > 0.0 else C * z0) + D
		var hi_max := base_max + maxf(0.0, A) + maxf(0.0, B) + maxf(0.0, C)   # + the unit-cube extent (matches junction_modify's `hi`)
		if hi_max <= SEAM_EPS:
			return true
	return false

## COSMOS FP-M2 §7.2 — conservative megablock erosion for LOD ℓ>0. A coarse buffer cell samples the LOD0 lattice
## corner (wx,wy,wz) but RENDERS an s³ megablock spanning the footprint [wx,wx+s]³. It survives ONLY if that whole
## footprint is interior to all 4 ridge planes; anything straddling or beyond a ridge becomes AIR. For a plane
## own(x,y,z)=A·x+B·y+C·z+D the MINIMUM over [wx,wx+s]³ is at the corner minimizing each term, i.e.
##   lo = A·wx + B·wy + C·wz + D + s·(min(0,A)+min(0,B)+min(0,C))
## and the megablock is interior iff lo ≥ −SEAM_EPS for EVERY ridge. This REPLACES the per-cell junction_modify at
## ℓ>0 (no junction sentinels are emitted for megablocks — a single sampled LOD0 cell cannot cut an s³ block, §7.1);
## at ℓ==0 (s==1) the shipped junction_modify path runs verbatim, so LOD0 is byte-identical (G-M2-ID). The retreat
## is ≤ s blocks — covered on LOD↔LOD ridges by the ridge apron (M2b), never interpenetrating a live facet. Pure
## frozen-atlas arithmetic (the block_all_air family) → worker/builder-safe, facet-static.
static func cell_interior_scaled(fid: int, wx: int, wy: int, wz: int, s: int) -> bool:
	var fx := float(wx); var fy := float(wy); var fz := float(wz); var fs := float(s)
	for slot in range(4):
		var b := fid * 16 + slot * 4
		var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]; var D := _seam_plane[b + 3]
		var lo := A * fx + B * fy + C * fz + D + fs * (minf(0.0, A) + minf(0.0, B) + minf(0.0, C))
		if lo < -SEAM_EPS:
			return false
	return true

static func frame_basis(fid: int) -> Basis:
	var f := fid * 12
	return Basis(Vector3(_frame[f + 3], _frame[f + 4], _frame[f + 5]),
		Vector3(_frame[f + 6], _frame[f + 7], _frame[f + 8]),
		Vector3(_frame[f + 9], _frame[f + 10], _frame[f + 11]))

# ------- spawn (§3.3 item 5) -------

static func _facet_centre_cell(fid: int) -> Vector2i:
	var p := fid * 8
	var qx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var qy: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	return Vector2i(_off[fid * 2] + int(round(qx)), _off[fid * 2 + 1] + int(round(qy)))

static func _pick_spawn_facet() -> int:
	# O4a: spawn is Earth-only — restrict the scan to Earth's fid block (§3.1/§3.3). In O4a Earth is
	# base 0 with 3456 facets, so range(0, 3456) == the shipped range(_nf); the Moon is never scanned.
	var e_base := fid_base("earth")
	for fid in range(e_base, e_base + body_facet_count("earth")):
		var cc := _facet_centre_cell(fid)
		var d := cell_dir(fid, cc.x, cc.y)
		if absf(d.z) >= 0.5:                       # temperate latitude only (|sin φ| < 0.5)
			continue
		var prof := TerrainConfig.facet_profile(fid, cc.x, cc.y)
		var g := int(prof.x); var biome := int(prof.y)
		if g > TerrainConfig.SEA_LEVEL + 1 and (biome == TerrainConfig.B_PLAINS or biome == TerrainConfig.B_FOREST):
			return fid
	return 0

static func spawn_facet() -> int:
	return _spawn_fid

## The centre lattice cell of any facet (gates / FP2 window centring).
static func centre_cell(fid: int) -> Vector2i:
	return _facet_centre_cell(fid)

## The spawn column (facet-local lattice cell) for find_spawn — the spawn facet's window centre.
static func spawn_column() -> Vector2i:
	return _facet_centre_cell(_spawn_fid)

## COSMOS FP-M2c (docs/COSMOS-FP-M2-DESIGN.md §10, risk #6) — the off-surface active-facet-by-DIRECTION classifier:
## which facet does the radial direction `d` (planet centre → a point) land in? Pure f64 (CubeSphere.dir_to_face_cell
## at n=K) over the frozen cube-sphere tables, so the SSE selector stays pure viewer camera math and never assumes the
## viewer stands on the active facet. Round-trips EXACTLY with every facet's centre direction — G-M2-DIR asserts
## facet_of_dir(cell_dir(fid, centre_cell(fid))) == fid over all 6·K² facets. The fid layout mirrors warm_up's build
## order fid = (face·K + a)·K + b. The M2d pool policy uses this only defensively (freeze spawns for a high flyer
## above OFFSURFACE_Y — no ridge-skim thrash); full off-facet gravity/locomotion is FP-M3.
## O4a: `body` names which body's facet grid to classify into (the fid namespace is global). For Earth
## (k == K == 24, fid_base 0) this returns `(face·K+fi)·K+fj` — byte-identical to the shipped classifier.
static func facet_of_dir(body: String, d: CubeSphere.DVec3) -> int:
	var slot := body_slot(body)
	var k := k_of_slot(slot)
	var base := fid_base_slot(slot)
	var fc := CubeSphere.dir_to_face_cell(d, k)
	var face: int = int(fc["face"])
	var fi: int = clampi(int(fc["fi"]), 0, k - 1)
	var fj: int = clampi(int(fc["fj"]), 0, k - 1)
	return base + (face * k + fi) * k + fj

# ------- frame self-test (G-F1e, all f64 — never routes the frame through f32 Vector3) -------

## f64 frame-math metrics for facet `fid` (the FP1 gate G-F1e asserts thresholds on these). Recomputes the
## true (unprojected) corners, reads the stored frame, and returns: orthonormality residual, basis
## determinant, n̂·(centre radial), max original-corner plane deviation (blocks) + edge length, and the
## worst W_fid⁻¹∘W_fid round-trip error over a 3×3 cell sample. All arithmetic stays in f64.
static func verify_frame(fid: int) -> Dictionary:
	var f := fid * 12
	var c0: Array = [_frame[f + 0], _frame[f + 1], _frame[f + 2]]
	var eu: Array = [_frame[f + 3], _frame[f + 4], _frame[f + 5]]
	var n: Array = [_frame[f + 6], _frame[f + 7], _frame[f + 8]]
	var ew: Array = [_frame[f + 9], _frame[f + 10], _frame[f + 11]]
	# orthonormality residual: worst deviation of the Gram matrix from identity
	var ortho := 0.0
	for pair in [[eu, eu, 1.0], [n, n, 1.0], [ew, ew, 1.0], [eu, n, 0.0], [eu, ew, 0.0], [n, ew, 0.0]]:
		var a: Array = pair[0]; var b: Array = pair[1]
		ortho = maxf(ortho, absf(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] - pair[2]))
	# determinant of [eu | n | ew] = eu · (n × ew); +1 for a right-handed orthonormal basis
	var nxw: Array = _cross(n, ew)
	var det: float = eu[0] * nxw[0] + eu[1] * nxw[1] + eu[2] * nxw[2]
	# recompute the true (unprojected) corners + centroid → n̂ must point along the centre radial.
	# O4b: decompose the fid in the OWNING BODY's grid — subtract its fid_base, then divide by ITS k
	# (the const-K decomposition would mis-read every Moon fid). Earth (base 0, k == K) is verbatim.
	var slot := body_of_fid(fid)
	var lf := fid - fid_base_slot(slot)
	var k := k_of_slot(slot)
	var r := r_of_slot(slot)
	var face := int(lf / (k * k))
	var rem := lf - face * k * k
	var a := int(rem / k); var b := rem - a * k
	var tc: Array = [_corner(face, a, b, k, r), _corner(face, a + 1, b, k, r), _corner(face, a + 1, b + 1, k, r), _corner(face, a, b + 1, k, r)]
	var mx: float = (tc[0][0] + tc[1][0] + tc[2][0] + tc[3][0]) / 4.0
	var my: float = (tc[0][1] + tc[1][1] + tc[2][1] + tc[3][1]) / 4.0
	var mz: float = (tc[0][2] + tc[1][2] + tc[2][2] + tc[3][2]) / 4.0
	var ml: float = sqrt(mx * mx + my * my + mz * mz)
	var n_dot_centre: float = (n[0] * mx + n[1] * my + n[2] * mz) / ml
	# original corners' deviation from the stored mean plane (through c0 with normal n)
	var plane_dev := 0.0
	for i in range(4):
		var dev: float = (tc[i][0] - c0[0]) * n[0] + (tc[i][1] - c0[1]) * n[1] + (tc[i][2] - c0[2]) * n[2]
		# c0 is the PROJECTED corner 0; measure each true corner's signed distance to the plane, de-meaned
		plane_dev = maxf(plane_dev, absf(dev))
	var edge: float = sqrt(pow(tc[1][0] - tc[0][0], 2.0) + pow(tc[1][1] - tc[0][1], 2.0) + pow(tc[1][2] - tc[0][2], 2.0))
	# W_fid round-trip: place a sample cell, invert with the orthonormal basis, recover (x−O.x, y, z−O.z)
	var rt := 0.0
	for sx in [-1, 0, 1]:
		for sz in [-1, 0, 1]:
			var px: float = 100.0 + float(sx)
			var pz: float = 100.0 + float(sz)
			var yy: float = 7.0
			var wx: float = c0[0] + px * eu[0] + yy * n[0] + pz * ew[0]
			var wy: float = c0[1] + px * eu[1] + yy * n[1] + pz * ew[1]
			var wz: float = c0[2] + px * eu[2] + yy * n[2] + pz * ew[2]
			var rx: float = wx - c0[0]; var ry: float = wy - c0[1]; var rz: float = wz - c0[2]
			var iu: float = rx * eu[0] + ry * eu[1] + rz * eu[2]
			var iy: float = rx * n[0] + ry * n[1] + rz * n[2]
			var iw: float = rx * ew[0] + ry * ew[1] + rz * ew[2]
			rt = maxf(rt, maxf(absf(iu - px), maxf(absf(iy - yy), absf(iw - pz))))
	return {"ortho": ortho, "det": det, "n_dot_centre": n_dot_centre, "plane_dev": plane_dev, "edge": edge, "roundtrip": rt}
