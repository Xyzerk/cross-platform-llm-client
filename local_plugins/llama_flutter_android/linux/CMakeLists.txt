# Linux build of the llama.cpp engine plugin.
#
# Flutter adds this file when the plugin is listed as an `ffiPlugin` under
# `linux`. It produces bundle/lib/libllama_flutter_android.so, which Dart opens
# through dart:ffi (lib/src/llama_desktop_ffi.dart).
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "llama_flutter_android")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# llama.cpp — the exact same source tree the Android/iOS/Windows build
# compiles, so the RPC protocol (v=rpc7) matches every worker byte for byte.
#
#   - everything static, linked into libllama_flutter_android.so
#   - CPU backend; no GGML_BACKEND_DL runtime loading
#   - GGML_RPC=ON: cluster client today, worker server once the POSIX worker
#     lands (Phase 3)
#   - Vulkan opt-in via PRIVATELM_LINUX_VULKAN; default CPU-only
#   - mtmd ON, mirroring Android, so vision-portable code compiles
# ---------------------------------------------------------------------------
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Static first: nothing but this .so ships" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "Vision support, as on Android" FORCE)
set(MTMD_VIDEO OFF CACHE BOOL "No ffmpeg dependency on Linux" FORCE)
set(GGML_RPC ON CACHE BOOL "Cluster (RPC) support" FORCE)
set(GGML_RPC_RDMA OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "Static backends" FORCE)

# ---------------------------------------------------------------------------
# Vulkan/GPU inference is opt-in:
#   PRIVATELM_LINUX_VULKAN=1 flutter build linux --release
#   scripts/build_linux.sh --vulkan
#
# The default build needs no Vulkan SDK and no libvulkan at runtime. A machine
# whose driver has no Vulkan ICD still starts: the backend registers zero
# devices, detectGpu() reports no GPU and the engine runs on the CPU.
# ---------------------------------------------------------------------------
set(LLAMA_LINUX_VULKAN OFF)
if(DEFINED ENV{PRIVATELM_LINUX_VULKAN})
    set(_plm_vulkan "$ENV{PRIVATELM_LINUX_VULKAN}")
    if(NOT _plm_vulkan STREQUAL "" AND
       NOT _plm_vulkan STREQUAL "0" AND
       NOT _plm_vulkan STREQUAL "OFF" AND
       NOT _plm_vulkan STREQUAL "off")
        set(LLAMA_LINUX_VULKAN ON)
    endif()
endif()

if(LLAMA_LINUX_VULKAN)
    message(STATUS "PrivateLM: Linux Vulkan backend enabled")
    set(GGML_VULKAN ON CACHE BOOL "ggml: use Vulkan" FORCE)
else()
    set(GGML_VULKAN OFF CACHE BOOL "ggml: use Vulkan" FORCE)
endif()

# EXCLUDE_FROM_ALL keeps llama.cpp's install() rules out of Flutter's install
# chain; the plugin .so is installed through PLUGIN_BUNDLED_LIBRARIES instead.
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp"
    "${CMAKE_BINARY_DIR}/llama.cpp"
    EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# The plugin .so: C ABI adapter (src/llama_ffi.cpp) over the shared engine core.
# ---------------------------------------------------------------------------
add_library(${PROJECT_NAME} SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/llama_ffi.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_core.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_engine.cpp"
)

target_include_directories(${PROJECT_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/ggml/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/tools/mtmd"
)

target_link_libraries(${PROJECT_NAME} PRIVATE
  llama
  ggml
  mtmd
  dl
  pthread
  m
)

# Keep the conventional lib<name>.so: Flutter copies it into bundle/lib and
# Dart opens it by absolute path.
set_target_properties(${PROJECT_NAME} PROPERTIES
  OUTPUT_NAME "${PROJECT_NAME}"
)

# ---------------------------------------------------------------------------
# Cluster worker: a separate process because ggml_backend_rpc_start_server
# blocks forever and cannot be stopped in-process. It links the same static
# llama.cpp/RPC code as the plugin, so the RPC protocol version matches every
# Android/iOS/Windows worker.
#
# It is installed into bundle/lib (Flutter's bundled-library contract); the
# Dart backend also looks next to the executable and on PATH.
# ---------------------------------------------------------------------------
add_executable(privatelm_rpc_worker
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/rpc_worker/main_common.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/rpc_worker/main_posix.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/rpc_worker/status_writer_posix.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/rpc_worker/mdns_advertiser_posix.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_core.cpp"
)

target_include_directories(privatelm_rpc_worker PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/rpc_worker"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/ggml/include"
)

target_link_libraries(privatelm_rpc_worker PRIVATE
  llama
  ggml
  dl
  pthread
  m
)

set_target_properties(privatelm_rpc_worker PROPERTIES
  OUTPUT_NAME "privatelm_rpc_worker"
  PREFIX ""
)

# The install step copies the bundled libraries next to the plugin; make sure
# the worker is built whenever the plugin is.
add_dependencies(${PROJECT_NAME} privatelm_rpc_worker)

# Flutter copies these into bundle/lib: the plugin .so and the worker binary.
set(${PROJECT_NAME}_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  $<TARGET_FILE:privatelm_rpc_worker>
  PARENT_SCOPE
)
