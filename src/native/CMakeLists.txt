cmake_minimum_required(VERSION 3.20)
project(LastEpochNative VERSION 0.1.0 LANGUAGES CXX)
if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Use Windows MSVC x64, for example -G \"Visual Studio 17 2022\" -A x64.")
endif()

function(le_native_target name)
  add_library(${name} SHARED Native.cpp Native.h Upscaler.h ${ARGN})
  target_compile_features(${name} PRIVATE cxx_std_17)
  target_compile_definitions(${name} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(${name} PRIVATE d3d11 dxgi)
  set_property(TARGET ${name} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
  target_compile_options(${name} PRIVATE /W4 /EHsc)
endfunction()

# The default bridge resolves an already-loaded OptiScaler. No NVIDIA SDK or
# NVIDIA binaries are linked into this build.
le_native_target(LastEpochNative OptiBackend.cpp NgxProtocol.h)

option(LE_BUILD_SMOKE "Build a software D3D11 ABI/contract smoke test" ON)
if(LE_BUILD_SMOKE)
  enable_testing()
  add_executable(LastEpochNativeSmoke NativeSmoke.cpp Native.h)
  target_compile_features(LastEpochNativeSmoke PRIVATE cxx_std_17)
  target_compile_definitions(LastEpochNativeSmoke PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(LastEpochNativeSmoke PRIVATE LastEpochNative d3d11)
  target_compile_options(LastEpochNativeSmoke PRIVATE /W4 /EHsc)
  add_test(NAME NativeSoftwareContract COMMAND LastEpochNativeSmoke "${CMAKE_CURRENT_BINARY_DIR}/smoke-logs")
endif()

# Optional read-only FG telemetry. This does not initialize, configure or enable
# Streamline; the OptiScaler provider owns those operations.
set(STREAMLINE_ROOT "" CACHE PATH "Optional Streamline SDK for read-only DLSS-G telemetry")
if(STREAMLINE_ROOT)
  find_path(STREAMLINE_INCLUDE sl_dlss_g.h PATHS "${STREAMLINE_ROOT}/include" "${STREAMLINE_ROOT}" NO_DEFAULT_PATH REQUIRED)
  target_include_directories(LastEpochNative PRIVATE "${STREAMLINE_INCLUDE}")
  target_compile_definitions(LastEpochNative PRIVATE LE_STREAMLINE_TELEMETRY=1)
endif()

# Maintained as a separate opt-in backend, never a dependency of the bridge.
option(LE_BUILD_NGX "Build standalone NVIDIA NGX SR backend (requires SDK)" OFF)
if(LE_BUILD_NGX)
  set(NGX_ROOT "" CACHE PATH "NVIDIA DLSS SDK")
  find_path(NGX_INCLUDE nvsdk_ngx.h PATHS "${NGX_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
  find_library(NGX_LIBRARY nvsdk_ngx_d PATHS "${NGX_ROOT}/lib/Windows_x86_64/x64" "${NGX_ROOT}/lib/Windows_x86_64" "${NGX_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
  if(NOT STREAMLINE_INCLUDE)
    message(FATAL_ERROR "LE_BUILD_NGX also requires STREAMLINE_ROOT for reporting headers")
  endif()
  le_native_target(LastEpochNgxNative NgxSdkBackend.cpp)
  target_include_directories(LastEpochNgxNative PRIVATE "${NGX_INCLUDE}" "${STREAMLINE_INCLUDE}")
  target_link_libraries(LastEpochNgxNative PRIVATE "${NGX_LIBRARY}")
endif()
