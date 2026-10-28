//============================================================================
//
//  Arabian Sound
//  Based on MAME arabian.cpp
//
//  There is no sound CPU on this board. The main Z80 drives the AY-3-8910
//  directly over I/O space (mirror $01FF, so decoded on A15-A9):
//    OUT ($C800) = register select
//    OUT ($CA00) = register data
//
//  Both AY I/O ports are wired as outputs and used as control registers:
//    Port A  b7 ENA  b6 ENB  b5 /ABHF  b4 /AGHF  b3 /ARHF   (video control)
//    Port B  b5 /IREQ to MCU  b4 /SRES to MCU  b1,b0 coin counters
//
//============================================================================

module Arabian_SND
(
    input         reset,
    input         clk_12m,

    // AY-3-8910 bus, driven by the main Z80 over I/O space
    input         ay_addr_wr,      // OUT to $C800: register select
    input         ay_data_wr,      // OUT to $CA00: register data
    input   [7:0] ay_din,

    // AY I/O ports — outputs on this board
    output  [7:0] ay_ioa,
    output  [7:0] ay_iob,

    output signed [15:0] sound_out,

    // shared AY-3-8910 (pool slot ay_0, rtl/arabian_board.sv)
    output chip_pool_pkg::ay_i_t   ay_0_i,
    input  chip_pool_pkg::ayio_o_t ay_0_o
);

//------------------------------------------------------- Clock Enable --------------------------------------------------------//

// AY-3-8910 at 12 MHz / 8 = 1.5 MHz
reg [2:0] div = 3'd0;
always_ff @(posedge clk_12m) begin
    div <= div + 3'd1;
end
wire cen_1m5 = (div == 3'd0);

//------------------------------------------------------- AY-3-8910 -----------------------------------------------------------//

// bdir/bc1: 11 = latch register address, 10 = write register data, 00 = inactive
wire ay_bdir = ay_addr_wr | ay_data_wr;
wire ay_bc1  = ay_addr_wr;

wire [7:0] ayA_raw, ayB_raw, ayC_raw;

assign ay_0_i.ce     = cen_1m5;
assign ay_0_i.bdir   = ay_bdir;
assign ay_0_i.bc1    = ay_bc1;
assign ay_0_i.din    = ay_din;
assign ay_0_i.ioa_in = 8'h00;
assign ay_0_i.iob_in = 8'h00;
assign ayA_raw = ay_0_o.a;
assign ayB_raw = ay_0_o.b;
assign ayC_raw = ay_0_o.c;
assign ay_ioa  = ay_0_o.ioa_out;
assign ay_iob  = ay_0_o.iob_out;

//----------------------------------------------------- Final Audio Output -----------------------------------------------------//

// Sum the three unsigned 8-bit channels and centre as signed 16-bit.
// MAME: AY8910 routes ALL_OUTPUTS to mono at 0.50
wire [9:0] ay_sum = {2'b00, ayA_raw} + {2'b00, ayB_raw} + {2'b00, ayC_raw};
wire signed [15:0] ay_signed = {1'b0, ay_sum, 5'd0} - 16'sd12288;

assign sound_out = ay_signed;

endmodule
