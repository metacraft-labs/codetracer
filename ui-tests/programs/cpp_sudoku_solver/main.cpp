#include <iostream>

using namespace std;

static const int SIZE = 9;

static void print_board(unsigned char board[SIZE][SIZE]) {
    for (int r = 0; r < SIZE; r++) {
        for (int c = 0; c < SIZE; c++) {
            if (board[r][c] == 0)
                cout << ". ";
            else
                cout << (int)board[r][c] << " ";
        }
        cout << "\n";
    }
}

static bool is_valid(unsigned char board[SIZE][SIZE], int row, int col, unsigned char num) {
    // Check row
    for (int c = 0; c < SIZE; c++) {
        if (board[row][c] == num) return false;
    }
    // Check column
    for (int r = 0; r < SIZE; r++) {
        if (board[r][col] == num) return false;
    }
    // Check 3x3 box
    int box_row_start = (row / 3) * 3;
    int box_col_start = (col / 3) * 3;
    for (int r = box_row_start; r < box_row_start + 3; r++) {
        for (int c = box_col_start; c < box_col_start + 3; c++) {
            if (board[r][c] == num) return false;
        }
    }
    return true;
}

static bool find_empty_cell(unsigned char board[SIZE][SIZE], int &row, int &col) {
    for (int r = 0; r < SIZE; r++) {
        for (int c = 0; c < SIZE; c++) {
            if (board[r][c] == 0) {
                row = r;
                col = c;
                return true;
            }
        }
    }
    return false;
}

static bool solve_sudoku(unsigned char board[SIZE][SIZE]) {
    int row, col;
    if (!find_empty_cell(board, row, col)) {
        return true; // Solved
    }

    for (unsigned char num = 1; num <= 9; num++) {
        if (is_valid(board, row, col, num)) {
            board[row][col] = num;
            if (solve_sudoku(board)) {
                return true;
            }
            board[row][col] = 0; // backtrack
        }
    }
    return false;
}

int main() {
    unsigned char test_boards[10][SIZE][SIZE] = {
        { // Example 1
          {5,3,0,0,7,0,0,0,0},
          {6,0,0,1,9,5,0,0,0},
          {0,9,8,0,0,0,0,6,0},
          {8,0,0,0,6,0,0,0,3},
          {4,0,0,8,0,3,0,0,1},
          {7,0,0,0,2,0,0,0,6},
          {0,6,0,0,0,0,2,8,0},
          {0,0,0,4,1,9,0,0,5},
          {0,0,0,0,8,0,0,7,9}
        },
        { // Example 2
          {0,0,0,0,0,0,0,0,0},
          {0,0,0,0,0,3,0,8,5},
          {0,0,1,0,2,0,0,0,0},
          {0,0,0,0,0,0,0,0,7},
          {0,0,0,0,1,0,0,0,0},
          {3,0,0,0,0,0,0,0,0},
          {0,0,0,0,4,0,1,0,0},
          {5,7,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        },
        { // Example 3
          {1,0,0,0,0,7,0,9,0},
          {0,3,0,0,2,0,0,0,8},
          {0,0,9,6,0,0,5,0,0},
          {0,0,5,3,0,0,9,0,0},
          {0,1,0,0,0,0,0,0,2},
          {0,0,6,0,0,3,0,0,0},
          {0,6,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        },
        { // Example 4
          {0,0,0,2,6,0,7,0,1},
          {6,8,0,0,7,0,0,9,0},
          {1,9,0,0,0,4,5,0,0},
          {8,2,0,1,0,0,0,4,0},
          {0,0,4,6,0,2,9,0,0},
          {0,5,0,0,0,3,0,2,8},
          {0,0,9,3,0,0,0,7,4},
          {0,4,0,0,5,0,0,3,6},
          {7,0,3,0,1,8,0,0,0}
        },
        { // Example 5
          {0,0,0,0,0,0,0,0,0},
          {0,0,0,0,0,3,0,8,5},
          {0,0,1,0,2,0,0,0,0},
          {0,0,0,0,0,0,0,0,7},
          {0,0,0,0,1,0,0,0,0},
          {3,0,0,0,0,0,0,0,0},
          {0,0,0,0,4,0,1,0,0},
          {5,7,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        },
        { // Example 6
          {0,0,0,0,0,0,0,0,6},
          {0,0,0,0,0,3,0,0,0},
          {0,0,1,0,2,0,0,0,0},
          {0,0,0,0,6,0,0,0,3},
          {4,0,0,8,0,3,0,0,1},
          {7,0,0,0,2,0,0,0,6},
          {0,6,0,0,0,0,2,8,0},
          {0,0,0,4,1,9,0,0,5},
          {0,0,0,0,8,0,0,7,9}
        },
        { // Example 7
          {9,0,0,0,0,0,0,0,5},
          {0,1,0,0,0,5,0,0,0},
          {0,0,0,3,0,0,0,8,0},
          {0,0,0,0,0,6,0,0,0},
          {0,0,0,0,0,0,2,0,0},
          {3,0,7,0,0,0,0,0,1},
          {0,6,0,0,0,0,0,9,0},
          {0,0,0,4,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        },
        { // Example 8
          {2,0,0,0,0,0,0,0,0},
          {0,0,0,0,0,3,0,8,5},
          {0,0,1,0,2,0,0,0,0},
          {0,0,0,0,0,0,0,0,7},
          {0,0,0,0,1,0,0,0,0},
          {3,0,0,0,0,0,0,0,0},
          {0,0,0,0,4,0,1,0,0},
          {5,7,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        },
        { // Example 9
          {0,0,0,0,7,0,0,0,0},
          {6,0,0,1,9,5,0,0,0},
          {0,9,8,0,0,0,0,6,0},
          {8,0,0,0,6,0,0,0,3},
          {4,0,0,8,0,3,0,0,1},
          {7,0,0,0,2,0,0,0,6},
          {0,6,0,0,0,0,2,8,0},
          {0,0,0,4,1,9,0,0,5},
          {0,0,0,0,8,0,0,7,0}
        },
        { // Example 10
          {0,0,0,4,0,0,0,0,0},
          {0,0,0,0,0,3,0,8,5},
          {0,2,1,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,7},
          {0,0,0,0,1,0,0,0,0},
          {3,0,0,0,0,0,0,0,0},
          {0,0,0,0,4,0,1,0,0},
          {5,7,0,0,0,0,0,0,0},
          {0,0,0,0,0,0,0,0,0}
        }
    };

    for (int i = 0; i < 10; i++) {
        cout << "Test Sudoku #" << i+1 << " (Before):" << "\n";
        print_board(test_boards[i]);
        if (solve_sudoku(test_boards[i])) {
            cout << "Solved Sudoku #" << i+1 << ":" << "\n";
            print_board(test_boards[i]);
        } else {
            cout << "No solution found for Sudoku #" << i+1 << "." << "\n";
        }
        cout << "-----------------------------------------" << "\n";
    }

    return 0;
}
