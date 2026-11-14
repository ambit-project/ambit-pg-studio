# 0005. A .deb package for Debian and Ubuntu

Status: accepted (2026-11-14) - project "ambit.pg-studio.app 2.0", spec 014

## Decision

- `scripts/package-deb.sh` builds `build/deb/pg-studio_<version>_amd64.deb` from the release bundle with `dpkg-deb`
  (`fakeroot`, `--root-owner-group`, xz, umask 022). Version = pubspec version without the build number (native
  package). Only .deb (D6): no APT repository, Flatpak, Snap or AppImage.
- Layout: the Flutter bundle unchanged in `/usr/lib/pg-studio/` (program, `data/`, `lib/` with `libpg_query.so`),
  `/usr/bin/pg-studio` (a shell wrapper: `pg-studio [folder]`), `dev.ambit.pg_studio.desktop` (name and
  `StartupWMClass` = the GTK application id, so docks group the window), hicolor icons 48-256 px + SVG, a man page,
  `copyright` (with libpg_query and Flutter licences), `changelog.gz`.
- Dependencies: `dpkg-shlibdeps` on the program and libraries, plus `libegl1, libgles2` - the Flutter engine dlopens
  EGL at run time, invisible to dpkg-shlibdeps; on a clean system the program aborted ("Couldn't open libEGL.so.1").
  Recommends: git (formatting checks the main branch), Mesa EGL/DRI.
- Clean binaries: no plugin keeps a build RUNPATH (`CMAKE_SKIP_BUILD_RPATH` in `linux/CMakeLists.txt`; the script
  fails if a library has a non-`$ORIGIN` RUNPATH); our ELF files are stripped. `shared_preferences` was replaced by
  `~/.config/pg-studio/settings.json` (`SettingsStore`): its Android implementation pulled JNI native code with the
  builder's `$HOME` in RUNPATH into the Linux bundle.
- Lintian: no errors, no warnings; two documented overrides (the embedded Flutter engine library; `libapp.so`, the
  Dart AOT snapshot without NEEDED entries).
- `scripts/test-deb.sh`: in clean `ubuntu:26.04` and `debian:13` containers - `apt install ./pg-studio.deb`,
  `desktop-file-validate`, `ldd`, `pg-studio <folder>` under Xvfb until the "PG Studio" window exists, `dpkg -r`
  leaves no file. `./verify package` runs build + lintian + this test.
- The maintainer field defaults to `Ambit <contact@ambitsys.eu>`; `DEB_MAINTAINER` overrides it.
