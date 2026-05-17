#!/usr/bin/env python3

import json
import numpy as np
from sklearn.cluster import MiniBatchKMeans

DIM = 14
BUCKETS = 4096
IVF_CLUSTERS = 2048

INPUT_PATH = "references.json"

DATASET_OUTPUT = "priv/references_bucketed.bin"
OFFSETS_OUTPUT = "priv/bucket_offsets.bin"
IVF_DATASET_OUTPUT = "priv/references_ivf.bin"
IVF_OFFSETS_OUTPUT = "priv/ivf_offsets.bin"
IVF_CENTROIDS_OUTPUT = "priv/ivf_centroids.bin"

print("Reading JSON...")

with open(INPUT_PATH, "r") as f:
    data = json.load(f)

vectors = np.array(
    [item["vector"] for item in data],
    dtype=np.float32
)

labels = np.array(
    [
        1 if item["label"] == "fraud" else 0
        for item in data
    ],
    dtype=np.uint16
)

print("Quantizing...")

encoded = np.round(
    vectors * 65534.0
).astype(np.uint16)

missing = vectors < 0
encoded[missing] = 65535

print("Building buckets...")

bucket_ids = (
    (
        encoded[:, 0].astype(np.uint32) >> 8
    ) ^
    (
        encoded[:, 2].astype(np.uint32) >> 8
    ) ^
    (
        encoded[:, 5].astype(np.uint32) >> 8
    ) ^
    (
        encoded[:, 12].astype(np.uint32) >> 8
    )
) & (BUCKETS - 1)

rows = []

for i in range(len(encoded)):
    row = np.concatenate([
        encoded[i],
        [labels[i]],
        [0]
    ]).astype(np.uint16)

    rows.append((bucket_ids[i], row))

rows.sort(key=lambda x: x[0])

bucket_offsets = np.zeros(
    (BUCKETS + 1,),
    dtype=np.uint64
)

dataset = []

current_bucket = 0
count = 0

for bucket, row in rows:
    while current_bucket <= bucket:
        bucket_offsets[current_bucket] = count
        current_bucket += 1

    dataset.append(row)
    count += 1

while current_bucket <= BUCKETS:
    bucket_offsets[current_bucket] = count
    current_bucket += 1

dataset = np.array(dataset, dtype=np.uint16)

print("Writing dataset...")

dataset.tofile(DATASET_OUTPUT)

print("Writing offsets...")

bucket_offsets.tofile(OFFSETS_OUTPUT)

print("Training IVF centroids...")

cluster_input = encoded.astype(np.float32)
cluster_input[encoded == 65535] = -65534.0
cluster_input /= 65534.0

rng = np.random.default_rng(42)
sample_idx = rng.choice(
    len(cluster_input),
    size=min(300_000, len(cluster_input)),
    replace=False
)

kmeans = MiniBatchKMeans(
    n_clusters=IVF_CLUSTERS,
    batch_size=8192,
    n_init=1,
    max_iter=80,
    random_state=42,
    reassignment_ratio=0.01
)

kmeans.fit(cluster_input[sample_idx])

print("Assigning IVF buckets...")

ivf_ids = np.empty(
    (len(cluster_input),),
    dtype=np.uint32
)

for start in range(0, len(cluster_input), 100_000):
    end = min(start + 100_000, len(cluster_input))
    ivf_ids[start:end] = kmeans.predict(cluster_input[start:end])

ivf_rows = []

for i in range(len(encoded)):
    row = np.concatenate([
        encoded[i],
        [labels[i]],
        [0]
    ]).astype(np.uint16)

    ivf_rows.append((ivf_ids[i], row))

ivf_rows.sort(key=lambda x: x[0])

ivf_offsets = np.zeros(
    (IVF_CLUSTERS + 1,),
    dtype=np.uint64
)

ivf_dataset = []
current_bucket = 0
count = 0

for bucket, row in ivf_rows:
    while current_bucket <= bucket:
        ivf_offsets[current_bucket] = count
        current_bucket += 1

    ivf_dataset.append(row)
    count += 1

while current_bucket <= IVF_CLUSTERS:
    ivf_offsets[current_bucket] = count
    current_bucket += 1

ivf_dataset = np.array(ivf_dataset, dtype=np.uint16)
ivf_centroids = kmeans.cluster_centers_.astype(np.float32)

print("Writing IVF dataset...")

ivf_dataset.tofile(IVF_DATASET_OUTPUT)

print("Writing IVF offsets...")

ivf_offsets.tofile(IVF_OFFSETS_OUTPUT)

print("Writing IVF centroids...")

ivf_centroids.tofile(IVF_CENTROIDS_OUTPUT)

print(f"""
Done.

Rows: {len(dataset)}
Buckets: {BUCKETS}
Dataset: {DATASET_OUTPUT}
Offsets: {OFFSETS_OUTPUT}
IVF clusters: {IVF_CLUSTERS}
IVF dataset: {IVF_DATASET_OUTPUT}
IVF offsets: {IVF_OFFSETS_OUTPUT}
IVF centroids: {IVF_CENTROIDS_OUTPUT}
""")
