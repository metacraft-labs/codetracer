address: 32

Kind:
  INT, FLOAT

Type:
  kind: Kind
  nimType: CString
  cType: CString
  SEQ, SET, VARARGS, REF, POINTER(elementType: Type)
  ARRAY(elementType: Type, length: UInt32)
  MEMBER(memberNames: List[CString], memberTypes: List[Type])

Value:
  kind: Kind
  typ: Type
  INT(i: Int64)
  FLOAT(f: Float64)
  STRING(text: CString)
  CSTRING(cText: CString)
  BOOL(b: Bool)
  CHAR(c: Char)
  SEQ, SET, VARARGS, ARRAY(elements: List[Value])
  ARRAY(length: Int)

