! Sudoku solver using backtracking.
! Compiled with: gfortran -g -O0 sudoku.f90 -o sudoku
! Produces DWARF debug info for codetracer RR-based tracing.
program sudoku_main
  implicit none

  integer, parameter :: SIZE = 9
  integer :: board(SIZE, SIZE)
  integer :: boards(SIZE, SIZE, 10)
  integer :: i

  ! Initialize all boards to zero
  boards = 0

  ! Example 1
  boards(:,:,1) = reshape([ &
    5,3,0,0,7,0,0,0,0, &
    6,0,0,1,9,5,0,0,0, &
    0,9,8,0,0,0,0,6,0, &
    8,0,0,0,6,0,0,0,3, &
    4,0,0,8,0,3,0,0,1, &
    7,0,0,0,2,0,0,0,6, &
    0,6,0,0,0,0,2,8,0, &
    0,0,0,4,1,9,0,0,5, &
    0,0,0,0,8,0,0,7,9], [SIZE, SIZE])
  ! Fortran stores column-major, so we transpose
  boards(:,:,1) = transpose(boards(:,:,1))

  ! Example 2
  boards(:,:,2) = reshape([ &
    0,0,0,0,0,0,0,0,0, &
    0,0,0,0,0,3,0,8,5, &
    0,0,1,0,2,0,0,0,0, &
    0,0,0,0,0,0,0,0,7, &
    0,0,0,0,1,0,0,0,0, &
    3,0,0,0,0,0,0,0,0, &
    0,0,0,0,4,0,1,0,0, &
    5,7,0,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0], [SIZE, SIZE])
  boards(:,:,2) = transpose(boards(:,:,2))

  ! Example 3
  boards(:,:,3) = reshape([ &
    1,0,0,0,0,7,0,9,0, &
    0,3,0,0,2,0,0,0,8, &
    0,0,9,6,0,0,5,0,0, &
    0,0,5,3,0,0,9,0,0, &
    0,1,0,0,0,0,0,0,2, &
    0,0,6,0,0,3,0,0,0, &
    0,6,0,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0], [SIZE, SIZE])
  boards(:,:,3) = transpose(boards(:,:,3))

  ! Example 4
  boards(:,:,4) = reshape([ &
    0,0,0,2,6,0,7,0,1, &
    6,8,0,0,7,0,0,9,0, &
    1,9,0,0,0,4,5,0,0, &
    8,2,0,1,0,0,0,4,0, &
    0,0,4,6,0,2,9,0,0, &
    0,5,0,0,0,3,0,2,8, &
    0,0,9,3,0,0,0,7,4, &
    0,4,0,0,5,0,0,3,6, &
    7,0,3,0,1,8,0,0,0], [SIZE, SIZE])
  boards(:,:,4) = transpose(boards(:,:,4))

  ! Examples 5-10 (various sparse boards)
  boards(:,:,5) = boards(:,:,2)

  boards(:,:,6) = reshape([ &
    0,0,0,0,0,0,0,0,6, &
    0,0,0,0,0,3,0,0,0, &
    0,0,1,0,2,0,0,0,0, &
    0,0,0,0,6,0,0,0,3, &
    4,0,0,8,0,3,0,0,1, &
    7,0,0,0,2,0,0,0,6, &
    0,6,0,0,0,0,2,8,0, &
    0,0,0,4,1,9,0,0,5, &
    0,0,0,0,8,0,0,7,9], [SIZE, SIZE])
  boards(:,:,6) = transpose(boards(:,:,6))

  boards(:,:,7) = reshape([ &
    9,0,0,0,0,0,0,0,5, &
    0,1,0,0,0,5,0,0,0, &
    0,0,0,3,0,0,0,8,0, &
    0,0,0,0,0,6,0,0,0, &
    0,0,0,0,0,0,2,0,0, &
    3,0,7,0,0,0,0,0,1, &
    0,6,0,0,0,0,0,9,0, &
    0,0,0,4,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0], [SIZE, SIZE])
  boards(:,:,7) = transpose(boards(:,:,7))

  boards(:,:,8) = reshape([ &
    2,0,0,0,0,0,0,0,0, &
    0,0,0,0,0,3,0,8,5, &
    0,0,1,0,2,0,0,0,0, &
    0,0,0,0,0,0,0,0,7, &
    0,0,0,0,1,0,0,0,0, &
    3,0,0,0,0,0,0,0,0, &
    0,0,0,0,4,0,1,0,0, &
    5,7,0,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0], [SIZE, SIZE])
  boards(:,:,8) = transpose(boards(:,:,8))

  boards(:,:,9) = reshape([ &
    0,0,0,0,7,0,0,0,0, &
    6,0,0,1,9,5,0,0,0, &
    0,9,8,0,0,0,0,6,0, &
    8,0,0,0,6,0,0,0,3, &
    4,0,0,8,0,3,0,0,1, &
    7,0,0,0,2,0,0,0,6, &
    0,6,0,0,0,0,2,8,0, &
    0,0,0,4,1,9,0,0,5, &
    0,0,0,0,8,0,0,7,0], [SIZE, SIZE])
  boards(:,:,9) = transpose(boards(:,:,9))

  boards(:,:,10) = reshape([ &
    0,0,0,4,0,0,0,0,0, &
    0,0,0,0,0,3,0,8,5, &
    0,2,1,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,7, &
    0,0,0,0,1,0,0,0,0, &
    3,0,0,0,0,0,0,0,0, &
    0,0,0,0,4,0,1,0,0, &
    5,7,0,0,0,0,0,0,0, &
    0,0,0,0,0,0,0,0,0], [SIZE, SIZE])
  boards(:,:,10) = transpose(boards(:,:,10))

  do i = 1, 10
    board = boards(:,:,i)
    write(*,'(A,I0,A)') 'Test Sudoku #', i, ' (Before):'
    call print_board(board)
    if (solve(board)) then
      write(*,'(A,I0,A)') 'Solved Sudoku #', i, ':'
      call print_board(board)
    else
      write(*,'(A,I0,A)') 'No solution found for Sudoku #', i, '.'
    end if
    write(*,'(A)') '-----------------------------------------'
  end do

contains

  subroutine print_board(board)
    integer, intent(in) :: board(SIZE, SIZE)
    integer :: r, c
    do r = 1, SIZE
      do c = 1, SIZE
        if (board(r, c) == 0) then
          write(*,'(A)', advance='no') '. '
        else
          write(*,'(I0,A)', advance='no') board(r, c), ' '
        end if
      end do
      write(*,*)
    end do
  end subroutine

  logical function is_valid(board, row, col, num)
    integer, intent(in) :: board(SIZE, SIZE), row, col, num
    integer :: r, c, box_row_start, box_col_start

    ! Check row
    do c = 1, SIZE
      if (board(row, c) == num) then
        is_valid = .false.
        return
      end if
    end do

    ! Check column
    do r = 1, SIZE
      if (board(r, col) == num) then
        is_valid = .false.
        return
      end if
    end do

    ! Check 3x3 box
    box_row_start = ((row - 1) / 3) * 3 + 1
    box_col_start = ((col - 1) / 3) * 3 + 1
    do r = box_row_start, box_row_start + 2
      do c = box_col_start, box_col_start + 2
        if (board(r, c) == num) then
          is_valid = .false.
          return
        end if
      end do
    end do

    is_valid = .true.
  end function

  logical function find_empty_cell(board, row, col)
    integer, intent(in) :: board(SIZE, SIZE)
    integer, intent(out) :: row, col

    do row = 1, SIZE
      do col = 1, SIZE
        if (board(row, col) == 0) then
          find_empty_cell = .true.
          return
        end if
      end do
    end do

    find_empty_cell = .false.
  end function

  recursive logical function solve(board) result(solved)
    integer, intent(inout) :: board(SIZE, SIZE)
    integer :: row, col, num

    if (.not. find_empty_cell(board, row, col)) then
      solved = .true.
      return
    end if

    do num = 1, 9
      if (is_valid(board, row, col, num)) then
        board(row, col) = num
        if (solve(board)) then
          solved = .true.
          return
        end if
        board(row, col) = 0  ! backtrack
      end if
    end do

    solved = .false.
  end function

end program sudoku_main
