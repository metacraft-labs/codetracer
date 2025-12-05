//! Simple derive macro used by the Rust checklist examples.
//! The derive emits an implementation of `rs_checklist::macros_support::AutoHello`
//! that returns a labeled greeting. Keeping it tiny avoids distracting from the
//! main probes while still exercising proc-macro plumbing.

use proc_macro::TokenStream;
use quote::quote;
use syn::{DeriveInput, parse_macro_input};

#[proc_macro_derive(AutoHello)]
pub fn derive_auto_hello(input: TokenStream) -> TokenStream {
    let ast = parse_macro_input!(input as DeriveInput);
    let ident = ast.ident;
    let expanded = quote! {
        impl ::rs_checklist::macros_support::AutoHello for #ident {
            fn hello(&self) -> String {
                format!(
                    "Hello from {} (Debug = {:?})",
                    stringify!(#ident),
                    self
                )
            }
        }
    };
    TokenStream::from(expanded)
}
