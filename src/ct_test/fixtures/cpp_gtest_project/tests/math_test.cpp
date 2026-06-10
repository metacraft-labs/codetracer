#include <gtest/gtest.h>

int add(int left, int right) {
  return left + right;
}

class CalculatorFixture : public ::testing::Test {
 protected:
  int base = 40;
};

TEST(MathTest, AddsNumbers) {
  EXPECT_EQ(add(2, 3), 5);
}

TEST_F(CalculatorFixture, UsesFixtureState) {
  EXPECT_EQ(add(base, 2), 42);
}

// TEST(CommentedOut, IsIgnored) {}

const char* ignored = "TEST(StringLiteral, IsIgnored)";

TEST(MathTest,
     MultiLineMacro) {
  EXPECT_EQ(add(1, 1), 2);
}
