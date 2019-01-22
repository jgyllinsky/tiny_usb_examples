module top(
  input  pin_clk,

  inout  pin_usbp,
  inout  pin_usbn,
  output pin_pu,

  output reg pin_led,
  output reg [7:0] leds
);

  ////////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////////
  ////////
  //////// generate 48 mhz clock
  ////////
  ////////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////////
  wire clk_48mhz;

  SB_PLL40_CORE #(
    .DIVR(4'b0000),
    .DIVF(7'b0101111),
    .DIVQ(3'b100),
    .FILTER_RANGE(3'b001),
    .FEEDBACK_PATH("SIMPLE"),
    .DELAY_ADJUSTMENT_MODE_FEEDBACK("FIXED"),
    .FDA_FEEDBACK(4'b0000),
    .DELAY_ADJUSTMENT_MODE_RELATIVE("FIXED"),
    .FDA_RELATIVE(4'b0000),
    .SHIFTREG_DIV_MODE(2'b00),
    .PLLOUT_SELECT("GENCLK"),
    .ENABLE_ICEGATE(1'b0)
  ) usb_pll_inst (
    .REFERENCECLK(pin_clk),
    .PLLOUTCORE(clk_48mhz),
    .PLLOUTGLOBAL(),
    .EXTFEEDBACK(),
    .RESETB(1'b1),
    .BYPASS(1'b0),
    .LATCHINPUTVALUE(),
    .LOCK(),
    .SDI(),
    .SDO(),
    .SCLK()
  );

  //assign leds = uart_reg_dat_do;

  reg clk_24mhz = 0;

  always @(posedge clk_48mhz) clk_24mhz <= ~clk_24mhz;

  reg [25:0] reset_cnt = 0;
  wire resetn = &reset_cnt;

  always @(posedge clk_24mhz) begin
      reset_cnt <= reset_cnt + !resetn;
  end

  parameter integer MEM_WORDS = 3584;
  parameter [31:0] STACKADDR = 32'h 0000_0000 + (4*MEM_WORDS);       // end of memory
  parameter [31:0] PROGADDR_RESET = 32'h 0000_0000;       // start of memory

  reg [31:0] ram [0:MEM_WORDS-1];
  initial $readmemh("firmware.hex", ram);
  reg [31:0] ram_rdata;
  reg ram_ready;

  wire mem_valid;
  wire mem_instr;
  wire mem_ready;
  wire [31:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [3:0] mem_wstrb;
  wire [31:0] mem_rdata;

  wire uart_reg_dat_wait;
  wire [7:0] uart_reg_dat_do;

  always @(posedge clk_24mhz) begin
    ram_ready <= 1'b0;
    leds <= {mem_valid, mem_ready, uart_reg_dat_sel, uart_reg_dat_wait, uart_reg_dat_do[3:0]};
    if (mem_addr[31:24] == 8'h00 && mem_valid) begin
      if (mem_wstrb[0]) ram[mem_addr[23:2]][7:0] <= mem_wdata[7:0];
      if (mem_wstrb[1]) ram[mem_addr[23:2]][15:8] <= mem_wdata[15:8];
      if (mem_wstrb[2]) ram[mem_addr[23:2]][23:16] <= mem_wdata[23:16];
      if (mem_wstrb[3]) ram[mem_addr[23:2]][31:24] <= mem_wdata[31:24];

        ram_rdata <= ram[mem_addr[23:2]];
        ram_ready <= 1'b1;
    end
  end

  wire iomem_valid;
  reg iomem_ready;
  wire [31:0] iomem_addr;
  wire [31:0] iomem_wdata;
  wire [3:0] iomem_wstrb;
  wire [31:0] iomem_rdata;

  assign iomem_valid = mem_valid && (mem_addr[31:24] > 8'h01);
  assign iomem_wstrb = mem_wstrb;
  assign iomem_addr = mem_addr;
  assign iomem_wdata = mem_wdata;

  wire uart_reg_dat_sel = mem_valid && (mem_addr == 32'h 0200_0008);
  reg uart_reg_dat_sel1;

  always @(posedge clk_24mhz) begin
    uart_reg_dat_sel1 <= uart_reg_dat_sel;
    iomem_ready <= 1'b0;
    if (iomem_valid && iomem_wstrb[0] && mem_addr == 32'h 0200_0000) begin
      pin_led <= iomem_wdata[0];
      iomem_ready <= 1'b1;
    end
  end

  assign mem_ready = (iomem_valid && iomem_ready) ||
         (uart_reg_dat_sel && !uart_reg_dat_wait) ||
	 ram_ready;

  assign mem_rdata = uart_reg_dat_sel ? uart_reg_dat_do : ram_rdata;

  picorv32 #(
    .STACKADDR(STACKADDR),
    .PROGADDR_RESET(PROGADDR_RESET),
    .PROGADDR_IRQ(32'h 0000_0000),
    .BARREL_SHIFTER(0),
    .COMPRESSED_ISA(0),
    .ENABLE_MUL(1),
    .ENABLE_DIV(0),
    .ENABLE_IRQ(0),
    .ENABLE_IRQ_QREGS(0)
  ) cpu (
    .clk         (clk_24mhz  ),
    .resetn      (resetn     ),
    .mem_valid   (mem_valid  ),
    .mem_instr   (mem_instr  ),
    .mem_ready   (mem_ready  ),
    .mem_addr    (mem_addr   ),
    .mem_wdata   (mem_wdata  ),
    .mem_wstrb   (mem_wstrb  ),
    .mem_rdata   (mem_rdata  )
  );

  // usb uart
  usb_uart uart (
    .clk_48mhz  (clk_48mhz),
    .resetn     (resetn),

    .usb_p_tx(usb_p_tx),
    .usb_n_tx(usb_n_tx),
    .usb_p_rx(usb_p_rx),
    .usb_n_rx(usb_n_rx),
    .usb_tx_en(usb_tx_en),

    .uart_we  (uart_reg_dat_sel && mem_wstrb[0]),
    .uart_re  (uart_reg_dat_sel && !mem_wstrb[0]),
    .uart_di  (mem_wdata[7:0]),
    .uart_do  (uart_reg_dat_do),
    .uart_wait(uart_reg_dat_wait)
  );

  wire usb_p_tx;
  wire usb_n_tx;
  wire usb_p_rx;
  wire usb_n_rx;
  wire usb_tx_en;
  wire usb_p_in;
  wire usb_n_in;

  assign pin_pu = 1'b1;
  assign usb_p_rx = usb_tx_en ? 1'b1 : usb_p_in;
  assign usb_n_rx = usb_tx_en ? 1'b0 : usb_n_in;

  SB_IO #(
    .PIN_TYPE(6'b 1010_01), // PIN_OUTPUT_TRISTATE - PIN_INPUT
    .PULLUP(1'b 0)
  ) 
  iobuf_usbp 
  (
    .PACKAGE_PIN(pin_usbp),
    .OUTPUT_ENABLE(usb_tx_en),
    .D_OUT_0(usb_p_tx),
    .D_IN_0(usb_p_in)
  );

  SB_IO #(
    .PIN_TYPE(6'b 1010_01), // PIN_OUTPUT_TRISTATE - PIN_INPUT
    .PULLUP(1'b 0)
  ) 
  iobuf_usbn 
  (
    .PACKAGE_PIN(pin_usbn),
    .OUTPUT_ENABLE(usb_tx_en),
    .D_OUT_0(usb_n_tx),
    .D_IN_0(usb_n_in)
  );

endmodule

// Implementation note:
// Replace the following two modules with wrappers for your SRAM cells.

module picosoc_regs (
	input clk, wen,
	input [5:0] waddr,
	input [5:0] raddr1,
	input [5:0] raddr2,
	input [31:0] wdata,
	output [31:0] rdata1,
	output [31:0] rdata2
);
	reg [31:0] regs [0:31];

	always @(posedge clk)
		if (wen) regs[waddr[4:0]] <= wdata;

	assign rdata1 = regs[raddr1[4:0]];
	assign rdata2 = regs[raddr2[4:0]];
endmodule