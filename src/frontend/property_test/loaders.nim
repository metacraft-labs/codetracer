import std / dom
from std / strformat import fmt

proc debugButton*(stepAction: string): dom.Element =
  document.querySelector(fmt"#{stepAction}-debug")

proc eventRow*(eventIndex: int): dom.Element =
  document.querySelectorAll("td.eventLog-text")[eventIndex]
