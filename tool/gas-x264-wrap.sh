#!/bin/bash
# gas-preprocessor scans the command line for "-arch arm..." to pick the
# comment char; inject it since x264's ASFLAGS don't carry it.
exec perl /Users/rcred/Documents/Projects/quietriot/tool/gas-preprocessor.pl \
    /usr/bin/clang -arch armv7 -miphoneos-version-min=6.1.3 "$@"
