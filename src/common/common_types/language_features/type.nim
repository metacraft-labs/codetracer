type
  # for now we'll try to reuse those
  TypeKind* = enum ## Common types of data in many programming languages
    Seq,
    Set,
    HashSet,
    OrderedSet,
    Array,
    Varargs, ## seq, HashSet, OrderedSet, set and array in Nim, vector and array in C++, list in Python, Array in Ruby
    Instance, ## object in Nim, Python and Ruby. struct, class in C++
    Int,
    Float,
    String,
    CString,
    Char,
    Bool,
    Literal, ## literals in each of them
    Ref, ## ref in Nim, ? C++, not used for Python, Ruby
    Recursion, ## used to signify self-referencing stuff
    Raw, ## fallback for unknown values
    Enum,
    Enum16,
    Enum32, ## enum in Nim and C++, not used for Python, Ruby
    C, ## fallback for c values in Nim, Ruby, Python, not used for C++
    TableKind, ## Table in Nim, std::map in C++, dict in Python, Hash in Ruby
    Union, ## variant objects in Nim, union in C++, not used in Python, Ruby
    Pointer, ## pointer in C/C++: still can have a referenced type, pointer in Nim, not used in Python, Ruby
    # TODO: do we need both `Ref` and `Pointer`?
    Error, ## errors
    FunctionKind, ## a function in Nim, Ruby, Python, a function pointer in C++
    TypeValue,
    Tuple, ## a tuple in Nim, Python
    Variant, ## an enum in Rust
    Html, ## visual value produced debugHTML
    None,
    NonExpanded,
    Any,
    Slice

  Type* = ref object ## Representation of a language type
    kind*: TypeKind
    labels*: seq[langstring]
    minVariant*: int
    variants*: seq[seq[int]]
    langType*: langstring
    cType*: langstring
    elementType*: Type
    length*: int
    childrenNames*: seq[seq[langstring]]
    childrenTypes*: seq[seq[Type]]
    kindType*: Type
    kindName*: langstring
    memberNames*: seq[langstring]
    memberTypes*: seq[Type]
    fieldVariants*: TableLike[langstring, langstring]
    caseObjects*: TableLike[langstring, seq[langstring]]
    enumObjects*: TableLike[langstring, int]
    intType*: langstring
    returnType*: Type
    discriminatorName*: langstring
    fieldTypes*: Table[langstring, Type]
    enumNames*: seq[langstring]
    keyType*: Type
    valueType*: Type
    isType*: bool
    withName*: bool
