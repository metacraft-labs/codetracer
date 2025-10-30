## Release checklist

* Update CHANGELOG.md with the new features, fixes, improvements and notes
  * don't write release notes for unfinished or non-documented features(except in special cases)
* Update version.nim with the new version, following [calendar versioning](https://calver.org/): `YY.OM.<build>`:
  e.g. the first build for a month can be `25.03.1`, the next one `25.03.2` etc
* Update Info.plist with the new version following the same format.
* Update `build-python/setup.cfg` with the new version following the same format.
* Open a pull request with the changes
* Check if CI builds and upload the artifacts correctly. Test the artifacts: if needed, one can
  fix/change things and push again
* When it's all tested or ready, you can merge the pull request which will automatically push a tag and release
* Once the release is ready, activate the option to make a GitHub discussion for the release, when publishing and publish!
* Update the desktop packages for CodeTracer:
  - All package updates are done by modifying files in the [metacraft-desktop-packages](https://github.com/metacraft-labs/metacraft-desktop-packages) repository
  - Updating debs/rpms:
    - debs are generated from the latest rpms so you only need to update the RPM package.
    - Open the CodeTracer spec which can be found as `rpm/SPECS/codetracer.spec`
    - Update the version field
    - Optionally, add changelog entries in the changelog field at the bottom of the file
    - Commit the file. GitHub actions will automatically build and deploy the package as an rpm and as a deb
  - Updating arch packages:
    - Open the PKGBUILD which can be found as `arch/codetracer/PKGBUILD`
    - Update the version field
    - Commit the file. GitHub actions will automatically build and deploy the package to the AUR
  - Updating gentoo packages:
    - Navigate to the ebuild which can be found as `gentoo/dev-debug/codetracer-bin/codetracer-bin-<version>.ebuild`
    - To update the package simply rename the file so that the version portion of it matches the new version
    - GitHub actions in [metacraft-desktop-packages](https://github.com/metacraft-labs/metacraft-desktop-packages) will push an update of the ebuild to [metacraft-overlay](https://github.com/metacraft-labs/metacraft-overlay)
    - In [metacraft-overlay](https://github.com/metacraft-labs/metacraft-overlay), GitHub actions will start building the package. The first CI build will be updating the `Manifest` file found in the same directory as the ebuild
      so it will be normal for the first build to automatically cancel itself. Building codetracer on Gentoo takes around 30 minutes so take a short break and check if it succeeded
* Eventually publish in OpenCollective news for the release
