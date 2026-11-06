# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
cmake_minimum_required(VERSION 3.20)
project(PatchPrimeMacDriver CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# libASPL is built on its own first: its generator step doesn't work as a subproject.
set(ASPL_PREFIX ${CMAKE_CURRENT_LIST_DIR}/../build/aspl-prefix)

add_library(PatchPrimeMac MODULE Driver.cpp)
target_include_directories(PatchPrimeMac PRIVATE ${ASPL_PREFIX}/include)
target_link_libraries(PatchPrimeMac PRIVATE ${ASPL_PREFIX}/lib/libASPL.a
    "-framework CoreFoundation" "-framework CoreAudio")
target_compile_options(PatchPrimeMac PRIVATE -Wall -Wextra -Wno-unused-parameter)
set_target_properties(PatchPrimeMac PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION driver
    PREFIX ""
    SUFFIX ""
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in)
add_custom_command(TARGET PatchPrimeMac POST_BUILD
    COMMAND codesign --force --sign - $<TARGET_BUNDLE_DIR:PatchPrimeMac>
    VERBATIM)

add_executable(ppdriver ppdriver.cpp)
target_link_libraries(ppdriver PRIVATE "-framework CoreAudio" "-framework CoreFoundation")
target_compile_options(ppdriver PRIVATE -Wall -Wextra)
