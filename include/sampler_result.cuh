#pragma once
struct sample_job
{
  uint idx;
  uint node_id;
  bool val = false;
};

struct sample_result
{
  uint size;
  uint hop_num;
  uint *hops;
  // uint *hops_acc;
  uint *addr_offset;
  uint *data;
  int *job_sizes;
  int *job_sizes_h;
  int *job_sizes_floor;
  uint capacity;
  // uint current_itr = 0;
  sample_result() {}
  void init(uint _size, uint _hop_num,
            uint *_hops, uint *seeds)
  {
    // printf("%s\t %s :%d\n", __FILE__, __PRETTY_FUNCTION__, __LINE__);
    size = _size;
    hop_num = _hop_num;
    cudaMalloc(&hops, hop_num * sizeof(uint));
    cudaMemcpy(hops, _hops, hop_num * sizeof(uint), cudaMemcpyHostToDevice);

    cudaMalloc(&addr_offset, hop_num * sizeof(uint));
    // cudaMalloc(&hops_acc, hop_num * sizeof(uint));

    // capacity = size;
    // for (size_t i = 0; i < _hop_num; i++)
    // {
    //   capacity *= _hops[i];
    // }

    uint64_t offset = 0;
    uint64_t cum = size;
    for (size_t i = 0; i < hop_num; i++)
    {
      cum *= _hops[i];
      offset += cum;
    }
    capacity=offset;

    paster(capacity);
    cudaMalloc(&data, capacity * sizeof(uint));
    cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice);

    job_sizes_h = new int[hop_num];
    job_sizes_h[0] = size;
    // for (size_t i = 1; i < hop_num; i++)
    // {
    //   job_sizes_h[i] = job_sizes_h[i - 1] * _hops[i];
    // }
    cudaMalloc(&job_sizes, (hop_num) * sizeof(int));
    cudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int));
    // cudaMemcpy(job_sizes, _hops, hop_num * sizeof(int), cudaMemcpyHostToDevice);
  }
  __device__ void setAddrOffset()
  {
    job_sizes[0] = size;
    uint64_t offset = 0;
    uint64_t cum = size;
    // hops_acc[0]=1;
    for (size_t i = 0; i < hop_num; i++)
    {
      // if (i!=0) hops_acc[i]
      addr_offset[i] = offset;
      cum *= hops[i];
      offset += cum;
      job_sizes_floor[i] = 0;
    }
  }
  __device__ uint *getNextAddr(uint hop)
  {
    // uint offset =  ;// + hops[hop] * idx;
    return &data[addr_offset[hop+1]];
  }
  __device__ uint getNodeId(uint idx, uint hop)
  {
    // paster(addr_offset[hop]);
    return data[addr_offset[hop] + idx];
  }
  __device__ uint getHopSize(uint hop)
  {
    return hops[hop];
  }
  __device__ uint getFrontierSize(uint hop)
  {
    uint64_t cum = size;
    for (size_t i = 0; i < hop; i++)
    {
      cum *= hops[i];
    }
    return cum;
  }
  __device__ struct sample_job requireOneJob(uint current_itr) //uint hop
  {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr])
    {
      // printf("poping wl ele idx %d\n", old);
      job.idx = (uint)old;
      job.node_id = getNodeId(old, current_itr);
      job.val = true;
    }
    else
    {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
      // job.val = false;
    }
    return job;
  }
  __device__ void AddActive(uint current_itr, uint *array, uint candidate)
  {

    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    array[old] = candidate;
    // printf("Add new ele %u to %d\n", candidate, old);
  }
  __device__ void NextItr(uint &current_itr)
  {
    current_itr++;
    // printf("start itr %d at block %d \n", current_itr, blockIdx.x);
  }
};

// __device__ uint *getAddr(uint idx, uint hop)
//   {
//     // uint64_t offset = 0;
//     // uint64_t cum = size;
//     // for (size_t i = 0; i < hop; i++)
//     // {
//     //   cum *= hops[i];
//     //   offset += cum;
//     // }
//     uint offset = addr_offset[hop] ;// + hops[hop] * idx;
//     return &data[offset];
//   }