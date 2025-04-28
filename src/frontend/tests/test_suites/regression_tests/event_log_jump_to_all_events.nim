import
  std / [
    sequtils, strutils, strformat, sets,
    macros, jsffi, async, jsconsole,
    algorithm, os, json
  ],
  lib,
  ../../testing_framework/test_helpers,
  ../../testing_framework/selenium_web_driver,
  ../../testing_framework/extended_web_driver,
  ../../testing_framework/test_runner,
  ../../page_objects/layout_page,
  ../../page_objects/layout_page_model,
  ../../page_objects/layout_page_model_extractors,
  ../../../lang

type TestParameters = object
  folderPath: cstring
  fileName: cstring
  isSourceGenerated: bool
  sourceGeneratorFilePath: cstring

proc newTestParameters(): TestParameters =
  var testPatrameters = TestParameters()

  #currently there are no lists or objects to be initialized but if such
  #are added in the `future to TestParameters then it should be done here

  return testPatrameters

proc getTestParamsFromEnvironment(): TestParameters =
  let json = JSON.parse(nodeProcess.argv[2])
  let testParameters = cast[TestParameters](json)
  return testParameters

# TODO: eventually implement a smarter way for the initial ReadFiles
const AFTER_INITIAL_READS_EVENT_INDEX: array[Lang, int] = [
  0, # C
  0, # C++
  0, # Rust
  0, # nim
  0, # Go
  0, # Pascal
  0, # Python
  0, # Ruby
  0, # Ruby(db)
  0, # JavaScript
  0, # Lua
  0, # Asm
  0, # Noir
  0, # Rust wasm
  0, # C++ wasm
  0, # Small
  0 # unknown
]

proc jumpToAllEventsOnce*(filePath: cstring, fileName: cstring, lang: Lang): Future[void] {.async.} =
  #TODO: optimize and remove the wait below
  await wait(5_000)
  let path = nodeProcess.argv[0]

  #TODO: create settings file for tests where the format of the filename is defined
  #_actual is defined in .gitignore
  let expectedFilePath = &"{filePath}/{fileName}_expected.txt"
  let actualFilePath = &"{filePath}/{fileName}_actual.txt"

  let layoutPage = LayoutPage()

  var eventLogTab = EventLogTab()
  for i in 0 .. defaultWaitForElement div defaultWaitInterval:
    let eventLogTabs = await eventLogTabs(layoutPage, true)
    if eventLogTabs.len > 0:
      eventLogTab = eventLogTabs[0]
      break
    await wait(defaultWaitInterval)

  #TODO: replace wait with load ready event when implemented, waiting for page to fully load and be functional
  await wait(8000)

  var events: seq[EventElement] = @[] #await eventLogTab.events
  for i in 0 .. defaultWaitForElement div defaultWaitInterval:
    #echo &"wait for events {i}"
    events = await eventElements(eventlogTab, true)
    if events.len > 0:
      break
    await wait(defaultWaitInterval)

  if not await pathExists(expectedFilePath):
    echo "creating new expected file"
    for i, event in events:
      if i >= AFTER_INITIAL_READS_EVENT_INDEX[lang]: # skip binary ELF-file like reads
        await event.jumpToEvent()
        await wait(4000)

        let eventConsoleOutput = await event.consoleOutput()
        discard await fsPromises.appendFile(expectedFilePath, &"click on event {i}: {eventConsoleOutput}\n")

        let layoutPageModel = await extractModel(layoutPage)

        #echo %layoutPageModel
        discard await fsPromises.appendFile(expectedFilePath, &"{%layoutPageModel}\n")
  else: #TODO investigate why test is flaky if test is executed immediately after the record
    discard await fsPromises.writeFile(actualFilePath, cstring "", js{})
    for i, event in events:
      if i >= AFTER_INITIAL_READS_EVENT_INDEX[lang]: # skip binary ELF-file like reads
        echo "  jumping to event with index ", i
        await event.jumpToEvent()
        echo "  wait a bit"
        await wait(4000)

        let eventConsoleOutput = await event.consoleOutput()
        discard await fsPromises.appendFile(actualFilePath, &"click on event {i}: {eventConsoleOutput}\n")

        let layoutPageModel = await extractModel(layoutPage)

        #echo %layoutPageModel
        discard await fsPromises.appendFile(actualFilePath, &"{%layoutPageModel}\n")

    #this is not run on the first pass when the expected file is not created
    if not (await compareFiles(actualFilePath, expectedFilePath)):
      raise UnexpectedTestResult.newException(&"{expectedFilePath} differs from {actualFilePath}")


