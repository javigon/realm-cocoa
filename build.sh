# NOTE: THIS SCRIPT IS SUPPOSED TO RUN IN A POSIX SHELL

cd "$(dirname "$0")"
TIGHTDB_OBJC_HOME="$(pwd)"

MODE="$1"
[ $# -gt 0 ] && shift



word_list_append()
{
    local list_name new_word list
    list_name="$1"
    new_word="$2"
    list="$(eval "printf \"%s\\n\" \"\${$list_name}\"")" || return 1
    if [ "$list" ]; then
        eval "$list_name=\"\$list \$new_word\""
    else
        eval "$list_name=\"\$new_word\""
    fi
    return 0
}

word_list_prepend()
{
    local list_name new_word list
    list_name="$1"
    new_word="$2"
    list="$(eval "printf \"%s\\n\" \"\${$list_name}\"")" || return 1
    if [ "$list" ]; then
        eval "$list_name=\"\$new_word \$list\""
    else
        eval "$list_name=\"\$new_word\""
    fi
    return 0
}



# Setup OS specific stuff
OS="$(uname)" || exit 1
NUM_PROCESSORS=""
if [ "$OS" = "Darwin" ]; then
    NUM_PROCESSORS="$(sysctl -n hw.ncpu)" || exit 1
else
    if [ -r /proc/cpuinfo ]; then
        NUM_PROCESSORS="$(cat /proc/cpuinfo | grep -E 'processor[[:space:]]*:' | wc -l)" || exit 1
    fi
fi
if [ "$NUM_PROCESSORS" ]; then
    word_list_prepend MAKEFLAGS "-j$NUM_PROCESSORS" || exit 1
fi
export MAKEFLAGS



require_config()
{
    cd "$TIGHTDB_OBJC_HOME" || return 1
    if ! [ -e "config" ]; then
        cat 1>&2 <<EOF
ERROR: Found no configuration!
You need to run 'sh build.sh config [PREFIX]'.
EOF
        return 1
    fi
    echo "Using existing configuration:"
    cat "config" | sed 's/^/    /' || return 1
}

auto_configure()
{
    cd "$TIGHTDB_OBJC_HOME" || return 1
    if [ -e "config" ]; then
        require_config || return 1
    else
        echo "No configuration found. Running 'sh build.sh config'"
        sh build.sh config || return 1
    fi
}

get_config_param()
{
    local name line value
    cd "$TIGHTDB_OBJC_HOME" || return 1
    name="$1"
    if ! [ -e "config" ]; then
        cat 1>&2 <<EOF
ERROR: Found no configuration!
You need to run 'sh build.sh config [PREFIX]'.
EOF
        return 1
    fi
    if ! line="$(grep "^$name:" "config")"; then
        echo "ERROR: Failed to read configuration parameter '$name'" 1>&2
        return 1
    fi
    value="$(printf "%s\n" "$line" | cut -d: -f2)" || return 1
    value="$(printf "%s\n" "$value" | sed 's/^ *//')" || return 1
    printf "%s\n" "$value"
}



case "$MODE" in

    "config")
        install_prefix="$1"
        if [ -z "$install_prefix" ]; then
            install_prefix="/usr/local"
        fi
        install_libdir="$(make prefix="$install_prefix" get-libdir)" || exit 1

        if [ "$OS" != "Darwin" ]; then
            echo "ERROR: Currently, the Objective-C extension is only available on Mac OS X" 1>&2
            exit 1
        fi

        cat >"config" <<EOF
install-prefix: $install_prefix
install-libdir: $install_libdir
EOF
        echo "New configuration:"
        cat "config" | sed 's/^/    /' || exit 1
        echo "Done configuring"
        exit 0
        ;;

    "clean")
        auto_configure || exit 1
        make clean || exit 1
        if [ "$OS" = "Darwin" ]; then
            PLATFORMS="iPhoneOS iPhoneSimulator"
            for x in $PLATFORMS; do
                make BASE_DENOM="$x" clean || exit 1
            done
            make BASE_DENOM="ios" clean || exit 1
        fi
        echo "Done cleaning"
        exit 0
        ;;

    "build")
        auto_configure || exit 1
# FIXME: Our language binding requires that Objective-C ARC is enabled, which, in turn, is only available on a 64-bit architecture, so for now we cannot build a "fat" version.
#        TIGHTDB_ENABLE_FAT_BINARIES="1" make || exit 1
        make || exit 1
        if [ "$OS" = "Darwin" ]; then
            # This section builds the following two static libraries:
            #     src/tightdb/libtightdb-objc-ios.a
            #     src/tightdb/libtightdb-objc-ios-dbg.a
            # Each one contains both a version for iPhone and one for
            # the iPhone simulator.
            # Each contained version of each of the two libraries
            # includes the TightDB core library and is therefore self
            # contained.
            TEMP_DIR="$(mktemp -d /tmp/tightdb.objc.build.XXXX)" || exit 1
            # Xcode provides the iPhoneOS SDK
            XCODE_HOME="$(xcode-select --print-path)" || exit 1
            PLATFORMS="iPhoneOS iPhoneSimulator"
            for x in $PLATFORMS; do
                PLATFORM_HOME="$XCODE_HOME/Platforms/$x.platform"
                if ! [ -e "$PLATFORM_HOME/Info.plist" ]; then
                    echo "Failed to find '$PLATFORM_HOME/Info.plist'" 1>&2
                    exit 1
                fi
                mkdir "$TEMP_DIR/$x" || exit 1
                for y in "$PLATFORM_HOME/Developer/SDKs"/*; do
                    VERSION="$(defaults read "$y/SDKSettings" Version)" || exit 1
                    if ! printf "%s\n" "$VERSION" | grep -q '^[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,3\}$'; then
                        echo "Uninterpretable version '$VERSION' in '$y'" 1>&2
                        exit 1
                    fi
                    if [ -e "$TEMP_DIR/$x/$VERSION" ]; then
                        echo "Ambiguous version '$VERSION' in '$y'" 1>&2
                        exit 1
                    fi
                    printf "%s\n" "$y" >"$TEMP_DIR/$x/$VERSION"
                    printf "%s\n" "$VERSION" >>"$TEMP_DIR/$x/versions"
                done
                if ! [ -e "$TEMP_DIR/$x/versions" ]; then
                    echo "Found no SDKs in '$PLATFORM_HOME'" 1>&2
                    exit 1
                fi
                sort -t . -k 1,1nr -k 2,2nr -k 3,3nr -k 4,4nr "$TEMP_DIR/$x/versions" >"$TEMP_DIR/$x/versions-sorted" || exit 1
                LATEST="$(cat "$TEMP_DIR/$x/versions-sorted" | head -n 1)" || exit 1
                (cd "$TEMP_DIR/$x" && ln "$LATEST" "sdk_root") || exit 1
                if [ "$x" = "iPhoneSimulator" ]; then
                    ARCH="i386"
                else
                    TYPE="$(defaults read-type "$PLATFORM_HOME/Info" "DefaultProperties")" || exit 1
                    if [ "$TYPE" != "Type is dictionary" ]; then
                        echo "Unexpected type of value of key 'DefaultProperties' in '$PLATFORM_HOME/Info.plist'" 1>&2
                        exit 1
                    fi
                    CHUNK="$(defaults read "$PLATFORM_HOME/Info" "DefaultProperties")" || exit 1
                    defaults write "$TEMP_DIR/$x/chunk" "$CHUNK" || exit 1
                    ARCH="$(defaults read "$TEMP_DIR/$x/chunk" NATIVE_ARCH)" || exit 1
                fi
                printf "%s\n" "$ARCH" >"$TEMP_DIR/$x/arch"
            done
            for x in $PLATFORMS; do
                PLATFORM_HOME="$XCODE_HOME/Platforms/$x.platform"
                SDK_ROOT="$(cat "$TEMP_DIR/$x/sdk_root")" || exit 1
                ARCH="$(cat "$TEMP_DIR/$x/arch")" || exit 1
                make -C "src/tightdb/objc" BASE_DENOM="$x" CFLAGS_ARCH="-arch $ARCH -isysroot $SDK_ROOT" "libtightdb-objc-$x.a" "libtightdb-objc-$x-dbg.a" || exit 1
                cp "src/tightdb/objc/libtightdb-objc-$x.a"     "$TEMP_DIR/$x/libtightdb-objc.a"     || exit 1
                cp "src/tightdb/objc/libtightdb-objc-$x-dbg.a" "$TEMP_DIR/$x/libtightdb-objc-dbg.a" || exit 1
            done
            lipo "$TEMP_DIR"/*/"libtightdb-objc.a"     -create -output "$TEMP_DIR/libtightdb-objc-ios.a"     || exit 1
            lipo "$TEMP_DIR"/*/"libtightdb-objc-dbg.a" -create -output "$TEMP_DIR/libtightdb-objc-ios-dbg.a" || exit 1
            LDFLAGS=""
            for x in $(printf "%s\n" "$LIBRARY_PATH" | sed 's/:/ /g'); do
                word_list_append LDFLAGS "-L$x" || exit 1
            done
            libtool -static -o "src/tightdb/objc/libtightdb-objc-ios.a"     "$TEMP_DIR/libtightdb-objc-ios.a"     -ltightdb-ios     $LDFLAGS || exit 1
            libtool -static -o "src/tightdb/objc/libtightdb-objc-ios-dbg.a" "$TEMP_DIR/libtightdb-objc-ios-dbg.a" -ltightdb-ios-dbg $LDFLAGS || exit 1
        fi
        echo "Done building"
        exit 0
        ;;

    "test")
        require_config || exit 1
        make test-norun || exit 1
        TEMP_DIR="$(mktemp -d /tmp/tightdb.objc.test.XXXX)" || exit 1
        mkdir -p "$TEMP_DIR/unit-tests.octest/Contents/MacOS" || exit 1
        cp "src/tightdb/objc/test/unit-tests" "$TEMP_DIR/unit-tests.octest/Contents/MacOS/" || exit 1
        XCODE_HOME="$(xcode-select --print-path)" || exit 1
        OBJC_DISABLE_GC=YES "$XCODE_HOME/Tools/otest" "$TEMP_DIR/unit-tests.octest" || exit 1
        echo "Test passed"
        exit 0
        ;;

    "test-debug")
        require_config || exit 1
        make test-debug-norun || exit 1
        TEMP_DIR="$(mktemp -d /tmp/tightdb.objc.test-debug.XXXX)" || exit 1
        mkdir -p "$TEMP_DIR/unit-tests-dbg.octest/Contents/MacOS" || exit 1
        cp "src/tightdb/objc/test/unit-tests-dbg" "$TEMP_DIR/unit-tests-dbg.octest/Contents/MacOS/" || exit 1
        XCODE_HOME="$(xcode-select --print-path)" || exit 1
        OBJC_DISABLE_GC=YES "$XCODE_HOME/Tools/otest" "$TEMP_DIR/unit-tests-dbg.octest" || exit 1
        echo "Test passed"
        exit 0
        ;;

    "install")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make install DESTDIR="$DESTDIR" prefix="$install_prefix" || exit 1
        echo "Done installing"
        exit 0
        ;;

    "install-shared")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make install DESTDIR="$DESTDIR" prefix="$install_prefix" INSTALL_FILTER=shared-libs || exit 1
        echo "Done installing"
        exit 0
        ;;

    "install-devel")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make install DESTDIR="$DESTDIR" prefix="$install_prefix" INSTALL_FILTER=static-libs,progs,headers || exit 1
        echo "Done installing"
        exit 0
        ;;

    "uninstall")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make uninstall prefix="$install_prefix" || exit 1
        echo "Done uninstalling"
        exit 0
        ;;

    "uninstall-shared")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make uninstall prefix="$install_prefix" INSTALL_FILTER=shared-libs || exit 1
        echo "Done uninstalling"
        exit 0
        ;;

    "uninstall-devel")
        require_config || exit 1
        install_prefix="$(get_config_param "install-prefix")" || exit 1
        make uninstall prefix="$install_prefix" INSTALL_FILTER=static-libs,progs,extra || exit 1
        echo "Done uninstalling"
        exit 0
        ;;

    "test-installed")
        require_config || exit 1
        install_libdir="$(get_config_param "install-libdir")" || exit 1
        export LD_RUN_PATH="$install_libdir"
        make -C "test-installed" clean || exit 1
        make -C "test-installed" test  || exit 1
        echo "Test passed"
        exit 0
        ;;

    "dist-copy")
        # Copy to distribution package
        TARGET_DIR="$1"
        if ! [ "$TARGET_DIR" -a -d "$TARGET_DIR" ]; then
            echo "Unspecified or bad target directory '$TARGET_DIR'" 1>&2
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/tightdb.objc.copy.XXXX)" || exit 1
        cat >"$TEMP_DIR/include" <<EOF
/README.md
/build.sh
/generic.mk
/config.mk
/Makefile
/src
/test-installed
/test-iphone
/doc
EOF
        cat >"$TEMP_DIR/exclude" <<EOF
.gitignore
EOF
        grep -E -v '^(#.*)?$' "$TEMP_DIR/include" >"$TEMP_DIR/include2" || exit 1
        grep -E -v '^(#.*)?$' "$TEMP_DIR/exclude" >"$TEMP_DIR/exclude2" || exit 1
        sed -e 's/\([.\[^$]\)/\\\1/g' -e 's|\*|[^/]*|g' -e 's|^\([^/]\)|^\\(.*/\\)\\{0,1\\}\1|' -e 's|^/|^|' -e 's|$|\\(/.*\\)\\{0,1\\}$|' "$TEMP_DIR/include2" >"$TEMP_DIR/include.bre" || exit 1
        sed -e 's/\([.\[^$]\)/\\\1/g' -e 's|\*|[^/]*|g' -e 's|^\([^/]\)|^\\(.*/\\)\\{0,1\\}\1|' -e 's|^/|^|' -e 's|$|\\(/.*\\)\\{0,1\\}$|' "$TEMP_DIR/exclude2" >"$TEMP_DIR/exclude.bre" || exit 1
        git ls-files >"$TEMP_DIR/files1" || exit 1
        grep -f "$TEMP_DIR/include.bre" "$TEMP_DIR/files1" >"$TEMP_DIR/files2" || exit 1
        grep -v -f "$TEMP_DIR/exclude.bre" "$TEMP_DIR/files2" >"$TEMP_DIR/files3" || exit 1
        tar czf "$TEMP_DIR/archive.tar.gz" -T "$TEMP_DIR/files3" || exit 1
        (cd "$TARGET_DIR" && tar xzf "$TEMP_DIR/archive.tar.gz") || exit 1
        exit 0
        ;;

    *)
        echo "Unspecified or bad mode '$MODE'" 1>&2
        echo "Available modes are: config clean build test install uninstall test-installed" 1>&2
        echo "As well as: install-shared install-devel uninstall-shared uninstall-devel dist-copy" 1>&2
        exit 1
        ;;

esac
