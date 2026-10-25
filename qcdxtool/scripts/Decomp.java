//@category QCDX
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.File;
import java.io.PrintWriter;

public class Decomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        String outPath = "decomp_out.txt";
        DecompInterface ifc = new DecompInterface();
        ifc.toggleCCode(true);
        ifc.toggleSyntaxTree(true);
        ifc.openProgram(currentProgram);
        PrintWriter pw = new PrintWriter(new File(outPath), "UTF-8");
        for (String s : a) {
            long off = Long.parseLong(s.replace("0x", ""), 16);
            Address addr = toAddr(off);
            Function f = getFunctionAt(addr);
            if (f == null) f = getFunctionContaining(addr);
            if (f == null) {
                pw.println("// no function at " + s);
                continue;
            }
            pw.println("\n//########## " + f.getName() + " @ " + f.getEntryPoint()
                    + "  (" + f.getBody().getNumAddresses() + " bytes)");
            DecompileResults res = ifc.decompileFunction(f, 180, monitor);
            if (!res.decompileCompleted()) {
                pw.println("// decompile failed: " + res.getErrorMessage());
                continue;
            }
            pw.println(res.getDecompiledFunction().getC());
        }
        pw.close();
        ifc.dispose();
        println("written: " + new File(outPath).getAbsolutePath());
    }
}
