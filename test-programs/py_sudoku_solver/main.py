"""Backtracking Sudoku solver used for Codetracer test programs.

The module exposes a reusable `solve_sudoku` function so it can be imported
from other scripts while still providing a simple CLI demonstration when
executed directly.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Iterable, List, Optional, Sequence, Set, Tuple

SIZE = 9
Board = List[List[int]]
Coordinate = Tuple[int, int]


def validate_board(board: Sequence[Sequence[int]]) -> None:
    """Validate that the candidate board is a 9x9 grid with digits 0-9."""
    if len(board) != SIZE:
        raise ValueError(f"expected {SIZE} rows, received {len(board)}")
    for row_index, row in enumerate(board):
        if len(row) != SIZE:
            raise ValueError(
                f"row {row_index} has length {len(row)} instead of {SIZE}"
            )
        for col_index, value in enumerate(row):
            if not isinstance(value, int):
                raise ValueError(
                    f"board[{row_index}][{col_index}] must be int, "
                    f"received {type(value).__name__}"
                )
            if value < 0 or value > SIZE:
                raise ValueError(
                    f"board[{row_index}][{col_index}] must be between 0 and 9, "
                    f"received {value}"
                )


def is_valid_move(board: Sequence[Sequence[int]], row: int, col: int, num: int) -> bool:
    """Return True when placing `num` at (row, col) obeys Sudoku constraints."""
    for c in range(SIZE):
        if board[row][c] == num:
            return False
    for r in range(SIZE):
        if board[r][col] == num:
            return False

    box_row_start = (row // 3) * 3
    box_col_start = (col // 3) * 3
    for r in range(box_row_start, box_row_start + 3):
        for c in range(box_col_start, box_col_start + 3):
            if board[r][c] == num:
                return False
    return True


def _box_index(row: int, col: int) -> int:
    """Return the index (0-8) of the 3x3 sub-grid containing (row, col)."""
    return (row // 3) * 3 + (col // 3)


def _initialize_options(
    board: Sequence[Sequence[int]],
) -> Tuple[List[Set[int]], List[Set[int]], List[Set[int]]]:
    """Prepare lookup tables tracking which digits remain available per unit."""
    digits = set(range(1, SIZE + 1))
    row_options = [set(digits) for _ in range(SIZE)]
    col_options = [set(digits) for _ in range(SIZE)]
    box_options = [set(digits) for _ in range(SIZE)]

    for row in range(SIZE):
        for col in range(SIZE):
            value = board[row][col]
            if value == 0:
                continue
            box = _box_index(row, col)
            if (
                value not in row_options[row]
                or value not in col_options[col]
                or value not in box_options[box]
            ):
                raise ValueError(
                    f"board has conflicting value {value} at ({row}, {col})"
                )
            row_options[row].remove(value)
            col_options[col].remove(value)
            box_options[box].remove(value)

    return row_options, col_options, box_options


def choose_cell_with_candidates(
    board: Sequence[Sequence[int]],
    row_options: Sequence[Set[int]],
    col_options: Sequence[Set[int]],
    box_options: Sequence[Set[int]],
) -> Tuple[Optional[Coordinate], List[int]]:
    """Select the next empty cell using a minimum remaining value heuristic.

    Returns a tuple of:
    - the chosen coordinate (row, col) or None when the board is already full
    - a list of candidate numbers that can appear in that cell

    An empty list of candidates indicates the current board configuration
    cannot lead to a valid solution.
    """
    best_coordinate: Optional[Coordinate] = None
    best_candidates: List[int] = []
    for row in range(SIZE):
        for col in range(SIZE):
            if board[row][col] != 0:
                continue
            box = _box_index(row, col)
            options = row_options[row] & col_options[col] & box_options[box]
            if not options:
                return (row, col), []
            option_list = sorted(options)
            if best_coordinate is None or len(option_list) < len(best_candidates):
                best_coordinate = (row, col)
                best_candidates = option_list
                if len(best_candidates) == 1:
                    return best_coordinate, best_candidates
    return best_coordinate, best_candidates


def solve_sudoku(board: Board) -> bool:
    """Solve the Sudoku puzzle in-place using backtracking.

    The function mutates `board`, filling empty cells (value 0). It validates
    the board before attempting to solve it so callers get clear errors for
    malformed input instead of silent failures.
    """
    validate_board(board)
    row_options, col_options, box_options = _initialize_options(board)
    return _solve_in_place(board, row_options, col_options, box_options)


def _solve_in_place(
    board: Board,
    row_options: List[Set[int]],
    col_options: List[Set[int]],
    box_options: List[Set[int]],
) -> bool:
    """Recursive solver that assumes board shape is already validated."""
    coordinate, candidates = choose_cell_with_candidates(
        board, row_options, col_options, box_options
    )
    if coordinate is None:
        return True
    if not candidates:
        return False

    row, col = coordinate
    box = _box_index(row, col)
    for value in candidates:
        board[row][col] = value
        row_options[row].remove(value)
        col_options[col].remove(value)
        box_options[box].remove(value)
        if _solve_in_place(board, row_options, col_options, box_options):
            return True
        board[row][col] = 0
        row_options[row].add(value)
        col_options[col].add(value)
        box_options[box].add(value)
    return False


def format_board(board: Sequence[Sequence[int]]) -> str:
    """Render the board with dots for empty cells for easier visual diffing."""
    lines = []
    for row in board:
        tokens = ["." if value == 0 else str(value) for value in row]
        lines.append(" ".join(tokens))
    return "\n".join(lines)


# Use a nearly-solved board (only 3 empty cells) to keep the DB trace small.
# A full 41-empty-cell puzzle produces >1 GB of trace data via the Python
# recorder, which the Electron frontend cannot load.
EXAMPLE_BOARDS: Iterable[Board] = [
    [
        [5, 3, 4, 6, 7, 8, 9, 1, 2],
        [6, 7, 2, 1, 9, 5, 3, 4, 8],
        [1, 9, 8, 3, 4, 2, 5, 6, 7],
        [8, 5, 9, 7, 6, 1, 4, 2, 3],
        [4, 2, 6, 8, 5, 3, 7, 9, 1],
        [7, 1, 3, 9, 2, 4, 8, 5, 6],
        [9, 6, 1, 5, 3, 7, 2, 8, 4],
        [2, 8, 7, 4, 1, 9, 6, 3, 5],
        [3, 4, 5, 0, 8, 0, 0, 7, 9],
    ],
]


def _solve_and_print(board_index: int, raw_board: Board) -> None:
    """Solve a single board and print the before/after state."""
    print(f"Test Sudoku #{board_index} (Before):")
    print(format_board(raw_board))
    solved_board = deepcopy(raw_board)
    try:
        solved = solve_sudoku(solved_board)
    except ValueError as exc:
        print(
            f"No solution found for Sudoku #{board_index} "
            f"(invalid puzzle: {exc})."
        )
    else:
        if solved:
            print(f"Solved Sudoku #{board_index}:")
            print(format_board(solved_board))
        else:
            print(f"No solution found for Sudoku #{board_index}.")
    print("-----------------------------------------")


def main() -> None:
    """Entry point used by the Codetracer test harness."""
    for index, board in enumerate(EXAMPLE_BOARDS, start=1):
        _solve_and_print(index, board)


if __name__ == "__main__":
    main()
