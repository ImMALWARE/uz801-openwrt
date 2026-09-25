FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
        gettext git libncurses5-dev libssl-dev python3-setuptools rsync swig \
        unzip zlib1g-dev file wget python3-cryptography mkbootimg qemu-utils \
        asciidoc help2man xsltproc bc binutils bzip2 make patch time \
        device-tree-compiler e2fsprogs fdisk util-linux nano perl perl-modules python3-dev \
        xz-utils zstd zip libelf-dev libfdt-dev \
        gcc-arm-none-eabi binutils-arm-none-eabi \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/*