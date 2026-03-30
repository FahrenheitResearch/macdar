cmake_minimum_required(VERSION 3.24)
project(cursdar2 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# ── GLFW ──────────────────────────────────────────────────────────────
FetchContent_Declare(
    glfw
    GIT_REPOSITORY https://github.com/glfw/glfw.git
    GIT_TAG        master
    GIT_SHALLOW    TRUE
)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(glfw)

# ── ImGui ─────────────────────────────────────────────────────────────
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG        v1.91.8-docking
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(imgui)

# ── nlohmann/json ─────────────────────────────────────────────────────
FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(nlohmann_json)

# ── ImGui static library (Metal + GLFW backends) ─────────────────────
add_library(imgui STATIC
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_metal.mm
)
target_include_directories(imgui PUBLIC
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
)
target_link_libraries(imgui PUBLIC glfw)

# ── BZip2 ─────────────────────────────────────────────────────────────
find_package(BZip2 QUIET)
if(NOT BZip2_FOUND)
    FetchContent_Declare(
        bzip2_src
        URL      https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
        URL_HASH SHA256=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
    )
    FetchContent_MakeAvailable(bzip2_src)
    add_library(bzip2 STATIC
        ${bzip2_src_SOURCE_DIR}/blocksort.c
        ${bzip2_src_SOURCE_DIR}/huffman.c
        ${bzip2_src_SOURCE_DIR}/crctable.c
        ${bzip2_src_SOURCE_DIR}/randtable.c
        ${bzip2_src_SOURCE_DIR}/compress.c
        ${bzip2_src_SOURCE_DIR}/decompress.c
        ${bzip2_src_SOURCE_DIR}/bzlib.c
    )
    target_include_directories(bzip2 PUBLIC ${bzip2_src_SOURCE_DIR})
    add_library(BZip2::BZip2 ALIAS bzip2)
endif()

# ── Metal shader compilation ──────────────────────────────────────────
set(METAL_SHADERS
    ${CMAKE_SOURCE_DIR}/src/metal/gpu_pipeline.metal
    ${CMAKE_SOURCE_DIR}/src/metal/renderer.metal
    ${CMAKE_SOURCE_DIR}/src/metal/volume3d.metal
)

# Check if the Metal compiler is available (requires Xcode, not just CLT)
execute_process(
    COMMAND xcrun -sdk macosx --find metal
    RESULT_VARIABLE METAL_COMPILER_FOUND
    OUTPUT_QUIET ERROR_QUIET
)

if(METAL_COMPILER_FOUND EQUAL 0)
    message(STATUS "Metal compiler found - compiling shaders to metallib")
    # Compile each .metal to .air
    foreach(SHADER ${METAL_SHADERS})
        get_filename_component(SHADER_NAME ${SHADER} NAME_WE)
        add_custom_command(
            OUTPUT ${CMAKE_BINARY_DIR}/${SHADER_NAME}.air
            COMMAND xcrun -sdk macosx metal -c ${SHADER}
                    -I ${CMAKE_SOURCE_DIR}/src/metal
                    -o ${CMAKE_BINARY_DIR}/${SHADER_NAME}.air
                    -ffast-math
            DEPENDS ${SHADER}
            COMMENT "Compiling Metal shader ${SHADER_NAME}.metal"
        )
        list(APPEND METAL_AIR_FILES ${CMAKE_BINARY_DIR}/${SHADER_NAME}.air)
    endforeach()

    # Link .air files into default.metallib
    add_custom_command(
        OUTPUT ${CMAKE_BINARY_DIR}/default.metallib
        COMMAND xcrun -sdk macosx metallib ${METAL_AIR_FILES}
                -o ${CMAKE_BINARY_DIR}/default.metallib
        DEPENDS ${METAL_AIR_FILES}
        COMMENT "Linking Metal library"
    )
    add_custom_target(metal_shaders ALL DEPENDS ${CMAKE_BINARY_DIR}/default.metallib)
else()
    message(STATUS "Metal compiler not found (need Xcode) - shaders will compile from source at runtime")
    add_custom_target(metal_shaders ALL)
endif()

# ── Executable ────────────────────────────────────────────────────────
add_executable(cursdar2
    src/main.mm
    src/app.cpp
    src/historic.cpp
    src/nexrad/level2_parser.cpp
    src/net/downloader.cpp
    src/net/polling_links.cpp
    src/net/warnings.cpp
    src/render/color_table.cpp
    src/render/metal_interop.mm
    src/metal/MetalRenderer.mm
    src/ui/ui.cpp
)

target_include_directories(cursdar2 PRIVATE
    src
    src/metal
)

# ── Objective-C++ compile flags for .mm files and app.cpp ─────────────
set_source_files_properties(
    src/main.mm
    src/render/metal_interop.mm
    src/metal/MetalRenderer.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)

set_source_files_properties(
    src/app.cpp
    src/ui/ui.cpp
    src/historic.cpp
    PROPERTIES COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
)

# ── Networking (libcurl) & compression (zlib) ────────────────────────
find_package(CURL REQUIRED)
find_package(ZLIB REQUIRED)

# ── Link libraries & frameworks ───────────────────────────────────────
target_link_libraries(cursdar2 PRIVATE
    imgui
    glfw
    BZip2::BZip2
    nlohmann_json::nlohmann_json
    CURL::libcurl
    ZLIB::ZLIB
    "-framework Metal"
    "-framework MetalKit"
    "-framework QuartzCore"
    "-framework Cocoa"
    "-framework IOKit"
    "-framework CoreFoundation"
)

# ── Shader dependency & post-build copy ───────────────────────────────
add_dependencies(cursdar2 metal_shaders)

if(METAL_COMPILER_FOUND EQUAL 0)
    add_custom_command(TARGET cursdar2 POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
            ${CMAKE_BINARY_DIR}/default.metallib
            $<TARGET_FILE_DIR:cursdar2>/default.metallib
    )
endif()
