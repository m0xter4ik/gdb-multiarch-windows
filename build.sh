#!/usr/bin/env bash

# The versions of GDB and libGMP that we will build
GDB_VERSION='17.2'
GMP_VERSION='6.3.0'
MPFR_VERSION='4.2.2'
PDCURSES_VERSION='3.9'
EXPAT_VERSION='2.7.1'

# Determine the number of logical CPU cores the host system has
CPU_CORES=`lscpu -e=CORE | tail -n +2 | wc -l`
#CPU_CORES=1

# Perform the build, using all available CPU cores
docker buildx build --progress=plain --build-arg "CPU_CORES=$CPU_CORES" \
                                     --build-arg "GDB_VERSION=$GDB_VERSION" \
                                     --build-arg "GMP_VERSION=$GMP_VERSION" \
                                     --build-arg "MPFR_VERSION=$MPFR_VERSION" \
                                     --build-arg "PDCURSES_VERSION=$PDCURSES_VERSION" \
                                     --build-arg "EXPAT_VERSION=$EXPAT_VERSION" \
                                     -t "gdb-cross-builder:$GDB_VERSION" .

# Copy the built files to the host filesystem
docker run --rm -ti --user root -v "`pwd`:/hostdir" "gdb-cross-builder:$GDB_VERSION" cp "/tmp/dist/gdb-multiarch-${GDB_VERSION}.zip" /hostdir/
sudo chown ${USER}:${USER} gdb-multiarch-${GDB_VERSION}.zip
