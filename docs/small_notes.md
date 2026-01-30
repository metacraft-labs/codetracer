
* Format:
  * Overall types: JSON/binary
    * Maybe add instance, eventually enum? Something else important?
  * Format: keep JSON? Or probably json lines for streaming/not whole file?
    Or `capnp`/`flatbuffers`/other?
  * db-backend adaptation if needed, or giving our code as an example?


---------------

db-backend/rr gdb backend:
  graph/explain; maybe plan; eventually resolve in later days/weeks?;

small-lang:
  ok# fix flow/eventually others
  ok# maybe merge?
  .. eventually start on value tracking

Others:
  Planning/documenting: talk with Stan? Maybe event flow/step view/others?
  Tooling: editors/others
  Testing?
  Peter: CI what to do?
  Cooperation with Nedy/others; Nikola: needed/also ct-web needs/db-backend??


----

Small regression for filesystem: imported traces(ctrlp working)

Tooling: editors/monitor etc
  ok, nix setup; update; lsp
  todo helix? others?

Plan value support?
  Simple events for value register/modify
  Add value id as an node in the graph;
  and events as edges;
  value_node:
    value_id or
    literal
  full_value register specifically

  atom!
  !
  atoms and compound

  register_cell(value_id, atom_value);
  register_compound(value_id, eventually_kind: seq/object/other? or just type_id, type_id);
  register_modify(value_id, coord, cell_value_id);
  // eventually coord / modify_info can include push/pop/insert etc?
  register_variable(variable_id, value_id);
  // reassign => new register_variable or assign?
  if value starts pointing somehow to new value? maybe ref?
  register_ref(value_id, target_value_id);
  register_ref for reassign to other?

  eventually we can track reads/usages
  register_access(value_id);

  modify_info:
    index coord index: Int; value_node: ValueNode
    field coord name: String;
    push index: Int; just in case
    pop index: Int; just in case
    clear
    eventually: others?

  or register_index_assign(value_id, index, index_node, sub_value_node);
  register_field_assign(value_id, name, sub_value_node);
  register_push(value_id, sub_value);
  register_pop(value_id);
  register_clear(value_id);

  register
  // nope
  register(value_id, full_value);
  assign(value_id, value_node);
  remove(value_id); // maybe connect to variables? as well
  variable(variable_id, value_id);

  #id @name

  register can generate many edges in one
  maybe still better than producing many mini-events for now
  or we can produce them internally from register
  register_compound_value(#value_id, value)

  register_compound_value(#0, [0 1 2 3 4]) -> #5 -> #0 -> 0; #1 -> 1; etc


  register_cell(#1 @list[0], 0)..
  register_compound(#0 @list, type_id);
  init_compound(#0 @list, [#1, #2..]);

  or just
  register_compound(values); and produce the init/edges at once in the backend

  variable("list", #0 @list)
  register_atom_value(#6 @limit, 10_000)
  variable("limit", #6 @limit)

  register_atom_value(#7 @i, 0)
  variable("i", #7 @i)

  assign_atom_value(#7 @i, 1)
  assign_atom_value(#7 @i, 2)

  etc

  # function: for now no copy annotation, just address
  variable("list", #0 @list)
  i..
  new-first..
  set -> assign_atom_value(#1 @list[0], 1)
  etc..

  list now : #0 -> #1
                -> #2 etc

  ready!

  modify(value_id, sub_value_coord, sub_value_node);
  sub_value_coord:
    index value_node(int); int: probably always can use int; but tracking value id useful for read-flow/usage references
    or
    field string name
    or slice?
    or address?
    or other TODO
  operations/call results for now maybe producing anon values with new value id;
  but eventually if we track them, can have more advanced history

Editors:
  VS-Code

  Helix/emacs/vim?

  zed/custom/codetracer/other??
