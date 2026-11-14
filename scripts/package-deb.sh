#!/usr/bin/env bash
# Builds pg-studio_<version>_amd64.deb (Debian / Ubuntu) from the release bundle:
#   /usr/lib/pg-studio/          the Flutter bundle (pg_studio, data/, lib/ with libpg_query.so)
#   /usr/bin/pg-studio           starts it: pg-studio [folder]
#   /usr/share/applications/dev.ambit.pg_studio.desktop, icons (hicolor), man page, copyright, changelog
# Usage: scripts/package-deb.sh [--no-build]     (the .deb lands in build/deb/)
# DEB_MAINTAINER overrides the Maintainer field ("Name <email>").
set -euo pipefail
cd "$(dirname "$0")/.."
umask 022

name=pg-studio
pubspec_version="$(sed -n 's/^version: *//p' pubspec.yaml)"
version="${pubspec_version%%+*}"          # 2.0.0+3 -> 2.0.0 (the build number is not part of a native version)
arch=amd64
maintainer="${DEB_MAINTAINER:-Ambit <contact@ambitsys.eu>}"

if [[ "${1:-}" != "--no-build" ]]; then
  flutter build linux --release
  (cd packages/pg_core && dart build cli -t bin/pg_studio_cli.dart -o build/cli >/dev/null)
fi
cli_bundle=packages/pg_core/build/cli/bundle
test -x "$cli_bundle/bin/pg_studio_cli" || { echo "no CLI bundle in $cli_bundle" >&2; exit 1; }
bundle=build/linux/x64/release/bundle
test -x "$bundle/pg_studio" || { echo "no release bundle in $bundle" >&2; exit 1; }
test -f "$bundle/lib/libpg_query.so" || { echo "libpg_query.so missing in the bundle" >&2; exit 1; }

out=build/deb
root="$out/root"
rm -rf "$out"
mkdir -p "$root/DEBIAN" "$root/usr/lib/$name" "$root/usr/bin" "$root/usr/share/applications" \
  "$root/usr/share/doc/$name" "$root/usr/share/man/man1" "$root/usr/share/lintian/overrides"

cp -a "$bundle/." "$root/usr/lib/$name/"
# The command line (check, refs, format, mcp, ...): a Dart executable with its own copy of libpg_query.
mkdir -p "$root/usr/lib/$name/cli"
cp -a "$cli_bundle/." "$root/usr/lib/$name/cli/"
# Shared objects are not executable (lintian shared-library-is-executable); the program is.
find "$root/usr/lib/$name" -type f -name '*.so' -exec chmod 0644 {} +
find "$root/usr/lib/$name" -type d -exec chmod 0755 {} +
chmod 0755 "$root/usr/lib/$name/pg_studio"
# The program, libpg_query and the plugins are built here: strip their debug symbols. libapp.so (the Dart AOT
# snapshot) and the Flutter engine come stripped as Flutter ships them.
strip --strip-unneeded "$root/usr/lib/$name/pg_studio"
chmod 0755 "$root/usr/lib/$name/cli/bin/pg_studio_cli"
for lib in "$root/usr/lib/$name/lib/"*.so "$root/usr/lib/$name/cli/lib/"*.so; do
  case "$(basename "$lib")" in libapp.so|libflutter_linux_gtk.so) ;; *) strip --strip-unneeded "$lib" ;; esac
done
# No library may carry a search path from the machine it was built on.
if readelf -d "$root/usr/lib/$name/lib/"*.so 2>/dev/null | grep -E 'R(UN)?PATH' | grep -v ORIGIN; then
  echo "a library has a build machine RUNPATH" >&2; exit 1
fi

cat > "$root/usr/bin/$name" <<'SH'
#!/bin/sh
# PG Studio: an offline editor for PostgreSQL database projects.
#   pg-studio [folder]                  the editor
#   pg-studio check|def|refs|graph|modules|contract|codes|format|mcp|help ...   the command line (pg-studio-cli)
case "$1" in
  check|def|refs|graph|modules|contract|codes|format|mcp|help|--help) exec /usr/lib/pg-studio/cli/bin/pg_studio_cli "$@" ;;
esac
exec /usr/lib/pg-studio/pg_studio "$@"
SH
cat > "$root/usr/bin/$name-cli" <<'SH'
#!/bin/sh
# PG Studio from the command line: pg-studio-cli <command> <folder> ... (pg-studio-cli help)
exec /usr/lib/pg-studio/cli/bin/pg_studio_cli "$@"
SH
chmod 0755 "$root/usr/bin/$name" "$root/usr/bin/$name-cli"

cat > "$root/usr/share/applications/dev.ambit.pg_studio.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=PG Studio
GenericName=PostgreSQL project editor
Comment=Open a folder of PostgreSQL database files and work with it like with code - offline
Exec=pg-studio %F
Icon=pg-studio
Terminal=false
Categories=Development;IDE;Database;
Keywords=PostgreSQL;SQL;Liquibase;database;editor;
MimeType=inode/directory;
StartupWMClass=dev.ambit.pg_studio
DESKTOP

for s in 48 64 128 256; do
  install -D -m 0644 "packaging/icons/$name-$s.png" "$root/usr/share/icons/hicolor/${s}x${s}/apps/$name.png"
done
install -D -m 0644 "packaging/icons/$name.svg" "$root/usr/share/icons/hicolor/scalable/apps/$name.svg"

cat > "$root/usr/share/doc/$name/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: PG Studio
Source: https://github.com/ambit-project/ambit-pg-studio

Files: *
Copyright: 2026 PG Studio contributors
License: Expat
 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
 documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
 rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
 persons to whom the Software is furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
 Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Files: usr/lib/pg-studio/lib/libpg_query.so
Copyright: 2015 Lukas Fittl, 2015-2026 Duboce Labs, Inc. (pganalyze); 1996-2026 The PostgreSQL Global Development Group
License: BSD-3-Clause and PostgreSQL
 libpg_query (https://github.com/pganalyze/libpg_query), BSD 3-Clause License, includes the PostgreSQL parser under
 the PostgreSQL License.

Files: usr/lib/pg-studio/lib/libflutter_linux_gtk.so usr/lib/pg-studio/data/*
Copyright: 2014-2026 The Flutter Authors
License: BSD-3-Clause
 Flutter engine and assets (https://github.com/flutter/flutter), BSD 3-Clause License.
COPY

{
  echo "$name ($version) unstable; urgency=medium"
  echo
  echo "  * PG Studio $version: see PRODUCT.md and docs/adr/ in the repository."
  echo
  echo " -- $maintainer  $(date -R)"
} | gzip -9n > "$root/usr/share/doc/$name/changelog.gz"

cat <<MAN | gzip -9n > "$root/usr/share/man/man1/$name.1.gz"
.TH PG-STUDIO 1 "$(date +%Y-%m-%d)" "$version" "User Commands"
.SH NAME
pg-studio \- offline editor for PostgreSQL database projects
.SH SYNOPSIS
.B pg-studio
.RI [ folder ]
.br
.B pg-studio
.RI "check|def|refs|graph|modules|contract|codes|format|mcp " folder " [" arguments ]
.br
.B pg-studio-cli
.RI "command " folder " [" arguments ]
.SH DESCRIPTION
Opens a folder of SQL files and Liquibase changesets and analyses it without a database connection: go to
definition, find references, hover, dependency graphs, formatting, the conventions of module folders.
.SH COMMANDS
.TP
.B check \fIfolder\fR [\-\-strict] [\-\-json]
Problems as file:line:column; exit 1 on errors (\-\-strict: also on warnings).
.TP
.B def|refs|graph \fIfolder name\fR
Definition, references, dependencies of schema.name or name.
.TP
.B format \fIfolder\fR [\-\-check]
Formats in place (whitespace only, deployed changesets untouched); \-\-check lists files and exits 1.
.TP
.B mcp \fIfolder\fR
Model Context Protocol server on stdio: claude mcp add pg\-studio \-\- pg\-studio\-cli mcp \fIfolder\fR
.SH FILES
.TP
.I .pgstudio.json
Project settings in the opened folder or a folder above it (formatting).
MAN

ln -s "$name.1.gz" "$root/usr/share/man/man1/$name-cli.1.gz"

# The bundle keeps Flutter's layout: its libraries live in a private directory next to the program.
cat > "$root/usr/share/lintian/overrides/$name" <<'OVR'
pg-studio: embedded-library *usr/lib/pg-studio/lib/libflutter_linux_gtk.so*
# libapp.so is the Dart AOT snapshot: an ELF without NEEDED entries, loaded by the Flutter engine.
pg-studio: shared-library-lacks-prerequisites [usr/lib/pg-studio/lib/libapp.so]
OVR

# Dependencies from the ELF files of the bundle.
shlibs_dir="$out/shlibs"
mkdir -p "$shlibs_dir/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$name" "$name" > "$shlibs_dir/debian/control"
elfs=()
while IFS= read -r f; do elfs+=("$(realpath "$f")"); done < <(find "$root/usr/lib/$name" -type f \( -name '*.so' -o -name pg_studio -o -name pg_studio_cli \))
depends="$(cd "$shlibs_dir" && dpkg-shlibdeps -O -l"$(realpath "../root/usr/lib/$name/lib")" -l"$(realpath "../root/usr/lib/$name/cli/lib")" "${elfs[@]}" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
test -n "$depends" || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }
# The Flutter engine dlopens EGL/GLES at run time (not in NEEDED, so dpkg-shlibdeps cannot see it): without libEGL the
# program aborts on a clean system ("Couldn't open libEGL.so.1"). Mesa provides the implementation.
depends="$depends, libegl1, libgles2"
rm -rf "$shlibs_dir"

installed_size="$(du -sk "$root/usr" | cut -f1)"
cat > "$root/DEBIAN/control" <<CONTROL
Package: $name
Version: $version
Architecture: $arch
Maintainer: $maintainer
Installed-Size: $installed_size
Depends: $depends
Recommends: git, libegl-mesa0, libgl1-mesa-dri
Section: devel
Priority: optional
Homepage: https://github.com/ambit-project/ambit-pg-studio
Description: offline editor for PostgreSQL database projects
 PG Studio opens a folder of SQL files and Liquibase changesets and analyses it
 without a database connection: go to definition, find references, hover,
 dependency graphs, formatting that never changes meaning, and the conventions
 of module folders (modules nn-, <module>_app contract, ERRCODE).
CONTROL

deb="$out/${name}_${version}_${arch}.deb"
fakeroot dpkg-deb --build --root-owner-group -Zxz "$root" "$deb" >/dev/null
echo "$deb"
