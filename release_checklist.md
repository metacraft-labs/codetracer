## release checklist

### local changes/PR/testing the artifacts

* update CHANGELOG.md with the new features, fixes, improvements and notes
  * don't write release notes for unfinished or non-documented features(except in special cases)
* update version.nim with the new version, following [calendar versioning](https://calver.org/): `YY.OM.<build>`:
  e.g. the first build for a month can be `25.03.1`, the next one `25.03.2` etc
* open a pull request with the changes and push a test tag, e.g. `YY.OM.<build>-test` (DON'T push the final release tag for now)
* check if CI builds and upload correctly the artifacts, if possible test the artifacts: if needed, one can
  fix/change things and push again(you can force push both the code and the test tag: `git push --force --tags`, or delete remotely and push the tag again)
* when it's all tested or ready, you can delete the test tag(locally and remotely), and merge(by rebase) the PR from the GitHub interface, 
and then you can pull `main` locally, tag the new last commit in `main` with the real version (`YY.OM.<build>`) and push the tag

### making the GitHub release

* go to https://github.com/metacraft-labs/codetracer/releases/ and click `Draft a new release`. you can save the release as a draft and edit it multiple times before publishing, be careful and publish it only when ready, as it seems that GitHub sends an email with the release text to the subscribers! Be careful, as the default action/shortcut seems to point to `Publish release`, explicitly save using `Save draft`, unless you're ready to publish!

* copy the changelog to the release notes, eventually with some additional screenshots and with adding buttons for downloading the artifacts, similar to:

```markdown
# FIX the versions in the urls! Use the same version as the new release tag
[![Download AppImage](https://img.shields.io/badge/Download-Linux%20AppImage-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-25.03.1-amd64.AppImage)
[![Download macOS](https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-25.03.1-arm64.dmg)
```

* activate the option to make a GitHub discussion for the release, when publishing and publish!

* publish in OpenCollective news for the release

