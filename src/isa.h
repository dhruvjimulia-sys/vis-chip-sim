#pragma once
#include <iostream>
#include <string>
#include <vector>
#include <cctype>

enum class InputKind { Address, PD, Up, Down, Right, Left, ZeroValue };

struct Input {
    InputKind inputKind;
    uint8_t address;
};

// convert to enum
struct ResultType {
    char value; // 's' or 'c'
};

enum class ResultKind { Address, Neighbour, External };

struct Result {
    ResultKind resultKind;
    uint8_t address;

    __device__ __host__ void print() const;
};

struct InputC {
    bool negated = false;
    Input input;

    __device__ __host__ void print() const;
};

enum class Carry { Zero, One, CR };

__device__ __host__ void printCarry(Carry carry);

struct Instruction {
    Result result; 
    InputC input1; 
    InputC input2; 
    Carry carry; 
    ResultType resultType; 

    __device__ __host__ void print() const;
};

struct Program {
    Instruction* instructions;
    size_t instructionCount;

    Program(size_t count, Instruction* instr);
    __device__ __host__ void print() const;
};

class Parser {
public:
    explicit Parser(const std::string &input);
    Program parse();

private:
    std::string input;
    size_t pos;

    void skipWhitespace();
    bool match(const std::string &str);
    void expect(char ch);
    Result parseResult();
    Input parseInput();
    InputC parseInputC();
    Carry parseCarry();
    ResultType parseResultType();
    Instruction parseInstruction();
    std::string parseNumber();
};