# Export/Import Bundle

## Why

Issue #89 requested a way to move `codex-auth` settings between machines.

## What

Added a local bundle flow: `codex-auth export <path>` and `codex-auth import --bundle <path> [--replace]`.

## How

The bundle stores account metadata, matching auth snapshots, and registry settings in one private JSON file. Import validates the bundle before mutating local files, then merges by default or replaces local managed accounts when requested.

## Code locations

- `src/registry/bundle.zig`
- `src/cli/commands/export.zig`
- `src/workflows/export.zig`
- `tests/registry_bundle_test.zig`

## Retrospective

The existing registry/import boundaries made this a small CLI extension instead of a new sync subsystem. Keeping transport out of scope avoided adding remote-copy failure modes.
