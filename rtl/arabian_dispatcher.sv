//  Copyright (C) 2026 Rodimus
//  Based on MAME arabian.cpp by Dan Boris

module arabian_dispatcher
(
    input                reset,
    input                clk_12m,

    input          [2:0] in0,
    input          [7:0] dsw1,
    input          [3:0] com0, com1, com2, com3, com4, com5,

    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,
    input                crt_flip,

    input                hs_access,
    input         [15:0] hs_address,
    input          [7:0] hs_data_in,
    output         [7:0] hs_data_out,
    input                hs_write
);

wire rom0_cs, rom1_cs, rom2_cs, rom3_cs;
wire idx0_wr = ioctl_wr & (ioctl_index == 8'd0);
selector main_sel
(
    .ioctl_addr(ioctl_addr),
    .rom0_cs(rom0_cs), .rom1_cs(rom1_cs), .rom2_cs(rom2_cs), .rom3_cs(rom3_cs)
);

wire idx6_wr = ioctl_wr & (ioctl_index == 8'd6);

wire idx2_wr = ioctl_wr & (ioctl_index == 8'd2);

/////////////////////////////  Shared ROM blocks  /////////////////////////////

wire [12:0] rom_cpu_a;
wire [10:0] mcu_rom_a;
wire [13:0] gfx_a;
wire  [7:0] rom0_D, rom1_D, rom2_D, rom3_D, mcu_rom_d, gfx_lo_q, gfx_hi_q;

eprom_8k rom0 (.ADDR(rom_cpu_a), .CLK(clk_12m), .DATA(rom0_D), .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data), .CS_DL(rom0_cs & idx0_wr), .WR(ioctl_wr));
eprom_8k rom1 (.ADDR(rom_cpu_a), .CLK(clk_12m), .DATA(rom1_D), .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data), .CS_DL(rom1_cs & idx0_wr), .WR(ioctl_wr));
eprom_8k rom2 (.ADDR(rom_cpu_a), .CLK(clk_12m), .DATA(rom2_D), .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data), .CS_DL(rom2_cs & idx0_wr), .WR(ioctl_wr));
eprom_8k rom3 (.ADDR(rom_cpu_a), .CLK(clk_12m), .DATA(rom3_D), .ADDR_DL(ioctl_addr), .CLK_DL(clk_12m), .DATA_IN(ioctl_data), .CS_DL(rom3_cs & idx0_wr), .WR(ioctl_wr));

dpram_dc #(.widthad_a(11), .width_a(8)) mcu_prog
(
    .clock_a(clk_12m), .address_a(mcu_rom_a), .data_a(8'd0), .wren_a(1'b0), .q_a(mcu_rom_d),
    .clock_b(clk_12m), .address_b(ioctl_addr[10:0]), .data_b(ioctl_data), .wren_b(idx6_wr), .q_b()
);

dpram_dc #(.widthad_a(14), .width_a(8)) gfx_plane_lo
(
    .clock_a(clk_12m), .address_a(gfx_a), .data_a(8'd0), .wren_a(1'b0), .q_a(gfx_lo_q),
    .clock_b(clk_12m), .address_b(ioctl_addr[13:0]), .data_b(ioctl_data), .wren_b(idx2_wr & ~ioctl_addr[14]), .q_b()
);

dpram_dc #(.widthad_a(14), .width_a(8)) gfx_plane_hi
(
    .clock_a(clk_12m), .address_a(gfx_a), .data_a(8'd0), .wren_a(1'b0), .q_a(gfx_hi_q),
    .clock_b(clk_12m), .address_b(ioctl_addr[13:0]), .data_b(ioctl_data), .wren_b(idx2_wr & ioctl_addr[14]), .q_b()
);

/////////////////////////////  Chip pool  /////////////////////////////

chip_pool_pkg::z80_i_t  z80_0_i;
chip_pool_pkg::z80_o_t  z80_0_o;
chip_pool_pkg::mb88_i_t mb88_0_i;
chip_pool_pkg::mb88_o_t mb88_0_o;
chip_pool_pkg::ay_i_t   ay_0_i;
chip_pool_pkg::ayio_o_t ay_0_o;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80_0
(
    .RESET_n(reset), .CLK(clk_12m), .CEN(z80_0_i.ce), .INT_n(z80_0_i.int_n), .NMI_n(z80_0_i.nmi_n), .BUSRQ_n(1'b1),
    .M1_n(z80_0_o.m1_n), .MREQ_n(z80_0_o.mreq_n), .IORQ_n(z80_0_o.iorq_n), .RD_n(z80_0_o.rd_n), .WR_n(z80_0_o.wr_n),
    .RFSH_n(z80_0_o.rfsh_n), .A(z80_0_o.a), .DI(z80_0_i.di), .DO(z80_0_o.dout)
);

wire [3:0] mcu_r0, mcu_r1, mcu_r2, mcu_r3, mcu_ol, mcu_oh;
assign mb88_0_o.r_out = {mcu_r3, mcu_r2, mcu_r1, mcu_r0};
assign mb88_0_o.o     = {mcu_oh, mcu_ol};
mb88 #(.IRQ_AFTER_INSN(1)) mb88_0
(
    .clock(clk_12m), .ena(mb88_0_i.ena), .reset_n(mb88_0_i.reset_n), .ram_clr(1'b0),
    .r0_port_in(mb88_0_i.r_in[3:0]), .r1_port_in(mb88_0_i.r_in[7:4]), .r2_port_in(mb88_0_i.r_in[11:8]), .r3_port_in(mb88_0_i.r_in[15:12]),
    .r0_port_out(mcu_r0), .r1_port_out(mcu_r1), .r2_port_out(mcu_r2), .r3_port_out(mcu_r3),
    .k_port_in(mb88_0_i.k), .ol_port_out(mcu_ol), .oh_port_out(mcu_oh), .p_port_out(mb88_0_o.p), .o_wr(mb88_0_o.o_wr),
    .stby_n(1'b1), .tc_n(mb88_0_i.tc_n), .irq_n(mb88_0_i.irq_n), .sc_in_n(1'b1), .si_n(mb88_0_i.si_n),
    .sc_out_n(), .so_n(), .to_n(),
    .rom_addr(mb88_0_o.rom_a), .rom_data(mb88_0_i.rom_d)
);

jt49_bus #(.COMP(3'b010)) ay_0
(
    .rst_n(reset), .clk(clk_12m), .clk_en(ay_0_i.ce), .bdir(ay_0_i.bdir), .bc1(ay_0_i.bc1), .din(ay_0_i.din), .sel(1'b1),
    .dout(ay_0_o.dout), .sound(ay_0_o.sound), .A(ay_0_o.a), .B(ay_0_o.b), .C(ay_0_o.c), .sample(),
    .IOA_in(ay_0_i.ioa_in), .IOA_out(ay_0_o.ioa_out), .IOB_in(ay_0_i.iob_in), .IOB_out(ay_0_o.iob_out)
);

/////////////////////////////  Board RAM pool  /////////////////////////////

ram_pool_pkg::pram_i_t [4:0] pool_i;
ram_pool_pkg::pram_o_t [4:0] pool_o;

dpram_dc #(.widthad_a(11)) ram_0
(
    .clock_a(clk_12m), .wren_a(pool_i[0].a_we), .address_a(pool_i[0].a_addr[10:0]), .data_a(pool_i[0].a_d), .q_a(pool_o[0].a_q),
    .clock_b(clk_12m), .wren_b(pool_i[0].b_we), .address_b(pool_i[0].b_addr[10:0]), .data_b(pool_i[0].b_d), .q_b(pool_o[0].b_q)
);

dpram_dc #(.widthad_a(14)) ram_1
(
    .clock_a(clk_12m), .wren_a(pool_i[1].a_we), .address_a(pool_i[1].a_addr[13:0]), .data_a(pool_i[1].a_d), .q_a(pool_o[1].a_q),
    .clock_b(clk_12m), .wren_b(pool_i[1].b_we), .address_b(pool_i[1].b_addr[13:0]), .data_b(pool_i[1].b_d), .q_b(pool_o[1].b_q)
);

dpram_dc #(.widthad_a(14)) ram_2
(
    .clock_a(clk_12m), .wren_a(pool_i[2].a_we), .address_a(pool_i[2].a_addr[13:0]), .data_a(pool_i[2].a_d), .q_a(pool_o[2].a_q),
    .clock_b(clk_12m), .wren_b(pool_i[2].b_we), .address_b(pool_i[2].b_addr[13:0]), .data_b(pool_i[2].b_d), .q_b(pool_o[2].b_q)
);

dpram_dc #(.widthad_a(14)) ram_3
(
    .clock_a(clk_12m), .wren_a(pool_i[3].a_we), .address_a(pool_i[3].a_addr[13:0]), .data_a(pool_i[3].a_d), .q_a(pool_o[3].a_q),
    .clock_b(clk_12m), .wren_b(pool_i[3].b_we), .address_b(pool_i[3].b_addr[13:0]), .data_b(pool_i[3].b_d), .q_b(pool_o[3].b_q)
);

dpram_dc #(.widthad_a(14)) ram_4
(
    .clock_a(clk_12m), .wren_a(pool_i[4].a_we), .address_a(pool_i[4].a_addr[13:0]), .data_a(pool_i[4].a_d), .q_a(pool_o[4].a_q),
    .clock_b(clk_12m), .wren_b(pool_i[4].b_we), .address_b(pool_i[4].b_addr[13:0]), .data_b(pool_i[4].b_d), .q_b(pool_o[4].b_q)
);

wire       ay_addr_wr, ay_data_wr;
wire [7:0] ay_din;
wire [7:0] ay_ioa, ay_iob;

Arabian_CPU cpu_board
(
    .reset(reset),
    .clk_12m(clk_12m),

    .video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_hsync(video_hsync),
    .video_vsync(video_vsync),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank),
    .ce_pix(ce_pix),

    .dsw1(dsw1),
    .in0(in0),
    .com0(com0), .com1(com1), .com2(com2),
    .com3(com3), .com4(com4), .com5(com5),

    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),
    .ay_din(ay_din),
    .ay_ioa(ay_ioa),
    .ay_iob(ay_iob),

    .z80_0_i(z80_0_i), .z80_0_o(z80_0_o),
    .mb88_0_i(mb88_0_i), .mb88_0_o(mb88_0_o),
    .rom_cpu_a(rom_cpu_a), .rom0_D(rom0_D), .rom1_D(rom1_D), .rom2_D(rom2_D), .rom3_D(rom3_D),
    .mcu_rom_a(mcu_rom_a), .mcu_rom_d(mcu_rom_d),
    .gfx_a(gfx_a), .gfx_lo_q(gfx_lo_q), .gfx_hi_q(gfx_hi_q),
    .pr_i(pool_i), .pr_o(pool_o),

    .pause(pause),
    .crt_flip(crt_flip),

    .hs_access(hs_access),
    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(hs_data_out),
    .hs_write(hs_write)
);

wire signed [15:0] snd_mono;

Arabian_SND snd_board
(
    .reset(reset),
    .clk_12m(clk_12m),

    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),
    .ay_din(ay_din),

    .ay_ioa(ay_ioa),
    .ay_iob(ay_iob),

    .sound_out(snd_mono),

    .ay_0_i(ay_0_i), .ay_0_o(ay_0_o)
);

assign sound_l = snd_mono;
assign sound_r = snd_mono;

endmodule
