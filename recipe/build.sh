#!/usr/bin/env bash
# Build NCBI BLAST+ from the C++ Toolkit sources using zig cc / zig c++ as
# the only C/C++ toolchain, on every platform. Runs natively on
# linux/macos, and under the m2-* (MSYS2) userland on Windows (invoked
# from build.bat), where zig targets x86_64-windows-gnu.
#
# The compiler shims below follow the pattern proven in ../r-zig-pixi:
# one script per tool, identical on all OSes, with the platform quirks
# (glibc floor, MinGW library naming, OpenMP runtime injection) handled
# inside the shim so the NCBI build system never sees an OS difference.
set -euxo pipefail

on_windows=false
case "${target_platform}" in
  win-*) on_windows=true ;;
esac

on_macos=false
case "${target_platform}" in
  osx-*) on_macos=true ;;
esac

# No Xcode SDK / xcrun is needed on macOS: zig carries its own libSystem
# stub, the C++ runtime comes from conda-forge's libcxx, and the shim
# drops the vestigial -framework flags NCBI adds on Darwin (nothing in
# the BLAST sources actually uses those frameworks). The only system
# artefact left is /usr/lib/libSystem.B.dylib, which is the macOS ABI
# itself — the counterpart of libc on Linux, not a build tool.

if ${on_windows}; then
  # Under MSYS2 bash the variables handed over by rattler-build are
  # Windows-style paths; normalize them for shell use.
  SRC_DIR="$(cygpath -u "${SRC_DIR}")"
  PREFIX="$(cygpath -u "${PREFIX}")"
  BUILD_PREFIX="$(cygpath -u "${BUILD_PREFIX}")"
fi

# Keep the zig compilation cache inside the work directory.
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/.zig-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/.zig-cache"

# Root of the host env's headers/libraries (conda layout differs on win).
if ${on_windows}; then
  conda_root="${PREFIX}/Library"
else
  conda_root="${PREFIX}"
fi

# --- target table -------------------------------------------------------
# Adding a platform to the package = one entry here plus the platform in
# pixi.toml. linux pins a glibc 2.17 floor (RHEL/CentOS 7 era — HPC
# clusters routinely run BLAST on old compute nodes); macOS stays on the
# native target so zig can discover the system SDK.
zig_target=""
case "${target_platform}" in
  linux-64)      zig_target="x86_64-linux-gnu.2.17"  ;;
  linux-aarch64) zig_target="aarch64-linux-gnu.2.17" ;;
  win-64)        zig_target="x86_64-windows-gnu"     ;;
  osx-64 | osx-arm64) ;;
esac

# NCBI compiles its bitset code with SSE4.2 intrinsics; zig's baseline
# x86-64 CPU model leaves popcnt off, so raise the floor to x86-64-v2
# (Nehalem+) on x86_64 targets. zig parses -march itself and expects its
# own CPU spelling (underscores). The level comes from the recipe's
# microarch_level variant (MICROARCH_LEVEL via script env); level 2 is
# the floor — NCBI's SSE4.2/popcnt requirement IS microarch level 2 —
# and level 3 adds AVX2 for the CPU-optimized variant.
march=""
case "${target_platform}" in
  linux-64 | win-64 | osx-64)
    march="-march=x86_64_v${MICROARCH_LEVEL:-2}" ;;
esac

# conda-forge's liblmdb.so carries no SONAME, so lld records the literal
# path it resolved — an absolute placeholder path into the build prefix.
# Post-link patchelf --replace-needed is NOT a safe fix: it leaves the old
# placeholder path as dead bytes in the binary, rattler-build then records
# the file as prefix-containing, and the install-time placeholder rewrite
# can zero the NEEDED string (install-prefix-length dependent, so it
# breaks in some environments and not others). Instead, link against a
# SONAME-fixed copy: lld then records the bare name and the dynamic
# section never contains a placeholder at all.
hostlib_dir=""
case "${target_platform}" in
  linux-*)
    hostlib_dir="${SRC_DIR}/hostlibs"
    mkdir -p "${hostlib_dir}"
    cp "${conda_root}/lib/liblmdb.so" "${hostlib_dir}/liblmdb.so"
    "${BUILD_PREFIX}/bin/patchelf" --set-soname liblmdb.so \
      "${hostlib_dir}/liblmdb.so"
    ;;
esac

# --- compiler shims -------------------------------------------------------
wrap_dir="${SRC_DIR}/zig-toolchain"
mkdir -p "${wrap_dir}"

# conda-forge's win-64 zig package installs the real executable as
# x86_64-w64-mingw32-zig.exe; the plain `zig` name exists only as
# .bat/.cmd wrappers, which MSYS2 bash cannot exec. Resolve the binary
# once here and bake the absolute path into the shims.
zig_exe="$(command -v x86_64-w64-mingw32-zig || command -v zig)"
if [[ -z "${zig_exe}" ]]; then
  echo "no zig executable found in the build environment" >&2
  exit 1
fi

write_compiler_shim() {
  local path="$1" tool="$2"
  cat > "${path}" <<EOF
#!/usr/bin/env bash
tool="${tool}"
zig_exe="${zig_exe}"
zig_target="${zig_target}"
march="${march}"
conda_root="${conda_root}"
hostlib_dir="${hostlib_dir}"
on_windows=${on_windows}
on_macos=${on_macos}
EOF
  cat >> "${path}" <<'EOF'
# Introspection flags: clang rejects glibc-versioned triples for these,
# so drop the version suffix before delegating.
for a in "$@"; do
  case "$a" in
    -dumpmachine|-dumpversion|-dumpspecs|-print-*|--version|-V|-qversion)
      exec "$zig_exe" "$tool" ${zig_target:+-target "${zig_target%%.*}"} "$@" ;;
  esac
done

args=("$@")

# Does this invocation link, or only produce an object?
linking=true
for a in "$@"; do case "$a" in -c|-S|-E|-M|-MM) linking=false; break;; esac; done

link_extra=()
if $on_macos; then
  # zig emits a reference to @rpath/libc++.1.dylib but records no
  # LC_RPATH, so C++ binaries abort at startup with "Library not loaded".
  # Resolve it against conda-forge's libcxx rather than /usr/lib, so the
  # C++ runtime is the one conda ships (and becomes a run dependency).
  if $linking; then
    link_extra+=(-L"$conda_root/lib" -Wl,-rpath,"$conda_root/lib")
  fi
  # NCBI's generated link lines name some libraries more than once (e.g.
  # -lz via both CMPRS_LIBS and the third-party list). lld emits one
  # LC_LOAD_DYLIB per occurrence and modern dyld rejects the result at
  # startup with "duplicate linked dylib". Drop all but the last mention
  # of each -l that resolves to a dylib in the conda prefix; repeated
  # static archives are left alone, since link order can depend on them.
  if $linking; then
    # Collect the -l flags that name a dylib in the conda prefix. Plain
    # string matching, no associative arrays, so this behaves the same
    # under any bash version.
    shared_ls=" "
    for a in "${args[@]}"; do
      case "$a" in
        -l?*)
          n="${a#-l}"
          case "$shared_ls" in
            *" $a "*) ;;
            *) if compgen -G "$conda_root/lib/lib$n*.dylib" > /dev/null 2>&1; then
                 shared_ls="$shared_ls$a "
               fi ;;
          esac ;;
      esac
    done
    deduped=()
    n_args=${#args[@]}
    for (( i = 0; i < n_args; i++ )); do
      a="${args[$i]}"
      drop=false
      case "$shared_ls" in
        *" $a "*)
          # Keep only the final mention, so it still follows every static
          # archive that needs it.
          for (( j = i + 1; j < n_args; j++ )); do
            if [ "${args[$j]}" = "$a" ]; then drop=true; break; fi
          done ;;
      esac
      $drop || deduped+=("$a")
    done
    args=("${deduped[@]}")
  fi

  filtered=()
  skip_next=false
  for a in "${args[@]}"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$a" in
      # Darwin's legacy -flat_namespace: zig's MachO linker rejects it
      # outright, and the default two-level namespace is what a modern
      # build wants anyway.
      -Wl,-flat_namespace|-flat_namespace) continue ;;
      # NCBI hardcodes -framework ApplicationServices on Darwin, but no
      # BLAST source references it (or CoreServices/Carbon/CoreFoundation)
      # — the flag is vestigial. Dropping it is what removes the Xcode SDK
      # from the build entirely. If a framework symbol were genuinely
      # needed the link would fail with an undefined symbol, not silently.
      -Wl,-framework,*) continue ;;
      -framework) skip_next=true; continue ;;
    esac
    filtered+=("$a")
  done
  args=("${filtered[@]}")
fi

# Windows: zig's MinGW -l search tries only <n>.dll, <n>.lib and lib<n>.a
# — missing lib<n>.dll.a (MinGW import libs) and lib<n>.lib (conda-forge
# MSVC naming). Resolve -lX to an explicit path when only a missed name
# exists (pattern from r-zig-pixi).
if $on_windows; then
  libdirs=("$conda_root/lib")
  for a in "$@"; do case "$a" in -L?*) libdirs+=("${a#-L}");; esac; done
  resolved=()
  for a in "${args[@]}"; do
    repl=""
    case "$a" in
      -l?*)
        n="${a#-l}"
        for d in "${libdirs[@]}"; do
          if [ -f "$d/lib$n.dll.a" ]; then
            repl="$d/lib$n.dll.a"; break
          elif [ -f "$d/$n.dll" ] || [ -f "$d/$n.lib" ] || [ -f "$d/lib$n.a" ]; then
            break  # zig finds these itself
          elif [ -f "$d/lib$n.lib" ]; then
            repl="$d/lib$n.lib"; break
          fi
        done ;;
    esac
    resolved+=("${repl:-$a}")
  done
  args=("${resolved[@]}")
fi

# NCBI's bundled Cloudflare zlib asks for -march=armv8-a+crc on aarch64
# to get the CRC32 instructions. zig parses -march itself and only knows
# its own CPU names; -mcpu=generic+crc is the equivalent it accepts.
translated=()
for a in "${args[@]}"; do
  case "$a" in
    -march=armv8-a+crc) translated+=(-mcpu=generic+crc) ;;
    -march=armv8-a)     translated+=(-mcpu=generic) ;;
    # Route lmdb through the SONAME-fixed copy (see hostlibs above) so
    # the recorded NEEDED entry is the bare name, not a placeholder path.
    -llmdb)
      if [ -n "$hostlib_dir" ] && [ -f "$hostlib_dir/liblmdb.so" ]; then
        translated+=("$hostlib_dir/liblmdb.so")
      else
        translated+=("$a")
      fi ;;
    *)                  translated+=("$a") ;;
  esac
done
args=("${translated[@]}")

# OpenMP: zig cc performs -fopenmp codegen but bundles neither omp.h nor
# libomp and won't auto-link it — wire in conda-forge's llvm-openmp from
# the host env.
omp=()
if [[ " $* " == *"-fopenmp"* ]]; then
  omp+=(-I"$conda_root/include")
  already=false
  for a in "$@"; do case "$a" in -lomp|*/libomp.lib) already=true; break;; esac; done
  if $linking && ! $already; then
    if [ -f "$conda_root/lib/libomp.lib" ]; then
      omp+=("$conda_root/lib/libomp.lib")  # zig's -l search misses this name
    else
      omp+=(-L"$conda_root/lib" -lomp)
    fi
  fi
fi

# -fno-sanitize=undefined: zig enables UBSan trap mode by default and the
# NCBI/zlib C code is not clean under it. -Wno-date-time: zig promotes
# -Wdate-time to an error; NCBI uses __DATE__/__TIME__.
exec "$zig_exe" "$tool" ${zig_target:+-target "$zig_target"} ${march} \
  -fno-sanitize=undefined -Wno-date-time \
  "${args[@]}" "${link_extra[@]}" "${omp[@]}"
EOF
  chmod +x "${path}"
}

write_compiler_shim "${wrap_dir}/zig-cc" cc
write_compiler_shim "${wrap_dir}/zig-cxx" c++

# zig 0.16.0's `zig ar` cannot create Mach-O archives on x86_64 (fails
# on a trivial two-object case; the arm64 build works). Where the recipe
# provides the standalone llvm-ar (osx-64), prefer it.
ar_exe="$(command -v llvm-ar || true)"
ranlib_exe="$(command -v llvm-ranlib || true)"

if [[ -n "${ar_exe}" ]]; then
  cat > "${wrap_dir}/ar" <<EOF
#!/usr/bin/env bash
exec "${ar_exe}" "\$@"
EOF
else
  cat > "${wrap_dir}/ar" <<EOF
#!/usr/bin/env bash
exec "${zig_exe}" ar "\$@"
EOF
fi

if [[ -n "${ranlib_exe}" ]]; then
  cat > "${wrap_dir}/ranlib" <<EOF
#!/usr/bin/env bash
exec "${ranlib_exe}" "\$@"
EOF
else
  cat > "${wrap_dir}/ranlib" <<EOF
#!/usr/bin/env bash
exec "${zig_exe}" ranlib "\$@"
EOF
fi

chmod +x "${wrap_dir}/ar" "${wrap_dir}/ranlib"

if ${on_windows}; then
  # build.bat already put the m2-* userland first on PATH; just add the
  # zig wrappers.
  export PATH="${wrap_dir}:${PATH}"
else
  # Hermetic build: only the zig wrappers and the conda build/host envs
  # are visible, so no tool or compiler can leak in from the system
  # (/usr/bin etc.).
  export PATH="${wrap_dir}:${BUILD_PREFIX}/bin:${PREFIX}/bin"
fi

export CC="${wrap_dir}/zig-cc"
export CXX="${wrap_dir}/zig-cxx"
# NCBI's configure probes for a separate "build" compiler for build-time
# helper tools; keep that inside the conda env as well.
export CC_FOR_BUILD="${wrap_dir}/zig-cc"
export CXX_FOR_BUILD="${wrap_dir}/zig-cxx"
# NCBI's configure treats $AR as the complete archiver command line,
# flags included (its default is "ar cr").
export AR="${wrap_dir}/ar cr"
export RANLIB="${wrap_dir}/ranlib"

export CFLAGS="-O2 ${CFLAGS:-}"
export CXXFLAGS="-O2 ${CXXFLAGS:-}"
export LDFLAGS="-L${conda_root}/lib ${LDFLAGS:-}"
if ! ${on_windows}; then
  export LDFLAGS="-Wl,-rpath,${conda_root}/lib ${LDFLAGS}"
fi
# Strip at link time (lld) — the statically linked BLAST binaries are
# enormous otherwise. macOS ld64 handles stripping differently; skip there.
case "${target_platform}" in
  linux-* | win-*) export LDFLAGS="-Wl,-s ${LDFLAGS}" ;;
esac

# NCBI's configure re-execs itself under its "preferred" shell (ksh first)
# and bakes that path into the generated makefiles as SHELL=. Pin it to
# the conda-provided bash instead of anything from the system.
CONFIG_SHELL="$(command -v bash)"
export CONFIG_SHELL

# The build system hardcodes a few absolute /bin tool paths; rewrite them
# so rm/ln/cp resolve from PATH (conda coreutils).
sed -i.bak -e 's|= /bin/rm|= rm|g' "${SRC_DIR}/c++/src/build-system/Makefile.mk.in"
sed -i.bak \
  -e 's|BINCOPY="/bin/ln -f"|BINCOPY="ln -f"|' \
  -e 's|BINCOPY="/bin/cp -p"|BINCOPY="cp -p"|' \
  "${SRC_DIR}/c++/src/build-system/configure"

if ${on_windows}; then
  # ncbi_export.h refuses the NCBI_OS_MSWIN path outright unless _MSC_VER
  # is set, and includes <ntverp.h>, a Windows SDK header mingw-w64 does
  # not ship. The refusal is a policy check, not a technical one: clang
  # (through zig cc) compiles the toolkit's MSWIN code — __declspec,
  # windows.h and friends — and simply ignores the MSVC-only
  # `#pragma warning` / `#pragma data_seg` directives. Lift the guard and
  # supply the single value the header actually consumes from ntverp.h.
  sed -i \
    -e 's|^#    error "This toolkit is not buildable with a compiler other than MSVC."|/* patched: built with zig cc (clang + mingw-w64) */|' \
    -e 's|^#  include <ntverp.h>|#  define VER_PRODUCTBUILD 10000|' \
    "${SRC_DIR}/c++/include/common/ncbi_export.h"
  # Assert the patch landed (set -e aborts the build otherwise).
  grep -q 'VER_PRODUCTBUILD 10000' "${SRC_DIR}/c++/include/common/ncbi_export.h"

  # `sizeof TYPE` without parentheses is an MSVC extension that clang
  # rejects (only these two occurrences exist in the whole tree).
  sed -i 's|(sizeof IMAGEHLP_SYMBOL64)|(sizeof(IMAGEHLP_SYMBOL64))|' \
    "${SRC_DIR}/c++/src/corelib/ncbi_stack_win64.cpp"
  sed -i 's|(sizeof IMAGEHLP_SYMBOL)|(sizeof(IMAGEHLP_SYMBOL))|' \
    "${SRC_DIR}/c++/src/corelib/ncbi_stack_win32.cpp"
  grep -q 'sizeof(IMAGEHLP_SYMBOL64)' "${SRC_DIR}/c++/src/corelib/ncbi_stack_win64.cpp"

  # The MSVC debug-CRT report APIs (_CrtSetReport*/_CRTDBG_*) are not
  # declared by mingw-w64's crtdbg.h and only affect the MSVC debug
  # runtime, so compile that block out elsewhere.
  sed -i \
    -e 's|^\( *\)_CrtSetReportFile(_CRT_WARN,   _CRTDBG_FILE_STDERR);|#ifdef _MSC_VER\n\1_CrtSetReportFile(_CRT_WARN,   _CRTDBG_FILE_STDERR);|' \
    -e 's|^\( *\)_CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);|\1_CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);\n#endif|' \
    "${SRC_DIR}/c++/src/corelib/ncbi_system.cpp"
  grep -q '^#ifdef _MSC_VER' "${SRC_DIR}/c++/src/corelib/ncbi_system.cpp"

  # GetProcAddress returns FARPROC; assigning a function pointer to void*
  # is ill-formed in standard C++ (MSVC allows it). The cast is valid on
  # every platform, so patch the shared line unconditionally.
  sed -i 's|^    entry.data = ptr;|    entry.data = (void*)ptr;|' \
    "${SRC_DIR}/c++/src/corelib/ncbidll.cpp"
  grep -q 'entry.data = (void\*)ptr;' "${SRC_DIR}/c++/src/corelib/ncbidll.cpp"

  # fstream(FILE*) is an MSVC extension libc++ lacks. Restrict the two
  # blocks that depend on it to MSVC; the portable filename-based branch
  # is then used, and CTmpStream's destructor already deletes the temp
  # file explicitly, so behaviour is unchanged.
  awk '
    /^#if defined\(NCBI_OS_MSWIN\)[[:space:]]*$/ { pend=$0; next }
    pend != "" {
      if ($0 ~ /CTmpStream\(const char\* s, FILE\* file\)/ || $0 ~ /^    \/\/ Open file manually/)
        print "#if defined(NCBI_OS_MSWIN) && defined(_MSC_VER)";
      else print pend;
      pend=""; print; next
    }
    { print }
    END { if (pend != "") print pend }
  ' "${SRC_DIR}/c++/src/corelib/ncbifile.cpp" > "${SRC_DIR}/c++/src/corelib/ncbifile.cpp.patched"
  mv "${SRC_DIR}/c++/src/corelib/ncbifile.cpp.patched" \
     "${SRC_DIR}/c++/src/corelib/ncbifile.cpp"
  grep -q 'NCBI_OS_MSWIN) && defined(_MSC_VER)' "${SRC_DIR}/c++/src/corelib/ncbifile.cpp"

  # The bundled cityhash/farmhash fall back to glibc's <byteswap.h> for
  # any platform they do not recognize, and neither knows about Windows.
  # clang always provides the __builtin_bswap* intrinsics.
  for f in src/util/checksum/cityhash/city.cc \
           src/util/checksum/farmhash/farmhash.cc; do
    sed -i 's|^#include <byteswap.h>|#if defined(_WIN32)\n#  define bswap_32(x) __builtin_bswap32(x)\n#  define bswap_64(x) __builtin_bswap64(x)\n#else\n#  include <byteswap.h>\n#endif|' \
      "${SRC_DIR}/c++/${f}"
    grep -q '__builtin_bswap32' "${SRC_DIR}/c++/${f}"
  done

  # Some Windows-only sources are listed *only* in the MSVC project
  # descriptions (Makefile.<lib>.lib.msvc, "SourceFiles = ..."), which the
  # autoconf build system never reads — the UNIX makefiles have UNIX_SRC
  # but no MSWIN equivalent. Without these the link fails on missing
  # CWinSecurity/CWinFeature/etc. Add them to the corresponding SRC lists.
  sed -i 's|^SRC = |SRC = ncbi_os_mswin |' \
    "${SRC_DIR}/c++/src/corelib/Makefile.corelib.lib"
  # Only ncbi_os_mswin is added. The other two entries in those .msvc
  # files are not usable here: ncbi_win_hook is MSVC-specific API hooking
  # that nothing in BLAST references (static archives only pull in the
  # objects actually used), and blast4_options.cpp no longer ships in the
  # BLAST source distribution at all — the .msvc file is stale.
  grep -q 'SRC = ncbi_os_mswin ' "${SRC_DIR}/c++/src/corelib/Makefile.corelib.lib"

  # BitMagic's block_type() is a non-template function, so both arms of
  # its `if constexpr (sizeof(void*) == 8)` are still type-checked. The
  # 32-bit arm casts a pointer to `unsigned long`, which is 64-bit on
  # LP64 (fine on Linux) but 32-bit under Windows' LLP64 — a hard error.
  # This breaks datatool, and without NCBI's ASN.1 generator nothing that
  # depends on generated sources can build.
  sed -i 's|unsigned w = reinterpret_cast<unsigned long>(bp);|unsigned w = (unsigned)reinterpret_cast<unsigned long long>(bp);|' \
    "${SRC_DIR}/c++/include/util/bitset/bmfunc.h"
  grep -q 'reinterpret_cast<unsigned long long>(bp)' \
    "${SRC_DIR}/c++/include/util/bitset/bmfunc.h"

  # mingw-w64's rpc.h does `#define interface struct`, and these headers
  # use `interface` as a parameter name. Drop the macro once the Windows
  # headers have been pulled in; BEGIN_NCBI_SCOPE sits after the include
  # block in every NCBI header.
  for f in dbapi_driver_utils dbapi_impl_cmd dbapi_impl_connection \
           dbapi_impl_result; do
    sed -i 's|^BEGIN_NCBI_SCOPE|#undef interface  /* mingw rpc.h: #define interface struct */\nBEGIN_NCBI_SCOPE|' \
      "${SRC_DIR}/c++/include/dbapi/driver/impl/${f}.hpp"
    grep -q '^#undef interface' \
      "${SRC_DIR}/c++/include/dbapi/driver/impl/${f}.hpp"
  done

  # mingw-w64 already provides mode_t (as unsigned short); MSVC does not,
  # which is why the toolkit defines it unconditionally here.
  sed -i 's|^typedef unsigned int mode_t;|#ifdef _MSC_VER\ntypedef unsigned int mode_t;\n#endif|' \
    "${SRC_DIR}/c++/src/util/compress/api/tar.cpp"
fi

if ${on_macos}; then
  # ncbi_lbdns.c needs <arpa/nameser.h> and <resolv.h>, which live in the
  # Xcode SDK and are not part of zig's bundled darwin headers. The file
  # already carries a non-UNIX #else branch defining SERV_LBDNS_Open as a
  # no-op, so select that instead of pulling in the SDK. LBDNS is NCBI's
  # internal DNS-based service discovery: it is off unless explicitly
  # enabled through the registry, and standalone BLAST (including
  # -remote, which goes over plain HTTP) does not use it.
  sed -i '0,\|^#ifdef NCBI_OS_UNIX$|s||#if 0  /* zig: no arpa/nameser.h in zig darwin headers */|' \
    "${SRC_DIR}/c++/src/connect/ncbi_lbdns.c"
  grep -q 'no arpa/nameser.h in zig darwin headers' \
    "${SRC_DIR}/c++/src/connect/ncbi_lbdns.c"
fi

build_root="conda-build"

# One configure invocation for every OS: all third-party libraries come
# from the conda host env (the shims translate library naming on win).
configure_args=(
  --prefix="${PREFIX}"
  --with-build-root="${build_root}"
  --with-projects=scripts/projects/blast/project.lst
  --with-experimental=Int8GI
  --with-mt
  --with-openmp
  --with-static
  --without-dll
  --with-flat-makefile
  --without-autodep
  --without-makefile-auto-update
  --without-caution
  --without-debug
  --without-strip
  --without-vdb
  --without-gnutls
  --without-gcrypt
  --without-boost
  # CI runners preinstall ccache; NCBI's configure auto-adopts any it
  # finds, and on Windows (where the MSYS2 PATH keeps the system PATH
  # visible) ccache cannot exec our bash shims — every compile fails
  # with "execute_noreturn ... failed". Same class of leak for distcc.
  --without-ccache
  --without-distcc
  --with-z="${conda_root}"
  --with-bz2="${conda_root}"
  --with-lmdb="${conda_root}"
  --with-sqlite3="${conda_root}"
)

if ${on_windows}; then
  # NCBI declares its Windows system libraries with MSVC-only
  # `#pragma comment(lib, ...)` directives (and gets the rest from its
  # .vcxproj files); clang ignores those, so the import libraries have to
  # be named on the link line. configure threads $LIBS through to every
  # link via CONF_LIBS/ORIG_LIBS.
  export LIBS="-ldbghelp -lgdi32 -lws2_32 -ladvapi32 -luser32 -lshell32 -lole32 -loleaut32 -luuid -lcrypt32 -lbcrypt -lsecur32 -lshlwapi -lpsapi -lrpcrt4 -liphlpapi -lnetapi32 -lversion -lwinmm ${LIBS:-}"

  # NCBI's bundled config.guess (2013) does not recognize MSYS_NT, and an
  # explicit mingw32 host is what selects the toolkit's native-Windows
  # code path: configure defines NCBI_OS_MSWIN when windows.h is present
  # and the host is not cygwin (the same macro its MSVC builds use).
  # build == host keeps autoconf out of cross-compilation mode — the
  # binaries we produce run natively on this machine.
  configure_args+=(
    --build=x86_64-w64-mingw32
    --host=x86_64-w64-mingw32
  )
else
  # rpath is a unix concept; on Windows the DLL search path is used.
  configure_args+=(--with-runpath="${conda_root}/lib")
fi

cd "${SRC_DIR}/c++"
./configure "${configure_args[@]}"

if ${on_windows}; then
  # project_tree_builder is itself a native Windows binary now, so it
  # writes Makefile.flat with backslash separators and a native
  # top_srcdir. MSYS make treats a backslash as an escape character, so
  # convert the separators (a trailing backslash is a line continuation
  # and must be preserved) and restore a POSIX top_srcdir — make cannot
  # use a "C:" path in a target or include, the colon is a rule separator.
  flat="${build_root}/build/Makefile.flat"
  if grep -qE '\\[[:space:]]+$' "${flat}"; then
    echo "unexpected continuation with trailing whitespace in ${flat}" >&2
    exit 1
  fi
  sed -i 's|\\\(.\)|/\1|g' "${flat}"
  sed -i "s|^top_srcdir=.*|top_srcdir=${SRC_DIR}/c++|" "${flat}"

  # xblast compiles the BLAST core C sources through generated one-line
  # stubs whose #include embeds $(srcdir). MSYS translates POSIX paths in
  # argv, but not inside a file, and the native clang cannot open
  # "/c/Users/...". Pre-generate the stubs with native "C:/..." paths;
  # the pattern rule has no prerequisites, so make leaves them alone.
  stub_dir="${build_root}/build/algo/blast/api"
  mkdir -p "${stub_dir}"
  core_native="$(cygpath -m "${SRC_DIR}/c++/src/algo/blast/core")"
  for f in "${SRC_DIR}"/c++/src/algo/blast/core/*.c; do
    b="$(basename "${f}" .c)"
    printf '#include "%s/%s.c"\n' "${core_native}" "${b}" \
      > "${stub_dir}/.core_${b}.c"
  done

  # project_tree_builder skips the xxconnect2 project ("unmet
  # requirements") on both platforms, but on Windows it still emits
  # -lxxconnect2 on the app link lines. Supply an empty archive: if
  # anything genuinely needed a symbol from it, the link would still fail
  # with an undefined symbol rather than silently misbehave.
  mkdir -p "${build_root}/lib"
  : > "${SRC_DIR}/empty_stub.c"
  "${wrap_dir}/zig-cc" -c "${SRC_DIR}/empty_stub.c" -o "${SRC_DIR}/empty_stub.o"
  "${wrap_dir}/ar" cr "${build_root}/lib/libxxconnect2.a" "${SRC_DIR}/empty_stub.o"
fi

# Build the BLAST+ user-facing applications (same set bioconda ships)
# rather than every project in the tree.
apps=(
  blastn blastp blastx tblastn tblastx psiblast rpsblast rpstblastn
  blast_formatter deltablast makembindex segmasker dustmasker windowmasker
  makeblastdb makeprofiledb blastdbcmd blastdb_aliastool convert2blastmask
  blastdbcheck
)
targets=()
for app in "${apps[@]}"; do targets+=("${app}.exe"); done

make -C "${build_root}/build" -f Makefile.flat -j"${CPU_COUNT:-4}" "${targets[@]}"

# The flat-makefile build has no usable `make install`; stage the built
# binaries and helper scripts directly.
if ${on_windows}; then
  dest="${PREFIX}/Library/bin"
else
  dest="${PREFIX}/bin"
fi
mkdir -p "${dest}"

# The flat makefile emits extensionless binaries even on Windows, where
# an executable must be named *.exe to be launchable.
exe_suffix=""
${on_windows} && exe_suffix=".exe"

for app in "${apps[@]}"; do
  if [[ -f "${build_root}/bin/${app}" ]]; then
    install -m 0755 "${build_root}/bin/${app}" "${dest}/${app}${exe_suffix}"
  elif [[ -f "${build_root}/bin/${app}.exe" ]]; then
    install -m 0755 "${build_root}/bin/${app}.exe" "${dest}/${app}${exe_suffix}"
  else
    echo "expected binary missing: ${app}" >&2
    exit 1
  fi
  # (lmdb's NEEDED entry is clean by construction — the shim links the
  # SONAME-fixed copy in hostlibs — so no post-link patching is needed;
  # post-link patchelf here previously caused install-time NEEDED
  # corruption via the placeholder-rewrite.)
done

# Helper scripts shipped with the official BLAST+ distributions.
for script in legacy_blast.pl update_blastdb.pl get_species_taxids.sh; do
  if [[ -f "src/app/blast/${script}" ]]; then
    install -m 0755 "src/app/blast/${script}" "${dest}/"
  fi
done
for script in cleanup-blastdb-volumes.py; do
  if [[ -f "src/app/blastdb/${script}" ]]; then
    install -m 0755 "src/app/blastdb/${script}" "${dest}/"
  fi
done
