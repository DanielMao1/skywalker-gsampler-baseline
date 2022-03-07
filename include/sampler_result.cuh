#pragma once
#include <gflags/gflags.h>
#include <omp.h>

#include "vec.cuh"

DECLARE_int32(device);
DECLARE_double(hd);
DECLARE_bool(peritr);
DECLARE_bool(node2vec);
DECLARE_double(p);
DECLARE_double(q);
DECLARE_bool(umresult);
DECLARE_bool(built);

#define ADD_FRONTIER 1
#define LOCALITY 1


struct sample_job {
  uint idx;
  uint node_id;
  bool val;  //= false
};

struct sample_job_new {
  uint idx_in_frontier;
  uint instance_idx;
  bool val;  //= false
};

struct id_pair {
  uint idx, node_id;
  __device__ id_pair &operator=(uint idx) {
    this->idx = 0;
    this->node_id = 0;
    return *this;
  }
};

enum class JobType {
  NS,  // neighbour sampling
  LS,  // layer sampling
  RW,  // random walk
  NODE2VEC
};

template <typename T>
__global__ void init_range_d(T *ptr, size_t size, size_t offset = 0) {
  if (TID < size) {
    ptr[TID] = offset + TID;
  }
}
template <typename T>
void init_range(T *ptr, size_t size, size_t offset = 0) {
  init_range_d<T><<<size / 512 + 1, 512>>>(ptr, size, offset);
}

template <typename T>
__global__ void get_sum_d(T *ptr, size_t size, size_t *result) {
  size_t local = 0;
  for (size_t i = TID; i < size; i += gridDim.x * blockDim.x) {
    local += ptr[i];
  }
  __syncthreads();
  size_t tmp = blockReduce<float>(local);
  if (LTID == 0) {
    *result = tmp;
  }
}

template <typename T>
size_t get_sum(T *ptr, size_t size) {
  size_t *sum;
  CUDA_RT_CALL(cudaMallocManaged(&sum, sizeof(size_t)));
  get_sum_d<T><<<1, BLOCK_SIZE>>>(ptr, size, sum);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  size_t t = *sum;
  return t;
}

static __global__ void initSeed2(uint *data, uint *seeds, size_t size,
                                 uint hop) {
  if (TID < size) {
    data[TID * hop] = seeds[TID];
  }
}

static __global__ void initSeed3(uint *data, uint *seeds, size_t size,
                                 uint hop) {
  if (TID < size) {
    data[TID] = seeds[TID];
  }
}

// template <JobType job, typename T>
// static __global__ void initStateSeed(SamplerState<job, T> *states, uint
// *seeds,
//                                      size_t size);

template <JobType job, typename T>
struct Jobs_result;

template <typename T>
struct Frontier {
  u64 *size;
  T *data;
  u64 capacity;
  void Allocate(size_t _size) {
    capacity = _size;
    CUDA_RT_CALL(cudaMalloc(&data, 3 * capacity * sizeof(T)));
    CUDA_RT_CALL(cudaMalloc(&size, 3 * sizeof(u64)));
  }
  __device__ void CheckActive(uint itr) {}
  __device__ void SetActive(uint itr, T idx) {
    size_t old = atomicAdd(&size[itr % 3], 1);
    data[capacity * (itr % 3) + old] = idx;
  }
  __device__ void Reset(uint itr) { size[itr % 3] = 0; }
  __device__ u64 Size(uint itr) { return size[itr % 3]; }
  __device__ T Get(uint itr, uint idx) {
    return data[capacity * (itr % 3) + idx];
  }
};
static __global__ void setFrontierSize(u64 *data, uint size) {
  if (TID == 0) data[0] = size;
}

template <JobType job, typename T>
struct SamplerState;

template <typename T>
struct SamplerState<JobType::NODE2VEC, T> {
  T last = 0;
  // bool alive = true;
};
// template <typename T> struct SamplerState<JobType::NODE2VEC, uint> {
//   // T *data;
//   uint depth = 0;
//   bool alive = true;
//   // void Allocate(uint size) { CUDA_RT_CALL(cudaMalloc(&data, size *
//   sizeof(T))); }
// };

// template<typename T>
#ifdef ADD_FRONTIER
template <typename T = uint>
struct sampleJob {
  uint instance_idx;
  uint offset;
  // uint itr;
  T src_id;
  int itr;
  bool val;
};
// template <typename T>
// struct JobInFrontier {
//   uint instance_idx;
//   uint offset;
//   // uint itr;
//   // T src_id;
// };
template <typename T = uint>
static __global__ void InitSampleFrontier(sampleJob<T> *data, uint *seed,
                                          uint size) {
  if (TID < size) {
    sampleJob<T> tmp = {TID, 0, seed[TID], 0, true};
    data[TID] = tmp;
  }
}
template <typename T = uint>
static __global__ void InitLocalitySampleFrontier(sampleJob<T> **data,
                                                  uint *seed, uint size,
                                                  uint vtx_per_bucket,
                                                  int *sizes) {
  if (TID < size) {
    sampleJob<T> tmp = {TID, 0, seed[TID], 0, true};
    uint bucket_idx = seed[TID] / vtx_per_bucket;
    size_t old = atomicAdd(&sizes[bucket_idx], 1);
    // assert(old < capacity[itr]); //change to ring buffer?
    data[bucket_idx][old] = tmp;
  }
}
template <typename T, uint bucket_num = 10>
struct LocalitySampleFrontier {
  // sampleJob<T> *data[bucket_num];
  sampleJob<T> **data, **data_h;
  int capacity;
  uint vtx_per_bucket;
  int *sizes;
  int *floor;
  int *focus;
  uint _bucket_num;
  uint size_per_bucket;
  // int hop_num = depth;
  void Allocate(size_t _size, uint *hops, uint num_vtx = 0) {
    _bucket_num = bucket_num;

    vtx_per_bucket = num_vtx / bucket_num + 1;

    assert(num_vtx != 0);
    assert(vtx_per_bucket != 0);
    capacity = _size;
    // CUDA_RT_CALL(cudaMalloc(&seed, capacity * sizeof(T)));
    uint length = 1;
    size_per_bucket =
        capacity * 26;  //  / bucket_num, hard to tell the buffer size
    // paster(size_per_bucket);
    // paster(bucket_num);
    data_h = new sampleJob<T> *[bucket_num];
    CUDA_RT_CALL(cudaMalloc(&data, bucket_num * sizeof(sampleJob<T> *)));

    // printf("%s:%d %s for %d\n", __FILE__, __LINE__, __FUNCTION__, 0);
    for (size_t i = 0; i < bucket_num; i++) {
      // capacity[0] *= hops[i];
      CUDA_RT_CALL(
          cudaMalloc(&data_h[i], size_per_bucket * sizeof(sampleJob<T>)));
    }
    CUDA_RT_CALL(cudaMalloc(&sizes, bucket_num * sizeof(int)));
    CUDA_RT_CALL(cudaMalloc(&floor, bucket_num * sizeof(int)));
    CUDA_RT_CALL(cudaMalloc(&focus, sizeof(int)));

    CUDA_RT_CALL(cudaMemcpy(data, data_h, bucket_num * sizeof(sampleJob<T> *),
                            cudaMemcpyHostToDevice));
    // printf("%s:%d %s for %d\n", __FILE__, __LINE__, __FUNCTION__, 0);
  }
  __host__ void Init(uint *seed, uint size) {
    InitLocalitySampleFrontier<T>
        <<<size / 1024 + 1, 1024>>>(data, seed, size, vtx_per_bucket, sizes);
    // int tmp = size;
    // CUDA_RT_CALL(cudaMemset(sizes, 0, bucket_num * sizeof(int)));
    CUDA_RT_CALL(cudaMemset(floor, 0, bucket_num * sizeof(int)));
    CUDA_RT_CALL(cudaMemset(focus, 0, sizeof(int)));
    // CUDA_RT_CALL(
    //     cudaMemcpy(&sizes[0], &tmp, sizeof(int), cudaMemcpyHostToDevice));
  }
  // __device__ void CheckActive(uint itr) {}
  __device__ void Add(uint instance_idx, uint offset, uint itr, T src_id) {
    assert(vtx_per_bucket != 0);
    uint bucket_idx = src_id / vtx_per_bucket;
    // printf("bucket_idx %u src_id %u vtx_per_bucket %u\n" , bucket_idx ,
    // src_id,vtx_per_bucket);

    size_t old = atomicAdd(&sizes[bucket_idx], 1);
    assert(old < size_per_bucket);  // change to ring buffer?

    sampleJob<T> tmp = {instance_idx, offset, src_id, itr, true};
    data[bucket_idx][old] = tmp;
  }
  // __device__ void Reset(uint itr) { size[itr % 3] = 0; }
  __device__ int Size(uint bucket_idx) { return sizes[bucket_idx]; }
  __device__ sampleJob<T> Get(uint bucket_idx, uint idx) {
    return data[bucket_idx][idx];
  }
  __device__ bool checkFocus(int idx) {
    if (floor[idx] < sizes[idx])
      return true;
    else
      return false;
  }
  __device__ void nextFocus(int current_focus) {
    for (size_t i = 1; i < bucket_num; i++) {
      int tmp = (current_focus + 1) % bucket_num;
      if (checkFocus(tmp)) {
        // CAS?
        int old = atomicCAS(focus, current_focus, tmp);
        // return tmp;
      }
    }
  }
  __device__ sampleJob<T> requireOneJobFromBucket(int bucket_idx) {
    // size_t old = atomicAdd(&floor[bucket_idx], 1);
    int old = atomicAggInc<int>(&floor[bucket_idx]);
    if (old < sizes[bucket_idx]) {
      return data[bucket_idx][old];
    } else {
      atomicSub(&floor[bucket_idx], 1);
      sampleJob<T> tmp = {0, 0, 0, 0, false};
      return tmp;
    }
  }
  // coalesced_group would cause "Warp Illegal Address" ?
  //  __forceinline__ __device__ sampleJob<T> requireOneJob() {
  //    auto active = coalesced_threads();
  //    int current_focus = *focus;
  //    if (!active.thread_rank()) {
  //      if (!checkFocus(current_focus)) {
  //        nextFocus(current_focus);
  //      }
  //    }
  //    active.sync();
  //    current_focus = *focus;
  //    return requireOneJobFromBucket(current_focus);
  //  }
  __forceinline__ __device__ sampleJob<T> requireOneJob() {
    int current_focus = *focus;

    if (!checkFocus(current_focus)) {
      nextFocus(current_focus);
    }

    current_focus = *focus;
    return requireOneJobFromBucket(current_focus);
  }
};

template <typename T, uint depth = 3>
struct SampleFrontier {
  sampleJob<T> *data[depth];
  int capacity[depth];
  int *sizes;
  int *floor;
  int hop_num = depth;
  // T *seed;

  void Allocate(size_t _size, uint *hops, uint num_vtx = 0) {
    capacity[0] = _size;
    // CUDA_RT_CALL(cudaMalloc(&seed, capacity * sizeof(T)));
    uint length = 1;
    for (size_t i = 0; i < depth; i++) {
      // capacity[0] *= hops[i];
      CUDA_RT_CALL(cudaMalloc(&data[i], capacity[i] * sizeof(sampleJob<T>)));
      if (i + 1 < depth) capacity[i + 1] = capacity[i] * hops[i + 1];
    }
    CUDA_RT_CALL(cudaMalloc(&sizes, depth * sizeof(int)));
    CUDA_RT_CALL(cudaMalloc(&floor, depth * sizeof(int)));
    // printf("%s:%d %s for %d\n", __FILE__, __LINE__, __FUNCTION__, 0);
  }
  __host__ void Init(uint *seed, uint size, uint vtx_per_bucket = 0) {
    InitSampleFrontier<T><<<size / 1024 + 1, 1024>>>(data[0], seed, size);
    int tmp = size;
    CUDA_RT_CALL(cudaMemset(sizes, 0, depth * sizeof(int)));
    CUDA_RT_CALL(cudaMemset(floor, 0, depth * sizeof(int)));
    CUDA_RT_CALL(
        cudaMemcpy(&sizes[0], &tmp, sizeof(int), cudaMemcpyHostToDevice));
  }
  // __device__ void CheckActive(uint itr) {}
  __device__ void Add(uint instance_idx, uint offset, uint itr, T src_id) {
    size_t old = atomicAdd(&sizes[itr], 1);
    assert(old < capacity[itr]);
    sampleJob<T> tmp = {instance_idx, offset, src_id, 0, true};
    data[itr][old] = tmp;
  }
  // __device__ void Reset(uint itr) { size[itr % 3] = 0; }
  __device__ int Size(uint itr) { return sizes[itr]; }
  __device__ sampleJob<T> Get(uint itr, uint idx) { return data[itr][idx]; }
  __device__ sampleJob<T> requireOneJob(uint itr) {
    int old = atomicAggInc(&floor[itr]);
    // size_t old = atomicAdd(&floor[itr], 1);
    if (old < sizes[itr]) {
      return data[itr][old];
    } else {
      atomicSub(&floor[itr], 1);
      sampleJob<T> tmp = {0, 0, 0, 0, false};
      return tmp;
    }
  }
};

#endif

template <typename T>
struct Jobs_result<JobType::NS, T> {
  // using task_t = Task<JobType::RW, T>;
  u64 size;
  uint hop_num;
  uint capacity;
  uint *data;
  char *alive;
  uint *length;

  int *job_sizes = nullptr;
  uint device_id;
  uint length_per_sample = 0;
  uint *hops;
  uint *hops_h;
  uint *sample_lengths;  // format ( len(s1), len(s1.h1),....len(s1.hk),
                         // len(s2),... )
  uint size_of_sample_lengths;
  uint *offsets;
  uint *seeds;

#ifdef ADD_FRONTIER
  int *job_sizes_floor = nullptr;
#ifdef LOCALITY
  LocalitySampleFrontier<T> frontier;
#else
  SampleFrontier<T> frontier;
#endif
  // Vector_gmem<sampleJob> *high_degrees;
  // Vector_gmem<sampleJob> *high_degrees_h;
#endif
  __device__ void SetSampleLength(uint sampleIdx, uint itr, size_t idx,
                                  uint v) {
    // if (sampleIdx == 0 && idx ==0)
    // {
    //   printf("itr * offsets[itr] %u\n ", itr * offsets[itr]);
    //   printf("itr * offsets[itr]+ idx %u\n ", itr * offsets[itr] + idx);
    //   printf(
    //       "sampleIdx * size_of_sample_lengths + itr * offsets[itr]+ idx
    //       %u\n", sampleIdx * size_of_sample_lengths + itr * offsets[itr] +
    //       idx);
    //   uint tmp = sampleIdx * size_of_sample_lengths + itr * offsets[itr] +
    //   idx; printf("tmp %u\n ", tmp); printf("sampleIdx %u itr %u idx %u loc
    //   %u \n", sampleIdx, itr, idx, tmp);
    // }
    uint tmp = sampleIdx * size_of_sample_lengths + offsets[itr] + idx;
    sample_lengths[tmp] = v;
  }
  __device__ uint GetSampleLength(uint sampleIdx, uint itr, size_t idx) {
    // printf("size_of_sample_lengths %u\n",size_of_sample_lengths);
    uint tmp = sampleIdx * size_of_sample_lengths + offsets[itr] + idx;
    return sample_lengths[tmp];
  }

  Jobs_result() {}
  void Free() {
    if (alive != nullptr) CUDA_RT_CALL(cudaFree(alive));
    if (length != nullptr) CUDA_RT_CALL(cudaFree(length));
    if (data != nullptr) CUDA_RT_CALL(cudaFree(data));
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
#ifdef ADD_FRONTIER
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));
      // for (size_t i = 0; i < hop_num; i++) {
      //   high_degrees_h[i].Free();
      // }
      // if (high_degrees != nullptr) CUDA_RT_CALL(cudaFree(high_degrees));
#endif
  }
  void init(uint _size, uint _hop_num, uint *_hops, uint *_seeds,
            uint _device_id = 0, uint num_vtx = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    size = _size;
    // paster(_hop_num);
    hop_num = _hop_num;
    hops_h = new uint[hop_num];
    memcpy(hops_h, _hops, hop_num * sizeof(uint));
    CUDA_RT_CALL(cudaMalloc(&hops, hop_num * sizeof(uint)));
    CUDA_RT_CALL(
        cudaMemcpy(hops, _hops, hop_num * sizeof(uint), cudaMemcpyDefault));
    uint *offsets_h = new uint[hop_num];

    uint tmp = 1;
    for (size_t i = 0; i < hop_num; i++) {
      tmp *= _hops[i];
      offsets_h[i] = length_per_sample;
      length_per_sample += tmp;
    }
    tmp = 1;
    for (size_t i = 1; i < hop_num - 1; i++) {
      tmp += _hops[i];
    }
    size_of_sample_lengths = tmp;
    // paster(length_per_sample);
    // paster(size_of_sample_lengths);
    // printf("hops ");
    // for (size_t i = 0; i < hop_num; i++) {
    //   printf("%d\t", _hops[i]);
    // }
    // printf("hop_num ");
    // printf("offsets ");
    // for (size_t i = 0; i < hop_num; i++) {
    //   printf("%d\t", offsets_h[i]);
    // }
    // for (size_t itr = 0; itr < 3; itr++)
    // for (size_t sampleIdx = 0; sampleIdx < 3; sampleIdx++) {
    //   int itr = 1, idx = 0;
    //   printf("offsets[itr] %u\n ", offsets_h[itr]);
    //   printf("offsets[itr]+ idx %u\n ", offsets_h[itr] + idx);
    //   printf("sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx
    //   %u\n",
    //          sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx);
    //   uint tmp = sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx;
    //   // printf("tmp %u\n ", tmp);
    //   printf("sampleIdx %u itr %u idx %u loc %u \n", sampleIdx, itr, idx,
    //   tmp);
    // }
    printf("\n ");
    CUDA_RT_CALL(cudaMalloc(&offsets, hop_num * sizeof(uint)));
    CUDA_RT_CALL(cudaMemcpy(offsets, offsets_h, hop_num * sizeof(uint),
                            cudaMemcpyHostToDevice));
    CUDA_RT_CALL(cudaMalloc(&sample_lengths,
                            size * size_of_sample_lengths * sizeof(uint)));
    CUDA_RT_CALL(cudaMemset(sample_lengths, 0,
                            size * size_of_sample_lengths * sizeof(uint)));

    if (size * hop_num > 400000000) FLAGS_umresult = true;
    if (!FLAGS_umresult) {
      CUDA_RT_CALL(cudaMalloc(&data, size * length_per_sample * sizeof(uint)));
    } else {
      CUDA_RT_CALL(
          cudaMallocManaged(&data, size * length_per_sample * sizeof(uint)));
      CUDA_RT_CALL(cudaMemAdvise(data, size * length_per_sample * sizeof(uint),
                                 cudaMemAdviseSetAccessedBy, device_id));
    }
    // CUDA_RT_CALL(cudaMalloc(&length, size * sizeof(uint)));

    CUDA_RT_CALL(cudaMalloc(&seeds, size * sizeof(uint)));
    CUDA_RT_CALL(
        cudaMemcpy(seeds, _seeds, size * sizeof(uint), cudaMemcpyHostToDevice));

#ifdef ADD_FRONTIER
    if (!FLAGS_peritr)
    {
      // printf("%s:%d %s for %d\n", __FILE__, __LINE__, __FUNCTION__,0);
      // high_degrees_h = new Vector_gmem<sampleJob>[hop_num];

      // for (size_t i = 0; i < hop_num; i++) {
      //   high_degrees_h[i].Allocate(MAX((size * FLAGS_hd), 4000), device_id);
      // }
      // CUDA_RT_CALL(
      //     cudaMalloc(&high_degrees, hop_num *
      //     sizeof(Vector_gmem<sampleJob>)));
      // CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
      //                         hop_num * sizeof(Vector_gmem<sampleJob>),
      //                         cudaMemcpyHostToDevice));
      CUDA_RT_CALL(cudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(cudaMalloc(&job_sizes, (hop_num) * sizeof(int)));

      // if (/* condition */) 
      {
        frontier.Allocate(size, hops_h, num_vtx);
        frontier.Init(seeds, size);
      }

      // copy seeds
      // if layout1, oor
      // CUDA_RT_CALL(cudaMemcpy(frontier.data, seeds, size * sizeof(uint),
      //                         cudaMemcpyHostToDevice));
      // setFrontierSize<<<1, 32>>>(frontier.size, size);
    }
#endif

    initSeed2<<<size / 1024 + 1, 1024>>>(data, seeds, size, length_per_sample);
    CUDA_RT_CALL(cudaDeviceSynchronize());
    CUDA_RT_CALL(cudaPeekAtLastError());
  }
  __host__ size_t GetSampledNumber(bool new_frontier = false) {
    // if (new_frontier)
    // return get_sum(frontier.sizes, frontier.hop_num); //normal frontier can
    // use this as well?
    // else
    return get_sum(sample_lengths, size * size_of_sample_lengths);
  }
  __device__ void AddActive(uint itr, uint sampleIdx, uint offset,
                            uint local_offset, uint candidate,
                            bool should_add = true) {
    // int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    // *(getNextAddr(current_itr) + old) = candidate;

    uint tmp = offset * hops[itr] + local_offset;
    // if (!sampleIdx && itr == 2 && (offset == 1 || offset == 0))
    //   printf("sampleIdx %u offset %u adding %u to tmp %u \n", sampleIdx,
    //   offset,
    //          candidate, tmp);
    *GetDataPtr(sampleIdx, itr, tmp) = candidate;
    if (should_add) frontier.Add(sampleIdx, tmp, itr, candidate);
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __forceinline__ __device__ sampleJob<T> requireOneJob(uint itr = 0) {
#ifdef LOCALITY
    auto tmp = frontier.requireOneJob();
    return tmp;
#else
    return frontier.requireOneJob(itr);
#endif
  }
  // __device__ void PrintResult() {
  //   if (LTID == 0) {
  //     for (int j = 0; j < MIN(3, size); j++) {
  //       printf("\n%dth sample src: %u, 1-hop len: %u \n", j, GetData(j, 0,
  //       0),
  //              GetSampleLength(j, 0, 0));
  //       for (uint i = 0; i < GetSampleLength(j, 0, 0); i++) {
  //         printf("\t %u th 2-hop: ", i, GetSampleLength(j, 1, i));
  //       }
  //       printf("\n first  2-hop ");
  //       for (size_t i = 0; i < MIN(GetSampleLength(j, 1, 0), 30); i++) {
  //         printf("%u \t", GetData(j, 1, i));
  //       }
  //       printf("\n");
  //     }
  //   }
  // }
  __device__ void PrintResult() {
    if (LTID == 0) {
      for (int j = 0; j < MIN(1, size); j++) {
        // for (size_t i = 0; i < 276; i++)
        // {
        //   printf("\t %u ", data[i]);
        // }
        // printf("\n");
        // for (size_t i = 0; i < 26; i++)
        // {
        //   printf("\t %u ", sample_lengths[i]);
        // }
        // printf("\n");
        printf("\n%dth sample src: %u, 1-hop len: %u \n", j, GetData(j, 0, 0),
               GetSampleLength(j, 0, 0));

        printf("\t 1-hop : ");
        for (uint k = 0; k < MIN(GetSampleLength(j, 0, 0), 30); k++) {
          printf("%u \t", GetData(j, 1, k));
        }
        printf("\n");
        for (uint i = 0; i < GetSampleLength(j, 0, 0); i++) {
          printf("\t %u th 2-hop [%u]: ", i, GetData(j, 1, i));

          for (uint k = 0; k < MIN(GetSampleLength(j, 1, i), 30); k++) {
            printf("%u \t", GetData(j, 2, k + i * hops[2]));
          }
          printf("\n");
        }
      }
    }
  }
  __device__ T *GetDataPtr(uint sampleIdx, uint itr, size_t idx) {
    return data + sampleIdx * length_per_sample + offsets[itr] + idx;
  }
  __device__ T GetData(uint sampleIdx, uint itr, size_t idx) {
    return data[sampleIdx * length_per_sample + offsets[itr] + idx];
  }
  // offsets 0       1       26
  // data layout: v n1 n1*n2 (1 25 250)
  // 原来的data layout有误
  // length_per_sample 276
};

template <typename T>
struct Jobs_result<JobType::RW, T> {
  // using task_t = Task<JobType::RW, T>;
  u64 size;
  uint hop_num;
  uint capacity;
  uint *data;
  char *alive;
  uint *length;
  // uint *frontier;
  Frontier<T> frontier;
  Vector_gmem<uint> *high_degrees;
  int *job_sizes_floor = nullptr;
  int *job_sizes = nullptr;
  uint *data2;
  uint device_id;

  SamplerState<JobType::NODE2VEC, T> *state;
  float p = 2.0, q = 0.5;
  Vector_gmem<uint> *high_degrees_h;

  Jobs_result() {}
  void Free() {
    if (alive != nullptr) CUDA_RT_CALL(cudaFree(alive));
    if (length != nullptr) CUDA_RT_CALL(cudaFree(length));
    if (data != nullptr) CUDA_RT_CALL(cudaFree(data));
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));

    for (size_t i = 0; i < hop_num; i++) {
      high_degrees_h[i].Free();
    }
    if (high_degrees != nullptr) CUDA_RT_CALL(cudaFree(high_degrees));
  }
  void init(uint _size, uint _hop_num, uint *seeds, uint _device_id = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    size = _size;
    hop_num = _hop_num;
    paster(hop_num);
    if (size * hop_num > 400000000) FLAGS_umresult = true;
    if (!FLAGS_umresult) {
      CUDA_RT_CALL(cudaMalloc(&data, size * hop_num * sizeof(uint)));
    } else {
      CUDA_RT_CALL(cudaMallocManaged(&data, size * hop_num * sizeof(uint)));
      CUDA_RT_CALL(cudaMemAdvise(data, size * hop_num * sizeof(uint),
                                 cudaMemAdviseSetAccessedBy, device_id));
    }
    CUDA_RT_CALL(cudaMalloc(&alive, size * sizeof(char)));
    CUDA_RT_CALL(cudaMemset(alive, 1, size * sizeof(char)));
    CUDA_RT_CALL(cudaMalloc(&length, size * sizeof(uint)));
    // CUDA_RT_CALL(cudaMemset(length, 0, size * sizeof(uint)));

    if (FLAGS_node2vec) {
      CUDA_RT_CALL(cudaMalloc(
          &state, size * sizeof(SamplerState<JobType::NODE2VEC, T>)));
      p = FLAGS_p;
      q = FLAGS_q;
    }

    {
      if (!FLAGS_umresult) {
        CUDA_RT_CALL(cudaMalloc(&data2, size * hop_num * sizeof(uint)));
      } else {
        CUDA_RT_CALL(cudaMallocManaged(&data2, size * hop_num * sizeof(uint)));
        CUDA_RT_CALL(cudaMemAdvise(data2, size * hop_num * sizeof(uint),
                                   cudaMemAdviseSetAccessedBy, device_id));
      }

      init_range(data2, size);
      // CUDA_RT_CALL(cudaMemcpy(data2, seeds, size * sizeof(uint),
      //                  cudaMemcpyHostToDevice));

      high_degrees_h = new Vector_gmem<uint>[hop_num];

      for (size_t i = 0; i < hop_num; i++) {
        high_degrees_h[i].Allocate(MAX((size * FLAGS_hd), 4000), device_id);
      }
      CUDA_RT_CALL(
          cudaMalloc(&high_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(cudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(cudaMalloc(&job_sizes, (hop_num) * sizeof(int)));
    }

    if (FLAGS_peritr) {
      frontier.Allocate(size);
      // copy seeds
      // if layout1, oor
      CUDA_RT_CALL(cudaMemcpy(frontier.data, seeds, size * sizeof(uint),
                              cudaMemcpyHostToDevice));
      setFrontierSize<<<1, 32>>>(frontier.size, size);
    }
    // uint *seeds_g;
    // CUDA_RT_CALL(cudaMalloc(&seeds_g, size * sizeof(uint)));
    // CUDA_RT_CALL(cudaMemcpy(seeds_g, seeds, size * sizeof(uint),
    //                  cudaMemcpyHostToDevice));
    // initSeed3<<<size / 1024 + 1, 1024>>>(data, seeds_g, size, hop_num);

    if (true)
      initSeed2<<<size / 1024 + 1, 1024>>>(data, seeds, size, hop_num);
    else
      CUDA_RT_CALL(
          cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice));
    CUDA_RT_CALL(cudaDeviceSynchronize());
    CUDA_RT_CALL(cudaPeekAtLastError());
  }
  __device__ void AddHighDegree(uint current_itr, uint instance_idx) {
    // printf("AddHighDegree %u %u \n",current_itr,instance_idx);
    high_degrees[current_itr].Add(instance_idx);
  }
  __host__ size_t GetSampledNumber() {
    // paster((get_sum(length, size)));
    // paster((get_sum(job_sizes, hop_num)));
    return get_sum(length, size);
  }
  __device__ void setAddrOffset() {
    // printf("%s:%d %s\n", __FILE__, __LINE__, __FUNCTION__);
    // paster(size);
    job_sizes[0] = size;
    // uint64_t offset = 0;
    // uint64_t cum = size;
    // hops_acc[0]=1;
    for (size_t i = 0; i < hop_num; i++) {
      // if (i!=0) hops_acc[i]
      // addr_offset[i] = offset;
      // cum *= hops[i];
      // offset += cum;
      job_sizes_floor[i] = 0;
    }
  }

  __device__ void PrintResult() {
    if (LTID == 0) {
      // printf("seeds \n");
      // for (size_t i = 0; i < MIN(3, size); i++) {
      //   printf("%u \t", GetData(0, i));
      // }
      for (int j = 0; j < MIN(3, size); j++) {
        printf("\n%drd path len %u \n", j, length[j]);
        for (size_t i = 0; i < MIN(length[j], hop_num); i++) {
          printf("%u \t", GetData(i, j));
        }
        printf("\n");
      }
    }
  }
  __device__ T *GetDataPtr(uint itr, size_t idx) {
    return data + itr + idx * hop_num;
  }
  __device__ T GetData(uint itr, size_t idx) {
    return data[itr + idx * hop_num];
  }
  // __device__ T *GetDataPtr(uint itr, size_t idx) {
  //   return data + itr * size + idx;
  // }
  // __device__ T GetData(uint itr, size_t idx) {
  //   return data[itr * size + idx];
  // }
  __device__ uint getNodeId(uint idx, uint hop) {
    // paster(addr_offset[hop]);
    return data[hop * size + idx];
  }
  __device__ uint getNodeId2(uint idx, uint hop) {
    // paster(addr_offset[hop]);
    return data2[hop * size + idx];
  }

  //   struct sample_job_new {
  //   uint idx_in_frontier;
  //   uint instance_idx;
  //   bool val;  //= false
  // };
  __device__ struct sample_job_new requireOneHighDegreeJob(uint current_itr) {
    sample_job_new job;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      job.instance_idx = high_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
    }
    return job;
  }
  __device__ struct sample_job_new requireOneJob(uint current_itr)  // uint hop
  {
    sample_job_new job;
    job.val = false;
    // printf("requireOneJob for itr %u\n", current_itr);
    // paster(job_sizes[current_itr]);
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr]) {
      // printf("poping wl ele idx %d\n", old);
      job.idx_in_frontier = (uint)old;
      job.instance_idx = getNodeId2(old, current_itr);
      job.val = true;
      // printf("poping wl ele node_id %d\n", job.node_id);
    } else {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
    }
    return job;
  }
  __device__ void AddActive(uint current_itr, uint candidate) {
    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    *(getNextAddr(current_itr) + old) = candidate;
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __device__ void NextItr(uint &current_itr) {
    current_itr++;
    // printf("start itr %d at block %d \n", current_itr, blockIdx.x);
  }
  __device__ uint *getNextAddr(uint hop) {
    // uint offset =  ;// + hops[hop] * idx;
    return &data2[(hop + 1) * size];
  }
};

struct sample_result {
  uint size;
  uint hop_num;
  uint *hops = nullptr;
  uint *hops_h;
  // uint *hops_acc;
  uint *addr_offset = nullptr;
  uint *data = nullptr;
  int *job_sizes = nullptr;
  int *job_sizes_h = nullptr;
  int *job_sizes_floor = nullptr;
  uint capacity;
  uint device_id;
  uint *seeds;

  Vector_gmem<uint> *high_degrees;
  Vector_gmem<uint> *mid_degrees;

  // uint current_itr = 0;
  sample_result() {}
  // void Free()
  // void AssemblyFeature(float * ptr, float * feat, ){

  // }
  __device__ int GetJobSize(uint itr) { return job_sizes[itr]; }
  void Free() {
    if (hops != nullptr) CUDA_RT_CALL(cudaFree(hops));
    if (addr_offset != nullptr) CUDA_RT_CALL(cudaFree(addr_offset));
    if (data != nullptr) {
      CUDA_RT_CALL(cudaFree(data));
      data = nullptr;
    }
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));
    if (job_sizes_h != nullptr) delete[] job_sizes_h;
  }
  void init(uint _size, uint _hop_num, uint *_hops, uint *_seeds,
            uint _device_id = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    Free();
    size = _size;
    hop_num = _hop_num;
    seeds = _seeds;
    hops_h = _hops;
    CUDA_RT_CALL(cudaMalloc(&hops, hop_num * sizeof(uint)));
    CUDA_RT_CALL(cudaMemcpy(hops, _hops, hop_num * sizeof(uint),
                            cudaMemcpyHostToDevice));
    CUDA_RT_CALL(cudaMalloc(&addr_offset, hop_num * sizeof(uint)));
    Vector_gmem<uint> *high_degrees_h = new Vector_gmem<uint>[hop_num];
    Vector_gmem<uint> *mid_degrees_h = new Vector_gmem<uint>[hop_num];
    // for (size_t i = 0; i < hop_num; i++) {
    // }
    uint64_t offset = 0;
    uint64_t cum = size;
    for (size_t i = 0; i < hop_num; i++) {
      cum *= _hops[i];
      if (FLAGS_bias && !FLAGS_built) {
        high_degrees_h[i].Allocate(MAX((cum * FLAGS_hd), 4000), device_id);
        mid_degrees_h[i].Allocate(MAX((cum * FLAGS_hd), 4000), device_id);
      }
      offset += cum;
    }
    capacity = offset;
    if (!FLAGS_built) {
      CUDA_RT_CALL(
          cudaMalloc(&high_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(
          cudaMalloc(&mid_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(mid_degrees, mid_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(cudaMalloc(&data, capacity * sizeof(uint)));
      CUDA_RT_CALL(
          cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice));
      job_sizes_h = new int[hop_num];
      job_sizes_h[0] = size;
      CUDA_RT_CALL(cudaMalloc(&job_sizes, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(cudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
    }
  }
  __host__ size_t GetSampledNumber() { return get_sum(job_sizes, hop_num); }
  __device__ void PrintResult() {
    if (LTID == 0) {
      printf("job_sizes \n");
      printD(job_sizes, hop_num);
      uint total = 0;
      for (size_t i = 0; i < hop_num; i++) {
        total += job_sizes[i];
      }
      printf("total sampled %u \n", total);
      // printf("job_sizes_floor \n");
      // printD(job_sizes_floor, hop_num);
      // printf("result: \n");
      // printD(data, MIN(capacity, 30));
    }
  }
  __device__ void setAddrOffset() {
    job_sizes[0] = size;
    uint64_t offset = 0;
    uint64_t cum = size;
    // hops_acc[0]=1;
    for (size_t i = 0; i < hop_num; i++) {
      // if (i!=0) hops_acc[i]
      addr_offset[i] = offset;
      cum *= hops[i];
      offset += cum;
      job_sizes_floor[i] = 0;
    }
  }
  __device__ uint *getNextAddr(uint hop) { return &data[addr_offset[hop + 1]]; }
  __device__ uint getNodeId(uint idx, uint hop) {
    return data[addr_offset[hop] + idx];
  }
  __device__ uint *getAddrOfInstance(uint idx, uint hop) {
    return data + addr_offset[hop] + idx * hops[hop];
  }
  __device__ uint getDataOfInstance(uint idx, uint hop, uint offset) {
    return data[addr_offset[hop] + idx * hops[hop] + offset];
  }
  __device__ uint getHopSize(uint hop) { return hops[hop]; }
  __device__ uint getFrontierSize(uint hop) {
    uint64_t cum = size;
    for (size_t i = 0; i < hop; i++) {
      cum *= hops[i];
    }
    return cum;
  }
  __device__ void AddHighDegree(uint current_itr, uint node_id) {
    high_degrees[current_itr].Add(node_id);
  }
  __device__ void AddMidDegree(uint current_itr, uint node_id) {
    mid_degrees[current_itr].Add(node_id);
  }
  __device__ struct sample_job requireOneHighDegreeJob(uint current_itr) {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      job.node_id = high_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
      // job.val = false;
    }
    return job;
  }
  __device__ struct sample_job requireOneMidDegreeJob(uint current_itr) {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(mid_degrees[current_itr].floor, 1);
    if (old < mid_degrees[current_itr].Size()) {
      job.node_id = mid_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(mid_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(mid_degrees[current_itr].floor, 1);
      // job.val = false;
    }
    return job;
  }
  __device__ struct sample_job requireOneJob(uint current_itr)  // uint hop
  {
    sample_job job;
    job.val = false;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr]) {
      job.idx = (uint)old;
      job.node_id = getNodeId(old, current_itr);
      job.val = true;
      // printf("send one job %d in itr %u\n", job.node_id, current_itr);
    } else {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
    }
    return job;
  }
  __device__ bool checkFinish(uint current_itr) {
    if (job_sizes_floor[current_itr] < job_sizes[current_itr] ||
        *high_degrees[current_itr].floor < high_degrees[current_itr].Size())
      return false;
    return true;
  }
  __device__ void AddActive(uint current_itr, uint candidate) {
    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    *(getNextAddr(current_itr) + old) = candidate;
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __device__ void NextItr(uint &current_itr) { current_itr++; }
};
