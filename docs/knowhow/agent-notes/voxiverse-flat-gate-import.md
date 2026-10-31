---
name: voxiverse-flat-gate-import
description: verify_feature FLAT shows 15 texture failures in a fresh worktree until godot --import is run
metadata: 
  node_type: memory
  type: reference
---

A fresh `git worktree` (or checkout) has NO imported block textures in `.godot`, so verify_feature.gd reports **6020/15** — exactly 15 texture-import assertions fail: grass/dirt/stone/wood/leaf × {is textured / is 128x128 / uses NEAREST filter}. These are NOT a code regression and are unrelated to whatever you changed.

**Fix / how to get the true 6035/0:** run `docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import` ONCE in the worktree to build the `.godot` import cache, then verify_feature returns 6035/0.

**Byte-identity check:** the count is stable given a fixed import state, so a change is byte-identical iff the FLAT count is the SAME with and without the change (e.g. 6035/0 vs 6035/0, or 6020/15 vs 6020/15) — don't chase the 15 if they pre-exist on the base in the same worktree. Also always `git checkout -- godot/src/cosmos/cube_sphere.gd` before a FLAT run so a leftover sed FACETED=true toggle (needed for verify_faceted/verify_fixed_frame) doesn't contaminate it. See [[voxiverse-gdscript-closure-trap]].
