## What are tracepoints?

Tracepoints are a type of breakpoint that allows you to run arbitrary code every time this breakpoint is hit. In most
debuggers that support tracepoints they allow for efficient debugging of complex scenarios, like really deep recursion,
or complex control flow.

In CodeTracer, however, they can also unlock a number of strategies for additional debugging, specifically in the realm
of hotspot debugging.

## Tracepoints usage guide

From the GUI:

1. Right-click on a line
1. Click on "Add tracepoint"
1. The tracepoints popup should appear
1. Write your tracepoint code in the text editor in the tracepoints popup
1. Press "CTRL + Enter" to run the trace
1. After running the trace, the output of your tracepoint will be listed in the tracepoint popup, and in the event log

From the TUI: Coming soon!

From the REPL: Coming soon!

## Tracepoints language

### Syntax

The syntax of the language is similar to Noir/Rust (and therefore most C-like languages). However it doesn't use semicolons.

In the future it is possible to add language-specific features or dialects of the tracepoint language.

#### Literals

Integer (`1`, `23`, `12`), Float (`1.23`, `.234`, `123.`), Bool (`true`, `false`) and String (`"some text"`) literals
are supported.

### `log()`

The `log()` statement is used to evaluate the argument expression and add it as output from the current tracepoint.
The `log()` statement suppors multiple values that are comma-separated: `log(v1, v2, v3)`.

#### Example

```rs
fn test() {
  let mut sum = 0;

  for i in 0..3 {
    sum += i;
    --------------------------------------------------------------------------------
    |  log("I'm in the loop", i)
    |
    --------------------------------------------------------------------------------
    // Output:
    --------------------------------------------------------------------------------
    |  "I'm in the loop" i=0
    |  "I'm in the loop" i=1
    |  "I'm in the loop" i=2
    --------------------------------------------------------------------------------
  }
```


### Accessing variables

The tracepoint for has access to all the variables, that are defined when the line on which the tracepoint is added is
evaluated. You can reference them just by using their names in the expressions.

#### Example

```rs
fn add(a: i32, b: i32) -> i32 {
  a + b
  --------------------------------------------------------------------------------
  |  log(a)
  |  log(b)
  --------------------------------------------------------------------------------
  // Output:
  --------------------------------------------------------------------------------
  |  a=3 b=5
  --------------------------------------------------------------------------------
}
```

### Comparison

#### `==` and `!=`

Two values are considered eqial iff their types are the same and their values are the same. **Exception** to this rule is
comparing **Int** and **Float**, which are compared by their values, despite them being different type.

#### `<`, `>`, `<=`, `>=`

These operators work **only with numerical values** (e.g Int and Float). If at least one of the values is of non-numerical
type, then an Error is raised.

#### Example

| Expression | Value |
| ---------- | ----- |
| 1 == 1 | true |
| 1 != 1 | false |
| 1 == 2 | false |
| 1 != 2 | true |
| "banana" == "banana" | true |
| "banana" != "banana" | false |
| "banana" == "apple" | false |
| "banana" != "apple" | true |
| "banana" == 1 | false |
| "banana" != 1 | true |
| | |
| **1.0 == 1** | **true** |
| **1.0 != 1** | **false** |
| **2.0 == 1** | **false** |
| **2.0 != 1** | **true** |
| **"1" == 1** | **false** |
| **"1" != 1** | **true** |
| | |
| 1 < 2 | true |
| 1 <= 2 | true |
| 1 > 2 | false |
| 1 >= 2 | false |
| 1 < 2.2 | true |
| 1.1 <= 2 | true |
| 1 > 2.2 | false |
| 1.1 >= 2 | false |
| | |
| **1 < "2"** | **ERROR** |
| **"0" < 1** | **ERROR** |
| **"1" >= "2"** | **ERROR** |


### Arithmetic operations

The supported arithmetic operations are addition (`+`), subtraction (`-`), multiplication (`*`), division (`/`) and
remainder (`%`). They work only with numerical types (Int and Float).

When both arguments are Integer values, then the result is an Integer (for `/` the result is rounded toward 0). If at
least one of the arguments is a Float, then the result is a Float.

#### Example
| Expression | Value |
| ---------- | ----- |
| 2 + 3 | 5 |
| 2 + 3.0 | 5.0 |
| 2.2 + 3.3 | 5.5 |
| 2 - 3 | -1 |
| 2 - 3.0 | -1.0 |
| 2.2 - 3.3 | -1.1 |
| 2 * 3 | 6 |
| 2 * 3.0 | 6.0 |
| 2.2 * 3.3 | 7.26 |
| **7 / 3** | **2** |
| 7 / 3.0 | 2.3333333 |
| 7.7 / 3.3 | 2.3333333 |
| 7 % 3 | 1 |
| 7 % 3.0 | 1.0 |
| 7.7 % 3.3 | 1.1 |


### Conditional branching (`if`-`else`)

The tracepoint language also supports conditional evaluation and branching. If the condition expression doesn't
evaluate to a boolean value, then an error is raised.

#### Example

```rs
fn test() {
  let mut sum = 0;

  for i in 0..4 {
    sum += i;
    --------------------------------------------------------------------------------
    |  log(i)
    |  if i % 2 == 0 {
    |    log("even")
    |  } else if i % 3 == 0 {
    |    log("div 3")
    |  } else {
    |    log("odd")
    |  }
    --------------------------------------------------------------------------------
    // Output:
    --------------------------------------------------------------------------------
    |  i=0 even
    |  i=1 odd
    |  i=2 even
    |  i=3 div 3
    --------------------------------------------------------------------------------
  }
}
```

### Array indexing

If a value is an array, you can index it using the `[]` operators. Indices are 0-based.

#### Example

```rs
fn arr(a: i32, b: i32) -> i32 {
  let a = [1, 2, 3, 4, 5];
  let b = a[2];
  --------------------------------------------------------------------------------
  |  log(a)
  |  log(a[0])
  |  log(a[1])
  |  log(a[4])
  --------------------------------------------------------------------------------
  // Output:
  --------------------------------------------------------------------------------
  |  a=[1, 2, 3, 4, 5] a[0]=1 a[1]=2 a[4]=5
  --------------------------------------------------------------------------------
}
```

### Errors

When an error occurs, the evaluation of the tracepoint stops.

#### Example
```rs
fn arr(a: i32, b: i32) -> i32 {
  let a = [1, 2, 3, 4, 5];
  let b = a[2];
  --------------------------------------------------------------------------------
  |  log(a[0])
  |  if a[1] { // This will cause error
  |    log("banana")
  |  }
  |  log(a[2]) // This won't be evaluated
  --------------------------------------------------------------------------------
  // Output:
  --------------------------------------------------------------------------------
  |  a[0]=1 Error=Non-boolean value on conditional jump
  --------------------------------------------------------------------------------
}
```

### Rust-specific extensions

We have some language-specific extensions in mind, but nothing concrete yet.
