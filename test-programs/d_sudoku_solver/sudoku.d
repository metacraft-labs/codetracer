/// Sudoku solver using backtracking.
/// Compiled with: ldmd2 -g -O0 -debug sudoku.d
/// Produces DWARF debug info for codetracer RR-based tracing.
import std.stdio;

enum SIZE = 9;

void printBoard(ref ubyte[SIZE][SIZE] board) {
    foreach (ref row; board) {
        foreach (cell; row) {
            if (cell == 0)
                write(". ");
            else
                writef("%d ", cell);
        }
        writeln();
    }
}

bool isValid(ref ubyte[SIZE][SIZE] board, int row, int col, ubyte num) {
    // Check row
    foreach (c; 0 .. SIZE) {
        if (board[row][c] == num) return false;
    }
    // Check column
    foreach (r; 0 .. SIZE) {
        if (board[r][col] == num) return false;
    }
    // Check 3x3 box
    int boxRowStart = (row / 3) * 3;
    int boxColStart = (col / 3) * 3;
    foreach (r; boxRowStart .. boxRowStart + 3) {
        foreach (c; boxColStart .. boxColStart + 3) {
            if (board[r][c] == num) return false;
        }
    }
    return true;
}

bool findEmptyCell(ref ubyte[SIZE][SIZE] board, out int row, out int col) {
    foreach (r; 0 .. SIZE) {
        foreach (c; 0 .. SIZE) {
            if (board[r][c] == 0) {
                row = r;
                col = c;
                return true;
            }
        }
    }
    return false;
}

bool solve(ref ubyte[SIZE][SIZE] board) {
    int row, col;
    if (!findEmptyCell(board, row, col)) {
        return true; // No empty cell means solved
    }

    foreach (num; 1 .. 10) {
        ubyte n = cast(ubyte) num;
        if (isValid(board, row, col, n)) {
            board[row][col] = n;
            if (solve(board)) {
                return true;
            }
            board[row][col] = 0; // backtrack
        }
    }
    return false;
}

void main() {
    // 10 test boards, same puzzles as the C version
    ubyte[SIZE][SIZE][10] testBoards = [
        // Example 1
        [[5,3,0,0,7,0,0,0,0],
         [6,0,0,1,9,5,0,0,0],
         [0,9,8,0,0,0,0,6,0],
         [8,0,0,0,6,0,0,0,3],
         [4,0,0,8,0,3,0,0,1],
         [7,0,0,0,2,0,0,0,6],
         [0,6,0,0,0,0,2,8,0],
         [0,0,0,4,1,9,0,0,5],
         [0,0,0,0,8,0,0,7,9]],
        // Example 2
        [[0,0,0,0,0,0,0,0,0],
         [0,0,0,0,0,3,0,8,5],
         [0,0,1,0,2,0,0,0,0],
         [0,0,0,0,0,0,0,0,7],
         [0,0,0,0,1,0,0,0,0],
         [3,0,0,0,0,0,0,0,0],
         [0,0,0,0,4,0,1,0,0],
         [5,7,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
        // Example 3
        [[1,0,0,0,0,7,0,9,0],
         [0,3,0,0,2,0,0,0,8],
         [0,0,9,6,0,0,5,0,0],
         [0,0,5,3,0,0,9,0,0],
         [0,1,0,0,0,0,0,0,2],
         [0,0,6,0,0,3,0,0,0],
         [0,6,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
        // Example 4
        [[0,0,0,2,6,0,7,0,1],
         [6,8,0,0,7,0,0,9,0],
         [1,9,0,0,0,4,5,0,0],
         [8,2,0,1,0,0,0,4,0],
         [0,0,4,6,0,2,9,0,0],
         [0,5,0,0,0,3,0,2,8],
         [0,0,9,3,0,0,0,7,4],
         [0,4,0,0,5,0,0,3,6],
         [7,0,3,0,1,8,0,0,0]],
        // Example 5
        [[0,0,0,0,0,0,0,0,0],
         [0,0,0,0,0,3,0,8,5],
         [0,0,1,0,2,0,0,0,0],
         [0,0,0,0,0,0,0,0,7],
         [0,0,0,0,1,0,0,0,0],
         [3,0,0,0,0,0,0,0,0],
         [0,0,0,0,4,0,1,0,0],
         [5,7,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
        // Example 6
        [[0,0,0,0,0,0,0,0,6],
         [0,0,0,0,0,3,0,0,0],
         [0,0,1,0,2,0,0,0,0],
         [0,0,0,0,6,0,0,0,3],
         [4,0,0,8,0,3,0,0,1],
         [7,0,0,0,2,0,0,0,6],
         [0,6,0,0,0,0,2,8,0],
         [0,0,0,4,1,9,0,0,5],
         [0,0,0,0,8,0,0,7,9]],
        // Example 7
        [[9,0,0,0,0,0,0,0,5],
         [0,1,0,0,0,5,0,0,0],
         [0,0,0,3,0,0,0,8,0],
         [0,0,0,0,0,6,0,0,0],
         [0,0,0,0,0,0,2,0,0],
         [3,0,7,0,0,0,0,0,1],
         [0,6,0,0,0,0,0,9,0],
         [0,0,0,4,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
        // Example 8
        [[2,0,0,0,0,0,0,0,0],
         [0,0,0,0,0,3,0,8,5],
         [0,0,1,0,2,0,0,0,0],
         [0,0,0,0,0,0,0,0,7],
         [0,0,0,0,1,0,0,0,0],
         [3,0,0,0,0,0,0,0,0],
         [0,0,0,0,4,0,1,0,0],
         [5,7,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
        // Example 9
        [[0,0,0,0,7,0,0,0,0],
         [6,0,0,1,9,5,0,0,0],
         [0,9,8,0,0,0,0,6,0],
         [8,0,0,0,6,0,0,0,3],
         [4,0,0,8,0,3,0,0,1],
         [7,0,0,0,2,0,0,0,6],
         [0,6,0,0,0,0,2,8,0],
         [0,0,0,4,1,9,0,0,5],
         [0,0,0,0,8,0,0,7,0]],
        // Example 10
        [[0,0,0,4,0,0,0,0,0],
         [0,0,0,0,0,3,0,8,5],
         [0,2,1,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,7],
         [0,0,0,0,1,0,0,0,0],
         [3,0,0,0,0,0,0,0,0],
         [0,0,0,0,4,0,1,0,0],
         [5,7,0,0,0,0,0,0,0],
         [0,0,0,0,0,0,0,0,0]],
    ];

    foreach (i; 0 .. 10) {
        writefln("Test Sudoku #%d (Before):", i + 1);
        printBoard(testBoards[i]);
        if (solve(testBoards[i])) {
            writefln("Solved Sudoku #%d:", i + 1);
            printBoard(testBoards[i]);
        } else {
            writefln("No solution found for Sudoku #%d.", i + 1);
        }
        writeln("-----------------------------------------");
    }
}
