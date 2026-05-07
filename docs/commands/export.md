# `codex-auth export`

## Usage

```shell
codex-auth export <path>
```

## Behavior

- Writes one bundle JSON file containing stored accounts, managed auth snapshots, and `auto`, `api`, and `live` settings.
- The bundle file contains authentication tokens. Treat it like `~/.codex/auth.json`.
- On Unix-like systems, the bundle is written with private file permissions.
- Export validates that every stored account has a matching managed auth snapshot before writing the bundle.
- Runtime usage state is not exported.

## Output

```text
Exported <count> account(s) to <path>
```
