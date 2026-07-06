# VOXIVERSE — Enriched Voxel Data Structure (four axes)

Status: **DESIGN — not implemented.** Branch: `feat/voxiverse-sim-extensions`.

This document specifies the in-memory, on-disk and transport representation of an
**enriched voxel**: each cell carries up to four independent axes —

| axis | width | default | analogue | meaning |
|---|---|---|---|---|
| **material** | 16-bit LRID | 0 = air | MC block id / Luanti `param0` | *what substance* — as `docs/RUNTIME-MATERIAL-STREAMING.md` defines |
| **modifier** | 16-bit | **0 = plain full cube** | Luanti `param2` (shape part) / VS chisel | *geometric occupancy*: non-cubic shape + orientation |
| **state** | 16-bit | 0 | MC block states / Luanti `param2` (facing part) | *behavioural variant*: facing, lit, powered, growth stage |
| **metadata** | structured | **absent** | MC block entities (NBT) / Luanti node metadata | *rare rich data*: container inventories, signs, machines |

**The hard requirement this design is built around:** default values consume
**zero per-cell memory**. A cell with modifier 0, state 0 and no metadata stores
nothing beyond its material id; a chunk full of plain cubes has *no* modifier
storage, *no* state storage, *no* metadata storage. (Precisely: zero bytes per
default cell; a constant ≤ 3 bytes of "layer absent" flags per *chunk* — §5.4.)

This document **supersedes `docs/SUB-VOXEL-SMOOTHING.md` §3's cell encoding**
(shape/orientation move out of the cell-int's high bits into the separate
modifier axis — §13.1 lists the exact revisions) and **amends
`docs/RUNTIME-MATERIAL-STREAMING.md`** (§13.2). Material identity (GMID ⇄ LRID)
is untouched: the three new axes are *separate* and never fork the material id
space.

Everything claimed about the engine is verified against the pinned module
source (`docker/engine/versions.env`: Godot 4.4.1-stable, godot_voxel v1.4.1,
cached at `docker/engine/cache/godot/modules/voxel/`) — §2.

---

## 1. Research survey — how the field stores enriched sparse voxels

### 1.1 Minecraft (Java): palettized sections + a block-entity side map

The world is 16×16×16-block *sections*. Each section stores a **local palette**
(list of distinct block states present) plus a bit-packed index array: all 4096
indices share one width — the minimum bits for the largest palette index
(minimum 4 bits; ≤ 12 bits since the palette never exceeds 4096 entries). A
**single-value palette** stores *no* index array at all — an all-stone or
all-air section costs a handful of bytes. Since 1.16 indices never straddle a
64-bit word (padding bits instead), trading ~1.5 % space for shift-and-mask
access with no cross-word reads. Crucially, Minecraft folds *state* into the
palette: `furnace[facing=north,lit=true]` is its own palette entry — defaults
cost nothing because unused state combinations simply never appear in the
palette. Block entities (chests, signs, spawners) live **outside** the array in
a per-chunk list of NBT compounds keyed by position — the canonical
"rare-and-rich data goes in a side map" pattern. Sources:
[Chunk format](https://minecraft.wiki/w/Chunk_format),
[Java Edition protocol / Chunk format](https://minecraft.wiki/w/Java_Edition_protocol/Chunk_format),
[wiki.vg Chunk Format](https://wiki.vg/Chunk_Format).

### 1.2 Minetest / Luanti: `param0/param1/param2` + node metadata + timers

The closest existing analogue of the owner's split. A MapBlock (16³ nodes)
stores three **always-dense** parallel arrays: `param0` (u16 content id — the
material), `param1` (u8 — engine light levels), `param2` (u8 — interpretation
depends on the node definition: `facedir`, `wallmounted`, `leveled`, …) — i.e.
a hardwired 8-bit "modifier/state" per node, *always allocated* (16 KiB per
MapBlock regardless of content; zlib on disk hides the constant cost at rest
but not in RAM). Node **metadata** is a separate serialized map
`position → {key/value string pairs (+ inventories)}`, plus a parallel **node
timers** list — both sparse, both keyed by position, both outside the arrays.
Lesson adopted: the *split* (dense-ish scalar params vs sparse rich metadata)
is right; the *always-dense* params are the part we reject — our modifier/state
must cost zero when default. Sources:
[world_format.md](https://github.com/luanti-org/luanti/blob/master/doc/world_format.md),
[Luanti basic data structures](https://docs.luanti.org/for-engine-devs/basic-data-structures/),
[Nodes — Luanti API](https://api.minetest.net/nodes/).

### 1.3 Zylann godot_voxel v1.4.1 (the pinned engine module)

See §2 for the verified facts: 8 fixed channels of configurable bit depth with
per-channel **uniform compression** (an unallocated channel is just one default
value — the module's own zero-cost-default mechanism), and a sparse per-voxel
metadata `FlatMap` (sorted vector, binary search) attached to each buffer,
explicitly documented as "versatile, not fast — for special cases", i.e. the
same block-entity philosophy as 1.1/1.2.

### 1.4 Sparse volumetric structures: VDB, SVO, DAGs, brickmaps

**OpenVDB / NanoVDB** — the film/simulation SOTA: a shallow B-tree-like tree
(root → two internal levels → 8³ leaves) where absent subtrees resolve to a
*background value*; NanoVDB linearizes the whole tree into one pointer-less
contiguous buffer for GPU/cache friendliness. The background-value idea *is*
zero-cost defaults, generalized. Rejected as our container: VDB pays its
complexity to skip vast empty space in float fields at film resolutions; a
game world with a dense playable band, uniform 1 m cells and constant edits is
better served by a flat chunk grid + per-chunk palettes (VDB's own leaves are
dense 8³ arrays anyway). Sources: [openvdb.org](https://www.openvdb.org/),
[NanoVDB paper](https://dl.acm.org/doi/fullHtml/10.1145/3450623.3464653),
[OpenVDB repo](https://github.com/AcademySoftwareFoundation/openvdb).

**Sparse Voxel Octrees / DAGs** — Kämpe, Sintorn & Assarsson's
"High Resolution Sparse Voxel DAGs" merges identical SVO subtrees, compressing
static binary geometry by 1–3 orders of magnitude ((128k)³ scenes, real-time
ray tracing); follow-ups (Dado et al.) add attribute compression. Superb for
*static, read-only* geometry; edits require subtree rebuild + re-dedup, and
per-voxel attributes fight the dedup. Rejected for an editable sandbox; noted
as a future *at-rest archive* format for pristine regions. Sources:
[SVDAG paper (Chalmers)](https://www.cse.chalmers.se/~uffe/HighResolutionSparseVoxelDAGs.pdf),
[TOG](https://dl.acm.org/doi/10.1145/2461912.2462024),
[Dado et al. 2016](https://onlinelibrary.wiley.com/doi/abs/10.1111/cgf.12841).

### 1.5 Palette compression as the dominant modern technique

The generalized form of 1.1 (variable-bit-width indices + reference-counted
palette; memory scales with local variety, not world variety) is well
documented and is the community-consensus baseline for block worlds. Sources:
[voxel.wiki — Palette Compression](https://voxel.wiki/wiki/palette-compression/),
[Longor1996's original write-up](https://www.longor.net/articles/voxel-palette-compression-reddit).

### 1.6 Other Minecraft-likes

**Vintage Story** — chiseled "microblocks" (16³ sub-voxels per cell) are stored
in a **block entity**, not in the block id: per-voxel detail is treated as
rare-and-rich data. Validates our two-tier approach — a cheap 16-bit modifier
for the *common* smoothing shapes, metadata only for genuinely rich cases.
Source: [VS wiki — Chisel](https://wiki.vintagestory.at/Chisel).
**Teardown** — thousands of small object volumes, one byte per voxel indexing
an ≤ 255-entry material palette; RLE for saves; a 1-bit occupancy mirror for
shadows. Validates "tiny dense id + palette + separate derived mirrors".
Sources: [blog.voxagon.se](https://blog.voxagon.se/),
[80.lv interview](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech).
**Morton/Z-order layouts** — improve locality for random spatial access;
for our access patterns (columnar physics scans, per-column meshing) a
column-major linear order beats Morton (§6.4). Source:
[Volumes of Fun — Morton ordering for chunked voxel data](http://www.volumesoffun.com/implementing-morton-ordering-for-chunked-voxel-data/index.html).

### 1.7 Comparison table

| System | material | shape/modifier | state | metadata | default cost | edit cost | notes |
|---|---|---|---|---|---|---|---|
| Minecraft | per-section palette + bit-packed indices | folded into blockstate palette entries | folded into palette | side list of NBT block entities | **0** (absent palette entries; 1-entry palette ⇒ 0-bit array) | palette insert + possible repack | state must be low-cardinality or palette explodes |
| Luanti | dense u16 `param0` | `param2` (dense u8, always) | `param2`/`param1` | side map pos→KV + timers | params always allocated (16 KiB/MapBlock) | O(1) array write | closest semantic split; dense params rejected |
| godot_voxel | TYPE channel (16-bit), uniform-compressible | — (models per id) | — | per-buffer sparse FlatMap | **0** (uniform channel = 1 defval) | densify-on-first-write | our render mirror |
| OpenVDB/NanoVDB | tree + background value | n/a | n/a | n/a | **0** (absent subtree = background) | tree surgery | float-field SOTA, wrong fit |
| SVO-DAG | deduped subtrees | n/a | attribute streams | n/a | **0** | very high | static archives only |
| Teardown | u8 → 255-entry palette per volume | n/a | n/a | n/a | low | O(1) | many small volumes |
| Vintage Story | block id | 16³ microgrid **in block entity** | block variant | block entity | 0 (entity absent) | entity rewrite | modifier-as-metadata for rare cases |
| **VOXIVERSE (this doc)** | LRID palette + bit-packed (at rest); function+overlay (live) | sparse u16 layer, 0 = cube | sparse u16 layer, 0 | side map cell→JSON doc | **0 per cell** (§5.4) | O(1) overlay; O(log n) layer | four independent axes, each sparse-by-construction |

---

## 2. Verified engine facts (pinned godot_voxel v1.4.1)

Read from `docker/engine/cache/godot/modules/voxel/`; numbered V1… for citation
below. (The streaming doc's F1–F10 remain valid and are referenced as F1….)

| # | Fact | Source |
|---|---|---|
| V1 | `VoxelBuffer` has exactly 8 channels: `CHANNEL_TYPE(0), SDF, COLOR, INDICES, WEIGHTS, DATA5, DATA6, DATA7`. | `storage/voxel_buffer.h:24-35` |
| V2 | Each channel has independent depth (8/16/32/64-bit) and a per-channel compression state: `COMPRESSION_NONE` or `COMPRESSION_UNIFORM` ("aka no voxels allocated") — a uniform channel stores a single `defval` in a union with the data pointer; **zero heap allocation**. | `voxel_buffer.h:38-42, 100-117` |
| V3 | TYPE defaults to 16-bit depth; dense data is laid out `[z][x][y]` (Y fastest — "faster vertical-wise access, the engine is Y-up"). | `voxel_buffer.h:89-90, 100-103` |
| V4 | Per-voxel **metadata** exists per buffer: `FlatMapMoveOnly<Vector3i, VoxelMetadata>` — a sorted vector with `std::lower_bound` lookup; header comment: "expected to be sparse, with low amount of items"; `VoxelMetadata` doc: "not intended at being an efficient or fast storage method, but rather a versatile one for special cases… text, tags, inventory contents". Types: `TYPE_EMPTY`, `TYPE_U64`, custom ≥ 32. | `voxel_buffer.h:479-553`, `util/containers/flat_map.h:43`, `storage/metadata/voxel_metadata.h:11-35` |
| V5 | Metadata is script-bound end-to-end: `VoxelBuffer.{get,set}_voxel_metadata`, `for_each_voxel_metadata(_in_area)`, `clear_voxel_metadata(_in_area)`, `copy_voxel_metadata_in_area`; `VoxelTool.{get,set}_voxel_metadata` reaches it on a live terrain. Uniform/compression control is also script-bound (`is_uniform`, `compress_uniform_channels`, `get_channel_compression`, `decompress_channel`). | `storage/voxel_buffer_gd.cpp:874-914`, `edition/voxel_tool.cpp:392-396, 554-555` |
| V6 | The blocky mesher reads **only `CHANNEL_TYPE`**; a uniform TYPE channel takes a fast path; other channels are ignored entirely by the blocky pipeline. | `meshers/blocky/voxel_mesher_blocky.cpp:551, 595-653` |
| V7 | The module's data blocks are 16³ (`DEFAULT_BLOCK_SIZE_PO2 = 4`). | `constants/voxel_constants.h:54`, `storage/voxel_data_map.h:28` |
| V8 | The module's block serializer already serializes per-voxel metadata alongside channels (relevant only if we ever adopt module streams; we don't — §10). | `streams/voxel_block_serializer.cpp:43-67` |

Consequences: (a) a *second* voxel channel for the modifier is technically
available (`DATA5`) but **useless for rendering** — the blocky mesher would
never read it (V6); (b) the module's own metadata store is real but
module-path-only and Vector3i-sorted per 16³ buffer — usable as a mirror, not
as gameplay truth (§8.3); (c) uniform compression means our render mirror
already has zero-cost defaults and we must not break that.

---

## 3. The layered four-axis model

### 3.1 Semantics — what goes on which axis (the contract)

* **Material (LRID)** — substance identity. Owned by the streaming design
  (GMID ⇄ LRID, air = 0). Determines density, strengths, look. One axis, one
  id space, never multiplied by anything below.
* **Modifier** — *geometric occupancy only*: which sub-volume of the cell is
  filled and how it is oriented. Everything that changes **mass, contact area,
  collision, silhouette** is modifier. The sub-voxel corner-height shape set
  (SUB-VOXEL §2) is modifier family 0. `modifier == 0` ⇔ the cell is a plain
  full cube — the overwhelming case, by decree and by construction.
  Rotating a wedge changes its modifier (corner permutation), not its state.
* **State** — *behavioural variant of a material within an unchanged
  occupancy*: facing of a machine (a full cube either way), lit/unlit,
  powered, growth stage, half/waterlogged-style flags. State may change a
  cell's **look and sim behaviour**, never its geometry or mass. Contrast
  with material states à la ice/water/steam, which are *different VoxelStates
  and therefore different LRIDs* (streaming §2.3) — the state axis is for
  variation *below* the granularity of a VoxelState. Interpretation of the 16
  bits is per-material (§3.2).
* **Metadata** — arbitrary structured per-cell data for the rare special
  blocks: container inventories, sign text, machine progress, spawner config.
  A material must declare the capability (`has_block_entity`) for cells of it
  to carry metadata. Metadata never encodes solidity, occupancy or mass — it
  can never disagree with the scalar axes about "what is here".

The four axes are orthogonal: any (material, modifier, state) triple is
representable; validation (not representation) constrains which combinations
are *meaningful* (e.g. a ramp of water fails validation, not encoding).

### 3.2 The 16-bit fields, bit by bit

**Modifier** (family-tagged so future shape families don't re-fork anything):

```
 15  14 13 12 11 10  9   8   7  6   5  4   3  2   1  0
┌───┬──────────────────┬───┬───────┬──────┬──────┬──────┐
│FAM│    reserved = 0  │ANC│  c01  │ c11  │ c10  │ c00  │   FAM 0: corner-height family
└───┴──────────────────┴───┴───────┴──────┴──────┴──────┘   (SUB-VOXEL §2, relocated)
  FAM  = 0 today (1 = reserved: e.g. full-height plan-triangular "horizontal wedge" family)
  ANC  = anchor (0 BOTTOM, 1 TOP);  c** ∈ {0,1,2} half-block corner heights, 2 bits each
  value 0 ⇔ FULL CUBE (canonicalization: all-corners-2 BOTTOM/TOP → 0; all-corners-0 → the
  cell must be air — same rules as SUB-VOXEL §3.1, applied to this field)
```

**State** — raw 16 bits whose layout is declared by the material document
(§10.3): an ordered list of named fields packed LSB-first, e.g.
`[{facing:3}, {lit:1}, {growth:4}]`, plus a `visual_mask` marking which bits
affect appearance (§8.2). Materials with no declaration have layout `[]` and
any nonzero state is a validation error for them. Default 0 must always be a
valid, canonical "at rest" configuration (like Minecraft's blockstate
defaults).

**Metadata** — a GDScript `Dictionary` restricted to the JSON-representable
subset (String keys; values: bool/int/float/String/Array/Dictionary — no
Object refs, no NaN/INF), so it serializes canonically, transports p2p, and
can never smuggle engine references across threads or saves. Optional
per-material schema in the material document (§10.3); size caps in §16.

### 3.3 The packed cell value — one query, three scalar axes

The three scalar axes pack into **one 64-bit int** (GDScript's native int;
Variant stores it inline — no heap):

```
 bit 63      48 47           32 31           16 15            0
┌───┬──────────┬───────────────┬───────────────┬───────────────┐
│ 0 │ reserved │     STATE     │   MODIFIER    │  MATERIAL LRID│
└───┴──────────┴───────────────┴───────────────┴───────────────┘
value 0 == air (air never carries modifier/state; enforced by canonicalization)
a bare legacy id (0..65535) IS a valid packed value meaning "full cube, state 0"
— zero migration for _edits, VoxelBody.cells, and every generated id.
```

`CellCodec` (static, pure — replaces SUB-VOXEL's `ShapeCodec` packing half;
the shape *math* half of ShapeCodec survives, §13.1):

```gdscript
class_name CellCodec
const MAT_MASK  := 0xFFFF
static func mat(v: int) -> int:       return v & MAT_MASK
static func modifier(v: int) -> int:  return (v >> 16) & 0xFFFF
static func state(v: int) -> int:     return (v >> 32) & 0xFFFF
static func pack(mat: int, modifier := 0, state := 0) -> int:
    return (mat & MAT_MASK) | ((modifier & 0xFFFF) << 16) | ((state & 0xFFFF) << 32)
static func canonical(v: int) -> int  # air-zeroing + modifier canonical form + state validation hook
static func is_plain(v: int) -> bool: return (v >> 16) == 0   # full cube, state 0
```

This is how architectural rule 1 survives **strengthened**: there is exactly
one composed overlay-else-generated query returning the packed value; material,
modifier and state are three bit-projections of that one int, so they cannot
desync — there is no second lookup that could return a different answer.
Metadata cannot ride in an int; it is kept coherent by *lifecycle*, not by
packing: one write choke point owns all four axes (§7.2, §11).

---

## 4. Where the data lives — the three storage tiers

The engine already has the ultimate zero-cost-default structure: **the pristine
world is a pure function** (`TerrainConfig.generated_block` + `TreeGen`), and
only deviations occupy memory (`_edits`). The four-axis design extends that
principle through all three tiers:

```
tier 1  LIVE OVERLAY (session truth)   _edits: {Vector3i → packed int}   ← unchanged dict, richer values
                                       _meta:  {Vector3i → Dictionary}   ← new, sparse, main-thread
tier 2  GENERATED (pure function)      TerrainConfig.generated_cell(x,y,z) → packed int
                                       (terrain smoothing emits modifiers; generated state = 0;
                                        generated metadata = absent — hook reserved)
tier 3  AT REST / TRANSPORT / LOADED   ZoneChunk: per-32³ palettized material layer
        ZONES (chunk containers)       + optional sparse modifier/state/metadata layers (§5)
```

Read order (rule 1, composed): `_edits` → loaded ZoneChunk base (when the
persistence workstream lands zone loading — seam flagged §17) → generated.
Today only tiers 1–2 exist at runtime; tier 3 is the serialization format now
and becomes the in-memory base layer for streamed zones later, read **through**
its compact form (no decompression on load — §6).

### 4.1 Tier 1: the live overlay — modifier and state ride free

`_edits` stays **one** dictionary (rule 1's sparse overlay), its values become
packed cell ints. A GDScript Dictionary entry costs the same whether the value
Variant holds `3` or `3 | ramp<<16 | lit<<32` — int64s are inline. **Therefore
the modifier and state axes add exactly zero bytes to every existing and future
edit entry.** Legacy values already stored are valid packed values (§3.3).

`_meta` is a second, *lifecycle-locked* sparse dictionary. It is not a
"parallel notion of what's solid" (the SUB-VOXEL §3.2 objection): metadata
carries no occupancy semantics by the §3.1 contract, and every write path that
can change a cell's material funnels through one internal function that settles
metadata in the same call (§7.2). This mirrors Minecraft's and Luanti's proven
split (§1.1/1.2) and godot_voxel's own design (V4).

### 4.2 Tier 2: generated modifiers cost nothing forever

Terrain smoothing (SUB-VOXEL §8) makes *millions* of surface cells non-cubic —
and they will never touch any storage: `generated_cell` computes the packed
(material | modifier) from the shared heightmap deterministically. Only *edits*
to smoothed cells enter the overlay. This is the single biggest memory win of
keeping the generated world functional, and the reason the modifier axis must
be in the *generated* signature, not only the overlay.

---

## 5. Tier 3: the ZoneChunk container (exact layout, zero-cost proof)

One ZoneChunk covers **32³ = 32 768 cells** (8 module data blocks, V7 — the
mirror boundary converts; the two sizes are independent). Cell index within a
chunk is **column-major, Y fastest**: `idx = ((z << 5) | x) << 5 | y`,
`idx ∈ [0, 32767]` — fits u16 exactly, and matches both the module's `[z][x][y]`
order (V3) and every columnar physics scan (§6.4). All integers little-endian.

```
ZoneChunk payload (inside a container file/bundle that carries the id-map
header per RUNTIME-MATERIAL-STREAMING §2.6 — palette entries below are
container-local material ids resolved through that id-map):

┌ u8  version                                                        1 B
├ u8  layer_flags   bit0 MODIFIER_PRESENT  bit1 STATE_PRESENT        1 B
│                   bit2 META_PRESENT      bit3 MODIFIER_DENSE
│                   bit4 STATE_DENSE       bits5-7 reserved=0
├─ MATERIAL layer (always present — it IS the chunk) ────────────────
│  u16 palette_count n                                               2 B
│  u16 palette[n]            container-local material ids            2n B
│  if n == 1:                (uniform chunk — e.g. all air)          0 B
│  else:
│    u8  bits b ∈ {1,2,4,8,16}  = ceil(log2 n) rounded up to set     1 B
│    u32 words[⌈32768·b/32⌉]    indices packed LSB-first, never      4096·b B
│                               straddling a word (padding bits,
│                               Minecraft-1.16 style — §1.1)
├─ MODIFIER layer (only if MODIFIER_PRESENT) ────────────────────────
│  sparse form (default):
│    u16 count k                                                     2 B
│    k × { u16 cell_idx ; u16 modifier }   ascending cell_idx        4k B
│  dense form (MODIFIER_DENSE, when k would exceed 4096 — §6.3):
│    u16 palette_count m ; u16 palette[m] ; u8 bits ; packed words
│    (raw u16[32768] when m > 256)
├─ STATE layer (only if STATE_PRESENT) — identical encoding ─────────
└─ METADATA layer (only if META_PRESENT) ────────────────────────────
   u16 count j                                                       2 B
   j × { u16 cell_idx ; u32 byte_len ; UTF-8 JSON bytes }            per entry
```

In memory, a loaded ZoneChunk keeps exactly these arrays
(`PackedByteArray`/`PackedInt32Array`) and is read **through** — `get(idx)` is
a shift-and-mask on the material words plus a binary search (sparse) or index
(dense) on the optional layers. No inflation to 32768-entry dictionaries, ever.

### 5.1 Why per-axis layers, not one tuple palette (analyzed & rejected)

Minecraft's approach — palettize the whole (material, modifier, state) tuple —
was evaluated. For a 32³ chunk with a 4-material terrain and 5 % smoothed
surface cells over ~13 distinct shapes: distinct tuples ≈ 4 + 4×13 ≈ 56 →
6-bit indices for **all** 32 768 cells = 24 576 B. The layered form: 2-bit
material indices (8 192 B) + sparse modifier (1 638 × 4 B = 6 552 B) =
14 752 B — **40 % smaller**, because non-default axes are *spatially sparse*
and a tuple palette taxes every cell for combinations it doesn't use. Worse,
our state axis is freeform 16-bit (a growth counter or damage value would mint
a palette entry per distinct value — palette explosion), and every furnace
toggle would mutate the palette. Minecraft survives tuple palettes only
because its state space is deliberately tiny per block. Layered wins on our
requirements; the dense-palettized *escalation* of a single layer (§6.3)
recovers the tuple-palette behaviour exactly where it is optimal.

### 5.2 Why not RLE / interval trees

Column RLE compresses pristine terrain beautifully but degrades under scattered
edits (the exact workload of a sandbox), makes random access O(runs), and we
never store pristine terrain anyway (tier 2 is a function). Rejected for the
live path; permitted later as an *outer* compression (zstd/deflate over the
whole payload at rest, like Luanti's zlib) without changing this layout.

### 5.3 Why not the module's own streams/metadata as the store

Module streams (V8) and buffer metadata (V4/V5) exist only on the module path —
the GDScript fallback has no VoxelBuffers at all. Rule 3 (two paths, one
behaviour) therefore forces the authoritative store to be engine-side GDScript
either way; anything buffer-resident would be a *second* copy needing sync. The
buffers stay what they are today: a **render mirror** (§8).

### 5.4 The zero-cost-default proof

*Claim:* a cell whose modifier = 0, state = 0, metadata = absent consumes zero
bytes on every tier beyond its material; a chunk of only such cells carries no
modifier/state/metadata storage beyond ≤ 3 constant bytes of flags.

* **Tier 1:** modifier/state live in bits 16–47 of the already-existing int64
  Variant → 0 extra bytes per entry (§4.1). `_meta` holds entries only for
  cells with metadata → a metadata-free world has an empty dictionary (one
  object, O(1)).
* **Tier 2:** a function; 0 bytes for everything, defaults included.
* **Tier 3:** `MODIFIER_PRESENT/STATE_PRESENT/META_PRESENT` are 0 → the three
  layers contribute **no bytes at all**; the only per-chunk constant is the
  `layer_flags` byte (+ the version byte that exists anyway). Within a present
  sparse layer, default cells simply have no (cell_idx, value) pair — cost is
  O(non-default cells), exactly.
* **Render mirror:** no new channels are allocated (V6 → a modifier channel
  would be dead weight; §8 keeps TYPE-only), so uniform blocks keep
  `COMPRESSION_UNIFORM` (V2) — byte-identical memory behaviour to today.

The claim is per-cell-exact and per-chunk-O(1). There is no configuration in
which a default value allocates.

### 5.5 Memory budget (bytes per 32³ chunk)

| scenario | material layer | modifier | state | metadata | total (serialized) |
|---|---|---|---|---|---|
| all air (uniform) | 5 B (1-entry palette, 0-bit) | 0 | 0 | 0 | **~7 B** |
| all-cube terrain (air+grass+dirt+stone, 4-entry palette, 2-bit) | 8 203 B | 0 | 0 | 0 | **~8.2 KiB** |
| 5 % smoothed surface (1 638 shaped cells, sparse) | 8 203 B | 6 554 B | 0 | 0 | **~14.7 KiB** |
| chest-heavy build (200 containers ≈ 700 B JSON each; some placed blocks → 8-entry palette, 3→4-bit) | 16 396 B | 0 | ~200×4 B if oriented | ~140 KiB | **~157 KiB** (metadata dominates — same shape as Minecraft chunks full of chests) |
| adversarial worst (every cell distinct material + checkerboard 16-bit modifiers + states) | 64 KiB + 64 KiB palette | 64 KiB raw | 64 KiB raw | capped (§16) | **≤ ~256 KiB + meta cap** — bounded, no unbounded blowup |

Live-overlay costs (tier 1, per *edited* cell): one Dictionary entry
(~60–90 B real cost in Godot's Dictionary including Variant key+value and load
factor) — **unchanged from today**; per metadata-bearing cell additionally its
Dictionary document.

Render mirror (module path): unchanged from today — 16-bit TYPE per 16³ block =
8 KiB dense, 0 B uniform (V2); a 32³ region ≈ 64 KiB dense worst case. No new
channel is ever allocated by this design.

---

## 6. CPU / access-cost analysis (WASM-first)

Context: web export runs interpreted GDScript on the main thread + exactly one
voxel worker (module path); no SIMD, no mmap, pthread pool fixed at startup;
every byte of working set fights the wasm heap and a smaller effective cache.

### 6.1 Random point queries (the physics hot path)

`cell_value_at(cell)` = one Dictionary lookup (Vector3i hash — the dominant
cost, same as today's `block_id_at`) then, on miss, `generated_cell` (heightmap
noise + smoothing corners; SUB-VOXEL §8 already budgets this; per-column
memoization in loops). Extracting modifier/state from the hit is two
shifts+masks — **free relative to the hash**. Rule-1 queries
(`floor_under`, `blocked`, DDA, collapse) gain zero new lookups: they already
call the composed query; they now just read more bits of the same int.

ZoneChunk random get (tier 3, when zones land): material = shift/mask +
palette index (O(1)); modifier/state = binary search over ≤ 4 096 sorted u16
pairs — ≤ 12 comparisons over a contiguous `PackedInt32Array`, cache-resident
(16 KiB worst). In interpreted GDScript this is ~1–2 µs on wasm; acceptable
because physics reads overwhelmingly hit tiers 1–2.

### 6.2 Meshing sweeps (the throughput path)

The fallback mesher iterates columns of a chunk. Two rules keep the sparse
layers from becoming a per-cell binary-search tax:

1. **Sweep-order = storage-order.** Layer pairs are sorted by the same
   Y-fastest column-major `cell_idx` the sweep uses, so a mesh pass consumes
   each layer with a *single monotonic cursor* (amortized O(1) per non-default
   cell, zero lookups for default cells) — the classic merge-join, not 32 768
   binary searches.
2. **Emptiness is one branch.** `layer == null` (flags bit clear) short-circuits
   the entire enrichment path; the all-cube chunk meshes on a code path
   byte-identical to today's.

Module-path meshing is C++ and reads only the TYPE mirror (V6) — its cost is
unchanged; enrichment enters as different model ids (§8), which the blocky
mesher treats exactly like today's ids.

### 6.3 Edits, inserts, and the sparse→dense escalation

Overlay writes stay O(1) (dict store). ZoneChunk layer insert = binary search +
`PackedInt32Array` insert (memmove of ≤ 16 KiB — microseconds). To bound the
memmove *and* the memory curve, a layer **escalates to dense** when its count
exceeds 4 096 (12.5 % — the exact crossover where 4 B/entry sparse meets 4-bit
dense palettized: 4096×4 B = 16 KiB = 32768×4 bit), and never de-escalates
in-session (compaction happens at the serialization boundary, mirroring the
LRID compact-on-save rule). Material palette growth: bit-width bumps through
{1,2,4,8,16} cost one O(chunk) repack each — at most 4 repacks in a chunk's
lifetime, ~10–30 µs each in packed-array ops.

### 6.4 Neighbour lookups & cache behaviour

6-neighbour reads in a ZoneChunk: ±Y = ±1 in `cell_idx` (adjacent bytes — the
common case for support/collapse logic is vertical), ±X = ±32, ±Z = ±1024;
cross-chunk resolves through the chunk dictionary (one hash per boundary
crossing, amortized by the 32³ chunk size). Column-major-Y beats Morton for
this engine because *every* hot loop (floor scans, column stackup, collapse
bounds, greedy tops, the module's own `[z][x][y]`) is columnar; Morton's
locality advantage only materializes for isotropic random access we don't have
(§1.6). WASM note: the 16 KiB sparse arrays and 8 KiB index words sit
comfortably in L1/L2 even on constrained browser targets; the Dictionary-based
overlay is the *worst* cache citizen in the system — unchanged from today, and
the reason tier 3 exists for scale.

### 6.5 What gets slower, honestly

* `generated_cell` (with smoothing) costs ~4 extra `height_at` samples per
  *surface* cell — SUB-VOXEL's cost, restated here because the packed query
  makes it ubiquitous. Mitigated by per-column corner memoization.
* Every `break/place` now canonicalizes a packed value (a handful of masks) and
  settles `_meta` (one dict erase on the common path). Negligible.
* Nothing else: default-value cells add no work anywhere, by the same
  absence-of-structure argument as the memory proof.

---

## 7. The revised cell-access API (rule 1 survives)

### 7.1 Queries

```gdscript
# WorldManager — THE composed query and its projections. One lookup, all axes.
func cell_value_at(cell: Vector3i) -> int:          # packed mat|modifier|state
    var e: int = _edits.get(cell, -1)
    if e >= 0:
        return e                                    # overlay (already canonical)
    # [zone base layer here when persistence lands — seam §17]
    return TerrainConfig.generated_cell(cell.x, cell.y, cell.z)

func block_id_at(cell) -> int:  return CellCodec.mat(cell_value_at(cell))       # UNCHANGED contract
func modifier_at(cell) -> int:  return CellCodec.modifier(cell_value_at(cell))
func state_at(cell) -> int:     return CellCodec.state(cell_value_at(cell))
func cell_solid(cell) -> bool:  return block_id_at(cell) != BlockCatalog.AIR    # unchanged

func metadata_at(cell: Vector3i) -> Dictionary:     # {} when absent; treat as read-only
    return _meta.get(cell, EMPTY_META)
func state_field(cell: Vector3i, field: StringName) -> int   # decodes via the material's state_layout
```

`block_id_at` remains THE material query with its exact current signature and
meaning — every existing call site (floor, DDA, collider, collapse, mesher,
catalog checks) compiles and behaves unchanged, because a bare id *is* a
canonical packed value (§3.3).

### 7.2 Writes — one choke point

```gdscript
# The ONLY function that mutates a cell. break/place/collapse/state-changes all route here.
func _write_cell(cell: Vector3i, packed: int, meta: Variant = null) -> void:
    packed = CellCodec.canonical(packed)
    var old_meta: Variant = _meta.get(cell)
    if old_meta != null:
        _meta.erase(cell)                       # ANY write settles metadata (leak-proof by construction)
        metadata_orphaned.emit(cell, old_meta)  # gameplay decides spillage (chest contents, …)
    if meta != null and BlockCatalog.has_block_entity(CellCodec.mat(packed)):
        _meta[cell] = meta
    _edits[cell] = packed
    _paint_cell(cell, packed)                   # render mirror (§8/§9)

func set_state(cell, new_state) -> bool        # read-modify-write of bits 32..47, KEEPS metadata
func set_metadata(cell, meta) -> bool          # only on has_block_entity materials; keeps scalar axes
```

The invariant that makes metadata leak-proof: **writing a cell's packed value
erases its metadata unless the same call provides new metadata**; `set_state`
and `set_metadata` are the two surgical exceptions that by construction cannot
change the material. `break_terrain` returns the broken material id as today
and the orphaned metadata travels by signal — the hotbar contract is untouched.

---

## 8. godot_voxel integration (module path)

### 8.1 The resolved double-claim: appearance ids (ARIDs) in the TYPE channel

The tension: material streaming assigns LRIDs 0..65535 to the 16-bit TYPE
channel; SUB-VOXEL §4.1 wanted the *same* channel to carry a
`(material × 162 shapes)` product via `lib_id = 1 + (mat−1)·S + shape` —
capping materials at ~404 and pre-baking 162 models per material. **This design
replaces that formula.**

Recognize what the TYPE channel actually is in this architecture: a **render
mirror** that gameplay never reads (rule 1 routes everything through
`WorldManager`). So the value in TYPE does not need to *be* the LRID — it needs
to deterministically select a baked model. Define:

> **ARID (Appearance Render ID)** — a session-local, append-only dense id, one
> per **(LRID, modifier, state & visual_mask)** combination *actually in use*,
> equal by construction to its `VoxelBlockyLibrary` model index. ARIDs never
> serialize, never cross sessions or peers — exactly the LRID rules, one layer
> up.

Allocation: the same single main-thread loader that owns LRIDs owns the ARID
table. Registering a material allocates its **plain-cube ARID immediately**
(cube model appended, per streaming §3.1); shaped/visual-state ARIDs are
allocated **lazily on first use** (generator manifest, `place_block`, or
`set_state`), appending a `VoxelBlockyModelMesh` built from `ShapeMesh` and
riding the existing batched `bake()` (streaming F2/F9 economics unchanged).

```gdscript
# module_world.gd / AppearanceTable (main-thread writer, voxel-worker reader)
var _cube_arid: PackedInt32Array   # LRID -> ARID, preallocated 65536; O(1); worker-readable
var _gen_arid:  PackedInt32Array   # (manifest slot) -> ARID, frozen at path activation; worker-readable
var _arid_by_key: Dictionary       # (lrid | modifier<<16 | vstate<<32) -> ARID; MAIN THREAD ONLY
func arid_of(lrid: int, modifier: int, vstate: int) -> int   # main thread; -1 if not yet baked
```

Cross-thread rule: the generator (voxel worker) reads **only** the two
preallocated packed arrays — `_cube_arid` and the manifest-frozen `_gen_arid`
(built and frozen before the render path activates, §8.3). It never touches
`_arid_by_key`: a growing Dictionary may rehash/reallocate under a concurrent
reader. Lazily allocated player-placed combos are main-thread-only by
construction (`set_cell` runs on the main thread).

Anti-drift: the streaming doc's deadly failure ("library order drift recolours
the world") keeps its guard, generalized — **`add_model()`'s returned index
must equal the ARID being allocated**, asserted at every append; violation
hard-disables streaming exactly as streaming §8 specifies. Bootstrap materials
register first and in const order, so ARIDs 1..5 == LRIDs 1..5 == today's
model ids: **an all-cube world produces byte-identical TYPE buffers to today**
(regression gate, §15). For later materials the cube ARID may drift from the
LRID — harmless and invisible, because *nothing outside the module mirror ever
sees an ARID*.

Capacity: one 16-bit space holds materials-in-use + shaped-combos-in-use +
visual-state-combos-in-use, bounded by *usage* (thousands), not by a product
(404×162). Exhaustion policy: refuse new combos loudly, render the material's
plain-cube ARID as fallback (wrong silhouette, correct substance, logged) —
never a hole (F5 remains the deeper safety net).

### 8.2 What flows where

```
generator (voxel worker):  generated_cell → (mat, modifier) → arid_of() → TYPE      [manifest-gated]
set_cell (main thread):    packed value   → arid_of()      → VoxelTool.set_voxel(TYPE)
sim / physics / HUD:       NEVER read TYPE — they read WorldManager (rule 1/2)
modifier/state/metadata:   authoritative in the GDScript-side store (§4) — NOT in any channel
```

**Option analysis — a second VoxelBuffer channel (DATA5) for the modifier was
considered and rejected:** the blocky mesher reads only TYPE (V6), so a
modifier channel renders nothing; the fallback path has no buffers, so the
GDScript-side store must exist anyway (rule 3), making the channel a pure
duplicate with a sync obligation and extra per-block memory that breaks
uniform compression on any edit. Same verdict for the module's per-voxel
metadata FlatMap (V4/V5): module-only, per-16³-buffer keyed, and lost unless we
adopt module streams — usable *only* as an opt-in debug mirror. The parallel
GDScript-side sparse store is the single mechanism serving both paths.

### 8.3 Threading (the single web voxel worker)

Writers: main thread only (loader/edits). Cross-thread readers: the runtime
generator on the voxel worker calls `TerrainConfig.generated_cell` (pure math,
warmed at setup as today), `ShapeCodec` tables (built in `ensure_ready`,
read-only after), and `arid_of` — the same publish-before-use discipline as the
dynamic BlockCatalog (streaming §6.1): `_cube_arid` preallocated to fixed
capacity (256 KiB, never resized), rows fully written *before* the published
count/manifest admits them, and the **appearance manifest gate** extends
streaming §6.5: the render path activates only after every (material, modifier)
pair the generator can emit is registered *and* baked. The generator never
reads `_edits`, `_meta` or ZoneChunks — nothing mutable crosses the thread.
Bake keeps its RWLock story (F3): one batched bake per arrival burst, worst
case a bounded main-thread hitch, no new lock parties introduced by this
design.

---

## 9. Fallback-path integration

`ChunkMesher` swaps its per-cell read to `cell_value_at`:

* `modifier == 0` cells take today's cube path (greedy top-merge keys extend
  with "modifier == 0", exactly SUB-VOXEL §4.2 — flat terrain output is
  byte-identical to today).
* Shaped cells emit `ShapeMesh.build(modifier)` geometry — the one shared
  geometry source both paths consume (rule 3 by construction).
* Visual state selects the surface material:
  `BlockMaterials.get_for_state(lrid, state & visual_mask)` — a cached variant
  per (LRID, visual bits) sharing the base texture (tint/glow/frame variants),
  the fallback twin of the ARID mechanism. Mask 0 (the default) hits the
  existing `get_for(lrid)` path untouched.
* Metadata is invisible to the mesher, by contract (§3.1).

`GroundCollider` and all analytic physics already read through `WorldManager`;
they consume the modifier via `ShapeCodec.local_top/occupied/contact_area`
(SUB-VOXEL §5 unchanged, just re-keyed to the modifier axis — §13.1) and are
path-agnostic by rule 1.

---

## 10. Streaming & serialization integration

### 10.1 Identity is untouched (the non-negotiable)

Modifier, state and metadata are **outside material identity**: GMIDs hash the
same material documents; LRIDs mean what they meant; the id-map header
(streaming §2.6) maps *materials only*. A grass ramp is grass. Nothing in the
three new axes is ever id-mapped, because their values are position-scoped
raw data (modifier: geometry code; state: material-relative bits; metadata:
self-describing JSON), not references into an id space.

### 10.2 Containers grow per-cell layers, not per-material documents

A save / p2p zone bundle = id-map header + a sequence of ZoneChunk payloads
(§5) + the sparse overlay tail for unchunked data (edit overlay, loose bodies,
inventory — all unchanged formats, except overlay values are now packed 48-bit
ints written as u64 and loose bodies carry packed values, which they already
do per SUB-VOXEL §9). Chunk material palettes double as the container-local
compact ids — the streaming doc's "compact on save" rule and the palette are
*the same mechanism*, one per chunk. State bits travel raw alongside the
material reference; because state layout is declared by the material document
(immutable per GMID), interpretation travels with identity and cannot alias
across versions — a changed layout is a new document, hence a new GMID.

### 10.3 Material-document extensions (forward-compatible keys)

```json
{
  "state_layout":  [ {"name": "facing", "bits": 3}, {"name": "lit", "bits": 1} ],
  "visual_mask":   7,
  "has_block_entity": true,
  "metadata_schema": { "inventory": "array", "label": "string" }
}
```

Unknown keys are already ignored by ingest validation (streaming §5.2), so old
documents keep their GMIDs and old engines skip the new keys. Defaults:
`state_layout: []`, `visual_mask: 0`, `has_block_entity: false`.

---

## 11. Edit overlay, VoxelBody, inventory — axis lifecycles

| event | material | modifier | state | metadata |
|---|---|---|---|---|
| `break_terrain` (player mines the cell) | returned to caller → inventory | **not kept as shape**: inventory credits `density × volume(modifier)` worth of the material (SUB-VOXEL §9's volume-conservation rule — no duplication exploit, no per-shape inventory identity) | dropped (item form has no state, as in Minecraft for most states) | erased + `metadata_orphaned` signal → gameplay spills contents as pickups |
| collapse detaches a cluster | `comp_ids` captures the **full packed value** — a detaching slope keeps its ramp faces, orientation and reduced mass in the `VoxelBody` (mass = Σ density × volume(modifier)) | kept (in packed value) | kept (in packed value — a falling lit furnace stays lit-looking) | **erased + orphan signal** (v1): tumbling rigid bodies do not carry live containers; re-attachment semantics and body serialization stay simple. Flagged as a v2 candidate (carry meta in the body and restore on freeze-in-place) |
| `place_block` | writes packed value (validation: material range-check on masked LRID; modifier canonicalized; state validated against layout) | player-chosen shape/orientation | placement default (0) or oriented via `state_layout.facing` from player facing | created only for `has_block_entity` materials, empty document |
| `set_state` (machines, growth) | unchanged | unchanged | RMW bits 32..47 | **kept** (the one write that preserves it) |
| chunk unload / zone eviction | compacted into ZoneChunk layers | 〃 | 〃 | serialized entries; in-memory dict entries freed |

---

## 12. Determinism & threading summary

* No wall-clock, no RNG anywhere in the four-axis machinery; smoothing
  modifiers are hash-of-position deterministic (SUB-VOXEL §8), state changes
  are event-driven through the sim, metadata mutations are gameplay events.
* Session-local structures (ARIDs) are deterministic given load order but
  never serialized — cross-session/cross-peer agreement rests only on
  GMIDs + raw modifier/state/metadata, which are order-independent.
* Thread map (web): main thread owns `_edits`, `_meta`, ZoneChunks, catalog,
  ARID table (writer); the single voxel worker reads only immutable-after-warm
  statics + the publish-gated ARID/catalog rows (§8.3). The fallback path is
  entirely main-thread. No new locks, no shared mutable collections.
* JSON metadata forbids NaN/INF and non-string keys → byte-stable round-trips.

---

## 13. Exact revisions forced on sibling documents

### 13.1 `docs/SUB-VOXEL-SMOOTHING.md` (this doc supersedes its §3 encoding)

1. **§3.1 bit layout replaced.** Shape+anchor move from cell-int bits 16..24
   into the **modifier axis** (bits 0..8 of the 16-bit modifier field; cell
   packed value = `mat[0..15] | modifier[16..31] | state[32..47]`, §3.3 here).
   The canonicalization rules (FULL ⇔ 0, all-corners-0 ⇒ air, corner-value-3
   clamp) survive verbatim, applied to the modifier field.
2. **`ShapeCodec` splits.** Packing/projection (`mat`, `shape`, `pack`,
   `canonical`, `is_full`) migrate to `CellCodec` (operating on the 64-bit
   cell value and the 16-bit modifier). The geometry/physics math
   (`volume`, `local_top`, `occupied`, `side_profile`, `contact_area`,
   `surface_tris`, LUTs) stays in `ShapeCodec`, **re-keyed to take a 16-bit
   modifier** instead of a 9-bit shape field.
3. **§4.1's static `lib_id(mat, shape) = 1 + (mat−1)·S + shape` is deleted**,
   along with its 404-material cap and the 162-models-per-material pre-bake.
   Replaced by lazy ARID allocation (§8.1 here); the roundtrip asserts retarget
   the ARID table (`add_model index == ARID`). The generator and `set_cell`
   write ARIDs.
4. **§3.1 reserved bits repurposed.** "bits 25..31 reserved (reinforcement,
   damage, 3rd family)" — future families use modifier bit 15 (FAM); scalar
   per-cell stats (damage, growth) belong on the **state axis**; per-joint
   reinforcement stays in `_joint_mods` (structural doc §7), outside all four
   axes.
5. **§3.2's streaming SEAM is resolved** as material-id-space-never-forks +
   ARIDs (no coordination on bit widths needed anymore); delete the "if
   streaming needs >16-bit ids the shape field shifts up" contingency.
6. **§10 verify items 1 and 6** retarget `CellCodec`/ARID roundtrips; §9's
   packed capture in `comp_ids` now naturally includes state.

### 13.2 `docs/RUNTIME-MATERIAL-STREAMING.md`

1. **§4.5 sharpened:** the "reserved upper band" model library rule is replaced
   by the ARID table (§8.1 here) — shape/state-visual models interleave in one
   append-only model space; the invariant becomes `add_model() == ARID`, with
   `cube ARID == LRID` asserted for the bootstrap set only.
2. **§3.1's `can_render_id(lrid)`** generalizes to
   `can_render(arid)` / `can_render_cell(mat, modifier, vstate)`; the paint
   gate in `_paint_cell` checks the composed appearance, not the bare LRID.
3. **§6.5 generator manifest** extends from a material set to an **appearance
   set**: the (material, modifier) pairs worldgen can emit, registered + baked
   before path activation.
4. **§2.6 container format:** payloads adopt ZoneChunk layers (§5 here);
   chunk material palettes are the container-local ids (one palette per chunk
   instead of one flat id remap per container body). Id-map header unchanged.
5. **§5.2 document schema:** add the three forward-compatible keys of §10.3.
6. **Decision log #4** amended accordingly (append+batched-bake mechanics and
   all bake-cost analysis are unchanged and now also cover ARID model appends).

### 13.3 `docs/STRUCTURAL-INTEGRITY.md` (seam kept intact, one re-keying)

`fill_fraction` and the contact-area factor now derive from the **modifier
axis**: mass = `density(LRID) × ShapeCodec.volume(modifier)`; the solver's
`contact_area(cell_a, cell_b, axis)` reads `modifier_at` through the composed
query. Its `_joint_mods` per-joint reinforcement store is *not* absorbed into
these axes (it is per-face, not per-cell) — explicitly unchanged. Its §7 note
that streaming must carry `strength_anchors`/`structural_class` is unaffected
(those are material-document physics fields, not per-cell data). **Assumption
flagged to that workstream:** temperature-dependent attachment reads state
*only* via PerVoxelEnvironment, never via the state axis — if a future material
wants a "weakened" flag, it is a state bit the solver may read through
`state_field`, not a new store. `attachment` on `VoxelState` is the **joint
participation multiplier** per INTEGRATION-DECISIONS §1.4 (default 1.0;
sand/gravel 0.0); the catalog's scalar `A` column is superseded/deleted.

---

## 14. Phased implementation plan

1. **P0 — CellCodec + packed overlay (no behaviour change).** `CellCodec`,
   `_edits` documented as packed (all existing values already canonical),
   `cell_value_at` + projections, `_write_cell` choke point. Every existing
   test green; verify adds projection-coherence + canonicalization tests.
2. **P1 — metadata store + lifecycle.** `_meta`, `has_block_entity` gate,
   orphan signal, `set_metadata`/`set_state` (state still always 0 in
   content). Verify: leak tests (§15.3).
3. **P2 — ZoneChunk container.** Writer/reader for §5 layouts, sparse→dense
   escalation, integration with the streaming container (id-map header);
   compact-on-save. Verify: zero-cost assertions + round-trips (§15.1/2).
   *(Aligns with streaming Phase 3.)*
4. **P3 — module ARID table + modifier rendering.** AppearanceTable, lazy
   model append + batched bake, appearance manifest gate, `set_cell`
   translation; fallback mesher shaped cells. *(Joint PR with SUB-VOXEL P3;
   live-site gate: web export loads, all-cube world byte-identical buffers.)*
5. **P4 — state machinery.** `state_layout`/`visual_mask` parsing,
   `get_for_state` variants + visual-state ARIDs, oriented placement.
   Benchmarks: meshing sweep with 5 % shaped cells (both paths, native + web),
   ARID bake batching under a burst.

---

## 15. verify_feature.gd invariants (new `_test_enriched_cells` block)

1. **Zero-cost default (the crux, asserted three ways):**
   (a) serialize a pristine all-cube 32³ region → `layer_flags & 0b1110 == 0`
   and payload size == material-layer-only baseline (exact byte count);
   (b) after a session of plain-cube place/break edits, every `_edits` value
   satisfies `CellCodec.is_plain(v)` (bits 16..63 all zero) and
   `_meta.is_empty()`;
   (c) module path: an all-cube world's TYPE buffers are byte-identical to a
   pre-change golden sample (ARID == LRID for bootstrap), and no non-TYPE
   channel of any sampled buffer is `COMPRESSION_NONE`.
2. **Round-trip:** build a region mixing shaped cells (every canonical shape ×
   2 materials), states, and metadata docs → serialize → load into a fresh
   store with shuffled material load order → per cell: GMID-level material
   equality, exact modifier/state equality, deep-equal metadata.
3. **Metadata lifecycle:** place a `has_block_entity` cell + metadata; (a)
   `break_terrain` → `metadata_at == {}`, `_meta` has no key, orphan signal
   fired once with the doc; (b) collapse-undercut the cell → same; (c)
   `set_state` on it → metadata retained; (d) placing metadata on a
   non-entity material fails.
4. **Projection coherence:** for random cells (edited, generated-smoothed,
   air): `block_id_at == mat(cell_value_at)` etc.; `cell_solid` unchanged
   against a pre-change golden sweep.
5. **ARID discipline (module only):** allocating a shaped combo returns
   `add_model index == ARID`; `arid_of` is idempotent; one bake per burst of N
   combo registrations (counter == 1); exhaustion path renders the cube
   fallback and logs.
6. **Escalation:** insert 4 097 distinct-position modifiers → representation
   flips to dense, all values preserved, byte size within the §5.5 dense
   budget; below threshold stays sparse.
7. **Volume conservation across axes:** break a shaped cell → inventory volume
   credit equals `volume(modifier)`; a collapsed shaped cluster's VoxelBody
   mass equals Σ `density × volume(modifier)` (re-anchors SUB-VOXEL verify 2
   to the modifier axis).

---

## 16. Adversarial review — how this breaks

* **Palette thrash.** An attacker (or a mad builder) cycling many distinct
  materials in one chunk forces bit-width repacks — bounded at 4 repacks and a
  ≤ 128 KiB worst-case material layer (§5.5); palettes never shrink in-session
  so there is no repack oscillation. Residual: a *peer-supplied* chunk can
  declare palette_count up to 32 768 → reader must bounds-check palette ids
  against the id-map and cap `bits` at 16, else a crafted payload
  over-allocates. Validation rule added to the container reader.
* **Sparse-map cache misses at meshing time.** The failure mode is per-cell
  binary search inside the sweep; designed out by cursor merge-join over
  sweep-ordered layers (§6.2) — the verify benchmark (P5) asserts the sweep
  does O(k), not O(32768·log k), by instrumented counter.
* **Metadata leak on overwrite/break.** Designed out at the single choke point
  (§7.2): there is no code path that changes a cell's material and skips
  metadata settlement, because there is only one write function. The
  remaining leak surface is *chunk-level* bulk ops (zone unload, bulk inject):
  both must route through layer-aware writers, and verify 15.3 covers the
  collapse path, historically the easiest to forget.
* **Memory blowup under adversarial edits.** Scalar layers are hard-bounded
  (dense escalation caps each at 64 KiB/chunk). Metadata is the unbounded axis
  by nature → caps: 16 KiB serialized per cell, 1 MiB per chunk, enforced at
  `set_metadata` (refuse, log) and at container load (reject chunk). The
  chest-heavy legit case (~140 KiB) sits comfortably inside.
* **Cross-thread reads of a growing store.** The voxel worker reads the ARID
  fast-path array while the main thread grows it: prevented from reallocating
  (preallocated fixed capacity, §8.3) and from torn rows (publish-count-last +
  manifest gate). The worker *never* touches `_edits`/`_meta`/ZoneChunks —
  asserted in dev by a thread-guard in their accessors. The known residual is
  inherited from streaming §6.1 (a future contributor adding a worker-side
  catalog read before publish) — same countermeasure, same assert.
* **Id-width overflow.** Materials: 16-bit LRID space unchanged (65 536,
  practically ~10 k — streaming §7.4). ARIDs: usage-bounded; exhaustion
  degrades to cube-appearance + loud error, never data loss (the modifier is
  still stored — only its *look* degrades). Modifier/state: fixed 16-bit by
  spec; family bit 15 reserves the escape hatch for a wider shape space
  *without* touching stored data (FAM 0 values are stable forever).
* **State-bits misinterpretation across material versions.** A document
  changing its `state_layout` is a new GMID (identity = bytes), so stored
  state bits can never be re-read under a different layout. The subtle case is
  a *placeholder* (UNRESOLVED) material whose cells hold nonzero state: layout
  unknown → `state_field` returns raw-bits-only until resolution; behaviour is
  provisional exactly like placeholder physics (streaming §8) — acceptable,
  same degradation contract.
* **The `is_plain` fast path lying.** If any writer stores a non-canonical
  packed value (e.g. all-corners-2 "FULL" with nonzero bits), equality tests
  and the zero-cost assertions break silently. Countermeasure: `_write_cell`
  canonicalizes unconditionally, and verify 15.1(b) sweeps `_edits` for
  canonical form after a scripted edit session.
* **Composed-query bypass.** The historical risk of rule 1 — someone reads
  `_edits` directly (it is exposed via `placed_cells()`) and forgets the high
  bits. Mitigation: `placed_cells()` documented as packed + a grep-gate in
  review; longer term, return a masked view for the fallback mesher's
  placed-cell pass (it needs materials only).

---

## 17. Flagged assumptions about siblings

1. **Persistence/p2p workstream** owns: when ZoneChunks become a live base
   layer under `_edits` (§4 read order), zone↔overlay merge semantics, and the
   outer at-rest compression (§5.2). This doc fixes the payload format only.
2. **WORLDGEN-CATALOG** emits `state_layout`/`visual_mask`/`has_block_entity`
   in its documents (§10.3) and enumerates its worldgen **appearance** manifest
   (materials × smoothing shapes) per §13.2-3.
3. **Structural integrity** consumes `volume(modifier)` / `contact_area` per
   §13.3 and keeps `_joint_mods` outside the four axes.
4. **Textures workstream:** visual-state variants (`get_for_state`) reuse the
   per-LRID Material instance family and the in-place texture-swap contract —
   variants must not break eviction (streaming §7.3).
5. **SUB-VOXEL** adopts the §13.1 revisions; its shape *math*, smoothing
   scheme, physics upgrades and verify plan are otherwise unchanged and remain
   authoritative for the corner-height family.

---

## 18. Decision log (locked by this doc)

1. **Four orthogonal axes; material identity never forks.** Modifier = 16-bit
   geometry (0 = cube), state = 16-bit material-interpreted variant bits
   (0 = default), metadata = JSON-subset document (absent = default).
2. **One packed 64-bit cell value** (`mat | modifier<<16 | state<<32`) behind
   the single composed query; bare legacy ids are valid packed values (zero
   migration). Metadata coherent via the single write choke point.
3. **Zero-cost defaults by absence at every tier:** pure-function world,
   free-riding overlay bits, per-axis optional chunk layers (sparse pairs ↔
   palettized dense at the 12.5 % crossover), uniform-compressed render
   mirror. Zero bytes per default cell; ≤ 3 flag bytes per chunk.
4. **TYPE channel carries session-local ARIDs** (appearance ids, lazily
   allocated per used (material, modifier, visual-state) combo, model index ==
   ARID asserted); material keeps its full 16-bit LRID space; ARIDs never
   serialize. SUB-VOXEL's static lib_id formula is retired.
5. **Modifier/state/metadata live in the path-agnostic GDScript store**, never
   in extra VoxelBuffer channels or module metadata (render-dead, module-only,
   duplicate-sync — rejected on all three grounds).
6. **Containers extend with per-cell layers, not per-material documents**;
   chunk palettes are the container-local material ids; state semantics travel
   with the GMID.
7. **Lifecycle table (§11) is contract:** shapes survive collapse in bodies;
   broken shapes credit volume; metadata orphans via signal and never rides
   rigid bodies (v1).
