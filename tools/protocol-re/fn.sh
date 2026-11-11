#!/bin/bash
# usage: OUT=<export dir> fn.sh <server> <hexaddr>...   print decompiled functions from an ExportAll dump
D=${OUT:?set OUT to the ExportAll output root}/$1/decomp.c; shift
for a in "$@"; do a=$(printf "%08x" $((16#${a#0x}))); awk -v a="$a" '/^\/\/==== FUNC/{p=($3==a)} p' "$D"; done
