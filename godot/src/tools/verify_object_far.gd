extends SceneTree
## COSMOS-OBJECT-LOD P1 gate (FP_OBJ_LOD_DEBRIS). Certifies the headless-testable parts of the far-object tier
## (ObjectRegistry + FacetFarObjects) against MOCK bodies: registry add/remove/iterate, rung→tier routing (DOT vs CARD
## by distance), the L0-hide RE-APPLY after a simulated _rebuild/rev bump (must-fix #1), budget eviction keeping the
## largest-projected objects, and frame-map (#131 fold) round-trip on a synthetic ring transform. No scene / GPU needed
## beyond the MultiMesh resources the tier writes. Run:
##   godot --headless --path godot --script res://src/tools/verify_object_far.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)

const K := 771.3   # k_px(1080, 70°) — the same reference the P0 gate asserts

# A duck-typed stand-in for a VoxelBody exposing exactly the interface the tier reads. `sim_rebuild` reproduces the
# must-fix #1 hazard: VoxelBody._rebuild recreates the MeshInstance visible=true and bumps the rev, WITHOUT re-applying
# the tier's hide — so the tier must re-hide on the rev change.
class MockBody extends RefCounted:
	var center := Vector3.ZERO
	var extent := 10.0
	var rev := 0
	var cls := ObjectLod.CLASS_DEBRIS
	var awake := false
	var visible := true          # simulates the render MeshInstance3D visibility
	var far_hidden := false
	func obj_world_center() -> Vector3: return center
	func obj_extent() -> float: return extent
	func obj_rev() -> int: return rev
	func obj_class() -> int: return cls
	func is_awake() -> bool: return awake
	func set_far_hidden(h: bool) -> void:
		far_hidden = h
		visible = not h
	func sim_rebuild() -> void:  # mesh re-created visible + rev bumped (tier owns the re-hide)
		visible = true
		rev += 1

func _mk_tier(budget := ObjectLod.OBJ_LOD_BYTES_MAX) -> Array:
	var reg := ObjectRegistry.new()
	var ring := Node3D.new()
	var tier := FacetFarObjects.new()
	tier.setup(ring, reg, budget)
	return [tier, reg, ring]

func _initialize() -> void:
	_test_registry()
	_test_routing()
	_test_hide_reapply()
	_test_budget_eviction()
	_test_frame_map()
	print("==== VERIFY-OBJECT-FAR: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_registry() -> void:
	var reg := ObjectRegistry.new()
	var a := MockBody.new()
	var b := MockBody.new()
	_ok(reg.register(a), "registry: register a is new")
	_ok(reg.register(b), "registry: register b is new")
	_ok(not reg.register(a), "registry: double-register a is a no-op")
	_ok(reg.size() == 2, "registry: size == 2")
	_ok(reg.has(a) and reg.has(b), "registry: has both")
	_ok(reg.ids().size() == 2, "registry: iterate yields 2 ids")
	# refresh pulls live fields off the node
	a.center = Vector3(1, 2, 3); a.extent = 20.0; a.rev = 7; a.awake = true
	var d := reg.refresh(a.get_instance_id())
	_ok(d["center"] == Vector3(1, 2, 3) and absf(float(d["radius"]) - 10.0) < 0.001 and int(d["rev"]) == 7 and bool(d["awake"]),
		"registry: refresh reads live center/radius/rev/awake")
	reg.unregister(a)
	_ok(reg.size() == 1 and not reg.has(a), "registry: unregister drops a")
	_ok(reg.refresh(a.get_instance_id()).is_empty(), "registry: refresh of a removed id is empty")

## Route ONE mock at camera distance `d` (fresh tier, no latch carryover) and return the result dict.
func _route_one(d: float, extent := 10.0) -> Dictionary:
	var t := _mk_tier()
	var tier: FacetFarObjects = t[0]
	var reg: ObjectRegistry = t[1]
	var m := MockBody.new()
	m.center = Vector3(0, 0, d)
	m.extent = extent
	reg.register(m)
	var res := tier.debug_route(Vector3.ZERO, K, Transform3D.IDENTITY)
	res["_mock"] = m   # keep a ref alive + expose for assertions
	res["_ring"] = t[2]
	return res

func _test_routing() -> void:
	# r=5 (extent 10). proj crosses: FULL near, CARD mid, DOT far (matching the P0 law, with hysteresis from FULL).
	var near := _route_one(1000.0)          # proj 7.71 → FULL (no far rep)
	var mid := _route_one(2500.0)           # proj 3.09 → CARD
	var far := _route_one(6000.0)           # proj 1.29 (< P_POINT·(1−HYST)=1.5) → DOT
	var idn: int = near["_mock"].get_instance_id()
	var idm: int = mid["_mock"].get_instance_id()
	var idf: int = far["_mock"].get_instance_id()
	_ok(near["cards"].is_empty() and near["dots"].is_empty() and not bool(near["hide"][idn]),
		"routing: d1000 → FULL (no card/dot, L0 shown)")
	_ok(mid["cards"].size() == 1 and mid["dots"].is_empty() and bool(mid["hide"][idm]),
		"routing: d2500 → CARD (1 card, L0 hidden)")
	_ok(far["dots"].size() == 1 and far["cards"].is_empty() and bool(far["hide"][idf]),
		"routing: d6000 → DOT (1 dot, L0 hidden)")
	# the drawn card's world-unit half-size equals the object radius (true angular size)
	_ok(absf(float(mid["cards"][0]["hs"]) - 5.0) < 0.001, "routing: card half-size == object radius r=5")

func _test_hide_reapply() -> void:
	# A far (CARD) object is hidden; a simulated _rebuild recreates its mesh visible + bumps rev; the NEXT tier step
	# must RE-APPLY the hide on the rev change (must-fix #1) — else a break_cell would un-hide the far body forever.
	var t := _mk_tier()
	var tier: FacetFarObjects = t[0]
	var reg: ObjectRegistry = t[1]
	var m := MockBody.new()
	m.center = Vector3(0, 0, 2500.0)         # CARD range → far → hidden
	reg.register(m)
	tier.debug_route(Vector3.ZERO, K, Transform3D.IDENTITY)
	_ok(m.far_hidden and not m.visible, "hide-reapply: far object hidden after first route")
	m.sim_rebuild()                          # mesh re-created visible=true, rev bumped, hide NOT re-applied by the body
	_ok(m.visible, "hide-reapply: sim _rebuild made the mesh visible again (the hazard)")
	tier.debug_route(Vector3.ZERO, K, Transform3D.IDENTITY)
	_ok(not m.visible and m.far_hidden, "hide-reapply: tier RE-APPLIED the hide on the rev change (must-fix #1)")
	t[2].free()

func _test_budget_eviction() -> void:
	# Three CARD objects (proj descending with distance). A 2-instance byte budget must keep the two LARGEST-proj and
	# evict the smallest (the closest survives, the farthest is dropped).
	var t := _mk_tier(2 * FacetFarObjects.STRIDE * 4)   # room for exactly 2 instances
	var tier: FacetFarObjects = t[0]
	var reg: ObjectRegistry = t[1]
	var m_near := MockBody.new(); m_near.center = Vector3(0, 0, 2000.0)   # proj 3.86 (largest)
	var m_mid := MockBody.new();  m_mid.center = Vector3(0, 0, 2500.0)    # proj 3.09
	var m_far := MockBody.new();  m_far.center = Vector3(0, 0, 3000.0)    # proj 2.57 (smallest → evicted)
	reg.register(m_near); reg.register(m_mid); reg.register(m_far)
	var res := tier.debug_route(Vector3.ZERO, K, Transform3D.IDENTITY)
	_ok(res["cards"].size() == 2, "budget: only 2 cards fit the 2-instance budget")
	_ok(int(res["evicted"]) == 1, "budget: exactly 1 object evicted")
	var kept_ids := {}
	for e in res["cards"]:
		kept_ids[int(e["id"])] = true
	_ok(kept_ids.has(m_near.get_instance_id()) and kept_ids.has(m_mid.get_instance_id()),
		"budget: the two LARGEST-proj objects survive")
	_ok(not kept_ids.has(m_far.get_instance_id()), "budget: the smallest-proj object is the one evicted")
	t[2].free()

func _test_frame_map() -> void:
	# #131 frame-weld: the tier writes each instance's origin in the ring's PARENT-LOCAL space (parent⁻¹·C) so it
	# renders at parent·(parent⁻¹·C) == C — the true world centre — for ANY ring rotation / scale / fold. Assert the
	# round-trip on the ACTUAL written origin, for a scaled+rotated parent AND a cube-face-fold-like 90° parent.
	var C := Vector3(2500.0, 0.0, 0.0)      # CARD range from the origin camera
	for parent: Transform3D in [
			Transform3D(Basis.from_euler(Vector3(0.3, 0.7, -0.2)).scaled(Vector3(1.7, 1.7, 1.7)), Vector3(1000, -500, 300)),
			Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)).scaled(Vector3(2.5, 2.5, 2.5)), Vector3(-800, 200, -60))]:
		var t := _mk_tier()
		var tier: FacetFarObjects = t[0]
		var reg: ObjectRegistry = t[1]
		var m := MockBody.new(); m.center = C
		reg.register(m)
		var res := tier.debug_route(Vector3.ZERO, K, parent)
		_ok(res["cards"].size() == 1, "frame-map: object produces one card")
		var origin: Vector3 = res["cards"][0]["origin"]
		var rendered: Vector3 = parent * origin   # where the child instance actually lands in world space
		_ok(rendered.distance_to(C) < 0.01, "frame-map: parent · written_origin == world centre (fold-correct)")
		t[2].free()
