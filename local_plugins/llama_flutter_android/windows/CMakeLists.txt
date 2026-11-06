# The Flutter tooling requires CMake 3.14 or later. Do not raise this minimum:
# it would break users on older Visual Studio installations.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "llama_flutter_android")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# llama.cpp — the exact same source tree the Android/iOS build compiles, so
# the RPC protocol (v=rpc7) matches every worker byte for byte.
#
# Phase 1 configuration, per docs/windows-port-plan.md §4:
#   - everything static, linked into llama_flutter_android.dll (no ggml-*.dll
#     files to ship or load)
#   - CPU backend (plain, no GGML_BACKEND_DL variant .so loading)
#   - GGML_RPC=ON: cluster client today, worker server in Phase 4
#   - Vulkan deferred to Phase 2c (GGML_VULKAN stays OFF)
#   - mtmd ON, mirroring the Android build, so vision-portable code compiles
# ---------------------------------------------------------------------------
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Static first: nothing but this DLL ships" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "Vision support, as on Android" FORCE)
set(MTMD_VIDEO OFF CACHE BOOL "No ffmpeg on Windows" FORCE)
set(GGML_RPC ON CACHE BOOL "Cluster (RPC) support" FORCE)
set(GGML_RPC_RDMA OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "Static backends for the first Windows build" FORCE)

# llama.cpp ships unconditional install() rules (llama.lib, headers,
# pkg-config files). Flutter's INSTALL step runs them with its
# "$<TARGET_FILE_DIR:privatelm>" prefix — the llama.cpp rules resolve their
# destinations at *install-script runtime*, so the generator expression the
# runner needs is seen raw and the script dies trying to create a literal
# "$<TARGET_FILE_DIR:privatelm>/lib" directory. Everything here is statically
# linked into the plugin DLL and Flutter copies that via its
# PLUGIN_BUNDLED_LIBRARIES contract at the runner level, so llama.cpp's rules
# are never wanted — they only poison the install chain.
#
# EXCLUDE_FROM_ALL severs the subtree from the build's default install
# pass: CMake's generated top-level install script only includes child
# directories that are not excluded from all, so llama.cpp's cmake_install
# script is never executed. Targets still build normally because the plugin
# DLL links them. (A no-op `function(install)` override is not an option:
# function definitions in a subdirectory leak back to the parent scope and
# would silently kill Flutter's own runner install rules too.)
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp"
    "${CMAKE_BINARY_DIR}/llama.cpp"
    EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# The plugin DLL: C ABI adapter (llama_ffi.cpp) over the shared engine core.
# ---------------------------------------------------------------------------
add_library(${PROJECT_NAME} SHARED
  "llama_ffi.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_core.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_engine.cpp"
)

target_include_directories(${PROJECT_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/ggml/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/tools/mtmd"
)

target_link_libraries(${PROJECT_NAME} PRIVATE
  llama
  ggml
  mtmd
)

# Dart FFI loads the library by its bare name, so keep the output name stable
# and do not add a "lib" prefix.
set_target_properties(${PROJECT_NAME} PROPERTIES
  OUTPUT_NAME "${PROJECT_NAME}"
  PREFIX ""
)

# Flutter copies this into the runner output directory. Everything else is
# statically linked, so the DLL is the only artifact to bundle.
set(${PROJECT_NAME}_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  PARENT_SCOPE
)
