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

    // Audio output
    output signed [15:0] sound_out
);

//------------------------------------------------------- Clock Enable --------------------------------------------------------//

// AY-3-8910 runs at MAIN_OSC/4/2 = 1.5 MHz
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

jt49_bus #(.COMP(3'b010)) ay_chip
(
    .rst_n(reset),
    .clk(clk_12m),
    .clk_en(cen_1m5),
    .bdir(ay_bdir),
    .bc1(ay_bc1),
    .din(ay_din),
    .sel(1'b1),        // No additional clock division
    .A(ayA_raw),
    .B(ayB_raw),
    .C(ayC_raw),
    .IOA_in(8'h00),
    .IOA_out(ay_ioa),
    .IOB_in(8'h00),
    .IOB_out(ay_iob)
);

//----------------------------------------------------- Final Audio Output -----------------------------------------------------//

// Sum the three unsigned 8-bit channels and centre as signed 16-bit.
// MAME: AY8910 routes ALL_OUTPUTS to mono at 0.50
wire [9:0] ay_sum = {2'b00, ayA_raw} + {2'b00, ayB_raw} + {2'b00, ayC_raw};
wire signed [15:0] ay_signed = {1'b0, ay_sum, 5'd0} - 16'sd12288;

assign sound_out = ay_signed;

endmodule
