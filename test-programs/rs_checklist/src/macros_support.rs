/// Trait implemented by the derive macro from `rs_checklist_macros`.
/// It is placed in its own module so the proc-macro can reference it with
/// the absolute path `::rs_checklist::macros_support::AutoHello`.
pub trait AutoHello {
    fn hello(&self) -> String;
}
