# crustybox

A pure-Rust, memory-safe, MIT-licensed alternative to a BusyBox container
image. It pairs nine upstream projects in a multi-arch `FROM scratch` image:

- [`uutils/coreutils`](https://github.com/uutils/coreutils) — compiled as a
  single multicall binary (`/bin/coreutils`), with a symlink per utility
  (`/bin/ls`, `/bin/cat`, ...), the same trick BusyBox itself uses. Built
  with the `feat_os_unix_musl` feature, which additionally pulls in
  `chmod`/`chown`/`chgrp`/`chroot`/`id`/`groups`/`kill`/`nice`/`nohup`/
  `timeout`/`install`/`mkfifo`/`mknod`/`logname`/`stat`/`stty`/`hostid`/
  `pinky`/`uptime`/`users`/`who` (via `feat_require_unix_core` /
  `_hostid` / `_utmpx`) and `arch`/`hostname`/`nproc`/`sync`/`uname`/
  `whoami` (via `feat_Tier1`) on top of the default set. Note: a separate
  `uutils/hostname` repo exists but is stale/unpublished -- `hostname` is
  actually already merged into the main `coreutils` monorepo and comes
  along for free with this one feature flag.
- [`brush`](https://github.com/reubeno/brush) — a bash/POSIX-compatible shell
  written in Rust, providing `/bin/sh`.
- [`uutils/diffutils`](https://github.com/uutils/diffutils) — a multicall
  binary providing `/bin/diff` and `/bin/cmp` (upstream hasn't wired
  `sdiff`/`diff3` into the dispatcher yet).
- [`uutils/findutils`](https://github.com/uutils/findutils) — `/bin/find`,
  `/bin/locate`, `/bin/updatedb`, `/bin/xargs`.
- [`uutils/sed`](https://github.com/uutils/sed) — `/bin/sed`.
- [`uutils/grep`](https://github.com/uutils/grep) — `/bin/grep`. The least
  mature of the uutils dependencies here (v0.1.0 at time of writing).
- [`procs`](https://github.com/dalance/procs) — a ps-alike process viewer
  (`/bin/procs`).
- [`bottom`](https://github.com/ClementTsang/bottom) — a top-alike
  process/system monitor (`/bin/btm`).
- [`ouch`](https://github.com/ouch-org/ouch) — an archive tool covering
  tar/gzip/zip/zstd/xz/7z/bzip2 (`/bin/ouch`), built without its default
  `unrar`/`bzip3` features (see the Dockerfile comment for why).

`diffutils`/`findutils`/`sed`/`grep` are uutils' own drop-in-compatible
rewrites of the real GNU tools of those names — same project and
compatibility goal as `coreutils`. `procs`/`bottom`/`ouch` are not: BusyBox
has ~300 applets across categories (networking, init, process tools, ...)
that `coreutils` alone doesn't cover, and these three are separate tools
that happen to cover a similar job, shipped under their own names rather
than aliased over the legacy `ps`/`top`/`tar`.

Two other uutils rewrites worth revisiting later: `uutils/procps` (a real
`ps`/`top`-compatible replacement, better than `procs`/`bottom`) and
`uutils/util-linux` — both currently have only a yanked crates.io release,
so they're not installable yet.

All binaries are statically linked against musl, stripped, and
UPX-compressed, then copied into an otherwise-empty scratch image alongside
a minimal `/etc/passwd` and `/etc/group` for non-root execution. No C code,
no libc, no shell or package manager beyond what's built here.

## Coverage vs BusyBox

BusyBox has historically shipped ~300 applets across categories that this
project doesn't attempt to replicate wholesale. Here's what's actually
covered, what's covered by a different (non-drop-in) tool, and what's a
real gap:

| Category | BusyBox has | crustybox status | Covered by |
|---|---|---|---|
| File/text utilities | ls, cp, cat, sort, cut, ... | ✅ Covered | `coreutils` |
| Permissions, identity, signaling | chmod, chown, id, kill, nice, timeout, ... | ✅ Covered | `coreutils` (`feat_os_unix_musl`) |
| Shell | ash | ✅ Covered | `brush` |
| Pattern matching / stream editing | grep, sed | ✅ Covered (grep is early, v0.1.0) | `uutils/grep`, `uutils/sed` |
| Diff/compare | diff, cmp | ✅ Covered (sdiff/diff3 not wired into the dispatcher upstream yet) | `uutils/diffutils` |
| Find/search | find, xargs | ✅ Covered | `uutils/findutils` |
| Process viewing | ps, top | ⚠️ Different CLI/output, not drop-in | `procs`, `bottom` |
| Archives/compression | tar, gzip, zip, xz, bzip2 | ⚠️ Different CLI, no rar/bzip3 | `ouch` |
| HTTP client | wget | ❌ Not added (candidate: `xh`, HTTPie-style not curl-compatible) | — |
| Networking (rest) | ifconfig, route, ping, telnet, nc, udhcpc, tiny httpd | ❌ No mature pure-Rust gap-filler exists | — |
| Init/service management | init, crond, syslogd, klogd, inetd | ❌ Not added | — |
| Filesystem/block devices | mount, fdisk, mkfs.*, blkid, losetup | ❌ Not added (`uutils/util-linux`'s only release was yanked) | — |
| User/auth management | adduser, passwd, su, login | ❌ Not added (`uutils/shadow` isn't published to crates.io; also arguably out of scope for an ephemeral scratch container) | — |
| Text editor | vi | ❌ Not added (candidate: `kibi`, untested) | — |
| awk | awk | ❌ Not added (`uutils/awk` isn't published to crates.io yet) | — |

## Building

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t crustybox:latest \
  .
```

See the top of the [Dockerfile](./Dockerfile) for the full explanation of
the cross-compilation approach (native builds via `$BUILDPLATFORM`, no QEMU
required).

## Tracking upstream

This project's real dependencies are nine crates.io packages: `coreutils`,
`brush-shell`, `procs`, `bottom`, `ouch`, `diffutils`, `findutils`, `sed`,
and `uu_grep`. Their pinned versions live in [`versions.env`](./versions.env)
and are used as Docker build-args.

- `.github/workflows/check-upstream.yml` checks crates.io daily and opens a
  PR bumping `versions.env` whenever any of the nine cuts a new release.
- `.github/workflows/build-and-push.yml` builds and pushes a new multi-arch
  image to `ghcr.io/<owner>/crustybox` whenever `versions.env` or the
  `Dockerfile` changes on `main`, or a `v*` tag is pushed.
- `.github/dependabot.yml` separately keeps the GitHub Actions themselves
  (`actions/checkout`, the `docker/*` actions, etc.) current — a different
  concern from the crates.io versions above.

So a new upstream release of any of these nine flows automatically into a
new crustybox image, with no manual steps.

## License

MIT — see [LICENSE](./LICENSE). Both `uutils/coreutils` and `brush` are
themselves MIT-licensed, so the whole stack stays permissive.
