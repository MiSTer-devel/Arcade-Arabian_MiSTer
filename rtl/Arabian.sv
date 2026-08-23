//============================================================================
//
//  Arabian top-level module
//  Copyright (C) 2026 Rodimus
//  Based on MAME arabian.cpp by Dan Boris
//
//============================================================================

module Arabian
(
    input                reset,
    input                clk_12m,

    // Player inputs (active HIGH, per MAME port definitions)
    input          [2:0] in0,              // $C000: {service, coin2, coin1}
    input          [7:0] dsw1,             // SW1 at $C200
    // Six 4-bit banks scanned by the MB8841 K port
    input          [3:0] com0, com1, com2, com3, com4, com5,

    // Video outputs
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    // Audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ROM loading
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,

    // Hiscore
    input                hs_access,
    input         [15:0] hs_address,
    input          [7:0] hs_data_in,
    output         [7:0] hs_data_out,
    input                hs_write
);

//------------------------------------------------------- ROM Selectors -------------------------------------------------------//

// Main CPU ROMs (index 0) — 4 x 8KB, flat 0x0000-0x7FFF
wire rom0_cs, rom1_cs, rom2_cs, rom3_cs;
wire idx0_wr = ioctl_wr & (ioctl_index == 8'd0);
selector main_sel
(
    .ioctl_addr(ioctl_addr),
    .rom0_cs(rom0_cs), .rom1_cs(rom1_cs), .rom2_cs(rom2_cs), .rom3_cs(rom3_cs)
);

// MCU ROM (index 6: MB8841 prog 0x000-0x7FF)
wire idx6_wr = ioctl_wr & (ioctl_index == 8'd6);

// Blitter GFX ROM (index 2) — one flat 32KB image, split into planes inside the CPU board
wire idx2_wr = ioctl_wr & (ioctl_index == 8'd2);

//------------------------------------------------------- CPU Board -----------------------------------------------------------//

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

    .rom0_cs_i(rom0_cs & idx0_wr),
    .rom1_cs_i(rom1_cs & idx0_wr),
    .rom2_cs_i(rom2_cs & idx0_wr),
    .rom3_cs_i(rom3_cs & idx0_wr),

    .gfx_cs_i(idx2_wr),

    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .mcurom_wr(idx6_wr),

    .pause(pause),

    .hs_access(hs_access),
    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(hs_data_out),
    .hs_write(hs_write)
);

//------------------------------------------------------- Sound Board ---------------------------------------------------------//

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

    .sound_out(snd_mono)
);

// Mono → stereo
assign sound_l = snd_mono;
assign sound_r = snd_mono;

endmodule
