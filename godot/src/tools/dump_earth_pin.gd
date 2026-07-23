extends SceneTree
## O4a byte-identity pin capture (COSMOS-ORBITAL-O1O4 §3.4). Run against the PRE-refactor tree to
## capture the canonical Earth atlas hash + worldgen sample hash, which verify_multibody.gd then pins
## and asserts UNCHANGED after the BodyAtlas namespace refactor (both MULTI_BODY states). f64 determinism
## on the pinned toolchain makes byte-hashing valid (same code path, same platform).
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

func _initialize() -> void:
	TC.warm_up()
	FA.warm_up()
	var earth_nf := 6 * FA.K * FA.K
	print("=== dump_earth_pin (K=%d R=%.1f earth_nf=%d spawn=%d) ===" % [FA.K, FA.R_BLOCKS, earth_nf, FA._spawn_fid])

	# 1) Atlas hash over Earth's fid range (all packed tables + spawn fid).
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FA._frame.slice(0, earth_nf * 12).to_byte_array())
	ctx.update(FA._off.slice(0, earth_nf * 2).to_byte_array())
	ctx.update(FA._poly.slice(0, earth_nf * 8).to_byte_array())
	ctx.update(FA._dom.slice(0, earth_nf * 4).to_byte_array())
	ctx.update(FA._seam_plane.slice(0, earth_nf * 16).to_byte_array())
	ctx.update(FA._seam_neigh.slice(0, earth_nf * 4).to_byte_array())
	ctx.update(FA._seam_ring.slice(0, earth_nf * 24).to_byte_array())
	ctx.update(FA._seam_mhat.slice(0, earth_nf * 12).to_byte_array())
	var spawn := PackedInt32Array([FA._spawn_fid]); ctx.update(spawn.to_byte_array())
	var atlas_hash := ctx.finish().hex_encode()
	print("ATLAS_HASH=%s" % atlas_hash)

	# 2) Worldgen sample hash: facet_profile over a deterministic (fid,x,z) set + a resolve_cell span.
	var wctx := HashingContext.new()
	wctx.start(HashingContext.HASH_MD5)
	var fids: Array[int] = [0, 37, 100, 500, 999, 1728, 2000, 3455]
	for fid in fids:
		var cc := FA.centre_cell(fid)
		for dx: int in [-40, -7, 0, 11, 33]:
			for dz: int in [-25, 0, 19]:
				var x := cc.x + dx
				var z := cc.y + dz
				var p: Vector4 = TC.facet_profile(fid, x, z)
				var pf := PackedFloat64Array([p.x, p.y, p.z, p.w])
				wctx.update(pf.to_byte_array())
				var g := int(p.x); var biome := int(p.y)
				var cells := PackedInt32Array()
				for y in range(g - 3, g + 3):
					cells.append(TC.resolve_cell(x, y, z, g, biome, p.z, p.w))
				wctx.update(cells.to_byte_array())
	var worldgen_hash := wctx.finish().hex_encode()
	print("WORLDGEN_HASH=%s" % worldgen_hash)
	print("=== done ===")
	quit(0)
