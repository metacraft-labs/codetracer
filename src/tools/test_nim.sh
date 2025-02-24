#!/usr/bin/env bash

# we can use something like that for nim's jenkins
nim c koch
./koch tests --targets:c cat fields