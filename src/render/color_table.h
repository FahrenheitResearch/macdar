#pragma once
#include <array>
#include <string>
#include <cstdint>

struct ParsedColorTable {
    int product = -1;
    std::string format;
    std::string label;
    std::array<uint32_t, 256> colors{};
};

bool loadColorTableFile(const std::string& path, ParsedColorTable& table, std::string& error);
