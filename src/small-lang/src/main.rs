use std::collections::{HashMap, HashSet};
use std::env;
use std::error::Error;
use std::fs;
use std::path;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::Instant;

use runtime_tracing::{
    EventLogKind, Line, Tracer, TypeId, TypeKind, ValueRecord, NONE_TYPE_ID, NONE_VALUE,
};

mod lang;
mod node;
mod parser;
mod position;

use crate::node::{Node, NodeItem};
use crate::parser::parse_program;
use crate::position::Position;

// TODO type-safe value index

type ValueId = usize;

#[allow(dead_code)]
#[derive(Debug, Clone)]
enum Value {
    Object { fields: Vec<ValueId>, typ: Type },
    Vector { items: Vec<ValueId> },
    String { text: String },
    Ref { value_id: ValueId },
    Int { i: i64 },
    Bool { b: bool },
    Void,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
enum Type {
    Object { fields: Vec<Type> },
    Simple { name: String },
}

#[derive(Debug, Clone)]
struct RuntimeFunction {
    name: String,
    params: Vec<String>,
    code: Vec<Node>,
    position: Position,
}

#[derive(Debug, Clone)]
struct EnvScope {
    values: HashMap<String, ValueId>,
    is_function_level: bool,
}

impl EnvScope {
    fn new_function_scope() -> Self {
        EnvScope {
            values: HashMap::new(),
            is_function_level: true,
        }
    }

    fn new_internal_scope() -> Self {
        EnvScope {
            values: HashMap::new(),
            is_function_level: false,
        }
    }

    fn set(&mut self, name: &str, value_id: ValueId) {
        self.values.insert(name.to_string(), value_id);
    }
}

const VOID_VALUE_ID: usize = 0;
const INT_TYPE_ID: TypeId = TypeId(1);
const BOOL_TYPE_ID: TypeId = TypeId(2);

struct Interpreter {
    env: Vec<EnvScope>,
    values: Vec<Value>,
    functions: HashMap<String, RuntimeFunction>,
    interned_ints: HashMap<i64, ValueId>,
    interned_strings: HashMap<String, ValueId>,

    current_position: Position,
    // for now: TODO? more than one program file?
    program_path: PathBuf,
    workdir: PathBuf,

    tracing: bool,
    tracer: Tracer,
}

// how would potential bytecode look like?
//
// 0 push-int 0   # 1
// 1 set-local 0  # 1
// 2 push-int 0 # 2
// 3 set-local 0 # 2
// 4 push-env # 3
// 5 push-int 0 # 3
// 6 set-local 0 # 3
// 7 push-local 0 # 3
// 8 push-int 10000000 # 3
// 9 cmp-less-than # 3
// 10 jump-if-last-false 17 # 3
// 11 push-local 0 # 4
// 12 set-local 1 # 4
// 13 push-local 0 # 5
// 14 set-local 1 # 5
// 15 inc-local 0 # 5
// 16 jump 7 # 3
// 17 pop-env # 3
// 18 end # 5

impl Interpreter {
    fn new(program_path: &Path, tracing: bool) -> Self {
        Interpreter {
            env: vec![EnvScope::new_function_scope()],
            values: vec![Value::Void],
            functions: HashMap::new(),
            interned_ints: HashMap::new(),
            interned_strings: HashMap::new(),
            current_position: Position { line: 0, column: 0 },
            program_path: program_path.to_path_buf(),

            tracing,
            workdir: env::current_dir().unwrap(),
            tracer: Tracer::new(&format!("{}", program_path.display()), &[]),
        }
    }

    // fn load_current_path_id(&mut self) -> PathId {
    //     self.tracer.ensure_path_id(&self.workdir.join(&self.program_path)) // TODO dynamic path
    // }

    fn on_start(&mut self) {
        if self.tracing {
            self.tracer.start(
                &self.workdir.join(&self.program_path),
                Line(self.current_position.line as i64),
            );

            assert!(NONE_TYPE_ID == self.tracer.ensure_type_id(TypeKind::None, "None"));
            assert!(INT_TYPE_ID == self.tracer.ensure_type_id(TypeKind::Int, "Int"));
            assert!(BOOL_TYPE_ID == self.tracer.ensure_type_id(TypeKind::Bool, "Bool"));
        }
    }

    fn on_step(&mut self, position: &Position) {
        // eprintln!("STEP {:?}", position);
        if self.current_position.line != position.line {
            self.current_position = *position;
            self.on_line(position);
        }
    }

    fn on_line(&mut self, position: &Position) {
        // eprintln!("LINE {:?}", position);
        // codetracer-generating
        if self.tracing {
            self.trace_step(position);

            self.trace_local_variables();
        }
    }

    fn trace_local_variables(&mut self) {
        let mut current_env_index: i64 = (self.env.len() - 1) as i64;
        let mut traced: HashSet<String> = HashSet::new();
        while current_env_index >= 0 {
            let current_env = self.env[current_env_index as usize].clone();
            for (name, value_id) in current_env.values.iter() {
                // deeper/more internal scopes shadow more shallow ones:
                // e.g. names in loop scopes shadow the function scope ones
                if !traced.contains(name) {
                    // eprintln!("variable on {current_env_index:?} {name} {value_id:?}");
                    self.trace_variable(name, *value_id);
                    traced.insert(name.to_string());
                }
            }
            if current_env.is_function_level {
                break;
            }
            current_env_index -= 1;
        }
        // eprintln!("===========");
    }

    fn trace_drop_locals(&mut self) {
        let mut current_env_index: i64 = (self.env.len() - 1) as i64;
        let mut dropped: HashSet<String> = HashSet::new();
        while current_env_index >= 0 {
            let current_env = self.env[current_env_index as usize].clone();
            for (name, _) in current_env.values.iter() {
                // deeper/more internal scopes shadow more shallow ones:
                // e.g. names in loop scopes shadow the function scope ones
                if !dropped.contains(name) {
                    self.tracer.drop_variable(name);
                    dropped.insert(name.to_string());
                }
            }
            if current_env.is_function_level {
                break;
            }
            current_env_index -= 1;
        }
    }

    fn trace_variable(&mut self, name: &str, value_id: ValueId) {
        let value = self.values[value_id].clone();
        let trace_value = self.convert_to_trace_value(&value);
        self.tracer
            .register_variable_with_full_value(name, trace_value);
    }

    fn convert_to_trace_value(&mut self, value: &Value) -> ValueRecord {
        match value {
            &Value::Int { i } => ValueRecord::Int {
                i,
                type_id: INT_TYPE_ID,
            },
            &Value::Bool { b } => ValueRecord::Bool {
                b,
                type_id: BOOL_TYPE_ID,
            },
            &Value::Void => NONE_VALUE,
            Value::Vector { items } => {
                let type_id = self.tracer.ensure_type_id(TypeKind::Seq, "List");
                let trace_items = items
                    .iter()
                    .map(|item| self.convert_to_trace_value(&self.values[*item].clone()))
                    .collect();
                ValueRecord::Sequence {
                    elements: trace_items,
                    is_slice: false,
                    type_id,
                }
            }
            Value::Ref { value_id } => {
                let text_repr = self.value_repr(*value_id);
                let type_id = self.tracer.ensure_type_id(TypeKind::Seq, "Ref");
                ValueRecord::Raw {
                    r: text_repr,
                    type_id,
                }
            }
            _ => {
                unimplemented!()
            }
        }
    }

    fn trace_step(&mut self, position: &Position) {
        // TODO: paths
        self.register_step(position);
    }

    fn register_step(&mut self, position: &Position) {
        self.tracer.register_step(
            &self.workdir.join(&self.program_path),
            Line(position.line as i64),
        );
    }

    fn invalidate_current_line(&mut self) {
        // enforce a new line event, if on_step later
        self.current_position.line = 0; // supposed to be impossible for normal lines
    }

    fn evaluate(&mut self, node: &Node) -> Result<ValueId, Box<dyn Error>> {
        // println!("evaluate {:#?}", node);
        match &node.item {
            NodeItem::Assignment {
                target,
                value,
                dereferencing,
            } => {
                self.on_step(&node.position);
                self.evaluate_assign(target, value, *dereferencing, node.position)
            }
            NodeItem::Block { items } => {
                self.on_step(&node.position);
                let mut res = VOID_VALUE_ID;
                for item in items {
                    res = self.evaluate(item)?;
                }
                Ok(res)
            }
            NodeItem::Index { collection, index } => {
                self.on_step(&node.position);
                if let Ok(c) = self.evaluate(collection) {
                    let value_id = self.evaluate(index)?;
                    if let Value::Vector { items } = &self.values[c] {
                        let value = &self.values[value_id];
                        if let Value::Int { i } = value {
                            Ok(items[*i as usize])
                        } else {
                            unimplemented!()
                        }
                    } else {
                        unimplemented!()
                    }
                } else {
                    unimplemented!()
                }
            }
            NodeItem::String { text } => {
                self.on_step(&node.position);
                Ok(self.value_for_string(text))
            }
            NodeItem::Int { i } => {
                self.on_step(&node.position);
                Ok(self.value_for_int(*i))
            }
            NodeItem::Name { name } => {
                // default if not found
                self.on_step(&node.position);
                let mut res: Result<ValueId, Box<dyn Error>> = Err(format!(
                    "error: local variable {} not found at {}:{}",
                    name, node.position.line, node.position.column
                )
                .into());
                for scope in self.env.iter().rev() {
                    if scope.values.contains_key(name) {
                        res = Ok(*scope.values.get(name).unwrap());
                        break;
                    } else {
                        continue;
                    }
                }
                res
            }
            NodeItem::Vector { items } => {
                self.on_step(&node.position);
                let items: Vec<ValueId> = items
                    .iter()
                    .map(|item| self.evaluate(item).unwrap())
                    .collect();
                let value = Value::Vector {
                    items: items.clone(),
                };
                self.values.push(value);
                let value_id = self.values.len() - 1;

                let type_id = self.tracer.ensure_type_id(TypeKind::Seq, "List");
                let compound_value = ValueRecord::Sequence {
                    elements: items
                        .iter()
                        .map(|item_value_id| ValueRecord::Cell {
                            place: runtime_tracing::Place((*item_value_id) as i64),
                        })
                        .collect(),
                    is_slice: false,
                    type_id,
                };
                self.tracer.register_compound_value(
                    runtime_tracing::Place(value_id as i64),
                    compound_value,
                );
                Ok(value_id)
            }
            NodeItem::Call { function, args } => {
                self.on_step(&node.position);
                self.evaluate_call(function, args, node.position)
            }
            NodeItem::Loop {
                item_name,
                from_expr,
                to_expr,
                code,
            } => {
                self.on_step(&node.position);
                self.evaluate_loop(item_name, from_expr, to_expr, code, node.position)
            }
            NodeItem::Function { name, params, code } => {
                self.define_function(name, params, code, node.position)?;
                Ok(VOID_VALUE_ID)
            }
            _ => {
                eprintln!("warn: trying to evaluate: {:?}", node);
                unimplemented!()
            }
        }
    }

    fn define_function(
        &mut self,
        name: &str,
        params: &[String],
        code: &[Node],
        position: Position,
    ) -> Result<(), Box<dyn Error>> {
        if self.functions.contains_key(name) {
            Err(format!("function {name} already exists").into())
        } else {
            self.functions.insert(
                name.to_string(),
                RuntimeFunction {
                    name: name.to_string(),
                    params: params.to_vec(),
                    code: code.to_vec(),
                    position,
                },
            );
            Ok(())
        }
    }

    fn value_for_int(&mut self, i: i64) -> ValueId {
        // TODO: hard to make the clippy suggestion work. Investigate more
        #[allow(clippy::map_entry)]
        if self.interned_ints.contains_key(&i) {
            *self.interned_ints.get(&i).unwrap()
        } else {
            let value = Value::Int { i };
            self.values.push(value.clone());
            let value_id = self.values.len() - 1;
            self.interned_ints.insert(i, value_id);
            let value_record = self.convert_to_trace_value(&value);
            self.tracer
                .register_cell_value(runtime_tracing::Place(value_id as i64), value_record);
            value_id
        }
    }

    fn new_value_id(&mut self) -> ValueId {
        self.values.push(Value::Void);
        self.values.len() - 1
    }

    fn value_for_string(&mut self, text: &str) -> ValueId {
        if self.interned_strings.contains_key(text) {
            *self.interned_strings.get(text).unwrap()
        } else {
            let value = Value::String {
                text: text.to_string(),
            };
            self.values.push(value);
            let value_id = self.values.len() - 1;
            self.interned_strings.insert(text.to_string(), value_id);
            value_id
        }
    }
    fn builtin_push(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        if args.len() != 2 {
            Err(format!("error: expected 2 args for push, got {} args", args.len()).into())
        } else {
            let collection_id = self.evaluate(&args[0])?;
            let value_id = self.evaluate(&args[1])?;
            if let Value::Vector { ref mut items } = self.values[collection_id] {
                items.push(value_id);
                Ok(collection_id)
            } else {
                Err("error: expected vector as first arg of push"
                    .to_string()
                    .into())
            }
        }
    }

    fn repr_many(&mut self, args: &[Node]) -> Result<String, Box<dyn Error>> {
        let mut output = "".to_string();
        for (i, arg) in args.iter().enumerate() {
            let value_id = self.evaluate(arg)?;
            let value_text = self.value_repr(value_id);
            output.push_str(&value_text);
            if i < args.len() - 1 {
                output.push(' ');
            }
        }
        Ok(output)
    }

    fn builtin_print(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        let text = self.repr_many(args)?;
        println!("{}", text);
        self.tracer
            .register_special_event(EventLogKind::Write, &text);
        Ok(VOID_VALUE_ID)
    }

    fn builtin_write_file(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        if args.len() != 2 {
            Err(format!(
                "error: expected 2 args for write-file, got {} args",
                args.len()
            )
            .into())
        } else {
            let path_value_id = self.evaluate(&args[0])?;
            let content_value_id = self.evaluate(&args[1])?;
            let path = self.values[path_value_id].clone();
            if let Value::String { text: path_text } = path {
                let content_repr: String = self.value_repr(content_value_id);
                self.tracer
                    .register_special_event(EventLogKind::WriteFile, &content_repr);
                fs::write(path_text, &content_repr)?;
                Ok(VOID_VALUE_ID)
            } else {
                Err("error: expected a string path for write-file"
                    .to_string()
                    .into())
            }
        }
    }

    fn builtin_add(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        if args.len() != 2 {
            Err(format!("error: expected 2 args for add, got {} args", args.len()).into())
        } else {
            let first_arg_id = self.evaluate(&args[0])?;
            let second_arg_id = self.evaluate(&args[1])?;
            let first_arg = self.values[first_arg_id].clone();
            let second_arg = self.values[second_arg_id].clone();
            if let Value::Int { i } = first_arg {
                if let Value::Int { i: i2 } = second_arg {
                    Ok(self.value_for_int(i + i2))
                } else {
                    Err("expected int for second arg for `add`".into())
                }
            } else {
                Err("expected int for first arg for `add`".into())
            }
        }
    }

    fn builtin_ref(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        if args.len() != 1 {
            Err(format!("error: expected 1 arg for ref, got {} args", args.len()).into())
        } else if let NodeItem::Name { name: _ } = &args[0].item {
            let arg_value_id = self.evaluate(&args[0])?;
            let value = Value::Ref {
                value_id: arg_value_id,
            };
            self.values.push(value);
            let value_id = self.values.len() - 1;
            Ok(value_id)
        } else {
            Err("error: expected a variable as an arg for `ref`"
                .to_string()
                .into())
        }
    }

    fn builtin_deref(&mut self, args: &[Node]) -> Result<ValueId, Box<dyn Error>> {
        if args.len() != 1 {
            Err(format!("error: expected 1 arg for ref, got {} args", args.len()).into())
        } else {
            let arg_value_id = self.evaluate(&args[0])?;
            let arg = &self.values[arg_value_id];
            if let Value::Ref { value_id } = arg {
                Ok(*value_id)
            } else {
                Err("expected a ref arg for `deref`".to_string().into())
            }
        }
    }
    fn evaluate_call(
        &mut self,
        function: &Node,
        args: &[Node],
        _position: Position,
    ) -> Result<ValueId, Box<dyn Error>> {
        if let NodeItem::Name { name } = &function.item {
            match name.as_str() {
                "push" => self.builtin_push(args),
                "print" => self.builtin_print(args),
                "write-file" => self.builtin_write_file(args),
                "add" => self.builtin_add(args),
                "ref" => self.builtin_ref(args),
                "deref" => self.builtin_deref(args),
                _ => {
                    if self.functions.contains_key(name) {
                        self.evaluate_call_to_user_function(name, args)
                    } else {
                        Err(format!("error: unsupported builtin call {name}").into())
                    }
                }
            }
        } else {
            Err("error: expected a function name for calls"
                .to_string()
                .into())
        }
    }

    fn evaluate_call_to_user_function(
        &mut self,
        name: &str,
        args: &[Node],
    ) -> Result<ValueId, Box<dyn Error>> {
        // called after check in self.functions
        let runtime_function = self.functions[name].clone();

        if args.len() != runtime_function.params.len() {
            return Err(format!(
                "error: function {} expected {} args, but received {}",
                name,
                runtime_function.params.len(),
                args.len()
            )
            .into());
        }

        let mut trace_args = vec![];
        let mut function_call_env = EnvScope::new_function_scope();
        for (param_name, arg) in runtime_function.params.iter().zip(args) {
            let arg_value_id = self.evaluate(arg)?;
            function_call_env.set(param_name, arg_value_id);
            let arg_value = self.values[arg_value_id].clone();
            let trace_arg_value = self.convert_to_trace_value(&arg_value);
            trace_args.push(self.tracer.arg(param_name, trace_arg_value));
        }

        self.env.push(function_call_env);
        let function_id = self.tracer.ensure_function_id(
            &runtime_function.name,
            &self.program_path,
            Line(runtime_function.position.line as i64),
        );

        self.tracer.register_call(function_id, trace_args);
        for (name, value_id) in self.env[self.env.len() - 1].values.iter() {
            self.tracer
                .register_variable(name, runtime_tracing::Place((*value_id) as i64));
        }

        let mut result_value_id = VOID_VALUE_ID;
        for expression in &runtime_function.code {
            // we return the last one
            result_value_id = self.evaluate(expression)?;
        }

        let _ = self.env.pop();

        let return_value = self.values[result_value_id].clone();
        let trace_return_value = self.convert_to_trace_value(&return_value);
        self.tracer.register_return(trace_return_value);
        self.trace_drop_locals();

        Ok(result_value_id)
    }

    fn evaluate_assign(
        &mut self,
        target: &Node,
        right: &Node,
        dereferencing: bool,
        _position: Position,
    ) -> Result<ValueId, Box<dyn Error>> {
        let last_index = self.env.len() - 1;
        let right_value_id = self.evaluate(right)?;
        match &target.item {
            NodeItem::Name { name } => {
                // eprintln!("info: INSERT IN ENV {name}");
                // map name to index for each function
                // directly store to index.. however similar to bytecode
                if !dereferencing {
                    self.env[last_index].set(name, right_value_id);
                    self.tracer
                        .register_variable(name, runtime_tracing::Place(right_value_id as i64));
                    Ok(right_value_id)
                } else {
                    // (set-deref name value)
                    // not changing where name points to, so not updating env
                    // but resetting the value to which name points to
                    let target_value_id = self.evaluate(target)?;
                    if let Value::Ref {
                        value_id: deref_value_id,
                    } = self.values[target_value_id]
                    {
                        // TODO set the underlying location to that `right_value_id`
                        // maybe ensure variables are stored in certain locations (~stack, ~heap or at least some kind of memory)
                        // register an assignment event: depending on `right`: copying directly from its variable, or a more complex expression
                        // with its variables
                        self.values[deref_value_id] = self.values[right_value_id].clone();
                        Ok(deref_value_id)
                        // todo!("implement assigning to ref")
                    } else {
                        Err("error: expected a ref value as the target for `set-deref`"
                            .to_string()
                            .into())
                    }
                }
            }
            NodeItem::Index { collection, index } => {
                let c = self.evaluate(collection)?;
                let index_value_id = self.evaluate(index)?;
                if let Value::Int { i } = self.values[index_value_id].clone() {
                    if let Value::Vector { ref mut items } = self.values[c] {
                        items[i as usize] = right_value_id;
                        self.tracer.assign_compound_item(
                            runtime_tracing::Place(c as i64),
                            i as usize,
                            runtime_tracing::Place(right_value_id as i64),
                        );
                        Ok(right_value_id)
                    } else {
                        Err("error: expected vector as the base of an index expression"
                            .to_string()
                            .into())
                    }
                } else {
                    Err("error: expected an integer as an index value"
                        .to_string()
                        .into())
                }
            }
            _ => unimplemented!(),
        }
    }

    fn evaluate_loop(
        &mut self,
        item_name: &str,
        from_expr: &Node,
        to_expr: &Node,
        code: &Node,
        _position: Position,
    ) -> Result<ValueId, Box<dyn Error>> {
        let mut result_value_id = VOID_VALUE_ID;
        let start_id = self.evaluate(from_expr)?;
        let to_id = self.evaluate(to_expr)?;
        if let Value::Int { i: start } = self.values[start_id] {
            if let Value::Int { i: to } = self.values[to_id] {
                self.env.push(EnvScope::new_internal_scope());
                let loop_env_index = self.env.len() - 1;
                let index_value_id = self.new_value_id();
                let index_trace_value_id = runtime_tracing::Place(index_value_id as i64);
                for index in start..to {
                    self.values[index_value_id] = Value::Int { i: index };
                    let index_value_record = ValueRecord::Int {
                        i: index,
                        type_id: INT_TYPE_ID,
                    };
                    self.env[loop_env_index].set(item_name, index_value_id);
                    self.invalidate_current_line(); // enforce a new "line" event for each loop iteration
                    if index == start {
                        self.tracer
                            .register_cell_value(index_trace_value_id, index_value_record.clone());
                        self.tracer
                            .register_variable(item_name, index_trace_value_id);
                    } else {
                        self.tracer
                            .assign_cell(index_trace_value_id, index_value_record.clone());
                    }
                    result_value_id = self.evaluate(code)?;
                }
                self.tracer.drop_variable(item_name);
                let _ = self.env.pop();
                Ok(result_value_id)
            } else {
                Err("error: expected int for `to` in loop".to_string().into())
            }
        } else {
            Err("error: expected int for `from` in loop".to_string().into())
        }
    }

    fn value_repr(&self, value_id: ValueId) -> String {
        let value = &self.values[value_id];
        match &value {
            Value::String { text } => text.clone(),
            Value::Int { i } => {
                format!("{i}")
            }
            Value::Bool { b } => {
                format!("{b}")
            }
            Value::Void => "void".to_string(),
            Value::Vector { items } => {
                let items_repr = items
                    .iter()
                    .map(|item| self.value_repr(*item))
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("[{items_repr}]")
            }
            Value::Object { .. } => "object".to_string(),
            Value::Ref {
                value_id: deref_value_id,
            } => format!("ref<{}>", self.value_repr(*deref_value_id)),
        }
    }
}

#[allow(dead_code)]
fn int_node(i: i64) -> Node {
    Node {
        item: NodeItem::Int { i },
        position: Position { line: 0, column: 0 },
    }
}

#[allow(dead_code)]
fn name_node(name: &str) -> Node {
    Node {
        item: NodeItem::Name {
            name: name.to_string(),
        },
        position: Position { line: 0, column: 0 },
    }
}

#[allow(dead_code)]
fn call_node(function: Node, args: Vec<Node>) -> Node {
    Node {
        item: NodeItem::Call {
            function: Box::new(function),
            args,
        },
        position: Position { line: 0, column: 0 },
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    // let program = Node::Block {
    //     items: vec![
    //         Node::Assignment {
    //             target: Box::new(name_node("value")),
    //             value: Box::new(Node::Vector {
    //                 items: vec![int_node(0), int_node(1)]
    //             }),
    //         },
    //         Node::Assignment {
    //             target: Box::new(
    //                 Node::Index {
    //                     collection: Box::new(name_node("value")),
    //                     index: Box::new(int_node(0)),
    //                 }),
    //             value: Box::new(int_node(1))
    //         },
    //         call_node(name_node("push"), vec![name_node("value"), int_node(1)]),
    //     ]
    // };
    let args: Vec<_> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: small-lang <file-path> [--tracing]");
        exit(1);
    }
    let path = path::PathBuf::from(&args[1]);
    let mut tracing = false;
    if args.len() > 2 {
        tracing = args[2] == "--tracing";
    }
    // println!("tracing {}", tracing);
    let source =
        fs::read_to_string(&path).unwrap_or_else(|_| panic!("tried to read from {path:?}"));

    let start = Instant::now();

    let mut interpreter = Interpreter::new(&path, tracing);

    // let code = r#"
    //     (set b (vector 0 1))
    //     (set (# b 0) 1)
    //     (push b 1)
    //     (loop i 0 100
    //         (push b i))
    //     b"#;
    // let program2 = parse_program(code).unwrap();
    // println!("{:#?}", program2);

    let program_node = parse_program(&source).unwrap();
    interpreter.on_start();
    let _res = interpreter.evaluate(&program_node).unwrap();

    let duration = start.elapsed();
    eprintln!("parsing/evaluating program: duration: {:?}", duration);

    if interpreter.tracing {
        let trace_path =
            PathBuf::from(env::var("CODETRACER_DB_TRACE_PATH").unwrap_or("trace.json".to_string()));
        let trace_folder = trace_path.parent().unwrap();
        let trace_metadata_path = trace_folder.join("trace_metadata.json");
        let trace_paths_path = trace_folder.join("trace_paths.json");

        println!("store in:");
        println!("  {trace_path:?} and");
        println!("  {trace_metadata_path:?} and");
        println!("  {trace_paths_path:?}");

        interpreter
            .tracer
            .store_trace_metadata(&trace_metadata_path)
            .unwrap();

        interpreter
            .tracer
            .store_trace_paths(&trace_paths_path)
            .unwrap();

        // duration code copied from
        // https://rust-lang-nursery.github.io/rust-cookbook/datetime/duration.html

        let start = Instant::now();
        interpreter.tracer.store_trace_events(&trace_path).unwrap();
        let duration = start.elapsed();
        eprintln!(
            "serializing and storing trace events: duration: {:?}",
            duration
        );
    }
    // println!("{}", interpreter.value_repr(res));
    // println!("values: raw: {:#?}", interpreter.values);
    // println!("values: repr: {:#?}", interpreter.values.iter()
    //         .enumerate()
    //         .map(|(value_id, _)| interpreter.value_repr(value_id))
    //         .collect::<Vec<String>>());

    Ok(())
}

// research: python, ruby others
// modification planning?
// toy language for example

// lang:
//
//
// 0: void
// 0: void; 1: 0; 2: 1; 3: b [h]
// 0: void; 1: 0; 2: 1; 3: b

// TODO:
//   generate more low-level events
//   generate steps, paths, full values, types for them
//   more complex postprocessing: for those; for calls(but no calls yet here..)/separate step?
//   also generate same for ruby/python high level
//   add small to ct? replay there
//   ..
//   modifications, model and generate events, eventually "checkpoints"
//   eventually: simple fns/calls: `(defun a (arg arg2) (set res (+ arg arg2)) res)` `(a 2 4)`
//     => generate: calls; process depths/parent etc in postprocess? but what about
//      partial trace: either always track calls or generate full values/track parents|callstack for those or
//      generate something like checkpoint on each "resume"?
//   eventually: also simple objects: `(set a (object (b 2) (c 4)))` `(. a b)`

// * small-lang: generate steps in json / ruby generate steps in json / maybe python
// * convert to capnp proto
// * eventually generate calls as well: simple? (maybe several/or in loop)
