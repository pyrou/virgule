# Virgule

Virgule is a native macOS CSV explorer: AppKit + Swift for the UI, Rust for the data engine, and SQLite for a local read-only view cache. Source CSV files must never be modified.

## Working loop

Use [`docs/ROADMAP.md`](docs/ROADMAP.md) as the source of truth.

1. Take the next relevant unchecked task.
2. Implement it and verify the result; application changes must compile.
3. Check the completed item in the roadmap.
4. Create an atomic commit.
5. Repeat.

Delegate independent, well-bounded work to sub-agents when that meaningfully speeds up the iteration. Keep ownership of integration, verification, roadmap updates, and commits.
