cmake_minimum_required(VERSION 3.20)
project(ct_m10_gtest_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()
find_package(GTest REQUIRED)

add_executable(gtest_math_tests tests/math_test.cpp)
target_link_libraries(gtest_math_tests PRIVATE GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(gtest_math_tests)
