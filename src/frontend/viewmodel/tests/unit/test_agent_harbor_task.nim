## A worktree agent session started from the desktop runs on the user's
## working copy and carries the task the user typed
## (codetracer-pm DeepReview/Agentic-Coding-Integration.md §6.8, §8.1).

import std/unittest

import ../../agent_harbor_task

suite "the working copy a worktree session runs on":

  test "the open project folder, without its trailing slash":
    check harborTaskWorkspace("", "/home/u/proj/", "") == "/home/u/proj"

  test "the user's own folder wins over a project folder showing an agent's worktree":
    check harborTaskWorkspace("/home/u/proj", "/cache/ah/git-worktrees/ah_1_main",
                              "") == "/home/u/proj"

  test "the main process's workspace folder when nothing else names one":
    check harborTaskWorkspace("", "", "/home/u/other/") == "/home/u/other"

  test "none when no folder is open":
    check harborTaskWorkspace("", "", "") == ""
    check harborTaskWorkspace("", "/", "") == ""

suite "the task a prompt carries":

  test "the omnibox's /ai prefix is not part of the task":
    check taskFromAgentPrompt("/ai Make featureValue return 42") ==
      "Make featureValue return 42"

  test "a prompt typed in the Agent Activity box is the task as typed":
    check taskFromAgentPrompt("  Make featureValue return 42 ") ==
      "Make featureValue return 42"

  test "a word starting with /ai is kept":
    check taskFromAgentPrompt("/aim the test at feature.nim") ==
      "/aim the test at feature.nim"

  test "a bare /ai carries no task":
    check taskFromAgentPrompt("/ai") == ""
