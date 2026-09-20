type
  GdbValue* = object # placeholder

  Value* = ref object ## Representation of a language value
    kind*: TypeKind
    typ*: Type
    elements*: seq[Value]
    text*: langstring
    cText*: langstring
    f*: langstring
    i*: langstring
    enumInt*: BiggestInt
    c*: langstring
    b*: bool
    member*: seq[Value]
    refValue*: Value
    address*: langstring
    strong*: int
    weak*: int
    r*: langstring
    items*: seq[seq[Value]]
    kindValue*: Value
    children*: seq[Value]
    shared*: seq[Value]
    msg*: langstring
    signature*: langstring
    functionLabel*: langstring
    base*: langstring
    dict*: TableLike[langstring, Value]
    members*: seq[Value]
    fields*: TableLike[langstring, Value]
    isWatch*: bool
    isType*: bool
    expression*: langstring
    isLiteral*: bool
    activeVariant*: langstring
    activeVariantValue*: Value
    activeFields*: seq[langstring]
    gdbValue*: ref GdbValue # should be nil always out of python
    partiallyExpanded*: bool

  SubPathKind* = enum
    Expression,
    Field,
    Index,
    Dereference,
    VariantKind

  SubPath* = object
    typeKind*: TypeKind
    case kind*: SubPathKind
    of Expression:
      expression*: langstring
    of Field:
      name*: langstring
    of Index:
      index*: int
    of Dereference:
      discard
    of VariantKind:
      kindNumber*: int
      variantName*: langstring

  ExpandValueTarget* = object
    subPath*: seq[SubPath]
    rrTicks*: int
    isLoadMore*: bool
    startIndex*: int
    count*: int

  CtLoadLocalsArguments* = ref object
    rrTicks*: int
    countBudget*: int
    minCountLimit*: int
    # for easier compat between nim and rust code:
    # NO_DEPTH_LIMIT = -1 for None for now
    depthLimit*: int
    watchExpressions*: seq[langstring]
    lang*: langstring
      ## The language's wire name -- ``langWireName(lang)``, which is the Rust
      ## ``Lang::wire_name`` spelling -- NOT a ``Lang``.  This record is
      ## handed to ``toJs`` and serialised as-is on the JS backend, where a
      ## Nim enum is its ordinal at runtime; typing the field ``Lang`` is how
      ## ``ct/load-locals`` came to carry ``ord(Lang)`` on the wire (LRS-1).
      ## The Rust receiver (``CtLoadLocalsArguments`` in
      ## ``src/db-backend/src/task.rs``) decodes it with ``ct-lang``'s
      ## ``lang_wire`` adapter and refuses an integer.

  CtLoadLocalsResponseBody* = ref object
    locals*: seq[Variable]

  CtUpdatedTableResponseBody* = ref object
    tableUpdate*: TableUpdate

  Variable* = ref object
    expression*: langstring
    value*: Value
    # NO_ADDRESS = -1
    # for db-backend for now NO_ADDRESS
    # used mostly for RR
    address*: int
