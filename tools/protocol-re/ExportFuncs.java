// Post-script: functions.tsv = entry, body size, full name (with namespace), callee entries in call order.
// Used by work item C02 to match 2016 <-> 2017 client functions by call graph.
// usage: -postScript ExportFuncs.java <outdir>     (also with -process -noanalysis on an existing project)
// @category Export
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class ExportFuncs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outDir = getScriptArgs()[0];
        new File(outDir).mkdirs();
        Listing l = currentProgram.getListing();
        try (PrintWriter w = new PrintWriter(new FileWriter(outDir + "/functions.tsv"))) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                StringBuilder calls = new StringBuilder();
                for (Instruction i : l.getInstructions(f.getBody(), true)) {
                    if (!i.getFlowType().isCall()) continue;
                    for (Reference r : i.getReferencesFrom()) {
                        if (r.getReferenceType().isCall()) calls.append(r.getToAddress()).append(",");
                    }
                }
                w.println(f.getEntryPoint() + "\t" + f.getBody().getNumAddresses() + "\t" + f.getName(true) + "\t" + calls);
            }
        }
    }
}
