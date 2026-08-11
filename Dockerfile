FROM ubuntu:24.04 as SOURCES

ARG CPU_CORES=8
ARG GMP_VERSION=6.3.0
ARG MPFR_VERSION=4.2.2
ARG GDB_VERSION=17.2
ARG PDCURSES_VERSION=3.9
ARG EXPAT_VERSION=2.7.1

# Install our build dependencies
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN --mount=type=cache,target=/var/cache/apt --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        curl \
        g++-mingw-w64-x86-64-posix \
        gcc-mingw-w64-x86-64-posix \
        tar \
        zip \
        xz-utils \
#        libncurses-dev \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user and perform all build steps as this user (this simplifies things a little when later copying files out of the container image)
RUN useradd --create-home --home /home/nonroot --shell /bin/bash nonroot

USER nonroot

RUN mkdir -p /tmp/src /tmp/build /tmp/install

# Curses
RUN curl -fSL \
    "https://github.com/wmcbrine/PDCurses/archive/refs/tags/${PDCURSES_VERSION}.tar.gz" \
    -o /tmp/pdcurses.tar.gz && \
    tar xf /tmp/pdcurses.tar.gz -C /tmp/src

# Expat
RUN curl -fSL \
    "https://github.com/libexpat/libexpat/releases/download/R_$(echo ${EXPAT_VERSION} | tr '.' '_')/expat-${EXPAT_VERSION}.tar.xz" \
    -o /tmp/expat.tar.xz && \
    tar xf /tmp/expat.tar.xz -C /tmp/src

# GMP
RUN curl -fSL \
    "https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz" \
    -o "/tmp/gmp.tar.xz" && \
    tar xf /tmp/gmp.tar.xz -C /tmp/src

# MPFR
RUN curl -fSL \
    "https://www.mpfr.org/mpfr-${MPFR_VERSION}/mpfr-${MPFR_VERSION}.tar.xz" \
    -o "/tmp/mpfr.tar.xz" && \
    tar xf /tmp/mpfr.tar.xz -C /tmp/src

# GDB
RUN curl -fSL \
    "https://ftp.gnu.org/gnu/gdb/gdb-${GDB_VERSION}.tar.xz" \
    -o "/tmp/gdb.tar.xz" && \
    tar xf /tmp/gdb.tar.xz -C /tmp/src

FROM SOURCES AS DEPS_BUILD

# Build PDCurses
RUN cd /tmp/src/PDCurses-${PDCURSES_VERSION}/wincon && \
    make -f Makefile -j"${CPU_CORES}" \
        CC=x86_64-w64-mingw32-gcc \
        AR=x86_64-w64-mingw32-ar \
        RANLIB=x86_64-w64-mingw32-ranlib

# Providing PDCurses as ncurses for gdb
USER root
RUN cp /tmp/src/PDCurses-${PDCURSES_VERSION}/curses.h \
       /usr/x86_64-w64-mingw32/include/ && \
    cp /tmp/src/PDCurses-${PDCURSES_VERSION}/wincon/pdcurses.a \
       /usr/x86_64-w64-mingw32/lib/libcurses.a
USER nonroot

# Build Expat
RUN mkdir -p /tmp/build/expat && \
    cd /tmp/build/expat && \
    "/tmp/src/expat-${EXPAT_VERSION}/configure" \
        --prefix=/tmp/install/expat \
        --host=x86_64-w64-mingw32 \
        --enable-static \
        --disable-shared && \
    make -j"${CPU_CORES}" && \
    make install

# Build GMP for Windows
RUN mkdir -p /tmp/build/gmp && \
    cd /tmp/build/gmp && \
    "/tmp/src/gmp-${GMP_VERSION}/configure" \
        --prefix=/tmp/install/gmp \
        --host=x86_64-w64-mingw32 \
        --enable-static \
        --disable-shared && \
    make -j"${CPU_CORES}" && \
    make install

# Build MPFR for Windows
RUN mkdir -p /tmp/build/mpfr && \
    cd /tmp/build/mpfr && \
    "/tmp/src/mpfr-${MPFR_VERSION}/configure" \
        --prefix=/tmp/install/mpfr \
        --host=x86_64-w64-mingw32 \
        --with-gmp=/tmp/install/gmp \
        --enable-static \
        --disable-shared && \
    make -j"${CPU_CORES}" && \
    make install

FROM DEPS_BUILD AS PROJECT_BUILD

# Cross-compile GDB for Windows with MinGW-w64, enabling multi-architecture support for debugging both Windows and Linux target applications
# (See:
# - https://stackoverflow.com/a/61363144
# - https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=gdb-multiarch
# - https://github.com/msys2/MINGW-packages/blob/master/mingw-w64-gdb/PKGBUILD)
RUN mkdir -p /tmp/build/gdb && \
    cd /tmp/build/gdb && \
      CPPFLAGS="-I/tmp/install/expat/include" \
      LDFLAGS="-L/tmp/install/expat/lib" \
      "/tmp/src/gdb-${GDB_VERSION}/configure" \
        --build=x86_64-linux-gnu \
        --host=x86_64-w64-mingw32 \
        --target=x86_64-w64-mingw32 \
        --prefix=/tmp/install/gdb \
        --enable-targets=all \
        --enable-tui \
        --with-curses \
        --with-expat \
        --with-gmp=/tmp/install/gmp \
        --with-mpfr=/tmp/install/mpfr \
        --with-static-standard-libraries \
        --enable-static \
        --disable-shared \
        --disable-ld \
        --disable-gold \
        --disable-sim && \
    make -j"${CPU_CORES}" && \
    make install

# Copy the GDB distribution from the built files and strip away debug symbols to reduce the filesize
RUN mkdir -p /tmp/dist && \
    cp -R /tmp/install/gdb/* /tmp/dist/ && \
    mv /tmp/dist/bin/gdb.exe /tmp/dist/bin/gdb-multiarch.exe && \
    x86_64-w64-mingw32-strip -s /tmp/dist/bin/gdb-multiarch.exe && \
    x86_64-w64-mingw32-strip -s /tmp/dist/bin/gdbserver.exe && \
	mkdir -p /tmp/dist/lib/debug && \
	mkdir -p /tmp/dist/lib/gdb

# Copy the license files for GDB and its dependencies
RUN mkdir -p /tmp/dist/licenses/gdb && cp "/tmp/src/gdb-${GDB_VERSION}/COPYING" /tmp/dist/licenses/gdb/ && \
        mkdir -p /tmp/dist/licenses/gmp && cp "/tmp/src/gmp-${GMP_VERSION}/COPYING" /tmp/dist/licenses/gmp/ && \
        mkdir -p /tmp/dist/licenses/bfd && cp "/tmp/src/gdb-${GDB_VERSION}/bfd/COPYING" /tmp/dist/licenses/bfd/ && \
        mkdir -p /tmp/dist/licenses/libiberty && cp "/tmp/src/gdb-${GDB_VERSION}/libiberty/COPYING.LIB" /tmp/dist/licenses/libiberty/ && \
        mkdir -p /tmp/dist/licenses/zlib && cp "/tmp/src/gdb-${GDB_VERSION}/zlib/README" /tmp/dist/licenses/zlib/ && \
        mkdir -p /tmp/dist/licenses/pdcurses && cp "/tmp/src/PDCurses-${PDCURSES_VERSION}/wincon/README.md" /tmp/dist/licenses/pdcurses/ && \
        mkdir -p /tmp/dist/licenses/libexpat && cp "/tmp/src/expat-${EXPAT_VERSION}/COPYING" /tmp/dist/licenses/libexpat/

# Retrieve the license files for GCC, since libgcc and libstdc++ are statically linked into the GDB executable
RUN mkdir -p /tmp/dist/licenses/gcc && \
        curl -fSL 'https://raw.githubusercontent.com/gcc-mirror/gcc/master/COPYING3' -o /tmp/dist/licenses/gcc/COPYING3 && \
        curl -fSL 'https://raw.githubusercontent.com/gcc-mirror/gcc/master/COPYING.RUNTIME' -o /tmp/dist/licenses/gcc/COPYING.RUNTIME

# Create a README file with links to the locations of the source code for GDB and its dependencies
RUN echo 'This directory contains a distribution of The GNU Project Debugger (GDB) in object form.' >> /tmp/dist/README.txt && \
        echo 'The binary was cross-compiled for Windows with MinGW-w64, and is statically linked against libgcc and libstdc++.' >> /tmp/dist/README.txt && \
        echo 'This distribution of GDB is configured for debugging remote Linux applications from a local Windows system.' >> /tmp/dist/README.txt && \
        echo '' >> /tmp/dist/README.txt && \
        echo 'The licenses for GDB and its dependencies can be found in the `licenses` subdirectory.' >> /tmp/dist/README.txt && \
        echo '' >> /tmp/dist/README.txt && \
        echo 'The source code for GDB and its dependencies can be downloaded from the following URLs:' >> /tmp/dist/README.txt && \
        echo '' >> /tmp/dist/README.txt && \
        echo "- https://ftp.gnu.org/gnu/gdb/gdb-${GDB_VERSION}.tar.gz" >> /tmp/dist/README.txt && \
        echo "- https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz" >> /tmp/dist/README.txt && \
        echo "- https://www.mpfr.org/mpfr-${MPFR_VERSION}/mpfr-${MPFR_VERSION}.tar.xz" >> /tmp/dist/README.txt && \
        echo '- https://github.com/gcc-mirror/gcc' >> /tmp/dist/README.txt && \
        echo "- https://github.com/wmcbrine/PDCurses/archive/refs/tags/${PDCURSES_VERSION}.tar.gz" >> /tmp/dist/README.txt && \
        echo "- https://github.com/libexpat/libexpat/releases/download/R_$(echo ${EXPAT_VERSION} | tr '.' '_')/expat-${EXPAT_VERSION}.tar.xz" >> /tmp/dist/README.txt && \
        echo '' >> /tmp/dist/README.txt

# Create a ZIP archive of the files for distribution
RUN cd /tmp/dist && \
        zip -r "gdb-multiarch-${GDB_VERSION}.zip" *
