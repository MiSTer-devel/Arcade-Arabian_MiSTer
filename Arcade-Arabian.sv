//============================================================================
//
// Arabian for MiSTer
// Copyright (C) 2026 Rodimus
// Based on Tutankham core structure
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio_l;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0; // no mix, true stereo

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

wire [1:0] ar = status[14:13];

assign VIDEO_ARX = status[12] ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = status[12] ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"ARABIAN;;",
	"P1,Video Options;",
	"P1ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"P2,Pause Options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"P3,High Score Options;",
	"P3OR,Autosave Hiscores,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button1,Button2,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [31:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_12M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////
wire CLK_60M;
wire CLK_12M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_60M),
    .outclk_1(CLK_12M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_60M;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

///////////////////         Keyboard           //////////////////

reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_fire     = 0;
reg btn_fire2    = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;
reg btn_service  = 0;
reg btn_service_sw = 0;

wire pressed = ~ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge CLK_12M) begin
	reg old_state;
	old_state <= ps2_key[10];
	if(old_state != ps2_key[10]) begin
		case(code)
			'h16: btn_1p_start <= pressed; // 1 = Player 1 Start
			'h1E: btn_2p_start <= pressed; // 2 = Player 2 Start
			'h2E: btn_coin1    <= pressed; // 5 = Coin Input 1
			'h36: btn_coin2    <= pressed; // 6 = Coin Input 2
			'h4D: btn_pause    <= pressed; // P = Pause
			'h46: btn_service    <= pressed; // 9 = AUX-S (IPT_SERVICE1)
			'h06: btn_service_sw <= pressed; // F2 = Service switch

			'h75: btn_up       <= pressed; // up         = Up
			'h72: btn_down     <= pressed; // down       = Down
			'h6B: btn_left     <= pressed; // left       = Left
			'h74: btn_right    <= pressed; // right      = Right
			'h14: btn_fire     <= pressed; // ctrl       = Draw Slow
			'h12: btn_fire2    <= pressed; // left shift = Draw Fast
		endcase 
	end
end

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

//Player 1 — COM1 (8-way) and COM2 (one button)
wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_btn1     = btn_fire      | joystick_0[4];

//Player 2 — COM3/COM4, the cocktail set
wire m_up2      = joystick_1[3];
wire m_down2    = joystick_1[2];
wire m_left2    = joystick_1[1];
wire m_right2   = joystick_1[0];
wire m_btn2     = joystick_1[4];

//Start/Coin
// Bit order follows the MRA <buttons names=".."> list, starting at joystick bit 4:
// 4 Kick · 5 Coin · 6 Start 1P · 7 Start 2P · 8 Pause
wire m_coin1    = btn_coin1     | joystick_0[5];
wire m_coin2    = btn_coin2     | joystick_1[5];
wire m_start1   = btn_1p_start  | joystick_0[6];
wire m_start2   = btn_2p_start  | joystick_0[7];
wire m_pause    = btn_pause     | joystick_0[8];

//Service inputs — MAME keeps these separate
wire m_service    = btn_service;      // AUX-S, IPT_SERVICE1 (key 9) -> COM0 bit3
wire m_service_sw = btn_service_sw;   // service switch (F2) -> IN0 bit2

// PAUSE SYSTEM
wire pause_cpu;
wire [23:0] rgb_out;
pause #(8,8,8,10) pause
(
	.*,
	.clk_sys(CLK_12M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

// One pixel per source pixel, 256 across — no Kangaroo-style doubling on this board.
wire rotate_ccw = 1;  // Arabian is ROT270 (CCW)
wire no_rotate = status[12] | direct_video;
wire flip = status[11] | ~no_rotate;
screen_rotate screen_rotate(.*);

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_60M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[17:15])
);

// DIP switches arrive from the OSD via ioctl index 254, not status.
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_12M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [7:0] sw1 = dip_sw[0];        // SW1, read directly by the Z80 at $C200
wire [3:0] sw2 = dip_sw[1][3:0];   // SW2, reaches the CPU through the MB8841 COM5 scan

//Instantiate Arabian top-level game module
Arabian arabian_inst
(
	.reset(~reset),       // MiSTer reset is active-high; invert for active-low game modules

	.clk_12m(CLK_12M),

	// Read directly by the Z80 at $C000 / $C200
	.in0({m_service_sw, m_coin2, m_coin1}),
	.dsw1(sw1),

	// Scanned by the MB8841. COM0 bit0 is an unused active-low input, so it reads 1.
	.com0({m_service, m_start2, m_start1, 1'b1}),
	.com1({m_down1, m_up1, m_left1, m_right1}),
	.com2({3'b000, m_btn1}),
	.com3({m_down2, m_up2, m_left2, m_right2}),
	.com4({3'b000, m_btn2}),
	.com5(sw2),

	.video_hsync(hs),
	.video_vsync(vs),
	.video_vblank(vblank),
	.video_hblank(hblank),
	.ce_pix(ce_pix),

	.video_r(r),
	.video_g(g),
	.video_b(b),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),

	.pause(pause_cpu),
	.crt_flip(status[22]),

	.hs_access(hs_access),
	.hs_address(hs_address),
	.hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out),
	.hs_write(hs_write_enable)
);

// HISCORE SYSTEM — config = MRA index 3, dump = index 4. Score data lives in the MB8841
// shared RAM, so hs_access borrows the MCU's port while the module has the CPU paused.
wire [15:0] hs_address;
wire  [7:0] hs_data_in;
wire  [7:0] hs_data_out;
wire        hs_write_enable;
wire        hs_access_read;
wire        hs_access_write;
wire        hs_pause;
wire        hs_configured;

wire        hs_access = hs_access_read | hs_access_write;

hiscore #(
	.HS_ADDRESSWIDTH(16),
	.CFG_ADDRESSWIDTH(3),
	.CFG_LENGTHWIDTH(2)
) hi (
	.*,
	.clk(CLK_12M),
	.paused(pause_cpu),
	.autosave(status[27]),
	.ram_address(hs_address),
	.data_from_ram(hs_data_out),
	.data_to_ram(hs_data_in),
	.data_from_hps(ioctl_dout),
	.data_to_hps(ioctl_din),
	.ram_write(hs_write_enable),
	.ram_intent_read(hs_access_read),
	.ram_intent_write(hs_access_write),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

endmodule
