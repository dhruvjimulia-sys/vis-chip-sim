#ifndef VECTOR_OPS_H
#define VECTOR_OPS_H

#define HANDLE_ERROR(call) { \
    cudaError_t error = call; \
    if (error != cudaSuccess) { \
        fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(error); \
    } \
}

void queryGPUProperties();

#endif