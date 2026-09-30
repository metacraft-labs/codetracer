## Release checklist

A release is cut from `dev`, tagged on `dev`, and published by
`.github/workflows/release.yml`. The process follows
[package-distribution.md §12](https://github.com/metacraft-labs/metacraft-specs/blob/latest/infrastructure/package-distribution.md#12-cutting-a-release)
and the [branching policy](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/branching-policy.md).

1. **Land everything on `dev` first.** Release-only fixes are merged into `dev`
   before the release, so the tagged commit is part of `dev`'s history.
2. **Bump the version on `dev`**, in its own pull request:
   * `src/ct/version.nim`, following [calendar versioning](https://calver.org/)
     `YY.OM.<build>`: the first release of a month is `26.09.1`, the next `26.09.2`.
     The month is the month the release is cut.
   * `resources/Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`).
   * `CHANGELOG.md`: the `## Unreleased` section becomes `## <version> - <date>`,
     with a fresh empty `## Unreleased` above it. Don't write release notes for
     unfinished or undocumented features.
3. **Dry-run the release on that exact commit.** Until `release.yml` is on the
   default branch, push the commit to a dry-run branch:

       git push origin <sha>:refs/heads/release-dry-run/<version>

   (afterwards, `gh workflow run release.yml --ref dev` also works). Every leg
   must be green: the AppImage builds, the `.deb` and `.rpm` install the
   AppImage's tree intact and a working `ct` in clean `debian:12` / `fedora:40`
   containers, the DMG builds and reports the version, and every asset is signed.
   Only tag a commit whose dry run was green.
4. **Tag the commit and push the tag:**

       git tag -a <version> -m "Release <version>" <sha>
       git push origin <version>

   The tag runs `release.yml` for real. It rebuilds and verifies everything,
   publishes the GitHub Release with all assets, `SHA256SUMS` and signatures,
   uploads the AppImage and DMG to `downloads.codetracer.com` (versioned and
   `latest`), and asks
   [metacraft-desktop-packages](https://github.com/metacraft-labs/metacraft-desktop-packages)
   to add the `.deb` and `.rpm` to `deb.metacraft-labs.com` and
   `rpm.metacraft-labs.com` (its `publish-release.yaml` run).
5. **After the release has published, fast-forward `stable` to the tag:**

       git branch -f release-to-stable <version>
       git push origin release-to-stable:stable

   A push to `stable` also redeploys https://get.codetracer.com.
6. **Smoke-test what users get**, on clean machines or containers:

       podman run --rm debian:12 sh -c 'apt-get update && apt-get install -y curl && curl -fsSL https://get.codetracer.com/sh | sh && ct --version'
       podman run --rm fedora:40 sh -c 'curl -fsSL https://get.codetracer.com/sh | sh && ct --version'

7. **Arch and Gentoo** still build from recipes in metacraft-desktop-packages:
   bump `arch/codetracer/PKGBUILD` and rename
   `gentoo/dev-debug/codetracer-bin/codetracer-bin-<version>.ebuild`. Both fetch
   the AppImage from `downloads.codetracer.com` and `resources.tar.xz` from the
   GitHub Release. The `.deb`/`.rpm` need no recipe change any more.
8. Optionally announce the release (GitHub discussion, OpenCollective).
