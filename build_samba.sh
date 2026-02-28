#!/usr/bin/env bash
#
# build_samba.sh — Cross-compile Samba 4.8.12 for NetBSD evbarm (Time Capsule)
#
# Produces a statically-linked smbd binary with catia, fruit, streams_xattr
# modules baked in. Target: ARM Cortex-A9, earmv4 ABI, NetBSD 6.0.
#
# Dependencies: git, curl, gcc, make, python2 (Samba 4.8 build), bison, flex
# Typically run inside a Debian container via CI.
#
set -euo pipefail

SAMBA_VERSION="4.8.12"
NETBSD_BRANCH="netbsd-6"
GMP_VERSION="6.2.1"
NETTLE_VERSION="3.7.3"
GNUTLS_VERSION="3.6.16"

WORKDIR="${WORKDIR:-/tmp/tc-build}"
PREFIX="${WORKDIR}/install"
TOOLDIR="${WORKDIR}/tools"
SYSROOT="${WORKDIR}/sysroot"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/dist}"

NBMAKE=""
TARGET_ARCH="evbarm"
TARGET_MACHINE="earmv4"
CROSS_PREFIX=""

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Step 1: Build NetBSD cross-toolchain
# ---------------------------------------------------------------------------
build_toolchain() {
    log "Fetching NetBSD source tree..."
    if [ ! -d "${WORKDIR}/netbsd-src" ]; then
        git clone --depth 1 --branch "${NETBSD_BRANCH}" \
            https://github.com/NetBSD/src.git "${WORKDIR}/netbsd-src"
    fi

    log "Building NetBSD cross-toolchain for ${TARGET_ARCH}..."
    cd "${WORKDIR}/netbsd-src"
    ./build.sh -U -m "${TARGET_ARCH}" -j "$(nproc)" \
        -T "${TOOLDIR}" -D "${SYSROOT}" tools

    # Locate the cross-compiler prefix
    CROSS_PREFIX=$(ls "${TOOLDIR}/bin/"*-gcc 2>/dev/null | head -1 | sed 's/-gcc$//' || true)
    if [ -z "${CROSS_PREFIX}" ]; then
        # Try to find it from the tooldir structure
        CROSS_PREFIX="${TOOLDIR}/bin/arm--netbsdelf-earmv4"
    fi

    NBMAKE="${TOOLDIR}/bin/nbmake-${TARGET_ARCH}"
    export CC="${CROSS_PREFIX}-gcc"
    export CXX="${CROSS_PREFIX}-g++"
    export AR="${CROSS_PREFIX}-ar"
    export RANLIB="${CROSS_PREFIX}-ranlib"
    export STRIP="${CROSS_PREFIX}-strip"

    log "Cross-compiler: ${CC}"
}

# ---------------------------------------------------------------------------
# Step 2: Build static dependencies (GMP, Nettle, GnuTLS)
# ---------------------------------------------------------------------------
build_gmp() {
    log "Building GMP ${GMP_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "gmp-${GMP_VERSION}.tar.xz" ]; then
        curl -LO "https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz"
    fi
    tar xf "gmp-${GMP_VERSION}.tar.xz"
    cd "gmp-${GMP_VERSION}"
    ./configure \
        --host=arm-netbsdelf \
        --prefix="${PREFIX}" \
        --enable-static --disable-shared
    make -j "$(nproc)"
    make install
}

build_nettle() {
    log "Building Nettle ${NETTLE_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "nettle-${NETTLE_VERSION}.tar.gz" ]; then
        curl -LO "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VERSION}.tar.gz"
    fi
    tar xf "nettle-${NETTLE_VERSION}.tar.gz"
    cd "nettle-${NETTLE_VERSION}"
    ./configure \
        --host=arm-netbsdelf \
        --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --with-lib-path="${PREFIX}/lib" \
        --with-include-path="${PREFIX}/include" \
        CFLAGS="-I${PREFIX}/include" \
        LDFLAGS="-L${PREFIX}/lib"
    make -j "$(nproc)"
    make install
}

build_gnutls() {
    log "Building GnuTLS ${GNUTLS_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "gnutls-${GNUTLS_VERSION}.tar.xz" ]; then
        curl -LO "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.6/gnutls-${GNUTLS_VERSION}.tar.xz"
    fi
    tar xf "gnutls-${GNUTLS_VERSION}.tar.xz"
    cd "gnutls-${GNUTLS_VERSION}"
    ./configure \
        --host=arm-netbsdelf \
        --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --without-p11-kit \
        --without-idn \
        --without-tpm \
        --disable-cxx \
        --disable-doc \
        --disable-tools \
        --disable-tests \
        GMP_CFLAGS="-I${PREFIX}/include" \
        GMP_LIBS="-L${PREFIX}/lib -lgmp" \
        NETTLE_CFLAGS="-I${PREFIX}/include" \
        NETTLE_LIBS="-L${PREFIX}/lib -lnettle" \
        HOGWEED_CFLAGS="-I${PREFIX}/include" \
        HOGWEED_LIBS="-L${PREFIX}/lib -lhogweed"
    make -j "$(nproc)"
    make install
}

# ---------------------------------------------------------------------------
# Step 3: Cross-compile Samba
# ---------------------------------------------------------------------------
build_samba() {
    log "Building Samba ${SAMBA_VERSION}..."
    cd "${WORKDIR}"
    if [ ! -f "samba-${SAMBA_VERSION}.tar.gz" ]; then
        curl -LO "https://download.samba.org/pub/samba/stable/samba-${SAMBA_VERSION}.tar.gz"
    fi
    tar xf "samba-${SAMBA_VERSION}.tar.gz"
    cd "samba-${SAMBA_VERSION}"

    # Cross-answers file for NetBSD ARM
    cat > cross-answers.txt <<'ANSWERS'
Checking uname sysname type: "NetBSD"
Checking uname machine type: "evbarm"
Checking uname release type: "6.0"
Checking uname version type: "NetBSD 6.0"
Checking simple C program: OK
rpath library support: OK
-Wl,--version-script support: NO
Checking getconf LFS_CFLAGS: NO
Checking for large file support without additional flags: OK
Checking for -D_FILE_OFFSET_BITS=64: OK
Checking for -D_LARGE_FILES: OK
Checking correct behavior of strtoll: OK
Checking for working strptime: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: NO
Checking for HAVE_INCOHERENT_MMAP: NO
Checking for HAVE_SECURE_MKSTEMP: OK
Checking value of NSIG: 64
Checking value of SCHAR_MAX: 127
Checking value of __STDC_ISO_10646__: NO
Checking for kernel change notify support: NO
Checking for Linux kernel oplocks: NO
Checking for kernel share modes: NO
Checking if can we convert from CP850 to UCS-2LE: NO
Checking if can we convert from UTF-8 to UCS-2LE: OK
ANSWERS

    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
    ./configure \
        --cross-compile \
        --cross-answers=cross-answers.txt \
        --prefix=/Volumes/dk2/samba \
        --without-ad-dc \
        --without-ads \
        --without-ldap \
        --without-winbind \
        --without-pam \
        --without-systemd \
        --without-acl-support \
        --disable-python \
        --disable-cups \
        --disable-iprint \
        --nonshared-binary=smbd/smbd \
        --with-static-modules=catia,vfs_fruit,vfs_streams_xattr \
        CFLAGS="-I${PREFIX}/include" \
        LDFLAGS="-L${PREFIX}/lib -static"

    make -j "$(nproc)" bin/default/source3/smbd/smbd

    log "Stripping binary..."
    ${STRIP} bin/default/source3/smbd/smbd

    log "Binary info:"
    file bin/default/source3/smbd/smbd
    ls -lh bin/default/source3/smbd/smbd
}

# ---------------------------------------------------------------------------
# Step 4: Package output
# ---------------------------------------------------------------------------
package_output() {
    log "Packaging output..."
    mkdir -p "${OUTPUT_DIR}"
    cp "${WORKDIR}/samba-${SAMBA_VERSION}/bin/default/source3/smbd/smbd" "${OUTPUT_DIR}/smbd"

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
    mkdir -p "${WORKDIR}"

    build_toolchain
    build_gmp
    build_nettle
    build_gnutls
    build_samba
    package_output

    log "Build complete!"
}

main "$@"
