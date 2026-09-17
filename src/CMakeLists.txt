set(CEF_TARGET "cha")
set(CEF_HELPER_TARGET "cha_Helper")
set(CEF_HELPER_OUTPUT_NAME "cha Helper")

SET_CEF_TARGET_OUT_DIR()

# The CEF layer: Objective-C++ compiled as C++ so the CEF headers get C++20.
add_library(chacore STATIC core/ChaEngine.mm core/ChaTab.mm)
target_include_directories(chacore PUBLIC "${CEF_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/core")
SET_LIBRARY_TARGET_PROPERTIES(chacore)
target_compile_options(chacore PRIVATE -fobjc-arc)
add_dependencies(chacore libcef_dll_wrapper)
target_link_libraries(chacore libcef_dll_wrapper ${CEF_STANDARD_LIBS})

set(CEF_APP "${CEF_TARGET_OUT_DIR}/${CEF_TARGET}.app")
set(EXECUTABLE_NAME "${CEF_TARGET}")
set(PRODUCT_NAME "${CEF_TARGET}")

file(GLOB CHA_SWIFT_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/app/*.swift")
add_executable(${CEF_TARGET} MACOSX_BUNDLE ${CHA_SWIFT_SRCS})
target_compile_options(${CEF_TARGET} PRIVATE
  "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/core/ChaCore.h")
target_link_libraries(${CEF_TARGET} chacore)
set_target_properties(${CEF_TARGET} PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/mac/Info.plist.in)

COPY_MAC_FRAMEWORK("${CEF_TARGET}" "${CEF_BINARY_DIR}" "${CEF_APP}")

foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_helper_target "${CEF_HELPER_TARGET}${_target_suffix}")
  set(_helper_output_name "${CEF_HELPER_OUTPUT_NAME}${_name_suffix}")

  set(_helper_info_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/mac/helper-Info.plist.in" _plist_contents)
  string(REPLACE "\${EXECUTABLE_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${PRODUCT_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${_plist_suffix}" _plist_contents ${_plist_contents})
  file(WRITE ${_helper_info_plist} ${_plist_contents})

  add_executable(${_helper_target} MACOSX_BUNDLE mac/helper_mac.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  add_dependencies(${_helper_target} libcef_dll_wrapper)
  target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${_helper_info_plist}
    OUTPUT_NAME ${_helper_output_name})

  add_dependencies(${CEF_TARGET} "${_helper_target}")
  add_custom_command(TARGET ${CEF_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CEF_TARGET_OUT_DIR}/${_helper_output_name}.app"
            "${CEF_APP}/Contents/Frameworks/${_helper_output_name}.app"
    VERBATIM)
endforeach()
