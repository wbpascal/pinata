# Ghidra projects

Ghidra 12.1.4 projects, one per binary (`<name>.gpr` + `<name>.rep/`). The exports in `re-data/exports/<name>/` are
made from them, and the work items read only the exports. A project is needed only to run extra Ghidra scripts
(`analyzeHeadless re-data/ghidra <name> -process <exe> -noanalysis -readOnly -scriptPath tools/protocol-re -postScript …`).

## Tracked vs local

| Project | In git | Rebuild |
|---|---|---|
| `login`, `wm`, `zone`, `account`, `accountlog`, `character`, `gamelog`, `client` | yes (LFS) | `reanalyze.sh` without a PDB, see below |
| `login-pdb`, `wm-pdb`, `zone-pdb`, `account-pdb`, `accountlog-pdb` (S01) | **no**, gitignored (~250 MB) | `reanalyze.sh` with the NA2016 PDB, see below |
| `client2017` (C02) | **no**, gitignored | C02's two-step command, see below |

The exports of every project, the PDB ones included, are tracked, so a missing local project does not block any work
item.

## Rebuild commands (from the repo root)

Requirements: Ghidra 12.1.4 (`/opt/homebrew/opt/ghidra@12.1.4`, or set `GHIDRA_HEADLESS`), OpenJDK 21 (`JAVA_HOME`).
`reanalyze.sh` imports with `-overwrite` and **also rewrites `re-data/exports/<name>/`**. Check the export diff before
committing it.

```bash
S=tools/protocol-re/reanalyze.sh; O=Files/Server/2016; N=Files/Server/NA2016
# 2016 servers with the NA2016 PDBs (S01). Always the unpatched 2016 exes: the NA2016 exes carry private-server patches.
$S login-pdb      $O/Login/3LoginServer2.exe                $N/Login/Login.pdb                  # ~30 s
$S wm-pdb         $O/w00_WorldManager/4WorldManagerServer2.exe $N/WorldManager/WorldManager.pdb
$S account-pdb    "$O/Account/Account Release.exe"          $N/Account/Account.pdb
$S accountlog-pdb "$O/AccountLog/AccountLog Release.exe"    $N/AccountLog/AccountLog.pdb
$S zone-pdb       $O/w00_Zone00/5ZoneServer2.exe            $N/Zone00/Zone.pdb                  # by far the longest
python3 -I tools/protocol-re/pdb_names.py      # then refresh names/<bin>/S01.json and docs/knowledge/S01-renames.tsv

# Tracked projects without a PDB (only if one is missing or broken)
$S zone $O/w00_Zone00/5ZoneServer2.exe          # likewise login, wm, account, accountlog, character, gamelog
```

`client2017` needs `ExportFuncs.java` (`functions.tsv`, used by `pdb_port.py`) as well as `ExportAll.java`. Run it in
two steps, as described in `docs/knowledge/C02.md` §8:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; R=$PWD; T=$R/tools/protocol-re
G=/opt/homebrew/opt/ghidra@12.1.4/libexec/support/analyzeHeadless
$G re-data/ghidra client2017 -import Files/Client/2017/Fiesta.bin -loader PeLoader -overwrite -scriptPath $T \
  -preScript EnableParamId.java -preScript SetPdb.java $R/Files/Client/2017/Fiesta.pdb \
  -postScript ExportFuncs.java $R/re-data/exports/client2017 -analysisTimeoutPerFile 7200 > re-data/exports/client2017/ghidra.log 2>&1
$G re-data/ghidra client2017 -process Fiesta.bin -noanalysis -readOnly -scriptPath $T \
  -postScript ExportAll.java $R/re-data/exports/client2017 > re-data/exports/client2017/export.log 2>&1
```

Since S01, `ExportAll.java` writes qualified function names (`Class::Method`) in the `//==== FUNC` separators. A
re-export of `client2017` therefore changes its separators from `Method` to `Class::Method`. `pdb_port.py` reads only
the addresses from them, so it is not affected.
