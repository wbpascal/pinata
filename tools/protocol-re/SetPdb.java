// Pre-script: load the given PDB with the PDB Universal analyzer (headless, PDB not on a symbol path).
// usage: -preScript SetPdb.java /path/to/Fiesta.pdb        (work item C02: client2017 import)
// @category Export
import ghidra.app.script.GhidraScript;
import ghidra.app.plugin.core.analysis.PdbUniversalAnalyzer;
import java.io.File;

public class SetPdb extends GhidraScript {
    @Override
    public void run() throws Exception {
        PdbUniversalAnalyzer.setPdbFileOption(currentProgram, new File(getScriptArgs()[0]));
    }
}
