# Benchmark: zig-built blast vs bioconda blast

Comparison of this repo's package against the official bioconda package,
same upstream version, same machine, same inputs.

| | this repo (`blast-2.17.0-hcc556be_0`) | bioconda (`blast-2.17.0-h66d330f_0`) |
|---|---|---|
| Compiler | zig cc / zig c++ 0.16 (clang 21, libc++) | gcc (conda-forge toolchain, libstdc++) |
| Linkage | static NCBI libs (`--with-static`), stripped | shared NCBI libs (`--with-dll`) |
| CPU baseline | x86-64-v2 (SSE4.2 via `-march=x86_64_v2`) | SSE4.2 disabled (`--without-sse42`) |
| glibc floor | 2.17 | 2.17 (conda-forge sysroot) |
| OpenMP | llvm-openmp (`libomp`) | libgomp (`--with-openmp`) |

## Environment

- CPU: Intel Xeon W-2145 (8 cores / 16 threads, Skylake-W), Linux 6.8
- Timing: `hyperfine`, 1 warmup; 5 runs (3 for the long blastp runs)
- Data: deterministic synthetic FASTA, seeded PRNG
  ([`bench/gen_data.py`](bench/gen_data.py)) — 20k nucleotide subjects
  (~20 MB) with 200 mutated-subsequence queries; 10k protein subjects
  (~3.5 M aa) with 100 mutated queries.
- Runner: [`bench/bench.sh`](bench/bench.sh)

## Correctness

`blastn` and `blastp` tabular outputs (12-column `outfmt 6`, sorted) are
**byte-identical** between the two packages: 200/200 and 839/839 hit
lines. Same alignments, same scores, same e-values.

## Results (mean ± σ; ratio > 1 means bioconda slower)

| Task | this repo | bioconda | bioconda / this repo |
|---|---:|---:|---:|
| startup (`blastn -version`) | 74.5 ± 5.5 ms | 88.5 ± 7.7 ms | **1.19×** |
| `makeblastdb` (20 MB nucl) | 378 ± 10 ms | 464 ± 12 ms | **1.23×** |
| `blastn`, 1 thread | 188 ± 13 ms | 173 ± 2 ms | 0.92× |
| `blastn`, 8 threads | 221 ± 11 ms | 151 ± 13 ms | 0.68× |
| `blastp`, 1 thread | 15.06 ± 0.04 s | 15.53 ± 0.01 s | **1.03×** |
| `blastp`, 8 threads | 2.40 ± 0.03 s | 2.45 ± 0.03 s | **1.02×** |

## Interpretation

- **On the substantive workload (blastp, 15 s single-thread, 6.3×
  scaling on 8 threads) the two builds are equivalent** — within 2–3%,
  slightly favoring this repo. Compute-bound BLAST performance is the
  same regardless of the toolchain.
- Startup and `makeblastdb` are measurably faster here (static linking:
  no `libstdc++`/NCBI shared-object relocation work at exec time).
- The `blastn` rows are dominated by fixed costs, not search: the whole
  run lasts ~0.2 s on this small dataset, and going 1→8 threads makes
  this build *slower* (188→221 ms) while barely helping bioconda's
  (173→151 ms). That gap is thread-pool spin-up (libomp vs libgomp
  defaults) amortized over almost no work — it disappears into the noise
  on any realistically sized nucleotide search. Treat those two rows as
  a fixed-overhead measurement, not a throughput one.

## Microarch variants: x86-64-v2 vs v3 (AVX2)

Following the prefix.dev microarch pattern, a `microarch_level` variant
axis was wired (see `recipe/variants.yaml`) and both levels were built
and compared on the same machine (`bench/microbench.sh`, level 2 =
`h3989d59_203`, level 3 = `h43b3d28_303`).

**Result: AVX2 is not worth shipping for BLAST.** `blastp` tabular
output is byte-identical between variants (839 lines), and every timing
delta sits inside the noise:

| Task | v2 | v3 | verdict |
|---|---:|---:|---|
| `blastp` 1 thread | 15.75 ± 0.23 s | 15.55 ± 0.09 s | 1.01× ± 0.02 — noise |
| `blastp` 8 threads | 2.87 ± 0.30 s | 3.03 ± 0.07 s | overlapping σ — noise |
| `blastn` 1 thread | 194 ± 16 ms | 185 ± 11 ms | noise |
| `makeblastdb` | 373 ± 10 ms | 380 ± 9 ms | noise |

This matches the mechanism: BLAST's hot paths use explicit SSE4.2
intrinsics (microarch level 2), so level 3 only changes what the
compiler auto-vectorizes elsewhere — which measures as nothing. The
variant axis stays in place with a single level ("2"), so a future
level-3 build is a one-line change; the level-2 gating run dependency
(`_x86_64-microarch-level >=2`) now also makes the package's real CPU
floor solver-enforced instead of a documented SIGILL.

## Reproducing

```sh
pixi install                       # build + install this repo's blast
cd bench
python3 gen_data.py                # writes data/ (seeded, deterministic)
# bioconda env: any env with bioconda blast 2.17.0 on PATH
bash bench.sh ../.pixi/envs/default/bin <bioconda-env>/bin results
```

`results/` gets one markdown/JSON pair per task (hyperfine exports) plus
`verify.md` with the output-identity check.
