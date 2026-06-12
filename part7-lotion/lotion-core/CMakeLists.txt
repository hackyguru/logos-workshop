cmake_minimum_required(VERSION 3.14)
project(LotionPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

find_package(Qt6      REQUIRED COMPONENTS Sql)
find_package(OpenSSL  REQUIRED)

logos_module(
    NAME lotion
    SOURCES
        src/lotion_interface.h
        src/lotion_plugin.h
        src/lotion_plugin.cpp
)

# logos_module() names the CMake target `<NAME>_module_plugin` even though
# the produced .dylib is `<NAME>_plugin` — see part 2's notes.
target_link_libraries(lotion_module_plugin
    PRIVATE
        Qt6::Sql
        OpenSSL::Crypto
)
