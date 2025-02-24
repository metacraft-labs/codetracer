import
  sequtils, options, strutils, strformat, sets, macros, jsffi, async, unittest, jsconsole, algorithm, os, # os because `/`
  ../../lib, ../../types,
  /extended_web_driver_helpers

let selenium* {.exportc.} = jsffi.require("selenium-webdriver")
#https://www.selenium.dev/selenium/docs/api/javascript/module/selenium-webdriver/index_exports_WebDriver.html

#TODO: implement selenium errors
#https://www.selenium.dev/selenium/docs/api/javascript/module/selenium-webdriver/lib/error_exports_ElementClickInterceptedError.html
#let seleniumError* {.exportc.} = jsffi.require("selenium-webdriver/lib/error.WebDriverError")

let seleniumLogger* {.exportc.} = jsffi.require("selenium-webdriver/lib/logging")

type
  CSSProperty* = ref object
    property*: cstring
    value*: cstring
    parsed*: JsObject

  # TODO windowByIndex
  SeleniumWebDriver* = ref object of JsObject
    element*: proc(selector: cstring): Future[js]
    elements*: proc(selector: cstring): Future[js]
    getAttribute*: proc(selector: cstring, attribute: cstring): Future[cstring]
    elementIdClick*: proc(id: cstring): Future[void]
    # getText*: proc(selector: cstring): Future[cstring]
    getTitle*: proc: Future[cstring]
    waitForText*: proc(selector: cstring, time: int): Future[void]
    keys*: proc(keys: seq[cstring]): Future[void]
    deleteSession*: proc: Future[void]
    closeWindow*: proc: Future[void]
    setTimeout*: proc(options: js): Future[void]
    close*: proc: Future[void]


  # webdriverio
  SeleniumElement* = ref object of JsObject
    id*: cstring
    error*: js
    waitForExist*: proc(options: js): Future[void]
    click*: proc(options: js = js{}): Future[void]
    getText*: proc: Future[cstring]
    getTagName*: proc: Future[cstring]
    getCssValue*: proc(property: cstring): Future[cstring]
    getProperty*: proc(property: cstring): Future[cstring]
    getAttribute*: proc(attribute: cstring): Future[cstring]
    isExisting*: proc: Future[bool]
    isClickable*: proc: Future[bool]
    isDisplayed*: proc: Future[bool]
    waitForDisplayed*: proc(options: js): Future[void]
    setValue*: proc(input: seq[string], options: js): Future[void]
    # TODO: varargs? currently producing [arg] instead of arg
    sendKeys*: proc(arg: cstring): Future[void]
    #getId*: proc: Future[cstring]
    # selenium
    #text*: cstring


# proc `=`*(leftSide: SeleniumElement,rightSide: Option[SeleniumElement]):
#   SeleniumElement =
#   return leftSide

# selenium type mappings

#proc click*(element: SeleniumElement): Future[void] {.importcpp: "#.click()".}
proc clear*(element: SeleniumElement): Future[void] {.importcpp: "#.clear()".}
#proc sendKeys*(element: SeleniumElement, arg: cstring): Future[void] {.importcpp: "#.sendKeys(#)".}

#// Driver Find Elements

#proc getId*(element: SeleniumElement): Future[cstring] {.importcpp: "#.getId()".}

proc click*(self: Future[SeleniumElement]):
  Future[void] {.async.} =

  let element = await self
  await element.click()

proc clear*(self: Future[SeleniumElement]):
  Future[void] {.async.} =

  let element = await self
  await element.clear()

proc sendKeys*(self: Future[SeleniumElement], text: cstring):
  Future[void] {.async.} =

  let element = await self
  await element.sendKeys(text)

proc getTagName*(self: Future[SeleniumElement]):
  Future[cstring] {.async.} =

  let element = await self
  return await element.getTagName()

proc text*(self: Future[SeleniumElement]):
  Future[cstring] {.async.} =

  let element = await self
  return await element.getText()

proc seleniumFindElementByCss*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.css(#))".}
proc seleniumFindElementsByCss*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.css(#))".}

proc seleniumFindElementById*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.id(#))".}
proc seleniumFindElementsById*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.id(#))".}

proc seleniumFindElementByClassName*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.className(#))".}
proc seleniumFindElementsByClassName*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.Name(#))".}

proc seleniumFindElementByTagName*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.tagName(#))".}
proc seleniumFindElementsByTagName*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.tagName(#))".}

proc seleniumFindElementByXPath*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.xpath(#))".}
proc seleniumFindElementsByXPath*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.xpath(#))".}

proc seleniumFindElementByLinkText*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.linkText(#))".}
proc seleniumFindElementsByLinkText*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.linkText(#))".}

proc seleniumFindElementByPartialLinkText*(driver: SeleniumWebDriver, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.partialLinkText(#))".}
proc seleniumFindElementsByPartialLinkText*(driver: SeleniumWebDriver, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.partialLinkText(#))".}

# Driver functions

proc seleniumDriverClose*(driver: SeleniumWebDriver): Future[void] {.importcpp: "#.findElement(selenium.By.partialLinkText(#))".}

#Element find elements

proc seleniumFindElementByCss*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.css(#))".}
proc seleniumFindElementsByCss*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.css(#))".}

proc seleniumFindElementById*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.id(#))".}
proc seleniumFindElementsById*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.id(#))".}

proc seleniumFindElementByClassName*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.className(#))".}
proc seleniumFindElementsByClassName*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.className(#))".}

proc seleniumFindElementByTagName*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.tagName(#))".}
proc seleniumFindElementsByTagName*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.tagName(#))".}

proc seleniumFindElementByXPath*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.xpath(#))".}
proc seleniumFindElementsByXPath*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.xpath(#))".}

proc seleniumFindElementByLinkText*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.linkText(#))".}
proc seleniumFindElementsByLinkText*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.linkText(#))".}

proc seleniumFindElementByPartialLinkText*(webElement: SeleniumElement, selector: cstring): Future[SeleniumElement] {.importcpp: "#.findElement(selenium.By.partialLinkText(#))".}
proc seleniumFindElementsByPartialLinkText*(webElement: SeleniumElement, selector: cstring): Future[seq[SeleniumElement]] {.importcpp: "#.findElements(selenium.By.partialLinkText(#))".}

proc findSeleniumElement*(driver: SeleniumWebDriver,
                          selector: cstring,
                          selectorType: SelectorType):
  Future[SeleniumElement] =
  case selectorType:
    of SelectorType.css:
      seleniumFindElementByCss(driver, selector)
    of SelectorType.xpath:
      seleniumFindElementByXPath(driver, selector)
    of SelectorType.id:
      seleniumFindElementById(driver, selector)
    of SelectorType.tagName:
      seleniumFindElementByTagName(driver, selector)
    of SelectorType.linkText:
      seleniumFindElementByLinkText(driver, selector)
    of SelectorType.partialLinkText:
      seleniumFindElementByPartialLinkText(driver, selector)

proc findSeleniumElement*(parentElement: SeleniumElement,
                          selector: cstring,
                          selectorType: SelectorType):
  Future[SeleniumElement] =
  case selectorType:
    of SelectorType.css:
      seleniumFindElementByCss(parentElement, selector)
    of SelectorType.xpath:
      seleniumFindElementByXPath(parentElement, selector)
    of SelectorType.id:
      seleniumFindElementById(parentElement, selector)
    of SelectorType.tagName:
      seleniumFindElementByTagName(parentElement, selector)
    of SelectorType.linkText:
      seleniumFindElementByLinkText(parentElement, selector)
    of SelectorType.partialLinkText:
      seleniumFindElementByPartialLinkText(parentElement, selector)

proc findSeleniumElements*(driver: SeleniumWebDriver,
                          selector: cstring,
                          selectorType: SelectorType):
  Future[seq[SeleniumElement]] =
  case selectorType:
    of SelectorType.css:
      seleniumFindElementsByCss(driver, selector)
    of SelectorType.xpath:
      seleniumFindElementsByXPath(driver, selector)
    of SelectorType.id:
      seleniumFindElementsById(driver, selector)
    of SelectorType.tagName:
      seleniumFindElementsByTagName(driver, selector)
    of SelectorType.linkText:
      seleniumFindElementsByLinkText(driver, selector)
    of SelectorType.partialLinkText:
      seleniumFindElementsByPartialLinkText(driver, selector)

proc findSeleniumElements*(parentElement: SeleniumElement,
                          selector: cstring,
                          selectorType: SelectorType):
  Future[seq[SeleniumElement]] =
  case selectorType:
    of SelectorType.css:
      seleniumFindElementsByCss(parentElement, selector)
    of SelectorType.xpath:
      seleniumFindElementsByXPath(parentElement, selector)
    of SelectorType.id:
      seleniumFindElementsById(parentElement, selector)
    of SelectorType.tagName:
      seleniumFindElementsByTagName(parentElement, selector)
    of SelectorType.linkText:
      seleniumFindElementsByLinkText(parentElement, selector)
    of SelectorType.partialLinkText:
      seleniumFindElementsByPartialLinkText(parentElement, selector)

#Element functions

proc seleniumElementSendKeys*(webElement: SeleniumElement, keys: cstring): Future[void] {.importcpp: "#.sendkeys(#)".}

# end of selenium type mappings

proc seleniumIsSelected*(webElement: SeleniumElement): Future[bool] {.importcpp: "#.isSelected()".}

proc executeAsyncScript*(driver: SeleniumWebDriver, script: cstring, args: varargs[JsObject]): Future[JsObject] {.importcpp: "#.executeAsyncScript(#,#)"}

#proc executeAsyncScript*(driver: SeleniumWebDriver, script: cstring): Future[js] {.importcpp: "#.executeAsyncScript(#)"}
