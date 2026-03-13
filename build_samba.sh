#!/usr/bin/env bash
#
# build_samba.sh — Cross-compile Samba 4.8.12 for NetBSD evbarm OABI (Time Capsule)
#
# Produces a statically-linked smbd binary with catia, fruit, streams_xattr
# modules baked in. Target: ARM Cortex-A9, OLD ABI (not EABI), NetBSD 4.0.
#
# The Apple Time Capsule runs a NetBSD 4.0_STABLE kernel that only loads
# OABI ARM binaries (EI_OSABI=0x61, no EABI version bits in e_flags).
# We use the NetBSD 5.x source tree which still supports OABI evbarm,
# and NetBSD 5.2.3 binary sets for the sysroot.
#
# Dependencies: git, curl, gcc, make, python2 (Samba 4.8 waf), bison, flex
# Recommended: Run inside a Debian bullseye container (GCC 10).
#
set -euo pipefail

SAMBA_VERSION="4.8.12"
NETBSD_BRANCH="netbsd-5"
GMP_VERSION="6.2.1"
NETTLE_VERSION="3.4.1"

WORKDIR="${WORKDIR:-/tmp/tc-build}"
PREFIX="${WORKDIR}/install"
TOOLDIR="${WORKDIR}/tools"
SYSROOT="${WORKDIR}/sysroot"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/dist}"

NBMAKE=""
TARGET_ARCH="evbarm"
CROSS_PREFIX=""

# Flags needed for building NetBSD 5 toolchain with modern GCC (10+)
HOST_COMPAT_CFLAGS="-O -fcommon -fgnu89-inline"
HOST_COMPAT_CPPFLAGS="-D__GNUC_GNU_INLINE__"

# Cross-compiler flags for NetBSD target
# -std=gnu99: GCC 4.1.3 defaults to C89; libraries like Nettle need C99
# -Os: optimize for size — device has limited RAM for loading static binaries
# -fno-stack-protector: NetBSD 4.0 libc doesn't support __stack_chk_guard TLS
# -fno-PIC: static binary doesn't need PIC; GOT-based PIC crashes on NB4 kernel
CROSS_CFLAGS="-std=gnu99 -Os -fno-stack-protector -fno-PIC -fno-pic -D_NETBSD_SOURCE -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGE_FILES"

# Sysroot is built from NetBSD 5 source (archive.netbsd.org returns 402)

log() { echo "==> $*"; }

_build_sysroot() {
    if [ -d "${SYSROOT}/usr/include/sys" ] && [ -f "${SYSROOT}/usr/lib/libc.a" ]; then
        log "Sysroot already populated, skipping..."
        return
    fi

    log "Building sysroot from NetBSD 5 source (OABI)..."
    cd "${WORKDIR}/netbsd-src"

    # Build the distribution (includes, libs, etc.) using our cross-toolchain.
    # This populates DESTDIR (our SYSROOT) with headers and static libraries.
    env HOST_CFLAGS="${HOST_COMPAT_CFLAGS}" \
        CFLAGS="${HOST_COMPAT_CFLAGS}" \
        CPPFLAGS="${HOST_COMPAT_CPPFLAGS}" \
        ./build.sh -U -u -m "${TARGET_ARCH}" -j "$(nproc)" \
            -T "${TOOLDIR}" -D "${SYSROOT}" \
            -V MKLINT=no -V MKPROFILE=no -V MKPIC=no \
            -V MKMAN=no -V MKINFO=no -V MKCATPAGES=no \
            -V MKATF=no -V MKWERROR=no \
            distribution

    log "Sysroot ready: $(ls ${SYSROOT}/usr/include | wc -l) include dirs"
    log "Libraries: $(ls ${SYSROOT}/usr/lib/*.a 2>/dev/null | wc -l) static libs"
}

# ---------------------------------------------------------------------------
# Step 1: Build NetBSD cross-toolchain (OABI, arm--netbsdelf)
# ---------------------------------------------------------------------------
build_toolchain() {
    if [ -d "${TOOLDIR}/bin" ] && ls "${TOOLDIR}/bin/"*-gcc >/dev/null 2>&1 && [ -d "${SYSROOT}/usr/include" ]; then
        log "Cross-toolchain already built, skipping..."
        _set_cross_vars
        return
    fi

    log "Fetching NetBSD 5.x source tree (OABI support)..."
    if [ ! -d "${WORKDIR}/netbsd-src" ]; then
        git clone --depth 1 --branch "${NETBSD_BRANCH}" \
            https://github.com/NetBSD/src.git "${WORKDIR}/netbsd-src"
    fi

    log "Building NetBSD cross-toolchain for ${TARGET_ARCH} (OABI)..."
    cd "${WORKDIR}/netbsd-src"

    # Patch gmake's glob.c: __alloca and __stat are glibc internals not
    # exported by modern glibc (2.31+). Replace with standard equivalents.
    log "Patching gmake glob.c for modern glibc compatibility..."
    local GLOB_C="gnu/dist/gmake/glob/glob.c"
    if [ -f "${GLOB_C}" ]; then
        sed -i \
            -e 's/__alloca/alloca/g' \
            -e 's/__stat/stat/g' \
            -e 's/__glob_pattern_p/glob_pattern_p/g' \
            "${GLOB_C}"
    fi

    # NetBSD 5 evbarm (without -earm suffix) builds OABI toolchain
    # producing arm--netbsdelf cross-compiler (not arm--netbsdelf-eabi)
    # HOST_CFLAGS is what build.sh passes to the nbmake bootstrap configure
    env HOST_CFLAGS="${HOST_COMPAT_CFLAGS}" \
        CFLAGS="${HOST_COMPAT_CFLAGS}" \
        CPPFLAGS="${HOST_COMPAT_CPPFLAGS}" \
        ./build.sh -U -m "${TARGET_ARCH}" -j "$(nproc)" \
            -T "${TOOLDIR}" -D "${SYSROOT}" tools

    # Build sysroot from source (pre-built binary sets are unavailable)
    _build_sysroot

    _set_cross_vars
    log "Cross-compiler: ${CC}"
}

_set_cross_vars() {
    # Locate the cross-compiler prefix
    CROSS_PREFIX=$(ls "${TOOLDIR}/bin/"*-gcc 2>/dev/null | head -1 | sed 's/-gcc$//' || true)
    if [ -z "${CROSS_PREFIX}" ]; then
        echo "ERROR: Could not find cross-compiler in ${TOOLDIR}/bin/"
        exit 1
    fi

    # Extract host triplet from cross-compiler name (e.g. arm--netbsdelf for OABI)
    CROSS_HOST=$(basename "${CROSS_PREFIX}")
    log "Cross-compiler triplet: ${CROSS_HOST}"

    NBMAKE="${TOOLDIR}/bin/nbmake-${TARGET_ARCH}"
    export CC="${CROSS_PREFIX}-gcc"
    export CXX="${CROSS_PREFIX}-g++"
    export AR="${CROSS_PREFIX}-ar"
    export RANLIB="${CROSS_PREFIX}-ranlib"
    export STRIP="${CROSS_PREFIX}-strip"
    export LD="${CROSS_PREFIX}-ld"

    # GCC 4.1/ld from NetBSD 5 toolchain does NOT support --sysroot.
    # Use -nostdinc + -isystem for headers, -B for crt startup files, -L for libs.
    export CFLAGS="-nostdinc -isystem ${SYSROOT}/usr/include -B${SYSROOT}/usr/lib ${CROSS_CFLAGS}"
    export CPPFLAGS="-nostdinc -isystem ${SYSROOT}/usr/include ${CROSS_CFLAGS}"
    export LDFLAGS="-L${SYSROOT}/usr/lib -L${SYSROOT}/lib -B${SYSROOT}/usr/lib"
}

# ---------------------------------------------------------------------------
# Step 2: Build static dependencies (GMP, Nettle)
# ---------------------------------------------------------------------------
build_gmp() {
    if [ -f "${PREFIX}/lib/libgmp.a" ]; then
        log "GMP already built, skipping..."
        return
    fi

    log "Building GMP ${GMP_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "gmp-${GMP_VERSION}.tar.xz" ]; then
        curl -LO "https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz"
    fi
    rm -rf "gmp-${GMP_VERSION}"
    tar xf "gmp-${GMP_VERSION}.tar.xz"
    cd "gmp-${GMP_VERSION}"
    # --disable-assembly: GMP 6.2 ARM asm uses UAL/Thumb2 syntax that the
    # OABI assembler (binutils from NetBSD 5) does not understand.
    ./configure \
        --host=arm-unknown-netbsd \
        --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --disable-assembly \
        CC="${CC}" \
        CFLAGS="${CFLAGS} -I${PREFIX}/include" \
        LDFLAGS="${LDFLAGS} -L${PREFIX}/lib"
    make -j "$(nproc)"
    make install
}

build_nettle() {
    if [ -f "${PREFIX}/lib/libnettle.a" ]; then
        log "Nettle already built, skipping..."
        return
    fi

    log "Building Nettle ${NETTLE_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "nettle-${NETTLE_VERSION}.tar.gz" ]; then
        curl -LO "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VERSION}.tar.gz"
    fi
    rm -rf "nettle-${NETTLE_VERSION}"
    tar xf "nettle-${NETTLE_VERSION}.tar.gz"
    cd "nettle-${NETTLE_VERSION}"
    # --disable-assembler: same as GMP, OABI assembler can't handle newer ARM asm
    ./configure \
        --host=arm-unknown-netbsd \
        --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --disable-assembler \
        CC="${CC}" \
        CFLAGS="${CFLAGS} -I${PREFIX}/include" \
        LDFLAGS="${LDFLAGS} -L${PREFIX}/lib"
    make -j "$(nproc)"
    make install
}

# ---------------------------------------------------------------------------
# Step 3: Build native Heimdal tools (needed by Samba build)
# ---------------------------------------------------------------------------
build_native_heimdal() {
    local HEIMDAL_INSTALL="${WORKDIR}/heimdal-native"
    if [ -x "${HEIMDAL_INSTALL}/bin/asn1_compile" ] && \
       [ -x "${HEIMDAL_INSTALL}/bin/compile_et" ]; then
        log "Native Heimdal tools already built, skipping..."
        return
    fi

    log "Building native Heimdal tools (asn1_compile, compile_et)..."
    cd "${WORKDIR}"
    if [ ! -f "heimdal-7.7.1.tar.gz" ]; then
        curl -LO "https://github.com/heimdal/heimdal/releases/download/heimdal-7.7.1/heimdal-7.7.1.tar.gz"
    fi
    rm -rf "heimdal-7.7.1"
    tar xf "heimdal-7.7.1.tar.gz"
    cd "heimdal-7.7.1"

    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        ./configure --prefix="${HEIMDAL_INSTALL}" \
            --disable-shared --enable-static \
            --without-readline \
            CFLAGS="-O -fcommon"
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        make -j "$(nproc)" -C include
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        make -j "$(nproc)" -C lib/roken
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        make -j "$(nproc)" -C lib/vers
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        make -j "$(nproc)" -C lib/com_err
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD -u CFLAGS -u CPPFLAGS -u LDFLAGS \
        make -j "$(nproc)" -C lib/asn1

    mkdir -p "${HEIMDAL_INSTALL}/bin"
    cp lib/asn1/asn1_compile "${HEIMDAL_INSTALL}/bin/"
    cp lib/com_err/compile_et "${HEIMDAL_INSTALL}/bin/"
    log "Native tools installed:"
    file "${HEIMDAL_INSTALL}/bin/asn1_compile" "${HEIMDAL_INSTALL}/bin/compile_et"
}

# ---------------------------------------------------------------------------
# Step 4: Cross-compile Samba
# ---------------------------------------------------------------------------
build_samba() {
    log "Building Samba ${SAMBA_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "samba-${SAMBA_VERSION}.tar.gz" ]; then
        curl -LO "https://download.samba.org/pub/samba/stable/samba-${SAMBA_VERSION}.tar.gz"
    fi
    rm -rf "samba-${SAMBA_VERSION}"
    tar xf "samba-${SAMBA_VERSION}.tar.gz"
    cd "samba-${SAMBA_VERSION}"

    # ---- Patch 1: Stub libpthread ----
    # NetBSD 5's real libpthread uses LWP scheduler activation syscalls
    # (sa_register etc.) that crash on the NetBSD 4.0 kernel. Samba only
    # needs 5 pthread functions, and since we run single-threaded on a
    # 256 MB device, we replace libpthread.a with no-op stubs.
    log "Creating stub libpthread.a for NetBSD 4.0 compatibility..."
    cat > /tmp/pthread_stub.c <<'STUBEOF'
typedef unsigned long pt_stub_t;
typedef struct { char _d[256]; } pt_attr_stub_t;
int pthread_create(pt_stub_t *t, const pt_attr_stub_t *a,
                   void *(*start)(void*), void *arg) { return 78; }
int pthread_attr_init(pt_attr_stub_t *a) {
    char *p = (char *)a; int i;
    for (i = 0; i < (int)sizeof(*a); i++) p[i] = 0;
    return 0;
}
int pthread_attr_destroy(pt_attr_stub_t *a) { return 0; }
int pthread_attr_setdetachstate(pt_attr_stub_t *a, int d) { return 0; }
int pthread_atfork(void (*prepare)(void), void (*parent)(void),
                   void (*child)(void)) { return 0; }
void pthread__init(void) { }
void pthread_lockinit(void) { }
void pthread__lockprim_init(void) { }
STUBEOF
    ${CC} ${CFLAGS} -c /tmp/pthread_stub.c -o /tmp/pthread_stub.o
    ${AR} rcs /tmp/libpthread_stub.a /tmp/pthread_stub.o
    if [ -f "${SYSROOT}/usr/lib/libpthread.a" ]; then
        cp "${SYSROOT}/usr/lib/libpthread.a" "${SYSROOT}/usr/lib/libpthread.a.real" 2>/dev/null || true
    fi
    cp /tmp/libpthread_stub.a "${SYSROOT}/usr/lib/libpthread.a"

    # ---- Patch 2: Disable talloc magic randomization ----
    # talloc's __attribute__((constructor)) talloc_lib_init() randomizes the
    # talloc_magic value. On NetBSD 4.0 with OABI static linking, constructors
    # from library .o files fire AFTER main() has started, which corrupts
    # talloc_magic after chunks have already been allocated with
    # TALLOC_MAGIC_NON_RANDOM, causing segfaults.
    log "Disabling talloc_lib_init constructor for NB4 compatibility..."
    sed -i 's/^#ifdef HAVE_CONSTRUCTOR_ATTRIBUTE/#if 0 \/* DISABLED for NB4: constructor fires after main *\//' \
        lib/talloc/talloc.c

    # Also add a re-entrancy guard to talloc_log to prevent infinite
    # recursion if talloc_abort triggers talloc allocation via the log fn.
    sed -i '/^static void talloc_log(const char \*fmt, \.\.\.)/,/^{/ {
        /^{/ a\
\tstatic int _talloc_log_guard = 0;\
\tif (_talloc_log_guard) return;\
\t_talloc_log_guard = 1;
    }' lib/talloc/talloc.c
    # Reset guard before function returns
    sed -i '/talloc_free(message);/a\\t_talloc_log_guard = 0;' lib/talloc/talloc.c

    # ---- Patch 3: Non-fatal talloc_abort ----
    # Make talloc_abort log-and-return instead of calling abort(). On NB4
    # with static linking, residual talloc use-after-free from edge cases
    # would otherwise kill the process. The root causes are patched out
    # (reload_services, lp_load calls), but this is belt-and-suspenders.
    log "Making talloc_abort non-fatal..."
    sed -i '/^static void talloc_abort(const char \*reason)/,/^}/ {
        /abort();/ {
            s|abort();|/* TC-PATCH: non-fatal */ return;|
        }
    }' lib/talloc/talloc.c

    # ---- Patch 4: Make reload_services a no-op after initial load ----
    # lp_load_with_shares() frees the talloc loadparm context (Globals.ctx).
    # In forked children, pointers to the old context still exist, causing
    # use-after-free crashes. Config never changes at runtime on the TC.
    log "Patching reload_services to be no-op after initial load..."
    sed -i '/^bool reload_services(struct smbd_server_connection \*sconn,/,/^{/ {
        /^{/ a\
\t/* TC-PATCH: no-op after initial load — lp_load frees talloc context */\
\tstatic bool initial_load_done = false;\
\tif (initial_load_done) { reopen_logs(); return true; }\
\tinitial_load_done = true;
    }' source3/smbd/server_reload.c

    # ---- Patch 5: Remove direct lp_load calls in auth path ----
    # auth_ntlmssp.c and auth_generic.c call lp_load_with_shares() directly,
    # bypassing reload_services(). These also cause use-after-free.
    log "Removing lp_load calls from auth path..."
    sed -i 's|lp_load_with_shares(get_dyn_CONFIGFILE());|/* TC-PATCH: skip lp_load — talloc UAF */|' \
        source3/auth/auth_ntlmssp.c source3/auth/auth_generic.c

    # ---- Patch 6: Skip ownership checks in directory_create_or_exist_strict ----
    # HFS+ on the Time Capsule returns uid=4294967295 for all files.
    # The strict ownership check always fails. Skip it entirely.
    log "Patching directory_create_or_exist_strict for HFS+..."
    sed -i '/^int directory_create_or_exist_strict/,/^{/ {
        /^{/ a\
\t/* TC-PATCH: HFS+ returns uid=4294967295; skip ownership checks */\
\t(void)uid; (void)dir_perms;\
\treturn directory_create_or_exist(dname, dir_perms);
    }' lib/util/util.c

    # ---- Patch 7: Disable REALPATH_TAKES_NULL ----
    # NetBSD 4.0 realpath() does NOT support NULL as the resolved buffer.
    # The cross-answers say OK but it crashes on the target.
    log "Disabling REALPATH_TAKES_NULL..."
    sed -i 's|#ifdef REALPATH_TAKES_NULL|#if 0 /* TC-PATCH: NB4 realpath does not support NULL */|' \
        source3/lib/system.c

    # Put native Heimdal tools on PATH
    export PATH="${WORKDIR}/heimdal-native/bin:${PATH}"

    # Cross-answers file for NetBSD 4.0 evbarm OABI (ARM, 32-bit LE)
    cat > cross-answers.txt <<'ANSWERS'
# System identification
Checking uname sysname type: "NetBSD"
Checking uname machine type: "evbarm"
Checking uname release type: "4.0_STABLE"
Checking uname version type: "NetBSD 4.0_STABLE"
# Basic compiler/linker
Checking simple C program: OK
rpath library support: OK
-Wl,--version-script support: NO
# Large file support
Checking getconf LFS_CFLAGS: NO
Checking for large file support without additional flags: OK
Checking for -D_FILE_OFFSET_BITS=64: OK
Checking for -D_LARGE_FILES: OK
# lib/replace checks
Checking correct behavior of strtoll: OK
Checking for working strptime: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: NO
Checking for HAVE_INCOHERENT_MMAP: NO
Checking for HAVE_SECURE_MKSTEMP: OK
# Network interface detection
Checking for HAVE_IFACE_GETIFADDRS: OK
Checking for HAVE_IFACE_AIX: NO
Checking for HAVE_IFACE_IFCONF: NO
Checking for HAVE_IFACE_IFREQ: NO
# Signal/value checks
Checking value of NSIG: "33"
Checking value of _NSIG: NO
Checking value of SIGRTMAX: NO
Checking value of SIGRTMIN: NO
Checking value of SCHAR_MAX: "127"
Checking value of __STDC_ISO_10646__: NO
# iconv/charset
Checking if can we convert from CP850 to UCS-2LE: NO
Checking if can we convert from IBM850 to UCS-2LE: NO
Checking if can we convert from UTF-8 to UCS-2LE: OK
Checking if can we convert from UTF8 to UCS-2LE: OK
Checking errno of iconv for illegal multibyte sequence: OK
# Linux-specific (all NO on NetBSD)
Checking for kernel change notify support: NO
Checking for Linux kernel oplocks: NO
Checking for kernel share modes: NO
Checking whether Linux should use 32-bit credential calls: NO
Checking whether we can use Linux thread-specific credentials with 32-bit system calls: NO
Checking whether we can use Linux thread-specific credentials: NO
# Privilege/setuid
Checking whether setreuid is available: OK
Checking whether setresuid is available: NO
Checking whether seteuid is available: OK
Checking whether setuidx is available: NO
# File locking (CRITICAL)
Checking whether fcntl locking is available: OK
Checking whether fcntl lock supports open file description locks: NO
# Filesystem/misc
Checking for the maximum value of the 'time_t' type: OK
Checking whether the realpath function allows a NULL argument: NO
Checking for ftruncate extend: OK
getcwd takes a NULL argument: OK
Checking whether pututline returns pointer: NO
# statfs
vfs_fileid checking for statfs() and struct statfs.f_fsid: NO
Checking for *bsd style statfs with statfs.f_iosize: OK
# Quota/RPC
checking for clnt_create(): NO
for QUOTACTL_4A: long quotactl(int cmd, char *special, qid_t id, caddr_t addr): NO
for QUOTACTL_4B:  int quotactl(const char *path, int cmd, int id, char *addr): OK
# POSIX capabilities
Checking whether POSIX capabilities are available: NO
# Kerberos
Checking whether the WRFILE -keytab is supported: NO
# Endianness runtime fallback
Checking for HAVE_LITTLE_ENDIAN - runtime: OK
Checking for HAVE_BIG_ENDIAN - runtime: NO
# Linux netlink (NO on NetBSD)
Checking whether Linux netlink is available: NO
Checking whether Linux rtnetlink is available: NO
ANSWERS

    # Samba 4.8 waf requires Python 2
    if command -v python2 >/dev/null 2>&1; then
        SAMBA_PYTHON="python2"
    elif python --version 2>&1 | grep -q "Python 2"; then
        SAMBA_PYTHON="python"
    else
        echo "ERROR: Samba 4.8 requires Python 2. Install python2."
        exit 1
    fi

    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export PYTHON="${SAMBA_PYTHON}"
    export CFLAGS="${CFLAGS} -I${PREFIX}/include"
    export CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include"
    export LDFLAGS="${LDFLAGS} -L${PREFIX}/lib -static"

    ./configure \
        --cross-compile \
        --cross-answers=cross-answers.txt \
        --prefix=/Volumes/dk2/samba \
        --without-ad-dc \
        --without-ntvfs-fileserver \
        --without-systemd \
        --without-gettext \
        --without-acl-support \
        --without-pam \
        --without-ldap \
        --without-ads \
        --without-winbind \
        --disable-python \
        --without-pie \
        --nonshared-binary=smbd/smbd \
        --with-static-modules=catia,vfs_fruit,vfs_streams_xattr \
        --bundled-libraries=ALL,!asn1_compile,!compile_et

    # Fix cross-compilation config.h errors
    log "Patching config.h for NetBSD cross-compilation..."
    sed -i \
        -e 's/#define HAVE_QUOTACTL_LINUX 1/\/* #undef HAVE_QUOTACTL_LINUX -- NetBSD *\//' \
        -e 's/#define HAVE_SYS_QUOTAS 1/\/* #undef HAVE_SYS_QUOTAS -- NetBSD *\//' \
        -e 's/#define WITH_QUOTAS 1/\/* #undef WITH_QUOTAS -- NetBSD *\//' \
        -e 's/#define HAVE_LINUX_IOCTL_H 1/\/* #undef HAVE_LINUX_IOCTL_H -- NetBSD *\//' \
        bin/default/include/config.h

    # Build smbd
    ${SAMBA_PYTHON} ./buildtools/bin/waf build --targets=smbd/smbd -j "$(nproc)" -v 2>&1 | tee /tmp/waf-build.log | grep -v "^\[" | tail -5

    # Re-link statically: device has no shared libraries or dynamic linker.
    # The waf build log prefixes link commands with "HH:MM:SS runner ..."
    # and uses relative .o paths from bin/, so we must:
    #  1. Strip the timestamp + "runner" prefix
    #  2. Add -static flag
    #  3. Run from the bin/ directory
    log "Re-linking smbd statically (device has no ld.elf_so)..."
    LINK_LINE=$(grep "\-o.*default/source3/smbd/smbd" /tmp/waf-build.log | tail -1)
    if [ -z "${LINK_LINE}" ]; then
        log "ERROR: Could not find link command in build log"
        exit 1
    fi
    # Strip waf runner prefix (e.g. "09:28:41 runner ")
    LINK_LINE=$(echo "${LINK_LINE}" | sed 's|^[0-9:]*[[:space:]]*runner[[:space:]]*||')
    # Insert -static flag and remove any -pie
    STATIC_CMD=$(echo "${LINK_LINE}" | sed 's|-o |-static -o |; s| -pie||g')
    # Save to script and execute from bin/ where the relative .o paths resolve
    echo "${STATIC_CMD}" > /tmp/static-link-cmd.sh
    cd bin
    bash /tmp/static-link-cmd.sh
    cd ..

    log "Stripping binary..."
    ${STRIP} bin/default/source3/smbd/smbd

    log "Binary info:"
    file bin/default/source3/smbd/smbd
    ls -lh bin/default/source3/smbd/smbd
}

# ---------------------------------------------------------------------------
# Step 5: Patch ELF binary for Time Capsule kernel
# ---------------------------------------------------------------------------
patch_elf_osabi() {
    local BINARY="$1"
    log "Patching ELF EI_OSABI to 0x61 for Time Capsule kernel compatibility..."

    # EI_OSABI is at offset 7 in the ELF header
    # 0x61 = 97 decimal, this is what the TC kernel expects
    printf '\x61' | dd of="${BINARY}" bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

    # Patch .note.netbsd.ident version from 502000000 (NB 5.2) to 400000000 (NB 4.0)
    # The kernel checks this note and refuses to run binaries targeting a newer version.
    # The note is at ELF offset 0xe8 as a 32-bit LE integer.
    log "Patching NetBSD version note to 4.0..."
    python3 -c "
import struct
with open('${BINARY}', 'r+b') as f:
    f.seek(0xe8)
    f.write(struct.pack('<I', 400000000))
" 2>/dev/null || printf '\x00\x84\xd7\x17' | dd of="${BINARY}" bs=1 seek=232 count=4 conv=notrunc 2>/dev/null

    log "ELF header after patching:"
    xxd -l 16 "${BINARY}" || od -A x -t x1z -N 16 "${BINARY}"
}

# ---------------------------------------------------------------------------
# Step 6: Package output
# ---------------------------------------------------------------------------
package_output() {
    local SMBD_BIN="${WORKDIR}/samba-${SAMBA_VERSION}/bin/default/source3/smbd/smbd"

    # Patch ELF before packaging
    patch_elf_osabi "${SMBD_BIN}"

    log "Packaging output..."
    mkdir -p "${OUTPUT_DIR}"
    cp "${SMBD_BIN}" "${OUTPUT_DIR}/smbd"

    cd "${OUTPUT_DIR}"
    sha256sum smbd > SHA256SUMS
    log "Output in ${OUTPUT_DIR}:"
    ls -lh "${OUTPUT_DIR}"
    cat SHA256SUMS
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "${WORKDIR}" "${PREFIX}"

    build_toolchain
    build_gmp
    build_nettle
    build_native_heimdal
    build_samba
    package_output

    log "Build complete!"
}

main "$@"
