//@category QCDX
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import java.io.File;
import java.io.PrintWriter;

public class ExportQcdx extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        File out = new File(a[0]);
        out.mkdirs();
        Listing listing = currentProgram.getListing();
        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager rm = currentProgram.getReferenceManager();

        PrintWriter fw = new PrintWriter(new File(out, "functions.tsv"), "UTF-8");
        fw.println("entry\tsize\tname");
        for (Function f : fm.getFunctions(true)) {
            fw.println(String.format("0x%x\t%d\t%s", f.getEntryPoint().getOffset(),
                    f.getBody().getNumAddresses(), f.getName()));
        }
        fw.close();
        println("functions done");

        PrintWriter dw = new PrintWriter(new File(out, "disasm.txt"), "UTF-8");
        PrintWriter rw = new PrintWriter(new File(out, "refs.tsv"), "UTF-8");
        rw.println("from\tto\ttype\tfunc\tinsn");
        int n = 0;
        for (Instruction ins : listing.getInstructions(true)) {
            Address ad = ins.getAddress();
            Function f = fm.getFunctionContaining(ad);
            if (f != null && ad.equals(f.getEntryPoint())) {
                dw.println("FUNC 0x" + Long.toHexString(ad.getOffset()) + " " + f.getName());
            }
            dw.println(String.format("  %06x  %s", ad.getOffset(), ins.toString()));
            Reference[] refs = ins.getReferencesFrom();
            if (refs != null && refs.length > 0) {
                String fn = (f == null) ? "?" : f.getName();
                for (Reference r : refs) {
                    rw.println(String.format("0x%x\t0x%x\t%s\t%s\t%s", ad.getOffset(),
                            r.getToAddress().getOffset(), r.getReferenceType(), fn, ins.toString()));
                }
            }
            n++;
            if ((n % 200000) == 0) {
                println("insn " + n);
            }
        }
        dw.close();
        rw.close();
        println("disasm done: " + n + " instructions");

        PrintWriter sw = new PrintWriter(new File(out, "strings.tsv"), "UTF-8");
        sw.println("addr\tfunc\tvalue");
        int ns = 0;
        for (Data d : listing.getDefinedData(true)) {
            Object v = d.getValue();
            String s = null;
            if (v instanceof String) {
                s = (String) v;
            } else if (v instanceof String[]) {
                StringBuilder sb = new StringBuilder();
                for (String p : (String[]) v) sb.append(p);
                s = sb.toString();
            }
            if (s == null || s.length() < 3) continue;
            s = s.replace("\t", " ").replace("\n", " ").replace("\r", " ");
            if (s.length() > 300) s = s.substring(0, 300);
            String fn = "(none)";
            ghidra.program.model.symbol.ReferenceIterator rit = rm.getReferencesTo(d.getAddress());
            if (rit.hasNext()) {
                Reference r0 = (Reference) rit.next();
                Function f = fm.getFunctionContaining(r0.getFromAddress());
                if (f != null) fn = f.getName();
            }
            sw.println(String.format("0x%x\t%s\t%s", d.getAddress().getOffset(), fn, s));
            ns++;
        }
        sw.close();
        println("strings done: " + ns);
    }
}

