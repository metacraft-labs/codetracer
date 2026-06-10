cmake_minimum_required(VERSION 3.20)
project(ct_m10_catch2_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()
find_package(Catch2 3 REQUIRED)

add_executable(catch2_math_tests tests/math_test.cpp)
target_link_libraries(catch2_math_tests PRIVATE Catch2::Catch2WithMain)

include(CTest)
include(Catch)
catch_discover_tests(catch2_math_tests)
