# VOXIVERSE

A Minecraft-like, highly-detailed **voxel immersive simulation engine** built in **Godot 4.4**, playable in the browser and served live at **https://voxiverse.game-host.org**.

The current milestone is a first-person voxel test environment (infinite grass world, procedural hilly terrain, ambient lighting, a HUD thermometer reading per-voxel air/ground temperature) that doubles as the foundation for a full simulation engine — voxel materials with environment-driven state transitions and per-voxel physical fields (temperature, light, pressure, current, magnetic, gravity).

See **[docs/DESIGN.md](docs/DESIGN.md)** for the full specification, architecture, and build/deploy pipeline.

## Layout

| Path | Purpose |
|---|---|
| `godot/` | Godot 4.4 project (game + simulation foundations) |
| `docker/engine/` | Builds the custom Godot Web engine + export templates (with the `godot_voxel` C++ module) |
| `docker/server/` | Runtime container serving the web export (COOP/COEP isolation headers, autossl) |
| `deploy/` | Compose + haproxy registration for the live domain |
| `scripts/` | Build / export / deploy harness |

## Quick start

```bash
scripts/build.sh        # build engine + templates (Docker)
scripts/export-web.sh   # headless Web export -> build/web/
scripts/deploy.sh       # containerize + register with haproxy -> live
```

## Status

Bootstrapped 2026-07-02. Built autonomously by a Claude Code agent team. See git history and `docs/` for decisions.
