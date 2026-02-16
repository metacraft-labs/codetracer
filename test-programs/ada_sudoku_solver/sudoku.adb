--  Sudoku solver using backtracking.
--  Compiled with: gnatmake -g -O0 sudoku.adb
--  Produces DWARF debug info for codetracer RR-based tracing.

with Ada.Text_IO;         use Ada.Text_IO;
with Ada.Integer_Text_IO; use Ada.Integer_Text_IO;

procedure Sudoku is
   Size : constant := 9;
   type Board_Type is array (0 .. Size - 1, 0 .. Size - 1) of Integer;

   procedure Print_Board (Board : Board_Type) is
   begin
      for R in 0 .. Size - 1 loop
         for C in 0 .. Size - 1 loop
            if Board (R, C) = 0 then
               Put (". ");
            else
               Put (Board (R, C), Width => 1);
               Put (" ");
            end if;
         end loop;
         New_Line;
      end loop;
   end Print_Board;

   function Is_Valid
     (Board : Board_Type; Row, Col, Num : Integer) return Boolean
   is
      Box_Row_Start : Integer;
      Box_Col_Start : Integer;
   begin
      --  Check row
      for C in 0 .. Size - 1 loop
         if Board (Row, C) = Num then
            return False;
         end if;
      end loop;

      --  Check column
      for R in 0 .. Size - 1 loop
         if Board (R, Col) = Num then
            return False;
         end if;
      end loop;

      --  Check 3x3 box
      Box_Row_Start := (Row / 3) * 3;
      Box_Col_Start := (Col / 3) * 3;
      for R in Box_Row_Start .. Box_Row_Start + 2 loop
         for C in Box_Col_Start .. Box_Col_Start + 2 loop
            if Board (R, C) = Num then
               return False;
            end if;
         end loop;
      end loop;

      return True;
   end Is_Valid;

   function Find_Empty_Cell
     (Board : Board_Type; Row, Col : out Integer) return Boolean
   is
   begin
      for R in 0 .. Size - 1 loop
         for C in 0 .. Size - 1 loop
            if Board (R, C) = 0 then
               Row := R;
               Col := C;
               return True;
            end if;
         end loop;
      end loop;
      return False;
   end Find_Empty_Cell;

   function Solve (Board : in out Board_Type) return Boolean is
      Row, Col : Integer;
   begin
      if not Find_Empty_Cell (Board, Row, Col) then
         return True;  --  No empty cell means solved
      end if;

      for Num in 1 .. 9 loop
         if Is_Valid (Board, Row, Col, Num) then
            Board (Row, Col) := Num;
            if Solve (Board) then
               return True;
            end if;
            Board (Row, Col) := 0;  --  backtrack
         end if;
      end loop;
      return False;
   end Solve;

   type Board_Array is array (0 .. 9) of Board_Type;
   Boards : Board_Array := (others => (others => (others => 0)));

begin
   --  Example 1
   Boards (0) := (
     (5,3,0,0,7,0,0,0,0),
     (6,0,0,1,9,5,0,0,0),
     (0,9,8,0,0,0,0,6,0),
     (8,0,0,0,6,0,0,0,3),
     (4,0,0,8,0,3,0,0,1),
     (7,0,0,0,2,0,0,0,6),
     (0,6,0,0,0,0,2,8,0),
     (0,0,0,4,1,9,0,0,5),
     (0,0,0,0,8,0,0,7,9));

   --  Example 2
   Boards (1) := (
     (0,0,0,0,0,0,0,0,0),
     (0,0,0,0,0,3,0,8,5),
     (0,0,1,0,2,0,0,0,0),
     (0,0,0,0,0,0,0,0,7),
     (0,0,0,0,1,0,0,0,0),
     (3,0,0,0,0,0,0,0,0),
     (0,0,0,0,4,0,1,0,0),
     (5,7,0,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0));

   --  Example 3
   Boards (2) := (
     (1,0,0,0,0,7,0,9,0),
     (0,3,0,0,2,0,0,0,8),
     (0,0,9,6,0,0,5,0,0),
     (0,0,5,3,0,0,9,0,0),
     (0,1,0,0,0,0,0,0,2),
     (0,0,6,0,0,3,0,0,0),
     (0,6,0,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0));

   --  Example 4
   Boards (3) := (
     (0,0,0,2,6,0,7,0,1),
     (6,8,0,0,7,0,0,9,0),
     (1,9,0,0,0,4,5,0,0),
     (8,2,0,1,0,0,0,4,0),
     (0,0,4,6,0,2,9,0,0),
     (0,5,0,0,0,3,0,2,8),
     (0,0,9,3,0,0,0,7,4),
     (0,4,0,0,5,0,0,3,6),
     (7,0,3,0,1,8,0,0,0));

   --  Example 5
   Boards (4) := Boards (1);

   --  Example 6
   Boards (5) := (
     (0,0,0,0,0,0,0,0,6),
     (0,0,0,0,0,3,0,0,0),
     (0,0,1,0,2,0,0,0,0),
     (0,0,0,0,6,0,0,0,3),
     (4,0,0,8,0,3,0,0,1),
     (7,0,0,0,2,0,0,0,6),
     (0,6,0,0,0,0,2,8,0),
     (0,0,0,4,1,9,0,0,5),
     (0,0,0,0,8,0,0,7,9));

   --  Example 7
   Boards (6) := (
     (9,0,0,0,0,0,0,0,5),
     (0,1,0,0,0,5,0,0,0),
     (0,0,0,3,0,0,0,8,0),
     (0,0,0,0,0,6,0,0,0),
     (0,0,0,0,0,0,2,0,0),
     (3,0,7,0,0,0,0,0,1),
     (0,6,0,0,0,0,0,9,0),
     (0,0,0,4,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0));

   --  Example 8
   Boards (7) := (
     (2,0,0,0,0,0,0,0,0),
     (0,0,0,0,0,3,0,8,5),
     (0,0,1,0,2,0,0,0,0),
     (0,0,0,0,0,0,0,0,7),
     (0,0,0,0,1,0,0,0,0),
     (3,0,0,0,0,0,0,0,0),
     (0,0,0,0,4,0,1,0,0),
     (5,7,0,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0));

   --  Example 9
   Boards (8) := (
     (0,0,0,0,7,0,0,0,0),
     (6,0,0,1,9,5,0,0,0),
     (0,9,8,0,0,0,0,6,0),
     (8,0,0,0,6,0,0,0,3),
     (4,0,0,8,0,3,0,0,1),
     (7,0,0,0,2,0,0,0,6),
     (0,6,0,0,0,0,2,8,0),
     (0,0,0,4,1,9,0,0,5),
     (0,0,0,0,8,0,0,7,0));

   --  Example 10
   Boards (9) := (
     (0,0,0,4,0,0,0,0,0),
     (0,0,0,0,0,3,0,8,5),
     (0,2,1,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,7),
     (0,0,0,0,1,0,0,0,0),
     (3,0,0,0,0,0,0,0,0),
     (0,0,0,0,4,0,1,0,0),
     (5,7,0,0,0,0,0,0,0),
     (0,0,0,0,0,0,0,0,0));

   for I in 0 .. 9 loop
      Put ("Test Sudoku #");
      Put (I + 1, Width => 1);
      Put_Line (" (Before):");
      Print_Board (Boards (I));
      if Solve (Boards (I)) then
         Put ("Solved Sudoku #");
         Put (I + 1, Width => 1);
         Put_Line (":");
         Print_Board (Boards (I));
      else
         Put ("No solution found for Sudoku #");
         Put (I + 1, Width => 1);
         Put_Line (".");
      end if;
      Put_Line ("-----------------------------------------");
   end loop;
end Sudoku;
