//! CodeTracer's extensions to DAP message bodies.
//!
//! `dap_types.rs` is GENERATED from the upstream Debug Adapter Protocol schema
//! (`node schema/schema.js`, which reads
//! `libs/vscode-debugadapter-node/debugProtocol.json`), and `ci/lint/rust.sh`
//! regenerates it and fails when the committed file differs. Fields that DAP
//! itself does not define therefore cannot live there: an edit to the
//! generated file is erased by the next regeneration, and the lint that guards
//! it goes red for every branch until someone does exactly that.
//!
//! They live here instead, as wrappers that carry the generated DAP body
//! through `#[serde(flatten)]` and add CodeTracer's fields beside it. On the
//! wire the result is one flat JSON object — the same bytes the extended
//! generated structs produced — so a generic DAP client sees plain DAP plus
//! fields it ignores, and CodeTracer's own clients see the extensions.
//!
//! See <https://microsoft.github.io/debug-adapter-protocol/specification#Requests_Source>
//! for the upstream `source` request these extend.

use serde::{Deserialize, Serialize};

use crate::dap_types::{SourceArguments, SourceResponseBody};

/// DAP `SourceArguments`, plus CodeTracer's `allowWorkingTree`.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SourceArgumentsExt {
    /// The upstream DAP arguments (`source`, `sourceReference`).
    #[serde(flatten)]
    pub dap: SourceArguments,
    /// CodeTracer extension: whether the client accepts source read off the
    /// REPLAY HOST rather than out of the recording.
    ///
    /// The engine's last resort is the recorded path itself — this machine's
    /// filesystem, or a source view a host installed through
    /// `ct/install-source-view`. Neither is tied to the recording: the file on
    /// this disk may be any build at all, and it may not even belong to this
    /// trace. That answer is still useful (it is how the desktop has always
    /// worked), so it stays available and is LABELLED
    /// [`SourceOriginKind::WorkingTree`] — but a client that must not render
    /// unverifiable text can refuse it up front by sending `false`, and then a
    /// path the recording does not carry is answered as unavailable instead of
    /// served.
    ///
    /// Absent means `true`, so a generic DAP client (and the desktop) keeps the
    /// behaviour it has today.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow_working_tree: Option<bool>,
}

/// DAP `SourceResponseBody`, plus CodeTracer's source-revision and provenance
/// fields.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SourceResponseBodyExt {
    /// The upstream DAP body (`content`, `mimeType`).
    #[serde(flatten)]
    pub dap: SourceResponseBody,
    /// CodeTracer extension: the source REVISION this content belongs to.
    ///
    /// DAP's own `SourceResponseBody` has no such field, and without one a
    /// client cannot tell "here is the revision you asked for" from "here is
    /// the only revision I have". Those two are the same bytes and different
    /// answers: one file path can have several recorded contents (live HCR),
    /// and rendering the wrong one under the right line numbers shows a build
    /// that never ran. The client
    /// (`src/frontend/viewmodel/sdk/source_provider.nim`) compares this
    /// against the generation it requested and reports a typed degradation
    /// rather than the text when they differ.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_generation: Option<i64>,
    /// CodeTracer extension: the content digest of the served revision, when
    /// the recording carries one. Empty/absent means the engine has no stable
    /// digest and the client falls back to path + generation, exactly as
    /// `Location.sourceDigest` already documents.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_digest: Option<String>,
    /// CodeTracer extension: WHERE these bytes came from. See
    /// [`SourceOriginKind`] — this is the field that lets a client report a
    /// working-tree read as unverified instead of trusting an answer it cannot
    /// characterise.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_origin: Option<SourceOriginKind>,
}

/// Where the bytes in a [`SourceResponseBodyExt`] came from.
///
/// CodeTracer extension. This is the *wire* provenance of one `source`
/// response, and it is deliberately a different type from
/// [`crate::expr_loader::SourceOrigin`], which is the per-line provenance the
/// value-origin classifier threads through an origin chain (spec §6.1). They
/// answer different questions at different granularities and must be free to
/// change independently.
///
/// # Why the response has to say this at all
///
/// Without it, `success: true` means only "some bytes exist for that path". A
/// client cannot tell the recording's own copy from a file that merely happens
/// to sit at the same path on the replay host, so it cannot honour the
/// verified/unverified distinction its own source pane is built on — and an
/// engine-side resolution bug (the payload silently skipped, the working tree
/// silently answering) is indistinguishable from correct behaviour. Measured:
/// before CTUI-4's fix the engine served the replay host's working tree for
/// every Noir recording and reported it exactly as it reported a payload read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SourceOriginKind {
    /// The RECORDING's own copy: the container's bundled raw source views, or
    /// the trace folder's `files/` payload. Verifiable against the recording.
    Payload,
    /// Read off the replay host — its filesystem, or a source view a host
    /// pushed in. Not tied to the recording, and reported as unverified.
    WorkingTree,
    /// No source anywhere for this path. Carried on the FAILURE response, so a
    /// client can tell "this engine has nothing for this path" from "this
    /// engine cannot answer `source` at all"; those two are different rows in
    /// the client's degraded-state axis.
    Unavailable,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dap_types::Source;
    use serde_json::json;
    use std::error::Error;

    // The wrappers exist so the WIRE stays what it was when these fields sat
    // inside the generated structs. These pin that: flattening must yield one
    // flat camelCase object, and an absent extension must stay absent.

    #[test]
    fn source_arguments_ext_reads_and_writes_the_flat_wire_shape() -> Result<(), Box<dyn Error>> {
        let wire = json!({
            "source": { "path": "/src/main.nr" },
            "sourceReference": 0,
            "allowWorkingTree": false,
        });
        let args: SourceArgumentsExt = serde_json::from_value(wire.clone())?;
        assert_eq!(
            args.dap.source.as_ref().and_then(|s| s.path.as_deref()),
            Some("/src/main.nr")
        );
        assert_eq!(args.dap.source_reference, 0);
        assert_eq!(args.allow_working_tree, Some(false));
        assert_eq!(serde_json::to_value(&args)?, wire);
        Ok(())
    }

    #[test]
    fn source_arguments_ext_accepts_a_plain_dap_client() -> Result<(), Box<dyn Error>> {
        let wire = json!({ "source": { "path": "/a" }, "sourceReference": 0 });
        let args: SourceArgumentsExt = serde_json::from_value(wire.clone())?;
        assert_eq!(args.allow_working_tree, None);
        // Absent in, absent out: no `allowWorkingTree: null` appears.
        assert_eq!(serde_json::to_value(&args)?, wire);
        Ok(())
    }

    #[test]
    fn source_response_body_ext_writes_the_flat_wire_shape() -> Result<(), Box<dyn Error>> {
        let body = SourceResponseBodyExt {
            dap: SourceResponseBody {
                content: "fn main() {}\n".to_string(),
                mime_type: None,
            },
            source_generation: Some(0),
            source_digest: None,
            source_origin: Some(SourceOriginKind::WorkingTree),
        };
        let wire = serde_json::to_value(&body)?;
        assert_eq!(
            wire,
            json!({
                "content": "fn main() {}\n",
                "sourceGeneration": 0,
                "sourceOrigin": "working-tree",
            })
        );
        let back: SourceResponseBodyExt = serde_json::from_value(wire)?;
        assert_eq!(back, body);
        Ok(())
    }

    #[test]
    fn source_arguments_ext_keeps_the_upstream_source_fields() -> Result<(), Box<dyn Error>> {
        let args = SourceArgumentsExt {
            dap: SourceArguments {
                source: Some(Source {
                    path: Some("/p".to_string()),
                    ..Default::default()
                }),
                source_reference: 7,
            },
            allow_working_tree: None,
        };
        assert_eq!(
            serde_json::to_value(&args)?,
            json!({ "source": { "path": "/p" }, "sourceReference": 7 })
        );
        Ok(())
    }
}
