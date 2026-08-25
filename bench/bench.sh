#!/usr/bin/env bash
# Benchmark: zig-built blast (this repo) vs bioconda blast 2.17.0.
# Usage: bench.sh <zig_bin_dir> <bioconda_bin_dir> <outdir>
set -euo pipefail

ZIG_BIN="$1"
BIO_BIN="$2"
OUT="$3"
cd "$(dirname "$0")"
mkdir -p "$OUT" work/zig work/bio

# --- one-time DB builds for the search benchmarks + output verification
"$ZIG_BIN/makeblastdb" -in data/nucl_db.fa -dbtype nucl -out work/zig/ndb > /dev/null
"$BIO_BIN/makeblastdb" -in data/nucl_db.fa -dbtype nucl -out work/bio/ndb > /dev/null
"$ZIG_BIN/makeblastdb" -in data/prot_db.fa -dbtype prot -out work/zig/pdb > /dev/null
"$BIO_BIN/makeblastdb" -in data/prot_db.fa -dbtype prot -out work/bio/pdb > /dev/null

# --- correctness: identical outputs required before timing means anything
fmt='6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore'
"$ZIG_BIN/blastn" -query data/nucl_q.fa -db work/zig/ndb -outfmt "$fmt" | sort > work/zig/blastn.tsv
"$BIO_BIN/blastn" -query data/nucl_q.fa -db work/bio/ndb -outfmt "$fmt" | sort > work/bio/blastn.tsv
"$ZIG_BIN/blastp" -query data/prot_q.fa -db work/zig/pdb -outfmt "$fmt" | sort > work/zig/blastp.tsv
"$BIO_BIN/blastp" -query data/prot_q.fa -db work/bio/pdb -outfmt "$fmt" | sort > work/bio/blastp.tsv

{
  echo "## Output verification"
  for t in blastn blastp; do
    n=$(wc -l < "work/zig/$t.tsv")
    if diff -q "work/zig/$t.tsv" "work/bio/$t.tsv" > /dev/null; then
      echo "- $t: IDENTICAL output ($n hit lines)"
    else
      d=$(diff "work/zig/$t.tsv" "work/bio/$t.tsv" | grep -c '^[<>]' || true)
      echo "- $t: DIFFERS ($d differing lines of $n)"
    fi
  done
} > "$OUT/verify.md"
cat "$OUT/verify.md"

hf() {
  local name="$1"; shift
  hyperfine --style basic --warmup 1 "$@" \
    --export-markdown "$OUT/$name.md" --export-json "$OUT/$name.json"
}

hf startup -r 10 \
  -n zig "$ZIG_BIN/blastn -version" \
  -n bioconda "$BIO_BIN/blastn -version"

hf makeblastdb_nucl -r 5 \
  -n zig "$ZIG_BIN/makeblastdb -in data/nucl_db.fa -dbtype nucl -out work/zig/tmpdb" \
  -n bioconda "$BIO_BIN/makeblastdb -in data/nucl_db.fa -dbtype nucl -out work/bio/tmpdb"

hf blastn_t1 -r 5 \
  -n zig "$ZIG_BIN/blastn -query data/nucl_q.fa -db work/zig/ndb -num_threads 1 -outfmt 6 -out /dev/null" \
  -n bioconda "$BIO_BIN/blastn -query data/nucl_q.fa -db work/bio/ndb -num_threads 1 -outfmt 6 -out /dev/null"

hf blastn_t8 -r 5 \
  -n zig "$ZIG_BIN/blastn -query data/nucl_q.fa -db work/zig/ndb -num_threads 8 -outfmt 6 -out /dev/null" \
  -n bioconda "$BIO_BIN/blastn -query data/nucl_q.fa -db work/bio/ndb -num_threads 8 -outfmt 6 -out /dev/null"

hf blastp_t1 -r 3 \
  -n zig "$ZIG_BIN/blastp -query data/prot_q.fa -db work/zig/pdb -num_threads 1 -outfmt 6 -out /dev/null" \
  -n bioconda "$BIO_BIN/blastp -query data/prot_q.fa -db work/bio/pdb -num_threads 1 -outfmt 6 -out /dev/null"

hf blastp_t8 -r 3 \
  -n zig "$ZIG_BIN/blastp -query data/prot_q.fa -db work/zig/pdb -num_threads 8 -outfmt 6 -out /dev/null" \
  -n bioconda "$BIO_BIN/blastp -query data/prot_q.fa -db work/bio/pdb -num_threads 8 -outfmt 6 -out /dev/null"

echo "benchmarks complete -> $OUT"
