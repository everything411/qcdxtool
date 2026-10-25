using System;
using System.Runtime.InteropServices;

// qcdx_edid.cs - drive qcdxkm8380 via DxgkDdiEscape(0x20000100) to load
// C:\Windows\edidoverride.xml and override the EDID of a given display child.
//
//   qcdx_edid.exe --index <1..10> [--clear] [--display "\\.\DISPLAY1"] [--dry]

static class QcdxEdid
{
    const uint ESCAPE_CODE_EDID_OVERRIDE = 0x20000100;
    const int  ESCAPE_BUF_SIZE           = 0x4854;
    const uint CMD_EDID                  = 0x106;
    const uint SUBOP_EDID_OVERRIDE       = 2;
    const int  CMD_OFF                   = 0x08C;
    const int  CMD_LEN_OFF               = 0x088;
    const uint CMD_LEN                   = 0x20;

    const int OPEN_ADAPTER_SIZE  = 80;
    const int CREATE_DEVICE_SIZE = 64;
    const int ESCAPE_ARG_SIZE    = 0x20;

    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromGdiDisplayName(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCreateDevice(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTDestroyDevice(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCCloseAdapter(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTEscape(IntPtr p);

    static int Num(string s)
    {
        s = s.Trim();
        if (s.StartsWith("0x", System.StringComparison.OrdinalIgnoreCase))
            return int.Parse(s.Substring(2), System.Globalization.NumberStyles.HexNumber);
        return int.Parse(s);
    }

    static void W(IntPtr p, int off, uint v) { Marshal.WriteInt32(p, off, unchecked((int)v)); }
    static uint R(IntPtr p, int off) { return unchecked((uint)Marshal.ReadInt32(p, off)); }
    static void W64(IntPtr p, int off, IntPtr v) { Marshal.WriteIntPtr(p, off, v); }
    static void Zero(IntPtr p, int n) { for (int i = 0; i < n; i++) Marshal.WriteByte(p, i, 0); }

    static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.WriteLine("qcdx_edid - Qualcomm Adreno KMD private escape tool");
            Console.WriteLine("");
            Console.WriteLine("  --get <text>        C3 0x20000101 text interface (get:/set:)");
            Console.WriteLine("  --dump <name>       C2 cmd 0x105: write diag dump to C:\\data\\test\\<name>");
            Console.WriteLine("  --c2 <cmd> <idx> <arg>   C2 0x20000100 raw command (decimal)");
            Console.WriteLine("  --clock <idx> <freq>     C1 0x20000002 clock lookup");
            Console.WriteLine("  --index <n> [--clear]    C2 cmd 0x106 sub-op 2: EDID override for display n");
            Console.WriteLine("  --dry               build only, do not send");
            return 0;
        }
        int index = 1;
        bool clear = false, dry = false;
        string display = @"\\.\DISPLAY1";
        bool displayFixed = false;
        bool allowInternal = false;
        bool persistOk = false;
        string getText = null;
        string dumpName = null;
        bool c2Mode = false;
        int c2Cmd = 0, c2Idx = 0, c2Arg = 0;
        bool clockMode = false;
        int clockIndex = 1;
        int clockFreq = 0;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--c2":      c2Mode = true; c2Cmd = Num(args[++i]); c2Idx = Num(args[++i]); c2Arg = Num(args[++i]); break;
                case "--dump":    dumpName = args[++i]; break;
                case "--clock":   clockMode = true; clockIndex = Num(args[++i]); clockFreq = Num(args[++i]); break;
                case "--index":   index = Num(args[++i]); break;
                case "--clear":   clear = true; break;
                case "--dry":     dry = true; break;
                case "--display": display = args[++i]; displayFixed = true; break;
                case "--allow-internal": allowInternal = true; break;
                case "--persist-ok": persistOk = true; break;
                case "--get":     getText = args[++i]; break;
                default:
                    Console.Error.WriteLine("unknown arg: " + args[i]);
                    return 1;
            }
        }
        if (index < 1 || index > 10)
        {
            Console.Error.WriteLine("index must be in 1..10 (driver tests uVar8-1 < 10, so 0 is rejected)");
            return 2;
        }
        IntPtr open = Marshal.AllocHGlobal(OPEN_ADAPTER_SIZE);
        IntPtr create = Marshal.AllocHGlobal(CREATE_DEVICE_SIZE);
        IntPtr esc = Marshal.AllocHGlobal(ESCAPE_ARG_SIZE);
        IntPtr data = Marshal.AllocHGlobal(0x9000);
        try
        {
            // 1. open adapter
            // Device names change across hotplug (\\.\DISPLAY1 may go stale).
            // Unless --display is given, try DISPLAY1..16 and use the first that opens.
            int st = -1;
            uint hAdapter = 0;
            if (displayFixed)
            {
                Zero(open, OPEN_ADAPTER_SIZE);
                char[] name = display.ToCharArray();
                if (name.Length > 31) { Console.Error.WriteLine("display name too long"); return 3; }
                for (int i = 0; i < name.Length; i++) Marshal.WriteInt16(open, i * 2, name[i]);
                st = D3DKMTOpenAdapterFromGdiDisplayName(open);
                if (st != 0) { Console.Error.WriteLine(string.Format("[err] OpenAdapter {0} -> 0x{1:X8}", display, st)); return st; }
                hAdapter = R(open, 0x40);
                Console.WriteLine(string.Format("[ok ] hAdapter = 0x{0:X}  ({1})", hAdapter, display));
            }
            else
            {
                for (int n = 1; n <= 16; n++)
                {
                    string cand = @"\\.\DISPLAY" + n;
                    Zero(open, OPEN_ADAPTER_SIZE);
                    char[] nm = cand.ToCharArray();
                    for (int i = 0; i < nm.Length; i++) Marshal.WriteInt16(open, i * 2, nm[i]);
                    st = D3DKMTOpenAdapterFromGdiDisplayName(open);
                    if (st == 0)
                    {
                        display = cand;
                        hAdapter = R(open, 0x40);
                        Console.WriteLine(string.Format("[ok ] hAdapter = 0x{0:X}  ({1})", hAdapter, cand));
                        break;
                    }
                }
                if (hAdapter == 0)
                {
                    Console.Error.WriteLine("[err] no usable display device (tried DISPLAY1..16). Use --display to pick one.");
                    return 5;
                }
            }

            // 2. create device
            Zero(create, CREATE_DEVICE_SIZE);
            W(create, 0x00, hAdapter);   // union hAdapter/pAdapter (8B)
            W(create, 0x08, 0);          // Flags
            st = D3DKMTCreateDevice(create);
            if (st != 0) { Console.Error.WriteLine(string.Format("[err] CreateDevice -> 0x{0:X8}", st)); return st; }
            uint hDevice = R(create, 0x0C);   // D3DKMT_HANDLE hDevice lives at 0x0C
            Console.WriteLine(string.Format("[ok ] hDevice  = 0x{0:X}", hDevice));            if (hDevice == 0) { Console.Error.WriteLine("[err] hDevice == 0"); return 4; }

            // 3. build escape payload
            Zero(data, ESCAPE_BUF_SIZE);

            // ---- --c2: raw C2 command (0x20000100 command block) ----
            if (c2Mode)
            {
                W(data, 0x00C, 0x20000100);
                W(data, 0x088, 0x100u);
                W(data, 0x08C, (uint)c2Cmd);
                W(data, 0x090, (uint)c2Idx);
                W(data, 0x094, (uint)c2Arg);
                Console.WriteLine(string.Format("[.. ] C2 cmd=0x{0:X} idx={1} arg={2}", c2Cmd, c2Idx, c2Arg));
                Zero(esc, ESCAPE_ARG_SIZE);
                W(esc, 0x00, hAdapter);
                W(esc, 0x04, hDevice);
                W(esc, 0x08, 0);
                W(esc, 0x0C, 0);
                W64(esc, 0x10, data);
                W(esc, 0x18, 0x4854u);
                st = D3DKMTEscape(esc);
                Console.WriteLine(st == 0 ? "[ok ] escape OK" : string.Format("[err] escape 0x{0:X8}", st));
                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                for (int k = 0; k < 0x60; k += 16)
                {
                    sb.Append(string.Format("\n  blk+0x{0:X2}: ", k));
                    for (int j = 0; j < 16; j++) sb.Append(string.Format("{0:x2} ", Marshal.ReadByte(data, 0x8C + k + j)));
                }
                Console.WriteLine("[c2 block]" + sb.ToString());
                Zero(create, CREATE_DEVICE_SIZE); W(create, 0x00, hDevice); D3DKMTDestroyDevice(create);
                Zero(open, OPEN_ADAPTER_SIZE); W(open, 0x00, hAdapter); D3DKMTCCloseAdapter(open);
                return 0;
            }

            // ---- --dump: C2 cmd 0x105 - write a diagnostics dump to C:\data\test\<name> ----
            if (dumpName != null)
            {
                W(data, 0x00C, 0x20000100);
                W(data, 0x088, 0x100u);      // param_2 (> 0x4F)
                W(data, 0x08C, 0x105u);      // cmd
                W(data, 0x090, 0u);          // arguments
                byte[] nb = System.Text.Encoding.ASCII.GetBytes(dumpName);
                for (int i = 0; i < nb.Length && i < 0x60; i++) Marshal.WriteByte(data, 0x098 + i, nb[i]);
                Marshal.WriteByte(data, 0x098 + nb.Length, 0);

                Console.WriteLine(string.Format("[.. ] C2 cmd=0x105 file=\"{0}\"", dumpName));
                Zero(esc, ESCAPE_ARG_SIZE);
                W(esc, 0x00, hAdapter);
                W(esc, 0x04, hDevice);
                W(esc, 0x08, 0);
                W(esc, 0x0C, 0);
                W64(esc, 0x10, data);
                W(esc, 0x18, 0x4854u);
                st = D3DKMTEscape(esc);
                Console.WriteLine(st == 0 ? "[ok ] escape OK" : string.Format("[err] escape 0x{0:X8}", st));
                Console.WriteLine(string.Format("[dump] status @+0xD8 = {0}", R(data, 0xD8)));
                Zero(create, CREATE_DEVICE_SIZE); W(create, 0x00, hDevice); D3DKMTDestroyDevice(create);
                Zero(open, OPEN_ADAPTER_SIZE); W(open, 0x00, hAdapter); D3DKMTCCloseAdapter(open);
                return 0;
            }

            // ---- --clock: C1 clock-tier query (0x20000002) ----
            if (clockMode)            {
                W(data, 0x0C, 0x20000002);
                W(data, 0x88, 8);
                W(data, 0x8C, (uint)clockIndex);
                W(data, 0x90, (uint)clockFreq);
                W(data, 0x94, 8);
                Console.WriteLine(string.Format("[.. ] C1 clock index={0} freq={1}", clockIndex, clockFreq));
                Zero(esc, ESCAPE_ARG_SIZE);
                W(esc, 0x00, hAdapter);
                W(esc, 0x04, hDevice);
                W(esc, 0x08, 0);
                W(esc, 0x0C, 0);
                W64(esc, 0x10, data);
                W(esc, 0x18, 0xA0u);
                st = D3DKMTEscape(esc);
                Console.WriteLine(st == 0 ? "[ok ] escape OK" : string.Format("[err] escape 0x{0:X8}", st));
                Console.WriteLine(string.Format("[clk] +0x98 = {0} (0x{0:X})", R(data, 0x98)));
                Console.WriteLine(string.Format("[clk] +0x9C = {0} (0x{0:X})", R(data, 0x9C)));
                Zero(create, CREATE_DEVICE_SIZE); W(create, 0x00, hDevice); D3DKMTDestroyDevice(create);
                Zero(open, OPEN_ADAPTER_SIZE); W(open, 0x00, hAdapter); D3DKMTCCloseAdapter(open);
                return 0;
            }

            // Gate 1: set keys that persist to disk require an explicit --persist-ok
            // (their setters call FUN_140138458, which writes the config; it survives reboot)
            if (getText != null && getText.StartsWith("set:", System.StringComparison.OrdinalIgnoreCase) && !persistOk)
            {
                string[] persistKeys = { "sharpness", "warmness", "hue", "saturation",
                                         "intensity", "contrast", "pcc", "3dlut" };
                foreach (string pk in persistKeys)
                {
                    if (getText.IndexOf(pk, System.StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        Console.Error.WriteLine("[refuse] \"" + pk + "\" is a persisting set key (written to disk, survives reboot).");
                        Console.Error.WriteLine("         Pass --persist-ok to confirm; write the neutral value 0 right after.");
                        return 7;
                    }
                }
            }

            // Gate 2: writing an internal slot (1/2/3/7) requires --allow-internal
            if (getText != null && getText.StartsWith("set:", System.StringComparison.OrdinalIgnoreCase) && !allowInternal)
            {
                System.Text.RegularExpressions.Match mz =
                    System.Text.RegularExpressions.Regex.Match(getText, @"displayId:(\d+)");
                if (mz.Success)
                {
                    int tgt = int.Parse(mz.Groups[1].Value);
                    if (tgt == 1 || tgt == 2 || tgt == 3 || tgt == 7)
                    {
                        Console.Error.WriteLine(string.Format(
                            "[refuse] displayId:{0} is an internal slot. Writing it may change panel color/link state and persists.", tgt));
                        Console.Error.WriteLine("         Pass --allow-internal to confirm.");
                        return 6;
                    }
                }
            }

            // ---- --get: C3 text interface (0x20000101) ----
            if (getText != null)
            {
                const int TEXT_OFF = 0x090;
                const int CAP_OFF  = 0x088;
                const int LEN_OFF  = 0x08C;
                uint cap = 0x8000;
                // Driver bug: the AuxRead scan window is 8 bytes shorter than the payload, so the
                // tail is never matched. Append 8 filler chars so the last key lands inside.
                string sendText = getText;
                bool needsPad = getText.IndexOf("AuxRead", System.StringComparison.OrdinalIgnoreCase) >= 0
                              || getText.StartsWith("set:", System.StringComparison.OrdinalIgnoreCase);
                if (needsPad && !getText.EndsWith("XXXXXXXX"))
                {
                    sendText = getText + "XXXXXXXX";
                    Console.WriteLine("[pad] set:/AuxRead detected -> appended 8 filler chars");
                }
                byte[] tb = System.Text.Encoding.ASCII.GetBytes(sendText);
                W(data, 0x00C, 0x20000101);
                W(data, CAP_OFF, cap);
                W(data, LEN_OFF, (uint)tb.Length);
                for (int i = 0; i < tb.Length; i++) Marshal.WriteByte(data, TEXT_OFF + i, tb[i]);

                Console.WriteLine(string.Format("[.. ] C3 get: \"{0}\" (len={1}, cap=0x{2:X})", sendText, tb.Length, cap));
                Zero(esc, ESCAPE_ARG_SIZE);
                W(esc, 0x00, hAdapter);
                W(esc, 0x04, hDevice);
                W(esc, 0x08, 0);
                W(esc, 0x0C, 0);
                W64(esc, 0x10, data);
                W(esc, 0x18, 0x9000u);
                st = D3DKMTEscape(esc);
                Console.WriteLine(st == 0 ? "[ok ] escape OK" : string.Format("[err] escape 0x{0:X8}", st));
                uint resLen = R(data, LEN_OFF);
                Console.WriteLine(string.Format("[get] result length = {0}  (cmd status would be @+0x8C)", resLen));
                int n = (int)Math.Min(resLen, cap);
                if (n > 0 && n < 0x9000 - TEXT_OFF)
                {
                    byte[] outp = new byte[n];
                    Marshal.Copy((IntPtr)((long)data + TEXT_OFF), outp, 0, n);
                    System.Text.StringBuilder sb = new System.Text.StringBuilder();
                    foreach (byte x in outp)
                    {
                        if (x == 0) break;
                        sb.Append(x >= 0x20 && x < 0x7F ? (char)x : (x == 0x0A ? '\n' : '.'));
                    }
                    Console.WriteLine("---- result ----");
                    Console.WriteLine(sb.ToString());
                    int hn = Math.Min(n, 128);
                    System.Text.StringBuilder hx = new System.Text.StringBuilder();
                    for (int k = 0; k < hn; k++)
                    {
                        if (k % 16 == 0) hx.Append(string.Format("\n  +0x{0:X3}: ", k));
                        hx.Append(string.Format("{0:x2} ", outp[k]));
                    }
                    Console.WriteLine("[hex first " + hn + " bytes]" + hx.ToString());

                    // AuxRead: print the raw bytes that follow "bufferData:"
                    string plain = sb.ToString();
                    int bi = plain.IndexOf("bufferData:");
                    if (bi >= 0)
                    {
                        int ds = bi + "bufferData:".Length;
                        int dn = n - ds;
                        if (dn > 0)
                        {
                            System.Text.StringBuilder db = new System.Text.StringBuilder();
                            for (int k = 0; k < dn; k++)
                            {
                                if (k % 16 == 0) db.Append(string.Format("\n  +0x{0:X2}: ", k));
                                db.Append(string.Format("{0:x2} ", outp[ds + k]));
                            }
                            Console.WriteLine("[auxdata " + dn + " bytes]" + db.ToString());
                        }
                    }
                }
                Zero(create, CREATE_DEVICE_SIZE); W(create, 0x00, hDevice); D3DKMTDestroyDevice(create);
                Zero(open, OPEN_ADAPTER_SIZE); W(open, 0x00, hAdapter); D3DKMTCCloseAdapter(open);
                return 0;
            }

            W(data, 0x00C, ESCAPE_CODE_EDID_OVERRIDE);
            W(data, CMD_LEN_OFF, CMD_LEN);
            W(data, CMD_OFF + 0x00, CMD_EDID);
            W(data, CMD_OFF + 0x04, SUBOP_EDID_OVERRIDE);
            W(data, CMD_OFF + 0x08, (uint)index);
            W(data, CMD_OFF + 0x0C, clear ? 0u : 1u);

            Console.WriteLine(string.Format("[.. ] cmd=0x106 subop=2 index={0} flag={1}  ({2})",
                index, clear ? 0 : 1, clear ? "clear override" : "load C:\\Windows\\edidoverride.xml"));
            if (dry) { Console.WriteLine("[dry] not sending"); return 0; }

            // 4. escape
            Zero(esc, ESCAPE_ARG_SIZE);
            W(esc, 0x00, hAdapter);          // D3DKMT_ESCAPE.hAdapter
            W(esc, 0x04, hDevice);           // D3DKMT_ESCAPE.hDevice
            W(esc, 0x08, 0);                 // Type = D3DKMT_ESCAPE_DRIVERPRIVATE
            W(esc, 0x0C, 0);                 // Flags
            W64(esc, 0x10, data);            // pPrivateDriverData
            W(esc, 0x18, ESCAPE_BUF_SIZE);   // PrivateDriverDataSize

            st = D3DKMTEscape(esc);
            if (st == 0) Console.WriteLine("[ok ] D3DKMTEscape -> STATUS_SUCCESS");
            else         Console.WriteLine(string.Format("[err] D3DKMTEscape -> 0x{0:X8}", st));

            // the driver writes the command result back to the cmd block at +0x1C
            uint cmdStatus = R(data, CMD_OFF + 0x1C);
            string meaning;
            switch (cmdStatus)
            {
                case 0: meaning = "OK"; break;
                case 2: meaning = "bad param (buffer/len)"; break;
                case 3: meaning = "panel lacks capability bit 0x30000 -> REJECTED"; break;
                case 5: meaning = "file read/parse failed"; break;
                default: meaning = "unknown"; break;
            }
            Console.WriteLine(string.Format("[cmd] status @+0x1C = {0}  ({1})", cmdStatus, meaning));

            // 5. cleanup
            Zero(create, CREATE_DEVICE_SIZE);
            W(create, 0x00, hDevice);
            D3DKMTDestroyDevice(create);
            Zero(open, OPEN_ADAPTER_SIZE);
            W(open, 0x00, hAdapter);
            D3DKMTCCloseAdapter(open);
            return st;
        }
        finally
        {
            Marshal.FreeHGlobal(open); Marshal.FreeHGlobal(create);
            Marshal.FreeHGlobal(esc); Marshal.FreeHGlobal(data);
        }
    }
}























