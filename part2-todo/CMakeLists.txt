cmake_minimum_required(VERSION 3.14)
project(TodoPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

find_package(Qt6 REQUIRED COMPONENTS Sql)

logos_module(
    NAME todo
    SOURCES
        src/todo_interface.h
        src/todo_plugin.h
        src/todo_plugin.cpp
)

# logos_module() names the CMake target `<NAME>_module_plugin` (output file is
# still `<NAME>_plugin`). That's why we link against `todo_module_plugin` even
# though the .dylib ends up as `todo_plugin.dylib`.
target_link_libraries(todo_module_plugin PRIVATE Qt6::Sql)
