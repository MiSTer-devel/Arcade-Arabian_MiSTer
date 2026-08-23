//============================================================================
//
//  Arabian Main CPU Board
//  Based on MAME arabian.cpp by Dan Boris.
//  The video timing, VRAM and blitter blocks are still the kangaroo.cpp implementation
//  by Ville Laitinen and Aaron Giles, pending their port.
//
//============================================================================

module Arabian_CPU
(
    input         reset,
    input         clk_12m,           // 12 MHz master clock (MAIN_OSC, matches real XTAL)

    // Video outputs — 8-bit, straight from the colour-output equations
    output  [7:0] video_r, video_g, video_b,
    output        video_hsync, video_vsync,
    output        video_hblank, video_vblank,
    output        ce_pix,

    // Inputs read directly by the Z80
    input   [7:0] dsw1,             // SW1  at $C200
    input   [2:0] in0,              // $C000: b0 coin1, b1 coin2, b2 service (all active high)
    // Everything else is scanned by the MB8841 through its K port, six 4-bit banks.
    // COM0 {aux-s, start2, start1, 1} · COM1/COM3 {down,up,left,right} · COM2/COM4 {0,0,0,button}
    // COM3/COM4 are the cocktail player-2 set · COM5 is SW2.
    input   [3:0] com0, com1, com2, com3, com4, com5,

    // AY-3-8910, driven directly over Z80 I/O space (no sound CPU on this board)
    output        ay_addr_wr,       // OUT to $C800: register select
    output        ay_data_wr,       // OUT to $CA00: register data
    output  [7:0] ay_din,
    // AY port A = video control, port B = MCU /IREQ, /SRES and coin counters.
    // Consumed by the MCU block and the palette/compositing stage.
    input   [7:0] ay_ioa,
    input   [7:0] ay_iob,

    // Blitter GFX ROM — 32KB, index 2. Blitter-only; not visible in CPU address space.
    input         gfx_cs_i,
    // Main program ROMs — 4 x 8KB, index 0
    input         rom0_cs_i, rom1_cs_i, rom2_cs_i, rom3_cs_i,
    input  [24:0] ioctl_addr,
    input   [7:0] ioctl_data,
    input         ioctl_wr,

    // AY port B drives the MCU's /IREQ and /SRES
    input         mcurom_wr,      // ioctl_wr for index 6 (MB8841 program, 2KB)

    input         pause,

    // Hiscore interface. Borrows the MCU's shared-RAM port; hiscore.v pauses the CPU (and
    // therefore the MCU) before asserting hs_access, so the port is free while it is high.
    input         hs_access,
    input  [15:0] hs_address,
    input   [7:0] hs_data_in,
    output  [7:0] hs_data_out,
    input         hs_write
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

// Generate clock enables from the 12 MHz master (MAIN_OSC, arabian.cpp)
// cen_6m = 12/2   = 6 MHz (pixel clock — provisional, see Video Timing)
// cen_3m = 12/4   = 3 MHz (Z80,     MAIN_OSC/4)
// cen_2m = 12/6   = 2 MHz (MB8841 pin clock, MAIN_OSC/3/2)
reg [1:0] div = 2'd0;
always_ff @(posedge clk_12m) begin
    div <= div + 2'd1;
end
wire cen_6m = (div[0] == 1'b0);      // Every 2nd clock
wire cen_3m = (div == 2'd0);         // Every 4th clock

reg [2:0] div6 = 3'd0;
always_ff @(posedge clk_12m) begin
    div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
end
wire cen_2m = (div6 == 3'd0);        // Every 6th clock

assign ce_pix = cen_6m;

// Asserted while the DMA blitter owns the bitmap. arabian.cpp performs the whole blit
// inside the $E006 write, so software may issue the next one a handful of instructions
// later; on the board the DMA holds the bus for the same span. Holding the Z80 makes the
// blit atomic from software's point of view and removes the whole class of dropped-trigger
// bugs (Kangaroo BLITQUEUE-2026-08-21, the invisible gloves) rather than queueing around it.
// Affordable here at 4 clocks per 4-pixel group (~1 clk/px); Kangaroo's was ~6 clk/px.
wire blit_active_w;

//------------------------------------------------------------ CPU -------------------------------------------------------------//

// Main CPU — Zilog Z80 (T80s soft core)
wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) main_cpu
(
    .RESET_n(reset),
    .CLK(clk_12m),
    .CEN(cen_3m & ~pause & ~blit_active_w), // DMA holds the bus; see the blitter
    .INT_n(n_irq),
    .NMI_n(n_nmi),
    .BUSRQ_n(1'b1),
    .M1_n(n_m1),
    .MREQ_n(n_mreq),
    .IORQ_n(n_iorq),
    .RD_n(n_rd),
    .WR_n(n_wr),
    .RFSH_n(n_rfsh),
    .A(cpu_A),
    .DI(cpu_Din),
    .DO(cpu_Dout)
);

//------------------------------------------------------ Address Decoding ------------------------------------------------------//

// Active-low signals for memory regions
wire mem_access = ~n_mreq & n_rfsh;

// Program ROM: 0x0000-0x7FFF (read only), flat 32KB
wire cs_any_rom = mem_access & ~cpu_A[15];

// Bitmap RAM: $8000-$BFFF, write only from the CPU's side
wire cs_videoram = mem_access & (cpu_A[15:14] == 2'b10);          // $8000-$BFFF

// Coin/service inputs: $C000, mirror $01FF
wire cs_in0 = mem_access & (cpu_A[15:9] == 7'b1100000);           // $C000-$C1FF

// SW1: $C200, mirror $01FF
wire cs_dsw1 = mem_access & (cpu_A[15:9] == 7'b1100001);          // $C200-$C3FF

// Shared MB8841 RAM: $D000-$D7FF, mirror $0800. This is also the Z80's only work RAM.
wire cs_customram = mem_access & (cpu_A[15:12] == 4'hD);          // $D000-$DFFF

// Blitter registers: $E000-$E006, mirror $0FF8 -> A15-A12 = 1110, register = A[2:0]
wire cs_blitter = mem_access & (cpu_A[15:12] == 4'hE);            // $E000-$EFFF


// AY-3-8910 lives in I/O space, not memory space. The game issues
//   ld bc,$C800 / out (c),d / ld b,$CA / out (c),e
// so the full 16-bit address is on the bus; mirror $01FF means A15-A9 decode.
// n_m1 qualification keeps interrupt acknowledge (IORQ+M1) out of the decode.
wire io_write = ~n_iorq & n_m1 & ~n_wr;
assign ay_addr_wr = io_write & (cpu_A[15:9] == 7'b1100100);   // $C800-$C9FF
assign ay_data_wr = io_write & (cpu_A[15:9] == 7'b1100101);   // $CA00-$CBFF
assign ay_din     = cpu_Dout;

//--------------------------------------------------------- CPU Data Mux -------------------------------------------------------//

wire [7:0] rom_D;
wire [7:0] customram_D;

wire [7:0] cpu_Din =
    cs_any_rom              ? rom_D :
    (cs_customram & ~n_rd)  ? customram_D :
    cs_dsw1                 ? dsw1 :
    cs_in0                  ? {5'b00000, in0} :
    8'hFF;

//-------------------------------------------------------- Program ROMs --------------------------------------------------------//

wire [7:0] rom0_D, rom1_D, rom2_D, rom3_D;

assign rom_D = (cpu_A[14:13] == 2'd0) ? rom0_D :
               (cpu_A[14:13] == 2'd1) ? rom1_D :
               (cpu_A[14:13] == 2'd2) ? rom2_D :
                                        rom3_D;

eprom_8k rom0 (.ADDR(cpu_A[12:0]), .CLK(clk_12m), .DATA(rom0_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data),
               .CS_DL(rom0_cs_i), .WR(ioctl_wr));
eprom_8k rom1 (.ADDR(cpu_A[12:0]), .CLK(clk_12m), .DATA(rom1_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data),
               .CS_DL(rom1_cs_i), .WR(ioctl_wr));
eprom_8k rom2 (.ADDR(cpu_A[12:0]), .CLK(clk_12m), .DATA(rom2_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data),
               .CS_DL(rom2_cs_i), .WR(ioctl_wr));
eprom_8k rom3 (.ADDR(cpu_A[12:0]), .CLK(clk_12m), .DATA(rom3_D),
               .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data),
               .CS_DL(rom3_cs_i), .WR(ioctl_wr));

//------------------------------------------------------------ RAM ------------------------------------------------------------//

// Shared MB8841 RAM ($D000-$D7FF, 2KB) is instantiated in the MB8841 MCU section below,
// after the MCU-side port wires it needs.

// Score data lives in the shared RAM ($D384 length 0x3C, $D3BD length 1), so hiscore reads
// it back off the MCU's port -- see the customram instance in the MB8841 section.

//----------------------------------------------------- Blitter Registers ------------------------------------------------------//

// arabian.cpp blitter_w: $E000-$E006, mirror $0FF8
//   0 = plane / BSEL mask   1,2 = source ROM address (lo,hi)   3 = destination Y
//   4 = destination X (<<2) 5 = size Y                         6 = size X, and writing it starts the blit
reg [7:0] blit_reg [0:7];
integer br_i;
initial begin
    for (br_i = 0; br_i < 8; br_i = br_i + 1)
        blit_reg[br_i] = 8'd0;
end

wire cs_blit_wr = cs_blitter & ~n_wr;
reg  cs_blit_wr_d = 1'b0;
reg  blitter_start = 1'b0;

// Edge-detected so one Z80 write produces exactly one register update and one start pulse,
// however many master clocks the write strobe spans.
always_ff @(posedge clk_12m) begin
    cs_blit_wr_d  <= cs_blit_wr;
    blitter_start <= 1'b0;
    if (cs_blit_wr & ~cs_blit_wr_d) begin
        blit_reg[cpu_A[2:0]] <= cpu_Dout;
        if (cpu_A[2:0] == 3'd6) blitter_start <= 1'b1;
    end
end

// NMI is not connected on this board (arabian.cpp memory map header).
wire n_nmi = 1'b1;

//-------------------------------------------------------- MB8841 MCU ---------------------------------------------------------//
// The SUN 8212 (an MB8841) is a shared-RAM coprocessor, not a protection oracle, and the
// game cannot run without it: every joystick, button, start and SW2 bit reaches the Z80
// only through this scan. Wiring mirrors arabian.cpp:
//   O port + P[2:0]        -> shared RAM address A0-A10        (mcu_port_o_w / mcu_port_p_w)
//   R0.1 low               -> write 0xF0|R3 to that address    (mcu_port_r0_w)
//   R0.0 low               -> K reads the low nibble of RAM    (mcu_port_k_r)
//   R0.0 high              -> K reads COM[i], i = lowest clear bit of {R2[1:0],R1}
//   R0.3                   -> flip screen                      (mcu_port_r0_w)
//   R port reads           -> the output latch, R0 with bit2 forced high ("RAM mode")
//   AY port B b5 -> /IREQ, b4 -> /SRES                         (ay8910_portb_w)
// There is no protection PROM on this board and the MCU does not drive the Z80's NMI.

// timer /32 prescaler (MAME TIMER_PRESCALE=32) lives INSIDE the mb88.sv wrapper
// (generated from `ena`, no external ena_timer port anymore — see mb88.sv header).
// `ena` is one MB88 MACHINE CYCLE, not one instruction: verilator/mb88_testsuite
// (in the PolePosition tree) diffs mb88_core against MAME and shows 1 ce for 1-cycle
// opcodes and 2 ce for the 19 two-cycle ones (3D/3E/3F/60-67/68-6F), 0 cycle failures.
// MAME converts pin clocks at (clocks+5)/6 (mb88xx.h:126). Arabian clocks the MB8841 at
// MAIN_OSC/3/2 = 2 MHz PIN rate (arabian.cpp), so machine cycles are 2 MHz / 6 = 333.33 kHz.
// cen_2m is the PIN rate; feeding it straight to `ena` would run the MCU -- and its timer
// -- 6x fast. Same rule as PolePosition's HW-confirmed MCU-DIV6 and Kangaroo's 2.5 MHz / 6.
localparam int MCU_CEN_DIV = 6;
reg [2:0] mcu_div_cnt = 3'd0;
always @(posedge clk_12m)
    if (cen_2m) mcu_div_cnt <= (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1) ? 3'd0 : mcu_div_cnt + 3'd1;
wire mcu_ena = cen_2m & ~pause & (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1);

// /SRES. The AY's registers come out of reset at 0, so the MCU stays held until the game
// writes AY register 15 — same as the real board.
wire mcu_reset_n = reset & ay_iob[4];

wire [10:0] mcu_rom_addr;
wire  [7:0] mcu_rom_q;
wire  [3:0] mcu_ol, mcu_oh, mcu_p;
wire  [7:0] mcu_o = {mcu_oh, mcu_ol};
wire  [3:0] r0_out, r1_out, r2_out, r3_out;

//--- shared MB8841 RAM ($D000-$D7FF), port A = Z80, port B = MCU ---
wire [10:0] mcu_ram_addr = {mcu_p[2:0], mcu_o};
wire  [7:0] mcu_ram_din  = {4'hF, r3_out};
wire  [7:0] mcu_ram_q;
// R0.1 is the RAM write strobe and is level-driven, as on the board. r_out resets to
// R0=0xF so it is inactive out of reset; qualified with mcu_reset_n regardless.
wire        mcu_ram_we   = mcu_reset_n & ~r0_out[1];

// Port B is shared between the MB8841 and the hiscore block. hs_access only rises while
// hiscore.v has the CPU paused, so the MCU is frozen and cannot be mid-transaction.
wire [10:0] ram_b_addr = hs_access ? hs_address[10:0] : mcu_ram_addr;
wire  [7:0] ram_b_din  = hs_access ? hs_data_in       : mcu_ram_din;
wire        ram_b_we   = hs_access ? hs_write         : mcu_ram_we;

dpram_dc #(.widthad_a(11)) customram
(
    .clock_a(clk_12m),
    .wren_a(cs_customram & ~n_wr),
    .address_a(cpu_A[10:0]),
    .data_a(cpu_Dout),
    .q_a(customram_D),

    .clock_b(clk_12m),
    .wren_b(ram_b_we),
    .address_b(ram_b_addr),
    .data_b(ram_b_din),
    .q_b(mcu_ram_q)
);

assign hs_data_out = mcu_ram_q;

//--- K port: shared RAM low nibble, or one of six input banks ---
// sel = {R2[1:0], R1}; the lowest clear bit selects its bank, none clear reads 0xF.
wire [5:0] com_sel = {r2_out[1:0], r1_out};
wire [3:0] com_val = ~com_sel[0] ? com0 :
                     ~com_sel[1] ? com1 :
                     ~com_sel[2] ? com2 :
                     ~com_sel[3] ? com3 :
                     ~com_sel[4] ? com4 :
                     ~com_sel[5] ? com5 : 4'hF;
// The RAM read is registered, but the MCU advances only every 36 master clocks while the
// dpram settles in 2 — the address is stable for an entire machine cycle before K is sampled.
wire [3:0] mcu_k = ~r0_out[0] ? mcu_ram_q[3:0] : com_val;

//--- flip screen ---
// MAME latches this only when the MCU writes R0. r_out resets to R0=0xF, so sampling R0.3
// continuously would report "flipped" before the first write; latch it on an R0 change.
reg [3:0] r0_out_d   = 4'hF;
reg       flip_screen = 1'b0;
always_ff @(posedge clk_12m) begin
    if (!mcu_reset_n) begin
        r0_out_d    <= 4'hF;
        flip_screen <= 1'b0;
    end
    else begin
        r0_out_d <= r0_out;
        if (r0_out != r0_out_d) flip_screen <= r0_out[3];
    end
end

mb88 mcu
(
    .clock      (clk_12m),
    .ena        (mcu_ena),
    .reset_n    (mcu_reset_n),

    // MAME's read_r returns the output latch; R0 additionally reads bit2 high ("RAM mode enabled")
    .r0_port_in (r0_out | 4'b0100),
    .r1_port_in (r1_out), .r2_port_in (r2_out), .r3_port_in (r3_out),
    .r0_port_out(r0_out), .r1_port_out(r1_out), .r2_port_out(r2_out), .r3_port_out(r3_out),
    .k_port_in  (mcu_k),
    .ol_port_out(mcu_ol), .oh_port_out(mcu_oh),
    .p_port_out (mcu_p),

    .stby_n     (1'b1),
    .tc_n       (1'b1),
    .irq_n      (ay_iob[5]),          // /IREQ from AY port B
    .sc_in_n    (1'b1),
    .si_n       (1'b1),
    .sc_out_n   (),
    .so_n       (),
    .to_n       (),

    .rom_addr   (mcu_rom_addr),
    .rom_data   (mcu_rom_q)
);

// MB8841 internal program ROM (2KB) — index 6
dpram_dc #(.widthad_a(11), .width_a(8)) mcu_prog
(
    .clock_a(clk_12m), .address_a(mcu_rom_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(mcu_rom_q),
    .clock_b(clk_12m), .address_b(ioctl_addr[10:0]), .data_b(ioctl_data),
    .wren_b(mcurom_wr), .q_b()
);

//-------------------------------------------------------- VBlank IRQ ----------------------------------------------------------//

// MAME: standard IM1 interrupt, RST 38h every vblank
// IRQ fires on vblank rising edge
reg n_irq = 1'b1;
reg vblank_last = 0;
always_ff @(posedge clk_12m) begin
    if(!reset) begin
        n_irq <= 1'b1;
        vblank_last <= 0;
    end
    else begin
        vblank_last <= video_vblank;
        // Assert IRQ on rising edge of vblank
        if(video_vblank & ~vblank_last)
            n_irq <= 1'b0;
        // Auto-clear: Z80 IM1 acknowledges via M1+IORQ
        if(~n_m1 & ~n_iorq)
            n_irq <= 1'b1;
    end
end

//-------------------------------------------------------- Video Timing --------------------------------------------------------//

// 12 MHz master (XTAL on SP-237 sheet 8B), 6 MHz dot clock.
//
// H_TOTAL is read off the schematic: the horizontal chain (IC95 LS393, AV0-AV6') counts
// 4-pixel GROUPS -- the LS95 shift registers on sheet 11B load once per 4 pixels -- so
// 96 groups x 4 = 384 dots, giving 6 MHz / 384 = 15.625 kHz.
//
// V_TOTAL is NOT off the schematic: the vertical decode gates (IC93/94/110/92 -> /BLNK,
// /INT, /VSYNC) are past what the scan resolves. 264 lines gives 59.19 Hz. Adjust here if
// the frame rate proves wrong -- everything IRQ-paced (music tempo included) follows it.
localparam int H_TOTAL = 384;
localparam int V_TOTAL = 264;

// Visible window matches MAME's visarea (0,255, 11,244): 256 across, 234 down.
localparam int H_VIS_END  = 256;
localparam int V_VIS_START = 11;
localparam int V_VIS_END   = 245;   // exclusive
localparam int HS_START = 272, HS_END = 304;
localparam int VS_START = 250, VS_END = 253;

reg [8:0] h_cnt = 9'd0;
reg [8:0] v_cnt = 9'd0;

always_ff @(posedge clk_12m) begin
    if (!reset) begin
        h_cnt <= 9'd0;
        v_cnt <= 9'd0;
    end
    else if (cen_6m) begin
        if (h_cnt == H_TOTAL[8:0] - 9'd1) begin
            h_cnt <= 9'd0;
            v_cnt <= (v_cnt == V_TOTAL[8:0] - 9'd1) ? 9'd0 : v_cnt + 9'd1;
        end
        else h_cnt <= h_cnt + 9'd1;
    end
end

// The scanout pixel pipeline is 2 clk_12m cycles deep (combinational address -> DPRAM
// address register -> scan_word latch), so the pixel for h_cnt=H leaves at H+2. hblank and
// hsync must be delayed to match or the active window leads the data. This is a latency
// match, not a window shift. The v axis has no such latency, so vblank/vsync stay
// combinational and the vblank IRQ keeps using the undelayed video_vblank.
wire video_hblank_raw = (h_cnt >= H_VIS_END[8:0]);
wire video_hsync_raw  = (h_cnt >= HS_START[8:0]) && (h_cnt < HS_END[8:0]);
reg [1:0] hblank_sr = 2'b11;
reg [1:0] hsync_sr  = 2'b00;
always_ff @(posedge clk_12m) begin
    hblank_sr <= {hblank_sr[0], video_hblank_raw};
    hsync_sr  <= {hsync_sr[0],  video_hsync_raw};
end
assign video_hblank = hblank_sr[1];
assign video_hsync  = hsync_sr[1];
assign video_vblank = (v_cnt <  V_VIS_START[8:0]) || (v_cnt >= V_VIS_END[8:0]);
assign video_vsync  = (v_cnt >= VS_START[8:0]) && (v_cnt < VS_END[8:0]);

//--------------------------------------------------------- Video RAM ----------------------------------------------------------//

// Kangaroo VRAM: 16384 addresses × 32 bits (4 bytes per word, 2 planes × 4 pixels)
// Split into two 16-bit-wide dpram_dc instances (lo=bytes 0,1  hi=bytes 2,3)
// Port A = CPU/blitter read-modify-write
// Port B = video scanout (read-only)

wire [15:0] vram_lo_qa, vram_hi_qa;   // Port A read data (CPU/blitter side)
wire [15:0] vram_lo_qb, vram_hi_qb;   // Port B read data (scanout side)
reg  [13:0] vram_addr_a;
reg  [15:0] vram_lo_da, vram_hi_da;
reg         vram_we_a;
wire [13:0] vram_addr_b;               // Scanout address (active accent accent driven by compositing logic)

dpram_dc #(.widthad_a(14), .width_a(16)) vram_lo
(
    .clock_a(clk_12m),
    .address_a(vram_addr_a),
    .data_a(vram_lo_da),
    .wren_a(vram_we_a),
    .q_a(vram_lo_qa),

    .clock_b(clk_12m),
    .address_b(vram_addr_b),
    .data_b(16'd0),
    .wren_b(1'b0),
    .q_b(vram_lo_qb)
);

dpram_dc #(.widthad_a(14), .width_a(16)) vram_hi
(
    .clock_a(clk_12m),
    .address_a(vram_addr_a),
    .data_a(vram_hi_da),
    .wren_a(vram_we_a),
    .q_a(vram_hi_qa),

    .clock_b(clk_12m),
    .address_b(vram_addr_b),
    .data_b(16'd0),
    .wren_b(1'b0),
    .q_b(vram_hi_qb)
);

// Arabian keeps both planes in the SAME pixel byte (A = upper nibble, B = lower), so one
// scanout read serves both. Kangaroo needed a second mirrored pair of RAMs because its two
// planes came from different addresses; that pair is gone, halving VRAM back to 512 Kbit.

//------------------------------------------------ VRAM Merge Functions --------------------------------------------------------//

// A VRAM word is 4 pixels x 8 bits; pixel m sits in byte m. Each pixel byte is
// {AZ,AR,AG,AB, BZ,BR,BG,BB} — plane A in the upper nibble, plane B in the lower.

// arabian.cpp blit_area(): a source byte pair (offs, offs+0x4000) carries four pixels;
// pixel m takes bit m and bit m+4 from each plane byte. Pixel value 8 is transparent.
// blitter[0] bit0 writes plane A, bit2 writes plane B.
function [31:0] blit_merge;
    input [31:0] old_word;
    input  [7:0] v1;          // low plane,  gfx $0000-$3FFF
    input  [7:0] v2;          // high plane, gfx $4000-$7FFF
    input        plane_a;
    input        plane_b;
    reg [31:0] w;
    reg  [3:0] pix;
    integer m;
    begin
        w = old_word;
        for (m = 0; m < 4; m = m + 1) begin
            pix = {v2[m+4], v2[m], v1[m+4], v1[m]};
            if (pix != 4'd8) begin
                if (plane_a) w[8*m + 4 +: 4] = pix;
                if (plane_b) w[8*m     +: 4] = pix;
            end
        end
        blit_merge = w;
    end
endfunction

// arabian.cpp videoram_w(): the CPU writes four pixels of two bits each, pixel m taking
// data[m] and data[m+4]. blitter[0] bits 3..0 each enable one bit-pair of the pixel byte:
// bit3 -> [1:0], bit2 -> [3:2], bit1 -> [5:4], bit0 -> [7:6].
// (MAME's AZ/AR-style comments on that function do not match the palette bit order; the
// code does, and this follows the code.)
function [31:0] cpu_merge;
    input [31:0] old_word;
    input  [7:0] data;
    input  [3:0] mask;
    reg [31:0] w;
    reg  [1:0] pv;
    integer m;
    begin
        w = old_word;
        for (m = 0; m < 4; m = m + 1) begin
            pv = {data[m+4], data[m]};
            if (mask[3]) w[8*m     +: 2] = pv;
            if (mask[2]) w[8*m + 2 +: 2] = pv;
            if (mask[1]) w[8*m + 4 +: 2] = pv;
            if (mask[0]) w[8*m + 6 +: 2] = pv;
        end
        cpu_merge = w;
    end
endfunction

//------------------------------------------------------ Blitter GFX ROM -------------------------------------------------------//

// 32KB split into two 16KB planes so a source pair is fetched in a single read.
wire [7:0]  gfx_lo_q, gfx_hi_q;
reg  [13:0] gfx_addr;

dpram_dc #(.widthad_a(14), .width_a(8)) gfx_plane_lo
(
    .clock_a(clk_12m), .address_a(gfx_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(gfx_lo_q),
    .clock_b(clk_12m), .address_b(ioctl_addr[13:0]), .data_b(ioctl_data),
    .wren_b(gfx_cs_i & ~ioctl_addr[14]), .q_b()
);

dpram_dc #(.widthad_a(14), .width_a(8)) gfx_plane_hi
(
    .clock_a(clk_12m), .address_a(gfx_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(gfx_hi_q),
    .clock_b(clk_12m), .address_b(ioctl_addr[13:0]), .data_b(ioctl_data),
    .wren_b(gfx_cs_i & ioctl_addr[14]), .q_b()
);

//------------------------------------------------------ DMA Blitter -----------------------------------------------------------//

// One iteration handles four pixels, which is exactly one VRAM word: the destination X is
// always a multiple of 4, so base[0..3] never straddle a word. Both the blit and the direct
// CPU write are therefore a plain read-modify-write of a single word.
//
// dpram_dc is altsyncram: registered address plus registered output = 2 clocks from
// presenting an address to valid data. Each access is RD, RD2, WR (compute, assert wren),
// COMMIT (wren high, address held) = 4 clocks per four pixels.
//
// MAME's loop is X outer, Y inner, the source advancing once per inner iteration:
//   for (i = 0; i <= sx; i++, x += 4) for (j = 0; j <= sy; j++)

localparam ST_IDLE        = 4'd0;
localparam ST_CPU_RD      = 4'd1;
localparam ST_CPU_RD2     = 4'd2;
localparam ST_CPU_WR      = 4'd3;
localparam ST_CPU_COMMIT  = 4'd4;
localparam ST_BLIT_RD     = 4'd5;
localparam ST_BLIT_RD2    = 4'd6;
localparam ST_BLIT_WR     = 4'd7;
localparam ST_BLIT_COMMIT = 4'd8;

reg [3:0] vram_state = ST_IDLE;

// blit parameters, snapshotted at the trigger
reg        blit_plane_a, blit_plane_b;
reg [15:0] blit_src;
reg  [7:0] blit_x, blit_y;
reg  [7:0] blit_sx, blit_sy;
reg  [7:0] blit_i, blit_j;
reg        blit_active = 1'b0;   // a blit is in progress; the Z80 is held for its duration
reg        blit_last   = 1'b0;   // this iteration is the last one
reg        blit_resume = 1'b0;   // a CPU write was serviced mid-blit; go back afterwards

// A trigger arriving mid-blit must not be dropped — the Kangaroo BLITQUEUE lesson.
reg        blit_pend = 1'b0;
reg  [7:0] pend_plane, pend_y, pend_x, pend_sy, pend_sx;
reg [15:0] pend_src;

// CPU bitmap writes are serviced between blit iterations, so one can wait at most a single
// iteration (4 clocks) — well inside the Z80's minimum spacing between consecutive writes.
wire       cpu_vram_wr = cs_videoram & ~n_wr;
reg        cpu_vram_wr_d = 1'b0;
wire       cpu_vram_wr_edge = cpu_vram_wr & ~cpu_vram_wr_d;
reg        cpu_pend = 1'b0;
reg [13:0] cpu_addr_l;
reg  [7:0] cpu_data_l;
reg  [3:0] cpu_mask_l;

// blit start parameters, from the live registers or the queued snapshot
wire  [7:0] start_plane = blit_pend ? pend_plane : blit_reg[0];
wire [15:0] start_src   = blit_pend ? pend_src   : {blit_reg[2], blit_reg[1]};
wire  [7:0] start_y     = blit_pend ? pend_y     : blit_reg[3];
wire  [7:0] start_x     = blit_pend ? pend_x     : {blit_reg[4][5:0], 2'b00};
wire  [7:0] start_sy    = blit_pend ? pend_sy    : blit_reg[5];
wire  [7:0] start_sx    = blit_pend ? pend_sx    : blit_reg[6];

// What ST_IDLE will actually consume this cycle. A CPU bitmap write wins over a blit, so a
// trigger arriving while idle-but-servicing-a-write is NOT started -- it has to be queued.
// Keying the queue off "not idle" missed that case and dropped the trigger outright.
wire idle_takes_cpu   = (vram_state == ST_IDLE) && (cpu_vram_wr_edge || cpu_pend);
wire idle_starts_blit = (vram_state == ST_IDLE) && !idle_takes_cpu && (blitter_start || blit_pend);
wire trigger_consumed = idle_starts_blit && !blit_pend;   // a live trigger started right now

// destination word of the current inner step
wire  [7:0] blit_row   = blit_y + blit_j;
wire [13:0] blit_vaddr = {blit_x[7:2], blit_row};

wire [31:0] vram_word_a  = {vram_hi_qa, vram_lo_qa};
wire [31:0] cpu_merged   = cpu_merge (vram_word_a, cpu_data_l, cpu_mask_l);
wire [31:0] blit_merged  = blit_merge(vram_word_a, gfx_lo_q, gfx_hi_q, blit_plane_a, blit_plane_b);

assign blit_active_w = blit_active;

always_ff @(posedge clk_12m) begin
    cpu_vram_wr_d <= cpu_vram_wr;

    if (!reset) begin
        vram_state  <= ST_IDLE;
        vram_we_a   <= 1'b0;
        blit_pend   <= 1'b0;
        cpu_pend    <= 1'b0;
        blit_resume <= 1'b0;
        blit_last   <= 1'b0;
        blit_active <= 1'b0;
    end
    else begin
        vram_we_a <= 1'b0;

        // Queue any trigger not started this very cycle. If a queued blit starts while a new
        // trigger arrives, the new one replaces it in the queue and nothing is lost.
        if (blitter_start && !trigger_consumed) begin
            blit_pend  <= 1'b1;
            pend_plane <= blit_reg[0];
            pend_src   <= {blit_reg[2], blit_reg[1]};
            pend_y     <= blit_reg[3];
            pend_x     <= {blit_reg[4][5:0], 2'b00};
            pend_sy    <= blit_reg[5];
            pend_sx    <= blit_reg[6];
        end
        else if (idle_starts_blit && blit_pend) blit_pend <= 1'b0;

        // queue a CPU bitmap write that cannot start right now
        if (cpu_vram_wr_edge && vram_state != ST_IDLE) begin
            cpu_pend   <= 1'b1;
            cpu_addr_l <= cpu_A[13:0];
            cpu_data_l <= cpu_Dout;
            cpu_mask_l <= blit_reg[0][3:0];
        end

        case (vram_state)
            ST_IDLE: begin
                if (cpu_vram_wr_edge) begin
                    cpu_addr_l  <= cpu_A[13:0];
                    cpu_data_l  <= cpu_Dout;
                    cpu_mask_l  <= blit_reg[0][3:0];
                    vram_addr_a <= cpu_A[13:0];
                    vram_state  <= ST_CPU_RD;
                end
                else if (cpu_pend) begin
                    cpu_pend    <= 1'b0;
                    vram_addr_a <= cpu_addr_l;
                    vram_state  <= ST_CPU_RD;
                end
                else if (blitter_start || blit_pend) begin
                    blit_plane_a <= start_plane[0];
                    blit_plane_b <= start_plane[2];
                    blit_src     <= start_src;
                    blit_y       <= start_y;
                    blit_x       <= start_x;
                    blit_sy      <= start_sy;
                    blit_sx      <= start_sx;
                    blit_i       <= 8'd0;
                    blit_j       <= 8'd0;
                    blit_active  <= 1'b1;

                    gfx_addr    <= start_src[13:0];
                    vram_addr_a <= {start_x[7:2], start_y};
                    vram_state  <= ST_BLIT_RD;
                end
            end

            //---- direct CPU write into the bitmap ----
            ST_CPU_RD:  vram_state <= ST_CPU_RD2;
            ST_CPU_RD2: vram_state <= ST_CPU_WR;
            ST_CPU_WR: begin
                vram_lo_da <= cpu_merged[15:0];
                vram_hi_da <= cpu_merged[31:16];
                vram_we_a  <= 1'b1;
                vram_state <= ST_CPU_COMMIT;
            end
            ST_CPU_COMMIT: begin
                // wren is high through this state, so the address must not move yet
                if (blit_resume) begin
                    blit_resume <= 1'b0;
                    gfx_addr    <= blit_src[13:0];
                    vram_addr_a <= blit_vaddr;
                    vram_state  <= ST_BLIT_RD;
                end
                else vram_state <= ST_IDLE;
            end

            //---- blit ----
            ST_BLIT_RD:  vram_state <= ST_BLIT_RD2;
            ST_BLIT_RD2: vram_state <= ST_BLIT_WR;
            ST_BLIT_WR: begin
                vram_lo_da <= blit_merged[15:0];
                vram_hi_da <= blit_merged[31:16];
                vram_we_a  <= 1'b1;

                blit_src  <= blit_src + 16'd1;
                blit_last <= (blit_j == blit_sy) && (blit_i == blit_sx);

                if (blit_j == blit_sy) begin
                    blit_j <= 8'd0;
                    blit_x <= blit_x + 8'd4;
                    blit_i <= blit_i + 8'd1;
                end
                else blit_j <= blit_j + 8'd1;

                vram_state <= ST_BLIT_COMMIT;
            end
            ST_BLIT_COMMIT: begin
                // wren is high through this state; blit_src / blit_x / blit_j already point
                // at the next iteration, so blit_vaddr is the next destination word.
                if (blit_last) begin
                    blit_active <= 1'b0;
                    if (cpu_pend) begin
                        cpu_pend    <= 1'b0;
                        vram_addr_a <= cpu_addr_l;
                        vram_state  <= ST_CPU_RD;
                    end
                    else vram_state <= ST_IDLE;
                end
                else if (cpu_pend) begin
                    cpu_pend    <= 1'b0;
                    blit_resume <= 1'b1;
                    vram_addr_a <= cpu_addr_l;
                    vram_state  <= ST_CPU_RD;
                end
                else begin
                    gfx_addr    <= blit_src[13:0];
                    vram_addr_a <= blit_vaddr;
                    vram_state  <= ST_BLIT_RD;
                end
            end

            default: vram_state <= ST_IDLE;
        endcase
    end
end

//----------------------------------------------- Pixel Compositing (screen_update) --------------------------------------------//

// arabian.cpp screen_update is a straight bitmap scanout: the pen IS the pixel byte, with
// the five AY port-A control bits forming the upper half of a 13-bit colour-table index:
//   pen = ((video_control >> 3) << 8) | pixel_byte
// There is no scroll, no priority latch and no KOS1 half-pixel mask on this board.

// Scanout address is combinational off the counters; the DPRAM address register and the
// scan_word latch supply the two pipeline stages, and the slice index is delayed by the
// same two so it lines up with the word it selects.
wire [7:0] eff_x = h_cnt[7:0];
wire [7:0] eff_y = v_cnt[7:0];

assign vram_addr_b = {eff_x[7:2], eff_y};

reg  [1:0] slice_hold = 2'd0;
reg  [1:0] slice_out  = 2'd0;
reg [31:0] scan_word  = 32'd0;
always_ff @(posedge clk_12m) begin
    slice_hold <= eff_x[1:0];
    scan_word  <= {vram_hi_qb, vram_lo_qb};
    slice_out  <= slice_hold;
end

wire [7:0] pix_byte = (slice_out == 2'd0) ? scan_word[7:0]   :
                      (slice_out == 2'd1) ? scan_word[15:8]  :
                      (slice_out == 2'd2) ? scan_word[23:16] :
                                            scan_word[31:24];

// AY port A: b7 ENA, b6 ENB, b5 /ABHF, b4 /AGHF, b3 /ARHF
wire ena  =  ay_ioa[7];
wire enb  =  ay_ioa[6];
wire abhf = ~ay_ioa[5];
wire aghf = ~ay_ioa[4];
wire arhf = ~ay_ioa[3];

// Pixel byte: plane A in the upper nibble, plane B in the lower, each {Z,R,G,B}
wire az = pix_byte[7], ar = pix_byte[6], ag = pix_byte[5], ab = pix_byte[4];
wire bz = pix_byte[3], br = pix_byte[2], bg = pix_byte[1], bb = pix_byte[0];

wire planea = (az | ar | ag | ab) & ena;

// Colour derivation, arabian.cpp palette(). Confirmed against SP-237 sheet 11B: plane B
// reaches red (BZ/BR via IC118) and green (BG via IC118, BB via IC120) but never blue --
// the blue driver TR6 is fed only from the plane-A path.
wire rhi   = planea ? ar : (enb ? bz : 1'b0);
wire rlo   = planea ? ((~arhf & az) ? 1'b0 : ar) : (enb ? br : 1'b0);
wire ghi   = planea ? ag : (enb ? bb : 1'b0);
wire glo   = planea ? ((~aghf & az) ? 1'b0 : ag) : (enb ? bg : 1'b0);
wire bhi   = ab;
wire bbase = (~abhf & az) ? 1'b0 : ab;

// Two bits per channel through the resistor DAC. MAME's weights match the sheet-11B
// network: red 1.2K/1.8K = 1.5 (153/102), green 750R/1.2K = 1.6 (156/99), 510R pull-ups.
//   r = rhi*115 + rlo*77 + 63,  g = ghi*117 + glo*75 + 63,  b = bhi*192 + bbase*63
wire [7:0] pal_r = ({rhi,rlo}     == 2'b00) ? 8'd0 : ({rhi,rlo}     == 2'b01) ? 8'd140 :
                   ({rhi,rlo}     == 2'b10) ? 8'd178 : 8'd255;
wire [7:0] pal_g = ({ghi,glo}     == 2'b00) ? 8'd0 : ({ghi,glo}     == 2'b01) ? 8'd138 :
                   ({ghi,glo}     == 2'b10) ? 8'd180 : 8'd255;
wire [7:0] pal_b = ({bhi,bbase}   == 2'b00) ? 8'd0 : ({bhi,bbase}   == 2'b01) ? 8'd63  :
                   ({bhi,bbase}   == 2'b10) ? 8'd192 : 8'd255;

wire blanked = video_hblank | video_vblank;

assign video_r = blanked ? 8'd0 : pal_r;
assign video_g = blanked ? 8'd0 : pal_g;
assign video_b = blanked ? 8'd0 : pal_b;

endmodule
