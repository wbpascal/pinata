// Headless export: decompiled C per function + strings with xrefs.
// @category Export
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.data.*;
import ghidra.program.model.symbol.*;
import ghidra.program.util.DefinedDataIterator;
import java.io.*;

public class ExportAll extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outDir = getScriptArgs()[0];
        new File(outDir).mkdirs();
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        try (PrintWriter w = new PrintWriter(new FileWriter(outDir + "/decomp.c"))) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                if (monitor.isCancelled()) break;
                DecompileResults r = d.decompileFunction(f, 60, monitor);
                w.println("//==== FUNC " + f.getEntryPoint() + " " + f.getName());
                if (r != null && r.decompileCompleted()) w.println(r.getDecompiledFunction().getC());
                else w.println("// decompile failed");
            }
        }
        try (PrintWriter w = new PrintWriter(new FileWriter(outDir + "/strings.tsv"))) {
            ReferenceManager rm = currentProgram.getReferenceManager();
            for (Data s : currentProgram.getListing().getDefinedData(true)) {
                if (!s.hasStringValue()) continue;
                StringBuilder refs = new StringBuilder();
                for (Reference ref : rm.getReferencesTo(s.getAddress())) {
                    Function f = getFunctionContaining(ref.getFromAddress());
                    refs.append(ref.getFromAddress()).append("@").append(f == null ? "?" : f.getName()).append(",");
                }
                String v = String.valueOf(s.getValue()).replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r");
                w.println(s.getAddress() + "\t" + v + "\t" + refs);
            }
        }
    }
}
