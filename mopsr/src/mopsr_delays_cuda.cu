#include <cuda_runtime.h>
#include <cuComplex.h>
#include <curand_kernel.h>
#include <inttypes.h>
#include <stdio.h>
#include <cub/block/block_radix_sort.cuh>
#include <assert.h>

#include "mopsr_cuda.h"
#include "mopsr_delays_cuda.h"

// maximum number of channels * antenna from 1 PFB 128 * 16
#define MOPSR_PFB_CHANANT_MAX 640 
#define MOPSR_MAX_ANT         352
#define WARP_SIZE             32
#define SPECTRAL_DELAYS       1
//#define _GDEBUG               1

//#define USE_DS_DELAYS 1

__constant__ float d_ant_scales_delay [MOPSR_MAX_NANT_PER_AQ];

int mopsr_transpose_delay_alloc (transpose_delay_t * ctx,
                                 uint64_t block_size, unsigned nchan,
                                 unsigned nant, unsigned ntap)
{
  ctx->nchan = nchan;
  ctx->nant = nant;
  ctx->ntap = ntap;
  ctx->half_ntap = ntap / 2;
  const unsigned nchanant = nchan * nant;
  const unsigned ndim = 2;

  ctx->curr = (transpose_delay_buf_t *) malloc (sizeof(transpose_delay_buf_t));
  ctx->next = (transpose_delay_buf_t *) malloc (sizeof(transpose_delay_buf_t));
  ctx->buffer_size = block_size + (ndim * nchanant * ctx->half_ntap * 2);

#ifdef SPECTRAL_DELAYS
  size_t counter_size = ctx->nchan * ctx->nant * sizeof(unsigned);
#else
  size_t counter_size = ctx->nant * sizeof(unsigned);
#endif

  if (mopsr_transpose_delay_buf_alloc (ctx->curr, ctx->buffer_size, counter_size) < 0)
  {
    fprintf (stderr, "mopsr_transpose_delay_alloc: mopsr_transpose_delay_buf_alloc failed\n");
    return -1;
  }

  if (mopsr_transpose_delay_buf_alloc (ctx->next, ctx->buffer_size, counter_size) < 0)
  {
    fprintf (stderr, "mopsr_transpose_delay_alloc: mopsr_transpose_delay_buf_alloc failed\n");
    return -1;
  }

  ctx->first_kernel = 1;
  
  return 0;
}

int mopsr_transpose_delay_buf_alloc (transpose_delay_buf_t * buf, size_t buffer_size, size_t counter_size)
{
  cudaError_t error; 

  // allocate the buffer for data
  error = cudaMalloc (&(buf->d_buffer), buffer_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMalloc failed for %ld bytes\n", buffer_size);
    return -1;
  }

  buf->counter_size = counter_size;

/*
  error = cudaMalloc (&(buf->d_out_from), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMalloc failed for %ld bytes\n", buf->counter_size);
    return -1;
  }

  error = cudaMalloc (&(buf->d_in_from), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMalloc failed for %ld bytes\n", buf->counter_size);
    return -1;
  }

  error = cudaMalloc (&(buf->d_in_to), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMalloc failed for %ld bytes\n", buf->counter_size);
    return -1;
  }
*/

  error = cudaMallocHost (&(buf->h_out_from), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMallocHost failed for %ld bytes\n", buf->counter_size);
    return -1;
  }

  error = cudaMallocHost (&(buf->h_in_from), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMallocHost failed for %ld bytes\n", buf->counter_size);
    return -1;
  }

  error = cudaMallocHost (&(buf->h_in_to), buf->counter_size);
  if (error != cudaSuccess)
  {
    fprintf (stderr, "mopsr_transpose_delay_buf_alloc: cudaMallocHost failed for %ld bytes\n", buf->counter_size);
    return -1;
  }

  buf->h_off = (unsigned *) malloc(buf->counter_size);
  buf->h_delays = (unsigned *) malloc(buf->counter_size);

  return 0;
}

void mopsr_transpose_delay_reset (transpose_delay_t * ctx)
{
  ctx->first_kernel = 1;
}


int mopsr_transpose_delay_dealloc (transpose_delay_t * ctx)
{
  mopsr_transpose_delay_buf_dealloc (ctx->curr);
  mopsr_transpose_delay_buf_dealloc (ctx->next);

  return 0;
}

int mopsr_transpose_delay_buf_dealloc (transpose_delay_buf_t * ctx)
{
  if (ctx->h_out_from)
    cudaFreeHost (ctx->h_out_from);
  ctx->h_out_from = 0;

  if (ctx->h_in_from)
    cudaFreeHost (ctx->h_in_from);
  ctx->h_in_from = 0;

  if (ctx->h_in_to)
    cudaFreeHost (ctx->h_in_to);
  ctx->h_in_to = 0;
  
  if (ctx->h_off)
    free(ctx->h_off);
  ctx->h_off = 0;

  if (ctx->h_delays)
    free(ctx->h_delays);
  ctx->h_delays = 0;

  if (ctx->d_buffer)
    cudaFree(ctx->d_buffer);
  ctx->d_buffer =0;

  return 0;
}

#ifdef SPECTRAL_DELAYS
__constant__ unsigned curr_out_from[MOPSR_PFB_CHANANT_MAX];
__constant__ unsigned curr_in_from[MOPSR_PFB_CHANANT_MAX];
__constant__ unsigned curr_in_to[MOPSR_PFB_CHANANT_MAX];
__constant__ unsigned next_out_from[MOPSR_PFB_CHANANT_MAX];
__constant__ unsigned next_in_from[MOPSR_PFB_CHANANT_MAX];
__constant__ unsigned next_in_to[MOPSR_PFB_CHANANT_MAX];
#else
__constant__ unsigned curr_out_from[MOPSR_MAX_NANT_PER_AQ];
__constant__ unsigned curr_in_from[MOPSR_MAX_NANT_PER_AQ];
__constant__ unsigned curr_in_to[MOPSR_MAX_NANT_PER_AQ];
__constant__ unsigned next_out_from[MOPSR_MAX_NANT_PER_AQ];
__constant__ unsigned next_in_from[MOPSR_MAX_NANT_PER_AQ];
__constant__ unsigned next_in_to[MOPSR_MAX_NANT_PER_AQ];
#endif

__global__ void mopsr_transpose_delay_kernel (
     int16_t * in,
     int16_t * curr,
     int16_t * next,
     const unsigned nchan, const unsigned nant, const unsigned nval, 
     const unsigned nval_per_thread, const unsigned in_block_stride, 
     const unsigned nsamp_per_block, const unsigned out_chanant_stride)
{
  // for loaded data samples
  extern __shared__ int16_t sdata[];

  const unsigned nchanant = nchan * nant;

  const unsigned warp_num = threadIdx.x / WARP_SIZE;
  const unsigned warp_idx = threadIdx.x % WARP_SIZE;
  const unsigned offset = (warp_num * (WARP_SIZE * nval_per_thread)) + warp_idx;

  unsigned in_idx  = (blockIdx.x * blockDim.x * nval_per_thread) + offset;
  unsigned sin_idx = offset;

  unsigned ival;
  for (ival=0; ival<nval_per_thread; ival++)
  {
    if (in_idx < nval * nval_per_thread)
      sdata[sin_idx] = in[in_idx];
    else
      sdata[sin_idx] = 0;

    in_idx += WARP_SIZE;
    sin_idx += WARP_SIZE;
  }

  __syncthreads();

  // our thread number within the warp [0-32], also the time sample this will write each time
  const unsigned isamp = warp_idx;

  // starting ichan/ant
  unsigned ichanant = warp_num * nval_per_thread;

  // determine which shared memory index for this output ichan and isamp
  unsigned sout_idx = (isamp * nchanant) + ichanant;

  // which sample number in the kernel this thread is writing
  const unsigned isamp_kernel = (blockIdx.x * nsamp_per_block) + (isamp);

  // vanilla output index for this thread
  uint64_t out_idx = (ichanant * out_chanant_stride) + isamp_kernel;

  int64_t curr_idx, next_idx;


#ifdef SPECTRAL_DELAYS
  for (ival=0; ival<nval_per_thread; ival++)
  {
    if ((curr_in_from[ichanant] <= isamp_kernel) && (isamp_kernel < curr_in_to[ichanant]))
    {
      curr_idx = (int64_t) out_idx + curr_out_from[ichanant] - curr_in_from[ichanant];
      curr[curr_idx] = sdata[sout_idx];
    }

    if ((next_in_from[ichanant] <= isamp_kernel) && (isamp_kernel < next_in_to[ichanant]))
    {
      next_idx = (int64_t) out_idx + next_out_from[ichanant] - next_in_from[ichanant];
      next[next_idx] = sdata[sout_idx];
    }

    sout_idx ++;
    out_idx += out_chanant_stride;
    ichanant++;
  }
#else
  unsigned iant;

  for (ival=0; ival<nval_per_thread; ival++)
  {
    iant = ichanant % nant;

    if ((curr_in_from[iant] <= isamp_kernel) && (isamp_kernel < curr_in_to[iant]))
    {
      curr_idx = (int64_t) out_idx + curr_out_from[iant] - curr_in_from[iant];
      curr[curr_idx] = sdata[sout_idx];
    }

    if ((next_in_from[iant] <= isamp_kernel) && (isamp_kernel < next_in_to[iant]))
    {
      next_idx = (int64_t) out_idx + next_out_from[iant] - next_in_from[iant];
      next[next_idx] = sdata[sout_idx];
    }

    sout_idx ++;
    out_idx += out_chanant_stride;
    ichanant++;
  }
#endif
}

void * mopsr_transpose_delay (cudaStream_t stream, transpose_delay_t * ctx, void * d_in, uint64_t nbytes, mopsr_delay_t ** delays)
{
  const unsigned ndim = 2;
  unsigned nthread = 1024;

  // since we want a warp of 32 threads to write out just 1 chunk
  const unsigned nsamp_per_block = 32;
  const unsigned nval_per_block  = nsamp_per_block * ctx->nchan * ctx->nant;
  const uint64_t nsamp = nbytes / (ctx->nchan * ctx->nant * ndim);

  unsigned ichan, iant;
  int shift;

#ifdef SPECTRAL_DELAYS
  unsigned ichanant = 0;

  for (ichan=0; ichan < ctx->nchan; ichan++)
  {
    for (iant=0; iant < ctx->nant; iant++)
    {
      if (delays[iant][ichan].samples < ctx->half_ntap)
      {
        fprintf (stderr, "ERROR: delay in samples is less than ntap/2\n");
        return 0;
      }

      if (ctx->first_kernel)
      {
        ctx->curr->h_delays[ichanant]   = delays[iant][ichan].samples;
        ctx->next->h_delays[ichanant]   = delays[iant][ichan].samples;

        ctx->curr->h_out_from[ichanant] = 0;
        ctx->curr->h_in_from[ichanant]  = ctx->curr->h_delays[ichanant] - ctx->half_ntap;
        ctx->curr->h_in_to[ichanant]    = nsamp;
        ctx->curr->h_off[ichanant]      = ctx->curr->h_in_to[ichanant] - ctx->curr->h_in_from[ichanant];

        // should never be used on first iteration
        ctx->next->h_out_from[ichanant] = 0;
        ctx->next->h_in_from[ichanant]  = nsamp;
        ctx->next->h_in_to[ichanant]    = 2 * nsamp;
      }

      else
      {
        // curr always uses delays from previous iteration
        ctx->curr->h_out_from[ichanant] = ctx->curr->h_off[ichanant];
        ctx->curr->h_in_from[ichanant]  = 0;
        ctx->curr->h_in_to[ichanant]    = nsamp + (2 * ctx->half_ntap) - ctx->curr->h_off[ichanant];
        if (nsamp + (2 * ctx->half_ntap) < ctx->curr->h_off[ichanant])
          ctx->curr->h_in_to[ichanant] = 0;

        // next always uses new delays
        ctx->next->h_out_from[ichanant] = 0;
        ctx->next->h_in_from[ichanant]  = ctx->curr->h_in_to[ichanant] - (2 * ctx->half_ntap);
        ctx->next->h_in_to[ichanant]    = nsamp;

        // handle a change in sample level delay this should be right
        shift = delays[iant][ichan].samples - ctx->curr->h_delays[ichanant];

        ctx->next->h_in_from[ichanant] += shift;
        ctx->next->h_delays[ichanant]   = delays[iant][ichan].samples;
        ctx->next->h_off[ichanant]      = ctx->next->h_in_to[ichanant] - ctx->next->h_in_from[ichanant];

      }
      ichanant++;
    }
  }

#else

  ichan = 0;
  for (iant=0; iant < ctx->nant; iant++)
  {
    if (ctx->first_kernel)
    {
      ctx->curr->h_delays[iant]   = delays[iant][0].samples;
      ctx->next->h_delays[iant]   = delays[iant][0].samples;

      ctx->curr->h_out_from[iant] = 0;
      ctx->curr->h_in_from[iant]  = ctx->curr->h_delays[iant] - ctx->half_ntap;
      ctx->curr->h_in_to[iant]    = nsamp;
      ctx->curr->h_off[iant]      = ctx->curr->h_in_to[iant] - ctx->curr->h_in_from[iant];

      // should never be used on first iteration
      ctx->next->h_out_from[iant] = 0;
      ctx->next->h_in_from[iant]  = nsamp;
      ctx->next->h_in_to[iant]    = 2 * nsamp;

      //if (iant == 0)
      //  fprintf (stderr, "1: h_out_from=%u h_in_from=%u h_in_to=%u h_off=%u\n", 
      //            ctx->curr->h_out_from[0], ctx->curr->h_in_from[0],
      //            ctx->curr->h_in_to[0], ctx->curr->h_off[0]);

    }
    else
    {
      // curr always uses delays from previous iteration
      ctx->curr->h_out_from[iant] = ctx->curr->h_off[iant];
      ctx->curr->h_in_from[iant]  = 0;
      ctx->curr->h_in_to[iant]    = nsamp + (2 * ctx->half_ntap) - ctx->curr->h_off[iant];
      if (nsamp + (2 * ctx->half_ntap) < ctx->curr->h_off[iant])
        ctx->curr->h_in_to[iant] = 0;
      //ctx->curr->h_off[iant]      = 0;  // no longer required

      //if (iant == 0)
      //  fprintf (stderr, "2: h_out_from=%u h_in_from=%u h_in_to=%u h_off=%u\n", 
      //            ctx->curr->h_out_from[0], ctx->curr->h_in_from[0],
      //            ctx->curr->h_in_to[0], ctx->curr->h_off[0]);

      // next always uses new delays
      ctx->next->h_out_from[iant] = 0;
      ctx->next->h_in_from[iant]  = ctx->curr->h_in_to[iant] - (2 * ctx->half_ntap);
      ctx->next->h_in_to[iant]    = nsamp;

      // handle a change in sample level delay
      shift = delays[iant][ichan].samples - ctx->curr->h_delays[iant];

      ctx->next->h_in_from[iant] += shift;
      ctx->next->h_delays[iant]   = delays[iant][ichan].samples;
      ctx->next->h_off[iant]      = ctx->next->h_in_to[iant] - ctx->next->h_in_from[iant];
    }
  }
#endif

/*
 */

  cudaMemcpyToSymbolAsync(curr_out_from, (void *) ctx->curr->h_out_from, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync(curr_in_from, (void *) ctx->curr->h_in_from, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync(curr_in_to, (void *) ctx->curr->h_in_to, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync(next_out_from, (void *) ctx->next->h_out_from, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync(next_in_from, (void *) ctx->next->h_in_from, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync(next_in_to, (void *) ctx->next->h_in_to, ctx->curr->counter_size, 0, cudaMemcpyHostToDevice, stream);
  cudaStreamSynchronize(stream);

  // special case where not a clean multiple [TODO validate this!]
  if (nval_per_block % nthread)
  {
    unsigned numerator = nval_per_block;
    while ( numerator > nthread )
      numerator /= 2;
    nthread = numerator;
  }
  unsigned nval_per_thread = nval_per_block / nthread;

  const uint64_t ndat = nbytes / (ctx->nchan * ctx->nant * ndim);
  // the total number of values we have to process is
  const uint64_t nval = nbytes / (ndim * nval_per_thread);
  int nblocks = nval / nthread;
  if (nval % nthread)
    nblocks++;

  const size_t sdata_bytes = (nthread * ndim * nval_per_thread);// + (6 * ctx->nchan * ctx->nant * sizeof(unsigned));
  const unsigned in_block_stride = nthread * nval_per_thread;
  const unsigned out_chanant_stride = ndat + (2 * ctx->half_ntap);

#ifdef _GDEBUG
  fprintf (stderr, "transpose_delay: nval_per_block=%u, nval_per_thread=%u\n", nval_per_block, nval_per_thread);
  fprintf (stderr, "transpose_delay: nbytes=%lu, ndat=%lu, nval=%lu\n", nbytes, ndat, nval);
  fprintf (stderr, "transpose_delay: nthread=%d, nblocks=%d sdata_bytes=%d\n", nthread, nblocks, sdata_bytes);
  fprintf (stderr, "transpose_delay: out_chanant_stride=%u\n", out_chanant_stride);
#endif

  mopsr_transpose_delay_kernel<<<nblocks,nthread,sdata_bytes,stream>>>((int16_t *) d_in, 
        (int16_t *) ctx->curr->d_buffer, //ctx->curr->d_out_from, ctx->curr->d_in_from, ctx->curr->d_in_to,
        (int16_t *) ctx->next->d_buffer, //ctx->next->d_out_from, ctx->next->d_in_from, ctx->next->d_in_to,
        ctx->nchan, ctx->nant, nval, nval_per_thread, in_block_stride, nsamp_per_block, out_chanant_stride);

#if _GDEBUG
  check_error_stream("mopsr_transpose_delay_kernel", stream);
#endif

  if (ctx->first_kernel)
  {
    ctx->first_kernel = 0;
    return 0;
  }
  else
  {
    transpose_delay_buf_t * save = ctx->curr;
    ctx->curr = ctx->next;
    ctx->next = save;
    return save->d_buffer;
  }
}



// fringe co-efficients are fast in constant memory here
__constant__ float fringe_coeffs[MOPSR_PFB_CHANANT_MAX];
#ifdef USE_DS_DELAYS
__constant__ float delays_ds[MOPSR_PFB_CHANANT_MAX];
__constant__ float fringe_coeffs_ds[MOPSR_PFB_CHANANT_MAX];
#endif

// apply a fractional delay correction to a channel / antenna, warps will always
__global__ void mopsr_fringe_rotate_kernel (int16_t * input, uint64_t ndat)
{
  const unsigned isamp = blockIdx.x * blockDim.x + threadIdx.x;
  const unsigned iant  = blockIdx.y;
  const unsigned nant  = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = (ichan * nant) + iant;
  const uint64_t idx = ichanant * ndat + isamp;

  if (isamp >= ndat)
    return;

  // using constant memory should result in broadcast for this block/half warp
  float fringe_coeff = fringe_coeffs[ichanant];
  cuComplex fringe_phasor = make_cuComplex (cosf(fringe_coeff), sinf(fringe_coeff));

  int16_t val16 = input[idx];
  int8_t * val8ptr = (int8_t *) &val16;
  const float scale = d_ant_scales_delay[iant];

  float re = ((float) (val8ptr[0]) + 0.5) * scale;
  float im = ((float) (val8ptr[1]) + 0.5) * scale;
  cuComplex val = make_cuComplex (re, im);
  cuComplex rotated = cuCmulf(val, fringe_phasor);

  val8ptr[0] = (int8_t) rintf (cuCrealf(rotated) - 0.5);
  val8ptr[1] = (int8_t) rintf (cuCimagf(rotated) - 0.5);

  input[idx] = val16;
}

//
// Perform fractional delay correction, out-of-place
//
void mopsr_fringe_rotate (cudaStream_t stream, void * d_in,
                          float * h_fringes, size_t fringes_size,
                          uint64_t nbytes, unsigned nchan,
                          unsigned nant)
{
  const unsigned ndim = 2;
  const uint64_t ndat = nbytes / (nchan * nant * ndim);

  // number of threads that actually load data
  unsigned nthread = 1024;

  dim3 blocks (ndat / nthread, nant, nchan);
  if (ndat % nthread)
    blocks.x++;

  cudaMemcpyToSymbolAsync(fringe_coeffs, (void *) h_fringes, fringes_size, 0, cudaMemcpyHostToDevice, stream);
  cudaStreamSynchronize(stream);

#if _GDEBUG
  fprintf (stderr, "fringe_rotate: bytes=%lu ndat=%lu\n", nbytes, ndat);
  fprintf (stderr, "fringe_rotate: nthread=%d, blocks.x=%d, blocks.y=%d, blocks.z=%d\n", nthread, blocks.x, blocks.y, blocks.z);
  fprintf (stderr, "fringe_rotate: d_in=%p h_fringes=%p\n", (void *) d_in, (void*) h_fringes);
#endif

  mopsr_fringe_rotate_kernel<<<blocks, nthread, 0, stream>>>((int16_t *) d_in, ndat);

#if _GDEBUG
  check_error_stream("mopsr_fringe_rotate_kernel", stream);
#endif
}


/*
__global__ void mopsr_print_ant_scales (unsigned nant)
{
  unsigned iant;
  for (iant=0; iant<nant; iant++)
  {
    printf("d_ant_scales[%d]=%f\n", iant, d_ant_scales_delay[iant]); 
  }
}
*/

void mopsr_delay_copy_scales (cudaStream_t stream, float * h_ant_scales, size_t nbytes)
{
  cudaMemcpyToSymbolAsync (d_ant_scales_delay, (void *) h_ant_scales, nbytes, 0, cudaMemcpyHostToDevice, stream);
  cudaStreamSynchronize(stream);
  //int blocks_test = 1;
  //int threads_test = 1;
  //mopsr_print_ant_scales<<<blocks_test, threads_test, 0, stream>>>(nbytes/sizeof(float));
}


// apply a fractional delay correction to a channel / antenna, warps will always 
__global__ void mopsr_delay_fractional_kernel (int16_t * input, int16_t * output, 
                                               float * delays,
                                               unsigned nthread_run, 
                                               uint64_t nsamp_in, 
                                               const unsigned chan_stride, 
                                               const unsigned ant_stride, 
                                               const unsigned ntap)
{
  // the input data for block are stored in blockDim.x values
  extern __shared__ cuComplex fk_shared1[];

  // the FIR filter stored in the final NTAP values
  float * filter = (float *) (fk_shared1 + blockDim.x);

  const unsigned half_ntap = (ntap / 2);
  const unsigned in_offset = 2 * half_ntap;
  
  const unsigned isamp = blockIdx.x * nthread_run + threadIdx.x;
  const unsigned iant  = blockIdx.y;
  const unsigned nant  = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = ichan * nant + iant;

  const unsigned nsamp_out = nsamp_in - in_offset;

#ifdef USE_DS_DELAYS
  const float isamp_offset = (float) isamp - ((float) nsamp_out) / 2;

  // using constant memory should result in broadcast for this block/half warp
  // handle change in delay across the block
  float delay = delays[ichanant] + (delays_ds[ichanant] * isamp_offset);
  float fringe_coeff = fringe_coeffs[ichanant] + (fringe_coeffs_ds[ichanant] * isamp_offset);
#else
  float delay = delays[ichanant];
  float fringe_coeff = fringe_coeffs[ichanant];
#endif

  cuComplex fringe_phasor = make_cuComplex (cosf(fringe_coeff), sinf(fringe_coeff));

  // calculate the filter coefficients for the delay
  if (threadIdx.x < ntap)
  {
    float x = ((float) threadIdx.x) - delay;
    float window = 0.54 - 0.46 * cos(2.0 * M_PI * (x+0.5) / ntap);
    float sinc = 1;
    if (x != half_ntap)
    {
      x -= half_ntap;
      x *= M_PI;
      sinc = sinf(x) / x;
    }
    //filter[threadIdx.x] = sinc;
    filter[threadIdx.x] = sinc * window;
  }
  
  if (isamp >= nsamp_in)
  {
    return;
  }

  // each thread must also load its data from main memory here chan_stride + ant_stride
  const unsigned in_data_idx  = (ichanant * nsamp_in) + isamp;
  // const unsigned out_data_idx = ichanant * nsamp_out + isamp;

  int16_t val16 = input[in_data_idx];
  int8_t * val8ptr = (int8_t *) &val16;

  {
    const float scale = d_ant_scales_delay[iant];
    cuComplex val = make_cuComplex ((float) (val8ptr[0]) + 0.5, (float) (val8ptr[1]) + 0.5);
    val.x *= scale;
    val.y *= scale;
    fk_shared1[threadIdx.x] = cuCmulf(val, fringe_phasor);
  }

  __syncthreads();

  // there are 2 * half_ntap threads that dont calculate anything
  if ((threadIdx.x < nthread_run) && (isamp < nsamp_out))
  {
    float re = 0;
    float im = 0;
    for (unsigned i=0; i<ntap; i++)
    {
      re += cuCrealf(fk_shared1[threadIdx.x + i]) * filter[i];
      im += cuCimagf(fk_shared1[threadIdx.x + i]) * filter[i];
    }
    
    val8ptr[0] = (int8_t) rintf (re - 0.5);
    val8ptr[1] = (int8_t) rintf (im - 0.5);

    output[ichanant * nsamp_out + isamp] = val16;
  }
}

// apply a fractional delay correction to a channel / antenna, warps will always 
__global__ void mopsr_delay_fractional_float_kernel (int16_t * input, 
                    cuFloatComplex * output, float * delays, 
                    unsigned nthread_run, uint64_t nsamp_in, 
                    const unsigned chan_stride, const unsigned ant_stride, 
                    const unsigned ntap)
{
  // the input data for block are stored in blockDim.x values
  extern __shared__ cuFloatComplex fk_shared2[];

  float * filter = (float *) (fk_shared2 + blockDim.x);

  //const unsigned ndim = 2;

  const unsigned half_ntap = ntap / 2;
  const unsigned in_offset = 2 * half_ntap;

  const unsigned isamp = blockIdx.x * nthread_run + threadIdx.x;
  const unsigned iant  = blockIdx.y;
  const unsigned nant  = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant  = ichan * nant + iant;

  const unsigned nsamp_out = nsamp_in - in_offset;

#ifdef USE_DS_DELAYS
  const float isamp_offset = (float) isamp - ((float) nsamp_out) / 2;

  // using constant memory should result in broadcast for this 
  // block/half warp.  handle change in delay across the block
  float delay        = delays[ichanant] + (delays_ds[ichanant] * isamp_offset);
  float fringe_coeff = fringe_coeffs[ichanant] + (fringe_coeffs_ds[ichanant] * isamp_offset);
#else
  float delay        = delays[ichanant];
  float fringe_coeff = fringe_coeffs[ichanant];
#endif

  cuFloatComplex fringe_phasor;
  sincosf (fringe_coeff, &(fringe_phasor.y), &(fringe_phasor.x));

  // calculate the filter coefficients for the delay
  if (threadIdx.x < ntap)
  {
    float x      = ((float) threadIdx.x) - delay;
    float window = 0.54 - 0.46 * cos(2.0 * M_PI * (x+0.5) / ntap);
    float sinc   = 1;
    if (x != half_ntap)
    {
      x -= half_ntap;
      x *= M_PI;
      sinc = sinf(x) / x;
    }
    filter[threadIdx.x] = sinc * window;
  }

  // final block check for data input (not data output!)
  if (isamp >= nsamp_in)
  {
    return;
  }

  // each thread must also load its data from main memory here chan_stride + ant_stride
  const unsigned in_data_idx  = (ichanant * nsamp_in) + isamp;

  int16_t val16 = input[in_data_idx];
  int8_t * val8ptr = (int8_t *) &val16;

  cuFloatComplex val = make_cuComplex ((float) (val8ptr[0]) + 0.5, (float) (val8ptr[1]) + 0.5);
  //cuFloatComplex val = make_cuComplex ((float) (val8ptr[0]), (float) (val8ptr[1]));
  fk_shared2[threadIdx.x] = cuCmulf (val, fringe_phasor);

  __syncthreads();

  const unsigned osamp = (blockIdx.x * nthread_run) + threadIdx.x;

  // there are 2 * half_ntap threads that dont calculate anything
  if (threadIdx.x < nthread_run && osamp < nsamp_out)
  {
    cuFloatComplex sum = make_cuComplex(0,0);
    for (unsigned i=0; i<ntap; i++)
    {
      val = fk_shared2[threadIdx.x + i];
      val.x *= filter[i];
      val.y *= filter[i];
      sum = cuCaddf(sum, val);
    }

    //val.x += cuCrealf(fk_shared2[threadIdx.x + i]) * filter[i];
    //val.y += cuCimagf(fk_shared2[threadIdx.x + i]) * filter[i];

    unsigned ou_data_idx = (ichanant * nsamp_out) + osamp;
    output[ou_data_idx] = sum;

/*
    if ((iant == 0) && (ichan == 13) && (blockIdx.x % 2 == 0))
    {
      output[ou_data_idx].x = 0;
      output[ou_data_idx].y = 0;
    }
*/
    //output[2*ou_data_idx + 0] = val.x;
    //output[2*ou_data_idx + 1] = val.y;

/*
    unsigned osamp = (blockIdx.x * nthread_run * ndim) + threadIdx.x;
    const unsigned nfloat_out = nsamp_out * ndim;

    // increment the base pointed to the right block
    output += (ichanant * nfloat_out);

    //if (osamp < nfloat_out)
    {
      float * dataf = (float *) fk_shared2;

      // pointer to first value in shared memory
      dataf += threadIdx.x;

      // compute sinc delayed float
      float val_re = 0;
      for (unsigned i=0; i<ntap; i++)
        val_re += dataf[2*i] * filter[i];

      //if ((blockIdx.x == 0) && (blockIdx.y == 0) && (blockIdx.z == 0))
      //  printf ("[%d] val_re=%f\n", threadIdx.x, val_re);

      //if (ichanant == 0 && blockIdx.x == 60)
      //  printf ("[%d][%d] output[%u]=%f\n", blockIdx.x, threadIdx.x, osamp, val);
      
      // write output to gmem
      output[osamp] = val_re;

      // increment shared memory pointer by number of active threads
      dataf += blockDim.x;

      // increment output pointer by number of active threads
      osamp += nthread_run;

      float val_im;
      //if (osamp < nfloat_out)
      {
        // compute sinc delayed float
        val_im = 0;
        for (unsigned i=0; i<ntap; i++)
          val_im += dataf[2*i] * filter[i];

        //if (ichanant == 0 && blockIdx.x == 60)
        //  printf ("[%d][%d] output[%u]=%f\n", blockIdx.x, threadIdx.x, osamp, val);

        // write output to gmem
        output[osamp] = val_im;
      }
      //if ((blockIdx.x == 0) && (blockIdx.y == 0) && (blockIdx.z == 0))
      //  printf ("[%d] val_im=%f\n", threadIdx.x, val_im);
    }
    */
  }
}

// 
// Perform fractional delay correction, out-of-place
//
void mopsr_delay_fractional (cudaStream_t stream, void * d_in, void * d_out,
                             float * d_delays, float * h_fringes, 
                             float * h_delays_ds, float * h_fringe_coeffs_ds, 
                             size_t fringes_size, 
                             uint64_t nbytes, unsigned nchan, 
                             unsigned nant, unsigned ntap)
{
  const unsigned ndim = 2;
  const uint64_t ndat = nbytes / (nchan * nant * ndim);
  const unsigned half_ntap = ntap / 2;

  // number of threads that actually load data
  unsigned nthread_load = 1024;
  if (ndat < nthread_load)
    nthread_load = ndat;
  unsigned nthread_run  = nthread_load - (2 * half_ntap);

  // need shared memory to load the ntap coefficients + nthread_load data points
  const size_t   sdata_bytes = (nthread_load * ndim + ntap) * sizeof(float);

  dim3 blocks (ndat / nthread_run, nant, nchan);
  if (ndat % nthread_load)
    blocks.x++;

  //fprintf (stderr, "delay_fractional: copying fringe's to symbold (%ld bytes)\n", fringes_size);
  cudaMemcpyToSymbolAsync (fringe_coeffs, (void *) h_fringes, fringes_size, 0, cudaMemcpyHostToDevice, stream);
#ifdef USE_DS_DELAYS
  cudaMemcpyToSymbolAsync (delays_ds, (void *) h_delays_ds, fringes_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync (fringe_coeffs_ds, (void *) h_fringe_coeffs_ds, fringes_size, 0, cudaMemcpyHostToDevice, stream);
#endif
  cudaStreamSynchronize(stream);

#if _GDEBUG
  fprintf (stderr, "delay_fractional: bytes=%lu ndat=%lu sdata_bytes=%ld\n", nbytes, ndat, sdata_bytes);
  fprintf (stderr, "delay_fractional: blocks.x=%d, blocks.y=%d, blocks.z=%d\n", blocks.x, blocks.y, blocks.z);
  fprintf (stderr, "delay_fractional: nthread_load=%d nthread_run=%d ntap=%d\n", nthread_load, nthread_run, ntap);
#endif

  const unsigned chan_stride = nant * ndat;
  const unsigned ant_stride  = ndat;

  mopsr_delay_fractional_kernel<<<blocks, nthread_load, sdata_bytes, stream>>>((int16_t *) d_in, (int16_t *) d_out, (float *) d_delays, nthread_run, ndat, chan_stride, ant_stride, ntap);

#if _GDEBUG
  check_error_stream("mopsr_delay_fractional_kernel", stream);
#endif
}


//#if HAVE_CUDA_SHUFFLE
__inline__ __device__
float warpReduceSumF(float val) {
  for (int offset = warpSize/2; offset > 0; offset /= 2) 
    val += __shfl_down(val, offset);
  return val;
}

__inline__ __device__
float blockReduceSumF(float val) {

  __shared__ float shared[32]; // Shared mem for 32 partial sums
  int lane = threadIdx.x % warpSize;
  int wid = threadIdx.x / warpSize;

  val = warpReduceSumF(val);     // Each warp performs partial reduction

  if (lane==0) shared[wid]=val; // Write reduced value to shared memory

  __syncthreads();              // Wait for all partial reductions

  //read from shared memory only if that warp existed
  val = (threadIdx.x < blockDim.x / warpSize) ? shared[lane] : 0;

  if (wid==0) val = warpReduceSumF(val); //Final reduce within first warp

  return val;
}

__inline__ __device__
int warpReduceSumI(int val) {
  for (int offset = warpSize/2; offset > 0; offset /= 2)
    val += __shfl_down(val, offset);
  return val;
}

__inline__ __device__
int blockReduceSumI(int val) {

  __shared__ int shared[32]; // Shared mem for 32 partial sums
  int lane = threadIdx.x % warpSize;
  int wid = threadIdx.x / warpSize;

  val = warpReduceSumI(val);     // Each warp performs partial reduction

  if (lane==0) shared[wid]=val; // Write reduced value to shared memory

  __syncthreads();              // Wait for all partial reductions

  //read from shared memory only if that warp existed
  val = (threadIdx.x < blockDim.x / warpSize) ? shared[lane] : 0;

  if (wid==0) val = warpReduceSumI(val); //Final reduce within first warp

  return val;
}
//#endif


// Compute the mean of the re and imginary compoents for 
__global__ void mopsr_measure_means_kernel (cuFloatComplex * in, cuFloatComplex * means, const unsigned nval_per_thread, const uint64_t ndat)
{
  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = (ichan * nant) + iant;
  const uint64_t in_offset = ichanant * ndat;

  cuFloatComplex * indat = in + in_offset;

  unsigned idx = threadIdx.x * nval_per_thread;

  cuFloatComplex val;
  float sum_re = 0;
  float sum_im = 0;
  int count = 0;

  for (unsigned ival=0; ival<nval_per_thread; ival++)
  {
    if (idx < ndat)
    {
      val = indat[idx];
      sum_re += val.x;
      sum_im += val.y;
      count++;
    }
    idx += blockDim.x;
  }

  // compute via block reduce sum
  sum_re = blockReduceSumF(sum_re);
  sum_im = blockReduceSumF(sum_im);
  count = blockReduceSumI(count);

  if (threadIdx.x == 0)
  {
    means[ichanant].x = sum_re / count;
    means[ichanant].y = sum_im / count;

    //if (ichanant == 10)
    //  printf ("ant=%d chan=%d raw=(%f, %f) means=(%f,%f) count=%u\n", iant, ichan, mean_re, mean_im, means[ichanant].x, means[ichanant].y, count);
  }
}

//
// Compute the S1 and S2 sums for blocks of input data, writing the S1 and S2 sums out to Gmem
//
//__global__ void mopsr_skcompute_kernel (cuFloatComplex * in, cuFloatComplex * sums, const unsigned nval_per_thread, const uint64_t ndat)
__global__ void mopsr_skcompute_kernel (cuFloatComplex * in, float * s1s, float * s2s, const unsigned nval_per_thread, const uint64_t ndat)
{
  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = (ichan * nant) + iant;
  const uint64_t in_offset = ichanant * ndat;

  // offset into the block for the current channel and antenna
  cuFloatComplex * indat = in + in_offset;

  unsigned idx = (blockIdx.x * blockDim.x + threadIdx.x) * nval_per_thread;

  cuFloatComplex val;
  float s1_sum = 0;
  float s2_sum = 0;
  float power;

  for (unsigned ival=0; ival<nval_per_thread; ival++)
  {
    if (idx < ndat)
    {
      val = indat[idx];
      power = (val.x * val.x) + (val.y * val.y);
      s1_sum += power;
      s2_sum += (power * power);
    }
    idx += blockDim.x;
  }

  // compute via block reduce sum  
  s1_sum = blockReduceSumF(s1_sum);
  s2_sum = blockReduceSumF(s2_sum);

  if (threadIdx.x == 0)
  {
    // FST ordered
    const unsigned out_idx = (ichanant * gridDim.x) +  blockIdx.x;
    s1s[out_idx] = s1_sum;
    s2s[out_idx] = s2_sum;
    //sums[out_idx].x = s1_sum;
    //sums[out_idx].y = s2_sum;
  }
}


void mopsr_test_skcompute (cudaStream_t stream, void * d_in, void * d_s1s_out, void * d_s2s_out, unsigned nchan, unsigned nant, unsigned nbytes)
{
  const unsigned ndim = 2;
  const uint64_t ndat = nbytes / (nchan * nant * ndim * sizeof(float));
  const unsigned nthreads = 1024;
  const unsigned nval_per_thread = 1;
  size_t shm_bytes = 0;

  dim3 blocks (ndat / nthreads, nant, nchan);
  if (ndat % nthreads)
    blocks.x++;

  fprintf (stderr, "mopsr_skcompute_kernel: bytes=%lu ndat=%lu shm_bytes=%ld\n", nbytes, ndat, shm_bytes);
  fprintf (stderr, "mopsr_skcompute_kernel: blocks.x=%d, blocks.y=%d, blocks.z=%d, nthreads=%u\n", blocks.x, blocks.y, blocks.z, nthreads);
  fprintf (stderr, "mopsr_skcompute_kernel: d_in=%p d_s1s_out=%p, d_s2s_out=%p nval_per_thread=%u, ndat_sk=%lu\n", d_in, d_s1s_out, d_s2s_out, nval_per_thread, ndat);

  mopsr_skcompute_kernel<<<blocks, nthreads, shm_bytes, stream>>>( (cuFloatComplex *) d_in, (float *) d_s1s_out, (float *) d_s2s_out, nval_per_thread, ndat);

  check_error_stream("mopsr_skcompute_kernel", stream);
}

//
// take the S1 and S2 values in sums.x and sums.y that were computed 
//  from M samples, and integrate of nsums blocks to
// compute a sk mask and zap
//
__global__ void mopsr_skmask_kernel (float * in, int8_t * out, cuFloatComplex * sums, 
                                     curandState * rstates, float * sigmas,
                                     unsigned nsums, unsigned M, unsigned nval_per_thread, 
                                     unsigned nsamp_per_thread, uint64_t ndat)
{
  // Pearson Type IV SK limits for 3sigma RFI rejection, based on 2^index

  // maximum to be 16384 samples (20.97152 ms)
  unsigned sk_idx_max = 20;

/*
  // 2 sigmas
  const float sk_low[20]  = { 0, 0, 0, 0, 0,
                              0.523764, 0.624469, 0.712994, 0.78523, 0.841598,
                              0.884441, 0.916408, 0.939919, 0.957021, 0.969359,
                              0.978208, 0.984528, 0.989028, 0.992226, 0.994495 };
  const float sk_high[20] = { 0, 0, 0, 0, 0,
                              1.83983, 1.59186, 1.41071, 1.28288, 1.19462,
                              1.13433, 1.09316, 1.06491, 1.04541, 1.03186,
                              1.0224, 1.01578, 1.01112, 1.00785, 1.00554 };
*/ 
  // 3 sigma
/*
  const float sk_low[20]  = { 0, 0, 0, 0, 0,
                              0.387702, 0.492078, 0.601904, 0.698159, 0.775046,
                              0.834186, 0.878879, 0.912209, 0.936770, 0.954684,
                              0.967644, 0.976961, 0.983628, 0.988382, 0.991764 };
  const float sk_high[20] = { 0, 0, 0, 0, 0,
                              2.731480, 2.166000, 1.762970, 1.495970, 1.325420,
                              1.216950, 1.146930, 1.100750, 1.069730, 1.048570,
                              1.033980, 1.023850, 1.016780, 1.011820, 1.008340 };
*/

  // 4 sigma
  const float sk_low[20]  = { 0, 0, 0, 0, 0,
                              0.274561, 0.363869, 0.492029, 0.613738, 0.711612,
                              0.786484, 0.843084, 0.885557, 0.917123, 0.940341,
                              0.957257, 0.969486, 0.978275, 0.984562, 0.989046 };
  const float sk_high[20] = { 0, 0, 0, 0, 0,
                              4.27587, 3.11001, 2.29104, 1.784, 1.48684,
                              1.31218, 1.20603, 1.13893, 1.0951, 1.06577,
                              1.0458, 1.03204, 1.02249, 1.01582, 1.01115 };

  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = (ichan * nant) + iant;

  const unsigned id = ichanant * blockDim.x + threadIdx.x;
  curandState localState = rstates[id];

  // zap mask for each set of M samples
  extern __shared__ char smask[];

  // initialize zap mask to 0
  {
    unsigned idx = threadIdx.x;
    for (unsigned ival=0; ival<nval_per_thread; ival++)
    {
      if (idx < nsums)
      {
        smask[idx] = 0;
        idx += blockDim.x;
      }
    }
  }

  __syncthreads();

  const unsigned log2_M = (unsigned) log2f (M);

  // 1 standard deviation for the input data, 0 indicates not value yet computed
  float sigma = sigmas[ichanant];
  float s1_thread = 0;
  int s1_count = 0;

  // sums data stored as FST
  sums += (ichanant * nsums);

  float sk_estimate;

  unsigned idx = threadIdx.x;
  for (unsigned ival=0; ival<nval_per_thread; ival++)
  {
    if (idx < nsums)
    {
      for (unsigned sk_idx = log2_M; sk_idx < sk_idx_max; sk_idx ++)
      {
        unsigned powers_to_add = sk_idx - log2_M;
        unsigned to_add = (unsigned) exp2f(powers_to_add);

        if (idx + to_add <= nsums)
        {
          const float m = (float) (M * to_add);
          const float m_fac = (m + 1) / (m - 1);
          float s1 = 0;
          float s2 = 0;

          for (unsigned ichunk=0; ichunk < to_add; ichunk++)
          {
            s1 += sums[idx + ichunk].x;
            s2 += sums[idx + ichunk].y;
          }

          if (s1 > 0)
            sk_estimate = m_fac * (m * (s2 / (s1 * s1)) - 1);
          else
            sk_estimate = 0;

          //if (ichan == 0 && iant == 0 && blockIdx.x == 0 && threadIdx.x == 0)
          //  printf ("M=%u m=%f sk_idx=%u powers_to_add=%u to_add=%u m_fac=%f s1=%f s2=%f sk_est=%f\n",
          //          M, m, sk_idx, powers_to_add, to_add, m_fac, s1, s2, sk_estimate);

          if ((sk_estimate < sk_low[sk_idx]) || (sk_estimate > sk_high[sk_idx]))
          {
            for (unsigned ichunk=0; ichunk < to_add; ichunk++)
            {
              smask[idx+ichunk] = 1;
            }
          }
          else
          {
            if (sk_idx == log2_M)
            {
              s1_thread += s1;
              s1_count++;
            }
          }
        }
      }
      idx += blockDim.x;
    }
  }

  // we should be able to have a syncthreads in here since 
  // all threads in the block will execute the same path
  if (sigma == 0)
  {
    // since s1 will have twice the variance of the Re/Im components, / 2
    s1_thread /= (2 * M);

    // compute the sum of the sums[].x for all the block
    s1_thread = blockReduceSumF (s1_thread);
    s1_count = blockReduceSumI (s1_count);

    // sync here to be sure the smask is now updated
    __syncthreads();

    __shared__ float block_sigma;

    if (threadIdx.x == 0)
    {
      sigma = 0;
      if (s1_count > 0)
        sigma = sqrtf (s1_thread / s1_count);

      sigmas[ichanant] = sigma;

      block_sigma = sigma;
    }

    __syncthreads();

    sigma = block_sigma;
  }

  // Jenet & Anderson 1998, 6-bit (2-bits for RFI) spacing
  //const float spacing = 0.09925;    // 6-bit
  const float spacing = 0.02957;      // 8-bit

  // dont do antenna scaling here anymore for the moment, unless it is zero
  const float ant_scale = d_ant_scales_delay[iant];
  float data_factor = ant_scale / (sigma * spacing);
  if (ant_scale < 0.01)
    data_factor = 0;
  const float rand_factor = ant_scale / spacing;
  //data_factor = 1;

  // now we want to zap all blocks of input that have an associated mask
  // note that this kernel has only 1 block, with blockDim.x threads that may not match
  const unsigned ndim = 2;
  const unsigned nval_per_sum = M * ndim;
  unsigned block_offset = (ichanant * ndat * ndim);
  float * indat = in + block_offset;
  int8_t * outdat = out + block_offset;

/*
  outdat += threadIdx.x * nval_per_sum;

  int8_t val = (int8_t) ((1 - sk_estimate) * 32);
  // i have an sk estimate for a sum/thread - set all values to that estimate
  for (unsigned isamp=0; isamp<nval_per_sum; isamp++)
  {
    outdat[isamp] = val;
    //outdat[isamp] = (int8_t) (((float) isamp / (float) nval_per_sum) * 32);
  }
*/

  // foreach block of M samples (i.e. 1 sum)
  for (unsigned isum=0; isum<nsums; isum++)
  {
    // use the threads to write out the int8_t scaled value (or zapped value)
    // back to global memory. There are 2 * M values to write each iteration

    unsigned idx = threadIdx.x;

    if (smask[isum] == 1 && 0)
    {
      for (unsigned isamp=0; isamp<nsamp_per_thread; isamp++)
      {
        if (idx < nval_per_sum)
        {
          const float inval = curand_normal (&localState);
          outdat[idx] = (int8_t) rintf(inval * rand_factor);
        }
        idx += blockDim.x;
      }
    }
    else
    {
      for (unsigned isamp=0; isamp<nsamp_per_thread; isamp++)
      {
        if (idx < nval_per_sum)
        {
          //outdat[idx] = (int8_t) rintf ((indat[idx] * data_factor) - 0.5);
          outdat[idx] = (int8_t) rintf (indat[idx] * data_factor);
        }
        idx += blockDim.x;
      }
    }
    outdat += ndim * M;
    indat += ndim * M;
  }

  rstates[id] = localState;
}

/*
 * TODO kernel currently requires that NSUMS < 1024
 * compute the median and absolute median difference median
 */
__global__ void mopsr_compute_power_limits_kernel (float * s1s_memory, cuFloatComplex * thresholds, unsigned nsums, unsigned valid_memory, unsigned nsigma, unsigned iblock)
{
  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned nchan = gridDim.z;
  const unsigned ichanant = (ichan * nant) + iant;
  const unsigned nchanant = nchan * nant;

  // nmemory should be something like 4
  float keys[MOPSR_MEMORY_BLOCKS];

  __shared__ float median;
  __shared__ float sigma;

  median = thresholds[ichanant].x;
  sigma  = thresholds[ichanant].y;

  // get the previous thresholds
  float upper = median + (3 * sigma);

  // S1 values stored as FST in blocks that are nsums long
  // first offset into the first block by the chanant
  float * in = s1s_memory + (ichanant * nsums);

  for (unsigned i=0; i<MOPSR_MEMORY_BLOCKS; i++)
  {
    keys[i] = in[threadIdx.x];
    if ((i == iblock) && (median != 0) && (keys[i] != 0) && (keys[i] > upper))
      keys[i] = median;

    //if ((iant == 0) && (ichan == 10))
    //  printf ("[%d][%d] s1s == %f\n", threadIdx.x, i, keys[i]);

    in += (nchanant * nsums);
  }

  // here compute the memory based median
  typedef cub::BlockRadixSort<float, 96, MOPSR_MEMORY_BLOCKS> BlockRadixSort;

  __shared__ typename BlockRadixSort::TempStorage temp_storage;

  BlockRadixSort(temp_storage).Sort(keys);

  __syncthreads();

  unsigned centre_thread = ((96*MOPSR_MEMORY_BLOCKS)- ((valid_memory * 96) / 2)) / MOPSR_MEMORY_BLOCKS;

  // the median will be located in thread (nthreads_sort/2)[0]
  if (threadIdx.x == centre_thread)
  {
    median = keys[0];
  }

  //if ((iant == 0) && (ichan == 10) && threadIdx.x == 0)
  //  printf ("centre_thread=%u\n", centre_thread);

  // ensure all threads in block can read the median
  __syncthreads();


  // now subtract median from s1 value in thread_keys and take abs value
  for (unsigned i=0; i<MOPSR_MEMORY_BLOCKS; i++)
  {
    if (keys[i] > 0)
    {
      keys[i] = fabsf(keys[i] - median);
      //if ((iant == 0) && (ichan == 10))
      //  printf ("[%d] keys[%d] = %f\n", threadIdx.x, i, keys[i]);
    }
  }

  __syncthreads();

  BlockRadixSort(temp_storage).Sort(keys);

  __syncthreads();

/*
  if (iant == 0 && ichan == 10)
  {
    printf ("[%d] = %f\n", threadIdx.x * 2, keys[0]);
    printf ("[%d] = %f\n", threadIdx.x * 2+1, keys[1]);
  }
*/
  if (threadIdx.x == centre_thread)
    sigma = keys[0];

  __syncthreads();

  //if (threadIdx.x == 0 && iant == 0 && ichan == 10)
  //  printf ("[%d] median=%f sigma=%f\n", ichanant, median, sigma);

  // now we have the median and sigma for the memory blocks of S1, compute the
  // total power thresholds
  thresholds[ichanant].x = median;
  thresholds[ichanant].y = sigma;
  //if ((iant == 0) && (ichan == 10) && threadIdx.x == 0)
  //  printf ("[%d][%d] median=%f, stddev=%f\n", ichan, iant, median, sigma);
}

void mopsr_test_compute_power_limits (cudaStream_t stream, void * d_s1s, void * d_thresh,
                          unsigned nsums, unsigned nant, unsigned nchan, uint64_t ndat,
                          uint64_t s1_count, unsigned s1_memory)
{
  dim3 blocks_skm (1, nant, nchan);
  unsigned nthreads = 96;
  const unsigned nsigma = 4;

  unsigned valid_memory = s1_memory;
  if (s1_count < s1_memory)
    valid_memory = (unsigned) s1_count;

  fprintf (stderr, "test_compute_power_limits: d_s1s=%p d_thresh=%p\n", d_s1s, d_thresh);
  fprintf (stderr, "test_compute_power_limits: nant=%u nchan=%u ndat=%lu\n", nant, nchan, ndat);
  fprintf (stderr, "test_compute_power_limits: nsums=%u nmemory=%u nsigma=%u\n", nsums, valid_memory, nsigma);

  // re-use d_in for the total power thresholds [FS]
  mopsr_compute_power_limits_kernel<<<blocks_skm,nthreads,0,stream>>>((float *) d_s1s, 
                  (cuFloatComplex *) d_thresh, nsums, valid_memory, nsigma, 0);

  check_error_stream("mopsr_compute_power_limits_kernel", stream);
}




//
// take the S1 and S2 values in sums.x and sums.y that were computed 
//  from M samples, and integrate of nsums blocks to
// compute a sk mask and zap
//
__global__ void mopsr_skdetect_kernel (float * s1s, float * s2s, cuFloatComplex * power_thresholds,
                                       int8_t * mask, float * sigmas, 
                                       unsigned nchan_sum, unsigned sk_nsigma,
                                       unsigned nsums, unsigned M, unsigned nval_per_thread, 
                                       unsigned nsamp_per_thread, uint64_t ndat)
                                       
{
  // zap mask for each set of M samples
  extern __shared__ int8_t smask_det[];

  // maximum to be 16384 samples (20.97152 ms)
  unsigned sk_idx_max = 16;

  // 3 sigma
  const float sk_low[20]  = { 0, 0, 0, 0, 0,
                              0.387702, 0.492078, 0.601904, 0.698159, 0.775046,
                              0.834186, 0.878879, 0.912209, 0.936770, 0.954684,
                              0.967644, 0.976961, 0.983628, 0.988382, 0.991764 };
  const float sk_high[20] = { 0, 0, 0, 0, 0,
                              2.731480, 2.166000, 1.762970, 1.495970, 1.325420,
                              1.216950, 1.146930, 1.100750, 1.069730, 1.048570,
                              1.033980, 1.023850, 1.016780, 1.011820, 1.008340 };


  // 4 sigma
/*
  const float sk_low[20]  = { 0, 0, 0, 0, 0,
                              0.274561, 0.363869, 0.492029, 0.613738, 0.711612,
                              0.786484, 0.843084, 0.885557, 0.917123, 0.940341,
                              0.957257, 0.969486, 0.978275, 0.984562, 0.989046 };
  const float sk_high[20] = { 0, 0, 0, 0, 0,
                              4.27587, 3.11001, 2.29104, 1.784, 1.48684,
                              1.31218, 1.20603, 1.13893, 1.0951, 1.06577,
                              1.0458, 1.03204, 1.02249, 1.01582, 1.01115 };
*/

  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned nchan = gridDim.z;
  const unsigned ichanant = (ichan * nant) + iant;


  // initialize zap mask to 0
  for (unsigned i=0; i<nchan_sum; i++)
  {
    unsigned idx = i * nsums + threadIdx.x;
    for (unsigned ival=0; ival<nval_per_thread; ival++)
    {
      if (idx < nsums * nchan_sum)
      {
        smask_det[idx] = 0;
        idx += blockDim.x;
      }
    }
  }

  __syncthreads();

  const unsigned log2_M = (unsigned) log2f (M);

  // 1 standard deviation for the input data, 0 indicates not value yet computed
  float sigma = sigmas[ichanant];
  float s1_thread = 0;
  int s1_count = 0;

  // sums data stored as FST
  s1s += (ichanant * nsums);
  s2s += (ichanant * nsums);

  float sk_estimate;

  const float upper_power_thresh = power_thresholds[ichanant].x + (3 * power_thresholds[ichanant].y);
  const float lower_power_thresh = power_thresholds[ichanant].x - (3 * power_thresholds[ichanant].y);

  unsigned idx = threadIdx.x;

  //sk_idx_max = log2_M + 1;
  for (unsigned ival=0; ival<nval_per_thread; ival++)
  {
    if (idx < nsums)
    {
      for (unsigned sk_idx = log2_M; sk_idx < sk_idx_max; sk_idx ++)
      {
        unsigned powers_to_add = sk_idx - log2_M;
        unsigned to_add = (unsigned) exp2f(powers_to_add);

        if (idx + to_add <= nsums)
        {
          const float m = (float) (M * to_add);
          const float m_fac = (m + 1) / (m - 1);
          unsigned cdx = idx;
          float sk_avg = 0;

          for (unsigned i=ichan; i<ichan+nchan_sum; i++)
          {
            if (i < nchan)
            {
              float s1 = 1e-10;
              float s2 = 1e-10;

              for (unsigned ichunk=0; ichunk < to_add; ichunk++)
              {
                s1 += s1s[cdx + ichunk];
                s2 += s2s[cdx + ichunk];
              }

              sk_estimate = m_fac * (m * (s2 / (s1 * s1)) - 1);
              sk_avg += sk_estimate;

              if (i == ichan)
              {
                if ((sk_estimate < sk_low[sk_idx]) || (sk_estimate > sk_high[sk_idx]))
                {
                  for (unsigned ichunk=0; ichunk < to_add; ichunk++)
                  {
                    smask_det[idx+ichunk] = (int8_t) 1;
                  }
                }
                else
                {
                  if (sk_idx == log2_M)
                  {
                    if ((s1 > upper_power_thresh) || (s1 < lower_power_thresh))
                      smask_det[idx] = 3;
                    else
                    {
                      s1_thread += s1;
                      s1_count++;
                    }
                  }
                }
              }
            }
            cdx += nant * nsums;
          }

          if (ichan + nchan_sum < nchan)
          {
            float mu2 = (4 * m * m) / ((m-1) * (m + 2) * (m + 3));
            float one_sigma_idat = sqrtf(mu2 / nchan_sum);
            float upper = 1 + (sk_nsigma * one_sigma_idat);
            float lower = 1 - (sk_nsigma * one_sigma_idat);
            sk_avg /= nchan_sum;

            if ((sk_avg < lower) || (sk_avg > upper))
            {
              cdx = idx;
              for (unsigned i=0; i<nchan_sum; i++)
              {
                for (unsigned ichunk=0; ichunk < to_add; ichunk++)
                {
                  smask_det[cdx+ichunk] = 2;
                }
                cdx += nsums;
              }
            }
          }
        }
      }
      idx += blockDim.x;
    }
  }

  // compute the s1 sum across the entire block

  // since s1 will have twice the variance of the Re/Im components, / 2
  s1_thread /= (2 * M);

  // compute the sum of the sums[].x for all the block
  s1_thread = blockReduceSumF (s1_thread);
  s1_count = blockReduceSumI (s1_count);

  // sync here to be sure the smask is now updated
  __syncthreads();

  if (threadIdx.x == 0)
  {
    sigma = 0;
    if (s1_count > 0)
       sigma = sqrtf (s1_thread / s1_count);
    sigmas[ichanant] = sigma;
  }

  // now write out the SK mask to gmem
  for (unsigned i=0; i < nchan_sum; i++)
  {
    if ((ichan + i) < nchan)
    {
      unsigned odx = (((ichan + i) * nant) + iant) * nsums + threadIdx.x;
      unsigned sdx = i * nsums + threadIdx.x;
      //unsigned odx = (ichanant * nsums) + threadIdx.x;
      //unsigned sdx = threadIdx.x;
      for (unsigned ival=0; ival<nval_per_thread; ival++)
      {
        if ((sdx < nchan_sum * nsums) && (smask_det[sdx] > 0))
        {
          //if (ichan == 19 && iant == 0)
            //printf ("[%d][%d] ichan=%d odx=%u sdx=%u smaskval=%u\n", blockIdx.x, threadIdx.x, ichan, odx, sdx, smask_det[sdx]);

          //if (smask_det[sdx] > 1)
          //  printf ("[%d][%d][%d] odx=%u sdx=%u smaskval=%u\n", blockIdx.x, threadIdx.x, i, odx, sdx, smask_det[sdx]);
          mask[odx] = smask_det[sdx];
        }
        sdx += blockDim.x;
        odx += blockDim.x;
      }
    }
  }
}

void mopsr_test_skdetect (cudaStream_t stream, void * d_s1s, void * d_s2s, void * d_thresh, 
                          void * d_mask, void * d_sigmas, unsigned nsums, unsigned nant, 
                          unsigned nchan, uint64_t ndat)
{
  unsigned M = 1024;
  unsigned ndim = 2;
  //////////////////////////////////////////////////////////
  // mask the input data
  dim3 blocks (1, nant, nchan);
  unsigned nthreads = 1024;
  unsigned nval_per_thread = 1;
  if (nsums > nthreads)
  {
    nval_per_thread = nsums / nthreads;
    if (nsums % nthreads)
      nval_per_thread++;
  }
  else
    nthreads = nsums;

  unsigned nsamp_per_thread = (M  * ndim) / nthreads;
  if (M % nthreads)
    nsamp_per_thread++;

  unsigned nchan_sum = 5;
  unsigned sk_nsigma = 4;

  size_t shm_bytes = nchan_sum * nsums * sizeof(uint8_t);
  size_t mask_size = nsums * nchan * nant * sizeof(uint8_t);
  cudaMemsetAsync (d_mask, 0, mask_size, stream);
  cudaStreamSynchronize(stream);

  fprintf (stderr, "mopsr_skdetect_kernel: blocks.x=%d, blocks.y=%d, blocks.z=%d\n", blocks.x, blocks.y, blocks.z);
  fprintf (stderr, "mopsr_skdetect_kernel: nthreads=%u shm_bytes=%ld\n", nthreads, shm_bytes);
  fprintf (stderr, "mopsr_skdetect_kernel: d_s1s=%p, d_s2s=%p, d_masks=%p, nsums=%u M=%u, nval_per_thread=%u, nsamp_per_thread=%u ndat=%lu\n", d_s1s, d_s2s, d_mask, nsums, M, nval_per_thread, nsamp_per_thread, ndat);

  mopsr_skdetect_kernel<<<blocks, nthreads, shm_bytes, stream>>>((float *) d_s1s, (float *) d_s2s, (cuFloatComplex *) d_thresh, (int8_t *) d_mask,
                      (float *) d_sigmas, nchan_sum, sk_nsigma, nsums, M, nval_per_thread, nsamp_per_thread, ndat);

  check_error_stream("mopsr_skdetect_kernel", stream);
}

//
// take the S1 and S2 values in sums.x and sums.y that were computed 
//  from M samples, and integrate of nsums blocks to
// compute a sk mask and zap
//
__global__ void mopsr_skmask_kernel_new (float * in, int8_t * out, int8_t * mask, 
                                         curandState * rstates, float * sigmas,
                                         unsigned nsums, unsigned M, unsigned nval_per_thread, 
                                         unsigned nsamp_per_thread, uint64_t ndat)
{
  const unsigned iant = blockIdx.y;
  const unsigned nant = gridDim.y;
  const unsigned ichan = blockIdx.z;
  const unsigned ichanant = (ichan * nant) + iant;

  const unsigned id = ichanant * blockDim.x + threadIdx.x;
  curandState localState = rstates[id];

  float sigma = sigmas[ichanant];
  int8_t * chanant_mask = mask + (ichanant * nsums);

  // Jenet & Anderson 1998, 6-bit (2-bits for RFI) spacing
  //const float spacing = 0.09925;    // 6-bit
  const float spacing = 0.02957;      // 8-bit

  // dont do antenna scaling here anymore for the moment, unless it is zero
  const float ant_scale = d_ant_scales_delay[iant];
  float data_factor = ant_scale / (sigma * spacing);
  const float rand_factor = ant_scale / spacing;

  // now we want to zap all blocks of input that have an associated mask
  // note that this kernel has only 1 block, with blockDim.x threads that may not match
  const unsigned ndim = 2;
  const unsigned nval_per_sum = M * ndim;
  unsigned block_offset = (ichanant * ndat * ndim);
  float * indat = in + block_offset;
  int8_t * outdat = out + block_offset;

  // foreach block of M samples (i.e. 1 sum)
  for (unsigned isum=0; isum<nsums; isum++)
  {
    // use the threads to write out the int8_t scaled value (or zapped value)
    // back to global memory. There are 2 * M values to write each iteration
    unsigned idx = threadIdx.x;

//#define SHOW_MASK
#ifdef SHOW_MASK
    for (unsigned isamp=0; isamp<nsamp_per_thread; isamp++)
    {
      if (idx < nval_per_sum)
      {
        //if (ichan == 19 && iant == 0 && threadIdx.x == 0 && isamp == 0)
        //  printf ("ichan=%d iant=%d chanant_mask[%d]=%u\n", ichan, iant, isum, chanant_mask[isum]);
        outdat[idx] = (int8_t) chanant_mask[isum];
      }
      idx += blockDim.x;
    }
#else
    if (chanant_mask[isum] > 0)
    {
      for (unsigned isamp=0; isamp<nsamp_per_thread; isamp++)
      {
        if (idx < nval_per_sum)
        {
          const float inval = curand_normal (&localState);
          outdat[idx] = (int8_t) rintf(inval * rand_factor);
          //outdat[idx] = 0;
        }
        idx += blockDim.x;
      }
    }
    else
    {
      for (unsigned isamp=0; isamp<nsamp_per_thread; isamp++)
      {
        if (idx < nval_per_sum)
        {
          outdat[idx] = (int8_t) rintf (indat[idx] * data_factor - 0.5);
          //outdat[idx] = (int8_t) rintf (indat[idx] - 0.5);
        }
        idx += blockDim.x;
      }
    }
#endif

    outdat += ndim * M;
    indat += ndim * M;
  }

  rstates[id] = localState;
}

void mopsr_test_skmask (cudaStream_t stream, void * d_in, void * d_out, void * d_mask, void * d_rstates, void * d_sigmas, unsigned nsums, unsigned nchan, unsigned nant, uint64_t ndat)
{
  unsigned M = 1024;
  unsigned ndim = 2;
  //////////////////////////////////////////////////////////
  // mask the input data
  dim3 blocks (1, nant, nchan);
  unsigned nthreads = 1024;
  unsigned nval_per_thread = 1;
  if (nsums > nthreads)
  {
    nval_per_thread = nsums / nthreads;
    if (nsums % nthreads)
      nval_per_thread++;
  }
  else
    nthreads = nsums;

  unsigned nsamp_per_thread = (M  * ndim) / nthreads;
  if (M % nthreads)
    nsamp_per_thread++;

  size_t shm_bytes = 0;

  fprintf (stderr, "mopsr_skmask_kernel: blocks.x=%d, blocks.y=%d, blocks.z=%d\n", blocks.x, blocks.y, blocks.z);
  fprintf (stderr, "mopsr_skmask_kernel: nthreads=%u shm_bytes=%ld\n", nthreads, shm_bytes);
  fprintf (stderr, "mopsr_skmask_kernel: d_in=%p d_out=%p, d_mask=%p, nsums=%u M=%u, nval_per_thread=%u, nsamp_per_thread=%u ndat=%lu\n", d_in, d_out, d_in, nsums, M, nval_per_thread, nsamp_per_thread, ndat);

  mopsr_skmask_kernel_new<<<blocks, nthreads, shm_bytes, stream>>>((float *) d_in, (int8_t *) d_out,
                (int8_t *) d_mask, (curandState *) d_rstates, (float *) d_sigmas,
                nsums, M, nval_per_thread, nsamp_per_thread, ndat);

  check_error_stream("mopsr_skmask_kernel_new", stream);
}


__global__ void mopsr_srand_setup_kernel (unsigned long long seed, curandState *states)
{
  unsigned id = blockIdx.x * blockDim.x + threadIdx.x;

  // more efficient, but less random...
  //curand_init( (seed << 20) + id, 0, 0, &states[id]);

  curand_init (seed, id, 0, &states[id]);
}

void mopsr_init_rng (cudaStream_t stream, unsigned long long seed, unsigned nrngs, void * states)
{
  unsigned nthreads = 1024;
  unsigned nblocks = nrngs / nthreads;

//#if _GDEBUG
  fprintf (stderr, "rand_setup: nblocks=%u nthreads=%u\n", nblocks, nthreads);
//#endif

  mopsr_srand_setup_kernel<<<nblocks, nthreads, 0, stream>>>(seed, (curandState *) states);

#if _GDEBUG
  check_error_stream("mopsr_srand_setup_kernel", stream);
#endif
}


// out-of-place
//
void mopsr_delay_fractional_sk_scale (cudaStream_t stream, 
     void * d_in, void * d_out, void * d_fbuf, void * d_rstates,
     void * d_sigmas, void * d_mask, float * d_delays, void * d_s1s, 
     void * d_s2s, void * d_thresh, float * h_fringes, float * h_delays_ds, 
     float * h_fringe_coeffs_ds, size_t fringes_size, uint64_t nbytes, 
     unsigned nchan, unsigned nant, unsigned ntap, 
     unsigned s1_memory, uint64_t s1_count)
{
  const unsigned ndim = 2;
  const uint64_t ndat = nbytes / (nchan * nant * ndim);
  const unsigned half_ntap = ntap / 2;

  // number of threads that actually load data
  unsigned nthread_load = 1024;
  if (ndat < nthread_load)
    nthread_load = ndat;
  unsigned nthread_run  = nthread_load - (2 * half_ntap);

  // need shared memory to load the ntap coefficients + nthread_load data points
  const size_t   sdata_bytes = (nthread_load * ndim + ntap) * sizeof(float);

  dim3 blocks (ndat / nthread_run, nant, nchan);
  if (ndat % nthread_load)
    blocks.x++;

  //fprintf (stderr, "delay_fractional_sk_scale: fringes_size=%ld\n", fringes_size);

  cudaMemcpyToSymbolAsync (fringe_coeffs, (void *) h_fringes, fringes_size, 0, cudaMemcpyHostToDevice, stream);
#ifdef USE_DS_DELAYS
  cudaMemcpyToSymbolAsync (delays_ds, (void *) h_delays_ds, fringes_size, 0, cudaMemcpyHostToDevice, stream);
  cudaMemcpyToSymbolAsync (fringe_coeffs_ds, (void *) h_fringe_coeffs_ds, fringes_size, 0, cudaMemcpyHostToDevice, stream);
#endif
  cudaStreamSynchronize(stream);

#if _GDEBUG
  fprintf (stderr, "delay_fractional_sk_scale: bytes=%lu ndat=%lu sdata_bytes=%ld\n", nbytes, ndat, sdata_bytes);
  fprintf (stderr, "delay_fractional_sk_scale: blocks.x=%d, blocks.y=%d, blocks.z=%d\n", blocks.x, blocks.y, blocks.z);
  fprintf (stderr, "delay_fractional_sk_scale: nthread_load=%d nthread_run=%d ntap=%d\n", nthread_load, nthread_run, ntap);
#endif

  const unsigned chan_stride = nant * ndat;
  const unsigned ant_stride  = ndat;

  mopsr_delay_fractional_float_kernel<<<blocks, nthread_load, sdata_bytes, stream>>>((int16_t *) d_in, 
                (cuFloatComplex *) d_fbuf, (float *) d_delays, nthread_run, 
                ndat, chan_stride, ant_stride, ntap);

#if _GDEBUG
  check_error_stream("mopsr_delay_fractional_float_kernel", stream);
#endif

  ///////////////////////////////////////////////////////// 
  // Calculate kurtosis sums

  // TODO fix this configuration
  unsigned M = 1024;
  unsigned nthreads = 1024;
  const uint64_t ndat_sk = ndat - (ntap - 1);

  unsigned nval_per_thread = 1;
  if (M > nthreads)
    nval_per_thread = M / nthreads;
  else
    nthreads = M;

  // each block is a single integration
  //size_t shm_bytes = M * ndim * sizeof(float);
  size_t shm_bytes = 0;

  ///////////////////////////////////////////////////////
  // compute the means of each antenna / channel
  //blocks.x = 1;
  //unsigned nval_per_thread_mean = ndat_sk / 1024;
  //mopsr_measure_means_kernel <<<blocks, nthreads, shm_bytes, stream>>>( (cuFloatComplex *) d_fbuf, 
  //          (cuFloatComplex *) d_means, nval_per_thread_mean, ndat_sk);

  blocks.x = ndat_sk / M;
#if _GDEBUG
  fprintf (stderr, "mopsr_skcompute_kernel: bytes=%lu ndat=%lu shm_bytes=%ld\n", nbytes, ndat_sk, shm_bytes);
  fprintf (stderr, "mopsr_skcompute_kernel: blocks.x=%d, blocks.y=%d, blocks.z=%d, nthreads=%u\n", blocks.x, blocks.y, blocks.z, nthreads);
  fprintf (stderr, "mopsr_skcompute_kernel: d_fbuf=%p d_in=%p, nval_per_thread=%u, ndat_sk=%lu\n", d_fbuf, d_in, nval_per_thread, ndat_sk);
#endif

  unsigned s1_idx = (unsigned) ((s1_count-1) % s1_memory);
  float * d_s1s_curr = ((float * ) d_s1s) + (s1_idx * blocks.x * nchan * nant);

  // reuse d_in as a temporary work buffer for the S1 and S2 sums
  //mopsr_skcompute_kernel<<<blocks, nthreads, shm_bytes, stream>>>( (cuFloatComplex *) d_fbuf, (cuFloatComplex *) d_in, nval_per_thread, ndat_sk);
  mopsr_skcompute_kernel<<<blocks, nthreads, shm_bytes, stream>>>( (cuFloatComplex *) d_fbuf, (float *) d_s1s_curr, (float *) d_s2s, nval_per_thread, ndat_sk);

#if _GDEBUG
  check_error_stream("mopsr_skcompute_kernel", stream);
#endif

  //
  unsigned nsums = blocks.x;
  dim3 blocks_skm (1, nant, nchan);

  /////////////////////////////////////////////////////////
  // compute the power limits based on the S1 and S2 values
  // this is required until we have an adaptive sorting method... (sigh cub)
#ifdef _GDEBUG
  fprintf (stderr, "ndat=%lu ndat_sk=%lu nsums=%u\n", ndat, ndat_sk, nsums);
  //fprintf (stderr, "d_s1s_curr=%p d_s1s=%p offset=%d\n", (void *) d_s1s_curr, (void *) d_s1s, int(d_s1s_curr - d_s1s));
  fprintf (stderr, "s1_idx=%u s1_count=%u\n", s1_idx, s1_count);  
#endif

  nthreads = nsums;
  const unsigned nsigma = 3;
  unsigned valid_memory = s1_memory;
  if (s1_count < s1_memory)
    valid_memory = (unsigned) s1_count;

  if (nsums == 96)
  {
    mopsr_compute_power_limits_kernel<<<blocks_skm,nthreads,0,stream>>>((float *) d_s1s, (cuFloatComplex *) d_thresh, nsums, valid_memory, nsigma, s1_count % s1_memory);
  }

#if _GDEBUG
  check_error_stream("mopsr_compute_power_limits_kernel", stream);
#endif

  //////////////////////////////////////////////////////////
  // mask the input data
  nthreads = 1024;

  nval_per_thread = 1;
  if (nsums > nthreads)
  {
    nval_per_thread = nsums / nthreads;
    if (nsums % nthreads)
      nval_per_thread++;
  }
  else
    nthreads = nsums;

  unsigned nsamp_per_thread = (M  * ndim) / nthreads;
  if (M % nthreads)
    nsamp_per_thread++;

  unsigned nchan_sum = 5;
  unsigned sk_nsigma = 4;

  shm_bytes = nchan_sum * nsums * sizeof(uint8_t);
  size_t mask_size = nsums * nchan * nant * sizeof(uint8_t);
  cudaMemsetAsync (d_mask, 0, mask_size, stream);
  cudaStreamSynchronize(stream);

#if _GDEBUG
  fprintf (stderr, "mopsr_skdetect_kernel: blocks_skm.x=%d, blocks_skm.y=%d, blocks_skm.z=%d\n", blocks_skm.x, blocks_skm.y, blocks_skm.z);
  fprintf (stderr, "mopsr_skdetect_kernel: nthreads=%u shm_bytes=%ld\n", nthreads, shm_bytes);
  fprintf (stderr, "mopsr_skdetect_kernel: d_fbuf=%p d_out=%p, d_in=%p, nsums=%u M=%u, nval_per_thread=%u, nsamp_per_thread=%u ndat_sk=%lu\n", d_fbuf, d_out, d_thresh, nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);
#endif

  //mopsr_skdetect_kernel<<<blocks_skm, nthreads, shm_bytes, stream>>>((cuFloatComplex *) d_in, (int8_t *) d_mask,
  //                    (float *) d_sigmas, nchan_sum, sk_nsigma, nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);
  mopsr_skdetect_kernel<<<blocks_skm, nthreads, shm_bytes, stream>>>(d_s1s_curr, (float *) d_s2s, (cuFloatComplex *) d_thresh, (int8_t *) d_mask,
                      (float *) d_sigmas, nchan_sum, sk_nsigma, nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);

#if _GDEBUG
  check_error_stream("mopsr_skdetect_kernel", stream);
#endif

  shm_bytes = nchan_sum * nsums;

#if _GDEBUG
  fprintf (stderr, "mopsr_skmask_kernel: blocks_skm.x=%d, blocks_skm.y=%d, blocks_skm.z=%d\n", blocks_skm.x, blocks_skm.y, blocks_skm.z);
  fprintf (stderr, "mopsr_skmask_kernel: nthreads=%u shm_bytes=%ld\n", nthreads, shm_bytes);
  fprintf (stderr, "mopsr_skmask_kernel: d_fbuf=%p d_out=%p, d_in=%p, nsums=%u M=%u, nval_per_thread=%u, nsamp_per_thread=%u ndat_sk=%lu\n", d_fbuf, d_out, d_in, nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);
#endif

  shm_bytes = 0;
  mopsr_skmask_kernel_new<<<blocks_skm, nthreads, shm_bytes, stream>>>((float *) d_fbuf, (int8_t *) d_out, 
                (int8_t *) d_mask, (curandState *) d_rstates, (float *) d_sigmas, 
                nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);

#if _GDEBUG
  check_error_stream("mopsr_skmask_kernel_new", stream);
#endif
/*

  shm_bytes = nsums;
  fprintf (stderr, "mopsr_skmask_kernel: blocks_skm.x=%d, blocks_skm.y=%d, blocks_skm.z=%d\n", blocks_skm.x, blocks_skm.y, blocks_skm.z);
  fprintf (stderr, "mopsr_skmask_kernel: nthreads=%u shm_bytes=%ld\n", nthreads, shm_bytes);
  fprintf (stderr, "mopsr_skmask_kernel: d_fbuf=%p d_out=%p, d_in=%p, nsums=%u M=%u, nval_per_thread=%u, nsamp_per_thread=%u ndat_sk=%lu\n", d_fbuf, d_out, d_in, nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);

  mopsr_skmask_kernel<<<blocks_skm, nthreads, shm_bytes, stream>>>((float *) d_fbuf, (int8_t *) d_out, 
                (cuFloatComplex *) d_in, (curandState *) d_rstates, (float *) d_sigmas, 
                nsums, M, nval_per_thread, nsamp_per_thread, ndat_sk);
#if _GDEBUG
  check_error_stream("mopsr_skmask_kernel", stream);
#endif
*/
}

// wrapper for getting curandState_t size
size_t mopsr_curandState_size()
{
  return sizeof(curandState_t);
}