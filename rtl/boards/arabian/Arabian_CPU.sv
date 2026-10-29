//  Based on MAME arabian.cpp by Dan Boris.

module Arabian_CPU
(
    input         reset,
    input         clk_12m,

    output  [7:0] video_r, video_g, video_b,
    output        video_hsync, video_vsync,
    output        video_hblank, video_vblank,
    output        ce_pix,

    input   [7:0] dsw1,
    input   [2:0] in0,
    input   [3:0] com0, com1, com2, com3, com4, com5,

    output        ay_addr_wr,
    output        ay_data_wr,
    output  [7:0] ay_din,
    input   [7:0] ay_ioa,
    input   [7:0] ay_iob,

    output chip_pool_pkg::z80_i_t  z80_0_i,
    input  chip_pool_pkg::z80_o_t  z80_0_o,
    output chip_pool_pkg::mb88_i_t mb88_0_i,
    input  chip_pool_pkg::mb88_o_t mb88_0_o,

    output [12:0] rom_cpu_a,
    input   [7:0] rom0_D, rom1_D, rom2_D, rom3_D,
    output [10:0] mcu_rom_a,
    input   [7:0] mcu_rom_d,
    output [13:0] gfx_a,
    input   [7:0] gfx_lo_q, gfx_hi_q,

    output ram_pool_pkg::pram_i_t [4:0] pr_i,
    input  ram_pool_pkg::pram_o_t [4:0] pr_o,

    input         pause,
    input         crt_flip,

    input         hs_access,
    input  [15:0] hs_address,
    input   [7:0] hs_data_in,
    output  [7:0] hs_data_out,
    input         hs_write
);

reg [1:0] div = 2'd0;
always_ff @(posedge clk_12m) begin
    div <= div + 2'd1;
end
wire cen_6m = (div[0] == 1'b0);
wire cen_3m = (div == 2'd0);

reg [2:0] div6 = 3'd0;
always_ff @(posedge clk_12m) begin
    div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
end
wire cen_2m = (div6 == 3'd0);

assign ce_pix = cen_6m;

wire blit_active_w;

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

wire mem_access = ~n_mreq & n_rfsh;

wire cs_any_rom = mem_access & ~cpu_A[15];

wire cs_videoram = mem_access & (cpu_A[15:14] == 2'b10);

wire cs_in0 = mem_access & (cpu_A[15:9] == 7'b1100000);

wire cs_dsw1 = mem_access & (cpu_A[15:9] == 7'b1100001);

wire cs_customram = mem_access & (cpu_A[15:12] == 4'hD);

wire cs_blitter = mem_access & (cpu_A[15:12] == 4'hE);

wire io_write = ~n_iorq & n_m1 & ~n_wr;
assign ay_addr_wr = io_write & (cpu_A[15:9] == 7'b1100100);
assign ay_data_wr = io_write & (cpu_A[15:9] == 7'b1100101);
assign ay_din     = cpu_Dout;

wire [7:0] rom_D;
wire [7:0] customram_D;

wire [7:0] cpu_Din =
    cs_any_rom              ? rom_D :
    (cs_customram & ~n_rd)  ? customram_D :
    cs_dsw1                 ? dsw1 :
    cs_in0                  ? {5'b00000, in0} :
    8'hFF;

assign rom_D = (cpu_A[14:13] == 2'd0) ? rom0_D :
               (cpu_A[14:13] == 2'd1) ? rom1_D :
               (cpu_A[14:13] == 2'd2) ? rom2_D :
                                        rom3_D;

assign rom_cpu_a = cpu_A[12:0];

ram_pool_pkg::pram_i_t cram_i, vl0_i, vl1_i, vh0_i, vh1_i;
ram_pool_pkg::pram_o_t cram_o, vl0_o, vl1_o, vh0_o, vh1_o;
assign pr_i = {vh1_i, vh0_i, vl1_i, vl0_i, cram_i};
assign {vh1_o, vh0_o, vl1_o, vl0_o, cram_o} = pr_o;

reg [7:0] blit_reg [0:7];
integer br_i;
initial begin
    for (br_i = 0; br_i < 8; br_i = br_i + 1)
        blit_reg[br_i] = 8'd0;
end

wire cs_blit_wr = cs_blitter & ~n_wr;
reg  cs_blit_wr_d = 1'b0;
reg  blitter_start = 1'b0;

always_ff @(posedge clk_12m) begin
    cs_blit_wr_d  <= cs_blit_wr;
    blitter_start <= 1'b0;
    if (cs_blit_wr & ~cs_blit_wr_d) begin
        blit_reg[cpu_A[2:0]] <= cpu_Dout;
        if (cpu_A[2:0] == 3'd6) blitter_start <= 1'b1;
    end
end

wire n_nmi = 1'b1;

localparam int MCU_CEN_DIV = 6;
reg [2:0] mcu_div_cnt = 3'd0;
always @(posedge clk_12m)
    if (cen_2m) mcu_div_cnt <= (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1) ? 3'd0 : mcu_div_cnt + 3'd1;
wire mcu_ena = cen_2m & ~pause & (mcu_div_cnt == MCU_CEN_DIV[2:0] - 3'd1);

wire mcu_reset_n = reset & ay_iob[4];

wire [10:0] mcu_rom_addr;
wire  [7:0] mcu_rom_q;
wire  [3:0] mcu_ol, mcu_oh, mcu_p;
wire  [7:0] mcu_o = {mcu_oh, mcu_ol};
wire  [3:0] r0_out, r1_out, r2_out, r3_out;

wire [10:0] mcu_ram_addr = {mcu_p[2:0], mcu_o};
wire  [7:0] mcu_ram_din  = {4'hF, r3_out};
wire  [7:0] mcu_ram_q;
wire        mcu_ram_we   = mcu_reset_n & ~r0_out[1];

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

wire [5:0] com_sel = {r2_out[1:0], r1_out};
wire [3:0] com_val = ~com_sel[0] ? com0 :
                     ~com_sel[1] ? com1 :
                     ~com_sel[2] ? com2 :
                     ~com_sel[3] ? com3 :
                     ~com_sel[4] ? com4 :
                     ~com_sel[5] ? com5 : 4'hF;
wire [3:0] mcu_k = ~r0_out[0] ? mcu_ram_q[3:0] : com_val;

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

assign mcu_rom_a = mcu_rom_addr;
assign mcu_rom_q = mcu_rom_d;

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
        if(~n_m1 & ~n_iorq)
            n_irq <= 1'b1;
    end
end

localparam int H_TOTAL = 384;
localparam int V_TOTAL = 264;

localparam int H_VIS_END  = 256;
localparam int V_VIS_START = 11;
localparam int V_VIS_END   = 245;
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

wire [15:0] vram_lo_qa, vram_hi_qa;
wire [15:0] vram_lo_qb, vram_hi_qb;
reg  [13:0] vram_addr_a;
reg  [15:0] vram_lo_da, vram_hi_da;
reg         vram_we_a;
wire [13:0] vram_addr_b;

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

function [31:0] blit_merge;
    input [31:0] old_word;
    input  [7:0] v1;
    input  [7:0] v2;
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

reg  [13:0] gfx_addr;

assign gfx_a = gfx_addr;

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

reg        blit_plane_a, blit_plane_b;
reg [15:0] blit_src;
reg  [7:0] blit_x, blit_y;
reg  [7:0] blit_sx, blit_sy;
reg  [7:0] blit_i, blit_j;
reg        blit_active = 1'b0;
reg        blit_last   = 1'b0;
reg        blit_resume = 1'b0;

// a trigger that arrives mid-blit is queued, never dropped
reg        blit_pend = 1'b0;
reg  [7:0] pend_plane, pend_y, pend_x, pend_sy, pend_sx;
reg [15:0] pend_src;

wire       cpu_vram_wr = cs_videoram & ~n_wr;
reg        cpu_vram_wr_d = 1'b0;
wire       cpu_vram_wr_edge = cpu_vram_wr & ~cpu_vram_wr_d;
reg        cpu_pend = 1'b0;
reg [13:0] cpu_addr_l;
reg  [7:0] cpu_data_l;
reg  [3:0] cpu_mask_l;

wire  [7:0] start_plane = blit_pend ? pend_plane : blit_reg[0];
wire [15:0] start_src   = blit_pend ? pend_src   : {blit_reg[2], blit_reg[1]};
wire  [7:0] start_y     = blit_pend ? pend_y     : blit_reg[3];
wire  [7:0] start_x     = blit_pend ? pend_x     : {blit_reg[4][5:0], 2'b00};
wire  [7:0] start_sy    = blit_pend ? pend_sy    : blit_reg[5];
wire  [7:0] start_sx    = blit_pend ? pend_sx    : blit_reg[6];

wire idle_takes_cpu   = (vram_state == ST_IDLE) && (cpu_vram_wr_edge || cpu_pend);
wire idle_starts_blit = (vram_state == ST_IDLE) && !idle_takes_cpu && (blitter_start || blit_pend);
wire trigger_consumed = idle_starts_blit && !blit_pend;

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

            ST_CPU_RD:  vram_state <= ST_CPU_RD2;
            ST_CPU_RD2: vram_state <= ST_CPU_WR;
            ST_CPU_WR: begin
                vram_lo_da <= cpu_merged[15:0];
                vram_hi_da <= cpu_merged[31:16];
                vram_we_a  <= 1'b1;
                vram_state <= ST_CPU_COMMIT;
            end
            ST_CPU_COMMIT: begin
                // wren is high through this state: the address must not move yet
                if (blit_resume) begin
                    blit_resume <= 1'b0;
                    gfx_addr    <= blit_src[13:0];
                    vram_addr_a <= blit_vaddr;
                    vram_state  <= ST_BLIT_RD;
                end
                else vram_state <= ST_IDLE;
            end

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

wire ena  =  ay_ioa[7];
wire enb  =  ay_ioa[6];
wire abhf = ~ay_ioa[5];
wire aghf = ~ay_ioa[4];
wire arhf = ~ay_ioa[3];

wire az = pix_byte[7], ar = pix_byte[6], ag = pix_byte[5], ab = pix_byte[4];
wire bz = pix_byte[3], br = pix_byte[2], bg = pix_byte[1], bb = pix_byte[0];

wire planea = (az | ar | ag | ab) & ena;

// plane B drives red and green, never blue (the blue driver sees plane A only)
wire rhi   = planea ? ar : (enb ? bz : 1'b0);
wire rlo   = planea ? ((~arhf & az) ? 1'b0 : ar) : (enb ? br : 1'b0);
wire ghi   = planea ? ag : (enb ? bb : 1'b0);
wire glo   = planea ? ((~aghf & az) ? 1'b0 : ag) : (enb ? bg : 1'b0);
wire bhi   = ab;
wire bbase = (~abhf & az) ? 1'b0 : ab;

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

assign z80_0_i.ce    = cen_3m & ~pause & ~blit_active_w;
assign z80_0_i.int_n = n_irq;
assign z80_0_i.nmi_n = n_nmi;
assign z80_0_i.di    = cpu_Din;

endmodule
