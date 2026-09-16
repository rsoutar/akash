# Agent notes — Akash

Working notes for people and coding agents changing this repository.

## Releases

Version ownership lives in [`manifest.json`](manifest.json) (`version`). Nothing else is the source of truth.

Releases are **manual**. Merging a bug fix or chore to `main` does **not** bump the version and does **not** create a tag.

To ship a release:

1. Bump `manifest.json` `version` (for example `0.1.0` → `0.1.1`) and land that on `main`.
2. Create and push a tag that matches: `v` plus that version (`v0.1.1`).
3. [`.github/workflows/release.yml`](.github/workflows/release.yml) runs on tags matching `v*.*.*`. It fails if the tag (without the `v`) does not equal `manifest.json` `version`, then creates a GitHub Release with generated notes.

Do not add auto-bump or tag-on-merge to `main` unless that is an explicit product decision later.
