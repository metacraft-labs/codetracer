#!/usr/bin/env bash

set -e

./dotnet_build.sh
xvfb-run dotnet run
