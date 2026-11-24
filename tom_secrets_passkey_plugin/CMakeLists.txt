# Copyright (c) 2026 Peter Nicolai Alexis Kyaw
# SPDX-License-Identifier: BSD-3-Clause
#
# tsm-passkey-plugin: the Windows 11 passkey plugin of the Tom Secrets
# Manager. Its core (CTAP2 requests as the service's passkey requests) and
# its tests build everywhere; the executable (the COM server and the
# registration commands) on Windows only.
#
# The C client comes from its release tag. A local checkout is used with
#   -DFETCHCONTENT_SOURCE_DIR_TSM_C=<a tom_secrets_clients checkout>
cmake_minimum_required(VERSION 3.18)
project(tom_secrets_passkey_plugin VERSION 0.1.0 LANGUAGES C CXX)

option(TSM_WERROR "Treat warnings as errors" OFF)
option(TSM_PLUGIN_BUILD_TESTS "Build the plugin's tests" ${PROJECT_IS_TOP_LEVEL})

include(FetchContent)
set(TSM_BUILD_TESTS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(tsm_c
  GIT_REPOSITORY https://github.com/al-the-bear/tom_secrets_clients.git
  GIT_TAG clients/c/v0.2.0
  GIT_SHALLOW TRUE
  SOURCE_SUBDIR clients/c)
FetchContent_MakeAvailable(tsm_c)

function(tsm_plugin_options target)
  set_target_properties(${target} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
  if(WIN32)
    target_compile_definitions(${target} PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE
      _CRT_SECURE_NO_WARNINGS)
  endif()
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /utf-8 $<$<BOOL:${TSM_WERROR}>:/WX>)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Wshadow
      $<$<BOOL:${TSM_WERROR}>:-Werror>)
  endif()
endfunction()

add_library(tsm_plugin_core STATIC src/core.cpp src/client_service.cpp)
target_include_directories(tsm_plugin_core PUBLIC src)
target_link_libraries(tsm_plugin_core PUBLIC tsm::tsm)
tsm_plugin_options(tsm_plugin_core)

if(WIN32)
  add_library(tsm_plugin_windows STATIC src/windows/webauthn_api.cpp src/windows/authenticator.cpp)
  target_link_libraries(tsm_plugin_windows PUBLIC tsm_plugin_core bcrypt ncrypt ole32 shell32 crypt32)
  tsm_plugin_options(tsm_plugin_windows)

  add_executable(tsm-passkey-plugin WIN32 src/windows/main.cpp)
  target_link_libraries(tsm-passkey-plugin PRIVATE tsm_plugin_windows)
  tsm_plugin_options(tsm-passkey-plugin)
  install(TARGETS tsm-passkey-plugin RUNTIME DESTINATION bin)
endif()

if(TSM_PLUGIN_BUILD_TESTS)
  enable_testing()
  add_executable(tsm_plugin_tests tests/core_tests.cpp)
  target_link_libraries(tsm_plugin_tests PRIVATE tsm_plugin_core)
  tsm_plugin_options(tsm_plugin_tests)
  add_test(NAME tsm_plugin_tests COMMAND tsm_plugin_tests)
  if(WIN32)
    # The COM authenticator against recorded CTAP2 requests, decoded and
    # encoded by this Windows' webauthn.dll.
    add_executable(tsm_plugin_windows_tests tests/windows_tests.cpp)
    target_link_libraries(tsm_plugin_windows_tests PRIVATE tsm_plugin_windows)
    tsm_plugin_options(tsm_plugin_windows_tests)
    add_test(NAME tsm_plugin_windows_tests COMMAND tsm_plugin_windows_tests)
  endif()
endif()
