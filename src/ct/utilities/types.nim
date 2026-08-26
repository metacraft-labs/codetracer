import ../online_sharing/artifact
# `UploadedInfo.kind` is an `ArtifactKind`, so anybody who can name the type
# must be able to name its values.
export artifact

const TRACE_SHARING_DISABLED_ERROR_MESSAGE* = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling the `enabled` field of the `traceSharing` object to true
"""

type UploadedInfo* = ref object
  ## The result of storing one artifact.
  ##
  ## AS-2 (`codetracer-specs/Sharing/Artifact-Store.md` §8, defects 3 and 11):
  ## this object used to carry `fileId`, `downloadKey`, `controlId` and
  ## `storedUntilEpochSeconds`, and of those four exactly one was ever
  ## assigned on the modern path — `fileId`, which held the *recording* id
  ## after a single-file upload and the *upload-session* id after a slice
  ## upload, with nothing telling the caller which of the two namespaces it
  ## had received.  The other three were the pre-M-REC-8 sharing service's
  ## tokens; nothing populated them, and printing them printed empty strings.
  ##
  ## So the fields are now what the store can actually answer, each in its own
  ## namespace and each named for what it is.
  artifactId*: string
    ## The artifact's identity, whatever kind it is.  For a recording this is
    ## its recording id (the `aioSeededFromRecordingId` binding); for every
    ## other kind it is minted at store time.
  kind*: ArtifactKind
    ## What was stored.  Said explicitly rather than inferred by a caller from
    ## which command ran.
  shareUrl*: string
    ## The link to hand to somebody else — `/{orgSlug}/{artifactId}/download`,
    ## which carries no kind and is the argument `ct download` takes.
  uploadSessionId*: string
    ## The server-issued handle for a *multi-part transfer*, empty unless one
    ## was opened.  Held apart from `artifactId` because it names the transfer
    ## rather than the artifact.
  protection*: ArtifactProtection
    ## What confidentiality the stored payload carries (AS-3).  `apNone` — the
    ## enum's zero value — unless the upload encrypted it, so every existing
    ## construction of this object keeps its meaning.
    ##
    ## Reported because whoever receives a share link has to be told whether a
    ## password goes with it, and the *uploader* is the only party who can say:
    ## the service was never told the key and, for the recording kind, whose
    ## request bodies are frozen, was never even told there is one.
  exitCode*: int
