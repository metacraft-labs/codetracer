cmake_minimum_required(VERSION 3.20)
project(ct_m10_ctest_fallback_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

add_executable(fallback_smoke tests/fallback_smoke.cpp)
add_test(NAME fallback_smoke COMMAND fallback_smoke)
add_test(NAME fallback_named_arg COMMAND fallback_smoke --named)
