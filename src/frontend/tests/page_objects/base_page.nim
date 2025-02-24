import
  ../testing_framework/extended_web_driver, ../testing_framework/test_helpers, async, strutils, lib, strformat, sequtils, sets, macros, os, jsffi, jsconsole, tables

type BasePage* = ref object of RootObj
  internalDriver: ExtendedWebDriver

proc driver*(basePage: BasePage): ExtendedWebDriver =
  if basePage.internalDriver.isNil:
    basePage.internalDriver = test_helpers.driver

  return basePage.internalDriver
