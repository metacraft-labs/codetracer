func startsWith*(a, b: cstring): bool {.importjs: "#.startsWith(#)".}
func endsWith*(a, b: cstring): bool {.importjs: "#.endsWith(#)".}
