#!/bin/bash
# Build KeroBurn.app and bundle minipro (plus its libraries and database) inside it.
# Needs: Xcode Command Line Tools (xcode-select --install) and minipro (MacPorts or Homebrew).
#
# By default the app is built as a Universal binary (Intel + Apple Silicon) and packed into a .dmg.
#   ARCHS="x86_64" bash build.sh   build for one architecture only
#   NO_DMG=1 bash build.sh         skip the .dmg
# For a fully native Apple Silicon build, minipro and libusb must be universal too:
#   sudo port upgrade --enforce-variants minipro +universal
set -euo pipefail

APP_NAME="KeroBurn"
BUNDLE_ID="com.kerosmm.keroburn"
VERSION="1.0b3"
MIN_MACOS="12.0"

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mError: %s\033[0m\n' "$*"; exit 1; }

# --- Tools -------------------------------------------------------------------
command -v swiftc >/dev/null 2>&1 || die "swiftc not found. Run: xcode-select --install"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS="${ARCHS:-x86_64 arm64}"

# --- minipro -----------------------------------------------------------------
MINIPRO="${MINIPRO:-$(command -v minipro || true)}"
if [ -z "$MINIPRO" ]; then
    if [ -x /opt/local/bin/minipro ]; then
        MINIPRO=/opt/local/bin/minipro
    elif command -v port >/dev/null 2>&1; then
        say "minipro not found, installing it with MacPorts"
        sudo port install minipro
        MINIPRO=/opt/local/bin/minipro
    elif command -v brew >/dev/null 2>&1; then
        say "minipro not found, installing it with Homebrew"
        brew install minipro
        MINIPRO="$(command -v minipro)"
    else
        die "minipro not found. Install it with MacPorts (Intel Macs) or Homebrew (Apple Silicon)."
    fi
fi

# Follow symlinks by hand (older macOS has no readlink -f).
resolve() {
    local p="$1" t
    while [ -L "$p" ]; do
        t="$(readlink "$p")"
        case "$t" in
            /*) p="$t" ;;
            *)  p="$(cd "$(dirname "$p")" && pwd)/$t" ;;
        esac
    done
    echo "$p"
}
MINIPRO_REAL="$(resolve "$MINIPRO")"
PREFIX="$(cd "$(dirname "$MINIPRO_REAL")/.." && pwd)"

SHARE=""
for d in "$PREFIX/share/minipro" \
         "$(brew --prefix 2>/dev/null || echo /usr/local)/share/minipro" \
         /usr/local/share/minipro /opt/homebrew/share/minipro; do
    if [ -f "$d/infoic.xml" ]; then SHARE="$d"; break; fi
done

say "minipro: $MINIPRO_REAL"
"$MINIPRO_REAL" --version 2>&1 | head -n 3 || true
MINIPRO_VERSION="$("$MINIPRO_REAL" --version 2>&1 | sed -n 's/.*minipro version \([0-9][0-9.]*\).*/\1/p' | head -n 1 || true)"

# minipro is rebuilt from source when either:
#  - an arm64 slice is wanted but the MacPorts binary is single-arch (MacPorts' "+universal"
#    rebuilds libusb as universal, but minipro's own Makefile ignores the extra -arch flags), or
#  - there are KeroBurn patches for minipro in patches/ (for example the T48 pin test).
# The build links against the same libusb, for whichever of $ARCHS that libusb has.
PATCHES=( "$ROOT"/patches/*.patch )
[ -e "${PATCHES[0]}" ] || PATCHES=()
want_arm=0
case " $ARCHS " in *" arm64 "*) want_arm=1 ;; esac
need_src=0
if [ "$want_arm" = 1 ] && ! lipo -archs "$MINIPRO_REAL" 2>/dev/null | grep -qw arm64; then need_src=1; fi
if [ "${#PATCHES[@]}" -gt 0 ]; then need_src=1; fi

if [ "$need_src" = 1 ]; then
    TARBALL="$(ls -t /opt/local/var/macports/distfiles/minipro/minipro-*.tar.* 2>/dev/null | head -n 1 || true)"
    if [ -z "$TARBALL" ]; then
        # MacPorts installed a prebuilt archive, so there's no source on disk. Fetch the matching tag.
        MP_VER="$("$MINIPRO_REAL" --version 2>&1 | sed -n 's/.*minipro version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
        if [ -n "$MP_VER" ]; then
            mkdir -p "$BUILD"
            TARBALL="$BUILD/minipro-$MP_VER.tar.gz"
            if [ ! -s "$TARBALL" ]; then
                say "Downloading minipro $MP_VER source"
                if ! curl -fsSL -o "$TARBALL" "https://gitlab.com/DavidGriffith/minipro/-/archive/$MP_VER/minipro-$MP_VER.tar.gz"; then
                    rm -f "$TARBALL"; TARBALL=""
                fi
            fi
        fi
    fi
    LIBUSB_ARCHS="$(lipo -archs "$PREFIX/lib/libusb-1.0.0.dylib" 2>/dev/null || true)"
    SRC_ARCHS=""
    for arch in $ARCHS; do
        if echo "$LIBUSB_ARCHS" | grep -qw "$arch"; then SRC_ARCHS="$SRC_ARCHS $arch"; fi
    done
    if [ -n "$TARBALL" ] && [ -n "$SRC_ARCHS" ]; then
        say "Building minipro from $(basename "$TARBALL") for$SRC_ARCHS"
        SRC="$BUILD/minipro-src"
        rm -rf "$SRC"; mkdir -p "$SRC"
        tar -xf "$TARBALL" -C "$SRC" --strip-components 1
        patched=1
        for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
            say "Applying $(basename "$p")"
            if ! patch -d "$SRC" -p1 -s < "$p"; then
                warn "$(basename "$p") did not apply cleanly."
                patched=0
            fi
        done
        ARCH_FLAGS=""
        for arch in $SRC_ARCHS; do ARCH_FLAGS="$ARCH_FLAGS -arch $arch"; done
        if [ "$patched" = 1 ] && make -C "$SRC" minipro \
                PREFIX="$PREFIX" \
                CC="clang$ARCH_FLAGS -mmacosx-version-min=$MIN_MACOS" \
                CFLAGS="-O2 -Wall" \
                >"$BUILD/minipro-build.log" 2>&1 \
           && [ -x "$SRC/minipro" ]; then
            MINIPRO_REAL="$SRC/minipro"
            say "Built minipro: $(lipo -archs "$MINIPRO_REAL")"
        else
            warn "minipro source build failed, using the MacPorts binary. See build/minipro-build.log"
        fi
    else
        warn "Can't build minipro from source (no source tarball, or libusb lacks the wanted architectures)."
    fi
fi

# --- Compile -----------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/minipro" "$FRAMEWORKS" "$BUILD/obj"

# One slice per architecture, then glue them together with lipo.
# The two -Xfrontend flags make slow type-checking fail fast with a line number instead of hanging.
SLICES=()
for arch in $ARCHS; do
    say "Compiling $APP_NAME ($arch, macOS $MIN_MACOS+)"
    swiftc -O -parse-as-library \
        -Xfrontend -warn-long-expression-type-checking=500 \
        -Xfrontend -solver-expression-time-threshold=30 \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MIN_MACOS" \
        -module-cache-path "$BUILD/obj/cache-$arch" \
        "$ROOT"/Sources/*.swift \
        -o "$BUILD/obj/$APP_NAME-$arch"
    SLICES+=("$BUILD/obj/$APP_NAME-$arch")
done
lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/$APP_NAME"
say "App binary: $(lipo -archs "$CONTENTS/MacOS/$APP_NAME")"

# --- Bundle minipro ----------------------------------------------------------
say "Bundling minipro"
cp "$MINIPRO_REAL" "$CONTENTS/MacOS/minipro"
chmod u+w "$CONTENTS/MacOS/minipro"

# Copy every non-system dylib the binary needs and point it at the copy.
bundle_deps() {
    local bin="$1" dep name
    for dep in $(otool -L "$bin" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
            @*) continue ;;
        esac
        name="$(basename "$dep")"
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            cp -L "$dep" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            install_name_tool -id "@executable_path/../Frameworks/$name" "$FRAMEWORKS/$name" 2>/dev/null
            bundle_deps "$FRAMEWORKS/$name"
        fi
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$name" "$bin" 2>/dev/null
    done
}
bundle_deps "$CONTENTS/MacOS/minipro"

# Report which architectures the bundled minipro and its libraries cover.
MP_ARCHS="$(lipo -archs "$CONTENTS/MacOS/minipro" 2>/dev/null || echo unknown)"
say "minipro binary: $MP_ARCHS"
for lib in "$FRAMEWORKS"/*.dylib; do
    if [ -e "$lib" ]; then echo "    $(basename "$lib"): $(lipo -archs "$lib" 2>/dev/null)"; fi
done
case " $MP_ARCHS " in
    *" arm64 "*) ;;
    *) warn "minipro is $MP_ARCHS only. On Apple Silicon it will run through Rosetta 2."
       warn "For a native build: sudo port upgrade --enforce-variants minipro +universal" ;;
esac

if otool -L "$CONTENTS/MacOS/minipro" | tail -n +2 | grep -q '@rpath'; then
    warn "minipro links a library through @rpath; it may still need Homebrew at runtime."
fi

if [ -n "$SHARE" ]; then
    cp "$SHARE"/*.xml "$CONTENTS/Resources/minipro/"
    say "Database: $SHARE"
else
    warn "infoic.xml not found; the app will rely on minipro's built-in database path."
fi

# --- Icon --------------------------------------------------------------------
if [ -f "$ROOT/Assets/Logo.png" ]; then cp "$ROOT/Assets/Logo.png" "$CONTENTS/Resources/Logo.png"; fi

ICON_KEY=""
if [ -f "$ROOT/Assets/AppIcon.png" ] && command -v iconutil >/dev/null 2>&1; then
    ICONSET="$BUILD/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# --- Info.plist ----------------------------------------------------------------
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>MiniproVersion</key><string>$MINIPRO_VERSION</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    $ICON_KEY
</dict>
</plist>
PLIST

# --- Sign (ad hoc, enough for local use) ----------------------------------------
say "Signing (ad hoc)"
for lib in "$FRAMEWORKS"/*.dylib; do
    if [ -e "$lib" ]; then codesign --force --sign - "$lib"; fi
done
codesign --force --sign - "$CONTENTS/MacOS/minipro"
codesign --force --sign - "$APP"

# --- Smoke test ----------------------------------------------------------------
if "$CONTENTS/MacOS/minipro" --version >/dev/null 2>&1; then
    say "Bundled minipro runs OK"
else
    warn "Bundled minipro did not run cleanly. Output:"
    "$CONTENTS/MacOS/minipro" --version 2>&1 | head -n 5 || true
fi

# --- Disk image -----------------------------------------------------------------
DMG=""
if [ -z "${NO_DMG:-}" ]; then
    say "Making disk image"
    STAGE="$BUILD/dmg"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    if [ -f "$ROOT/README.md" ]; then cp "$ROOT/README.md" "$STAGE/README.md"; fi
    DMG="$BUILD/$APP_NAME-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
fi

say "Done: $APP"
if [ -n "$DMG" ]; then say "Disk image: $DMG"; fi
echo "Drag it into /Applications, or run:  open \"$APP\""
