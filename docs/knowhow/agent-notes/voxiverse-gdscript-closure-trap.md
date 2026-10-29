---
name: voxiverse-gdscript-closure-trap
description: "GDScript lambdas capture by value — headless verify_*.gd drivers must use inline loops, not closures"
metadata: 
  node_type: memory
  type: feedback
---

In GDScript, lambdas (`func(x): ...`) capture enclosing locals BY VALUE and mutations inside do NOT persist across calls. A per-tick driver like `func(_i): pos = step(pos); return |pos|` re-runs from the SEED every call — a SILENT no-op that fakes a perfect "hold" (0.0000% drift) because the state never advances.

**Why:** proven with `var acc:=0.0; var f:=func(x): acc+=x; return acc` → `f.call(1);f.call(1);f.call(1)` returns `1,1,1` (not `1,2,3`); outer `acc` stays 0. Same for captured ints/Vector3. Only RefCounted objects mutated through their reference (e.g. `os.step()` on an OrbitalState) persist.

**How to apply:** write every headless `verify_*.gd` / probe loop that advances state as a PLAIN inline `for` loop over local vars — never a `Callable` closure driver. Sanity-check any "it holds perfectly" result: if a metric that MUST change over the run reads exactly 0, suspect the state isn't advancing (during the ODECAY orbit-decay hunt this produced a false "composite holds radius 0.0000%"; a facet-crossing count of 0 over an orbit that provably sweeps 449 facets exposed it). Custom editor: ~/voxiverse/docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/<gate>.gd
