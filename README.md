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

## Installing

Packages are published to the public `universe` channel on prefix.dev
(v3 metadata, so use pixi ≥ 0.71 — see *Release channel* below):

```sh
# one-off tool install
pixi global install -c https://prefix.dev/universe -c conda-forge blast

# in a project
pixi init -c https://prefix.dev/universe -c conda-forge myproject
cd myproject && pixi add blast
# with working helper scripts (update_blastdb.pl etc.), v3 extras:
pixi add "blast[extras=[scripts]]"
```

On x86_64 the solver picks the highest microarch variant your CPU
supports automatically (`_x86_64-microarch-level`); see the variant
section below.

## Building

```sh
pixi build            # builds the .conda package for the current platform
# or, to get the package installed straight into the workspace env:
pixi install
pixi run blastn-version
```

## Status

All five release platforms build and pass the package tests on every CI
run (latest: run 33789331808, 2026-09-03, with the `-version` tests; the
smoke test below joins from the next run); the build strings below are
the CI-built release artifacts.

| Platform | Runner | Package | Notes |
|---|---|---|---|
| linux-64 | `ubuntu-latest` | `blast-2.17.0-h3989d59_205.conda` | benchmarked against bioconda; also built locally |
| linux-aarch64 | `ubuntu-24.04-arm` | `blast-2.17.0-h7bd4480_5.conda` | CI only |
| osx-64 | `macos-15-intel` | `blast-2.17.0-h5567b9d_205.conda` | CI only (llvm-ar fallback) |
| osx-arm64 | `macos-15` | `blast-2.17.0-h60d57d3_5.conda` | also built locally, real searches verified |
| win-64 | `windows-latest` | `blast-2.17.0-ha1ecfd9_205.conda` | also built locally, 20 executables, real searches verified |
| win-arm64 | `windows-11-arm` | — | experimental cross-build, `continue-on-error`; see the bring-up log below |

Package tests (run in a clean environment on every platform): `-version`
of the four core tools, plus `recipe/tests/smoke.py`, which builds tiny
nucleotide and protein databases, queries them with `blastdbcmd`,
`blastn` and `blastp`, and checks for the expected 100 % self-hits.

## CI / releases

`.github/workflows/build.yml` builds all five platforms on native
GitHub-hosted runners (including the two never built locally: osx-64 on
`macos-15-intel`, linux-aarch64 on `ubuntu-24.04-arm`), tests every
package in a clean environment, and uploads the `.conda` files as
workflow artifacts. Publishing to the prefix.dev `universe` channel
happens either on a `v*` tag push or on a manual `workflow_dispatch`
run with the *publish* box ticked; both need a `PREFIX_API_KEY`
repository secret (prefix.dev → account settings → API keys, with
upload rights on `universe`). Manual publishing is restricted to
`main`. Uploads use `--skip-existing`, so re-publishing a run is
idempotent — which also means a rebuilt package whose build number was
not bumped is skipped silently: **bump `build.number` for any change
that alters the package.** The experimental win-arm64 job uploads no
artifact on publishing runs, and its artifact name sits outside the
`blast-*` pattern the publish job downloads.

To publish an already-built run from a workstation instead (e.g. the
artifacts of a green `main` run), download them and run:

```sh
gh run download <run-id> -R luciorq/blast-zig-pixi --dir dist/ci
pixi exec --spec rattler-build -- rattler-build upload prefix \
  --channel universe --skip-existing dist/ci/*/*.conda
```

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

## Windows ARM64 (win-arm64): feasibility

Assessed 2026-09-02: **feasible, with one real blocker and one workaround
pattern already proven elsewhere in this project.** Verified inventory:

| Requirement | Status |
|---|---|
| CI hardware | ✅ `windows-11-arm` GitHub-hosted runner (partner image, GA; free for public repos, not covered by GitHub's standard SLA) |
| MSYS2 userland | ✅ the `m2-*` conda packages are **noarch** — they install on any subdir and their x86_64 binaries run under Windows-on-ARM's built-in x64 emulation |
| zlib, bzip2, libsqlite, llvm-openmp | ✅ published for `win-arm64` on conda-forge |
| lmdb | ⚠️ not on conda-forge for `win-arm64` — but the NCBI toolkit bundles its own copy (`src/util/lmdb`), so a scoped `--without-lmdb` branch (external→bundled) covers it |
| zig compiler | ❌ conda-forge ships **no native win-arm64 zig** (only the noarch `zig-compiler` shim, whose `zig` dependency is unsolvable there) |

The zig gap has two routes:

1. **Cross-build (works today, mirrors our Rosetta pattern):** run the
   *win-64* zig and m2 userland under x64 emulation on the ARM machine,
   with `-target aarch64-windows-gnu`. Configure's test programs and the
   mid-build `datatool` are aarch64 binaries that run natively on the
   same machine — the exact inversion of the osx-64-via-Rosetta setup we
   validated on omicron. This requires invoking rattler-build directly
   with `--build-platform win-64 --target-platform win-arm64`; the
   pixi-build backend path cannot express a split build/target today.
2. **Native (cleaner, needs upstream):** add `win-arm64` to the
   conda-forge zig feedstock — zig upstream already ships
   aarch64-windows release binaries, so this is packaging plumbing, not
   porting work.

Recipe deltas either way are small and mostly already arch-guarded:
`aarch64-windows-gnu` in the target table; the microarch axis, CPU flags
and `__archspec` gating are all under `if: x86_64` and skip
automatically; the `.exe` staging and MSYS2 bootstrap are shared; and
`ncbi_stack_win64.cpp`'s DbgHelp API is architecture-neutral.

Honest unknowns until a first build runs: mingw-w64 **aarch64** headers
with NCBI's `NCBI_OS_MSWIN` code path (x86_64-mingw is proven, aarch64
is not), and whether `zig ar` misbehaves there the way it does on
x86_64-macos (the `llvm-tools` fallback pattern is ready if so — but
llvm-tools would also need a win-arm64 or emulated x64 build). Expect
the usual two-or-three-iteration bring-up, gated `continue-on-error` in
CI until green.

### Bring-up log (route 1, experimental CI job)

- **Run 1 (2026-09-03, 33746309276):** the split-platform resolve works
  (win-64 build env under emulation, win-arm64 host env), the shims
  compile and link aarch64 test programs that run natively. Configure
  stalled after ~17 min until the 350-min job timeout. The host triple
  was still `x86_64-w64-mingw32`.
- **Run 2 (33789331808):** with `aarch64-w64-mingw32` and a 90-min step
  cap, configure ran 278 checks (each link test ≈ 1 s, so the emulated
  toolchain is *not* slow per se) and then stalled on a different,
  equally trivial check (`dbopen`) for 76 min. The two stalls at
  unrelated checks point at a nondeterministic hang inside zig under
  x64 emulation, not at a configure problem.
- **Mitigation now in place:** when `build_platform != target_platform`
  the shims run zig under `timeout` with two retries; native builds
  still `exec` zig directly. Budgets: 120 s for configure's `conftest`
  probes, `ZIG_SHIM_TIMEOUT` (default 600 s, forwarded through the
  recipe's script env) for compiles, three times that for links. The
  step cap is raised to 320 min to measure how far a full emulated
  compile gets.
- **Run 3 (2026-09-04, 33922689196):** with the watchdog armed,
  configure completed all 543 checks in ~25 min with zero retries and
  generated the Makefiles. The first *compile* then hit the first
  genuinely architecture-specific code: `ncbi_stack_win64.cpp` seeds
  `StackWalk64` from the x86-64 `CONTEXT` registers (`Rip`/`Rbp`/`Rsp`).
  Patched to `Pc`/`Fp`/`Sp` and `IMAGE_FILE_MACHINE_ARM64` on
  win-arm64; the mingw-w64 aarch64 headers otherwise accepted NCBI's
  `NCBI_OS_MSWIN` code without complaint, which answers the main
  "honest unknown" above.
- **Structural limit:** the full toolkit build takes ~4 h natively on a
  4-core win-64 runner; under emulation it will not fit GitHub's 6-hour
  job ceiling. Route 1 therefore validates the recipe (patches, headers,
  linking) but cannot ship. Shipping needs route 2 — a native zig on
  conda-forge. The zig feedstock already models `win-arm64` as a *cross
  target* (`zig_win-arm64` exists on win-64) but lists it under
  `xc_host_valid` exclusions, i.e. no win-arm64-hosted zig; that is the
  upstream request to make. With it, this recipe would take zig from
  the host env on win-arm64 and keep the emulated `m2-*` userland for
  configure/make, whose cost is negligible.

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
  builds carry `cpu:x86_64_v${level}` (the compiled-in baseline),
  selectable via `blast[flags=[cpu:x86_64_v2]]`. Flag segments allow
  only `[a-z0-9_]`.

### Microarch variant axis (prefix.dev pattern)

`recipe/variants.yaml` defines a `microarch_level` axis wired the way
the prefix.dev "CPU-optimized packages" post describes: the level
contributes the hundreds digit of the build number (203, 303, …) so the
solver prefers the highest installable level; each variant carries an
`__archspec`-gated run dependency (`_x86_64-microarch-level >=N`) so it
can only install on capable CPUs; and the level flows into the zig shim
as `-march=x86_64_v${level}`. Non-x86_64 platforms never reference the
variable and stay a single variant at the base number.

Two deviations from the blog, both deliberate: the gating constraint is
declared directly as a run dependency instead of via the
`x86_64-microarch-level` build metapackage (the backend's host solve
does not detect `__archspec`, and the metapackage's compiler-activation
flags are meaningless to the zig shim anyway), and only level 2 is
enabled — a level-3 (AVX2) build was benchmarked and shipped nothing
(see BENCHMARK.md). The backend builds the full variant matrix from one
`pixi build` invocation.

Consumer-side corollary: a workspace that locks this package for
platforms other than the one it runs on cannot detect `__archspec`
there, so `pixi.toml` declares the assumed floor per platform
(`{ platform = "linux-64", archspec = "x86_64_v2" }` inline entries in
`workspace.platforms` — the modern replacement for the deprecated
`[system-requirements]` table).

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

## Release channel & licensing

- **Channel**: releases go to the public `universe` channel on
  prefix.dev (`https://prefix.dev/universe`; the channel also holds
  unrelated packages of the same owner, so add `conda-forge` after it
  for dependencies). Because the packages carry v3 metadata, channel
  consumers need a v3-aware client (pixi ≥ 0.71); pre-v3 clients do not
  see v3 packages in channel repodata at all, though direct
  `.conda`-URL installs still work (the archive format is unchanged and
  unknown metadata fields are ignored — extras simply never apply).
- **Licensing**: the repository (recipe, shims, bench harness) is MIT —
  see `LICENSE.txt`. The packages contain NCBI BLAST+ (US-Government
  public domain, `NCBI-PD`; the notice ships as the package license
  file) plus statically linked bundled components (Mbed TLS Apache-2.0,
  PCRE2 BSD-3-Clause, Cloudflare zlib Zlib), reflected in the package
  license expression. NCBI requests citation in derivative work.

## Runtime notes

- BLAST's `-num_threads` parallelism is pthreads-based and works
  regardless of OpenMP; OpenMP additionally enables the toolkit's
  `#pragma omp` paths.
- `update_blastdb.pl` / `legacy_blast.pl` need a `perl` at runtime and
  `cleanup-blastdb-volumes.py` needs `python`; these are intentionally not
  run dependencies of the package.
- Host libraries surface as run dependencies automatically through their
  conda-forge `run_exports` (zlib, bzip2, lmdb, libsqlite, llvm-openmp).
