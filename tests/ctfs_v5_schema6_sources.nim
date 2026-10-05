## Native importer fixtures: actual frozen Rust writer containers and actual
## declared Nim writer root overflow. No reader/compiler/filesystem mocks.
## Deliberate byte mutations are protocol refusal controls; original expected
## payloads come from genuine producer/readback receipts, not altered oracles.
import std/[unittest, json, os]
import codetracer_ctfs/container as nativeCtfs
include "../src/ct/trace/ctfs_sources"

let fixtures = paramStr(1)
let metadataFixtures = paramStr(2)
let output = paramStr(3)
doAssert fixtures.len > 0 and metadataFixtures.len > 0 and dirExists(output)
proc binaryString(data: seq[byte]): string =
  result = newString(data.len)
  for i,b in data: result[i] = char(b)
proc put64(data: var string, pos: int, value: uint64) =
  for i in 0..<8: data[pos+i] = char((value shr (8*i)) and 255)
proc refusedMember(label: string, data: string, member: string) =
  let path = output / (label & ".ct")
  writeFile(path, data)
  expect ValueError:
    discard openCtfs(path).readCtfsFile(member)

proc offsets(values: seq[uint64]): string =
  result = newString(values.len * 8)
  for i,value in values:put64(result,i*8,value)
proc schema6Table(label: string, flags: uint16, data, off: string,
                  hasData=true, hasOffsets=true, hasFilemap=false, filemap="",
                  sourcePayload=""): string =
  var ct = nativeCtfs.createCtfs(blockSize=4096,maxRootEntries=31,maxShards=0)
  var meta = openCtfs(metadataFixtures / "schema6-empty.ct").readCtfsFile("meta.dat")
  meta[6]=char(flags and 255);meta[7]=char(flags shr 8)
  proc add(name,payload: string) =
    var member=ct.addFile(name).get()
    var bytes=newSeq[byte](payload.len)
    for i,value in payload:bytes[i]=byte(value.ord)
    ct.writeToFile(member,bytes).get()
  add("meta.dat",meta)
  if hasData:add("paths.dat",data)
  if hasOffsets:add("paths.off",off)
  if hasFilemap:add("filemap.bin",filemap)
  if sourcePayload.len > 0:add("src0",sourcePayload)
  ct.closeCtfs().get()
  result=output / (label & ".ct")
  writeFile(result,binaryString(ct.toBytes()))

disableParamFiltering() # Three explicit fixture paths are input arguments, not test filters.

suite "version-aware real CTFS importer":
  test "actual frozen Rust empty/direct/mapped payloads":
    for name in ["empty", "direct", "mapped"]:
      let reader = openCtfs(fixtures / (name & ".ct"))
      check reader.readCtfsFile("payload") == readFile(fixtures / (name & ".expected"))
  test "actual unsharded Nim root-overflow allocation and payload":
    var ct = nativeCtfs.createCtfs(blockSize=4096, maxRootEntries=200, maxShards=0)
    var member = ct.addFile("payload").get()
    let expected = @[3'u8, 7, 11, 255]
    ct.writeToFile(member, expected).get()
    ct.closeCtfs().get()
    let data = binaryString(ct.toBytes())
    let path=output / "root-overflow.ct"
    writeFile(path,data)
    let reader=openCtfs(path)
    check reader.v5RootBlocks == 2
    check reader.readCtfsFile("payload") == binaryString(expected)
    var corrupt=data
    put64(corrupt, 16+8, (1'u64 shl 63) or 1'u64)
    refusedMember("reserved-root-direct",corrupt,"payload")
    put64(corrupt,16+8,1)
    refusedMember("reserved-root-mapping",corrupt,"payload")
    refusedMember("truncated-root",data[0..<4096],"payload")
  test "real writer null/truncated/direct bounds refuse":
    var direct=readFile(fixtures / "direct.ct")
    put64(direct,24,0)
    refusedMember("nonempty-null",direct,"payload")
    put64(direct,24,(1'u64 shl 63))
    refusedMember("direct-block-zero",direct,"payload")
    put64(direct,24,(1'u64 shl 63) or 2'u64)
    refusedMember("direct-outside",direct,"payload")
    refusedMember("partial-direct",readFile(fixtures / "direct.ct")[0..<4097],"payload")
  test "unknown and unsupported container versions are named refusals":
    for version in [6,255]:
      var data=readFile(fixtures / "empty.ct");data[5]=char(version)
      let path=output / ("version-" & $version & ".ct");writeFile(path,data)
      try:
        discard openCtfs(path)
        check false
      except ValueError as error:
        check ("version " & $version) in error.msg
  test "actual schema6 producer core and path ID authority":
    for name in ["schema6-absent", "schema6-empty"]:
      let meta=readCtfsMetaDat(metadataFixtures / (name & ".ct"))
      check meta.program == "fixture-program"
      check meta.args == @["arg one", "arg-two"]
      check meta.workdir == "/fixture/workdir"
      check meta.paths.len == 0
    check readCtfsMetaDat(metadataFixtures / "schema6-bare-ids.ct").paths == @["/fixture/one", "/fixture/one", ""]
    check readCtfsMetaDat(metadataFixtures / "schema6-columns.ct").paths == @["/fixture/columns", "/fixture/conventional"]
  test "retained actual Python core matches frozen canonical Rust decoder":
    let data=readFile(metadataFixtures / "retained-python-meta.dat")
    let actual=parseCtfsMetaDat(data)
    let expected=parseJson(readFile(metadataFixtures / "retained-python-meta.expected.json"))
    check actual.recordingId == expected["recording_id"].getStr()
    check actual.program == expected["program"].getStr()
    check actual.workdir == expected["workdir"].getStr()
    check actual.args.len == expected["args"].len
    for i,arg in actual.args:check arg == expected["args"][i].getStr()
    var bad=data;bad[8]=char(2)
    expect ValueError:discard parseCtfsMetaDat(bad)
    expect ValueError:discard parseCtfsMetaDat(data[0..<11])
    expect ValueError:discard parseCtfsMetaDat(data[0..<13])
  test "schema6 finalized tables reject malformed pair and offset authority":
    for pair in [(true,false),(false,true)]:
      expect ValueError:discard readCtfsMetaDat(schema6Table("missing-" & $pair[0],0,"abc",offsets(@[0'u64,3]),pair[0],pair[1]))
    for index, off in ["", "1234567", offsets(@[1'u64,3]),offsets(@[0'u64,5,3]),offsets(@[0'u64,9]),offsets(@[0'u64,2])]:
      expect ValueError:discard readCtfsMetaDat(schema6Table("offset-" & $index,0,"abc",off))
  test "schema6 whole framed records refuse missing, overflow and extra fields":
    for index,record in ["\x01a", "\x01a\x01", "\x01a\x01\x01", "\x01a\x01\x00", "\x01a\x00x", "\x01a" & repeat("\x80",9) & "\x02"]:
      expect ValueError:discard readCtfsMetaDat(schema6Table("column-bad-" & $index,0x10,record,offsets(@[0'u64,uint64(record.len)])))
    for index,record in ["\x01a", "\x01a\x00", "\x01a\x01x"]:
      expect ValueError:discard readCtfsMetaDat(schema6Table("line-bad-" & $index,0x4000,record,offsets(@[0'u64,uint64(record.len)])))
    check readCtfsMetaDat(schema6Table("line-good",0x4000,"\x01a\x01",offsets(@[0'u64,3]))).paths == @["a"]
    expect ValueError:discard readCtfsMetaDat(schema6Table("mutually-exclusive",0x4010,"",offsets(@[0'u64])))
  test "legacy materialization retains tables without metadata":
    var ct=nativeCtfs.createCtfs(blockSize=4096,maxRootEntries=31,maxShards=0)
    var data=ct.addFile("paths.dat").get()
    let path="/legacy/one"
    var bytes=newSeq[byte](path.len)
    for i,value in path:bytes[i]=byte(value.ord)
    ct.writeToFile(data,bytes).get()
    var off=ct.addFile("paths.off").get()
    let offString=offsets(@[0'u64,uint64(path.len)])
    bytes=newSeq[byte](offString.len)
    for i,value in offString:bytes[i]=byte(value.ord)
    ct.writeToFile(off,bytes).get()
    ct.closeCtfs().get()
    let container=output / "legacy-no-meta.ct";writeFile(container,binaryString(ct.toBytes()))
    let extracted=output / "legacy-extracted";createDir(extracted)
    check materializeCtfsSources(container,extracted)
    check parseJson(readFile(extracted / "paths.json")) == %(@[path])

  test "schema6 nonempty source paths resolve preserved trace payload without filemap":
    let path = output / "recorded-source.py"
    let expected = "value = 42\nprint(value)\n"
    let target = output / "source-preserved"
    let stored = target / "files" / safePayloadPath(path)
    createDir(stored.parentDir)
    writeFile(stored, expected)
    let container = schema6Table("source-preserved", 0, path, offsets(@[0'u64, uint64(path.len)]))
    check materializeCtfsSources(container, target)
    check parseJson(readFile(target / "paths.json")) == %(@[path])
    check readFile(stored) == expected
    check not fileExists(path) # No ambient source supplied this positive.
  test "schema6 original source bytes materialize and missing references refuse":
    let path = output / "actual-original.py"
    let expected = "print(123)\n"
    writeFile(path, expected)
    let container = schema6Table("source-original", 0, path, offsets(@[0'u64, uint64(path.len)]))
    let target = output / "source-original"; createDir(target)
    check materializeCtfsSources(container, target)
    check readFile(target / "files" / safePayloadPath(path)) == expected
    check parseJson(readFile(target / "paths.json")) == %(@[path])
    removeFile(path)
    let absent = output / "source-missing"; createDir(absent)
    expect ValueError: discard materializeCtfsSources(container, absent)
    check not fileExists(absent / "paths.json")
  test "schema6 present malformed filemap still refuses despite preserved source":
    let path = output / "mapped-reference.py"
    let target = output / "malformed-filemap"; createDir(target)
    let stored = target / "files" / safePayloadPath(path)
    createDir(stored.parentDir); writeFile(stored, "print(456)\n")
    let container = schema6Table("malformed-filemap", 0, path,
      offsets(@[0'u64, uint64(path.len)]), hasFilemap=true, filemap="not-FMAP")
    expect ValueError: discard materializeCtfsSources(container, target)
    check readFile(stored) == "print(456)\n"
    check not fileExists(target / "paths.json")
    let valid = schema6Table("valid-empty-filemap", 0, path,
      offsets(@[0'u64, uint64(path.len)]), hasFilemap=true,
      filemap="FMAP\x01\x00\x00\x00")
    check materializeCtfsSources(valid, target)
    check readFile(stored) == "print(456)\n"
    check parseJson(readFile(target / "paths.json")) == %(@[path])
  test "schema6 nonempty filemap preserves identical bytes and refuses conflicts and links":
    let path = output / "fmap-source.py"
    let expected = "print(789)\n"
    var fmap = "FMAP\x01\x00\x01\x00" & newString(8)
    var encoded = 0'u64
    var factor = 1'u64
    for letter in "src0":
      encoded += uint64(Base40Alphabet.find(letter)) * factor
      factor *= 40
    put64(fmap, 8, encoded)
    fmap.add "\x02\x00\x00"
    doAssert path.len < 128
    fmap.add char(path.len); fmap.add path
    fmap.add "\x06python"
    let container = schema6Table("nonempty-filemap", 0, path,
      offsets(@[0'u64, uint64(path.len)]), hasFilemap=true,
      filemap=fmap, sourcePayload=expected)
    for kind in ["new", "identical", "different", "linked"]:
      let target = output / ("fmap-" & kind); createDir(target)
      let stored = target / "files" / safePayloadPath(path)
      createDir(stored.parentDir)
      let foreign = output / "fmap-foreign.py"
      if kind == "identical": writeFile(stored, expected)
      if kind == "different": writeFile(stored, "preserved different bytes\n")
      if kind == "linked":
        writeFile(foreign, "foreign bytes\n")
        createSymlink(foreign, stored)
      if kind in ["new", "identical"]:
        check materializeCtfsSources(container, target)
        check readFile(stored) == expected
        check parseJson(readFile(target / "paths.json")) == %(@[path])
      else:
        expect ValueError: discard materializeCtfsSources(container, target)
        check not fileExists(target / "paths.json")
        if kind == "different": check readFile(stored) == "preserved different bytes\n"
        else:
          check symlinkExists(stored)
          check readFile(foreign) == "foreign bytes\n"

  test "schema6 source payload link refuses and preserves its foreign target":
    let path = output / "linked-reference.py"
    let target = output / "linked-payload"; createDir(target)
    let foreign = output / "foreign-source.py"; writeFile(foreign, "foreign bytes\n")
    let stored = target / "files" / safePayloadPath(path)
    createDir(stored.parentDir); createSymlink(foreign, stored)
    let container = schema6Table("linked-payload", 0, path, offsets(@[0'u64, uint64(path.len)]))
    expect ValueError: discard materializeCtfsSources(container, target)
    check symlinkExists(stored)
    check readFile(foreign) == "foreign bytes\n"

  test "genuine current Python recording materializes nonempty source IDs and bytes":
    let actualRecording = paramStr(4)
    doAssert actualRecording.len > 0 and fileExists(actualRecording)
    let actual = readCtfsMetaDat(actualRecording)
    check actual.paths.len > 0
    let target = output / "actual-python-source"; createDir(target)
    check materializeCtfsSources(actualRecording, target)
    check parseJson(readFile(target / "paths.json")) == %(actual.paths)
    for path in actual.paths:
      if path.len > 0:
        let original = resolveTraceSourcePath(path, actual.workdir)
        check fileExists(original)
        check readFile(target / "files" / safePayloadPath(path)) == readFile(original)
