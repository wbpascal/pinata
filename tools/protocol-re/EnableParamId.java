// Pre-script: enable decompiler parameter recovery so thiscall/stack args survive in exports.
// @category Export
import ghidra.app.script.GhidraScript;

public class EnableParamId extends GhidraScript {
    @Override
    public void run() throws Exception {
        setAnalysisOption(currentProgram, "Decompiler Parameter ID", "true");
    }
}
