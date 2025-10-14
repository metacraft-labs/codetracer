const TRACE_SHARING_DISABLED_ERROR_MESSAGE* = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling the `enabled` field of the `traceSharing` object to true
"""

const FILE_ID_FIELD* = "fileId"
const CONTROL_ID_FIELD* = "controlId"
const UPLOAD_URL_FIELD* = "uploadUrl"
const FILE_STORED_UNTIL_FIELD* = "fileStoredUntilEpochSeconds"

type UploadedInfo* = ref object
  fileId*: string
  downloadKey*: string
  controlId*: string
  storedUntilEpochSeconds*: int
