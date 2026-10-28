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

wire        art_fb;                // artwork framebuffer on HDMI: square canvas pixels
wire        art_ioctl_wait, art_avail;
wire [11:0] art_cw, art_ch;
assign VIDEO_ARX = (!ar) ? (art_fb ? art_cw : status[12] ? 12'd4 : 12'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (art_fb ? art_ch : status[12] ? 12'd3 : 12'd4) : 12'd0;

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
	"H1P4,Game Options;",
	"H1P4-,Artwork (MAME layout views);",
	"H1P4O[50:48],View,Off,View 1,View 2,View 3,View 4,View 5,View 6,View 7;",
	"H1P4O[51],Backdrop,On,Off;",
	"H1P4O[52],Overlay,On,Off;",
	"H1P4O[53],Bezel,On,Off;",
	"H1P4O[56],Control Panel,On,Off;",
	"H1P4O[54],Side Art,On,Off;",
	"H1P4O[55],Zoom to Screen,Off,On;",
	"H1-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button1,Button2,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr27;                     // hps_io's full address: the artwork download can pass 32 MB
wire [24:0] ioctl_addr = ioctl_addr27[24:0];  // every other ioctl user
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;

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
	.status_menumask({~art_avail, direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr27),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(art_ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////
wire CLK_40M;                       // video back end + artwork (same VCO as CLK_12M)
wire CLK_12M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_40M),
    .outclk_1(CLK_12M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_40M;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

///////////////////         Keyboard           //////////////////

// kb: [0] up [1] down [2] left [3] right [4] Ctrl [5] Alt [6] 1 [7] 2 [8] 5 [9] 6 [10] 9 [11] T [12] P
// kbx: [0] F2 service switch, [1] left Shift (Draw Fast, not wired to the board)
/* verilator lint_off UNUSED */
wire [12:0] kb;                     // Alt and T are not used on this board
wire  [1:0] kbx;
/* verilator lint_on UNUSED */
wire btn_up         = kb[0];
wire btn_down       = kb[1];
wire btn_left       = kb[2];
wire btn_right      = kb[3];
wire btn_fire       = kb[4];
wire btn_coin1      = kb[8];
wire btn_coin2      = kb[9];
wire btn_1p_start   = kb[6];
wire btn_2p_start   = kb[7];
wire btn_pause      = kb[12];
wire btn_service    = kb[10];
wire btn_service_sw = kbx[0];

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

// service inputs
wire m_service    = btn_service;      // AUX-S (key 9) -> COM0 bit3
wire m_service_sw = btn_service_sw;   // service switch (F2) -> IN0 bit2

// PAUSE SYSTEM
wire pause_cpu;
// keyboard (see Keyboard above); held keys keep tracking while paused
ctl_keyboard #(.NX(2), .NXO(2), .XKEYS({24'h10_12_01, 24'h10_06_00})) u_kb(.clk(CLK_12M), .ps2_key(ps2_key),
	.pause(pause_cpu), .kb(kb), .kbx(kbx));
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
wire bd_ce;                        // board pixel enable (CLK_12M)
wire ce_pix;                       // CLK_40M pixel enable (art_xclk)

// video back end on CLK_40M: art_xclk -> artwork -> screen_rotate / arcade_video. The board, pause and hiscore stay on
// CLK_12M; art_xclk moves the pixels and the artwork download across (related clocks: plain timed register paths).
wire  [7:0] av_r, av_g, av_b;      // artwork output: the board picture one pixel late, artwork applied
wire        av_hs, av_vs, av_hbl, av_vbl;
wire [27:0] v_px;
wire        a_wr;
wire [26:0] a_addr;
wire  [7:0] a_dout;
wire        art_wait;
art_xclk #(.IDX(8'd5), .VW(28)) art_xclk
(
	.clk_sys(CLK_12M), .clk_art(CLK_40M),
	.bd_ce(bd_ce), .bd_px({hs, vs, hblank, vblank, rgb_out}), .ce_art(ce_pix), .px(v_px),
	.ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr27), .ioctl_dout(ioctl_dout),
	.ioctl_wait(art_ioctl_wait), .a_wr(a_wr), .a_addr(a_addr), .a_dout(a_dout), .art_wait(art_wait)
);

// MAME artwork (OSD Game Options page): native composite on the core video (one pixel late), full view through the
// DDR3 framebuffer on HDMI
wire        art_run, art_ddr;
wire [31:0] art_fb_base;
wire  [7:0] art_burstcnt, art_be;
wire [28:0] art_addr;
wire [63:0] art_din;
wire        art_rd, art_we;
artwork #(.IDX(8'd5)) artwork
(
	.clk(CLK_40M),
	.sel({1'b0, status[50:48]}), .layer_off({status[56], status[53:51]}), .side_off(status[54]), .zoom(status[55]),
	.crt_flip(status[22]), .hdmi_flip(status[11]), .turn(status[12]), .avail(art_avail),
	.hdmi_w(HDMI_WIDTH), .hdmi_h(HDMI_HEIGHT),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(a_wr),
	.ioctl_addr(a_addr), .ioctl_dout(a_dout), .ioctl_wait(art_wait),
	.ce_pix(ce_pix),
	.hs_in(v_px[27]), .vs_in(v_px[26]), .hblank_in(v_px[25]), .vblank_in(v_px[24]), .rgb_in(v_px[23:0]),
	.hs_out(av_hs), .vs_out(av_vs), .hblank_out(av_hbl), .vblank_out(av_vbl), .rgb_out({av_r, av_g, av_b}),
	.running(art_run), .ddr_owner(art_ddr), .canvas_w(art_cw), .canvas_h(art_ch),
	.fb_base(art_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(art_burstcnt), .DDRAM_ADDR(art_addr),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(art_rd),
	.DDRAM_DIN(art_din), .DDRAM_BE(art_be), .DDRAM_WE(art_we)
);
// Orientation Horz (rotated monitor): the artwork turns its own view, so it keeps the framebuffer
assign art_fb = art_run & ~direct_video;

// one pixel per source pixel, 256 across
wire rotate_ccw = 1;  // Arabian is ROT270 (CCW)
wire no_rotate = status[12] | direct_video;
wire flip = status[11] | ~no_rotate;
wire        sr_fb_en, sr_clk, sr_rd, sr_we;
wire  [4:0] sr_fb_format;
wire [11:0] sr_fb_w, sr_fb_h;
wire [31:0] sr_fb_base;
wire [13:0] sr_fb_stride;
wire  [7:0] sr_burstcnt, sr_be;
wire [28:0] sr_addr;
wire [63:0] sr_din;
screen_rotate screen_rotate
(
	.*,
	.FB_EN(sr_fb_en), .FB_FORMAT(sr_fb_format), .FB_WIDTH(sr_fb_w), .FB_HEIGHT(sr_fb_h),
	.FB_BASE(sr_fb_base), .FB_STRIDE(sr_fb_stride),
	.DDRAM_CLK(sr_clk), .DDRAM_BURSTCNT(sr_burstcnt), .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(sr_rd)
);

// the artwork takes the framebuffer while it draws, and DDR3 while it loads or draws
assign FB_EN     = art_fb | sr_fb_en;
assign FB_FORMAT = art_fb ? 5'b00110  : sr_fb_format;
assign FB_WIDTH  = art_fb ? art_cw    : sr_fb_w;
assign FB_HEIGHT = art_fb ? art_ch    : sr_fb_h;
assign FB_BASE   = art_fb ? art_fb_base : sr_fb_base;
assign FB_STRIDE = art_fb ? 14'd8192  : sr_fb_stride;
assign DDRAM_CLK      = CLK_40M;
assign DDRAM_BURSTCNT = art_ddr ? art_burstcnt : sr_burstcnt;
assign DDRAM_ADDR     = art_ddr ? art_addr : sr_addr;
assign DDRAM_DIN      = art_ddr ? art_din : sr_din;
assign DDRAM_BE       = art_ddr ? art_be : sr_be;
assign DDRAM_WE       = art_ddr ? art_we : sr_we;
assign DDRAM_RD       = art_ddr ? art_rd : sr_rd;

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_40M),

	.RGB_in({av_r, av_g, av_b}),
	.HBlank(av_hbl),
	.VBlank(av_vbl),
	.HSync(av_hs),
	.VSync(av_vs),

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
arabian_dispatcher arabian_inst
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
	.ce_pix(bd_ce),

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
