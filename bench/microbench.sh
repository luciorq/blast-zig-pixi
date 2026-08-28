#!/usr/bin/env bash
# Benchmark the microarch_level 2 vs 3 variants of the SAME recipe.
# Usage: microbench.sh <v2_conda> <v3_conda> <outdir>
set -euo pipefail
V2="$1"; V3="$2"; OUT="$3"
cd "$(dirname "$0")"
mkdir -p "$OUT"
DEPS=/home/luciorq/projects/blast-zig-pixi/.pixi/envs/default/lib

stage() { # stage <conda> <dir>
  rm -rf "$2"; mkdir -p "$2"; cd "$2"
  python3 - "$1" <<'EOF'
import sys, zipfile, glob, subprocess
zipfile.ZipFile(sys.argv[1]).extractall()
pkg = glob.glob('pkg-*.tar.zst')[0]
subprocess.run(['tar', '--zstd', '-xf', pkg], check=True)
EOF
  mkdir -p lib
  ln -sf "$DEPS"/*.so "$DEPS"/*.so.* lib/ 2>/dev/null || true
  cd - > /dev/null
}

stage "$V2" work/v2
stage "$V3" work/v3

# Sanity: correct flags baked in each
for v in v2 v3; do
  tar --zstd -xf work/$v/info-*.tar.zst -O info/index.json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print('$v flags:', d['flags'], '| build:', d['build'])"
done

# DBs once per variant + output identity check
fmt='6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore'
for v in v2 v3; do
  work/$v/bin/makeblastdb -in data/prot_db.fa -dbtype prot -out work/$v/pdb > /dev/null
  work/$v/bin/makeblastdb -in data/nucl_db.fa -dbtype nucl -out work/$v/ndb > /dev/null
  work/$v/bin/blastp -query data/prot_q.fa -db work/$v/pdb -outfmt "$fmt" | sort > work/$v/blastp.tsv
done
if diff -q work/v2/blastp.tsv work/v3/blastp.tsv > /dev/null; then
  echo "blastp output: IDENTICAL between variants ($(wc -l < work/v2/blastp.tsv) lines)"
else
  echo "blastp output: DIFFERS — INVESTIGATE BEFORE TRUSTING TIMINGS"
fi

hf() {
  local name="$1"; shift
  hyperfine --style basic --warmup 1 "$@" \
    --export-markdown "$OUT/$name.md" --export-json "$OUT/$name.json"
}

hf blastp_t1 -r 3 \
  -n v2 "work/v2/bin/blastp -query data/prot_q.fa -db work/v2/pdb -num_threads 1 -outfmt 6 -out /dev/null" \
  -n v3 "work/v3/bin/blastp -query data/prot_q.fa -db work/v3/pdb -num_threads 1 -outfmt 6 -out /dev/null"

hf blastp_t8 -r 5 \
  -n v2 "work/v2/bin/blastp -query data/prot_q.fa -db work/v2/pdb -num_threads 8 -outfmt 6 -out /dev/null" \
  -n v3 "work/v3/bin/blastp -query data/prot_q.fa -db work/v3/pdb -num_threads 8 -outfmt 6 -out /dev/null"

hf blastn_t1 -r 5 \
  -n v2 "work/v2/bin/blastn -query data/nucl_q.fa -db work/v2/ndb -num_threads 1 -outfmt 6 -out /dev/null" \
  -n v3 "work/v3/bin/blastn -query data/nucl_q.fa -db work/v3/ndb -num_threads 1 -outfmt 6 -out /dev/null"

hf makeblastdb_nucl -r 5 \
  -n v2 "work/v2/bin/makeblastdb -in data/nucl_db.fa -dbtype nucl -out work/v2/tmpdb" \
  -n v3 "work/v3/bin/makeblastdb -in data/nucl_db.fa -dbtype nucl -out work/v3/tmpdb"

echo "done -> $OUT"
