@0xaa61dbf81a44073c;

struct Type {
  kind @0 :UInt8;
  nimType @1 :Text;
  cType @2 :Text;

  union {
    elementType @3 :Int32;
    member @4 :Member;
    pairType @5 :PairType;
    arrayType @6 :ArrayType;
  }
}

struct Value {
  kind @0: UInt8;

  union {
  	none @1: Void;
  	fields @2: CompoundValue;
  }
}

struct CompoundValue {
  typ @0: Int32;

  union {
  	i @1 :Int64;
  	f @2 :Float64;
  	text @3 :Text;
  	cText @4 :Data;
  	b @5 :Bool;
  	c @6 :Text;
  	pointer @7 :Pointer;
  }
}


struct Member {
  names @0 :List(Text);
  types @1 :List(Int32);
}

struct PairType {
  key @0 :Int32;
  value @1 :Int32;
}

struct ArrayType {
	element @0 :Int32;
	length @1 :Int64;
}


struct Pointer {
  element @0 :Int32;
  address @1 :Int64;
}
