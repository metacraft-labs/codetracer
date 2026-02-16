package main

import (
	"fmt"
)

const SIZE = 9

func printBoard(board [SIZE][SIZE]int) {
	for r := 0; r < SIZE; r++ {
		for c := 0; c < SIZE; c++ {
			val := board[r][c]
			if val == 0 {
				fmt.Print(". ")
			} else {
				fmt.Printf("%d ", val)
			}
		}
		fmt.Println()
	}
}

func isValid(board [SIZE][SIZE]int, row, col, num int) bool {
	// Check row
	for c := 0; c < SIZE; c++ {
		if board[row][c] == num {
			return false
		}
	}
	// Check column
	for r := 0; r < SIZE; r++ {
		if board[r][col] == num {
			return false
		}
	}
	// Check 3x3 box
	boxRowStart := (row / 3) * 3
	boxColStart := (col / 3) * 3
	for r := boxRowStart; r < boxRowStart+3; r++ {
		for c := boxColStart; c < boxColStart+3; c++ {
			if board[r][c] == num {
				return false
			}
		}
	}
	return true
}

func findEmptyCell(board [SIZE][SIZE]int) (int, int, bool) {
	for r := 0; r < SIZE; r++ {
		for c := 0; c < SIZE; c++ {
			if board[r][c] == 0 {
				return r, c, true
			}
		}
	}
	return 0, 0, false
}

func solveSudoku(board *[SIZE][SIZE]int) bool {
	row, col, found := findEmptyCell(*board)
	if !found {
		return true // solved
	}

	for num := 1; num <= 9; num++ {
		if isValid(*board, row, col, num) {
			board[row][col] = num
			if solveSudoku(board) {
				return true
			}
			board[row][col] = 0 // backtrack
		}
	}
	return false
}

func main() {
	// Use a nearly-solved board (only 3 empty cells) to keep the RR trace small.
	// A full 10-board puzzle set produces >1700 events in the event log, pushing
	// stdout "Solved" entries off the visible DataTable page.
	testBoards := [1][SIZE][SIZE]int{
		{
			{5, 3, 4, 6, 7, 8, 9, 1, 2},
			{6, 7, 2, 1, 9, 5, 3, 4, 8},
			{1, 9, 8, 3, 4, 2, 5, 6, 7},
			{8, 5, 9, 7, 6, 1, 4, 2, 3},
			{4, 2, 6, 8, 5, 3, 7, 9, 1},
			{7, 1, 3, 9, 2, 4, 8, 5, 6},
			{9, 6, 1, 5, 3, 7, 2, 8, 4},
			{2, 8, 7, 4, 1, 9, 6, 3, 5},
			{3, 4, 5, 0, 8, 0, 0, 7, 9},
		},
	}

	for i := 0; i < len(testBoards); i++ {
		fmt.Printf("Test Sudoku #%d (Before):\n", i+1)
		printBoard(testBoards[i])
		if solveSudoku(&testBoards[i]) {
			fmt.Printf("Solved Sudoku #%d:\n", i+1)
			printBoard(testBoards[i])
		} else {
			fmt.Printf("No solution found for Sudoku #%d.\n", i+1)
		}
		fmt.Println("-----------------------------------------")
	}
}
