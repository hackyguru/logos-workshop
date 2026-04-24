cmake_minimum_required(VERSION 3.14)
project(CounterPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

logos_module(
    NAME counter
    SOURCES
        src/counter_interface.h
        src/counter_plugin.h
        src/counter_plugin.cpp
)
