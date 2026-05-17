#include <erl_nif.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define DIM 14
#define K 5
#define BUCKETS 4096
#define IVF_CLUSTERS 2048
#define IVF_PROBES 32

typedef struct {
  uint16_t vec[14];
  uint16_t label;
  uint16_t pad;
} Row;

typedef struct {
  uint64_t score;
  uint16_t label;
} Neighbor;

typedef struct {
  float score;
  uint16_t cluster;
} ClusterNeighbor;

static Row* dataset_ptr = NULL;
static uint64_t* offsets_ptr = NULL;
static Row* ivf_dataset_ptr = NULL;
static uint64_t* ivf_offsets_ptr = NULL;
static float* ivf_centroids_ptr = NULL;

static inline uint64_t l2_distance(const uint16_t* q, const uint16_t* v, uint64_t worst) {
  uint64_t sum = 0;

  for (int i = 0; i < DIM; i++) {
    uint32_t diff;

    if (q[i] == 65535) {
      diff = v[i] == 65535 ? 0 : 65534u + (uint32_t)v[i];
    } else if (v[i] == 65535) {
      diff = (uint32_t)q[i] + 65534u;
    } else {
      diff = q[i] > v[i] ? (uint32_t)q[i] - (uint32_t)v[i] : (uint32_t)v[i] - (uint32_t)q[i];
    }

    sum += (uint64_t)diff * (uint64_t)diff;

    if (sum > worst) return UINT64_MAX;
  }

  return sum;
}

static inline void insert_neighbor(uint64_t score, uint16_t label, Neighbor* neighbors) {
  if (score >= neighbors[K - 1].score) return;

  int pos = K - 1;

  while (pos > 0 && score < neighbors[pos - 1].score) {
    neighbors[pos] = neighbors[pos - 1];
    pos--;
  }

  neighbors[pos].score = score;
  neighbors[pos].label = label;
}

static inline void insert_cluster_neighbor(float score, uint16_t cluster, ClusterNeighbor* neighbors) {
  if (score >= neighbors[IVF_PROBES - 1].score) return;

  int pos = IVF_PROBES - 1;

  while (pos > 0 && score < neighbors[pos - 1].score) {
    neighbors[pos] = neighbors[pos - 1];
    pos--;
  }

  neighbors[pos].score = score;
  neighbors[pos].cluster = cluster;
}

static inline float centroid_distance(const uint16_t* q, const float* centroid) {
  float sum = 0.0f;

  for (int i = 0; i < DIM; i++) {
    float qv = q[i] == 65535 ? -1.0f : (float)q[i] / 65534.0f;
    float diff = qv - centroid[i];
    sum += diff * diff;
  }

  return sum;
}

static ERL_NIF_TERM knn(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary query_bin;

  if (argc != 1 || !enif_inspect_binary(env, argv[0], &query_bin)) return enif_make_badarg(env);
 
  uint16_t query[DIM] __attribute__((aligned(32)));

  memcpy(query, query_bin.data, DIM * sizeof(uint16_t));

  Neighbor neighbors[K];

  for (int i = 0; i < K; i++) {
    neighbors[i].score = UINT64_MAX;
    neighbors[i].label = 0;
  }

  uint64_t worst = UINT64_MAX;

  ClusterNeighbor clusters[IVF_PROBES];

  for (int i = 0; i < IVF_PROBES; i++) {
    clusters[i].score = INFINITY;
    clusters[i].cluster = 0;
  }

  for (uint16_t i = 0; i < IVF_CLUSTERS; i++) {
    float score = centroid_distance(query, &ivf_centroids_ptr[i * DIM]);
    insert_cluster_neighbor(score, i, clusters);
  }

  for (int probe = 0; probe < IVF_PROBES; probe++) {
    uint16_t bucket = clusters[probe].cluster;

    uint64_t start = ivf_offsets_ptr[bucket];

    uint64_t end = ivf_offsets_ptr[bucket + 1];

    for (uint64_t i = start; i < end; i++) {
      Row* row = &ivf_dataset_ptr[i];

      uint64_t score = l2_distance(query, row->vec, worst);

      if (score < worst) {
        insert_neighbor(score, row->label, neighbors);
        worst = neighbors[K - 1].score;
      }
    }
  }

  uint16_t fraud = 0;
  uint16_t total = 0;

  for (int i = 0; i < K; i++) {
    if (neighbors[i].score == UINT64_MAX) continue;
    total++;
    fraud += neighbors[i].label ? 1 : 0;
  }

  double result = total > 0 ? (double)fraud / (double)K : 0.0;

  return enif_make_double(env, result);
}

static void* mmap_file(const char* path, size_t* size_out) {
  int fd = open(path, O_RDONLY);

  if (fd < 0) return NULL;

  struct stat st;

  if (fstat(fd, &st) < 0) {
    close(fd);
    return NULL;
  }

  void* ptr = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);

  close(fd);

  if (ptr == MAP_FAILED) return NULL;

  madvise(ptr, st.st_size, MADV_RANDOM);

  *size_out = st.st_size;

  return ptr;
}

static ERL_NIF_TERM load_dataset(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary dataset_bin;
  ErlNifBinary offsets_bin;
  ErlNifBinary ivf_dataset_bin;
  ErlNifBinary ivf_offsets_bin;
  ErlNifBinary ivf_centroids_bin;

  if (
    argc != 5 ||
    !enif_inspect_binary(
      env,
      argv[0],
      &dataset_bin
    ) ||
    !enif_inspect_binary(
      env,
      argv[1],
      &offsets_bin
    ) ||
    !enif_inspect_binary(
      env,
      argv[2],
      &ivf_dataset_bin
    ) ||
    !enif_inspect_binary(
      env,
      argv[3],
      &ivf_offsets_bin
    ) ||
    !enif_inspect_binary(
      env,
      argv[4],
      &ivf_centroids_bin
    )
  ) {
    return enif_make_badarg(env);
  }

  char dataset_path[1024];
  char offsets_path[1024];
  char ivf_dataset_path[1024];
  char ivf_offsets_path[1024];
  char ivf_centroids_path[1024];

  if (
    dataset_bin.size >= sizeof(dataset_path) ||
    offsets_bin.size >= sizeof(offsets_path) ||
    ivf_dataset_bin.size >= sizeof(ivf_dataset_path) ||
    ivf_offsets_bin.size >= sizeof(ivf_offsets_path) ||
    ivf_centroids_bin.size >= sizeof(ivf_centroids_path)
  ) {
    return enif_make_atom(env, "path_too_long");
  }

  memcpy(dataset_path, dataset_bin.data, dataset_bin.size);
  dataset_path[dataset_bin.size] = '\0';
  memcpy(offsets_path, offsets_bin.data, offsets_bin.size);
  offsets_path[offsets_bin.size] = '\0';
  memcpy(ivf_dataset_path, ivf_dataset_bin.data, ivf_dataset_bin.size);
  ivf_dataset_path[ivf_dataset_bin.size] = '\0';
  memcpy(ivf_offsets_path, ivf_offsets_bin.data, ivf_offsets_bin.size);
  ivf_offsets_path[ivf_offsets_bin.size] = '\0';
  memcpy(ivf_centroids_path, ivf_centroids_bin.data, ivf_centroids_bin.size);
  ivf_centroids_path[ivf_centroids_bin.size] = '\0';

  size_t dataset_size;
  size_t offsets_size;
  size_t ivf_dataset_size;
  size_t ivf_offsets_size;
  size_t ivf_centroids_size;

  dataset_ptr = mmap_file(dataset_path, &dataset_size);
  offsets_ptr = mmap_file(offsets_path, &offsets_size);
  ivf_dataset_ptr = mmap_file(ivf_dataset_path, &ivf_dataset_size);
  ivf_offsets_ptr = mmap_file(ivf_offsets_path, &ivf_offsets_size);
  ivf_centroids_ptr = mmap_file(ivf_centroids_path, &ivf_centroids_size);

  if (!dataset_ptr || !offsets_ptr || !ivf_dataset_ptr || !ivf_offsets_ptr || !ivf_centroids_ptr)
    return enif_make_atom(env, "load_failed");

  return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
  {"load_dataset", 5, load_dataset},
  {"knn", 1, knn,ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(Elixir.Rinha2026.NIF, nif_funcs, NULL, NULL, NULL, NULL)
