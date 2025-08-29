#!/usr/bin/env bash
ct start_core $1 1 &
export CODETRACER_CALLER_PID=1
export CODETRACER_TRACE_ID=$1
export CODETRACER_IN_UI_TEST=1
export CODETRACER_TEST=1
export CODETRACER_WRAP_ELECTRON=1
export CODETRACER_START_INDEX=1

ct --remote-debugging-port=9222