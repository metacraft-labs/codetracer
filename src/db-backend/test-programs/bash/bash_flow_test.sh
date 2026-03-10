#!/bin/bash
# Simple Bash program for flow/omniscience integration testing.
# This program tests that variables inside functions can be loaded
# and that function names and command names are filtered out
# from variable lists.
#
# The computation matches the other flow test programs:
#   a=10, b=32, sum_val=42, doubled=84, final_result=94

calculate_sum() {
	local a=$1
	local b=$2
	local sum_val=$((a + b))
	local doubled=$((sum_val * 2))
	local final_result=$((doubled + 10))
	echo "Sum: $sum_val"
	echo "Doubled: $doubled"
	echo "Final: $final_result"
	echo $final_result
}

x=10
y=32
result=$(calculate_sum $x $y)
echo "Result: $result"
