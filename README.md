# blast-zig-pixi

Conda package for the [NCBI BLAST+](https://blast.ncbi.nlm.nih.gov/) command
line tools, built from source with [pixi](https://pixi.prefix.dev/) and the
`pixi-build-rattler-build` backend, using **`zig cc` / `zig c++`** as the
C/C++ compiler toolchain on every platform.

## Layout

- `pixi.toml` — pixi workspace + `[package]` definition pointing at the
  `pixi-build-rattler-build` backend.
- `recipe/recipe.yaml` — rattler-build recipe for `blast` (NCBI BLAST+
  sources, currently 2.17.0).
- `recipe/build.sh` — the single build script for all platforms: generates
  the zig compiler shims, runs the NCBI C++ Toolkit `configure` restricted
  to the BLAST project list, builds the BLAST+ app targets with the flat
  makefile, and stages binaries + helper scripts.
- `recipe/build.bat` — Windows entry point: puts the `m2-*` (MSYS2)
  userland on `PATH` and re-invokes `recipe/build.sh` under `bash`. That is
  all it does — every real build step lives in `build.sh`.

## Building

```sh
pixi build            # builds the .conda package for the current platform
# or, to get the package installed straight into the workspace env:
pixi install
pixi run blastn-version
```

## Status

| Platform | State |
|---|---|
| linux-64 | Built and tested (`blast-2.17.0-hcc556be_2.conda`), benchmarked against bioconda |
| win-64 | Built and tested (`blast-2.17.0-h9490d1a_2.conda`), 20 executables, real searches verified |
| osx-arm64 | Built and tested (`blast-2.17.0-h60d57d3_2.conda`), real searches verified |
| osx-64 | Recipe covers it; unbuilt (no Intel Mac available) |

## Design: one build, every OS

The goal is that the OS-specific surface stays as close to zero as
possible, so new targets are cheap to add:

- **Compilers**: the conda-forge `zig` package is the only toolchain,
  exposed through generated shims (`zig-cc`, `zig-cxx`, `ar`, `ranlib`)
  that behave identically everywhere. The shim pattern is shared with
  [`../r-zig-pixi`](../r-zig-pixi).
- **Third-party libraries** (`zlib`, `bzip2`, `lmdb`, `libsqlite`,
  `llvm-openmp`) come from the conda host environment on *all* platforms —
  including win-64, where the shim resolves conda-forge's MSVC-style
  library names (`lib<n>.lib`, `<n>.lib`, `lib<n>.dll.a`) that zig's
  MinGW-style `-l` search would miss. The Windows import libraries
  (`dbghelp`, `gdi32`, `bcrypt`, …) are named explicitly on the link line,
  because NCBI declares them with MSVC-only `#pragma comment(lib, ...)`
  directives that clang ignores.
- **OpenMP**: built with `--with-openmp` on every OS. `zig cc` performs
  `-fopenmp` codegen but bundles neither `omp.h` nor the runtime; the shim
  injects conda-forge's `llvm-openmp` (`-lomp`) at link time.
- **Userland**: NCBI's `configure`/`make` run under conda-provided tools
  only — coreutils/make/gawk/sed/… on unix, the `m2-*` MSYS2 packages on
  Windows. `build.sh` pins `PATH` to the conda envs (plus the shims), pins
  `CONFIG_SHELL` to conda bash (NCBI would otherwise bake `/bin/ksh` into
  its makefiles), and patches the few hardcoded `/bin/rm`//`bin/ln`
  `/bin/cp` paths. No system packages are used.
- **New platforms**: add the platform to `platforms` in `pixi.toml` and
  one line to the target table in `build.sh` (the zig target triple, e.g.
  `aarch64-linux-gnu.2.17` — linux-aarch64 is already wired). Because zig
  is inherently a cross-compiler and carries its own libc headers/stubs,
  this same table is the seed for future cross-compilation; the current
  blocker for full cross builds is NCBI's `configure`, which insists on
  running the test programs it compiles.

## Toolchain quirks the shims absorb

These were all found empirically while bringing the build up; they are
handled centrally in the shim/`build.sh` so the NCBI build system never
sees them:

- `zig cc` enables UBSan trap mode by default → `-fno-sanitize=undefined`
  (NCBI/zlib C code traps otherwise).
- `zig cc` promotes `-Wdate-time` to an error → `-Wno-date-time` (NCBI
  uses `__DATE__`/`__TIME__`).
- clang rejects glibc-versioned triples (`x86_64-linux-gnu.2.28`) for
  introspection flags (`-dumpmachine`, `-print-*`) → shim strips the
  version for those calls.
- zig spells CPU baselines its own way → `-march=x86_64_v2` (not
  `x86-64-v2`); needed because NCBI's bitset code uses SSE4.2/popcnt
  intrinsics.
- NCBI's `configure` treats `$AR` as a full command line → `AR="… ar cr"`.
- linux binaries pin a glibc 2.17 floor (RHEL/CentOS 7 era) via the
  target triple, enforced at install time by a `__glibc >=2.17` run
  dependency. A single low floor is deliberate: binaries built against
  2.17 symbol versions run unchanged on every newer glibc, and the
  optimized function implementations are supplied by the *runtime* glibc
  regardless of the floor, so higher-glibc build variants would add
  matrix cost without measurable benefit.
- Static binaries (`--with-static --without-dll`) are stripped at link
  time (`-Wl,-s`) on linux/windows.
- On win-64 conda-forge ships zig as `x86_64-w64-mingw32-zig.exe`; the
  plain `zig` name exists only as `.bat`/`.cmd` wrappers, which MSYS2
  bash cannot `exec`. `build.sh` resolves the real binary once.

## macOS: building without the Xcode SDK

The macOS build uses no Apple toolchain at all — no `xcrun`, no Xcode SDK,
no system libc++. What made that possible:

- **C++ runtime from conda-forge.** zig emits a reference to
  `@rpath/libc++.1.dylib` but records no `LC_RPATH`, so C++ binaries abort
  at startup. Rather than point that at `/usr/lib`, `libcxx` is a host and
  run dependency and the shim rpaths the conda prefix. conda-forge's
  `libcxx` ships no `run_exports`, so the run dependency is explicit.
- **No frameworks.** NCBI's configure hardcodes
  `-framework ApplicationServices` on Darwin, and frameworks are the one
  thing that genuinely requires the SDK. No BLAST source references it (or
  CoreServices/Carbon/CoreFoundation), so the shim drops `-framework`
  flags. A genuinely needed framework symbol would surface as an undefined
  symbol at link time, not as silent breakage.
- **`-flat_namespace`** is rejected by zig's MachO linker and is filtered;
  the default two-level namespace is what a modern build wants anyway.
- **`ncbi_lbdns.c`** needs `<arpa/nameser.h>`/`<resolv.h>`, which live in
  the SDK and are not among zig's bundled darwin headers. The file already
  carries a non-UNIX `#else` branch defining `SERV_LBDNS_Open` as a no-op,
  so the build selects that. LBDNS is NCBI's internal DNS-based service
  discovery, off unless explicitly enabled; standalone BLAST — including
  `-remote`, which is plain HTTP — does not use it.
- **Duplicate dylibs.** NCBI's link lines name some libraries twice (e.g.
  `-lz`); lld emits one `LC_LOAD_DYLIB` per mention and modern dyld rejects
  the binary at startup with "duplicate linked dylib". The shim keeps only
  the last mention of each `-l` that resolves to a dylib in the conda
  prefix, leaving repeated static archives alone since link order can
  depend on them.
- **`-march=armv8-a+crc`** (NCBI's bundled Cloudflare zlib) is spelled
  `-mcpu=generic+crc` for zig — the aarch64 counterpart of the
  `x86_64_v2` naming difference.

The only system artefact left is `/usr/lib/libSystem.B.dylib`, which is
the macOS ABI itself; zig links it through its own bundled stub rather
than the SDK. That is the counterpart of libc on Linux, not a build tool.

## Windows: building NCBI's toolkit without MSVC

NCBI supports Windows only through MSVC. Getting a `-windows-gnu` build
required a set of source patches, all applied in `build.sh` under a single
`if ${on_windows}` block and each guarded by an assertion so a silently
non-applying patch fails the build. The interesting ones:

- `ncbi_export.h` hard-`#error`s unless `_MSC_VER` is set and includes
  `<ntverp.h>` (a Windows SDK header mingw-w64 lacks). This turns out to
  be a policy check, not a technical one — clang compiles the toolkit's
  `NCBI_OS_MSWIN` paths fine and merely ignores the MSVC `#pragma warning`
  / `#pragma data_seg` directives.
- Passing `--build/--host=x86_64-w64-mingw32` is what selects that native
  Windows path (NCBI's 2013-era `config.guess` does not recognise
  `MSYS_NT`, and `cygwin` would demand a POSIX layer zig cannot target).
- `ncbi_os_mswin.cpp` is listed *only* in NCBI's MSVC project description
  (`Makefile.corelib.lib.msvc`), which the autoconf system never reads —
  the UNIX makefiles have `UNIX_SRC` but no MSWIN equivalent. Without it
  the link fails on `CWinSecurity`/`CWinFeature`.
- BitMagic's `block_type()` is not a template, so both arms of its
  `if constexpr (sizeof(void*) == 8)` are still type-checked; the 32-bit
  arm casts a pointer to `unsigned long`, fine on LP64 Linux but a hard
  error under Windows' LLP64. This one blocks `datatool`, and without
  NCBI's ASN.1 generator nothing downstream can build.
- `project_tree_builder` is itself a Windows binary here, so it writes
  `Makefile.flat` with backslash separators — which GNU make reads as
  escapes — and embeds `$(srcdir)` into generated `#include` stubs as an
  MSYS `/c/...` path that the native clang cannot open. `build.sh`
  converts the separators (preserving line continuations) and
  pre-generates those stubs with native `C:/...` paths.
- Smaller ones: `sizeof TYPE` without parentheses, mingw's
  `#define interface struct` colliding with NCBI parameter names,
  `mode_t` already provided by mingw, and cityhash/farmhash falling back
  to glibc's `<byteswap.h>`.

## v3 package metadata (extras + variant flags)

The recipe uses rattler-build's v3 package spec (beta; the
`pixi-build-rattler-build` backend accepts it without extra
configuration). Two features are used:

- **`scripts` extra** — the package ships `update_blastdb.pl`,
  `legacy_blast.pl` and `cleanup-blastdb-volumes.py` but does not depend
  on their interpreters. `blast[extras=[scripts]]` adds `perl` + `python`.
  The workspace demonstrates consumption: `pixi run -e scripts
  update-blastdb-check`. Base installs stay lean.
- **Variant flags** — every build carries `toolchain:zig`, and x86_64
  builds carry `cpu:x86_64_v2` (the compiled-in baseline). A future AVX2
  build would carry `cpu:x86_64_v3` and be selectable via
  `blast[flags=[cpu:x86_64_v3]]`. Flag segments allow only `[a-z0-9_]`.

Packages record this in `index.json` (`repodata_revision: 3`,
`extra_depends`, `flags`); `rattler-index` places v3 packages in a
dedicated repodata section that pre-v3 clients ignore.

### A hard-won linking rule (the `_2` rebuild)

Do **not** fix a missing-SONAME library (conda-forge's `liblmdb.so`) with
post-link `patchelf --replace-needed`. patchelf leaves the old absolute
placeholder path as dead bytes in the binary; rattler-build then records
the file as prefix-containing, and the install-time placeholder rewrite
can zero the `DT_NEEDED` string — producing binaries that fail with
`undefined symbol: mdb_txn_begin` in *some* install prefixes and work in
others. The `_0`/`_1` linux builds carried this latent defect. The fix,
in `build.sh`: copy `liblmdb.so`, give the copy a proper SONAME
(`patchelf --set-soname` at *build* time), and have the shim link
`-llmdb` against the copy — the recorded NEEDED entry is then the bare
name and the dynamic section never contains a placeholder at all.

## Benchmarks

See [BENCHMARK.md](BENCHMARK.md): outputs are byte-identical to the
bioconda 2.17.0 package, compute-bound performance is equal within 2–3%,
and startup/`makeblastdb` are ~20% faster (static linking).

## Runtime notes

- BLAST's `-num_threads` parallelism is pthreads-based and works
  regardless of OpenMP; OpenMP additionally enables the toolkit's
  `#pragma omp` paths.
- `update_blastdb.pl` / `legacy_blast.pl` need a `perl` at runtime and
  `cleanup-blastdb-volumes.py` needs `python`; these are intentionally not
  run dependencies of the package.
- Host libraries surface as run dependencies automatically through their
  conda-forge `run_exports` (zlib, bzip2, lmdb, libsqlite, llvm-openmp).
