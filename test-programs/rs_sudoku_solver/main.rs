fn print_board(board: &[[u8; 9]; 9]) {
    for row in 0..9 {
        for col in 0..9 {
            let val = board[row][col];
            if val == 0 {
                print!(". ");
            } else {
                print!("{} ", val);
            }
        }
        println!();
    }
}

fn is_valid(board: &[[u8; 9]; 9], row: usize, col: usize, num: u8) -> bool {
    // Check row
    for c in 0..9 {
        if board[row][c] == num {
            return false;
        }
    }
    // Check column
    for r in 0..9 {
        if board[r][col] == num {
            return false;
        }
    }
    // Check 3x3 box
    let box_row_start = (row / 3) * 3;
    let box_col_start = (col / 3) * 3;
    for r in box_row_start..(box_row_start + 3) {
        for c in box_col_start..(box_col_start + 3) {
            if board[r][c] == num {
                return false;
            }
        }
    }
    true
}

fn find_empty_cell(board: &[[u8; 9]; 9]) -> Option<(usize, usize)> {
    for r in 0..9 {
        for c in 0..9 {
            if board[r][c] == 0 {
                return Some((r, c));
            }
        }
    }
    None
}

fn solve_sudoku(board: &mut [[u8; 9]; 9]) -> bool {
    let empty = find_empty_cell(board);
    if empty.is_none() {
        return true; // Solved
    }
    let (row, col) = empty.unwrap();

    for num in 1..=9 {
        if is_valid(board, row, col, num) {
            board[row][col] = num;
            if solve_sudoku(board) {
                return true;
            }
            board[row][col] = 0; // backtrack
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solves_classic_board() {
        // Classic Sudoku puzzle from the sample program with its known solution.
        let mut board: [[u8; 9]; 9] = [
            [5, 3, 0, 0, 7, 0, 0, 0, 0],
            [6, 0, 0, 1, 9, 5, 0, 0, 0],
            [0, 9, 8, 0, 0, 0, 0, 6, 0],
            [8, 0, 0, 0, 6, 0, 0, 0, 3],
            [4, 0, 0, 8, 0, 3, 0, 0, 1],
            [7, 0, 0, 0, 2, 0, 0, 0, 6],
            [0, 6, 0, 0, 0, 0, 2, 8, 0],
            [0, 0, 0, 4, 1, 9, 0, 0, 5],
            [0, 0, 0, 0, 8, 0, 0, 7, 9],
        ];
        let expected_solution: [[u8; 9]; 9] = [
            [5, 3, 4, 6, 7, 8, 9, 1, 2],
            [6, 7, 2, 1, 9, 5, 3, 4, 8],
            [1, 9, 8, 3, 4, 2, 5, 6, 7],
            [8, 5, 9, 7, 6, 1, 4, 2, 3],
            [4, 2, 6, 8, 5, 3, 7, 9, 1],
            [7, 1, 3, 9, 2, 4, 8, 5, 6],
            [9, 6, 1, 5, 3, 7, 2, 8, 4],
            [2, 8, 7, 4, 1, 9, 6, 3, 5],
            [3, 4, 5, 2, 8, 6, 1, 7, 9],
        ];

        println!("Solving classic Sudoku board used by the CLI example");
        let solved = solve_sudoku(&mut board);
        assert!(solved, "solver should succeed on a valid puzzle");
        assert_eq!(board, expected_solution);
    }

    #[test]
    fn rejects_unsolvable_board() {
        // The last cell in the first row cannot take any value because 9 is already
        // present in the same column, so backtracking must eventually give up.
        let mut board: [[u8; 9]; 9] = [
            [1, 2, 3, 4, 5, 6, 7, 8, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 9],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0, 0],
        ];

        println!("Trying to solve an intentionally inconsistent puzzle");
        assert!(
            !solve_sudoku(&mut board),
            "solver should report failure when the first row cannot be completed"
        );
        assert_eq!(
            board[0][8],
            0,
            "solver should leave the impossible cell untouched when it backtracks"
        );
    }
}

fn main() {
    let mut test_boards = vec![
        // Example 1
        [
            [5,3,0,0,7,0,0,0,0],
            [6,0,0,1,9,5,0,0,0],
            [0,9,8,0,0,0,0,6,0],
            [8,0,0,0,6,0,0,0,3],
            [4,0,0,8,0,3,0,0,1],
            [7,0,0,0,2,0,0,0,6],
            [0,6,0,0,0,0,2,8,0],
            [0,0,0,4,1,9,0,0,5],
            [0,0,0,0,8,0,0,7,9],
        ],
        // Example 2
        [
            [0,0,0,0,0,0,0,0,0],
            [0,0,0,0,0,3,0,8,5],
            [0,0,1,0,2,0,0,0,0],
            [0,0,0,0,0,0,0,0,7],
            [0,0,0,0,1,0,0,0,0],
            [3,0,0,0,0,0,0,0,0],
            [0,0,0,0,4,0,1,0,0],
            [5,7,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
        // Example 3
        [
            [1,0,0,0,0,7,0,9,0],
            [0,3,0,0,2,0,0,0,8],
            [0,0,9,6,0,0,5,0,0],
            [0,0,5,3,0,0,9,0,0],
            [0,1,0,0,0,0,0,0,2],
            [0,0,6,0,0,3,0,0,0],
            [0,6,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
        // Example 4
        [
            [0,0,0,2,6,0,7,0,1],
            [6,8,0,0,7,0,0,9,0],
            [1,9,0,0,0,4,5,0,0],
            [8,2,0,1,0,0,0,4,0],
            [0,0,4,6,0,2,9,0,0],
            [0,5,0,0,0,3,0,2,8],
            [0,0,9,3,0,0,0,7,4],
            [0,4,0,0,5,0,0,3,6],
            [7,0,3,0,1,8,0,0,0],
        ],
        // Example 5
        [
            [0,0,0,0,0,0,0,0,0],
            [0,0,0,0,0,3,0,8,5],
            [0,0,1,0,2,0,0,0,0],
            [0,0,0,0,0,0,0,0,7],
            [0,0,0,0,1,0,0,0,0],
            [3,0,0,0,0,0,0,0,0],
            [0,0,0,0,4,0,1,0,0],
            [5,7,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
        // Example 6 (a harder one)
        [
            [0,0,0,0,0,0,0,0,6],
            [0,0,0,0,0,3,0,0,0],
            [0,0,1,0,2,0,0,0,0],
            [0,0,0,0,6,0,0,0,3],
            [4,0,0,8,0,3,0,0,1],
            [7,0,0,0,2,0,0,0,6],
            [0,6,0,0,0,0,2,8,0],
            [0,0,0,4,1,9,0,0,5],
            [0,0,0,0,8,0,0,7,9],
        ],
        // Example 7
        [
            [9,0,0,0,0,0,0,0,5],
            [0,1,0,0,0,5,0,0,0],
            [0,0,0,3,0,0,0,8,0],
            [0,0,0,0,0,6,0,0,0],
            [0,0,0,0,0,0,2,0,0],
            [3,0,7,0,0,0,0,0,1],
            [0,6,0,0,0,0,0,9,0],
            [0,0,0,4,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
        // Example 8
        [
            [2,0,0,0,0,0,0,0,0],
            [0,0,0,0,0,3,0,8,5],
            [0,0,1,0,2,0,0,0,0],
            [0,0,0,0,0,0,0,0,7],
            [0,0,0,0,1,0,0,0,0],
            [3,0,0,0,0,0,0,0,0],
            [0,0,0,0,4,0,1,0,0],
            [5,7,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
        // Example 9
        [
            [0,0,0,0,7,0,0,0,0],
            [6,0,0,1,9,5,0,0,0],
            [0,9,8,0,0,0,0,6,0],
            [8,0,0,0,6,0,0,0,3],
            [4,0,0,8,0,3,0,0,1],
            [7,0,0,0,2,0,0,0,6],
            [0,6,0,0,0,0,2,8,0],
            [0,0,0,4,1,9,0,0,5],
            [0,0,0,0,8,0,0,7,0],
        ],
        // Example 10
        [
            [0,0,0,4,0,0,0,0,0],
            [0,0,0,0,0,3,0,8,5],
            [0,2,1,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,7],
            [0,0,0,0,1,0,0,0,0],
            [3,0,0,0,0,0,0,0,0],
            [0,0,0,0,4,0,1,0,0],
            [5,7,0,0,0,0,0,0,0],
            [0,0,0,0,0,0,0,0,0],
        ],
    ];

    for (i, board) in test_boards.iter_mut().enumerate() {
        println!("Test Sudoku #{} (Before):", i+1);
        print_board(board);
        if solve_sudoku(board) {
            println!("Solved Sudoku #{}:", i+1);
            print_board(board);
        } else {
            println!("No solution found for Sudoku #{}.", i+1);
        }
        println!("-----------------------------------------");
    }
}
