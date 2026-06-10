with Ada.Text_IO; use Ada.Text_IO;

procedure Test_Calculator is
   function Add (A, B : Integer) return Integer is
   begin
      return A + B;
   end Add;
begin
   if Add (2, 3) /= 5 then
      raise Program_Error;
   end if;
   Put_Line ("ada fixture passed");
end Test_Calculator;
