//============================================================================
//
//  Arabian Main CPU Board
//  Based on MAME arabian.cpp by Dan Boris.
//  Video timing, VRAM and blitter derived from kangaroo.cpp by Ville Laitinen and Aaron Giles.
//
//============================================================================

module Arabian_CPU
(
    input         reset,
    input         clk_12m,           // 12 MHz master (XTAL)

    output  [7:0] video_r, video_g, video_b,
    output        video_hsync, video_vsync,
    output        video_hblank, video_vblank,
    output        ce_pix,

    input   [7:0] dsw1,             // SW1  at $C200
    input   [2:0] in0,              // $C000: b0 coin1, b1 coin2, b2 service (all active high)
    // MB8841 K-port banks: COM0 {aux-s, start2, start1, 1}, COM1/COM3 {down, up, left, right},
    // COM2/COM4 {0, 0, 0, button} (COM3/COM4 = cocktail player 2), COM5 = SW2
    input   [3:0] com0, com1, com2, com3, com4, com5,

    // AY-3-8910 bus, in Z80 I/O space
    output        ay_addr_wr,       // OUT to $C800: register select
    output        ay_data_wr,       // OUT to $CA00: register data
    output  [7:0] ay_din,
    // AY port A = video control, port B = MCU /IREQ, /SRES and coin counters
    input   [7:0] ay_ioa,
    input   [7:0] ay_iob,


    // shared Z80 (pool slot z80_0) and MB8841 (pool slot mb88_0), rtl/arabian_dispatcher.sv
    output chip_pool_pkg::z80_i_t  z80_0_i,
    input  chip_pool_pkg::z80_o_t  z80_0_o,
    output chip_pool_pkg::mb88_i_t mb88_0_i,
    input  chip_pool_pkg::mb88_o_t mb88_0_o,

    // shared ROM blocks: program (index 0), MB8841 program (index 6), blitter GFX planes (index 2)
    output [12:0] rom_cpu_a,
    input   [7:0] rom0_D, rom1_D, rom2_D, rom3_D,
    output [10:0] mcu_rom_a,
    input   [7:0] mcu_rom_d,
    output [13:0] gfx_a,
    input   [7:0] gfx_lo_q, gfx_hi_q,

    // board RAM pool blocks 0-4: shared MB8841 RAM (port B = MCU / hiscore), VRAM byte lanes 0-3
    output ram_pool_pkg::pram_i_t [4:0] pr_i,
    input  ram_pool_pkg::pram_o_t [4:0] pr_o,

    input         pause,
    input         crt_flip,

    // hiscore: borrows the MCU's shared-RAM port (hiscore.v pauses the CPU, and so the MCU, first)
    input         hs_access,
    input  [15:0] hs_address,
    input   [7:0] hs_data_in,
    output  [7:0] hs_data_out,
    input         hs_write
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

reg [1:0] div = 2'd0;
always_ff @(posedge clk_12m) begin
    div <= div + 2'd1;
end
wire cen_6m = (div[0] == 1'b0);      // 6 MHz pixel
wire cen_3m = (div == 2'd0);         // 3 MHz Z80

reg [2:0] div6 = 3'd0;
always_ff @(posedge clk_12m) begin
    div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
end
wire cen_2m = (div6 == 3'd0);        // 2 MHz MB8841 pin clock

assign ce_pix = cen_6m;

// the Z80 is held for the whole blit (the DMA owns the bus), so a blit is atomic
wire blit_active_w;

//------------------------------------------------------------ CPU -------------------------------------------------------------//

// Z80 bus (pool slot z80_0)
wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

assign cpu_A    = z80_0_o.a;
assign cpu_Dout = z80_0_o.dout;
assign n_m1     = z80_0_o.m1_n;
assign n_mreq   = z80_0_o.mreq_n;
assign n_iorq   = z80_0_o.iorq_n;
assign n_rd     = z80_0_o.rd_n;
assign n_wr     = z80_0_o.wr_n;
assign n_rfsh   = z80_0_o.rfsh_n;

//------------------------------------------------------ Address Decoding ------------------------------------------------------//

wire mem_access = ~n_mreq & n_rfsh;

// $0000-$7FFF program ROM, flat 32KB
wire cs_any_rom = mem_access & ~cpu_A[15];

wire cs_videoram = mem_access & (cpu_A[15:14] == 2'b10);          // $8000-$BFFF bitmap, CPU write only

wire cs_in0 = mem_access & (cpu_A[15:9] == 7'b1100000);           // $C000 coin / service, mirror $01FF

wire cs_dsw1 = mem_access & (cpu_A[15:9] == 7'b1100001);          // $C200 SW1, mirror $01FF

wire cs_customram = mem_access & (cpu_A[15:12] == 4'hD);          // $D000-$D7FF shared MB8841 RAM (mirror $0800) = the Z80's only work RAM

wire cs_blitter = mem_access & (cpu_A[15:12] == 4'hE);            // $E000-$E006 blitter, mirror $0FF8


// AY in I/O space: the game uses OUT (C) with B = $C8 / $CA, so A15-A9 decode (mirror $01FF);
// M1 keeps the interrupt acknowledge out
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


assign rom_D = (cpu_A[14:13] == 2'd0) ? rom0_D :
               (cpu_A[14:13] == 2'd1) ? rom1_D :
               (cpu_A[14:13] == 2'd2) ? rom2_D :
                                        rom3_D;

assign rom_cpu_a = cpu_A[12:0];

//------------------------------------------------------------ RAM ------------------------------------------------------------//

// board RAMs = pool blocks 0-4 (0 = shared MB8841 RAM, 1-4 = VRAM byte lanes)
ram_pool_pkg::pram_i_t cram_i, vl0_i, vl1_i, vh0_i, vh1_i;
ram_pool_pkg::pram_o_t cram_o, vl0_o, vl1_o, vh0_o, vh1_o;
assign pr_i = {vh1_i, vh0_i, vl1_i, vl0_i, cram_i};
assign {vh1_o, vh0_o, vl1_o, vl0_o, cram_o} = pr_o;


// hiscore: scores at $D384 (0x3C bytes) and $D3BD (1) in the shared RAM, read via the MCU port

//----------------------------------------------------- Blitter Registers ------------------------------------------------------//

// blitter registers $E000-$E006 (mirror $0FF8):
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

// edge-detected: one register update and one start pulse per Z80 write
always_ff @(posedge clk_12m) begin
    cs_blit_wr_d  <= cs_blit_wr;
    blitter_start <= 1'b0;
    if (cs_blit_wr & ~cs_blit_wr_d) begin
        blit_reg[cpu_A[2:0]] <= cpu_Dout;
        if (cpu_A[2:0] == 3'd6) blitter_start <= 1'b1;
    end
end

// NMI is not connected on this board
wire n_nmi = 1'b1;

//-------------------------------------------------------- MB8841 MCU ---------------------------------------------------------//
// SUN 8212 (MB8841): shared-RAM coprocessor. Every joystick, button, start and SW2 bit reaches the Z80
// through its scan; the game cannot run without it.
//   O port + P[2:0]        -> shared RAM address A0-A10
//   R0.1 low               -> write 0xF0|R3 to that address
//   R0.0 low               -> K reads the low nibble of RAM
//   R0.0 high              -> K reads COM[i], i = lowest clear bit of {R2[1:0],R1}
//   R0.3                   -> flip screen
//   R port reads           -> the output latch, R0 with bit2 forced high ("RAM mode")
//   AY port B b5 -> /IREQ, b4 -> /SRES
// No protection PROM; the MCU does not drive the Z80 NMI.

// ena = one MB88 machine cycle = 2 MHz pin clock / 6 (the /32 timer prescaler is inside mb88.sv)
localparam int MCU_CEN_DIV = 6;
reg [2:0] mcu_div_cnt = 3'd0;
always @(posedge clk_12m)
    if (cen_2m) mcu_div_cnt <= (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1) ? 3'd0 : mcu_div_cnt + 3'd1;
wire mcu_ena = cen_2m & ~pause & (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1);

// /SRES: AY registers reset to 0, so the MCU is held until the game writes AY register 15, as on the board
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
// R0.1 = level-driven RAM write strobe; R0 resets to 0xF, so it is inactive out of reset
wire        mcu_ram_we   = mcu_reset_n & ~r0_out[1];

// port B: MCU, or hiscore while hiscore.v has the CPU (and so the MCU) paused
wire [10:0] ram_b_addr = hs_access ? hs_address[10:0] : mcu_ram_addr;
wire  [7:0] ram_b_din  = hs_access ? hs_data_in       : mcu_ram_din;
wire        ram_b_we   = hs_access ? hs_write         : mcu_ram_we;

assign cram_i.a_addr = 15'(cpu_A[10:0]);
assign cram_i.a_d    = cpu_Dout;
assign cram_i.a_we   = cs_customram & ~n_wr;
assign cram_i.b_addr = 15'(ram_b_addr);
assign cram_i.b_d    = ram_b_din;
assign cram_i.b_we   = ram_b_we;
assign customram_D   = cram_o.a_q;
assign mcu_ram_q     = cram_o.b_q;

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
// The dpram settles in 2 clocks and the MCU advances every 36, so the address is stable.
wire [3:0] mcu_k = ~r0_out[0] ? mcu_ram_q[3:0] : com_val;

//--- flip screen ---
// latched on an R0 change: R0 resets to 0xF, so reading R0.3 directly says "flipped" before the first write
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

assign mb88_0_i.ena     = mcu_ena;
assign mb88_0_i.reset_n = mcu_reset_n;
assign mb88_0_i.k       = mcu_k;
assign mb88_0_i.r_in    = {r3_out, r2_out, r1_out, r0_out | 4'b0100};
assign mb88_0_i.irq_n   = ay_iob[5];
assign mb88_0_i.tc_n    = 1'b1;
assign mb88_0_i.si_n    = 1'b1;
assign mb88_0_i.rom_d   = mcu_rom_q;
assign {r3_out, r2_out, r1_out, r0_out} = mb88_0_o.r_out;
assign {mcu_oh, mcu_ol} = mb88_0_o.o;
assign mcu_p        = mb88_0_o.p;
assign mcu_rom_addr = mb88_0_o.rom_a;

// MB8841 program ROM (index 6): shared ROM block in the dispatcher
assign mcu_rom_a = mcu_rom_addr;
assign mcu_rom_q = mcu_rom_d;

//-------------------------------------------------------- VBlank IRQ ----------------------------------------------------------//

// IM1 interrupt (RST 38h) on the vblank rising edge
reg n_irq = 1'b1;
reg vblank_last = 0;
always_ff @(posedge clk_12m) begin
    if(!reset) begin
        n_irq <= 1'b1;
        vblank_last <= 0;
    end
    else begin
        vblank_last <= video_vblank;
        if(video_vblank & ~vblank_last)
            n_irq <= 1'b0;
        // cleared by the acknowledge (M1 + IORQ)
        if(~n_m1 & ~n_iorq)
            n_irq <= 1'b1;
    end
end

//-------------------------------------------------------- Video Timing --------------------------------------------------------//

// 12 MHz XTAL (SP-237 sheet 8B), 6 MHz dot clock. H_TOTAL 384: IC95 counts 96 4-pixel groups (15.625 kHz).
// V_TOTAL 264 (59.19 Hz) is not read off the schematic. #unverified
localparam int H_TOTAL = 384;
localparam int V_TOTAL = 264;

// visible 256 x 234 (x 0-255, y 11-244)
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

// hblank / hsync delayed 2 clocks to match the scanout pipeline (latency, not a window shift)
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

// VRAM 16K x 32 (4 pixels x 2 planes per word) = 4 pool byte lanes; port A = CPU / blitter
// read-modify-write, port B = scanout

wire [15:0] vram_lo_qa, vram_hi_qa;   // Port A read data (CPU/blitter side)
wire [15:0] vram_lo_qb, vram_hi_qb;   // Port B read data (scanout side)
reg  [13:0] vram_addr_a;
reg  [15:0] vram_lo_da, vram_hi_da;
reg         vram_we_a;
wire [13:0] vram_addr_b;               // Scanout address, from the compositing logic

assign vl0_i.a_addr = 15'(vram_addr_a);
assign vl0_i.a_d    = vram_lo_da[7:0];
assign vl0_i.a_we   = vram_we_a;
assign vl0_i.b_addr = 15'(vram_addr_b);
assign vl0_i.b_d    = 8'd0;
assign vl0_i.b_we   = 1'b0;
assign vl1_i.a_addr = 15'(vram_addr_a);
assign vl1_i.a_d    = vram_lo_da[15:8];
assign vl1_i.a_we   = vram_we_a;
assign vl1_i.b_addr = 15'(vram_addr_b);
assign vl1_i.b_d    = 8'd0;
assign vl1_i.b_we   = 1'b0;
assign vram_lo_qa = {vl1_o.a_q, vl0_o.a_q};
assign vram_lo_qb = {vl1_o.b_q, vl0_o.b_q};

assign vh0_i.a_addr = 15'(vram_addr_a);
assign vh0_i.a_d    = vram_hi_da[7:0];
assign vh0_i.a_we   = vram_we_a;
assign vh0_i.b_addr = 15'(vram_addr_b);
assign vh0_i.b_d    = 8'd0;
assign vh0_i.b_we   = 1'b0;
assign vh1_i.a_addr = 15'(vram_addr_a);
assign vh1_i.a_d    = vram_hi_da[15:8];
assign vh1_i.a_we   = vram_we_a;
assign vh1_i.b_addr = 15'(vram_addr_b);
assign vh1_i.b_d    = 8'd0;
assign vh1_i.b_we   = 1'b0;
assign vram_hi_qa = {vh1_o.a_q, vh0_o.a_q};
assign vram_hi_qb = {vh1_o.b_q, vh0_o.b_q};

// Both planes live in the same pixel byte (A upper nibble, B lower), so one read serves both.

//------------------------------------------------ VRAM Merge Functions --------------------------------------------------------//

// A VRAM word is 4 pixels x 8 bits; pixel m sits in byte m. Each pixel byte is
// {AZ,AR,AG,AB, BZ,BR,BG,BB} — plane A in the upper nibble, plane B in the lower.

// blit: a source byte pair (offs, offs + $4000) carries four pixels, pixel m = bits m and m+4 of each;
// pixel value 8 is transparent. blitter[0] bit0 writes plane A, bit2 plane B.
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

// CPU write: pixel m = {data[m+4], data[m]}; blitter[0] bits 3..0 enable pixel-byte bit pairs
// [1:0], [3:2], [5:4], [7:6]
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
reg  [13:0] gfx_addr;

assign gfx_a = gfx_addr;

//------------------------------------------------------ DMA Blitter -----------------------------------------------------------//

// one iteration = one 4-pixel VRAM word, read-modify-write: RD, RD2, WR, COMMIT = 4 clocks
// (dpram_dc = 2 clocks address to data). X outer, Y inner, source advancing per step.

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

// A trigger arriving mid-blit must not be dropped.
reg        blit_pend = 1'b0;
reg  [7:0] pend_plane, pend_y, pend_x, pend_sy, pend_sx;
reg [15:0] pend_src;

// CPU bitmap writes are serviced between blit iterations, so one waits at most 4 clocks.
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

// What ST_IDLE consumes this cycle. A CPU bitmap write wins over a blit, so a trigger
// arriving while idle-but-servicing-a-write is not started and must be queued.
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

        // A new trigger replaces any queued one; nothing is lost.
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

// straight bitmap scanout: pen = {AY port A[7:3], pixel byte} (13-bit colour-table index);
// no scroll, priority latch or half-pixel mask

// scanout address is combinational; the slice index is delayed 2 to line up with its word
// flip = MCU R0.3 (Flip Screen DIP) XOR OSD CRT Flip: an exact 180-degree mirror of the 256 x 256
// bitmap (visible y 11-244 maps onto itself)
wire screen_mirror = flip_screen ^ crt_flip;
wire [7:0] eff_x = h_cnt[7:0] ^ {8{screen_mirror}};
wire [7:0] eff_y = v_cnt[7:0] ^ {8{screen_mirror}};

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

// colour (SP-237 sheet 11B): plane B reaches red and green but never blue (blue driver TR6 sees plane A only)
wire rhi   = planea ? ar : (enb ? bz : 1'b0);
wire rlo   = planea ? ((~arhf & az) ? 1'b0 : ar) : (enb ? br : 1'b0);
wire ghi   = planea ? ag : (enb ? bb : 1'b0);
wire glo   = planea ? ((~aghf & az) ? 1'b0 : ag) : (enb ? bg : 1'b0);
wire bhi   = ab;
wire bbase = (~abhf & az) ? 1'b0 : ab;

// 2 bits per channel through the sheet-11B resistor DAC (red 1.2K/1.8K, green 750R/1.2K, 510R pull-ups):
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


// pool slot z80_0 inputs
assign z80_0_i.ce    = cen_3m & ~pause & ~blit_active_w;
assign z80_0_i.int_n = n_irq;
assign z80_0_i.nmi_n = n_nmi;
assign z80_0_i.di    = cpu_Din;

endmodule
