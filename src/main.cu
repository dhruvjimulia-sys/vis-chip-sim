#include <iostream>
#include <chrono>
#include <cuda/atomic>
#include "main.h"
#include "isa.h"
#include "pe.h"
#include "utils/cuda_utils.h"
#include "utils/file_utils.h"
#include "utils/program_utils.h"
#include "powerandarea.h"

__constant__ char dev_instructions[sizeof(Instruction) * MAX_NUM_INSTRUCTIONS];

#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb/stb_image_resize2.h"

uint8_t* transform_image(const char* filename, int new_dimension, int new_bits) {
    int width, height, channels;
    // Check if the file exists
    FILE *file = fopen(filename, "r");
    if (!file) {
        std::cerr << "Error: Could not open file " << filename << std::endl;
        exit(EXIT_SUCCESS);
    } else {
        fclose(file);
    }

    uint8_t* img_data = stbi_load(filename, &width, &height, &channels, 0);
    if (!img_data) {
        return nullptr;
    }

    if (new_bits < 1 || new_bits > 8) {
        stbi_image_free(img_data);
        return nullptr;
    }

    // TODO Make resize automatic
    uint8_t* resized_data = img_data;
    
    // (uint8_t*)malloc(new_dimension * new_dimension * channels);
    // if (!resized_data) {
    //     stbi_image_free(img_data);
    //     return nullptr;
    // }

    // // Resize the image
    // stbir_resize_uint8(img_data, width, height, 0,
    //                    resized_data, new_dimension, new_dimension, 0,
    //                    channels);
    // stbi_image_free(img_data); // Free original image data

    // Convert to grayscale (1 channel)
    uint8_t* gray_data = (uint8_t*)malloc(new_dimension * new_dimension);
    if (!gray_data) {
        free(resized_data);
        return nullptr;
    }

    for (int i = 0; i < new_dimension * new_dimension; ++i) {
        int src_idx = i * channels;
        if (channels >= 3) {
            // Use luminance formula: 0.299*R + 0.587*G + 0.114*B (integer approximation)
            uint8_t r = resized_data[src_idx];
            uint8_t g = resized_data[src_idx + 1];
            uint8_t b = resized_data[src_idx + 2];
            gray_data[i] = static_cast<uint8_t>((r * 299 + g * 587 + b * 114 + 500) / 1000);
        } else {
            gray_data[i] = resized_data[src_idx];
        }
    }
    free(resized_data); 

    // Quantized to required bit depth
    const int max_level = (1 << new_bits) - 1;
    if (max_level > 0) {
        for (int i = 0; i < new_dimension * new_dimension; ++i) {
            gray_data[i] = (gray_data[i] >> (8 - new_bits)) & max_level;
        }
    }

    return gray_data;
}

std::pair<bool *, float> process_image_gpu(Program program, uint8_t* pixels, size_t image_x_dim, size_t image_y_dim, bool use_shared_memory) {
    size_t program_num_outputs = numOutputs(program);
    size_t program_num_shared_neighbours = numSharedNeighbours(program);
    
    // Non-constant memory version
    // Instruction* dev_instructions;
    // size_t instructions_mem_size = sizeof(Instruction) * program.instructionCount * program.vliwWidth;
    // HANDLE_ERROR(cudaMalloc((void **) &dev_instructions, instructions_mem_size));
    // HANDLE_ERROR(cudaMemcpy(dev_instructions, program.instructions, instructions_mem_size, cudaMemcpyHostToDevice));

    size_t instructions_mem_size = sizeof(Instruction) * program.instructionCount * program.vliwWidth;
    HANDLE_ERROR(cudaMemcpyToSymbol(dev_instructions, (void *) program.instructions, instructions_mem_size));

    // read grayscale pixels from image and memcpy to cuda memory
    size_t image_size = image_x_dim * image_y_dim;
    size_t image_mem_size = sizeof(uint8_t) * image_size;
    uint8_t* dev_image;
    HANDLE_ERROR(cudaMalloc((void **) &dev_image, image_mem_size));
    HANDLE_ERROR(cudaMemcpy(dev_image, pixels, image_mem_size, cudaMemcpyHostToDevice));

    // debugging output
    size_t* dev_debug_output = nullptr;
    size_t num_debug_outputs = 3;
    // size_t debug_output_mem_size = sizeof(size_t) * image_size * program.instructionCount * program.vliwWidth * num_debug_outputs;
    // HANDLE_ERROR(cudaMalloc((void **) &dev_debug_output, debug_output_mem_size));
    // HANDLE_ERROR(cudaMemset(dev_debug_output, 0, debug_output_mem_size));

    // neighbour
    bool* dev_neighbour_shared_values;
    size_t neighbour_shared_mem_size = sizeof(bool) * image_size * program_num_shared_neighbours;
    HANDLE_ERROR(cudaMalloc((void **) &dev_neighbour_shared_values, neighbour_shared_mem_size));
    HANDLE_ERROR(cudaMemset(dev_neighbour_shared_values, 0, neighbour_shared_mem_size));

    // program counter when neighbour written
    cuda::atomic<int, cuda::thread_scope_device>* dev_neighbour_program_counter;
    size_t neighbour_program_counter_mem_size = sizeof(cuda::atomic<int, cuda::thread_scope_device>) * image_size;
    HANDLE_ERROR(cudaMalloc((void **) &dev_neighbour_program_counter, neighbour_program_counter_mem_size));
    cuda::atomic<int, cuda::thread_scope_device> *initial_neighbour_program_counter = (cuda::atomic<int, cuda::thread_scope_device> *) malloc(neighbour_program_counter_mem_size);
    for (size_t i = 0; i < image_size; i++) {
        initial_neighbour_program_counter[i] = 0;
    }
    HANDLE_ERROR(cudaMemcpy(dev_neighbour_program_counter, initial_neighbour_program_counter, neighbour_program_counter_mem_size, cudaMemcpyHostToDevice));
    free(initial_neighbour_program_counter);

    // external values
    bool* dev_external_values;
    size_t external_values_mem_size = sizeof(bool) * image_size * program_num_outputs;
    HANDLE_ERROR(cudaMalloc((void **) &dev_external_values, external_values_mem_size));
    HANDLE_ERROR(cudaMemset(dev_external_values, 0, external_values_mem_size));

    // local memory values
    bool* dev_local_memory_values;
    size_t local_memory_values_mem_size = sizeof(bool) * image_size * MEMORY_SIZE_IN_BITS;
    HANDLE_ERROR(cudaMalloc((void **) &dev_local_memory_values, local_memory_values_mem_size));
    HANDLE_ERROR(cudaMemset(dev_local_memory_values, 0, local_memory_values_mem_size));

    // carry register values
    bool* dev_carry_register_values;
    size_t carry_register_values_mem_size = sizeof(bool) * image_size * program.vliwWidth;
    HANDLE_ERROR(cudaMalloc((void **) &dev_carry_register_values, carry_register_values_mem_size));
    HANDLE_ERROR(cudaMemset(dev_carry_register_values, 0, carry_register_values_mem_size));

    // result values
    const size_t PIPELINE_WIDTH = 3;
    bool* dev_result_values;
    HANDLE_ERROR(cudaMalloc((void **) &dev_result_values, image_size * PIPELINE_WIDTH * program.vliwWidth));
    HANDLE_ERROR(cudaMemset(dev_result_values, 0, image_size * PIPELINE_WIDTH * program.vliwWidth));

    cudaEvent_t start, stop;
    float elapsedTime;
    
    HANDLE_ERROR(cudaEventCreate(&start));
    HANDLE_ERROR(cudaEventCreate(&stop));
        
    HANDLE_ERROR(cudaEventRecord(start, 0));

    // TODO compute actual MAX_BLOCK_SIZE
    constexpr size_t MAX_BLOCK_SIZE = 6;

    dim3 blocks(
        std::min((image_x_dim + NUM_THREADS_PER_BLOCK_PER_DIM - 1) / NUM_THREADS_PER_BLOCK_PER_DIM, MAX_BLOCK_SIZE),
        std::min((image_y_dim + NUM_THREADS_PER_BLOCK_PER_DIM - 1) / NUM_THREADS_PER_BLOCK_PER_DIM, MAX_BLOCK_SIZE)
    );
    dim3 threads(NUM_THREADS_PER_BLOCK_PER_DIM, NUM_THREADS_PER_BLOCK_PER_DIM);

    void *kernelArgs[] = {
        (void *) &program.instructionCount,
        (void *) &dev_image,
        (void *) &dev_neighbour_shared_values,
        (void *) &dev_neighbour_program_counter,
        (void *) &dev_external_values,
        (void *) &image_size,
        (void *) &image_x_dim,
        (void *) &image_y_dim,
        (void *) &program_num_outputs,
        (void *) &program_num_shared_neighbours,
        (void *) &dev_debug_output,
        (void *) &num_debug_outputs,
        (void *) &program.vliwWidth,
        (void *) &use_shared_memory,
        (void *) &program.isPipelining,
        (void *) &dev_local_memory_values,
        (void *) &dev_carry_register_values,
        (void *) &dev_result_values
    };
    cudaLaunchCooperativeKernel((void *) processingElemKernel, blocks, threads, kernelArgs);

    HANDLE_ERROR(cudaPeekAtLastError());

    HANDLE_ERROR(cudaDeviceSynchronize());

    HANDLE_ERROR(cudaEventRecord(stop, 0));
    HANDLE_ERROR(cudaEventSynchronize(stop));

    // Gets the elapsed time in milliseconds
    HANDLE_ERROR(cudaEventElapsedTime(&elapsedTime, start, stop));

    bool* external_values = (bool *) malloc(external_values_mem_size);
    HANDLE_ERROR(cudaMemcpy(external_values, dev_external_values, external_values_mem_size, cudaMemcpyDeviceToHost));

    // debugging output
    // size_t* debug_output = (size_t *) malloc(debug_output_mem_size);
    // HANDLE_ERROR(cudaMemcpy(debug_output, dev_debug_output, debug_output_mem_size, cudaMemcpyDeviceToHost));
    // for (size_t i = 0; i < image_size; i++) {
    //     for (size_t j = 0; j < program.instructionCount * program.vliwWidth; j++) {
    //         size_t offset = (i * program.instructionCount * program.vliwWidth + j) * num_debug_outputs;
    //         std::cout << "Instruction " << j << " at " << i << ": ";
    //         for (size_t k = 0; k < num_debug_outputs; k++) {
    //             std::cout << debug_output[offset + k] << " ";
    //         }
    //         std::cout << std::endl;
    //     }
    // }

    // HANDLE_ERROR(cudaFree(dev_instructions));
    HANDLE_ERROR(cudaFree(dev_image));
    HANDLE_ERROR(cudaFree(dev_neighbour_shared_values));
    HANDLE_ERROR(cudaFree(dev_neighbour_program_counter));
    HANDLE_ERROR(cudaFree(dev_external_values));
    HANDLE_ERROR(cudaFree(dev_local_memory_values));
    HANDLE_ERROR(cudaFree(dev_carry_register_values));
    HANDLE_ERROR(cudaFree(dev_result_values));
    // HANDLE_ERROR(cudaFree(dev_debug_output));

    return {external_values, elapsedTime};
}

bool get_instruction_input_value_cpu(
    InputC inputc,
    bool* memory,
    uint8_t* image,
    size_t pd_bit,
    bool* pd_increment,
    int64_t x,
    int64_t y,
    size_t image_x_dim,
    size_t image_y_dim,
    size_t image_size,
    size_t offset,
    bool* neighbour_shared_values,
    size_t num_shared_neighbours,
    size_t shared_neighbour_value
) {
    bool input_value = false;
    switch (inputc.input.inputKind) {
        case InputKind::Address: input_value = memory[inputc.input.address]; break;
        case InputKind::ZeroValue: input_value = false; break;
        case InputKind::PD:
            input_value = getBitAt(image[offset], pd_bit);
            *pd_increment = true;
            break;
        case InputKind::Up:
            if (y - 1 >= 0) {
                int64_t up_index = offset - image_x_dim;
                input_value = neighbour_shared_values[up_index * num_shared_neighbours + shared_neighbour_value - 1];
            } else {
                input_value = false;
            }
            break;
        case InputKind::Down:
            if (y + 1 < image_y_dim) {
                int64_t down_index = offset + image_x_dim;
                input_value = neighbour_shared_values[down_index * num_shared_neighbours + shared_neighbour_value - 1];
            } else {
                input_value = false;
            }
            break;
        case InputKind::Right:
            if (x + 1 < image_x_dim) {
                int64_t right_index = offset + 1;
                input_value = neighbour_shared_values[right_index * num_shared_neighbours + shared_neighbour_value - 1];
            } else {
                input_value = false;
            }
            break;
        case InputKind::Left:
            if (x - 1 >= 0) {
                int64_t left_index = offset - 1;
                input_value = neighbour_shared_values[left_index * num_shared_neighbours + shared_neighbour_value - 1];
            } else {
                input_value = false;
            }
            break;
        default:
            break;
    }
    return (inputc.negated) ? !input_value : input_value;
}

std::pair<bool *, float> process_image_cpu(Program program, uint8_t* pixels, size_t image_x_dim, size_t image_y_dim) {
    size_t program_num_outputs = numOutputs(program);
    size_t program_num_shared_neighbours = numSharedNeighbours(program);
    size_t image_size = image_x_dim * image_y_dim;

    bool* neighbour_shared_values = (bool *) malloc(image_size * program_num_shared_neighbours);
    for (size_t i = 0; i < image_size * program_num_shared_neighbours; i++) {
        neighbour_shared_values[i] = false;
    }
    bool* local_memory_values = (bool *) malloc(image_size * MEMORY_SIZE_IN_BITS);
    for (size_t i = 0; i < image_size * MEMORY_SIZE_IN_BITS; i++) {
        local_memory_values[i] = false;
    }
    bool* carry_register = (bool *) malloc(image_size * program.vliwWidth);
    for (size_t i = 0; i < image_size * program.vliwWidth; i++) {
        carry_register[i] = false;
    }
    bool* external_values = (bool *) malloc(image_size * program_num_outputs);
    for (size_t i = 0; i < image_size * program_num_outputs; i++) {
        external_values[i] = false;
    }
    size_t output_number = 0;
    bool output_number_increment = false;
    size_t shared_neighbour_value = 0;
    bool shared_neighbour_increment = false;

    // Note: PIPELINE_WIDTH
    // TODO is PIPELINE_WIDTH = 1 equivalent to no pipelining?
    size_t PIPELINE_WIDTH = 3;
    bool* result_values = (bool *) malloc(image_size * PIPELINE_WIDTH * program.vliwWidth);
    // TODO initializing result_values unnecessary?
    for (size_t i = 0; i < image_size * PIPELINE_WIDTH * program.vliwWidth; i++) {
        result_values[i] = false;
    }

    auto start_time = std::chrono::high_resolution_clock::now();
    size_t pd_bit = 0;
    bool pd_increment = false;

    for (size_t i = 0; (i < program.instructionCount && !program.isPipelining) || (i < program.instructionCount + PIPELINE_WIDTH - 1 && program.isPipelining); i++) {
        for (size_t x = 0; x < image_x_dim; x++) {
            for (size_t y = 0; y < image_y_dim; y++) {
                size_t offset = x + y * image_x_dim;
                if (i < program.instructionCount) {
                    for (size_t j = 0; j < program.vliwWidth; j++) {
                        const Instruction instruction = program.instructions[i * program.vliwWidth + j];
                        if (instruction.isNop) {
                            continue;
                        }
                        bool carryval = false;
                        switch (instruction.carry) {
                            case Carry::CR: carryval = carry_register[offset * program.vliwWidth + j]; break;
                            case Carry::One: carryval = true; break;
                            case Carry::Zero: carryval = false; break;
                        }
                        bool input_one = get_instruction_input_value_cpu(
                            instruction.input1,
                            local_memory_values + offset * MEMORY_SIZE_IN_BITS,
                            pixels,
                            pd_bit,
                            &pd_increment,
                            x,
                            y,
                            image_x_dim,
                            image_y_dim,
                            image_size,
                            offset,
                            neighbour_shared_values,
                            program_num_shared_neighbours,
                            shared_neighbour_value
                        );
                        bool input_two = get_instruction_input_value_cpu(
                            instruction.input2,
                            local_memory_values + offset * MEMORY_SIZE_IN_BITS,
                            pixels,
                            pd_bit,
                            &pd_increment,
                            x,
                            y,
                            image_x_dim,
                            image_y_dim,
                            image_size,
                            offset,
                            neighbour_shared_values,
                            program_num_shared_neighbours,
                            shared_neighbour_value
                        );

                        const bool sum = (input_one != input_two) != carryval;
                        const bool carry = (carryval && (input_one != input_two)) || (input_one && input_two);
                        
                        result_values[(offset * PIPELINE_WIDTH + (i % PIPELINE_WIDTH)) * program.vliwWidth + j] = (instruction.resultType.value == 's') ? sum : carry;

                        // Interesting choice...
                        if (instruction.carry == Carry::CR) {
                            carry_register[offset * program.vliwWidth + j] = carry;
                        }
                    }
                }

                if (!program.isPipelining || (program.isPipelining && i >= PIPELINE_WIDTH - 1)) {
                    for (size_t j = 0; j < program.vliwWidth; j++) {
                        const Instruction instruction = 
                        program.isPipelining ?
                        program.instructions[(i - PIPELINE_WIDTH + 1) * program.vliwWidth + j] :
                        program.instructions[i * program.vliwWidth + j];
                        if (instruction.isNop) {
                            continue;
                        }
                        bool resultvalue = !program.isPipelining ?
                        result_values[(offset * PIPELINE_WIDTH + (i % PIPELINE_WIDTH)) * program.vliwWidth + j] :
                        result_values[(offset * PIPELINE_WIDTH + ((i - PIPELINE_WIDTH + 1) % PIPELINE_WIDTH)) * program.vliwWidth + j];
                        // result_values[offset * program.vliwWidth + j];
                        switch (instruction.result.resultKind) {
                            case ResultKind::Address:
                                local_memory_values[offset * MEMORY_SIZE_IN_BITS + instruction.result.address] = resultvalue;
                                break;
                            case ResultKind::Neighbour:
                                neighbour_shared_values[offset * program_num_shared_neighbours + shared_neighbour_value] = resultvalue;
                                shared_neighbour_increment = true;
                                break;
                            case ResultKind::External:
                                external_values[program_num_outputs * offset + output_number] = resultvalue;
                                output_number_increment = true;
                                break;
                        }
                    }
                }
            }
        }

        if (pd_increment) {
            pd_bit++;
        }
        pd_increment = false;

        if (shared_neighbour_increment) {
            shared_neighbour_value++;
        }
        shared_neighbour_increment = false;

        if (output_number_increment) {
            output_number++;
        }
        output_number_increment = false;
    }

    auto stop_time = std::chrono::high_resolution_clock::now();
    size_t duration = std::chrono::duration_cast<std::chrono::microseconds>(stop_time - start_time).count();
    float durationInMilliseconds = duration / 1000.0f;

    free(neighbour_shared_values);
    free(local_memory_values);
    free(carry_register);

    // std::cout << "External values" << std::endl;
    // for (size_t i = 0; i < image_size * program_num_outputs; i++) {
    //     std::cout << "offset " << i << ": " << external_values[i] << std::endl;
    // }

    return {external_values, durationInMilliseconds};
}

void testProgram(std::string programFilename,
    size_t vliwWidth,
    bool isPipelining,
    const char *imageFilename,
    size_t dimension,
    size_t num_bits,
    size_t expected_program_num_outputs,
    std::vector<std::vector<std::vector<bool>>> expected_image,
    std::vector<float>& real_time_timings,
    std::vector<float>& per_frame_timings,
    size_t timing_index,
    bool useGPU
) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    // Print image in binary form
    // std::cout << "Image (binary):" << std::endl;
    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         for (size_t i = 0; i < num_bits; i++) {
    //             size_t val = (image[y * dimension + x] & (1 << i)) >> i;
    //             std::cout << val;
    //         }
    //         std::cout << " ";
    //     }
    //     std::cout << std::endl;
    // }

    // Print image
    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         std::cout << (uint16_t) image[y * dimension + x] << " ";
    //     }
    //     std::cout << std::endl;
    // }

    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         std::cout << "offset " << y * dimension + x << ": " << (int) image[y * dimension + x] << std::endl;
    //     }
    // }


    std::string programText;
    readFile(programFilename, programText);

    Parser parser(programText);
    Program program = parser.parse(vliwWidth, isPipelining);
    // program.print();

    size_t program_num_outputs = numOutputs(program);


    // cudaEvent_t start, stop;
    // float elapsedTime;

    // HANDLE_ERROR(cudaEventCreate(&start));
    // HANDLE_ERROR(cudaEventCreate(&stop));

    // HANDLE_ERROR(cudaEventRecord(start, 0));

    bool *processed_image = nullptr;
    if (useGPU) {
        auto normal_start = std::chrono::high_resolution_clock::now();
        std::pair<bool *, float> process_image_result = process_image_gpu(program, image, dimension, dimension, true);
        auto normal_stop = std::chrono::high_resolution_clock::now();
        size_t real_time_duration = std::chrono::duration_cast<std::chrono::microseconds>(normal_stop - normal_start).count();
        processed_image = process_image_result.first;
        per_frame_timings[timing_index] = process_image_result.second;
        real_time_timings[timing_index] = real_time_duration / 1000.0f;
    } else {
        auto normal_start = std::chrono::high_resolution_clock::now();
        std::pair<bool *, float> process_image_result = process_image_cpu(program, image, dimension, dimension);
        auto normal_stop = std::chrono::high_resolution_clock::now();
        size_t real_time_duration = std::chrono::duration_cast<std::chrono::microseconds>(normal_stop - normal_start).count();
        processed_image = process_image_result.first;
        per_frame_timings[timing_index] = process_image_result.second;
        real_time_timings[timing_index] = real_time_duration / 1000.0f;
    }

    // HANDLE_ERROR(cudaEventRecord(stop, 0));
    // HANDLE_ERROR(cudaEventSynchronize(stop));

    // HANDLE_ERROR(cudaEventElapsedTime(&elapsedTime, start, stop));

    // std::cout << "Processing time: " << elapsedTime << " ms" << std::endl;
    // std::cout << "Frame rate: " << 1000.0f / elapsedTime << " fps" << std::endl;

    
    // std::cout << "Processing time: " << duration / 1000.0f << " ms" << std::endl;
    // std::cout << "Frame rate: " << 1000000.0f / duration << " fps" << std::endl;

    // HANDLE_ERROR(cudaEventDestroy(start));
    // HANDLE_ERROR(cudaEventDestroy(stop));

    bool test_passed = true;
    for (size_t y = 0; y < dimension; y++) {
        for (size_t x = 0; x < dimension; x++) {
            size_t offset = x + y * dimension;
            for (int64_t i = program_num_outputs - 1; i >= 0; i--) {
                bool actual_value = processed_image[program_num_outputs * offset + i];
                if (actual_value != expected_image[y][x][i]) {
                    std::cout << "Mismatch at (" << x << ", " << y << ")[" << i << "]: " << actual_value << " != " << expected_image[y][x][i] << std::endl;
                    test_passed = false;
                }
            }
        }
    }

    // Print external values
    // std::cout << "External values:" << std::endl;
    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         size_t offset = x + y * dimension;
    //         for (size_t i = 0; i < program_num_outputs; i++) {
    //             std::cout << processed_image[program_num_outputs * offset + i];
    //         }
    //         std::cout << " ";
    //     }
    //     std::cout << std::endl;
    // }

    if (test_passed) {
        // Logging when tests pass
        std::cout << programFilename << " test passed with frame rate " << 1000.0f / per_frame_timings[timing_index] << " fps" << std::endl;
    } else {
        std::cout << programFilename << " test failed" << std::endl;
    }

    // Print power and area
    // double computeArea = getComputeArea(program.vliwWidth) * dimension * dimension;
    // double memoryArea = getMemoryArea(program.vliwWidth, program.isPipelining) * dimension * dimension;
    // double computeDynPower = getComputeDynamicPower(program) * dimension * dimension;
    // double memoryDynPower = getMemoryDynamicPower(program) * dimension * dimension;
    // double computeSubThreshLeakage = getComputeSubthresholdLeakage(program.vliwWidth) * dimension * dimension;
    // double memorySubThreshLeakage = getMemorySubthresholdLeakage(program.vliwWidth, program.isPipelining) * dimension * dimension;
    // double computeGateLeakage = getComputeGateLeakage(program.vliwWidth) * dimension * dimension;
    // double memoryGateLeakage = getMemoryGateLeakage(program.vliwWidth, program.isPipelining) * dimension * dimension;

    // std::cout << "Compute Area: " << computeArea << " um^2" << std::endl;
    // std::cout << "Memory Area: " << memoryArea << " um^2" << std::endl;
    // std::cout << "Compute Dynamic Power: " << computeDynPower << " W" << std::endl;
    // std::cout << "Memory Dynamic Power: " << memoryDynPower << " W" << std::endl;
    // std::cout << "Compute Subthreshold Leakage: " << computeSubThreshLeakage << " W" << std::endl;
    // std::cout << "Memory Subthreshold Leakage: " << memorySubThreshLeakage << " W" << std::endl;
    // std::cout << "Compute Gate Leakage: " << computeGateLeakage << " W" << std::endl;
    // std::cout << "Memory Gate Leakage: " << memoryGateLeakage << " W" << std::endl;

    free(image);
    free(processed_image);
    delete [] program.instructions;
}


std::vector<std::vector<std::vector<bool>>> getExpectedImageForOneBitEdgeDetection(const char *imageFilename, size_t num_bits, size_t dimension, size_t expected_program_num_outputs) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    std::vector<std::vector<std::vector<bool>>> expected_image(dimension, std::vector<std::vector<bool>>(dimension, std::vector<bool>(expected_program_num_outputs, 0)));
    for (int i = 0; i < dimension; i++) {
        for (int j = 0; j < dimension; j++) {
            size_t val = image[i * dimension + j];
            expected_image[i][j][0] =
            (((i - 1 < 0) ? 0 : image[(i - 1) * dimension + j]) != val)
            || (((i + 1 >= dimension) ? 0 : image[(i + 1) * dimension + j]) != val)
            || (((j - 1 < 0) ? 0 : image[i * dimension + (j - 1)]) != val)
            || (((j + 1 >= dimension) ? 0 : image[i * dimension + j + 1]) != val); 
        }
    }
    free(image);
    return expected_image;
}

std::vector<std::vector<std::vector<bool>>> getExpectedImageForOneBitThinning(const char *imageFilename, size_t num_bits, size_t dimension, size_t expected_program_num_outputs) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    std::vector<std::vector<std::vector<bool>>> expected_image(dimension, std::vector<std::vector<bool>>(dimension, std::vector<bool>(expected_program_num_outputs, 0)));
    for (int i = 0; i < dimension; i++) {
        for (int j = 0; j < dimension; j++) {
            size_t count = 
            ((i - 1 < 0) ? 0 : image[(i - 1) * dimension + j])
            + ((i + 1 >= dimension) ? 0 : image[(i + 1) * dimension + j])
            + ((j - 1 < 0) ? 0 : image[i * dimension + j - 1])
            + ((j + 1 >= dimension) ? 0 : image[i * dimension + j + 1]);
            expected_image[i][j][0] = (count == 1 || count == 2) ? 0 : image[i * dimension + j];
        }
    }
    free(image);
    return expected_image;
}

std::vector<std::vector<std::vector<bool>>> getExpectedImageForOneBitSmoothing(const char *imageFilename, size_t num_bits, size_t dimension, size_t expected_program_num_outputs) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    std::vector<std::vector<std::vector<bool>>> expected_image(dimension, std::vector<std::vector<bool>>(dimension, std::vector<bool>(expected_program_num_outputs, 0)));
    for (int i = 0; i < dimension; i++) {
        for (int j = 0; j < dimension; j++) {
            size_t count = 
            ((i - 1 < 0) ? 0 : image[(i - 1) * dimension + j])
            + ((i + 1 >= dimension) ? 0 : image[(i + 1) * dimension + j])
            + ((j - 1 < 0) ? 0 : image[i * dimension + j - 1])
            + ((j + 1 >= dimension) ? 0 : image[i * dimension + j + 1])
            + image[i * dimension + j];
            expected_image[i][j][0] = count >= 3;
        }
    }
    free(image);
    return expected_image;
}

std::vector<std::vector<std::vector<bool>>> getExpectedImageForPrewittEdgeDetection(const char *imageFilename, size_t num_bits, size_t dimension, size_t expected_program_num_outputs) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    std::vector<std::vector<std::vector<bool>>> expected_image(dimension, std::vector<std::vector<bool>>(dimension, std::vector<bool>(expected_program_num_outputs, 0)));
    for (int i = 0; i < dimension; i++) {
        for (int j = 0; j < dimension; j++) {
            // Prewitt edge detection
            int16_t gx = ((j - 1 < 0) ? 0 : (int16_t) image[i * dimension + j - 1])
            + ((j - 1 < 0 || i + 1 >= dimension) ? 0 : (int16_t) image[(i + 1) * dimension + j - 1])
            + ((j - 1 < 0 || i - 1 < 0) ? 0 : (int16_t) image[(i - 1) * dimension + j - 1])
            - ((j + 1 >= dimension) ? 0 : (int16_t) image[i * dimension + j + 1])
            - (((j + 1 >= dimension || i + 1 >= dimension) ? 0 : (int16_t) image[(i + 1) * dimension + j + 1]))
            - (((j + 1 >= dimension || i - 1 < 0) ? 0 : (int16_t) image[(i - 1) * dimension + j + 1]));
            
            for (size_t k = 0; k < expected_program_num_outputs; k++) {
                expected_image[i][j][k] = (gx & (1 << k)) >> k;
            }
        }
    }

    // Print expected image
    // std::cout << "Expected image:" << std::endl;
    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         uint16_t val = 0;
    //         for (size_t i = 0; i < expected_program_num_outputs; i++) {
    //             val |= expected_image[y][x][i] << i;
    //         }
    //         int16_t result = (val & 0x100) ? (int16_t) (val | 0xFE00) : (int16_t) val;
    //         std::cout << result << " ";
    //     }
    //     std::cout << std::endl;
    // }
    free(image);
    return expected_image;
}

std::vector<std::vector<std::vector<bool>>> getExpectedImageForMultiBitSmoothing(const char *imageFilename, size_t num_bits, size_t dimension, size_t expected_program_num_outputs) {
    uint8_t* image = transform_image(imageFilename, dimension, num_bits);
    std::vector<std::vector<std::vector<bool>>> expected_image(dimension, std::vector<std::vector<bool>>(dimension, std::vector<bool>(expected_program_num_outputs, 0)));
    for (int i = 0; i < dimension; i++) {
        for (int j = 0; j < dimension; j++) {
            uint16_t result = (((j - 1 < 0) ? 0 : (uint16_t) image[i * dimension + j - 1])
            + ((i + 1 >= dimension) ? 0 : (uint16_t) image[(i + 1) * dimension + j])
            + ((i - 1 < 0) ? 0 : (uint16_t) image[(i - 1) * dimension + j])
            + ((j + 1 >= dimension) ? 0 : (uint16_t) image[i * dimension + j + 1])) / 4;
            
            for (size_t k = 0; k < expected_program_num_outputs; k++) {
                expected_image[i][j][k] = (result & (1 << k)) >> k;
            }
        }
    }
    free(image);
    return expected_image;
}

std::pair<double, double> testAllPrograms(const char *imageFilename, size_t dimension, bool useGPU) {

    uint8_t* image = transform_image(imageFilename, dimension, 1);

    // Print image
    // std::cout << "Image:" << std::endl;
    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         std::cout << (int) image[y * dimension + x] << " ";
    //     }
    //     std::cout << std::endl;
    // }

    // for (size_t y = 0; y < dimension; y++) {
    //     for (size_t x = 0; x < dimension; x++) {
    //         std::cout << "offset " << y * dimension + x << ": " << (int) image[y * dimension + x] << std::endl;
    //     }
    // }

    size_t min_vliw_width = 1;
    size_t max_vliw_width = 4;
    // Note: Need to change this if we need to add more tests
    size_t NUM_TESTS = 5;
    size_t num_total_tests = NUM_TESTS * (max_vliw_width - min_vliw_width + 1);
    std::vector<float> real_time_timings(num_total_tests);
    std::vector<float> per_frame_timings(num_total_tests);
    for (size_t vliwWidth = min_vliw_width; vliwWidth <= max_vliw_width; vliwWidth++) {
        // Note: only make pipelining tests for vliwWidth == 1
        for (size_t pipelining = 0; (pipelining <= 1 && vliwWidth == 1) || pipelining == 0; pipelining++) {
            std::string directory_name = pipelining == 0 ? std::to_string(vliwWidth) + "_vliw_slot/" : "pipelining/";
            bool is_pipelining = pipelining == 1;
            testProgram(
                ("programs/" + directory_name + "edge_detection_one_bit.vis").c_str(),
                vliwWidth,
                is_pipelining,
                imageFilename,
                dimension,
                1,
                1,
                getExpectedImageForOneBitEdgeDetection(imageFilename, 1, dimension, 1),
                real_time_timings,
                per_frame_timings,
                (vliwWidth - min_vliw_width) * NUM_TESTS + 0,
                useGPU
            );

            testProgram(
                ("programs/" + directory_name + "thinning_one_bit.vis").c_str(),
                vliwWidth,
                is_pipelining,
                imageFilename,
                dimension,
                1,
                1,
                getExpectedImageForOneBitThinning(imageFilename, 1, dimension, 1),
                real_time_timings,
                per_frame_timings,
                (vliwWidth - min_vliw_width) * NUM_TESTS + 1,
                useGPU
            );

            testProgram(
                ("programs/" + directory_name + "smoothing_one_bit.vis").c_str(),
                vliwWidth,
                is_pipelining,
                imageFilename,
                dimension,
                1,
                1,
                getExpectedImageForOneBitSmoothing(imageFilename, 1, dimension, 1),
                real_time_timings,
                per_frame_timings,
                (vliwWidth - min_vliw_width) * NUM_TESTS + 2,
                useGPU
            );

            testProgram(
                ("programs/" + directory_name + "prewitt_edge_detection_six_bits.vis").c_str(),
                vliwWidth,
                is_pipelining,
                imageFilename,
                dimension,
                6,
                9,
                getExpectedImageForPrewittEdgeDetection(imageFilename, 6, dimension, 9),
                real_time_timings,
                per_frame_timings,
                (vliwWidth - min_vliw_width) * NUM_TESTS + 3,
                useGPU
            );

            testProgram(
                ("programs/" + directory_name + "smoothing_six_bits.vis").c_str(),
                vliwWidth,
                is_pipelining,
                imageFilename,
                dimension,
                6,
                6,
                getExpectedImageForMultiBitSmoothing(imageFilename, 6, dimension, 6),
                real_time_timings,
                per_frame_timings,
                (vliwWidth - min_vliw_width) * NUM_TESTS + 4,
                useGPU
            );
        }
    }

    free(image);
    
    // Compute average processing time and average frame rate
    double total_real_time_duration = 0;
    double total_per_frame_duration = 0;
    for (size_t i = 0; i < num_total_tests; i++) {
        total_real_time_duration += (double) real_time_timings[i];
        total_per_frame_duration += (double) per_frame_timings[i];
    }
    return {total_real_time_duration / ((double) num_total_tests), total_per_frame_duration / ((double) num_total_tests)};
}

int main() {
    queryGPUProperties();

    const char *imageFilename = "images/windmill_512.jpg";
    size_t dimension = 512;

    std::pair<double, double> gpu_tests_result = testAllPrograms(imageFilename, dimension, true);
    // std::cout << "Average real-time processing time (GPU): " << gpu_tests_result.first << " ms" << std::endl;
    // std::cout << "Average real-time frame rate (GPU): " << 1000.0f / gpu_tests_result.first << " fps" << std::endl;
    std::cout << "Average per-frame processing time (GPU): " << gpu_tests_result.second << " ms" << std::endl;
    std::cout << "Average per-frame frame rate (GPU): " << 1000.0f / gpu_tests_result.second << " fps" << std::endl;

    // TODO Assuming no cache effects
    std::pair<double, double> cpu_tests_result = testAllPrograms(imageFilename, dimension, false);
    // std::cout << "Average processing time (CPU): " << cpu_tests_result.first << " ms" << std::endl;
    // std::cout << "Average frame rate (CPU): " << 1000.0f / cpu_tests_result.first << " fps" << std::endl;
    std::cout << "Average per-frame processing time (CPU): " << cpu_tests_result.second << " ms" << std::endl;
    std::cout << "Average per-frame frame rate (CPU): " << 1000.0f / cpu_tests_result.second << " fps" << std::endl;

    return EXIT_SUCCESS;
}