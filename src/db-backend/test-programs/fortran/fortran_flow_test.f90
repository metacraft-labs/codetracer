! Simple Fortran program for MCR flow/omniscience DAP integration testing.
!
! Mirrors the C/Nim/Rust flow tests:
!   a = 10, b = 32, sum = 42, doubled = 84, final_result = 94
!
! Breakpoint is set at the `calculate_sum = final_result` assignment line
! inside `calculate_sum`; the DAP test verifies that the listed locals
! are reported with the expected values.

program fortran_flow_test
    implicit none
    integer :: x, y, result_val
    integer :: calculate_sum

    x = 10
    y = 32
    result_val = calculate_sum(x, y)
    print *, "Result:", result_val
end program fortran_flow_test

function calculate_sum(a, b) result(final_result)
    implicit none
    integer, intent(in) :: a, b
    integer :: sum_val, doubled, final_result
    sum_val = a + b
    doubled = sum_val * 2
    final_result = doubled + 10
    print *, "Sum:", sum_val
    print *, "Doubled:", doubled
    print *, "Final:", final_result
end function calculate_sum
