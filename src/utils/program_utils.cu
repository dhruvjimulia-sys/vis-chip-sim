#include "program_utils.h"
#include "../isa.h"

size_t numOutputs(Program program) {
    size_t num_outputs = 0;
    for (int i = 0; i < program.instructionCount * program.vliwWidth; i++) {
        if (program.instructions[i].result.resultKind == ResultKind::External && !program.instructions[i].isNop) {
            num_outputs++;
        }
    }
    return num_outputs;
}

size_t numSharedNeighbours(Program program) {
    size_t num_shared_neighbours = 0;
    for (int i = 0; i < program.instructionCount * program.vliwWidth; i++) {
        if (program.instructions[i].result.resultKind == ResultKind::Neighbour && !program.instructions[i].isNop) {
            num_shared_neighbours++;
        }
    }
    return num_shared_neighbours;
}

size_t numComputeAccesses(Program program) {
    size_t num_compute_accesses = 0;
    for (int i = 0; i < program.instructionCount * program.vliwWidth; i++) {
        if (!program.instructions[i].isNop) {
            num_compute_accesses++;
        }
    }
    return num_compute_accesses;
}

size_t numMemoryReadAccesses(Program program) {
    // ASSUME: reading from photodetector/0/neighbours counts as an access
    return numComputeAccesses(program) * 2;
}

size_t numMemoryWriteAccesses(Program program) {
    return numComputeAccesses(program);
}

size_t numRegisterReadAccesses(Program program) {
    size_t num_register_read_accesses = 0;
    for (int i = 0; i < program.instructionCount * program.vliwWidth; i++) {
        if (!program.instructions[i].isNop) {
            if (program.instructions[i].carry == Carry::CR) {
                num_register_read_accesses += 4;
            } else {
                num_register_read_accesses += 3;
            }
        }
    }
    return num_register_read_accesses;
}

size_t numRegisterWriteAccesses(Program program) {
    // number of writes to internal registers turns out to be the same as number of reads
    return numRegisterReadAccesses(program);
}