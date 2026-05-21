import std/[json]

import repro_hcr_agent
import repro_hcr_linker
import repro_hcr_linkgraph

when defined(macosx) and defined(arm64):
  proc dapInspectionAnchor(before, after: int): int {.noinline.} =
    result = before + after # CODETRACER_DAP_STABLE_POST_HCR_LINE

  proc main() =
    let functionName = "_codetracer_reprobuild_hcr_mcr_dap_entry"
    let oldBytes = aarch64PatchableReturnBytes(11, sledNops = 4)
    let patchBytes = aarch64ReturnImmediateBytes(77)
    var target = initMinimalAarch64Target(functionName, oldBytes)
    defer: target.close()

    let observedBefore = target.callOriginalPointer()
    let plan = directPatchPlanFromBytes(functionName, patchBytes)
    let tx = patchTransactionFromPlan(plan, functionName,
      target.targetEntryAddress, nopSledBytes = 16)
    let evidence = applyPatchTransaction(target.targetOps(), tx)
    let observedAfter = target.callOriginalPointer()
    let dapStablePostHcrLine = dapInspectionAnchor(observedBefore, observedAfter)

    var root = newJObject()
    root["schemaId"] = newJString("codetracer.reprobuild-hcr-mcr-dap/v1")
    root["before"] = newJInt(observedBefore)
    root["after"] = newJInt(observedAfter)
    root["dapStablePostHcrLine"] = newJInt(dapStablePostHcrLine)
    root["targetEntryAddress"] = newJInt(BiggestInt(target.targetEntryAddress))
    root["patchAddress"] = newJInt(BiggestInt(target.patchAddress))
    root["targetProtection"] = newJString($target.targetProtection)
    root["patchProtection"] = newJString($target.patchProtection)
    root["retainedOldEntryBytesHex"] =
      newJString(bytesHex(target.retainedOldEntryBytes))
    root["symbolGeneration"] = newJInt(BiggestInt(target.symbolGeneration))
    root["publishedPatchAddress"] =
      newJInt(BiggestInt(target.publishedPatchAddress))
    root["flushCount"] = newJInt(target.flushes.len)
    root["sharedLibraryPositivePath"] = newJBool(false)
    root["debuggerUnwindRegistered"] = newJBool(false)
    root["patchPlan"] = patchPlanJson(plan)
    root["evidence"] = transactionEvidenceJson(evidence)
    echo $root

  main()
else:
  echo """{"schemaId":"codetracer.reprobuild-hcr-mcr-dap/v1","unsupported":"macos-arm64-only"}"""
