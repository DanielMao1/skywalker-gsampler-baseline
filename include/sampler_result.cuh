#pragma once
#include "gflags/gflags.h"
#include "vec.cuh"
DECLARE_int32(hd);

struct sample_job {
  uint idx;
  uint node_id;
  bool val = false;
};

struct id_pair {
  uint idx, node_id;
  __device__ id_pair &operator=(uint idx) {
    idx = 0;
    node_id = 0;
    return *this;
  }
};

enum class JobType {
  NS, // neighbour sampling
  LS, // layer sampling
  RW, // random walk
};

template <JobType job, typename T> struct Result;

template <typename T> struct Result<JobType::RW, T> {
  T *data;
  uint depth = 0;
  bool alive = true;
  void Allocate(uint size) { H_ERR(cudaMalloc(&data, size * sizeof(T))); }
  // void Allocate(uint _hop_num, uint *_hops) {
  // }
};

// task{job_id, local_idx}, to find Result
// template <JobType job, typename T> struct Task;

// template <typename T> struct Task<JobType::RW, T> {
//   T job_idx;
//   uint depth;
//   // static __device__ Task<JobType::RW, T> &Create(uint idx, uint _depth) {
//   //   job_idx = idx;
//   //   depth = _depth;
//   //   return *this;
//   // }
//   __device__ Task<JobType::RW, T> &operator=(uint idx) {
//     job_idx = idx;
//     depth = 0;
//     return *this;
//   }
// };

// template <JobType job, typename T> struct Job;

// template <typename T> struct Job<JobType::RW, T> {
//   // uint idx;
//   // uint node_id;
//   struct Task<JobType::RW, T> task;
//   bool val = false;
// };

template <typename Result>
__global__ void initSeed(Result *results, uint *seeds, size_t size) {
  if (TID < size) {
    results[TID].data[0] = seeds[TID];
  }
}
template __global__ void
initSeed<Result<JobType::RW, uint>>(Result<JobType::RW, uint> *jobs,
                                    uint *seeds, size_t size);

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

template <JobType job, typename T> struct Jobs_result;

template <typename T> struct Jobs_result<JobType::RW, T> {
  // using task_t = Task<JobType::RW, T>;
  u64 size;
  uint hop_num;
  uint capacity;
  uint *data;
  char *alive;

  Jobs_result() {}

  void init(uint _size, uint _hop_num, uint *seeds) {
    size = _size;
    hop_num = _hop_num;
    cudaMalloc(&data, size * hop_num * sizeof(uint));
    cudaMalloc(&alive, size * sizeof(char));
    cudaMemset(alive, 1, size * sizeof(char));

    // copy seeds
    // if layout1, oor
    // cudaMemcpy(data, seeds, size * hop_num * sizeof(uint),
    //            cudaMemcpyHostToDevice);

    uint *seeds_g;
    cudaMalloc(&seeds_g, size * sizeof(uint));
    cudaMemcpy(seeds_g, seeds, size * sizeof(uint), cudaMemcpyHostToDevice);
    // layout 2
    // initSeed<JobType::RW><<<size / 1024 + 1, 1024>>>(results, seeds, size);
    // initSeed2<<<size / 1024 + 1, 1024>>>(data, seeds_g, size, hop_num);
    // layout 3
    initSeed3<<<size / 1024 + 1, 1024>>>(data, seeds_g, size, hop_num);
  }
  __device__ void PrintResult() {
    if (LTID == 0) {
      printf("seeds \n");
      for (size_t i = 0; i < 10; i++) {
        printf("%u \t", GetData(0, i));
      }
      printf("\nfirst path \n");
      for (size_t i = 0; i < hop_num; i++) {
        printf("%u \t", GetData(i, 0));
      }
      printf("\n");
    }
  }
  __device__ T *GetDataPtr(size_t itr, size_t idx) {
    return data + itr * size + idx;
  }
  __device__ T GetData(size_t itr, size_t idx) {
    return data[itr * size + idx];
  }
};

struct sample_result {
  uint size;
  uint hop_num;
  uint *hops = nullptr;
  // uint *hops_acc;
  uint *addr_offset = nullptr;
  uint *data = nullptr;
  int *job_sizes = nullptr;
  int *job_sizes_h = nullptr;
  int *job_sizes_floor = nullptr;
  uint capacity;

  Vector_gmem<uint> *high_degrees;

  // uint current_itr = 0;
  sample_result() {}
  // void Free()
  void Free() {
    if (hops != nullptr)
      H_ERR(cudaFree(hops));
    if (addr_offset != nullptr)
      H_ERR(cudaFree(addr_offset));
    if (data != nullptr)
      H_ERR(cudaFree(data));
    if (job_sizes != nullptr)
      H_ERR(cudaFree(job_sizes));
    if (job_sizes_floor != nullptr)
      H_ERR(cudaFree(job_sizes_floor));
    if (job_sizes_h != nullptr)
      delete[] job_sizes_h;
  }
  void init(uint _size, uint _hop_num, uint *_hops, uint *seeds) {
    Free();
    size = _size;
    hop_num = _hop_num;
    // paster(hop_num);
    cudaMalloc(&hops, hop_num * sizeof(uint));
    cudaMemcpy(hops, _hops, hop_num * sizeof(uint), cudaMemcpyHostToDevice);
    cudaMalloc(&addr_offset, hop_num * sizeof(uint));
    Vector_gmem<uint> *high_degrees_h = new Vector_gmem<uint>[hop_num];
    // for (size_t i = 0; i < hop_num; i++) {

    // }
    uint64_t offset = 0;
    uint64_t cum = size;
    for (size_t i = 0; i < hop_num; i++) {
      cum *= _hops[i];
      high_degrees_h[i].Allocate(MAX((cum / FLAGS_hd), 4000));
      offset += cum;
    }
    capacity = offset;
    cudaMalloc(&high_degrees, hop_num * sizeof(Vector_gmem<uint>));
    cudaMemcpy(high_degrees, high_degrees_h,
               hop_num * sizeof(Vector_gmem<uint>), cudaMemcpyHostToDevice);

    // paster(capacity);
    cudaMalloc(&data, capacity * sizeof(uint));
    cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice);

    job_sizes_h = new int[hop_num];
    job_sizes_h[0] = size;
    cudaMalloc(&job_sizes, (hop_num) * sizeof(int));
    cudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int));
  }
  __device__ void PrintResult() {
    if (LTID == 0) {
      printf("job_sizes \n");
      printD(job_sizes, hop_num);
      uint total = 0;
      for (size_t i = 0; i < hop_num; i++) {
        total += job_sizes[total];
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
  __device__ uint *getNextAddr(uint hop) {
    // uint offset =  ;// + hops[hop] * idx;
    return &data[addr_offset[hop + 1]];
  }
  __device__ uint getNodeId(uint idx, uint hop) {
    // paster(addr_offset[hop]);
    return data[addr_offset[hop] + idx];
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
    // printf("AddHighDegree size %llu floor  %llu\n",
    // high_degrees[current_itr].Size(),*high_degrees[current_itr].floor);
  }
  __device__ struct sample_job requireOneHighDegreeJob(uint current_itr) {
    // if (LID == 0)
    // printf("----%s %d\n", __FUNCTION__, __LINE__);
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      // printf("poping wl ele idx %d\n", old);
      // job.idx = (uint)0;
      job.node_id = high_degrees[current_itr].Get(old);
      job.val = true;
      // printf("poping high degree node_id %d\n", job.node_id);
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // job.val = false;
    }
    return job;
  }
  __device__ struct sample_job requireOneJob(uint current_itr) // uint hop
  {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr]) {
      // printf("poping wl ele idx %d\n", old);
      job.idx = (uint)old;
      job.node_id = getNodeId(old, current_itr);
      job.val = true;
      // printf("poping wl ele node_id %d\n", job.node_id);
    } else {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
      // printf("no job \n");
      // job.val = false;
    }
    return job;
  }
  __device__ void AddActive(uint current_itr, uint *array, uint candidate) {

    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    array[old] = candidate;
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __device__ void NextItr(uint &current_itr) {
    current_itr++;
    // printf("start itr %d at block %d \n", current_itr, blockIdx.x);
  }
};
