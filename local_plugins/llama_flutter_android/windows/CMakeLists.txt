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
#   - Vulkan opt-in via PRIVATELM_WINDOWS_VULKAN (Phase 2c); default CPU-only
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

# ---------------------------------------------------------------------------
# Vulkan/GPU inference (Phase 2c) is opt-in. The default build stays CPU-only:
# it needs no Vulkan SDK and no vulkan-1.dll at runtime.
#
# Enable it for one build with:
#   $env:PRIVATELM_WINDOWS_VULKAN = 1; flutter build windows --release
# or `scripts/build_windows.ps1 -Release -Vulkan`.
#
# The backend is compiled into the plugin DLL. A machine without a Vulkan ICD
# (or without Vulkan support in its driver) still starts: the backend registers
# zero devices, detectGpu() reports no GPU and the engine runs on the CPU.
# ---------------------------------------------------------------------------
set(LLAMA_WINDOWS_VULKAN OFF)
if(DEFINED ENV{PRIVATELM_WINDOWS_VULKAN})
    set(_plm_vulkan "$ENV{PRIVATELM_WINDOWS_VULKAN}")
    if(NOT _plm_vulkan STREQUAL "" AND
       NOT _plm_vulkan STREQUAL "0" AND
       NOT _plm_vulkan STREQUAL "OFF" AND
       NOT _plm_vulkan STREQUAL "off")
        set(LLAMA_WINDOWS_VULKAN ON)
    endif()
endif()

if(LLAMA_WINDOWS_VULKAN)
    # ggml's Vulkan target runs find_package(Vulkan COMPONENTS glslc), then
    # find_package(SPIRV-Headers CONFIG) after appending $ENV{VULKAN_SDK} to
    # CMAKE_PREFIX_PATH. Find the SDK once here and export it so the
    # subdirectory sees the same one.
    if(NOT DEFINED ENV{VULKAN_SDK} AND DEFINED ENV{Vulkan_ROOT})
        set(ENV{VULKAN_SDK} "$ENV{Vulkan_ROOT}")
    endif()
    if(NOT DEFINED ENV{VULKAN_SDK})
        file(GLOB _plm_vulkan_sdks "$ENV{ProgramFiles}/VulkanSDK/*")
        if(_plm_vulkan_sdks)
            list(SORT _plm_vulkan_sdks)
            list(REVERSE _plm_vulkan_sdks)
            list(GET _plm_vulkan_sdks 0 _plm_vulkan_sdk)
            set(ENV{VULKAN_SDK} "${_plm_vulkan_sdk}")
        endif()
    endif()
    if(NOT DEFINED ENV{VULKAN_SDK})
        message(FATAL_ERROR
            "PRIVATELM_WINDOWS_VULKAN is set but no Vulkan SDK was found. "
            "Install it from https://vulkan.lunarg.com or set VULKAN_SDK.")
    endif()
    message(STATUS "PrivateLM: Vulkan backend enabled (SDK $ENV{VULKAN_SDK})")
    set(GGML_VULKAN ON CACHE BOOL "ggml: use Vulkan" FORCE)
    # ggml builds the Vulkan shader generator with ExternalProject. Its default
    # prefix lives under llama.cpp/ggml/src/ggml-vulkan, which pushes MSBuild's
    # FileTracker log paths past MAX_PATH and fails with FTK1011. EP_BASE is a
    # directory property inherited by the llama.cpp subtree; a short base keeps
    # the nested configure under the limit.
    set_property(DIRECTORY PROPERTY EP_BASE "${CMAKE_BINARY_DIR}/ep")
else()
    set(GGML_VULKAN OFF CACHE BOOL "ggml: use Vulkan" FORCE)
endif()

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

# ---------------------------------------------------------------------------
# Cluster worker (Phase 4): a separate process because
# ggml_backend_rpc_start_server blocks forever and cannot be stopped in-process.
# It links the same static llama.cpp/RPC code as the DLL, so the RPC protocol
# version matches every Android/iOS worker.
# ---------------------------------------------------------------------------
add_executable(privatelm_rpc_worker
  "rpc_worker/main.cpp"
  "rpc_worker/status_writer.cpp"
  "rpc_worker/mdns_advertiser.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/plm_core.cpp"
)

target_include_directories(privatelm_rpc_worker PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/ggml/include"
)

target_compile_definitions(privatelm_rpc_worker PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  UNICODE
  _UNICODE
)

target_link_libraries(privatelm_rpc_worker PRIVATE
  llama
  ggml
  ws2_32
  dnsapi
  psapi
)

set_target_properties(privatelm_rpc_worker PROPERTIES
  OUTPUT_NAME "privatelm_rpc_worker"
  PREFIX ""
)

# The install step copies bundled libraries next to privatelm.exe. Make sure
# the worker is built whenever the plugin is.
add_dependencies(${PROJECT_NAME} privatelm_rpc_worker)

# Flutter copies these into the runner output directory. Everything else is
# statically linked, so the DLL and the worker exe are the only artifacts.
set(${PROJECT_NAME}_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  $<TARGET_FILE:privatelm_rpc_worker>
  PARENT_SCOPE
)
