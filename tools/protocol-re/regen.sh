#!/bin/bash
# Rebuild every generated doc from re-data/exports.  usage: tools/protocol-re/regen.sh
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd); T=$R/tools/protocol-re; E=$R/re-data/exports; D=$R/docs/protocol
for s in login wm zone account accountlog character gamelog; do python3 -I "$T/extract.py" "$E/$s" > /dev/null; done
python3 "$T/layouts.py" "$E/login" x
python3 "$T/layouts.py" "$E/wm" x
python3 "$T/layouts.py" "$E/zone" x "$R/Files/Server/2016/w00_Zone00/5ZoneServer2.exe"
for s in account accountlog character gamelog; do python3 "$T/layouts.py" "$E/$s" x > /dev/null; done
python3 -I "$T/pdb.py" "$R/Files/Client/2017/Fiesta.pdb" layouts "$D/pdb-layouts.json"
N=$R/Files/Server/NA2016   # 2016 server PDBs (S01): same builds; merged, preferred over the 2017 client PDB
python3 -I "$T/pdb.py" "$N/Zone00/Zone.pdb" layouts2016 "$D/pdb2016-layouts.json" "$N/WorldManager/WorldManager.pdb" \
    "$N/Login/Login.pdb" "$N/Account/Account.pdb" "$N/AccountLog/AccountLog.pdb"
python3 -I "$T/catalog.py" "$E" "$D"
python3 -I "$T/packets.py" "$E" "$D"
python3 -I "$T/errcodes.py" "$E/client" "$R/Files/Client/2016/ressystem" > "$D/client-error-codes.json"
python3 -I "$T/make_dissector.py"
python3 -I "$T/coverage.py" --overview
