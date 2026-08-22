//============================================================================
//
//  Arabian ROM loader
//  ROM layout matched to MAME arabian.cpp
//
//============================================================================

// ROM layout for Arabian:
//
// Index 0 — Main CPU program ROMs (32KB), flat at 0x0000-0x7FFF, no banking:
//   0x0000 - 0x1FFF = ic1rev2.87 (IC1)
//   0x2000 - 0x3FFF = ic2rev2.88 (IC2)
//   0x4000 - 0x5FFF = ic3rev2.89 (IC3)
//   0x6000 - 0x7FFF = ic4rev2.90 (IC4)
//
// Index 2 — Blitter GFX ROMs (32KB), addressed as two 16KB planes:
//   0x0000 - 0x1FFF = tvg-91 (IC84)  \ low plane,  bytes 0x0000-0x3FFF
//   0x2000 - 0x3FFF = tvg-92 (IC85)  /
//   0x4000 - 0x5FFF = tvg-93 (IC86)  \ high plane, bytes 0x4000-0x7FFF
//   0x6000 - 0x7FFF = tvg-94 (IC87)  /
//   A source byte pair (offs, offs+0x4000) yields 4 pixels of 4 bits, so both
//   planes are read at the same offset — see the blitter in Arabian_CPU.sv.
//
// Index 6 — MB8841 (SUN 8212) internal ROM (2KB). No protection PROM on this board.

// Main CPU ROM selector (active during ioctl_index == 0)
module selector
(
    input  logic [24:0] ioctl_addr,
    output logic rom0_cs, rom1_cs, rom2_cs, rom3_cs
);
    always_comb begin
        {rom0_cs, rom1_cs, rom2_cs, rom3_cs} = 0;

        if(ioctl_addr < 'h2000)      rom0_cs = 1;
        else if(ioctl_addr < 'h4000) rom1_cs = 1;
        else if(ioctl_addr < 'h6000) rom2_cs = 1;
        else if(ioctl_addr < 'h8000) rom3_cs = 1;
    end
endmodule

////////////
// EPROMS //
////////////

// Generic 8KB ROM module (13-bit address)
module eprom_8k
(
    input  logic        CLK,
    input  logic        CLK_DL,
    input  logic [12:0] ADDR,
    input  logic [24:0] ADDR_DL,
    input  logic  [7:0] DATA_IN,
    input  logic        CS_DL,
    input  logic        WR,
    output logic  [7:0] DATA
);
    dpram_dc #(.widthad_a(13)) rom
    (
        .clock_a(CLK),
        .address_a(ADDR[12:0]),
        .q_a(DATA[7:0]),

        .clock_b(CLK_DL),
        .address_b(ADDR_DL[12:0]),
        .data_b(DATA_IN),
        .wren_b(WR & CS_DL)
    );
endmodule

// Generic 4KB ROM module (12-bit address)
module eprom_4k
(
    input  logic        CLK,
    input  logic        CLK_DL,
    input  logic [11:0] ADDR,
    input  logic [24:0] ADDR_DL,
    input  logic  [7:0] DATA_IN,
    input  logic        CS_DL,
    input  logic        WR,
    output logic  [7:0] DATA
);
    dpram_dc #(.widthad_a(12)) rom
    (
        .clock_a(CLK),
        .address_a(ADDR[11:0]),
        .q_a(DATA[7:0]),

        .clock_b(CLK_DL),
        .address_b(ADDR_DL[11:0]),
        .data_b(DATA_IN),
        .wren_b(WR & CS_DL)
    );
endmodule
