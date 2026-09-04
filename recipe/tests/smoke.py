"""Functional package test: build a tiny nucleotide and protein database,
search them, and check the expected self-hits come back. Runs on every
platform through rattler-build's test phase (python is a test-only
requirement, not a package dependency)."""
import os
import subprocess
import sys
import tempfile

import random

# Deterministic pseudo-random sequences: a repetitive hand-written one
# gets masked entirely by DUST/SEG and yields no hits.
_rng = random.Random(20260903)
NUC = "".join(_rng.choice("ACGT") for _ in range(300))
PROT = "".join(_rng.choice("ACDEFGHIKLMNPQRSTVWY") for _ in range(300))


def run(*cmd):
    print("+", " ".join(cmd), flush=True)
    # stderr stays inherited so a failing tool's reason lands in the CI log.
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, text=True).stdout


def write(path, name, seq):
    with open(path, "w") as fh:
        fh.write(f">{name}\n{seq}\n")


def check(kind, dbtype, seq, prog):
    db = f"{kind}_db"
    write(f"{kind}.fa", f"{kind}1", seq)
    write(f"{kind}_q.fa", "query", seq[40:160])
    run("makeblastdb", "-in", f"{kind}.fa", "-dbtype", dbtype, "-out", db,
        "-parse_seqids")
    entry = run("blastdbcmd", "-db", db, "-entry", f"{kind}1")
    assert entry.startswith(f">{kind}1"), entry
    hits = run(prog, "-query", f"{kind}_q.fa", "-db", db, "-outfmt",
               "6 qseqid sseqid pident length", "-num_threads", "2",
               *(["-dust", "no"] if prog == "blastn" else ["-seg", "no"]))
    rows = [r.split("\t") for r in hits.strip().splitlines()]
    assert rows, f"{prog}: no hits\n{hits}"
    q, s, pident, length = rows[0]
    assert s == f"{kind}1" and float(pident) == 100.0 and int(length) == 120, rows[0]
    print(f"{prog}: OK ({pident}% over {length})")


def main():
    work = tempfile.mkdtemp(prefix="blast-smoke-")
    os.chdir(work)
    check("nuc", "nucl", NUC, "blastn")
    check("prot", "prot", PROT, "blastp")
    # The BLAST database index format is shared across platforms; make
    # sure the LMDB-backed lookup path (v5 databases) is functional.
    info = run("blastdbcmd", "-db", "nuc_db", "-info")
    assert "1 sequences" in info, info
    print("smoke test passed")


if __name__ == "__main__":
    sys.exit(main())
