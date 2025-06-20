const TRACE_SHARING_DISABLED_ERROR_MESSAGE* = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling the `enabled` field of the `traceSharing` object to true
"""

const UPLOAD_URL_FIELD* = "UploadUrl"
const FILE_ID_FIELD* = "FileId"
const CONTROL_ID_FIELD* = "ControlId"
const FILE_STORED_FIELD* = "FileStoredUntil"

type UploadedInfo* = ref object
  fileId*: string
  downloadKey*: string
  controlId*: string
  storedUntilEpochSeconds*: int
