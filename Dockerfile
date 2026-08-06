# syntax=docker/dockerfile:1.7
#
# crustybox — a pure-Rust, memory-safe BusyBox replacement.
#
#   /bin/coreutils  uutils coreutils multicall binary (MIT)
#   /bin/brush      brush, a bash/POSIX-compatible shell written in Rust (MIT)
#   /bin/<util>     symlink -> coreutils, one per compiled-in utility
#   /bin/sh         symlink -> brush
#   /bin/procs      procs, a ps-alike process viewer (MIT)
#   /bin/btm        bottom, a top-alike process/system monitor (MIT)
#   /bin/ouch       ouch, tar/gzip/zip/zstd/xz/7z/bzip2 archive tool (MIT)
#   /bin/diff       symlink -> diffutils (uutils/diffutils, MIT)
#   /bin/cmp        symlink -> diffutils
#   /bin/find       uutils/findutils (MIT)
#   /bin/locate     uutils/findutils
#   /bin/updatedb   uutils/findutils
#   /bin/xargs      uutils/findutils
#   /bin/sed        uutils/sed (MIT)
#   /bin/grep       uutils/grep (MIT)
#
# None of procs/btm/ouch are byte-compatible CLI/output replacements for the
# classic ps/top/tar -- they're separate tools that happen to cover the same
# job, shipped under their own names rather than aliased over the legacy
# ones. diffutils/findutils/sed/grep, by contrast, are uutils' own
# drop-in-compatible rewrites of the real GNU tools of those names -- same
# project, same compatibility goal as coreutils. `grep` is the least mature
# of the bunch (v0.1.0 at time of writing); worth revisiting as it matures.
#
# All binaries are statically linked against musl and shipped, stripped and
# UPX-compressed, in a `FROM scratch` image with no libc, shell, or package
# manager other than what we just built.

# The upstream releases this project tracks. `versions.env` in the repo root
# holds the currently-pinned values and is kept up to date by
# .github/workflows/check-upstream.yml; --build-arg overrides these defaults.
ARG RUST_VERSION=1
ARG UUTILS_COREUTILS_VERSION=0.10.0
ARG BRUSH_SHELL_VERSION=0.4.0
ARG PROCS_VERSION=0.14.12
ARG BOTTOM_VERSION=0.14.7
ARG OUCH_VERSION=0.8.0
ARG DIFFUTILS_VERSION=0.5.0
ARG FINDUTILS_VERSION=0.10.0
ARG SED_VERSION=0.1.1
ARG GREP_VERSION=0.1.0
ARG UPX_VERSION=4.2.4
ARG NONROOT_UID=65532
ARG NONROOT_GID=65532

################################################################################
# builder
#
# Pinned to --platform=$BUILDPLATFORM so this stage always runs *natively* on
# the machine driving the build, regardless of which TARGETPLATFORM buildx is
# currently producing. We cross-compile to the musl target with a plain
# cross-gcc used only as a linker driver -- rustup's musl target component
# already ships its own static libc/CRT objects, so no QEMU emulation is ever
# needed to run rustc/cargo itself.
################################################################################
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim-bookworm AS builder

ARG TARGETPLATFORM
ARG TARGETARCH
ARG UUTILS_COREUTILS_VERSION
ARG BRUSH_SHELL_VERSION
ARG PROCS_VERSION
ARG BOTTOM_VERSION
ARG OUCH_VERSION
ARG DIFFUTILS_VERSION
ARG FINDUTILS_VERSION
ARG SED_VERSION
ARG GREP_VERSION
ARG UPX_VERSION

# crossbuild-essential-{arm64,amd64} guarantee an aarch64-linux-gnu-gcc and
# x86_64-linux-gnu-gcc are both available no matter which arch is building
# (an amd64 CI runner producing an arm64 image, an Apple Silicon host
# producing an amd64 image, etc). They double as our strip toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
        crossbuild-essential-arm64 \
        crossbuild-essential-amd64 \
        curl \
        ca-certificates \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Fetch a static UPX release for the *build* host arch. A single UPX binary
# ships decompression stubs for every architecture it can target, so a
# host-native UPX is able to compress binaries for any TARGETARCH.
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)  upx_arch=amd64_linux ;; \
        aarch64) upx_arch=arm64_linux ;; \
        *) echo "unsupported build host arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/upx.tar.xz \
        "https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-${upx_arch}.tar.xz"; \
    tar -xJf /tmp/upx.tar.xz -C /tmp; \
    install -m 0755 "/tmp/upx-${UPX_VERSION}-${upx_arch}/upx" /usr/local/bin/upx; \
    rm -rf /tmp/upx*

# Map buildx's TARGETPLATFORM onto a Rust target triple.
RUN set -eux; \
    case "${TARGETPLATFORM}" in \
        linux/amd64) echo x86_64-unknown-linux-musl  > /rust_target ;; \
        linux/arm64) echo aarch64-unknown-linux-musl  > /rust_target ;; \
        *) echo "unsupported TARGETPLATFORM: ${TARGETPLATFORM}" >&2; exit 1 ;; \
    esac
RUN rustup target add "$(cat /rust_target)"

# Scoped per-target (rather than a blanket RUSTFLAGS) because the native
# throwaway build below -- used only to run `coreutils --list` -- compiles
# for the host's own glibc triple, and forcing +crt-static there breaks
# proc-macro crates (they must build as a host dylib, which static linking
# is incompatible with).
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=x86_64-linux-gnu-gcc \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static -C strip=symbols" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static -C strip=symbols"

WORKDIR /build

# --- native throwaway build, used only to enumerate compiled-in utilities --
#
# `coreutils --list` has to run on the machine invoking it. When cross-
# compiling (e.g. TARGETPLATFORM=linux/arm64 on an amd64 builder) the real
# target binary can't be executed here without QEMU. Rather than pull in
# binfmt emulation just to list utility names, we do a second, native-only
# install of the same pinned version purely to ask it what it contains, then
# throw the binary away.
#
# Must use the *same* --features as the real build below (feat_os_unix_musl)
# so the utility list matches exactly what the shipped binary contains --
# that feature set excludes stdbuf (a musl cdylib limitation) that a plain
# glibc build would otherwise include, which would leave a dangling
# /bin/stdbuf symlink if the two builds' feature sets ever drifted apart.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${UUTILS_COREUTILS_VERSION}" ] && ver_flag="--version ${UUTILS_COREUTILS_VERSION}"; \
    cargo install --locked --root /tmp/native-coreutils coreutils \
        --no-default-features --features feat_os_unix_musl ${ver_flag}; \
    /tmp/native-coreutils/bin/coreutils --list > /util_list.txt; \
    rm -rf /tmp/native-coreutils

# --- uutils coreutils (multicall binary), cross-compiled for TARGETPLATFORM -
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${UUTILS_COREUTILS_VERSION}" ] && ver_flag="--version ${UUTILS_COREUTILS_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out coreutils \
        --no-default-features --features feat_os_unix_musl ${ver_flag}

# --- brush, a bash/POSIX-compatible shell, cross-compiled for TARGETPLATFORM
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${BRUSH_SHELL_VERSION}" ] && ver_flag="--version ${BRUSH_SHELL_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out brush-shell ${ver_flag}

# --- procs, a ps-alike process viewer, cross-compiled for TARGETPLATFORM ---
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${PROCS_VERSION}" ] && ver_flag="--version ${PROCS_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out procs ${ver_flag}

# --- bottom (btm), a top-alike monitor, cross-compiled for TARGETPLATFORM --
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${BOTTOM_VERSION}" ] && ver_flag="--version ${BOTTOM_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out bottom ${ver_flag}

# --- ouch, an archive tool, cross-compiled for TARGETPLATFORM --------------
#
# Built without the default `unrar`/`bzip3` features: both pull in bindgen,
# which needs libclang -- not worth adding an LLVM toolchain to the builder
# for rar support and a rarely-used bzip3 variant. tar/gzip/zip/zstd/xz/7z/
# bzip2 all still work; verified this combination cross-compiles cleanly.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${OUCH_VERSION}" ] && ver_flag="--version ${OUCH_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out ouch \
        --no-default-features --features use_zlib,use_zstd_thin ${ver_flag}

# --- diffutils (multicall: diff, cmp), cross-compiled for TARGETPLATFORM ---
#
# Upstream's multicall dispatcher currently only wires up "cmp" and "diff"
# (its own --help lists just those two), even though diff3/sdiff exist as
# source files -- so only those two get symlinked below.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${DIFFUTILS_VERSION}" ] && ver_flag="--version ${DIFFUTILS_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out diffutils ${ver_flag}

# --- findutils (find, locate, updatedb, xargs), cross-compiled -------------
#
# Explicit --bin list: the package also defines a "testing-commandline" bin
# used only by its own test suite, which we don't want to ship.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${FINDUTILS_VERSION}" ] && ver_flag="--version ${FINDUTILS_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out findutils \
        --bin find --bin locate --bin updatedb --bin xargs ${ver_flag}

# --- sed, cross-compiled for TARGETPLATFORM ---------------------------------
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${SED_VERSION}" ] && ver_flag="--version ${SED_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out sed ${ver_flag}

# --- grep, cross-compiled for TARGETPLATFORM --------------------------------
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    set -eux; \
    ver_flag=""; \
    [ -n "${GREP_VERSION}" ] && ver_flag="--version ${GREP_VERSION}"; \
    cargo install --locked --target "$(cat /rust_target)" --root /out uu_grep ${ver_flag}

# --- strip + UPX-compress every binary ---------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) strip_bin=x86_64-linux-gnu-strip ;; \
        arm64) strip_bin=aarch64-linux-gnu-strip ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    for bin in /out/bin/coreutils /out/bin/brush /out/bin/procs /out/bin/btm /out/bin/ouch \
               /out/bin/diffutils /out/bin/find /out/bin/locate /out/bin/updatedb /out/bin/xargs \
               /out/bin/sed /out/bin/grep; do \
        "${strip_bin}" --strip-all "${bin}"; \
        upx --best --lzma "${bin}"; \
    done

# --- assemble the root filesystem that becomes the scratch image -----------
RUN set -eux; \
    mkdir -p /rootfs/bin /rootfs/usr /rootfs/etc /rootfs/tmp /rootfs/home/nonroot; \
    cp /out/bin/coreutils /rootfs/bin/coreutils; \
    cp /out/bin/brush /rootfs/bin/brush; \
    cp /out/bin/procs /rootfs/bin/procs; \
    cp /out/bin/btm /rootfs/bin/btm; \
    cp /out/bin/ouch /rootfs/bin/ouch; \
    cp /out/bin/diffutils /rootfs/bin/diffutils; \
    cp /out/bin/find /rootfs/bin/find; \
    cp /out/bin/locate /rootfs/bin/locate; \
    cp /out/bin/updatedb /rootfs/bin/updatedb; \
    cp /out/bin/xargs /rootfs/bin/xargs; \
    cp /out/bin/sed /rootfs/bin/sed; \
    cp /out/bin/grep /rootfs/bin/grep; \
    ln -s diffutils /rootfs/bin/diff; \
    ln -s diffutils /rootfs/bin/cmp; \
    ln -s brush /rootfs/bin/sh; \
    while read -r cmd; do \
        [ -n "${cmd}" ] && ln -sf coreutils "/rootfs/bin/${cmd}"; \
    done < /util_list.txt; \
    ln -s bin /rootfs/sbin; \
    ln -s ../bin /rootfs/usr/bin; \
    ln -s ../bin /rootfs/usr/sbin

ARG NONROOT_UID
ARG NONROOT_GID
RUN set -eux; \
    printf 'root:x:0:0:root:/root:/bin/sh\nnonroot:x:%s:%s:nonroot:/home/nonroot:/bin/sh\n' \
        "${NONROOT_UID}" "${NONROOT_GID}" > /rootfs/etc/passwd; \
    printf 'root:x:0:\nnonroot:x:%s:\n' "${NONROOT_GID}" > /rootfs/etc/group; \
    chown "${NONROOT_UID}:${NONROOT_GID}" /rootfs/home/nonroot /rootfs/tmp

################################################################################
# final -- nothing but what builder placed in /rootfs
################################################################################
FROM scratch AS final

ARG NONROOT_UID
ARG NONROOT_GID

COPY --from=builder /rootfs/ /

ENV PATH=/bin
WORKDIR /home/nonroot
USER ${NONROOT_UID}:${NONROOT_GID}

CMD ["/bin/sh"]
