<?php
// Simple PHP program for flow/omniscience integration testing.
// The computation matches the Nim, Rust, Go, Python, and Ruby flow test programs:
//   a=10, b=32, sum_val=42, doubled=84, final_result=94

function calculate_sum($a, $b) {
    $sum_val = $a + $b;
    $doubled = $sum_val * 2;
    $final_result = $doubled + 10;
    echo "Sum: $sum_val\n";
    echo "Doubled: $doubled\n";
    echo "Final: $final_result\n";
    return $final_result;
}

$x = 10;
$y = 32;
$result = calculate_sum($x, $y);
echo "Result: $result\n";
