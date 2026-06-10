program test_calculator
  implicit none
  if (add(2, 3) /= 5) error stop 1
  print *, "fortran fixture passed"
contains
  integer function add(a, b)
    integer, intent(in) :: a, b
    add = a + b
  end function add
end program test_calculator
