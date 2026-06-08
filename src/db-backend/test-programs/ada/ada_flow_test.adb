-- Simple Ada program for MCR flow/omniscience DAP integration testing.
--
-- Mirrors the C/Nim/Rust flow tests:
--   A = 10, B = 32, Sum = 42, Doubled = 84, Final_Result = 94
--
-- Breakpoint is set at the `return Final_Result;` line inside
-- Calculate_Sum; the DAP test verifies that the listed locals are
-- reported with the expected values.

with Ada.Text_IO;
with Ada.Integer_Text_IO;

procedure ada_flow_test is

   function Calculate_Sum (A, B : Integer) return Integer is
      Sum_Val      : Integer := A + B;
      Doubled      : Integer := Sum_Val * 2;
      Final_Result : Integer := Doubled + 10;
   begin
      Ada.Text_IO.Put ("Sum: ");
      Ada.Integer_Text_IO.Put (Sum_Val);
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put ("Doubled: ");
      Ada.Integer_Text_IO.Put (Doubled);
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put ("Final: ");
      Ada.Integer_Text_IO.Put (Final_Result);
      Ada.Text_IO.New_Line;
      return Final_Result;
   end Calculate_Sum;

   X          : Integer := 10;
   Y          : Integer := 32;
   Result_Val : Integer;
begin
   Result_Val := Calculate_Sum (X, Y);
   Ada.Text_IO.Put ("Result: ");
   Ada.Integer_Text_IO.Put (Result_Val);
   Ada.Text_IO.New_Line;
end ada_flow_test;
