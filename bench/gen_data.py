#!/usr/bin/env python3
"""Deterministic synthetic BLAST benchmark data (seeded PRNG)."""
import random

random.seed(20260812)

AA = "ACDEFGHIKLMNPQRSTVWY"
NT = "ACGT"


def mutate(seq, alphabet, rate):
    out = []
    for c in seq:
        r = random.random()
        if r < rate:
            out.append(random.choice(alphabet))
        else:
            out.append(c)
    return "".join(out)


def write_fasta(path, records):
    with open(path, "w") as fh:
        for name, seq in records:
            fh.write(f">{name}\n")
            for i in range(0, len(seq), 70):
                fh.write(seq[i:i + 70] + "\n")


# --- nucleotide: 20k subjects (~20 Mb), 200 queries sampled w/ 2% mutations
subjects = []
for i in range(20000):
    n = random.randint(500, 1500)
    subjects.append((f"nsubj{i}", "".join(random.choice(NT) for _ in range(n))))
write_fasta("data/nucl_db.fa", subjects)

queries = []
for i in range(200):
    name, seq = random.choice(subjects)
    ln = random.randint(300, min(800, len(seq)))
    start = random.randint(0, len(seq) - ln)
    queries.append((f"nq{i}_{name}", mutate(seq[start:start + ln], NT, 0.02)))
write_fasta("data/nucl_q.fa", queries)

# --- protein: 10k subjects (~3.5M aa), 100 queries w/ 5% mutations
psubjects = []
for i in range(10000):
    n = random.randint(200, 500)
    psubjects.append((f"psubj{i}", "".join(random.choice(AA) for _ in range(n))))
write_fasta("data/prot_db.fa", psubjects)

pqueries = []
for i in range(100):
    name, seq = random.choice(psubjects)
    pqueries.append((f"pq{i}_{name}", mutate(seq, AA, 0.05)))
write_fasta("data/prot_q.fa", pqueries)

print("data written")
