#include <catch2/catch_test_macros.hpp>

int multiply(int left, int right) {
  return left * right;
}

TEST_CASE("multiplication works", "[math][fast]") {
  REQUIRE(multiply(6, 7) == 42);

  SECTION("identity") {
    REQUIRE(multiply(7, 1) == 7);
  }
}

SCENARIO("zero multiplication") {
  REQUIRE(multiply(10, 0) == 0);
}

// TEST_CASE("commented out") {}

const char* ignored = "TEST_CASE(\"string literal\")";
