// Testbench for mem_subsys, synthesized from circular_queue.ivy via
// ivy_to_rtl + yosys write_verilog.
//
// The op stream is READ FROM A FILE (`+ops=<path>`), not generated from a
// PRNG seed: every edge of the trace is reproducible byte-for-byte and a
// failing trace can be minimized by hand.
//
// Protocol facts (from circular_queue.ivy):
//   * `posedge` is the clock, `rst` a synchronous reset (init values are
//     loaded through a reset mux at the clock edge).
//   * The cpu-side request enable is `cpu_req_en`: the LSQ consumes the
//     presented op on an edge where `cpu_ready & cpu_req_en`, and an edge
//     with `cpu_ready & ~cpu_req_en` is a DO-NOTHING edge -- the port is
//     ignored entirely.  This tb exploits that: while it holds the enable
//     low it presents a SCRAMBLED op (poison store or a load nobody
//     ordered), so a sneak latch shows up as a read-back mismatch or as a
//     response with no outstanding read.
//   * Responses (cpu_valid) are 1-cycle pulses, loads only, in program
//     order.  A response at edge N answers a pre-edge head load, so at the
//     same edge the response is scored BEFORE the accept.
//   * DRAM read is combinational: when mem_rd_en is high the design
//     samples mem_rdata at that same edge (assume [dram_read]).  Word j of
//     the beat lives at bits [64j +: 64] and word address (base|j), where
//     base = mem_rd_addr & ~3.
//   * DRAM write (mem_wr_en) commits a full beat at the edge.  A same-edge
//     read of the same beat is forwarded inside the controller, so the
//     testbench may commit with NBA and serve reads from pre-edge state.
//
// Trace file grammar -- one directive per line, `#` or `//` starts a
// comment, blank lines ignored.  ALL NUMBERS ARE HEX, optional `0x`
// prefix, `_` separators allowed:
//
//   r <addr>          load word <addr>              (aliases: ld, load)
//   w <addr> <data>   store <data> to word <addr>    (aliases: st, store)
//   n [count]         count do-nothing edges,        (aliases: nop, idle)
//                     default 1: cpu_req_en is held
//                     low for `count` ready edges
//                     while a scrambled op is presented
//
// <addr> is a WORD address in 0..NWORDS-1 (0..ff).  A memory op stays
// presented until the DUT accepts it; a bubble is charged only on an edge
// where cpu_ready is high, so bubble placement does not drift with DUT
// timing.  After the file is exhausted the tb sweeps the whole word pool
// with loads and checks every word against the reference memory.
//
// Plusargs:
//   +ops=<path>  trace file (REQUIRED)
//   +corrupt     XOR every DRAM fill beat (checker sanity: must FAIL)
//   +vcd         dump tb.vcd (build with --trace)
//   +verbose     per-edge accept/response log

`timescale 1ns/1ps

module tb;

  localparam int NWORDS = 256;          // lines 0..31 x 8 words

  // trace directive kinds
  localparam int T_LD = 0, T_ST = 1, T_IDLE = 2;
  // what is currently waiting to go out on the port
  localparam int K_MEM = 0, K_IDLE = 1, K_SWEEP = 2, K_NONE = 3;

  localparam int MAX_BUBBLE = 4096;     // cap on one `n <count>` directive

  // ---------------- plusargs ----------------
  string       ops_file;
  bit          corrupt    = 0;
  bit          do_vcd     = 0;
  bit          verbose    = 0;

  // ---------------- DUT hookup ----------------
  logic         clk = 0;
  logic         rst = 1;
  logic [63:0]  cpu_req_addr;
  logic         cpu_req_en;
  logic         cpu_req_wen;
  logic [63:0]  cpu_req_wdata;
  logic [255:0] mem_rdata;

  wire         cpu_valid, cpu_ready;
  wire [63:0]  cpu_resp_addr, cpu_data;
  wire         mem_rd_en, mem_wr_en;
  wire [63:0]  mem_rd_addr, mem_wr_addr;
  wire [255:0] mem_wr_data;

  mem_subsys dut (
    .\posedge      (clk),
    .rst           (rst),
    .cpu_req_addr  (cpu_req_addr),
    .cpu_req_en    (cpu_req_en),
    .cpu_req_wen   (cpu_req_wen),
    .cpu_req_wdata (cpu_req_wdata),
    .cpu_valid     (cpu_valid),
    .cpu_resp_addr (cpu_resp_addr),
    .cpu_data      (cpu_data),
    .cpu_ready     (cpu_ready),
    .mem_rd_en     (mem_rd_en),
    .mem_rd_addr   (mem_rd_addr),
    .mem_wr_en     (mem_wr_en),
    .mem_wr_addr   (mem_wr_addr),
    .mem_wr_data   (mem_wr_data),
    .mem_rdata     (mem_rdata)
  );

  always #5 clk = ~clk;

  // ---------------- trace program ----------------
  int          tr_kind[$];
  logic [63:0] tr_addr[$];
  logic [63:0] tr_data[$];
  int unsigned tr_idx;                   // next directive to hand over
  int unsigned n_tr_mem;                 // memory ops in the file
  int unsigned n_tr_bub;                 // bubbles requested by the file

  string tok[3];

  // split `s` into at most 3 whitespace-separated tokens, stopping at a
  // `#` or `//` comment; returns the token count
  function automatic int split_line(input string s);
    int n = 0;
    int i = 0;
    int len = s.len();
    byte ch;
    for (int k = 0; k < 3; k++) tok[k] = "";
    while (i < len && n < 3) begin
      ch = s.getc(i);
      if (ch == "#") break;
      if (ch == "/" && i + 1 < len && s.getc(i+1) == "/") break;
      if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") begin
        i++;
      end else begin
        automatic int start = i;
        while (i < len) begin
          ch = s.getc(i);
          if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "#")
            break;
          if (ch == "/" && i + 1 < len && s.getc(i+1) == "/") break;
          i++;
        end
        tok[n] = s.substr(start, i-1);
        n++;
      end
    end
    return n;
  endfunction

  // hex token -> value; 0 on a malformed token.  Note: verilator does not
  // short-circuit `&&` around a call with an output argument, so every
  // parse_hex call below stands alone in its own `if`.
  function automatic bit parse_hex(input string s, output logic [63:0] v);
    string t = s;
    v = 64'h0;
    if (t.len() == 0) return 1'b0;
    if (t.len() > 2) begin
      if (t.substr(0,1) == "0x" || t.substr(0,1) == "0X")
        t = t.substr(2, t.len()-1);
    end
    if (t.len() == 0) return 1'b0;
    for (int i = 0; i < t.len(); i++) begin
      automatic byte ch = t.getc(i);
      if (ch == "_") continue;
      if      (ch >= "0" && ch <= "9") v = (v << 4) | (64'(ch) - 64'("0"));
      else if (ch >= "a" && ch <= "f") v = (v << 4) | (64'(ch) - 64'("a") + 64'd10);
      else if (ch >= "A" && ch <= "F") v = (v << 4) | (64'(ch) - 64'("A") + 64'd10);
      else return 1'b0;
    end
    return 1'b1;
  endfunction

  task automatic load_trace(input string path);
    int fd;
    int nt;
    int lineno = 0;
    string line;
    string kind;
    logic [63:0] a, d, cnt;

    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open ops file '%s'", path);

    while ($fgets(line, fd) > 0) begin
      lineno++;
      nt = split_line(line);
      if (nt == 0) continue;                       // blank / comment
      kind = tok[0].tolower();

      if (kind == "r" || kind == "ld" || kind == "load") begin
        if (nt < 2) $fatal(1, "%s:%0d: load needs an address", path, lineno);
        if (!parse_hex(tok[1], a))
          $fatal(1, "%s:%0d: bad address '%s'", path, lineno, tok[1]);
        if (a >= NWORDS)
          $fatal(1, "%s:%0d: address %h outside 0..%h", path, lineno, a, NWORDS-1);
        tr_kind.push_back(T_LD);
        tr_addr.push_back(a);
        tr_data.push_back(64'h0);
        n_tr_mem++;

      end else if (kind == "w" || kind == "st" || kind == "store") begin
        if (nt < 3) $fatal(1, "%s:%0d: store needs an address and data", path, lineno);
        if (!parse_hex(tok[1], a))
          $fatal(1, "%s:%0d: bad address '%s'", path, lineno, tok[1]);
        if (!parse_hex(tok[2], d))
          $fatal(1, "%s:%0d: bad data '%s'", path, lineno, tok[2]);
        if (a >= NWORDS)
          $fatal(1, "%s:%0d: address %h outside 0..%h", path, lineno, a, NWORDS-1);
        tr_kind.push_back(T_ST);
        tr_addr.push_back(a);
        tr_data.push_back(d);
        n_tr_mem++;

      end else if (kind == "n" || kind == "nop" || kind == "idle") begin
        cnt = 64'h1;
        if (nt >= 2) begin
          if (!parse_hex(tok[1], cnt))
            $fatal(1, "%s:%0d: bad bubble count '%s'", path, lineno, tok[1]);
        end
        if (cnt == 0 || cnt > MAX_BUBBLE)
          $fatal(1, "%s:%0d: bubble count %h outside 1..%h",
                 path, lineno, cnt, MAX_BUBBLE);
        for (int k = 0; k < int'(cnt); k++) begin
          tr_kind.push_back(T_IDLE);
          tr_addr.push_back(64'h0);
          tr_data.push_back(64'h0);
        end
        n_tr_bub += int'(cnt);

      end else begin
        $fatal(1, "%s:%0d: unknown directive '%s'", path, lineno, tok[0]);
      end
    end
    $fclose(fd);

    if (tr_kind.size() == 0) $fatal(1, "ops file '%s' has no operations", path);
  endtask

  // ---------------- memories ----------------
  function automatic logic [63:0] init_word(input int unsigned i);
    return (64'(i) + 64'h1) * 64'h9E3779B97F4A7C15;
  endfunction

  logic [63:0] dram    [0:NWORDS-1];
  logic [63:0] ref_mem [0:NWORDS-1];

  // ---------------- combinational DRAM read ----------------
  always_comb begin
    mem_rdata = '0;
    if (mem_rd_en) begin
      automatic int unsigned base = int'(mem_rd_addr) & ~32'h3;
      for (int j = 0; j < 4; j++) begin
        automatic logic [63:0] w = dram[(base | j) & (NWORDS-1)];
        if (corrupt) w ^= 64'h1;
        mem_rdata[64*j +: 64] = w;
      end
    end
  end

  // ---------------- scoreboard state ----------------
  logic [63:0] exp_addr_q[$];
  logic [63:0] exp_data_q[$];

  int unsigned n_acc, n_rd, n_wr, n_resp, n_fill, n_wb;
  int unsigned n_idle;                   // ready & ~req_en edges: do nothing
  int unsigned n_bub;                    // bubbles actually charged
  int unsigned n_scr_st, n_scr_ld;       // scrambled ops presented while low
  int unsigned scr_ctr;                  // deterministic poison generator
  int unsigned sweep_idx;                // final read-back sweep position
  int unsigned n_sweep;
  int unsigned cycles;
  int unsigned errors;

  // what the port carries at the NEXT edge (driven with NBA below)
  logic [63:0] cur_addr, cur_wdata;
  logic        cur_wen;

  // the op waiting to be accepted
  logic [63:0] pend_addr, pend_wdata;
  logic        pend_wen;
  int unsigned pend_kind;

  task automatic drive(input logic [63:0] a, input logic w,
                       input logic [63:0] d, input logic en);
    cur_addr  = a;  cur_wen = w;  cur_wdata = d;
    cpu_req_addr  <= a;
    cpu_req_wen   <= w;
    cpu_req_wdata <= d;
    cpu_req_en    <= en;
  endtask

  // take the next directive from the trace, then the read-back sweep
  task automatic fetch_op();
    if (tr_idx < tr_kind.size()) begin
      pend_addr  = tr_addr[tr_idx];
      pend_wdata = tr_data[tr_idx];
      pend_wen   = (tr_kind[tr_idx] == T_ST);
      pend_kind  = (tr_kind[tr_idx] == T_IDLE) ? K_IDLE : K_MEM;
      tr_idx++;
    end else if (sweep_idx < n_sweep) begin
      pend_addr  = 64'(sweep_idx);
      pend_wen   = 1'b0;
      pend_wdata = 64'h0;
      sweep_idx++;
      pend_kind  = K_SWEEP;
    end else begin
      pend_kind  = K_NONE;               // nothing left: hold the enable low
    end
  endtask

  // present the pending op, or -- on a do-nothing edge -- a scrambled one
  task automatic present();
    if (pend_kind == K_MEM || pend_kind == K_SWEEP) begin
      drive(pend_addr, pend_wen, pend_wdata, 1'b1);
    end else begin
      automatic logic [63:0] mix = (64'(scr_ctr) + 64'h1) * 64'h9E3779B97F4A7C15;
      automatic logic [63:0] sa  = mix % NWORDS;
      automatic logic        sw  = scr_ctr[0];
      scr_ctr++;
      if (sw) n_scr_st++; else n_scr_ld++;
      drive(sa, sw, 64'hDEADBEEFDEADBEEF ^ sa, 1'b0);
    end
  endtask

  task automatic fail(input string msg);
    errors++;
    $display("[%0t] FAIL: %s", $time, msg);
    report(0);
    $finish;
  endtask

  task automatic report(input bit pass);
    $display("---- trace stats (ops=%0s: %0d mem ops, %0d bubbles%0s) ----",
             ops_file, n_tr_mem, n_tr_bub, corrupt ? " CORRUPT" : "");
    $display("  cycles         : %0d", cycles);
    $display("  accepted ops   : %0d  (reads %0d, writes %0d)", n_acc, n_rd, n_wr);
    $display("  read-back sweep: %0d words", n_sweep);
    $display("  do-nothing edges: %0d  (%0d from the file; scrambled st %0d, ld %0d)",
             n_idle, n_bub, n_scr_st, n_scr_ld);
    $display("  cpu responses  : %0d", n_resp);
    $display("  dram fills     : %0d", n_fill);
    $display("  dram writebacks: %0d", n_wb);
    if (pass) $display("PASS");
    else      $display("FAIL (%0d errors)", errors);
  endtask

  // ---------------- clocked scoreboard / driver ----------------
  always @(posedge clk) begin
    if (!rst) begin
      cycles++;

      // 1. score a response (answers a pre-edge head load)
      if (cpu_valid) begin
        if (exp_addr_q.size() == 0)
          fail("cpu_valid with no outstanding read (sneak accept?)");
        else begin
          automatic logic [63:0] ea = exp_addr_q.pop_front();
          automatic logic [63:0] ed = exp_data_q.pop_front();
          n_resp++;
          if (verbose)
            $display("[%0t] c%0d RESP  a=%h d=%h (exp %h)",
                     $time, cycles, cpu_resp_addr, cpu_data, ed);
          if (cpu_resp_addr !== ea)
            fail($sformatf("resp addr %h, expected %h", cpu_resp_addr, ea));
          if (cpu_data !== ed)
            fail($sformatf("resp data %h @ addr %h, expected %h",
                           cpu_data, cpu_resp_addr, ed));
        end
      end

      // 2. score the accept, or count the do-nothing edge
      if (cpu_ready && cpu_req_en) begin
        n_acc++;
        if (verbose)
          $display("[%0t] c%0d ACC#%0d %s a=%h d=%h", $time, cycles, n_acc,
                   cur_wen ? "W" : "R", cur_addr,
                   cur_wen ? cur_wdata : ref_mem[int'(cur_addr)]);
        if (cur_wen) begin
          ref_mem[int'(cur_addr)] = cur_wdata;
          n_wr++;
        end else begin
          exp_addr_q.push_back(cur_addr);
          exp_data_q.push_back(ref_mem[int'(cur_addr)]);
          n_rd++;
        end
        fetch_op();
      end else if (cpu_ready && !cpu_req_en) begin
        n_idle++;                        // the port is ignored: nothing scored
        if (pend_kind == K_IDLE) begin   // a bubble from the file is spent
          n_bub++;
          fetch_op();
        end
      end

      // 3. commit a DRAM writeback (NBA: reads see pre-edge state)
      if (mem_wr_en) begin
        automatic int unsigned base = int'(mem_wr_addr) & ~32'h3;
        if (base >= NWORDS)
          fail($sformatf("writeback outside pool: %h", mem_wr_addr));
        for (int j = 0; j < 4; j++)
          dram[base | j] <= mem_wr_data[64*j +: 64];
        n_wb++;
      end

      // 4. count fills, check bounds
      if (mem_rd_en) begin
        if ((int'(mem_rd_addr) & ~32'h3) >= NWORDS)
          fail($sformatf("fill outside pool: %h", mem_rd_addr));
        n_fill++;
      end

      // 5. re-present for the next edge
      present();

      // 6. done?  everything accepted, every read answered
      if (pend_kind == K_NONE && exp_addr_q.size() == 0 &&
          n_acc >= n_tr_mem + n_sweep) begin
        // non-vacuity: the trace must actually have exercised the machine
        if (n_resp == 0)              fail("vacuous: no responses");
        if (n_fill == 0)              fail("vacuous: no dram fills");
        if (n_wr > 0 && n_wb == 0)    fail("vacuous: dirty lines never written back");
        if (n_bub != n_tr_bub)        fail($sformatf(
              "%0d of %0d requested bubbles charged", n_bub, n_tr_bub));
        if (n_resp != n_rd)           fail("reads left unanswered");
        report(1);
        $finish;
      end

      // 7. watchdog
      if (cycles > 200000 + 100 * (n_tr_mem + n_tr_bub + n_sweep))
        fail("watchdog: no forward progress");
    end
  end

  // ---------------- init / reset ----------------
  initial begin
    if (!$value$plusargs("ops=%s", ops_file))
      $fatal(1, "+ops=<file> is required (file of memory operations)");
    if ($test$plusargs("corrupt")) corrupt  = 1;
    if ($test$plusargs("vcd"))     do_vcd   = 1;
    if ($test$plusargs("verbose")) verbose  = 1;

    if (do_vcd) begin
      $dumpfile("tb.vcd");
      $dumpvars(0, tb);
    end

    load_trace(ops_file);

    for (int i = 0; i < NWORDS; i++) begin
      dram[i]    = init_word(i);
      ref_mem[i] = init_word(i);
    end
    n_sweep = NWORDS;

    fetch_op();
    present();                 // legal op (or a low enable) before reset ends
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 0;
  end

endmodule
