#include "scale.cuh"
#include "device.cuh"

static __global__ void scale_f32(const float * x, float * dst, const float scale, const int k) {
    const int i = blockDim.x*blockIdx.x + threadIdx.x;

    if (i >= k) {
        return;
    }

    dst[i] = scale * x[i];
}

static void scale_f32_cuda(const float * x, float * dst, const float scale, const int k, cudaStream_t stream) {
    const int num_blocks = (k + CUDA_SCALE_BLOCK_SIZE - 1) / CUDA_SCALE_BLOCK_SIZE;
    scale_f32<<<num_blocks, CUDA_SCALE_BLOCK_SIZE, 0, stream>>>(x, dst, scale, k);
}

void ggml_cuda_op_scale(ggml_backend_cuda_context & ctx, ggml_tensor * dst) {
    const ggml_tensor * src0 = dst->src[0];
    const float * src0_d = (const float *)src0->data;
    float * dst_d = (float *)dst->data;
    cudaStream_t stream = ctx.stream();

    GGML_ASSERT(src0->type == GGML_TYPE_F32);
    GGML_ASSERT( dst->type == GGML_TYPE_F32);

    float scale;
    memcpy(&scale, dst->op_params, sizeof(scale));

    const int64_t total = ggml_nelements(src0);

    // query the device’s max 1D grid size:
    const cudaDeviceProp prop = getCachedDeviceProperties();

    // maximum elements per launch = maxGridSize[0] * blockDim.x,
    // still also clamp to INT_MAX for the kernel’s 32-bit k parameter:
    const int64_t max_by_grid = int64_t(prop.maxGridSize[0]) * CUDA_SCALE_BLOCK_SIZE;
    const int64_t max_chunk = std::min<int64_t>(
        max_by_grid,
        std::numeric_limits<int>::max() - CUDA_SCALE_BLOCK_SIZE);

    // launch in chunks of at most INT_MAX elements to stay within grid size
    int64_t offset = 0;
    while (offset < total) {
        int chunk = static_cast<int>(std::min(max_chunk, total - offset));
        scale_f32_cuda(src0_d + offset, dst_d + offset, scale, chunk, stream);
        offset += chunk;
    }

    // check for any launch errors
    CUDA_CHECK(cudaGetLastError());
}

