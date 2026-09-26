# Release policy and rehearsal

Current version: `0.1.0-dev`. The repository is public and MIT-licensed;
there is no published stable release. Before 1.0,
patch releases will preserve the documented source API and behavior; intentional
breaking changes require a minor version bump, migration notes, and an explicit
API contract review. After 1.0, breaking changes require a major version bump.
Adding errors, changing ownership/defaults, tightening accepted responses, and
changing the required Zig toolchain all require compatibility review. Development
snapshots should be pinned by commit and package hash.

## Rehearse locally

From a clean, committed checkout with Zig 0.16.0 and Python 3.12:

```sh
python3 scripts/release.py
```

Or manually run **Jevlin release rehearsal** in GitHub Actions. It has
read-only repository permissions and uploads workflow artifacts. Treat those
artifacts as public now that the repository is public. It creates no tag or
GitHub release.

The script selects the package paths from the committed manifest, packages HEAD
twice using Git's committed bytes/modes and deterministic gzip metadata, and
requires byte-identical output. It then verifies the exact archive in independent
Debug and ReleaseSafe consumers with fresh package caches. Their Zig package
hashes must agree. Output under `release-dist/` contains the source archive,
`SHA256SUMS`, consumer reports, and a release report tying them to the commit.
The reproducibility claim applies to repeated builds with the same Git/Python/
compression toolchain; it does not promise identical compression across versions.
SHA-256 identifies archive bytes; the Zig package hash identifies the fetched
package. Checksums are not signatures or publisher authentication.

## Before public release

1. Keep the MIT `LICENSE` in the manifest's package paths. The rehearsal requires
   the tracked license to be included in the archive.
2. Review API compatibility and migration notes, set a release version, and move
   the changelog's unreleased entries into its versioned section.
3. Require passing native CI, TLS checks, a release rehearsal, and reviewed soak
   evidence for the intended release commit. Earlier commits' evidence must not
   be presented as validation of later code without reviewing the differences.
4. Review remaining documented limits, including the scope of the fuzz campaigns.
5. Obtain approval for the versioned release, then create a matching version tag
   and publish the verified archive/checksums. Repository visibility is already public.

No publishing automation or automatic version bump is enabled by this rehearsal.
