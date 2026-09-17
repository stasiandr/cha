cmake_minimum_required(VERSION 3.21)
project(cha LANGUAGES C CXX Swift)

set_property(GLOBAL PROPERTY OS_FOLDERS ON)
set(PROJECT_ARCH "arm64")
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef")
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

add_subdirectory(src)
