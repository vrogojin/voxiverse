class_name ObjectRegistry
extends RefCounted
## COSMOS-OBJECT-LOD P1 (docs/COSMOS-OBJECT-LOD-DESIGN.md, FP_OBJ_LOD_DEBRIS) — the live-object index the far-render
## tier (FacetFarObjects) iterates each frame. GENERIC by design (decision 1): a VoxelBody is registered today, but a
## descriptor is a plain Dictionary {node, cls, extent, radius, rev, awake, center} so ships / stations / asteroids plug
## into the SAME add/remove/iterate API later without touching the tier. Keyed by `node.get_instance_id()` so add and
## remove are O(1) and a double-register / stale-remove is a no-op.
##
## NEVER-OOM: the index is hard-capped at CAP entries; past it, a register is DROPPED (logged once) — the world can hold
## unbounded debris over a long session, and an unbounded index would defeat the tier's own byte ceiling. The tier only
## ever draws min(CAP, budget) of them anyway (priority = projected size), so dropping the (CAP+1)-th smallest is safe.
##
## The `node` is expected to expose the VoxelBody-style duck interface the tier reads: `obj_world_center() -> Vector3`,
## `obj_extent() -> float`, `obj_rev() -> int`, `obj_class() -> int`, `is_awake() -> bool`, `set_far_hidden(bool)`. A
## mock supplying those certifies the registry + tier FLAT (verify_object_far.gd), no scene / GPU needed.

const CAP := 4096          # hard bound on tracked objects (never-OOM); DOT_CAP(4096) is the tier's own ceiling too

var _objs: Dictionary = {}     # instance_id:int -> descriptor Dictionary
var _warned := false           # CAP-exceeded log fired once

## Register `node` as class `cls` (ObjectLod.CLASS_*). Idempotent per node id. Extent/radius/rev/awake/center are read
## live from the node at refresh() time — the descriptor stored here is just the stable identity + class. Returns true
## iff newly added (false on a duplicate or when the cap is hit).
func register(node: Object, cls: int = ObjectLod.CLASS_DEBRIS) -> bool:
	if node == null:
		return false
	var id := node.get_instance_id()
	if _objs.has(id):
		return false
	if _objs.size() >= CAP:
		if not _warned:
			_warned = true
			print("  ObjectRegistry: CAP ", CAP, " reached — further objects not far-rendered (never-OOM)")
		return false
	_objs[id] = {
		"node": node, "cls": cls,
		"extent": 0.0, "radius": 0.0, "rev": -1, "awake": false, "center": Vector3.ZERO,
	}
	return true

## Unregister by node (or by raw instance id). No-op if absent.
func unregister(node: Object) -> void:
	if node == null:
		return
	_objs.erase(node.get_instance_id())

func unregister_id(id: int) -> void:
	_objs.erase(id)

func size() -> int:
	return _objs.size()

func has(node: Object) -> bool:
	return node != null and _objs.has(node.get_instance_id())

## The tracked instance ids (iteration order is Dictionary insertion order — stable within a session).
func ids() -> Array:
	return _objs.keys()

## Refresh one descriptor's live fields (center/extent/radius/rev/awake) from its node and return it. If the node has
## been freed (is_instance_valid false) the entry is dropped and {} returned. Called by the tier per object per frame.
func refresh(id: int) -> Dictionary:
	if not _objs.has(id):
		return {}
	var d: Dictionary = _objs[id]
	var node: Object = d["node"]
	if not is_instance_valid(node):
		_objs.erase(id)
		return {}
	var extent := float(node.obj_extent())
	d["extent"] = extent
	d["radius"] = extent * 0.5
	d["rev"] = int(node.obj_rev())
	d["awake"] = bool(node.is_awake())
	d["center"] = node.obj_world_center() as Vector3
	d["cls"] = int(node.obj_class())
	return d

## Drop every descriptor whose node was freed (bounded housekeeping the tier can call occasionally). Returns dropped n.
func prune() -> int:
	var dead: Array = []
	for id in _objs.keys():
		if not is_instance_valid(_objs[id]["node"]):
			dead.append(id)
	for id in dead:
		_objs.erase(id)
	return dead.size()

func clear() -> void:
	_objs.clear()
