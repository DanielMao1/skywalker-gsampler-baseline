#include "app.cuh"

template <>
__device__ bool
alias_table_constructor_shmem<uint, thread_block_tile<32>, BufferType::SHMEM>::
    roll_once<Jobs_result<JobType::NS, uint>>(
        uint *local_size, curandState *local_state, size_t target_size,
        Jobs_result<JobType::NS, uint> result, uint instance_id, uint offset,
        uint local_offset) {
  int col = (int)floor(curand_uniform(local_state) * buffer.size);
  float p = curand_uniform(local_state);
  uint candidate;
  if (p < buffer.prob[col])
    candidate = col;
  else
    candidate = buffer.alias[col];
  unsigned short int updated =
      atomicCAS(&buffer.selected[candidate], (unsigned short int)0,
                (unsigned short int)1);
  if (!updated) {
    auto active = coalesced_threads();
    // if (AddTillSize(local_size, target_size))
    if (*local_size + active.thread_rank() < target_size) {
      result.AddActive(buffer.current_itr + 1, instance_id, offset,
                       *local_size + active.thread_rank(),
                       buffer.ggraph->getOutNode(buffer.src_id, candidate),
                       (buffer.current_itr + 2) != result.hop_num);
    }
    if (active.thread_rank() == 0) *local_size += active.size();

    return true;
  } else
    return false;
}
template <>
__device__ bool
alias_table_constructor_shmem<uint, thread_block, BufferType::GMEM>::roll_once<
    Jobs_result<JobType::NS, uint>>(uint *local_size, curandState *local_state,
                                    size_t target_size,
                                    Jobs_result<JobType::NS, uint> result,
                                    uint instance_id, uint offset,
                                    uint local_offset) {
  int col = (int)floor(curand_uniform(local_state) * buffer.size);
  float p = curand_uniform(local_state);
  uint candidate;
  if (p < buffer.prob[col])
    candidate = col;
  else
    candidate = buffer.alias[col];
  unsigned short int updated =
      atomicCAS(&buffer.selected[candidate], (unsigned short int)0,
                (unsigned short int)1);
  if (!updated) {
    auto active = coalesced_threads();
    // if (AddTillSize(local_size, target_size))
    if (*local_size + active.thread_rank() < target_size) {
      result.AddActive(buffer.current_itr + 1, instance_id, offset,
                       *local_size + active.thread_rank(),
                       buffer.ggraph->getOutNode(buffer.src_id, candidate),
                       (buffer.current_itr + 2) != result.hop_num);
      // if (!instance_id)  // offset == 1 || && itr == 1 && (offset == 0)
      //   printf(
      //       " itr %u instance_id %u offset %u local_offset %u adding %u\n",
      //       buffer.current_itr + 1, instance_id, offset, *local_size +
      //       active.thread_rank(), buffer.ggraph->getOutNode(buffer.src_id,
      //       candidate));
    }
    if (active.thread_rank() == 0) *local_size += active.size();
    // if (AddTillSize(local_size, target_size)) {
    //   result.AddActive(buffer.current_itr + 1, instance_id, offset,
    //                    local_offset,
    //                    buffer.ggraph->getOutNode(buffer.src_id, candidate),
    //                    (buffer.current_itr + 2) != result.hop_num);
    //   // if (!instance_id && offset == 1)
    //   //   printf("offset %u local_offset %u   should %d\n", offset,
    //   //   local_offset, buffer.ggraph->getOutNode(buffer.src_id,
    //   local_offset),
    //   //   (buffer.current_itr + 2) != result.hop_num);
    // }
    return true;
  } else
    return false;
}
template <>
__device__ void
alias_table_constructor_shmem<uint, thread_block_tile<32>, BufferType::SHMEM>::
    roll_atomic<Jobs_result<JobType::NS, uint>>(
        curandState *state, Jobs_result<JobType::NS, uint> result,
        uint instance_id, uint offset) {
  uint target_size = result.hops[buffer.current_itr + 1];
  // (target_size > 0) &&
  if (target_size < buffer.ggraph->getDegree(buffer.src_id)) {
    int itr = 0;
    __shared__ uint sizes[WARP_PER_BLK];
    uint *local_size = sizes + WID;
    if (LID == 0) *local_size = 0;
    MySync();
    while (*local_size < target_size) {
      roll_once(local_size, state, target_size, result, instance_id, offset, 0);
      itr++;
      if (itr > 10) {
        break;
      }
      __syncwarp();
    }
    MySync();
  } else if (target_size >= buffer.ggraph->getDegree(buffer.src_id)) {
    target_size = buffer.ggraph->getDegree(buffer.src_id);
    for (size_t i = LID; i < target_size; i += 32) {
      result.AddActive(buffer.current_itr + 1, instance_id, offset, i,
                       buffer.ggraph->getOutNode(buffer.src_id, i));
    }
  }
  if (LID == 0)
    result.SetSampleLength(instance_id, buffer.current_itr, offset,
                           target_size);
}

template <>
__device__ void
alias_table_constructor_shmem<uint, thread_block, BufferType::GMEM>::
    roll_atomic<Jobs_result<JobType::NS, uint>>(
        int target_size, curandState *state,
        Jobs_result<JobType::NS, uint> result, uint instance_id, uint offset,
        uint local_offset) {
  __shared__ uint size;
  if (WID == 0) {
    buffer.selected.CleanDataWC();
    int itr = 0;
    // uint *local_size = &sizes[0];
    if (LID == 0) size = 0;
    MySync();
    while (size < target_size) {
      roll_once(&size, state, target_size, result, instance_id, offset, 0);
      itr++;
      if (itr > 10) {
        break;
      }
      __syncwarp();
    }
    if (LID == 0)
      result.SetSampleLength(instance_id, buffer.current_itr, offset, size);
  }
  __syncthreads();
}

static __device__ void SampleWarpCentic(Jobs_result<JobType::NS, uint> &result,
                                        gpu_graph *ggraph, curandState state,
                                        int current_itr, int instance_idx,
                                        int src_id, void *buffer, uint offset) {
  alias_table_constructor_shmem<uint, thread_block_tile<32>> *tables =
      (alias_table_constructor_shmem<uint, thread_block_tile<32>> *)buffer;
  alias_table_constructor_shmem<uint, thread_block_tile<32>> *table =
      &tables[WID];
  bool not_all_zero =
      table->loadFromGraph(ggraph->getNeighborPtr(src_id), ggraph,
                           ggraph->getDegree(src_id), current_itr, src_id);
  // if(!LID) printf("buffer.current_itr %u\n", table->buffer.current_itr);
  if (not_all_zero) {
    table->construct();
    table->roll_atomic(&state, result, instance_idx, offset);
  }
  table->Clean();
}

static __device__ void SampleBlockCentic(Jobs_result<JobType::NS, uint> &result,
                                         gpu_graph *ggraph, curandState state,
                                         int current_itr, int src_id,
                                         void *buffer,
                                         Vector_pack<uint> *vector_packs,
                                         uint instance_idx, uint offset) {
  alias_table_constructor_shmem<uint, thread_block, BufferType::GMEM> *tables =
      (alias_table_constructor_shmem<uint, thread_block, BufferType::GMEM> *)
          buffer;
  alias_table_constructor_shmem<uint, thread_block, BufferType::GMEM> *table =
      &tables[0];
  table->loadGlobalBuffer(vector_packs);
  // if(LTID)
  // printf("vector_packs->selected.size %u\n",vector_packs->selected.size );
  __syncthreads();
  bool not_all_zero =
      table->loadFromGraph(ggraph->getNeighborPtr(src_id), ggraph,
                           ggraph->getDegree(src_id), current_itr, src_id);
  __syncthreads();
  if (not_all_zero) {
    table->constructBC();
    uint target_size =
        MIN(ggraph->getDegree(src_id), result.hops[current_itr + 1]);
    table->roll_atomic(target_size, &state, result, instance_idx, offset);
  }
  __syncthreads();
  table->Clean();
}

__global__ void sample_kernel(Sampler_new *sampler,
                              Vector_pack<uint> *vector_pack) {
  Jobs_result<JobType::NS, uint> &result = sampler->result;
  gpu_graph *ggraph = &sampler->ggraph;
  Vector_pack<uint> *vector_packs = &vector_pack[BID];
  __shared__ alias_table_constructor_shmem<uint, thread_block_tile<32>>
      table[WARP_PER_BLK];
  void *buffer = &table[0];
  curandState state;
  curand_init(TID, 0, 0, &state);

  __shared__ uint current_itr;
  if (threadIdx.x == 0) current_itr = 0;
  __syncthreads();
  for (; current_itr < result.hop_num - 1;)  // for 2-hop, hop_num=3
  {
    // Vector_gmem<uint> *high_degrees =
    //     &sampler->result.high_degrees[current_itr];
    sampleJob<uint> job;
    __threadfence_block();
    if (LID == 0) job = result.requireOneJob(current_itr);
    __syncwarp(FULL_WARP_MASK);
    job.instance_idx = __shfl_sync(FULL_WARP_MASK, job.instance_idx, 0);
    job.offset = __shfl_sync(FULL_WARP_MASK, job.offset, 0);
    job.val = __shfl_sync(FULL_WARP_MASK, job.val, 0);
    job.src_id = __shfl_sync(FULL_WARP_MASK, job.src_id, 0);
    __syncwarp(FULL_WARP_MASK);
    while (job.val) {
      if (ggraph->getDegree(job.src_id) < ELE_PER_WARP) {
        SampleWarpCentic(result, ggraph, state, current_itr, job.instance_idx,
                         job.src_id, buffer, job.offset);
      } else {
#ifdef skip8k
        if (LID == 0 && ggraph->getDegree(job.src_id) < 8000)
#else
        if (LID == 0)
#endif  // skip8k
          result.AddHighDegree(current_itr, job);
      }
      __syncwarp(FULL_WARP_MASK);
      if (LID == 0) job = result.requireOneJob(current_itr);
      job.instance_idx = __shfl_sync(FULL_WARP_MASK, job.instance_idx, 0);
      job.val = __shfl_sync(FULL_WARP_MASK, job.val, 0);
      job.src_id = __shfl_sync(FULL_WARP_MASK, job.src_id, 0);
      job.offset = __shfl_sync(FULL_WARP_MASK, job.offset, 0);
    }
    __syncthreads();
    __shared__ sampleJob<uint> high_degree_job;
    if (LTID == 0) {
      job = result.requireOneHighDegreeJob(current_itr);
      high_degree_job.instance_idx = job.instance_idx;
      high_degree_job.val = job.val;
      high_degree_job.src_id = job.src_id;
      high_degree_job.offset = job.offset;
    }
    __syncthreads();
    while (high_degree_job.val) {
      SampleBlockCentic(result, ggraph, state, current_itr,
                        high_degree_job.src_id, buffer, vector_packs,
                        high_degree_job.instance_idx,
                        high_degree_job.offset);  // buffer_pointer
      __syncthreads();
      if (LTID == 0) {
        job = result.requireOneHighDegreeJob(current_itr);
        high_degree_job.instance_idx = job.instance_idx;
        high_degree_job.val = job.val;
        high_degree_job.src_id = job.src_id;
        high_degree_job.offset = job.offset;
      }
      __syncthreads();
    }
    __syncthreads();
    if (threadIdx.x == 0) {
      // while (!result.checkFinish(current_itr))
      // {
      //   printf("waiting ");
      // }
      // result.NextItr(current_itr);
      current_itr++;
    }
    __syncthreads();
  }
}

static __global__ void print_result(Sampler_new *sampler) {
  sampler->result.PrintResult();
}

// void Start_high_degree(Sampler sampler)
float OnlineGBSampleNew(Sampler_new &sampler) {
  // orkut max degree 932101

#ifdef LOCALITY
  printf("error: cannot run with  LOCALITY yet \n");
  return 0.0;
#endif

  LOG("%s\n", __FUNCTION__);
#ifdef skip8k
  LOG("skipping 8k\n");
#endif  // skip8k

  int device;
  cudaDeviceProp prop;
  cudaGetDevice(&device);
  cudaGetDeviceProperties(&prop, device);
  int n_sm = prop.multiProcessorCount;

  Sampler_new *sampler_ptr;
  cudaMalloc(&sampler_ptr, sizeof(Sampler_new));
  CUDA_RT_CALL(cudaMemcpy(sampler_ptr, &sampler, sizeof(Sampler_new),
                          cudaMemcpyHostToDevice));
  double start_time, total_time;
  // init_kernel_ptr<<<1, 32, 0, 0>>>(sampler_ptr, true);

  // allocate global buffer
  int block_num = n_sm * FLAGS_m;
#ifdef DEBUG
  block_num = 1;
#endif

  int gbuff_size = sampler.ggraph.MaxDegree + 10;

  LOG("alllocate GMEM buffer %d MB\n",
      block_num * gbuff_size * MEM_PER_ELE / 1024 / 1024);
  paster(gbuff_size);
  Vector_pack<uint> *vector_pack_h = new Vector_pack<uint>[block_num];
  for (size_t i = 0; i < block_num; i++) {
    vector_pack_h[i].Allocate(gbuff_size, sampler.device_id);
  }
  CUDA_RT_CALL(cudaDeviceSynchronize());
#pragma omp barrier
  Vector_pack<uint> *vector_packs;
  CUDA_RT_CALL(
      cudaMalloc(&vector_packs, sizeof(Vector_pack<uint>) * block_num));
  CUDA_RT_CALL(cudaMemcpy(vector_packs, vector_pack_h,
                          sizeof(Vector_pack<uint>) * block_num,
                          cudaMemcpyHostToDevice));

  //  Global_buffer
  CUDA_RT_CALL(cudaDeviceSynchronize());
  start_time = wtime();
#ifndef NDEBUG
  sample_kernel<<<1, 256, 0, 0>>>(sampler_ptr, vector_packs);
#else
  sample_kernel<<<block_num, BLOCK_SIZE, 0, 0>>>(sampler_ptr, vector_packs);
#endif
  CUDA_RT_CALL(cudaDeviceSynchronize());
  // CUDA_RT_CALL(cudaPeekAtLastError());
  total_time = wtime() - start_time;
  sampler.sampled_edges = sampler.result.GetSampledNumber(!FLAGS_peritr);
  LOG("Device %d sampling time:\t%.2f ms ratio:\t %.1f MSEPS\n",
      omp_get_thread_num(), total_time * 1000,
      static_cast<float>(sampler.sampled_edges / total_time / 1000000));
  LOG("sampled_edges %d\n", sampler.sampled_edges);
  if (FLAGS_printresult) print_result<<<1, 32, 0, 0>>>(sampler_ptr);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  return total_time;
}
