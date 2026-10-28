//============================================================================
//  board_template.sv - start a new Arabian-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/arabian_dispatcher.sv: Z80 z80_0, MB8841 mb88_0, AY-3-8910 ay_0 (chip_pool_pkg buses), the shared ROM blocks
//  (eprom_8k rom0-3 on index 0, mcu_prog on index 6, gfx_plane_lo / _hi on index 2) and the 5 board RAM pool blocks
//  (ram_pool_pkg: 0 = shared MB8841 RAM 2K (port B = MCU / hiscore), 1-4 = VRAM byte lanes 16K).
//  To add a board: copy this file to rtl/boards/<board>/<board>.sv, add it to files.qip + verilator/Makefile, instance
//  it in the dispatcher, put its buses on variant muxes (z80_0_i, mb88_0_i, ay_0_i, pool_i, ROM read addresses) and tie
//  the pool blocks it doesn't use to '0. A RAM bigger than its block = grow the block, never a private dpram_dc.
//  ROM images: an index window + a read port exported to the dispatcher (load decode by the download address only).
//  A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its instance line + a Pool contract row
//  (Claude/ vault note). verilator/common/pool_check.sh (POOL_MODS in verilator/Makefile) enforces it.
//============================================================================

module board_template
(
    input  logic        clk_12m,
    input  logic        reset,          // active low, as Arabian_CPU / Arabian_SND
    input  logic        pause,

    // shared Z80 / MB8841 / AY (pool slots z80_0, mb88_0, ay_0)
    output chip_pool_pkg::z80_i_t   z80_0_i,
    input  chip_pool_pkg::z80_o_t   z80_0_o,
    output chip_pool_pkg::mb88_i_t  mb88_0_i,
    input  chip_pool_pkg::mb88_o_t  mb88_0_o,
    output chip_pool_pkg::ay_i_t    ay_0_i,
    input  chip_pool_pkg::ayio_o_t  ay_0_o,

    // shared ROM blocks (read ports)
    output logic [12:0] rom_cpu_a,
    input  logic  [7:0] rom0_D,

    // board RAM pool (rtl/ram_pool_pkg.sv): 5 blocks, tie the unused ones to '0
    output ram_pool_pkg::pram_i_t [4:0] pr_i,
    input  ram_pool_pkg::pram_o_t [4:0] pr_o,

    input  logic  [7:0] dsw1,

    output logic        ce_pix,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hsync,
    output logic        video_vsync,
    output logic        video_hblank,
    output logic        video_vblank,
    output logic signed [15:0] sound_out
);

endmodule
