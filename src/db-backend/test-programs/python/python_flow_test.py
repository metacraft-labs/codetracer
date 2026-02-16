# Simple Python program for flow/omniscience integration testing.
# This program tests that local variables inside functions can be loaded
# and that function calls (print, calculate_sum) are filtered out from variable lists.
#
# The computation matches the Nim, Rust, and Go flow test programs:
#   a=10, b=32, sum_val=42, doubled=84, final_result=94
#
# Note: using sum_val instead of sum (Python builtin) and final_result instead
# of final (Python reserved word).


def calculate_sum(a, b):
    # Local variables inside a function — these should be extracted
    sum_val = a + b
    doubled = sum_val * 2
    final_result = doubled + 10
    print("Sum:", sum_val)
    print("Doubled:", doubled)
    print("Final:", final_result)
    return final_result


# Local variables in main scope
x = 10
y = 32
result = calculate_sum(x, y)
print("Result:", result)
