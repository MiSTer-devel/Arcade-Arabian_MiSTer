//  Based on MAME arabian.cpp

module Arabian_SND
(
    input         reset,
    input         clk_12m,

    input         ay_addr_wr,
    input         ay_data_wr,
    input   [7:0] ay_din,

    output  [7:0] ay_ioa,
    output  [7:0] ay_iob,

    output signed [15:0] sound_out,

    output chip_pool_pkg::ay_i_t   ay_0_i,
    input  chip_pool_pkg::ayio_o_t ay_0_o
);

reg [2:0] div = 3'd0;
always_ff @(posedge clk_12m) begin
    div <= div + 3'd1;
end
wire cen_1m5 = (div == 3'd0);

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

wire [9:0] ay_sum = {2'b00, ayA_raw} + {2'b00, ayB_raw} + {2'b00, ayC_raw};
wire signed [15:0] ay_signed = {1'b0, ay_sum, 5'd0} - 16'sd12288;

assign sound_out = ay_signed;

endmodule
