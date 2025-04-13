#include "pe.h"
// ceil(image_size / (blockDim.x * gridDim.x * blockDim.y * gridDim.y))
// = ceil(image_size / (NUM_THREADS_PER_BLOCK_PER_DIM * NUM_THREADS_PER_BLOCK_PER_DIM * MAX_BLOCK_SIZE * MAX_BLOCK_SIZE))
#define MAX_NUM_PIXELS_PER_THREAD 8

__device__ __host__ bool getBitAt(uint8_t pixel_value, size_t bit_num) {
    if (bit_num >= 8) {
        printf("PD called more times than number of bits in image");
        return 0;
    } else {
        return (pixel_value & (1 << bit_num)) >> bit_num; 
    }
}

__device__ bool getNeighbourValue(
    cuda::atomic<int, cuda::thread_scope_device>* neighbour_program_counter,
    size_t neighbour_pc,
    bool* neighbour_shared_values,
    size_t neighbour_index,
    size_t num_shared_neighbours,
    size_t shared_neighbour_value
) {
    // while (neighbour_program_counter[neighbour_index].load(cuda::std::memory_order_acquire) < neighbour_pc);
    return neighbour_shared_values[neighbour_index * num_shared_neighbours + shared_neighbour_value - 1];
}

// Note: MEMORY_SIZE_IN_BITS
constexpr int MEMORY_SIZE_IN_BITS = 24;

__device__ bool getInstructionInputValue(
    InputC inputc,
    bool memory[][MEMORY_SIZE_IN_BITS],
    uint8_t* image,
    size_t pd_bit,
    bool* pd_increment,
    int64_t x,
    int64_t y,
    size_t image_x_dim,
    size_t image_y_dim,
    size_t image_size,
    size_t offset,
    cuda::atomic<int, cuda::thread_scope_device>* neighbour_program_counter,
    bool* neighbour_shared_values,
    size_t neighbour_update_pc,
    size_t num_shared_neighbours,
    size_t shared_neighbour_value,
    bool use_shared_memory,
    bool* neighbour_shared_values_cache,
    size_t num_pixel
) {
    bool input_value = false;
    switch (inputc.input.inputKind) {
        case InputKind::Address: input_value = memory[num_pixel][inputc.input.address]; break;
        case InputKind::ZeroValue: input_value = false; break;
        case InputKind::PD:
            input_value = getBitAt(image[offset], pd_bit);
            *pd_increment = true;
            break;
        case InputKind::Up:
            if (y - 1 >= 0) {
                int64_t up_index = offset - image_x_dim;
                input_value = getNeighbourValue(
                    neighbour_program_counter,
                    neighbour_update_pc,
                    neighbour_shared_values,
                    up_index,
                    num_shared_neighbours,
                    shared_neighbour_value
                );
            } else {
                input_value = false;
            }
            break;
        case InputKind::Down:
            if (y + 1 < image_y_dim) {
                int64_t down_index = offset + image_x_dim;
                input_value = getNeighbourValue(
                    neighbour_program_counter,
                    neighbour_update_pc,
                    neighbour_shared_values,
                    down_index,
                    num_shared_neighbours,
                    shared_neighbour_value
                );
            } else {
                input_value = false;
            }
            break;
        case InputKind::Right:
            if (x + 1 < image_x_dim) {
                int64_t right_index = offset + 1;
                input_value = getNeighbourValue(
                    neighbour_program_counter,
                    neighbour_update_pc,
                    neighbour_shared_values,
                    right_index,
                    num_shared_neighbours,
                    shared_neighbour_value
                );
            } else {
                input_value = false;
            }
            break;
        case InputKind::Left:
            if (x - 1 >= 0) {
                int64_t left_index = offset - 1;
                input_value = getNeighbourValue(
                    neighbour_program_counter,
                    neighbour_update_pc,
                    neighbour_shared_values,
                    left_index,
                    num_shared_neighbours,
                    shared_neighbour_value
                );
            } else {
                input_value = false;
            }
            break;
        default:
            break;
    }
    return (inputc.negated) ? !input_value : input_value;
}

__global__ void processingElemKernel(
    size_t num_instructions,
    uint8_t* image,
    bool* neighbour_shared_values,
    cuda::atomic<int, cuda::thread_scope_device>* neighbour_program_counter,
    bool* external_values,
    size_t image_size,
    size_t image_x_dim,
    size_t image_y_dim,
    size_t num_outputs,
    size_t num_shared_neighbours,
    size_t* debug_output,
    size_t num_debug_outputs,
    size_t vliw_width,
    bool use_shared_memory,
    bool is_pipelining
) {
    size_t x = threadIdx.x + blockIdx.x * blockDim.x;
    size_t y = threadIdx.y + blockIdx.y * blockDim.y;
    size_t offset = x + y * blockDim.x * gridDim.x;
    // Note: PIPELINE_WIDTH
    const size_t PIPELINE_WIDTH = 3;
    // Note: MAX_VLIW_WIDTH
    const size_t MAX_VLIW_WIDTH = 4;
    // Note: MEMORY_SIZE_IN_BITS
    const size_t MEMORY_SIZE_IN_BITS = 24;
    
    if (offset < image_size) {
        cg::grid_group grid = cg::this_grid();
        
        // image_x, image_y in image space
        // x, y in thread/block space
        __shared__ bool neighbour_shared_values_cache[NUM_THREADS_PER_BLOCK_PER_DIM][NUM_THREADS_PER_BLOCK_PER_DIM];
        // if (use_shared_memory) {
        //     neighbour_shared_values_cache[threadIdx.y][threadIdx.x] = false;
        //     __syncthreads();
        // }

        bool memory[MAX_NUM_PIXELS_PER_THREAD][MEMORY_SIZE_IN_BITS];
        for (size_t j = 0; j < MAX_NUM_PIXELS_PER_THREAD; j++) {
            for (size_t i = 0; i < MEMORY_SIZE_IN_BITS; i++) {
                memory[j][i] = false;
            }
        }
        bool carry_register[MAX_NUM_PIXELS_PER_THREAD][MAX_VLIW_WIDTH];
        for (size_t j = 0; j < MAX_NUM_PIXELS_PER_THREAD; j++) {
            for (size_t i = 0; i < MAX_VLIW_WIDTH; i++) {
                carry_register[j][i] = false;
            }
        }
        bool result_values[MAX_NUM_PIXELS_PER_THREAD][MAX_VLIW_WIDTH][PIPELINE_WIDTH];
        for (size_t k = 0; k < MAX_NUM_PIXELS_PER_THREAD; k++) {
            for (size_t i = 0; i < MAX_VLIW_WIDTH; i++) {
                for (size_t j = 0; j < PIPELINE_WIDTH; j++) {
                    result_values[k][i][j] = false;
                }
            }
        }
        size_t pd_bit = 0;
        bool pd_increment = false;
        size_t output_number = 0;

        // updated when we write to neighbour
        size_t neighbour_update_pc = 0;

        // shared_neighbour_value is the index of the shared neighbour value
        bool shared_neighbour_value_increment = false;
        size_t shared_neighbour_value = 0;

        bool output_number_increment = false;

        size_t pc = 1;

        bool contains_neighbour_sharing = false;

        for (size_t i = 0; (i < num_instructions && !is_pipelining) || (i < num_instructions + PIPELINE_WIDTH - 1 && is_pipelining); i++) {
            size_t offset = x + y * blockDim.x * gridDim.x;
            size_t image_x = offset % image_x_dim;
            size_t image_y = offset / image_x_dim;
            for (size_t num_pixel = 0; num_pixel < MAX_NUM_PIXELS_PER_THREAD && offset < image_size; num_pixel++) {
                if (i < num_instructions) {
                    for (size_t j = 0; j < vliw_width; j++) { 
                        const Instruction instruction = ((Instruction *) dev_instructions)[i * vliw_width + j];
                        pc = i + 1;
                        if (instruction.isNop) {
                            continue;
                        }
                        bool carryval = false;
                        switch (instruction.carry) {
                            case Carry::CR: carryval = carry_register[num_pixel][j]; break;
                            case Carry::One: carryval = true; break;
                            case Carry::Zero: carryval = false; break;
                        }
                        bool input_one = getInstructionInputValue(
                            instruction.input1,
                            memory,
                            image,
                            pd_bit,
                            &pd_increment,
                            image_x,
                            image_y,
                            image_x_dim,
                            image_y_dim,
                            image_size,
                            offset,
                            neighbour_program_counter,
                            neighbour_shared_values,
                            neighbour_update_pc,
                            num_shared_neighbours,
                            shared_neighbour_value,
                            use_shared_memory,
                            (bool *) neighbour_shared_values_cache,
                            num_pixel
                        );
                        bool input_two = getInstructionInputValue(
                            instruction.input2,
                            memory,
                            image,
                            pd_bit,
                            &pd_increment,
                            image_x,
                            image_y,
                            image_x_dim,
                            image_y_dim,
                            image_size,
                            offset,
                            neighbour_program_counter,
                            neighbour_shared_values,
                            neighbour_update_pc,
                            num_shared_neighbours,
                            shared_neighbour_value,
                            use_shared_memory,
                            (bool *) neighbour_shared_values_cache,
                            num_pixel
                        );

                        // printf("offset: %lu, instruction: %lu, input_one: %d, carryval: %d, input_two: %d\n", offset, i, input_one, carryval, input_two);
                        
                        // debug_output value = 0 if nop
                        // debug_output[((offset * num_instructions + i) * vliw_width + j) * num_debug_outputs] = input_one;
                        // debug_output[((offset * num_instructions + i) * vliw_width + j) * num_debug_outputs + 1] = input_two;
                        // debug_output[((offset * num_instructions + i) * vliw_width + j) * num_debug_outputs + 2] = carryval;

                        const bool sum = (input_one != input_two) != carryval;
                        const bool carry = (carryval && (input_one != input_two)) || (input_one && input_two);

                        // Assuming can only be two values
                        result_values[num_pixel][j][i % PIPELINE_WIDTH] = (instruction.resultType.value == 's') ? sum : carry;

                        // Interesting choice...
                        if (instruction.carry == Carry::CR) {
                            carry_register[num_pixel][j] = carry;
                        }
                    }
                }

                if (!is_pipelining || (is_pipelining && i >= PIPELINE_WIDTH - 1)) {
                    for (size_t j = 0; j < vliw_width; j++) {
                        const Instruction instruction = 
                        !is_pipelining ?
                        ((Instruction *) dev_instructions)[i * vliw_width + j] :
                        ((Instruction *) dev_instructions)[(i - PIPELINE_WIDTH + 1) * vliw_width + j];
                        if (instruction.isNop) {
                            continue;
                        }
                        size_t resultvalue = 
                        !is_pipelining ?
                        result_values[num_pixel][j][i % PIPELINE_WIDTH] :
                        result_values[num_pixel][j][(i - PIPELINE_WIDTH + 1) % PIPELINE_WIDTH];
                        switch (instruction.result.resultKind) {
                            case ResultKind::Address:
                                memory[num_pixel][instruction.result.address] = resultvalue;
                                break;
                            case ResultKind::Neighbour:
                                neighbour_update_pc = pc;
                                neighbour_shared_values[offset * num_shared_neighbours + shared_neighbour_value] = resultvalue;
                                shared_neighbour_value_increment = true;
                                // neighbour_program_counter[offset].store(pc, cuda::std::memory_order_release);
                                contains_neighbour_sharing = true;
                                break;
                            case ResultKind::External:
                                external_values[num_outputs * offset + output_number] = resultvalue;
                                output_number_increment = true;
                                break;
                        }
                    }
                }
                offset += blockDim.x * gridDim.x * blockDim.y * gridDim.y;
                image_x = offset % image_x_dim;
                image_y = offset / image_x_dim;
            }

            if (pd_increment) {
                pd_bit++;
            }
            pd_increment = false;
            if (shared_neighbour_value_increment) {
                shared_neighbour_value++;
            }
            shared_neighbour_value_increment = false;
            if (contains_neighbour_sharing) {
                grid.sync();
            }
            contains_neighbour_sharing = false;
            if (output_number_increment) {
                output_number++;
            }
            output_number_increment = false;
        }
    }
};
