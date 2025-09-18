## Release checklist

* Update CHANGELOG.md with the new features, fixes, improvements and notes
  * don't write release notes for unfinished or non-documented features(except in special cases)
* Update version.nim with the new version, following [calendar versioning](https://calver.org/): `YY.OM.<build>`:
  e.g. the first build for a month can be `25.03.1`, the next one `25.03.2` etc
* Open a pull request with the changes
* Check if CI builds and upload correctly the artifacts. Test the artifacts: if needed, one can
  fix/change things and push again
* When it's all tested or ready, you can merge the pull request which will automatically push a tag and release
* Once the release is ready, activate the option to make a GitHub discussion for the release, when publishing and publish!
* Eventually publish in OpenCollective news for the release
