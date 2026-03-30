#include "color_table.h"
#include "metal/metal_common.h"
#include "nexrad/products.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct ColorStop {
    float value = 0.0f;        // internal units
    uint32_t start_color = 0;
    uint32_t end_color = 0;
    bool solid = false;
    bool explicit_gradient = false;
};

std::string trim(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && std::isspace((unsigned char)s[start])) start++;
    size_t end = s.size();
    while (end > start && std::isspace((unsigned char)s[end - 1])) end--;
    return s.substr(start, end - start);
}

std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return s;
}

std::string stripQuotes(const std::string& s) {
    std::string out = trim(s);
    if (!out.empty() && (out.front() == '"' || out.front() == '\'')) out.erase(out.begin());
    if (!out.empty() && (out.back() == '"' || out.back() == '\'')) out.pop_back();
    return trim(out);
}

std::string filenameOnly(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

uint32_t makeRGBA(int r, int g, int b, int a = 255) {
    return (uint32_t)std::clamp(r, 0, 255) |
           ((uint32_t)std::clamp(g, 0, 255) << 8) |
           ((uint32_t)std::clamp(b, 0, 255) << 16) |
           ((uint32_t)std::clamp(a, 0, 255) << 24);
}

uint32_t lerpColor(uint32_t c0, uint32_t c1, float t) {
    t = std::clamp(t, 0.0f, 1.0f);
    auto lerpChannel = [t](int a, int b) {
        return (int)std::lround((1.0f - t) * (float)a + t * (float)b);
    };
    return makeRGBA(
        lerpChannel((int)(c0 & 0xFF), (int)(c1 & 0xFF)),
        lerpChannel((int)((c0 >> 8) & 0xFF), (int)((c1 >> 8) & 0xFF)),
        lerpChannel((int)((c0 >> 16) & 0xFF), (int)((c1 >> 16) & 0xFF)),
        lerpChannel((int)((c0 >> 24) & 0xFF), (int)((c1 >> 24) & 0xFF)));
}

bool startsWithInsensitive(const std::string& text, const char* prefix) {
    const std::string lhs = toLower(trim(text));
    const std::string rhs = toLower(prefix);
    return lhs.rfind(rhs, 0) == 0;
}

bool parseRgbSpec(const std::string& spec, uint32_t& color, std::string& error) {
    std::string lower = toLower(trim(spec));
    if (lower.rfind("rgb(", 0) != 0) {
        error = "Only rgb(...) colors are currently supported";
        return false;
    }
    size_t open = lower.find('(');
    size_t close = lower.rfind(')');
    if (open == std::string::npos || close == std::string::npos || close <= open + 1) {
        error = "Malformed rgb(...) color spec";
        return false;
    }
    std::string inside = lower.substr(open + 1, close - open - 1);
    for (char& c : inside) if (c == ',') c = ' ';
    std::istringstream iss(inside);
    int r = 0, g = 0, b = 0, a = 255;
    if (!(iss >> r >> g >> b)) {
        error = "Malformed rgb(...) channel values";
        return false;
    }
    if (!(iss >> a)) a = 255;
    color = makeRGBA(r, g, b, a);
    return true;
}

int mapPaletteProduct(const std::string& rawId) {
    const std::string id = toLower(stripQuotes(rawId));
    if (id == "br" || id == "dr" || id == "ref")
        return PROD_REF;
    if (id == "bv" || id == "dv" || id == "srv" || id == "vel")
        return PROD_VEL;
    if (id == "sw")
        return PROD_SW;
    if (id == "zdr")
        return PROD_ZDR;
    if (id == "cc" || id == "rho" || id == "rhv" || id == "rhov")
        return PROD_CC;
    if (id == "kdp")
        return PROD_KDP;
    if (id == "phi")
        return PROD_PHI;
    return -1;
}

float unitScaleForProduct(int product, const std::string& rawUnits) {
    std::string units = toLower(stripQuotes(rawUnits));
    if (units.empty() || units == "dbz" || units == "db" || units == "deg" || units == "deg/km" ||
        units == "°/km" || units == "none" || units == "???")
        return 1.0f;

    if (product == PROD_VEL || product == PROD_SW) {
        if (units == "kts" || units == "knots") return 1.943844f;
        if (units == "mph") return 2.236936f;
        if (units == "kph") return 3.6f;
        if (units == "mps") return 1.0f;
    }
    if (product == PROD_CC && units == "%")
        return 100.0f;
    return 1.0f;
}

float productMin(int product) { return PRODUCT_INFO[product].min_value; }
float productMax(int product) { return PRODUCT_INFO[product].max_value; }

bool parseLegacyStop(const std::string& line, ColorStop& stop, std::string& error) {
    std::string work = trim(line);
    const size_t colon = work.find(':');
    if (colon == std::string::npos) {
        error = "Malformed legacy palette line";
        return false;
    }

    const std::string keyword = toLower(trim(work.substr(0, colon)));
    std::string payload = trim(work.substr(colon + 1));
    std::istringstream iss(payload);

    float value = 0.0f;
    int r = 0, g = 0, b = 0, a = 255;
    if (!(iss >> value >> r >> g >> b)) {
        error = "Malformed legacy palette color line";
        return false;
    }

    stop.value = value;
    stop.start_color = makeRGBA(r, g, b);
    stop.end_color = stop.start_color;
    stop.solid = (keyword == "solidcolor" || keyword == "solidcolor4");
    stop.explicit_gradient = false;

    if (keyword == "color4" || keyword == "solidcolor4") {
        if (!(iss >> a)) {
            error = "Malformed legacy alpha value";
            return false;
        }
        stop.start_color = makeRGBA(r, g, b, a);
        stop.end_color = stop.start_color;
    }

    int r2 = 0, g2 = 0, b2 = 0, a2 = 255;
    std::streampos beforeSecond = iss.tellg();
    if (iss >> r2 >> g2 >> b2) {
        if (keyword == "color4" || keyword == "solidcolor4") {
            if (!(iss >> a2)) a2 = a;
        }
        stop.end_color = makeRGBA(r2, g2, b2, a2);
        stop.explicit_gradient = true;
    } else {
        iss.clear();
        iss.seekg(beforeSecond);
    }

    return true;
}

bool parseCt3Stop(const std::string& line, ColorStop& stop, std::string& error) {
    const size_t lb = line.find('[');
    const size_t rb = line.find(']');
    const size_t eq = line.find('=');
    if (lb == std::string::npos || rb == std::string::npos || eq == std::string::npos || rb <= lb + 1) {
        error = "Malformed Color[...] statement";
        return false;
    }
    stop.value = std::stof(trim(line.substr(lb + 1, rb - lb - 1)));
    std::string expr = trim(line.substr(eq + 1));
    std::string lower = toLower(expr);

    stop.solid = false;
    stop.explicit_gradient = false;
    stop.start_color = 0;
    stop.end_color = 0;

    if (lower.rfind("gradient(", 0) == 0) {
        const size_t open = expr.find('(');
        const size_t close = expr.rfind(')');
        if (open == std::string::npos || close == std::string::npos || close <= open + 1) {
            error = "Malformed gradient(...)";
            return false;
        }
        std::string inside = expr.substr(open + 1, close - open - 1);
        int depth = 0;
        size_t split = std::string::npos;
        for (size_t i = 0; i < inside.size(); i++) {
            if (inside[i] == '(') depth++;
            else if (inside[i] == ')') depth--;
            else if (inside[i] == ',' && depth == 0) {
                split = i;
                break;
            }
        }
        if (split == std::string::npos) {
            error = "Malformed gradient color list";
            return false;
        }
        if (!parseRgbSpec(inside.substr(0, split), stop.start_color, error)) return false;
        if (!parseRgbSpec(inside.substr(split + 1), stop.end_color, error)) return false;
        stop.explicit_gradient = true;
        return true;
    }

    if (lower.rfind("solid(", 0) == 0) {
        const size_t open = expr.find('(');
        const size_t close = expr.rfind(')');
        if (open == std::string::npos || close == std::string::npos || close <= open + 1) {
            error = "Malformed solid(...)";
            return false;
        }
        if (!parseRgbSpec(expr.substr(open + 1, close - open - 1), stop.start_color, error)) return false;
        stop.end_color = stop.start_color;
        stop.solid = true;
        return true;
    }

    if (!parseRgbSpec(expr, stop.start_color, error)) return false;
    stop.end_color = stop.start_color;
    return true;
}

bool evaluateStops(int product,
                   float scale,
                   float offset,
                   std::vector<ColorStop> stops,
                   ParsedColorTable& table,
                   std::string& error) {
    if (stops.size() < 2) {
        error = "Color table needs at least two color entries";
        return false;
    }

    const float effectiveScale = (std::fabs(scale) < 1e-6f) ? 1.0f : scale;
    for (auto& stop : stops)
        stop.value = (stop.value - offset) / effectiveScale;

    std::sort(stops.begin(), stops.end(),
              [](const ColorStop& a, const ColorStop& b) { return a.value < b.value; });

    const float vmin = productMin(product);
    const float vmax = productMax(product);
    table.product = product;
    for (int i = 0; i < 256; i++) {
        const float t = (float)i / 255.0f;
        const float value = vmin + t * (vmax - vmin);
        const ColorStop* current = &stops.front();
        const ColorStop* next = &stops.back();
        for (size_t s = 0; s + 1 < stops.size(); s++) {
            if (value >= stops[s].value && value < stops[s + 1].value) {
                current = &stops[s];
                next = &stops[s + 1];
                break;
            }
            if (value >= stops.back().value) {
                current = &stops.back();
                next = &stops.back();
            }
        }

        uint32_t color = current->start_color;
        if (current != next && !current->solid) {
            const float denom = std::max(1e-5f, next->value - current->value);
            const float bandT = std::clamp((value - current->value) / denom, 0.0f, 1.0f);
            const uint32_t endColor = current->explicit_gradient ? current->end_color : next->start_color;
            color = lerpColor(current->start_color, endColor, bandT);
        }
        table.colors[(size_t)i] = color;
    }
    return true;
}

bool parseLegacyPalette(const std::string& text, ParsedColorTable& table, std::string& error) {
    std::istringstream input(text);
    std::string line;
    std::string productId;
    std::string units;
    float scale = 0.0f;
    float offset = 0.0f;
    bool scaleSet = false;
    std::vector<ColorStop> stops;

    while (std::getline(input, line)) {
        const size_t comment = line.find(';');
        if (comment != std::string::npos) line.erase(comment);
        line = trim(line);
        if (line.empty()) continue;

        if (startsWithInsensitive(line, "product:")) {
            productId = trim(line.substr(line.find(':') + 1));
        } else if (startsWithInsensitive(line, "units:")) {
            units = trim(line.substr(line.find(':') + 1));
        } else if (startsWithInsensitive(line, "scale:")) {
            scale = std::stof(trim(line.substr(line.find(':') + 1)));
            scaleSet = true;
        } else if (startsWithInsensitive(line, "offset:")) {
            offset = std::stof(trim(line.substr(line.find(':') + 1)));
        } else if (startsWithInsensitive(line, "color:") ||
                   startsWithInsensitive(line, "color4:") ||
                   startsWithInsensitive(line, "solidcolor:") ||
                   startsWithInsensitive(line, "solidcolor4:")) {
            ColorStop stop;
            if (!parseLegacyStop(line, stop, error)) return false;
            stops.push_back(stop);
        }
    }

    const int product = mapPaletteProduct(productId);
    if (product < 0) {
        error = "Unsupported or missing Product: entry";
        return false;
    }
    if (!scaleSet)
        scale = unitScaleForProduct(product, units);

    table.format = "RadarScope/GR legacy";
    return evaluateStops(product, scale, offset, std::move(stops), table, error);
}

bool parseCt3Palette(const std::string& text, ParsedColorTable& table, std::string& error) {
    std::istringstream input(text);
    std::string line;
    bool inBlock = false;
    std::string category;
    std::string units;
    float scale = 1.0f;
    float offset = 0.0f;
    std::vector<ColorStop> stops;

    while (std::getline(input, line)) {
        const size_t slashComment = line.find("//");
        if (slashComment != std::string::npos) line.erase(slashComment);
        const size_t semiComment = line.find(';');
        if (semiComment != std::string::npos) line.erase(semiComment);
        line = trim(line);
        if (line.empty()) continue;

        if (!inBlock) {
            if (startsWithInsensitive(line, "colortable"))
                inBlock = true;
            continue;
        }

        if (line == "{") continue;
        if (line == "}") break;

        if (startsWithInsensitive(line, "category")) {
            category = stripQuotes(line.substr(line.find('=') + 1));
        } else if (startsWithInsensitive(line, "units")) {
            units = stripQuotes(line.substr(line.find('=') + 1));
        } else if (startsWithInsensitive(line, "scale")) {
            scale = std::stof(trim(line.substr(line.find('=') + 1)));
        } else if (startsWithInsensitive(line, "offset")) {
            offset = std::stof(trim(line.substr(line.find('=') + 1)));
        } else if (startsWithInsensitive(line, "color[")) {
            ColorStop stop;
            if (!parseCt3Stop(line, stop, error)) return false;
            stops.push_back(stop);
        }
    }

    const int product = mapPaletteProduct(category);
    if (product < 0) {
        error = "Unsupported or missing Category entry";
        return false;
    }
    if (std::fabs(scale - 1.0f) < 1e-6f)
        scale = unitScaleForProduct(product, units);

    table.format = "GR CT3";
    return evaluateStops(product, scale, offset, std::move(stops), table, error);
}

} // namespace

bool loadColorTableFile(const std::string& path, ParsedColorTable& table, std::string& error) {
    std::ifstream in(path, std::ios::binary);
    if (!in.is_open()) {
        error = "Could not open palette file";
        return false;
    }

    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (text.empty()) {
        error = "Palette file is empty";
        return false;
    }

    table = {};
    table.label = filenameOnly(path);

    const std::string lower = toLower(text);
    const bool isCt3 = lower.find("colortable") != std::string::npos &&
                       lower.find("color[") != std::string::npos;

    const bool ok = isCt3
        ? parseCt3Palette(text, table, error)
        : parseLegacyPalette(text, table, error);

    if (!ok) return false;
    return true;
}
