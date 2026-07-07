class_name ItemCatalog
extends RefCounted
## Non-block hotbar ITEMS (tools) live in the NEGATIVE id space — disjoint by
## construction from every present and future dense block id (BlockCatalog is a
## 0..count()-1 append-only table), so a tool can never collide with a block and
## needs no catalog/render-path coupling (PORTALS §3.2). This mirrors BlockCatalog's
## static facade shape (name/colour/stack) so the Inventory, HotbarHUD and Player can
## branch on `is_item(id)` and read an item's presentation from one place.

## The portal-linking tool. Arm one obsidian frame, then use it on a second to link
## them; use it on a linked frame to unlink (PortalManager.use_linker).
const PORTAL_LINKER := -1

## True iff `id` is an ITEM (tool), not a block. THE discriminator every caller uses
## (Inventory stack cap, HotbarHUD swatch branch, Player RMB routing).
static func is_item(id: int) -> bool:
	return id < 0

## Human-readable name for an item id (toast text / debugging).
static func name_of(id: int) -> String:
	match id:
		PORTAL_LINKER:
			return "portal linker"
	return "item %d" % id

## The hotbar swatch colour for an item id (no baked icon yet — a flat swatch; PORTALS
## §3.2.3 notes an icon can replace it later).
static func color_of(id: int) -> Color:
	match id:
		PORTAL_LINKER:
			return Color(0.55, 0.30, 0.95)      # violet, matching the portal energy fill
	return Color(0.8, 0.8, 0.8)

## Per-slot stack cap for an item id. Tools are unique — stack of 1.
static func max_stack_of(_id: int) -> int:
	return 1
