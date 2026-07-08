# PORTALS — See-Through Linked Portals (obsidian frames + linking tool)

Status: **locked design, ready to implement** (this doc is the implementation
contract for the `feat/voxiverse-portals` branch). Written against the code as of
`cdc5b71` (flat world + mountains/snow/sharp-slope/LOD; **not** COSMOS).

The feature: the player builds rectangular **obsidian frames**, links two frames
with a **portal-linking tool**, and each frame's interior becomes a **live
see-through portal** showing the world at the other frame from the correct
relative viewpoint (Portal / Minecraft Immersive-Portals style). Walk-through
teleport is designed here as an explicitly optional final stage.

---

## 1. Research summary and the chosen approach

### 1.1 The candidate techniques

**Valve Portal (2007): stencil masking + recursive re-render + oblique near-plane
clipping.** The destination view is re-rendered into the main framebuffer with the
stencil buffer masking the portal opening; the destination camera is the player
camera transformed by the portal pair's isometry; the near plane of the projection
is made *oblique* (Lengyel's clip-matrix trick) so it coincides with the
destination portal plane — otherwise geometry lying between the virtual camera and
the destination plane (the hillside the portal is built against, the back of the
frame wall) intrudes into the image. Recursion (portal seen through portal)
re-runs the pass with incremented stencil values.
*Feasibility here:* poor. Godot's high-level renderer exposes no user stencil
passes, and the GL Compatibility backend has no render-graph hooks to inject
mid-frame masked re-renders. Oblique projections are **not exposed** on
`Camera3D` in 4.4 — the proposals are still open
([godot-proposals #1863](https://github.com/godotengine/godot-proposals/issues/1863),
[#501](https://github.com/godotengine/godot-proposals/issues/501)) and the
"Oblique camera" PR ([godot #89140](https://github.com/godotengine/godot/pull/89140))
is unmerged. Full stencil recursion in Compatibility is a custom-renderer project,
not a feature.

**Minecraft Immersive Portals** ([implementation notes](https://qouteall.fun/immptl/wiki/Implementation-Details.html),
[repo](https://github.com/iPortalTeam/ImmersivePortalsMod)): renders the
destination with a second camera pass, clips everything on the near side of the
destination plane by *patching the terrain shaders* with a clip plane, loads
chunks around the destination (it rewrote vanilla's player-centred chunk arrays
into maps to allow far/remote chunk loading), culls the portal's inner frustum to
the portal opening and the outer world against portal occlusion, renders
plane-clipped entities twice when they straddle the seam, and teleports entities
by applying the portal isometry to position/orientation/velocity with the seam
crossing detected against the plane.
*Transferable ideas:* (a) secondary camera per visible portal, hard cap on how
many; (b) clip at the destination plane; (c) cull the inner render to the portal
opening's frustum; (d) **stream terrain around the destination** while a portal is
active; (e) teleport = apply the isometry to position/yaw/velocity + debounce.
All five map cleanly onto this engine (see §3), except (b), which we get *for
free* by construction — see below.

**Spigot/Bukkit portal plugins** (server-side, no client render): teleport-only
portals with particle/effect fills. This is the floor, not the goal — but it is
exactly our **degrade-to fallback** if render-to-texture proves too slow on a
given web client: the portal surface falls back to a static "energy" material and
the (optional) teleport still works. The feature ships in some form no matter
what the GPU does.

**Godot-native: SubViewport render-to-texture.** The standard Godot 4 recipe: a
`SubViewport` with `own_world_3d = false` and `world_3d` pointed at the main
scene's `World3D`, containing a `Camera3D`; the portal quad samples the
`ViewportTexture`. Fully supported by the Compatibility renderer and the WebGL2
export (it is an ordinary FBO pass; no `SharedArrayBuffer`/COOP-COEP interaction).
Two variants exist:

- **(A) SCREEN_UV variant** (the commonly-cited recipe, and the prior in the
  task brief): the SubViewport camera *copies the player camera's full
  projection* (FOV/aspect), transformed by the portal isometry, and the quad
  shader samples the texture at `SCREEN_UV`. Correct parallax, but: the
  SubViewport must track the main viewport's resolution (or accept blur), the
  virtual camera renders a *full-screen* frustum (no culling win), and the
  destination-plane clipping problem is unsolved — you must approximate with a
  perpendicular `near` push, which still lets flanking geometry intrude.

- **(B) Window (off-axis frustum) variant — CHOSEN.** `Camera3D` in
  `PROJECTION_FRUSTUM` mode (`set_frustum(size, offset, near, far)`,
  ["tilted frustum" per the 4.4 docs](https://docs.godotengine.org/en/4.4/classes/class_camera3d.html))
  can realise a *generalized off-axis perspective*: put the virtual eye at the
  transformed player-eye position, orient the camera **perpendicular to the
  destination portal plane**, and choose `near`/`frustum_offset`/`size` so that
  **the near-plane rectangle is exactly the destination portal opening**. This
  is Kooima's "generalized perspective projection" (CAVE/head-tracked-window
  math). Three decisive consequences:
  1. **The oblique-clipping problem vanishes.** The near plane *is* the portal
     plane — by construction nothing between the virtual eye and the destination
     plane can render. Exact, not an approximation; no shader patching, no
     stencil, nothing the Compatibility renderer lacks.
  2. **The frustum is only as wide as the portal opening**, so Godot's regular
     frustum culling drops almost all of the destination scene — the SubViewport
     pass renders a small fraction of the main view's draw calls.
  3. **The image maps onto the portal quad with plain static UVs** (the window
     rectangle fills the render target), so the SubViewport resolution is set by
     the portal's physical size, not the screen — a 1×2 m portal is perfectly
     served by a ~128×256 target. No SCREEN_UV, no full-res target.
  The off-axis image viewed from the *matching* eye point is exactly the
  through-the-window radiance field, so the main camera looking at the textured
  quad from any angle sees the correct view — the classic window-projection
  property. (This also means the virtual camera does **not** rotate with the
  player's head; only the eye *position* matters. One transform update/frame.)

### 1.2 Why not the SCREEN_UV variant

| | (A) SCREEN_UV | (B) window frustum (chosen) |
|---|---|---|
| Destination-plane clipping | approximate (`near` push; flanking intrusions) | **exact** (near plane = portal plane) |
| SubViewport resolution | must track screen (or blur) | fixed, portal-sized (small) |
| Culling of destination pass | full camera frustum | **portal-opening frustum only** |
| Per-frame camera update | position + full rotation | position + near/offset only |
| Shader | SCREEN_UV sample | plain UV sample (+ per-side U flip) |
| Known Godot recipe risk | widely used | frustum-offset math must be got right once |

The single risk of (B) — getting the off-axis math and the per-side UV flip right —
is retired by a *headless math verify* (§3.7) plus a scripted landmark eyeball
test (§4 Stage 3). (A) is kept as the documented fallback recipe if (B) hits an
unexpected engine limitation (§5.3), since everything else in the architecture
(manager, frames, tool, caps, viewer streaming) is identical for both.

### 1.3 WebGL2 / Compatibility constraints honoured

- **SubViewport RTT works in Compatibility/WebGL2** but each active viewport is a
  full extra scene pass — web reports of unbudgeted multi-viewport setups
  collapsing to <1 fps exist ([godot forum #101434](https://forum.godotengine.org/t/subviewport-rendering-performances-on-web/101434)).
  Hence: **hard cap on simultaneously-rendered portals (default 1, max 2)**,
  portal-sized low-res targets, `UPDATE_DISABLED` when inactive, optional
  half-rate updates, and a kill switch that degrades to energy-surface portals
  (§3.5, §5).
- **No instance uniforms in Compatibility** — per-portal shader state
  (texture, U-flip) lives in a per-portal `ShaderMaterial` instance sharing ONE
  shader (one pipeline, one prewarm job).
- **First-draw pipeline compiles stutter on web (ANGLE)** — the portal-surface
  shader and the energy material are added to `ShaderPrewarm`'s job list so the
  ~800 ms compile lands behind the boot overlay, not on first link (§3.5.7).
- **Threaded export / COOP-COEP:** irrelevant to viewports; no interaction.
- **Destination chunk loading:** the module path supports **multiple
  `VoxelViewer`s** ("allows multiple loading points",
  [changelog](https://voxel-tools.readthedocs.io/en/latest/changelog/)) — an
  active portal parks a small-radius viewer at the destination (§3.5.6). The
  GDScript fallback streamer is single-centre; distant destinations degrade to
  fog there (accepted, documented).
- **Physics is analytic** (`floor_under`/`blocked` are pure functions of
  TerrainConfig + edits, never of loaded meshes), so neither rendering-only
  portals nor teleport can ever drop the player through unloaded terrain. This is
  a genuinely load-bearing property for teleport (§3.6).

**Verdict: fully feasible on this engine.** The chosen approach is (B):
one `PortalManager` global-class node owning per-link `PortalSurface` pairs, each
an off-axis-frustum SubViewport camera + a UV-textured quad, capped and
render-scale-bounded for the web budget, recursion depth 0 (portal-in-portal
shows a cheap energy fill), destination `VoxelViewer` streaming on the module
path, and an optional analytic teleport stage.

---

## 2. Codebase facts this design is grounded in

(paths relative to `godot/`; verified against the worktree)

- **Scene assembly in code, no autoloads** — `src/main.gd` builds
  WorldManager → Player (world+inventory injected) → HotbarHUD → ThermometerHUD →
  ShaderPrewarm. New subsystems attach the same way (FarTerrain precedent:
  render-only node owned by WorldManager, `ENABLED` const to switch off
  bit-for-bit).
- **`WorldManager` (src/world/world_manager.gd)** — `cell_value_at`/`block_id_at`
  is THE composed cell query; `_write_cell` is the single write choke point (all
  break/place/collapse/sim writes route through it); `break_terrain`,
  `place_block`, `aimed_voxel` (DDA), analytic `floor_under`/`blocked`/
  `ceiling_scan`; existing signals `path_selected`, `block_entity_orphaned`.
  **There is no per-cell edit signal yet** — this design adds one (§3.4.3).
- **`BlockCatalog` (src/sim/block_catalog.gd) + `assets/blocks.json`** —
  **obsidian already exists: id 75**, mass 1330, break_force 5700, swatch
  (0.063, 0.043, 0.098), opaque, with a real texture tile
  (`BlockTextures.TILES[&"obsidian"]` → `assets/textures/pack/obsidian.png`).
  It is placeable/breakable through the normal path already. It does **not**
  generate in terrain, so it must be granted (§3.1).
- **`Inventory` (src/ui/inventory.gd)** — pure model, slots
  `{"id": int, "count": int}`, `add()` rejects `block_id <= 0`,
  `selected_block_id()`, `consume_selected()`. **No tool/item concept exists**;
  §3.2 adds one via negative ids.
- **`Player` (src/player/player.gd)** — LMB `_try_break()`, RMB `_try_place()`
  via `_current_target()` (nearest of physics-ray-vs-wood and analytic DDA);
  `world` and `inventory` injected by Main; camera built in `_ready`
  (`_camera.far` = 3840 with far field); `_camera.cull_mask` currently default.
- **`HotbarHUD` (src/ui/hotbar_hud.gd)** — renders slots from
  `BlockTextures.texture_for(id)` else `BlockCatalog.color_of(id)`; must learn
  the tool id (§3.2.3).
- **Two render paths, one behaviour** — `module_world.gd` (godot_voxel;
  `attach_viewer()` adds a `VoxelViewer` under the player) or
  `fallback/chunk_streamer.gd`. **Portals live entirely outside both** as their
  own node graph, exactly like `FarTerrain` — automatically path-agnostic.
- **`ShaderPrewarm` (src/tools/shader_prewarm.gd)** — enumerates
  (mesh, material) jobs and draws them behind the boot overlay; the far material
  has its own job (`_build_far_warm_mesh`) — the pattern to copy for the two new
  portal materials.
- **`verify_feature.gd` (src/tools/verify_feature.gd)** — headless SceneTree
  script, `_ok(cond, msg)` assertions, one `_test_*()` per feature, live
  WorldManager-in-tree tests already exist (`_test_world_loop`,
  `_test_structural`). Portal invariants slot in as new `_test_portal_*`
  functions (§3.7).
- **Analytic physics** — no terrain trimesh; visual layers: all world geometry
  renders on VisualInstance3D default layer 1.
- **Structural integrity** — `place_block` triggers `_structural_update`; a
  frame's top lintel is a horizontally-spanning run of heavy blocks, so frame
  buildability must be asserted (§3.7, guard against solver-driven collapse of
  the max frame; tune obsidian's `anchors` in blocks.json if it fires).

---

## 3. Architecture

### 3.0 New files and the node graph

```
godot/src/portal/portal_frame.gd        class_name PortalFrame      (RefCounted: detected-frame value object)
godot/src/portal/portal_frame_detector.gd  class_name PortalFrameDetector  (static, pure: detection algorithm)
godot/src/portal/portal_manager.gd      class_name PortalManager    (Node3D: registry + tool logic + lifecycle)
godot/src/portal/portal_surface.gd      class_name PortalSurface    (Node3D: quad + energy fill + SubViewport + camera)
godot/src/portal/portal_math.gd         class_name PortalMath       (static, pure: isometry + window-frustum math)
godot/src/ui/item_catalog.gd            class_name ItemCatalog      (static: non-block hotbar items — the linker tool)
godot/src/ui/toast_hud.gd               class_name ToastHUD         (CanvasLayer: transient one-line status text)
godot/assets/portal.gdshader            (the portal-surface shader; res path referenced by PortalSurface)
```

Modified files: `main.gd` (wire PortalManager + ToastHUD + starter kit),
`world_manager.gd` (add `cell_edited` signal — 2 lines), `inventory.gd` (accept
negative ids, stack-1 tools), `player.gd` (route RMB to the tool when a tool is
selected; camera cull_mask), `hotbar_hud.gd` (tool icon branch),
`shader_prewarm.gd` (2 new jobs), `tools/verify_feature.gd` (new `_test_portal_*`),
`assets/blocks.json` (only if the Stage-1 buildability assert forces an obsidian
`anchors` tune — otherwise untouched).

Scene graph at runtime (all built in code):

```
Main
 ├─ WorldManager …                     (unchanged; + cell_edited signal)
 ├─ Player                             (portals ref injected; RMB tool routing)
 ├─ HotbarHUD / ThermometerHUD         (hotbar learns tool icons)
 ├─ ToastHUD                           (created by Main, injected into PortalManager)
 └─ PortalManager                      (ENABLED const; world+player injected)
     ├─ PortalSurface (per linked frame, 2 per link)
     │   ├─ MeshInstance3D "Quad"      visual layer 2 (live view; main camera only)
     │   ├─ MeshInstance3D "Fill"      visual layer 3 (energy fill; portal cameras only)
     │   └─ SubViewport                (only while ACTIVE)
     │       └─ Camera3D               cull_mask = layers 1|3 (never 2 → recursion depth 0)
     └─ VoxelViewer (module path only, per ACTIVE portal's destination)
```

Visual-layer contract (the recursion-depth-0 mechanism):
- **Layer 1**: all world geometry (default — terrain, debris, far field). Unchanged.
- **Layer 2**: live portal quads. Seen ONLY by the player camera.
- **Layer 3**: energy fills. Seen ONLY by portal cameras.
- Player camera: `cull_mask = (1<<0) | (1<<1)` (set in `Player._ready`).
- Portal cameras: `cull_mask = (1<<0) | (1<<2)`.
So a portal seen through a portal renders as its energy fill — never a feedback
loop, and no camera ever draws both coincident quads (no z-fighting).

`PortalManager.ENABLED := true` (FarTerrain pattern): `false` → Main creates no
node, zero behaviour change. `PortalManager.render_enabled := true` instance flag:
verify sets it `false` so no SubViewport/quad nodes are created headless — every
registry/math/teardown invariant still runs.

### 3.1 Obsidian (and how the player gets it)

Already in the catalog (id 75 — resolved by name, never hard-coded:
`BlockCatalog.id_of(&"obsidian")`), textured, placeable, breakable. **No catalog
work needed.** It does not generate in terrain and the inventory starts empty, so
for this milestone Main grants a **portal starter kit** at spawn, gated by
`PortalManager.GRANT_STARTER_KIT := true`:

```gdscript
# main.gd, after inv is created (deliberate demo affordance — obsidian has no
# worldgen source yet; revisit when lava/water interactions can produce it):
if PortalManager.ENABLED and PortalManager.GRANT_STARTER_KIT:
    inv.add(BlockCatalog.id_of(&"obsidian"), 40)      # two ~4×5 frames' worth
    inv.add(ItemCatalog.PORTAL_LINKER, 1)
```

This intentionally bends the "starts EMPTY, break-first" rule for the demo;
the const documents and isolates the decision.

### 3.2 The tool/item concept (ItemCatalog + Inventory + HUD)

Blocks occupy the non-negative dense LRID space (append-only, up to 65536).
**Tools are negative ids** — disjoint by construction from any present or future
block id, no catalog interaction, no render-path coupling.

**`ItemCatalog`** (static, mirrors BlockCatalog's facade shape, tiny):

```gdscript
class_name ItemCatalog
const PORTAL_LINKER := -1
static func is_item(id: int) -> bool            # id < 0
static func name_of(id: int) -> String          # "portal linker"
static func color_of(id: int) -> Color          # Color(0.55, 0.30, 0.95) — violet swatch
static func max_stack_of(id: int) -> int        # 1 for tools
```

**`Inventory` changes** (minimal, behaviour-preserving for blocks):
- `add()`: guard becomes `if block_id == 0: return count` (was `<= 0`); the
  per-slot stack cap becomes `ItemCatalog.max_stack_of(id)` for negative ids
  (`MAX_STACK` unchanged for blocks). Existing tests keep passing: block-id
  behaviour is byte-identical.
- `selected_block_id()` keeps its name and may now return a negative id; all
  existing callers are in `Player._try_place`, which is updated in the same
  stage (below), so no caller ever misreads a tool as a block.

**`HotbarHUD._refresh_slot`**: branch before the texture lookup —
`if id < 0:` show `ItemCatalog.color_of(id)` swatch (count label hidden for
stack-1 tools). `BlockTextures.texture_for` is never called with a negative id.
(A baked icon can replace the swatch later; out of scope.)

**`Player` changes**:
- new injected field `var portals: PortalManager` (nullable — standalone/verify).
- `_try_place()` first line: `if id < 0: _use_tool(id); return`.
- `_use_tool(id)`: for `PORTAL_LINKER` → `portals.use_linker(_current_target())`
  (null-safe). The existing `_current_target()` already supplies
  `{"kind": "terrain", "cell": Vector3i, ...}` from the DDA — the tool reuses the
  exact same aim contract as break/place, so aiming and tool use can never
  disagree.

### 3.3 Frame detection (`PortalFrameDetector` + `PortalFrame`)

Pure/static, reads the world ONLY via `world.block_id_at(cell)` — the one cell
query (CLAUDE.md rule 1) — so generated terrain, edits and trees are all valid
frame material sources automatically (only obsidian passes the material test, and
obsidian only exists as placed edits today, but the detector does not care).

**Definitions.** A frame is a **closed axis-aligned rectangular ring of obsidian
on a vertical plane** with an all-air interior. Two orientations:
- `AXIS_X`: plane normal = ±X; the ring spans Z (width) × Y (height) at fixed x.
- `AXIS_Z`: plane normal = ±Z; the ring spans X (width) × Y (height) at fixed z.

Interior size: `MIN_W×MIN_H = 1×2` (a doorway; the 0.8 m player capsule fits a
1-cell opening) to `MAX_W×MAX_H = 8×8` (bounds detection cost, texture size and
the structural lintel span). The ring includes **all four corners** (stricter
than Nether portals; simpler and unambiguous to validate).

**Data (`PortalFrame`, RefCounted):**

```gdscript
var axis: int            # PortalFrame.AXIS_X or AXIS_Z (plane normal axis)
var interior_min: Vector3i   # min-corner interior air cell (canonical key part)
var width: int           # interior cells along the tangent axis
var height: int          # interior cells along Y
func key() -> Vector4i   # (interior_min.x, .y, .z, axis) — THE registry key
func ring_cells() -> Array[Vector3i]     # the 2*(w+h)+4 obsidian cells
func interior_cells() -> Array[Vector3i] # the w*h air cells
func center() -> Vector3 # interior centre: min + 0.5*(w·tangent + h·up) + (0.5,0.5,0.5)-style cell centring
func global_transform() -> Transform3D   # see below
```

**Canonical transform convention** (used by quad placement, camera math, teleport;
asserted in verify): basis columns
`X = tangent` (`+Z` unit for AXIS_X, `+X` unit for AXIS_Z),
`Y = +Y` (up), `Z = normal` (`+X` unit for AXIS_X, `+Z` unit for AXIS_Z — always
the **positive** axis; "front" is an arbitrary but fixed choice), origin =
`center()`, where `center()` places the portal plane on the **mid-plane of the
interior cell layer** (plane coordinate = `interior_min.axis + 0.5`).
This basis is right-handed for AXIS_Z (X,Y,Z = x̂,ŷ,ẑ); for AXIS_X
(X=ẑ, Y=ŷ, Z=x̂) it is left-handed — to keep `Basis` orthonormal &
right-handed (Godot requires it for cameras), AXIS_X uses `X = -ẑ` instead;
the detector fixes this once and verify pins it
(`basis.determinant() == 1` for both orientations).

**Detection algorithm** (`PortalFrameDetector.detect(world, seed_cell) -> PortalFrame?`;
`seed_cell` is the obsidian cell the tool was used on):

```
for axis in [AXIS_X, AXIS_Z]:
  for each interior candidate c adjacent to seed_cell within the axis plane
      (the 4 in-plane neighbours of the seed that are air):
    1. drop:  from c, walk -Y through air (in-plane) at most MAX_H steps → bottom
              interior row must rest on obsidian, else next candidate.
    2. slide: from the bottom cell, walk -tangent through air at most MAX_W steps
              → left column must abut obsidian, else next candidate.
              Result: candidate interior_min.
    3. measure: from interior_min, walk +tangent while air → w (fail if > MAX_W
              or the far side is not obsidian); walk +Y while air → h (same).
    4. validate rectangle:
         a. every interior cell (w×h) is air        — world.block_id_at == AIR
         b. every ring cell (2(w+h)+4, incl. corners) is obsidian
         c. MIN_W <= w <= MAX_W, MIN_H <= h <= MAX_H
       all pass → return PortalFrame(axis, interior_min, w, h)
return null
```

Cost: O(MAX_W·MAX_H) ≤ 64 composed cell queries per candidate — trivial, and it
runs only on tool clicks. The interior/ring walks re-run cheaply on demand;
frames are **revalidated** (`PortalFrameDetector.still_valid(world, frame)` — a
re-run of steps 4a/4b for the stored rect) whenever an edit touches their cells
(§3.4.3) and before any link is consummated.

**Edits later breaking a frame** are handled by the manager via the new
`cell_edited` signal — not by the detector.

### 3.4 `PortalManager` — registry, tool interaction, lifecycle

A global `class_name` Node3D created by Main (`ENABLED` gate), with
`setup(world: WorldManager, player: Player, toast: ToastHUD)` injection
(verify passes `player = null`, `toast = null`, `render_enabled = false`).

#### 3.4.1 State

```gdscript
const MAX_LINKS := 16                 # sanity cap on simultaneous links
var _armed: PortalFrame = null        # the arm→link two-step's first frame
var _links: Dictionary = {}           # key(Vector4i) -> {frame: PortalFrame, other: Vector4i, surface: PortalSurface}
var _cell_index: Dictionary = {}      # Vector3i -> Vector4i owning link key (ring ∪ interior cells)
```

`_cell_index` maps every ring **and** interior cell of every linked frame to its
frame key — the O(1) hook the edit signal checks against. (Armed-but-unlinked
frames are NOT indexed; arming is a transient UI state, revalidated at link time.)

#### 3.4.2 Tool interaction (`use_linker(target: Dictionary)`)

```
target.kind != "terrain" or block_id_at(target.cell) != obsidian:
    → toast "Aim at an obsidian frame block"; return
frame := PortalFrameDetector.detect(world, target.cell)
frame == null → toast "Not a valid frame (closed obsidian rectangle, interior 1×2 … 8×8)"; return
frame.key() already linked → unlink it (tear down BOTH surfaces), toast "Portal unlinked"; return
_armed == null            → _armed = frame; toast "Frame armed — use the linker on a second frame"; return
_armed.key() == frame.key() → _armed = null; toast "Frame disarmed"; return
else → link(_armed, frame); _armed = null
```

`link(a, b)`:
- revalidate both (`still_valid`); a stale armed frame → toast + abort.
- `_links.size()/2 >= MAX_LINKS` → toast "Too many portals"; abort.
- if either frame is already linked (possible for `b`), unlink it first
  (re-linking steals cleanly; the orphaned partner's surface is torn down).
- register both directions, index all cells, and (render path) create one
  `PortalSurface` per frame: `surface_a.configure(frame_a, frame_b)`,
  `surface_b.configure(frame_b, frame_a)`. Toast "Portals linked".

The same tool click therefore does: arm / disarm / link / unlink — one item, no
modes, mirroring how Immersive-Portals-adjacent Spigot tools behave.

#### 3.4.3 Teardown on world edits — the `cell_edited` signal

`WorldManager._write_cell` gains one line at its end:

```gdscript
signal cell_edited(cell: Vector3i, packed: int)   # declared with the other signals
...
cell_edited.emit(cell, packed)                    # last line of _write_cell
```

This is the *only* WorldManager change. Every write path (break, place, collapse
carve, snowfall sim, zone loads) already funnels through `_write_cell`, so the
signal is complete by construction — the same argument the choke point makes for
metadata settlement. Cost: one emit per edit; PortalManager's handler is a single
`_cell_index.has(cell)` dictionary probe (the snowfall sim's writes stay
negligible).

Handler: if the edited cell belongs to a link and
`not still_valid(frame)` **or** the cell is an interior cell now non-air
(`CellCodec.mat(packed) != AIR` — placing a block inside a portal disrupts it) →
`unlink` that link (both surfaces torn down, toast "Portal destroyed"). A ring
edit that leaves the frame intact (e.g. snow state bits on top of the lintel —
same material) keeps the link.

Registry invariants (verified): symmetry (`_links[a].other == b ⇔
_links[b].other == a`); `_cell_index` exactly covers ring∪interior of live links;
unlink removes both directions and all indexed cells; re-link steals atomically.

#### 3.4.4 Persistence

None in this milestone: links are session state (the game has no save/load loop
in the live demo; the edit overlay persists frames' obsidian, and re-linking
after a reload is one tool click). Future: serialize `_links` keys next to the
ZoneChunk overlay. Documented, deliberately out of scope.

### 3.5 Portal rendering (`PortalSurface` + `PortalMath`)

#### 3.5.1 The isometry

For source frame S linked to destination frame D (both `Transform3D` from
§3.3), with `R := Basis(Vector3.UP, PI)` (180° about local up — entering S's
front exits D's front):

```
T_SD := D.global_transform() * Transform3D(R) * S.global_transform().affine_inverse()
```

Properties (all asserted headless): `T_SD * T_DS == identity`;
`T_SD.basis` is a pure yaw (multiple of 90°, since frames are axis-aligned —
`basis.y == UP`, `basis.determinant() == 1`); a point 1 m in front of S's centre
maps to 1 m behind D's centre; up is preserved.

#### 3.5.2 The window-frustum camera (per frame, ~15 lines in `PortalMath`)

Inputs: player camera origin `E`, source frame S, dest frame D, `T := T_SD`.

```
E' := T * E                                   # virtual eye
n_d := D.basis.z ;  up := D.basis.y ;  right_d := D.basis.x
s  := sign((E' - D.origin) · n_d)             # which side of D the eye landed on
Z_cam := s * n_d                              # camera backward → camera looks at/through the window
X_cam := up.cross(Z_cam)                      # right-handed: X = Y × Z
cam.global_transform := Transform3D(Basis(X_cam, up, Z_cam), E')
near := max((E' - D.origin) · Z_cam, NEAR_MIN)        # ⊥ distance to the plane; NEAR_MIN = 0.01
off  := Vector2((D.origin - E') · X_cam, (D.origin - E') · up)
cam.set_frustum(size = H_m, offset = off, near = near, far = PORTAL_FAR)
cam.keep_aspect = Camera3D.KEEP_HEIGHT        # size == near-plane HEIGHT
```

`H_m = frame.height` (metres); the SubViewport is sized `W:H`, so the near-plane
rectangle is exactly the interior opening (width = size × aspect = W). `PORTAL_FAR`
= the player camera far (3840 with the far field, else the near value in
`player.gd`) so fog composes identically. **The camera basis never tracks the
player's look direction** — only `E'`, `near`, `off` update per frame (and `s`
flips when the player crosses the source plane).

Degeneracy: as the player approaches the source plane, `near → 0`; clamped at
`NEAR_MIN`, the last-centimetre image is imperfect for a frame or two — masked in
practice by the opening filling the screen (and by teleport when enabled).

#### 3.5.3 UV mapping and the per-side flip

The quad's UVs are authored in the frame's `(X=right, Y=up)` basis
(u along +right, v along +up, v up-positive; flip V once empirically for
render-target orientation — pinned by the Stage-3 landmark test).

Derivation of the horizontal correspondence: a point `q = S.origin +
u·S.right + v·up` maps to `T(q) = D.origin − u·D.right + v·up`
(since `T.basis · S.right = −D.right` — the R_y(π) flip). Its texture x is
`(T(q) − D.origin)·X_cam = −u·(D.right · (up × (s·n_d))) = −s·u·(D.right·D.right)
= −s·u`. With the player on S's front (`σ = sign((E − S.origin)·n_s) = +1`),
`s = −σ = −1` ⇒ texture-x ∝ `+u` — **no flip**; from S's back (`σ = −1`) ⇒
flip. So:

```
flip_u := (σ < 0)        # recomputed when the player's side of S changes
```

implemented as a `uniform bool flip_u` on the portal shader (per-portal
ShaderMaterial instance; Compatibility has no instance uniforms). Verify pins
`s == −σ` and the `T.basis · S.right == −D.right` identity; the sign of the
final on-screen flip is confirmed once by the scripted landmark test.

#### 3.5.4 The portal-surface shader (`assets/portal.gdshader`)

```glsl
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;   // both sides show the live view
uniform sampler2D view_tex : source_color, filter_linear;
uniform bool flip_u = false;
void fragment() {
    vec2 uv = UV;
    if (flip_u) { uv.x = 1.0 - uv.x; }
    ALBEDO = texture(view_tex, uv).rgb;
}
```

- `unshaded` + `fog_disabled`: the SubViewport pass already applied ambient +
  depth fog (it renders under the same WorldEnvironment), so the quad must not
  re-shade or re-fog the image. (`fog_disabled` render_mode is available in 4.4
  spatial shaders; the far-terrain material precedent shows the fog pipeline
  participates in Compatibility.)
- ONE shader → one Compatibility pipeline → one `ShaderPrewarm` job (§3.5.7);
  per-portal `ShaderMaterial` instances carry `view_tex`
  (`SubViewport.get_texture()`) and `flip_u`.

**Energy fill** (the depth-0 recursion stand-in + inactive-portal look + the §5
fallback surface): a shared `StandardMaterial3D` — unshaded, albedo
`Color(0.45, 0.2, 0.85)`, `emission_enabled` with a mild glow, `cull_disabled` —
on the second quad (layer 3), and **also shown on layer 2** whenever the portal
is INACTIVE (swap the quad's material rather than spawning a third mesh: ACTIVE →
portal shader, INACTIVE → energy material). So: far/off-screen portals shimmer
violet; portals seen through portals shimmer violet; active portals are live.

#### 3.5.5 `PortalSurface` node behaviour

`configure(src: PortalFrame, dst: PortalFrame)` builds:
- `Quad`: `MeshInstance3D` with a `QuadMesh(size = Vector2(W, H))` (or a 4-vert
  ArrayMesh if custom UV handedness is easier), transform = `src.global_transform()`,
  layer 2. Material per activation state (above).
- `Fill`: same mesh, layer 3, energy material, offset `±0.001` along the normal
  is unnecessary (no camera sees both) — keep coincident.
- `SubViewport` (created lazily on first activation): `own_world_3d = false`,
  `world_3d = get_viewport().find_world_3d()` (the standard shared-world RTT
  recipe, [Godot viewports doc](https://docs.godotengine.org/en/stable/tutorials/rendering/viewports.html)),
  `msaa_3d = MSAA_DISABLED`, `screen_space_aa = off`, `use_debanding = false`,
  `positional_shadow_atlas_size = 0` (no shadows in this scene anyway),
  `render_target_update_mode = UPDATE_DISABLED` until active. Size (§3.5.6).
- `Camera3D` child of the SubViewport: `cull_mask = (1<<0)|(1<<2)`, `current = true`.

Per-frame (`PortalManager._process` drives all surfaces; surfaces hold no logic
loop of their own): active surfaces get the §3.5.2 update; on player-side change,
`flip_u` is rewritten.

#### 3.5.6 Activation policy, caps, resolution — the web frame budget

An extra SubViewport pass re-renders the destination scene. Budget reasoning:
the window frustum subtends only the portal opening, so Godot frustum-culls the
destination pass down to the chunks/debris/far-tiles inside a narrow pyramid —
measured expectation 10–30 % of the main view's draw calls for a 2×3 portal at
4–16 m (it *grows* as the player nears the portal and the frustum widens; worst
case standing at the plane ≈ a second full view, briefly, exactly when teleport
fires). Web (WebGL2 + ANGLE) is draw-call-bound, hence hard caps:

```gdscript
const MAX_ACTIVE := 1            # simultaneously-rendered portals (2 = desktop luxury; web default 1)
const ACTIVATE_DIST := 24.0      # metres from player to source frame centre
const PX_PER_BLOCK := 96         # SubViewport pixels per interior metre
const MAX_TARGET_PX := 768       # per-axis clamp (8×8 portal → 768×768)
const HALF_RATE_SECOND := true   # a 2nd active portal updates every other frame
const DEACTIVATE_HYSTERESIS := 4.0   # m beyond ACTIVATE_DIST before deactivation
```

**ACTIVE** = the `MAX_ACTIVE` nearest linked surfaces with (a) player within
`ACTIVATE_DIST`, (b) quad centre inside the player camera frustum
(`camera.is_position_in_frustum` on the centre + a corner), (c) the player NOT
exactly edge-on (|(E−S.origin)·n_s| > 0.05). Everything else is INACTIVE: energy
material, `UPDATE_DISABLED`, and (after a grace period) SubViewport freed.
Activation flips `UPDATE_ALWAYS`, swaps the live material, resizes the target to
`clamp(size_m * PX_PER_BLOCK, 64, MAX_TARGET_PX)` — sized ONCE per activation
(resizes reallocate the FBO; never per-frame).

**Destination streaming (module path):** on activation, PortalManager parks a
`VoxelViewer` (instantiated via `ClassDB`, exactly like
`module_world.attach_viewer` does — string-based, safe when absent) at
`dst.center()` with `view_distance = 64`, `requires_collisions = false`; freed
`DEACTIVATE_HYSTERESIS`-style 10 s after deactivation (avoid stream thrash when
peeking repeatedly). Multiple viewers are supported by godot_voxel
([multiple loading points](https://voxel-tools.readthedocs.io/en/latest/changelog/)).
Web caveat: the voxel worker pool is pinned at 2 (`project.godot [voxel]`); a
second stream centre competes for it — the small radius bounds the burst, and the
portal simply shows fog until meshes land (identical to how the main view
streams). **Fallback GDScript path:** `ChunkStreamer` is single-centre; a
destination beyond `RENDER_RADIUS_BLOCKS` of the player shows sky/fog through the
portal. Accepted degrade; near-destination links (the common sandbox case) work
on both paths.

**Far field through portals:** FarTerrain tiles are player-centred, layer 1, so
portal cameras see the same far silhouette the player would at the destination
only where tiles exist (they cover an annulus 192–3072 m around the *player*).
A distant destination's near view streams via the viewer; its horizon may be
thinner than standing there. Accepted for v1 (documented); fix = per-destination
far tiles, deliberately out of scope.

#### 3.5.7 Shader prewarm (web first-draw stutter)

`ShaderPrewarm.spawn_warmups` gains two jobs (same pattern as
`_build_far_warm_mesh`), gated on `PortalManager.ENABLED`:
1. a unit quad with the portal `ShaderMaterial` (dummy `ImageTexture` — pipelines
   key on shader + vertex format, not texture contents);
2. a unit quad with the shared energy `StandardMaterial3D`.
Without this, the first link on web eats an ~800 ms ANGLE compile; with it, both
compiles land behind the boot overlay. (SubViewport's own pass uses already-warmed
world materials — no new pipelines there.)

### 3.6 Optional stage: walk-through teleport

Marked optional; everything above ships without it (portals as windows). Design:

**Crossing test (analytic, no Area3D).** Physics is analytic and the player
tunnels planes only via position updates, so use a segment test, mirroring how
`ceiling_scan` prevents tunneling: each `_physics_process`, for each *linked*
frame S within 4 m, with `p0/p1` = previous/current player **eye** positions
(`global_position + (0, eye_height, 0)` — the seam is where the head goes
through): if `((p0 − S.origin)·n_s)` and `((p1 − S.origin)·n_s)` straddle 0 AND
the plane-intersection point lies inside the interior rect **inflated by
`PLAYER_RADIUS`** on both axes → teleport through S. (Area3D would work but adds
physics-server state for no benefit; the analytic test is exact at any frame
rate, and PortalManager already knows every frame rect.)

**The applied transform** (`T := T_SD`, pure yaw + translation, §3.5.1):

```
player.global_position = T * player.global_position
player.rotation.y     += yaw_of(T.basis)        # T is an exact multiple of 90°
player.velocity        = T.basis * player.velocity
# camera pitch (_pitch) unchanged — T preserves up
```

Then nudge: if the arrival cell stack is blocked
(`world.blocked(...)`/`floor_under` disagree with standing room — reuse the
`_cell_intersects_player` spirit), step up to 2 cells along `+n_d` (the exit
direction) looking for feet+head air; if none, **refuse the teleport** (the
player just walks through the quad, as pre-teleport). Because floor/walls are
pure functions, arrival into not-yet-meshed terrain is safe — the ground holds
before the meshes appear.

**Debounce:** after a teleport, disable crossing tests for 0.25 s AND until the
player is > 0.5 m from the destination plane — the mirrored geometry otherwise
re-triggers instantly (the classic ping-pong). One `_teleport_lockout` timer in
PortalManager.

**Systems interaction:** the next `player._physics_process` already calls
`world.update_streaming(global_position)` — GroundCollider recentres,
ChunkStreamer/VoxelViewer/FarTerrain re-evaluate, snowfall latches the new
position. No additional wiring. Loose-body pushes and the wood ray are
position-local and unaffected. `frozen` (prewarm) gates input, not teleports;
teleports can only happen after unfreeze since crossing requires movement.

**Velocity note:** falling into a floor-adjacent vertical portal keeps |v| —
axis-aligned yaw means no energy hacks needed. Horizontal-plane portals (floor/
ceiling) are excluded by the frame definition (vertical planes only), dodging
the up-vector singularity entirely.

### 3.7 Verify invariants (headless — `verify_feature.gd`)

New functions appended to `_initialize()` in this order, all running with
`render_enabled = false` (no SubViewport/quad nodes; registry+math only — the
GPU-truth parts are covered by the Stage-3 scripted eyeball test, listed in §4):

**`_test_portal_items()`** — Inventory/ItemCatalog:
- `add(ItemCatalog.PORTAL_LINKER, 1)` absorbs; stack caps at 1
  (`add(...,2)` returns 1 surplus); `add(0, n)` still no-ops; block stacking
  byte-identical (re-assert an existing 64-cap case).
- `selected_block_id()` returns the negative id when selected.

**`_test_portal_frames()`** — detection (live WorldManager in tree, frames built
via `world.place_block` on a flat generated area, the `_test_world_loop`/
`_grass_column` pattern):
- ACCEPT: a 1×2-interior AXIS_X frame and a 4×5 AXIS_Z frame — detected from
  every ring block as seed; `key()`, `width/height`, `axis`, `interior_min` all
  exact; `interior_cells().size() == w*h`; `ring_cells().size() == 2*(w+h)+4`.
- ACCEPT: seed on any of the four corner blocks resolves the same frame.
- REJECT: ring with one block missing; ring closed but one interior cell filled
  (place a dirt block inside); interior 1×1 (too small); interior 9×2 (too wide —
  build with MAX_W+1); an L-shaped obsidian blob; a *horizontal* ring (flat on
  the ground).
- CANONICAL TRANSFORM: for both orientations, `basis` orthonormal,
  `determinant() == 1`, `basis.y == UP`, `origin` at the interior mid-plane
  centre (hand-computed expected values).
- BUILDABILITY (structural guard): building the MAX 8×8-interior ring block-by-
  block via `place_block` never triggers a collapse
  (`world.active_body_count() == 0` after each course) — if this fires, tune
  obsidian `anchors` in blocks.json (documented escape hatch), re-run.
- EDIT INTERPLAY: `still_valid` true after an unrelated neighbouring edit; false
  after breaking a ring block; false after filling an interior cell.

**`_test_portal_linking()`** — registry:
- arm → link creates symmetric entries; `linked_key_of(a) == b` and vice versa.
- arm same frame twice = disarm (no link); linking a frame to itself rejected.
- re-link: A↔B then C→A steals: B unlinked (its entry + indexed cells gone),
  A↔C live.
- unlink-by-tool: using the linker on a linked frame removes both directions.
- teardown: `break_terrain` on a ring block of a linked frame → both entries
  gone, `_cell_index` empty for all its cells; `place_block` into an interior
  cell → same. An **unrelated** edit two cells away changes nothing.
- MAX_LINKS enforced (17th link refused, registry unchanged).
- `cell_edited` signal itself: emitted exactly once per `break_terrain` /
  `place_block` (a counting listener).

**`_test_portal_math()`** — pure `PortalMath` (no world needed):
- `T_SD * T_DS == IDENTITY` (within epsilon) for AXIS_X↔AXIS_Z, AXIS_X↔AXIS_X
  and translated/rotated frame pairs; `T.basis.y == UP`;
  `T.basis` yaw is a multiple of 90°; determinant 1.
- front-maps-to-back: `T * (S.origin + S.basis.z) ≈ D.origin − D.basis.z`.
- `T.basis * S.basis.x ≈ −D.basis.x` (the U-flip identity, §3.5.3).
- window-frustum: for hand-built S, D and eye E, the computed
  `(near, offset, size, cam transform)` reprojects each of D's four interior
  corners to the expected NDC corners (±1, ±1) — i.e. build the projection from
  `near/off/size/aspect` and assert corner correspondence. Also `s == −σ`.
- degeneracy: E on the S plane → `near` clamps to `NEAR_MIN`, no NaNs.

**`_test_portal_teleport()`** (only if Stage 5 lands) —
- segment crossing detector: hits for a straight walk-through at centre; misses
  for a pass 0.2 m outside the inflated rect, for motion parallel to the plane,
  and for a crossing of an *unlinked* frame.
- transform application on a mock kinematic state: position/yaw/velocity
  round-trip through T then T_back recovers the original (mod 2π).
- debounce: an immediate mirrored re-cross within the lockout does not teleport;
  after lockout + distance it does.
- blocked-arrival refusal: wall off the destination exit, assert no teleport and
  position unchanged.

All are pure logic + live-WorldManager state — no GPU, safe under
`--headless` exactly like the existing 40+ tests.

---

## 4. Staged implementation plan

Each stage is independently landable and verifiable; run
`docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script
res://src/tools/verify_feature.gd` after each. Conventional Commits, scope
`voxiverse`, on `feat/voxiverse-portals`.

**Stage 0 — plumbing: edit signal, items, starter kit.**
Create `src/ui/item_catalog.gd`, `src/ui/toast_hud.gd`. Modify
`world_manager.gd` (declare + emit `cell_edited` in `_write_cell`),
`inventory.gd` (negative-id acceptance, per-id stack cap), `hotbar_hud.gd`
(tool swatch branch), `player.gd` (`portals` field; `_try_place` early-routes
`id < 0` to `_use_tool` — a no-op stub logging until Stage 2), `main.gd`
(ToastHUD; starter kit behind `GRANT_STARTER_KIT` — const parked in
`item_catalog.gd` until Stage 2 creates PortalManager, then moved).
Verify: `_test_portal_items` + the `cell_edited` emission-count assert
(temporarily inside `_test_portal_items`; moved into `_test_portal_linking`
at Stage 2). Existing inventory/world tests must stay green (regression gate for
the `add()` guard change).

**Stage 1 — frame detection.**
Create `src/portal/portal_frame.gd`, `src/portal/portal_frame_detector.gd`.
No integration yet (pure classes). Verify: `_test_portal_frames` complete,
including the canonical-transform pins and the 8×8 buildability/structural guard
(tune `assets/blocks.json` obsidian `anchors` only if it fails).

**Stage 2 — manager, tool, registry, teardown.**
Create `src/portal/portal_manager.gd` (registry + `use_linker` + `cell_edited`
handler + toasts; `render_enabled` flag present but surfaces stubbed to null).
Modify `main.gd` (create/inject PortalManager under the `ENABLED` gate; inject
into Player), `player.gd` (`_use_tool` → `portals.use_linker(_current_target())`).
Verify: `_test_portal_linking` complete. Manual smoke (desktop editor run):
build two frames, arm/link/unlink via toasts.

**Stage 3 — see-through rendering (the headline).**
Create `src/portal/portal_math.gd`, `src/portal/portal_surface.gd`,
`assets/portal.gdshader`. Modify `portal_manager.gd` (activation policy, caps,
per-frame camera updates, material swap), `player.gd` (camera
`cull_mask = 0b11`), `shader_prewarm.gd` (two portal jobs, `ENABLED`-gated).
Verify: `_test_portal_math` complete (the NDC-corner reprojection assert is the
math gate). **Scripted landmark test (eyeball, desktop):** spawn, build a 2×3
frame pair ~30 m apart with a distinctive block tower behind frame B; look
through A: tower visible, correct parallax when strafing, correct left/right
(U-flip sign pinned HERE — flip the `flip_u` derivation sign if mirrored, then
re-pin the verify assert to match), energy fill when viewed through a portal,
INACTIVE energy look beyond 24 m. Then the same on the exported web build
(`scripts/export-web.sh`, serve `build/web/`).

**Stage 4 — destination streaming + budget hardening.**
Modify `portal_manager.gd`: destination `VoxelViewer` lifecycle (ClassDB-guarded,
module path only, 10 s linger), `HALF_RATE_SECOND`, activation hysteresis,
SubViewport free-on-linger. Verify (headless): viewer-lifecycle state machine
asserts with the module absent (no-op path must be clean — `ClassDB.class_exists`
guard), activation-policy pure-function asserts (feed synthetic
player positions → expected active set under the caps). Web measurement pass:
`ui/perf_hud.gd` numbers recorded in this doc's §5 table (before/after, 0/1/2
active portals) on the reference laptop; acceptance ≥ 30 fps with 1 active
portal, else apply the §5 ladder and record which rung shipped.

**Stage 5 (OPTIONAL) — walk-through teleport.**
Modify `portal_manager.gd` (crossing tests + lockout + arrival nudge/refusal),
`player.gd` (expose prev-eye or let the manager cache last positions — prefer
the manager caching `player.head_position()` each frame; zero Player API change).
Verify: `_test_portal_teleport`. Eyeball: walk through, orientation/momentum
continuity, no ping-pong, refusal against a walled exit.

**Stage 6 — docs + ship.**
Update this doc with measured numbers + any deviations (a DEVIATIONS section is
mandatory if the U-flip sign or activation constants changed); add the one-line
portals pointer to `docs/DESIGN.md`'s feature list; `scripts/export-web.sh` +
`scripts/deploy.sh`; verify live site loads (COOP/COEP gate) and portals behave.
`/steelman` before PR.

---

## 5. Risks, web-perf budget, fallbacks

### 5.1 Risk register

| Risk | Likelihood | Containment |
|---|---|---|
| SubViewport pass too slow on weak web clients | medium | caps (`MAX_ACTIVE=1`), portal-sized target, `PX_PER_BLOCK` ↓, half-rate updates, §5.2 ladder; measured gate in Stage 4 |
| Off-axis math/UV sign errors | medium, cheap to fix | headless NDC-corner + flip-identity asserts; Stage-3 landmark protocol explicitly pins signs once |
| `frustum_offset` semantics differ from assumption (offset at near plane, camera-space metres) | low | the NDC-corner verify assert fails loudly in Stage 3 before any visual work; fallback = SCREEN_UV variant (§5.3) |
| First-draw pipeline stutter on web | high if unhandled | ShaderPrewarm jobs (Stage 3, non-optional) |
| 8×8 lintel collapses under StructuralSolver | low | Stage-1 buildability assert; obsidian `anchors` tune escape hatch |
| Destination unloaded → portal shows fog | certain at range | VoxelViewer streaming (module), honest fog degrade (fallback path); documented |
| Snowfall sim writes spam the edit signal | certain, benign | O(1) dict probe per emit; measured as noise |
| Teleport ping-pong / blocked arrival | medium | lockout + distance re-arm; nudge-or-refuse rule; verify asserts |
| `NEAR_MIN` shimmer at the plane | certain, brief | accepted; teleport masks it; freeze-frame option noted |

### 5.2 Perf budget + degrade ladder (web, GL Compatibility)

Budget stance: the live demo must stay playable (CLAUDE.md non-negotiable §7).
Baseline main view is draw-call-bound under ANGLE; one active window-frustum
portal ≈ 10–30 % extra draws (narrow frustum), worst-case ~2× for one frame when
standing at the plane. Ladder, applied in order until the Stage-4 gate passes:
1. `PX_PER_BLOCK` 96 → 64; `MAX_TARGET_PX` 768 → 512.
2. Active portal updates every 2nd frame (`UPDATE_ALWAYS` → manual
   `UPDATE_ONCE` pulses).
3. `MAX_ACTIVE` 2 → 1 (default is already 1 on web).
4. Destination `VoxelViewer` view_distance 64 → 32, or module-path viewer off.
5. **Kill switch** `PortalManager.RENDER_PORTALS := false`: surfaces keep the
   energy material permanently (Spigot-style portals) — linking, HUD, teardown
   and (optional) teleport all still work. The feature never blocks the ship.

### 5.3 Render-technique fallback

If `PROJECTION_FRUSTUM` misbehaves in Compatibility (not expected — it is plain
projection-matrix state): switch `PortalMath` + the shader to the SCREEN_UV
variant (§1.1-A): virtual camera = `T * player_cam.global_transform`, copy
fov/aspect, SubViewport sized to a fixed fraction (0.5) of the main viewport,
shader samples `SCREEN_UV`, near-plane approximation
`near = max(NEAR_MIN, distance from E' to the closest D-quad corner along
camera forward)`. Everything else (manager, frames, caps, activation, teleport)
is untouched — the two variants are a `PortalMath`/shader-local swap by design.

---

## 6. Source pointers (research)

- Oblique near-plane status in Godot:
  [godot-proposals #1863](https://github.com/godotengine/godot-proposals/issues/1863),
  [godot-proposals #501](https://github.com/godotengine/godot-proposals/issues/501),
  [PR #89140 (unmerged)](https://github.com/godotengine/godot/pull/89140)
- Camera3D frustum mode / `set_frustum` / `frustum_offset`:
  [Godot 4.4 Camera3D class docs](https://docs.godotengine.org/en/4.4/classes/class_camera3d.html)
- SubViewport as texture / shared `world_3d` recipe:
  [Godot viewports tutorial](https://docs.godotengine.org/en/stable/tutorials/rendering/viewports.html),
  [SubViewport class docs](https://docs.godotengine.org/en/4.4/classes/class_subviewport.html)
- Web SubViewport perf cautionary tale:
  [godot forum #101434](https://forum.godotengine.org/t/subviewport-rendering-performances-on-web/101434)
- Immersive Portals internals (clip plane, remote chunk loading, in/out frustum
  culling, dual entity render):
  [Implementation Details wiki](https://qouteall.fun/immptl/wiki/Implementation-Details.html),
  [ImmersivePortalsMod repo](https://github.com/iPortalTeam/ImmersivePortalsMod)
- godot_voxel multiple stream centres:
  [Voxel Tools changelog — VoxelViewer "multiple loading points"](https://voxel-tools.readthedocs.io/en/latest/changelog/),
  [multiplayer doc](https://voxel-tools.readthedocs.io/en/latest/multiplayer/)
- Off-axis ("window") projection math: Kooima, *Generalized Perspective
  Projection* (2008) — the head-tracked-window formulation §3.5.2 instantiates.

---

## 7. Implementation notes & DEVIATIONS (as-built, `feat/voxiverse-portals`)

Implemented Stages 0–5 + docs. Headless verify: **`VERIFY: 6163 passed, 0 failed`**
(`_test_portal_items / _frames / _buildability / _linking / _math / _activation /
_surface_lifecycle / _teleport`). The GPU render is eyeballed after deploy — the
headless suite validates logic/math/detection/registry/lifecycle, not the live draw.

Deviations from the locked design, and why:

1. **Off-axis frustum math confirmed correct as specified — no sign flips.** The
   NDC-corner assert (`_test_portal_math`) builds the projection with Godot's OWN
   `Projection.create_frustum_aspect(size = D.height, aspect = W/H, offset, near, far,
   flip_fov = false)` and reprojects D's four interior corners; all land on the NDC
   rectangle (±1, ±1). So `near`/`frustum_offset`/`size` per §3.5.2 are right and the
   `PROJECTION_FRUSTUM` fallback (§5.3) was not needed. `size` is the near-plane HEIGHT
   with `KEEP_HEIGHT`; the portal-sized targets never trip the 64/`MAX_TARGET_PX` clamp
   for w,h ∈ [1,8] at `PX_PER_BLOCK = 96` (min 96, max 768), so the pixel aspect equals
   `W/H` exactly and the live projection matches the verified one.

2. **The shader carries a second `flip_v` uniform** on top of the spec's `flip_u`, for
   the SubViewport render-target vertical orientation. Both flips are **eyeball-pinned**
   (not headless-verifiable): `flip_u` is set per-side from `PortalMath` (the derived
   `σ < 0` rule); `flip_v` is one global constant. If the live view is mirrored
   horizontally, flip the `flip_u` derivation sign in `PortalMath` and re-pin the
   `T.basis·S.right == −D.right` assert; if it is upside-down, toggle `flip_v`. Both are
   uniforms (not `#define`s) so correcting them needs no new pipeline.

   **Live correction (post-deploy): `flip_v` default `true` → `false`.** The first live
   `/portals/` build showed the through-view **upside-down**, and — because the window
   frustum is off-axis when the eye is not level with the opening — the inverted ground
   plane also read as an **incline toward the far side's ground** (reported as two bugs,
   one root cause). The window-frustum camera is provably Y-upright (camera up is always
   `+Y`; the extended NDC verify shows a frame's *bottom* corners map to NDC bottom, not
   inverted, for **both** front-side and back-side eyes), and the GL-Compatibility/WebGL2
   viewport texture sampled by `UV` is not vertically inverted here, so no extra V-flip is
   warranted — `flip_v = true` was the over-correction. This *also* resolved the
   "see-through visible from only one side" report: the quad has been double-sided
   (`cull_disabled`) and the window math correct on both sides since Stage 3 (verified),
   so both faces always rendered a live image; on the **back** face `flip_u = true` (which
   correctly undoes back-face UV mirroring) combined with the erroneous `flip_v = true` was
   a full 180° rotation, so the back view looked broken rather than see-through. With
   `flip_v = false` the front face is upright and the back face is a clean, upright,
   `flip_u`-corrected view — usable from both sides. No `PortalMath`, camera-basis,
   `cull_mask`, or visual-layer change was needed (or made).

3. **Frame buildability is verified via "build a solid 10×10 wall, then dig the 8×8
   interior"** (collapse-proof: every wall block is supported from below during
   construction, the finished lintel is a closed beam), NOT block-by-block ring
   construction. The completed max frame is structurally stable with obsidian's
   **existing** `anchors` — **no `blocks.json` tune was required** (the §3.7 escape hatch
   was not triggered). A player building a big lintel free-hand in mid-air can still shed
   transient cantilevers (the engine has structural integrity); build on the ground or
   with support, exactly like a real portal frame.

4. **Detection seeds from all 8 in-plane neighbours** of the tool-clicked obsidian cell
   (orthogonal + diagonal), not the 4 orthogonal the prose names — a **corner** ring
   block reaches its interior only diagonally, and §3.7 requires corner seeds to resolve.
   Behaviour is otherwise exactly the drop/slide/measure/validate of §3.3.

5. **`compute_active_set` is a pure function** (distance range + hysteresis + edge-on +
   `MAX_ACTIVE`, nearest-first); the live `_process` ANDs the camera `is_position_in_frustum`
   test (which needs a real camera) on top. This let the activation policy be verified
   headless with synthetic eye positions.

6. **`ToastHUD` + `PortalManager` + the starter kit are wired into `main.gd` together**
   (Stages 2–3), not `ToastHUD` alone at Stage 0 — they are inert without the manager, so
   consolidating keeps `main.gd` coherent. `GRANT_STARTER_KIT` lives on `PortalManager`
   as designed.

7. **`PortalManager.player` is duck-typed** (untyped field/param) rather than `: Node`, so
   the headless teleport test can drive `_physics_process` with a tree-free `RefCounted`
   mock (a Node3D read out-of-tree returns an identity transform). The live injection is
   the real `Player` unchanged.

8. **Verify float tolerances**: the isometry round-trip is asserted as `basis ≈ I` +
   `origin.length() < 0.01` (not `Transform3D.is_equal_approx`) because Godot's `real_t`
   is 32-bit — round-off at coordinates ~200 is ~2e-5, above the 1e-5 default epsilon,
   while a real bug is O(distance). The NDC and math asserts use a 1e-3 tolerance.

### Web perf budget (§5.2) — deferred measurement

The budget **levers are all wired** (`MAX_ACTIVE = 1` on web, portal-sized low-res
targets, `PX_PER_BLOCK`, `HALF_RATE_SECOND` for a 2nd portal, `UPDATE_DISABLED` when
inactive + 10 s linger free, the destination `VoxelViewer` at `view_distance = 64`, and
the `RENDER_PORTALS` kill switch to the energy surface). The actual reference-laptop fps
table is to be filled in at deploy time (`export-web.sh` + `deploy.sh` + eyeball on
`/portals/`); apply the §5.2 ladder in order if 1 active portal drops below 30 fps and
record which rung shipped. The see-through effect is **kept** at every rung down to
low-resolution; only the last-ditch kill switch falls back to the flat energy surface.

### Destination streaming (owner's required visual)

On the module (`godot_voxel`) path an active portal parks a `VoxelViewer` at the
destination (`view_distance = 64`, `requires_collisions = false`, `ClassDB`-instantiated
so the file still loads when the module is absent), so the real far-side blocks stream in
and render behind the opening; it is freed 10 s after deactivation (verified: no leak).
On the GDScript fallback path a distant destination shows fog (accepted degrade); the
common near-destination sandbox case works on both paths.
