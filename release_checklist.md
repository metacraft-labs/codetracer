## release checklist

### local changes/PR/testing the artifacts

* update CHANGELOG.md with the new features, fixes, improvements and notes
  * don't write release notes for unfinished or non-documented features(except in special cases)
* update version.nim with the new version, following [calendar versioning](https://calver.org/): `YY.OM.<build>`:
  e.g. the first build for a month can be `25.03.1`, the next one `25.03.2` etc
  update the release artifact url-s in with the new versions in README.md as well!
* open a pull request with the changes and push a test tag, e.g. `YY.OM.<build>-test` (DON'T push the final release tag for now)
* check if CI builds and upload correctly the artifacts, if possible test the artifacts: if needed, one can
  fix/change things and push again(you can force push both the code and the test tag: `git push --force --tags`, or delete remotely and push the tag again)
* when it's all tested or ready, you can delete the test tag(locally and remotely)

### making the GitHub release

* update version.nim with the new version

* check if the CI has built/uploaded the new correctly tagged artifacts! maybe at least try to download them from the updated merged README or the release notes.

* only if they're already uploaded, we can publish, as the release notes also point to the new artifacts.

* activate the option to make a GitHub discussion for the release, when publishing and publish!

* eventually publish in OpenCollective news for the release

