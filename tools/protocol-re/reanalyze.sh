#!/bin/bash
# Re-import + analyze + export one binary into the persistent project.  usage: reanalyze.sh <name> <path-to-exe>
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
G=${GHIDRA_HEADLESS:-/opt/homebrew/opt/ghidra@12.1.4/libexec/support/analyzeHeadless}
T=$R/tools/protocol-re
mkdir -p "$R/re-data/ghidra" "$R/re-data/exports/$1"
"$G" "$R/re-data/ghidra" "$1" -import "$2" -loader PeLoader -overwrite -scriptPath "$T" \
    -preScript EnableParamId.java -postScript ExportAll.java "$R/re-data/exports/$1" \
    -analysisTimeoutPerFile 7200 > "$R/re-data/exports/$1/ghidra.log" 2>&1
echo "$1 exit $?"
