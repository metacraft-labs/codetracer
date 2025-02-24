import
  sequtils, strutils, strformat, sets, macros, jsffi, async, unittest, jsconsole, algorithm, os, # os because `/`
  #chronicles,
  ../../lib, ../../types, /test_helpers, /selenium_web_driver, /extended_web_driver_helpers

#Web Driver Framework Settings
const isWebDriverInDebugMode* = true

const defaultWaitInterval* = 250
const defaultWaitForElement* = 20_000

const defaultRetryFindElementLimit* = defaultWaitForElement div defaultWaitInterval

type StaleElementReferenceException* = object of Exception
type ElementNotFoundException* = object of Exception

#----- Workaround for not being able to catch javascript exceptions
#----- Diferent exceptions are being hadnled by their error messages

#selenium exception messages examples and variables
#no such element: Unable to locate element: {"method":"css selector","selector":"div"}
#TODO: replace with regular expression
let seleniumElementNotFoundMessage: cstring = "no such element: Unable to locate element:"
#stale element reference: element is not attached to the page document
let seleniumStaleElementMessage: cstring = "(handled) stale element reference: element is not attached to the page document"


#Testing Framework Types
type
  PageElementErrorType* = enum
    notImplemented, staleElement, elementNotFound

type
  SharedElementsData = ref object
    seleniumElements: seq[SeleniumElement]

type
  ExtendedWebDriver* = ref object of RootObj
    wrappedDriver*: SeleniumWebDriver

type
  PageElement* = ref object of RootObj
    internalWrappedElement: SeleniumElement
    sharedElementsData: SharedElementsData
    indexInList*: int
    internalDriver*: ExtendedWebDriver
    parentElement*: PageElement
    selector*: cstring
    selectorType*: SelectorType
    clearTextOnSendKeys*: bool
    isStale*: bool
    staleElementRetryCount*: int
    disableWait*: bool
    waitElementRetryCount*: int
    isListElement*: bool
    name*: cstring

#verboseSelector returns a human readable version of the search pattern
proc verboseSelector(self: PageElement): cstring =
  if self.selector.isNil or self.selector == "":
    self.selector = "selector not set"

  if self.isListElement:
    if self.parentElement.isNil:
      return &"Driver find elements:{self.name} {self.selector} by {self.selectorType} with index: {self.indexInList}"
    else: return &"{self.parentElement.verboseSelector} -> find elements:{self.name} {self.selector} by {self.selectorType} with index: {self.indexInList}"
  else: #self is not a list element:
    if self.parentElement.isNil:
      return &"Driver find element:{self.name} {self.selector} by {self.selectorType}"
    else:
      return &"{self.parentElement.verboseSelector} -> find element:{self.name} {self.selector} by {self.selectorType}"

proc driver*(self: PageElement): ExtendedWebDriver =
  if self.internalDriver.isNil:
    raise Exception.newException(&"Nil driver in proc driver*(self: PageElement) for element: {self.verboseSelector()}")
  result = self.internalDriver

proc `driver=`*(left: PageElement, right: ExtendedWebDriver): void =
  left.internalDriver = right

proc getPageElementErrorType*(errorMessage: cstring):
  PageElementErrorType =

  if $seleniumStaleElementMessage in $errorMessage:
    return PageElementErrorType.staleElement
  if $seleniumElementNotFoundMessage in $errorMessage:
    return PageElementErrorType.elementNotFound
  return PageElementErrorType.notImplemented


proc handlePageElementException(element: PageElement,
                                errorMessage: cstring):
  void =
  let errorType = getPageElementErrorType(errorMessage)
  case errorType:
    of PageElementErrorType.staleElement:
      echo "TODO: handlePageElementException"
    of PageElementErrorType.elementNotFound:
      echo "TODO: handlePageElementException"
    of PageElementErrorType.notImplemented:
      echo "TODO: handlePageElementException"

proc `wrappedElement=`*(left: PageElement, right: SeleniumElement):
  void =
  if left.isListElement:
    left.sharedElementsData.seleniumElements[left.indexInList] = right
  else:
    left.internalWrappedElement = right

#proc wrappedElement*(self: PageElement): Future[SeleniumElement] {.async, gcsafe, raises: [Defect].}
proc wrappedElement*(self: PageElement): Future[SeleniumElement] {.async.} =

  #1 check if wrapped element needs to be initialized/updated
  #2 return apropiate wrapped element depending on if it is a list or not
  #3.1 if not initialized do so
  #3.2 if element has a parent element check and initialize the wrapped element of parent recursively
  #4 return wrappedElement(self)
  #the only exit point is at step 2 to reuse code from the first half of the function

  #step 1 and 2
  if self.isListElement:
    if not self.isStale and not self.sharedElementsData.seleniumElements[self.indexInList].isNil:
      return self.sharedElementsData.seleniumElements[self.indexInList]
  else: #element is not part of a list
    if not self.isStale and not self.internalWrappedElement.isNil:
      return self.internalWrappedElement

  #step 3
    if self.isListElement:
      if self.parentElement.isNil: #is list, no parent
        self.sharedElementsData.seleniumElements = await findSeleniumElements(self.driver.wrappedDriver,
                                                                              self.selector,
                                                                              self.selectorType)
      else: #is list, with parent
        self.sharedElementsData.seleniumElements = await findSeleniumElements(await self.parentElement.wrappedElement,
                                                                              self.selector,
                                                                              self.selectorType)
    else:
      try:
        if self.parentElement.isNil: #not list, no parent
          self.internalWrappedElement = await findSeleniumElement(self.driver.wrappedDriver,
                                                                  self.selector,
                                                                  self.selectorType)
        else: #not list, with parent
          self.internalWrappedElement = await findSeleniumElement(await self.parentElement.wrappedElement,
                                                                  self.selector,
                                                                  self.selectorType)
        if isWebDriverInDebugMode and self.waitElementRetryCount != 0:
          echo "recovered {self.verboseSelector} after {self.waitElementRetryCount} search attemts which took {self.waitElementRetryCount * }"
        self.waitElementRetryCount = 0
      except:
        let errorMessage = getCurrentExceptionMsg()
        let errorType = getPageElementErrorType(errorMessage)
        if errorType == PageElementErrorType.elementNotFound and self.waitElementRetryCount * defaultWaitInterval < defaultWaitForElement:
          self.waitElementRetryCount += 1
          await wait(defaultWaitInterval)
          return await wrappedElement(self)
        else:
          raise ElementNotFoundException.newException(&"pageElement.wrappedElement for {self.name} has trown the following error message:\n{errorMessage}")

  #step 4
  self.isStale = false
  return await wrappedElement(self)


proc newPageElement*(): PageElement =
  let newElement = PageElement()
  newElement.isListElement = false
  newElement.clearTextOnSendKeys = true
  newElement.isListElement = false
  newElement.isStale = true
  newElement.name = ""

  return newElement

proc findElement*(driver: ExtendedWebDriver,
                  selector: cstring,
                  selectorType: SelectorType = SelectorType.css,
                  name: cstring = ""):
  PageElement =

  let newElement = PageElement()
  newElement.internalDriver = driver
  newElement.selector = selector
  newElement.selectorType = selectorType
  newElement.clearTextOnSendKeys = true
  newElement.isListElement = false
  newElement.isStale = true
  newElement.name = name

  return newElement


proc findElement*(root: PageElement,
                  selector: cstring,
                  selectorType: SelectorType = SelectorType.css,
                  name: cstring = ""):
  PageElement =

  let newElement = PageElement()
  newElement.internalDriver = root.driver
  newElement.selector = selector
  newElement.selectorType = selectorType
  newElement.parentElement = root
  newElement.clearTextOnSendKeys = true
  newElement.isListElement = false
  newElement.isStale = true
  newElement.name = name

  return newElement

proc wrapSeleniumElementsInPageElements(prototypeElement: PageElement):
  Future[seq[PageElement]] {.async.} =

  var pageElements: seq[PageElement] = @[]

  for loopIndex, seleniumElement in prototypeElement.sharedElementsData.seleniumElements:
    let newPageElement = newPageElement()

    newPageElement.parentElement = prototypeElement.parentElement
    newPageElement.internalDriver = prototypeElement.internalDriver
    newPageElement.selector = prototypeElement.selector
    newPageElement.selectorType = prototypeElement.selectorType
    newPageElement.isListElement = true
    newPageElement.indexInList = loopIndex
    newPageElement.sharedElementsData = prototypeElement.sharedElementsData
    newPageElement.isStale = false
    newPageElement.name = prototypeElement.name

    pageElements.add(newPageElement)

  return pageElements

proc findElements*(driver: ExtendedWebDriver,
                    selector: cstring,
                    selectorType: SelectorType = SelectorType.css,
                    name: cstring = ""):
  Future[seq[PageElement]] {.async.} =

  var sharedElementsData = SharedElementsData()
  sharedElementsData.seleniumElements = await findSeleniumElements(driver.wrappedDriver, selector, selectorType)

  var elementsPrototype = PageElement()
  elementsPrototype.internalDriver = driver
  elementsPrototype.selectorType = selectorType
  elementsPrototype.selector = selector
  elementsPrototype.sharedElementsData = sharedElementsData
  elementsPrototype.name = name

  return await wrapSeleniumElementsInPageElements(elementsPrototype)


proc findElements*(rootElement: PageElement,
                    selector: cstring,
                    selectorType: SelectorType = SelectorType.css,
                    name: cstring = ""):
  Future[seq[PageElement]] {.async.} =

  var seleniumElements: seq[SeleniumElement] = @[]

  var sharedElementsData = SharedElementsData()
  sharedElementsData.seleniumElements = await findSeleniumElements(await rootElement.wrappedElement, selector, selectorType)

  var elementsPrototype = PageElement()
  elementsPrototype.internalDriver = rootElement.driver
  elementsPrototype.selectorType = selectorType
  elementsPrototype.selector = selector
  elementsPrototype.sharedElementsData = sharedElementsData
  elementsPrototype.parentElement = rootElement
  elementsPrototype.name = name

  return await wrapSeleniumElementsInPageElements(elementsPrototype)

proc click*(element: PageElement):
  Future[void] {.async.} =
  try:
    await element.wrappedElement.click()
    element.staleElementRetryCount = 0
  except:
    let exceptionMessage = getCurrentExceptionMsg()
    #echo exceptionMessage
    let errorType = getPageElementErrorType(exceptionMessage)
    case errorType:

      of PageElementErrorType.elementNotFound:
        raise ElementNotFoundException.newException(&"element not found: {element.verboseSelector}")
      of PageElementErrorType.staleElement:
        element.isStale = true
        if element.staleElementRetryCount < defaultRetryFindElementLimit:
          element.staleElementRetryCount += 1
          await click(element)
        else:
          raise StaleElementReferenceException.newException(&"element {element.verboseSelector} has thrown StaleElementReferenceException")
      of PageElementErrorType.notImplemented:
        raise Exception.newException(&"NotImplementedException in {element.verboseSelector} Click, original error message:\n{exceptionMessage}")

proc sendKeys*(element: PageElement,
                text: cstring):
  Future[void] {.async.} =

  if element.clearTextOnSendKeys:
    await element.wrappedElement.clear()
  await element.wrappedElement.sendKeys(text)

proc clear*(element: PageElement) {.async.} =
  await element.wrappedElement.clear()

proc getTagName*(element: PageElement):
  Future[cstring] {.async.} =
  return await element.wrappedElement.getTagName()

proc getAttribute*(element: PageElement, attributeName: cstring):
  Future[cstring] {.async.} =
  return await (await element.wrappedElement).getAttribute(attributeName)

proc close*(self: ExtendedWebDriver):
  void =
  discard seleniumDriverClose(self.wrappedDriver)

proc text*(self: PageElement): Future[cstring] {.async.} =
  try:
    return await (await self.wrappedElement).getText()
    self.staleElementRetryCount = 0
  except:
    let exceptionMessage = getCurrentExceptionMsg()
    #echo exceptionMessage
    let errorType = getPageElementErrorType(exceptionMessage)
    case errorType:
      of PageElementErrorType.elementNotFound:
        raise ElementNotFoundException.newException(&"element not found: {self.verboseSelector}")
      of PageElementErrorType.staleElement:
        self.isStale = true
        if self.staleElementRetryCount < defaultRetryFindElementLimit:
          self.staleElementRetryCount += 1
          return await text(self)
        else:
          raise StaleElementReferenceException.newException(&"element {self.verboseSelector} has thrown StaleElementReferenceException")
      of PageElementErrorType.notImplemented:
        raise Exception.newException(&"NotImplementedException in {self.verboseSelector} Click, original error message:\n{exceptionMessage}")

proc getCssValue*(self: PageElement, property: cstring): Future[cstring] {.async.} =
  return await (await self.wrappedElement).getCssValue(property)

proc getProperty*(self: PageElement, attribute: cstring): Future[cstring] {.async.} =
  return await (await self.wrappedElement).getProperty(attribute)

proc domParent*(self: PageElement): PageElement =
  return self.findElement("""//parent::*""", SelectorType.xpath)

proc isSelected*(self: PageElement): Future[bool] {.async.} =
  return seleniumIsSelected(await self.wrappedElement)

#--- javascript executor ----

proc executeAsyncScript*(self: ExtendedWebDriver, script: cstring, args: varargs[JsObject]): Future[js] {.async.} =
  return await executeAsyncScript(self.wrappedDriver, script, args)

proc jsClick*(self: PageElement): Future[void] {.async.} =
  discard await executeAsyncScript(self.driver, "var callback = arguments[arguments.length - 1]; arguments[0][0].click(); callback(null);", await self.wrappedElement)
  return

proc jsFocusElement*(self: PageElement): Future[void] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];
  var element = arguments[0][0];

  element.focus();

  callback(null);
  """.cstring

  discard await executeAsyncScript(self.driver, script, await self.wrappedElement)

  return

proc jsSendKeys*(self: PageElement, inputKeys: cstring, pressCtrlKey: bool = false, pressAltKey: bool = false, pressShiftKey: bool = false, pressMetaKey: bool = false): Future[void] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];
  var element = arguments[0][0];
  var str = arguments[0][1];
  var pressCtrlKey = arguments[0][2];
  var pressAltKey = arguments[0][3];
  var pressShiftKey = arguments[0][4];
  var pressMetaKey = arguments[0][5]

  element.focus();

  for (var i = 0; i < str.length; i++) {
    var keyCode = str.charCodeAt(i);
    var keyboardEvent = new KeyboardEvent('keydown', { 'keyCode': keyCode, 'charCode': keyCode, bubbles: true,  ctrlKey: pressCtrlKey, altKey: pressAltKey, shiftKey: pressShiftKey, metaKay: pressMetaKey});
    element.dispatchEvent(keyboardEvent);
    element.value += str[i];
  }
  callback(null);
  """.cstring

  discard await executeAsyncScript(self.driver, script, await self.wrappedElement , inputKeys.toJs, pressCtrlKey.toJs, pressAltKey.toJs, pressShiftKey.toJs, pressMetaKey.toJs)

  return

proc jsSendKeys*(self: PageElement, key: Keys, pressCtrlKey: bool = false, pressAltKey: bool = false, pressShiftKey: bool = false, pressMetaKey: bool = false): Future[void] {.async.} =
  let script = """
  var callback = arguments[arguments.length - 1];
  var element = arguments[0][0];
  var keyCode = parseInt(arguments[0][1]);
  console.log(keyCode);

  var pressCtrlKey = arguments[0][2];
  var pressAltKey = arguments[0][3];
  var pressShiftKey = arguments[0][4];
  var pressMetaKey = arguments[0][5];

  element.focus();
  var keyboardEvent = new KeyboardEvent('keydown', { 'key': keyCode, bubbles: true, ctrlKey: pressCtrlKey, altKey: pressAltKey, shiftKey: pressShiftKey, metaKey: pressMetaKey});
  element.dispatchEvent(keyboardEvent);
  element.value += String.fromCharCode(keyCode);

  callback(null);
  """.cstring

  discard await executeAsyncScript(self.driver, script, await self.wrappedElement , keyCode(key).toJs , pressCtrlKey.toJs, pressAltKey.toJs, pressShiftKey.toJs, pressMetaKey.toJs)

  return

#--- Custom Waits

proc wait(self: PageElement, milliseconds: int, waitInterval: int): Future[PageElement] {.async.} =
  let maxRetryCount = milliseconds div waitInterval
  for i in 0 .. maxRetryCount:
    if self.parentElement.isNil:
      let searchResults = await findElements(self.driver, self.selector, self.selectorType)
      if searchResults.len > 0:
        return self
    else: #has parent element
      let searchResults = await findElements(self.parentElement, self.selector, self.selectorType)
      if searchResults.len > 0:
        return self
    await wait(waitInterval)
  raise ElementNotFoundException.newException(&"{self.verboseSelector} has not been found after waiting for {milliseconds} milliseconds")

proc wait*(self: PageElement, waitDuration: int): Future[PageElement] {.async.} =
  return await wait(self, waitDuration, defaultWaitInterval)

proc wait*(self: PageElement): Future[PageElement] {.async.} =
  return await wait(self, defaultWaitForElement, defaultWaitInterval)

export extended_web_driver_helpers
