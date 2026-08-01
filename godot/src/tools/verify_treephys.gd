extends SceneTree
## G-TREEPHYS — FP_TREEPHYS_BOUND: a single block edit can NEVER tank the physics server.
## Run with the flag sed'd ON (like the other faceted/physics gates). Byte-OFF (flag false) is
## covered by verify_feature (FLAT 6042/0): every path below early-returns to the shipped
## per-cell / never-deadline behaviour when FP_TREEPHYS_BOUND is false.
##
## Root cause it pins down: WorldManager._structural_update groups the StructuralSolver's `falling`
## set into 6-connected components and spawns each as one VoxelBody; VoxelBody._rebuild builds ONE
## BoxShape3D collider PER CELL and stays fully dynamic until _grounded confirms. A several-hundred-
## cell detachment (a far tree-chop whose collapse detached a large component — observed live:
## objects ~152, phys_ms 300-420) therefore drops a rigid body carrying that many box colliders,
## which the physics server broadphases/integrates every frame; and if _grounded never confirms
## (far/faceted staleness) it never freezes → permanent ~5 fps.
##
## Four proofs:
##  (A) BOUND       — a LARGE component (> TREEPHYS_COLLIDER_CAP cells) collides as exactly ONE box
##                    (its cell AABB), not a per-cell field.
##  (B) UX PRESERVED— a SMALL component still emits one box PER cell and spawns DYNAMIC (real blocky
##                    debris falls exactly as today).
##  (C) FALSIFIER   — the un-fixed path emits cells.size() colliders (proven by B: colliders == cells
##                    for the small body); the large body escapes that (1 ≪ its cell count) AND spawns
##                    DORMANT (frozen STATIC) so it never churns the sim.
##  (D) DEADLINE    — a dynamic body that never reaches rest freezes to STATIC after
##                    TREEPHYS_MAX_ACTIVE_SEC regardless of _grounded (belt-and-suspenders), and does
##                    NOT freeze before the deadline.
## Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _collider_count(b: Node) -> int:
	var n := 0
	for ch in b.get_children():
		if ch is CollisionShape3D:
			n += 1
	return n

## Build a bare-id (plain full-cube) slab of `mat` spanning [0,w)×[0,h)×[0,d) → w*h*d cells.
func _slab(w: int, h: int, d: int, mat: int) -> Dictionary:
	var cells := {}
	for x in range(w):
		for y in range(h):
			for z in range(d):
				cells[Vector3i(x, y, z)] = mat
	return cells

func _initialize() -> void:
	print("=== verify_treephys (G-TREEPHYS: FP_TREEPHYS_BOUND) ===")
	print("  FP_TREEPHYS_BOUND=%s CAP=%d MAX_ACTIVE_SEC=%.1f"
		% [str(CubeSphere.FP_TREEPHYS_BOUND), CubeSphere.TREEPHYS_COLLIDER_CAP, CubeSphere.TREEPHYS_MAX_ACTIVE_SEC])
	if not CubeSphere.FP_TREEPHYS_BOUND:
		print("  SKIP: flag OFF (byte-off is covered by verify_feature FLAT 6042/0)")
		print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	var root := get_root()

	# --- (A) LARGE component → ONE AABB box, DORMANT (frozen) ------------------------------------
	# 10×2×10 = 200 cells (> CAP 64). Grass = a non-wood GROUND body (would be the tree-chop soil clod).
	var big_cells := _slab(10, 2, 10, BlockCatalog.GRASS)
	var big := VoxelBody.spawn_loose(root, big_cells, null)
	_ok(big != null and big.block_count() == 200, "A large body carries 200 cells (got %d)"
		% (big.block_count() if big != null else -1))
	var big_cc := _collider_count(big)
	_ok(big_cc == 1, "A large body collides as ONE box, not a per-cell field (colliders=%d, cells=200)" % big_cc)
	_ok(big.freeze, "A large body spawns DORMANT (freeze STATIC) — never churns the sim")
	# The single box must actually cover the cell AABB (x:0..10, y:0..2, z:0..10).
	var box_ok := false
	for ch in big.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape is BoxShape3D:
			var s: BoxShape3D = (ch as CollisionShape3D).shape
			box_ok = s.size.is_equal_approx(Vector3(10, 2, 10)) and ch.position.is_equal_approx(Vector3(5, 1, 5))
	_ok(box_ok, "A the single box covers the body's cell AABB (size 10×2×10 @ centre 5,1,5)")

	# --- (B) SMALL component → per-cell boxes, DYNAMIC (UX preserved) ----------------------------
	# 4×1×5 = 20 cells (≤ CAP): a canopy-sized clod must still fall as real blocky debris.
	var small_cells := _slab(4, 1, 5, BlockCatalog.GRASS)
	var small := VoxelBody.spawn_loose(root, small_cells, null)
	var small_cc := _collider_count(small)
	_ok(small.block_count() == 20 and small_cc == 20,
		"B small body keeps ONE box per cell (colliders=%d == cells=%d)" % [small_cc, small.block_count()])
	_ok(not small.freeze, "B small body spawns DYNAMIC (real blocky debris falls as today)")

	# --- (C) FALSIFIER: the reduction is real -------------------------------------------------
	# B proves the shipped rule is 1 collider/cell → the un-fixed large body would carry 200 colliders.
	# A shows the bounded large body carries 1. That 200 → 1 cut is the fix; and it spawns dormant.
	_ok(small_cc == small.block_count() and big_cc == 1 and big_cc < big.block_count(),
		"C un-fixed path = %d colliders (1/cell); bounded = %d (%dx fewer), and dormant"
			% [big.block_count(), big_cc, big.block_count() / maxi(1, big_cc)])

	# --- (D) HARD ACTIVE DEADLINE: a never-resting body freezes anyway --------------------------
	# A small (sub-cap) grass body spawns DYNAMIC. Drive _physics_process with a high, never-settling
	# velocity and world=null (so _grounded can never confirm — the live failure mode). It must NOT
	# freeze before the deadline, then MUST freeze at it, regardless of ground support.
	var dl := VoxelBody.spawn_loose(root, _slab(4, 1, 5, BlockCatalog.GRASS), null)
	dl.linear_velocity = Vector3(0, -40, 0)              # fast fall — normal settle can never freeze it
	var t := 0.0
	while t < CubeSphere.TREEPHYS_MAX_ACTIVE_SEC - 1.0:  # accrue to just under the deadline
		dl.linear_velocity = Vector3(0, -40, 0)
		dl._physics_process(0.1)
		t += 0.1
	_ok(not dl.freeze, "D a never-resting body is STILL dynamic just under the deadline (t=%.1fs)" % t)
	dl._physics_process(1.5)                            # cross the deadline
	_ok(dl.freeze, "D it freezes to STATIC at the deadline regardless of _grounded (world=null)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
