//////////////////////////////////////////////////////////////////////
////                                                              ////
//// WISHBONE SD Card Controller IP Core                          ////
////                                                              ////
//// sd_data_serial_host.v                                        ////
////                                                              ////
//// This file is part of the WISHBONE SD Card                    ////
//// Controller IP Core project                                   ////
//// http://opencores.org/project,sd_card_controller              ////
////                                                              ////
//// Description                                                  ////
//// Module resposible for sending and receiving data through     ////
//// 4-bit sd card data interface                                 ////
////                                                              ////
//// Author(s):                                                   ////
////     - Marek Czerski, ma.czerski@gmail.com                    ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
//// Copyright (C) 2013 Authors                                   ////
////                                                              ////
//// Based on original work by                                    ////
////     Adam Edvardsson (adam.edvardsson@orsoc.se)               ////
////                                                              ////
////     Copyright (C) 2009 Authors                               ////
////                                                              ////
//// This source file may be used and distributed without         ////
//// restriction provided that this copyright statement is not    ////
//// removed from the file and that any derivative work contains  ////
//// the original copyright notice and the associated disclaimer. ////
////                                                              ////
//// This source file is free software; you can redistribute it   ////
//// and/or modify it under the terms of the GNU Lesser General   ////
//// Public License as published by the Free Software Foundation; ////
//// either version 2.1 of the License, or (at your option) any   ////
//// later version.                                               ////
////                                                              ////
//// This source is distributed in the hope that it will be       ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied   ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      ////
//// PURPOSE. See the GNU Lesser General Public License for more  ////
//// details.                                                     ////
////                                                              ////
//// You should have received a copy of the GNU Lesser General    ////
//// Public License along with this source; if not, download it   ////
//// from http://www.opencores.org/lgpl.shtml                     ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
`include "sd_defines.h"

module sd_data_serial_host(
           input 			 sd_clk,
           input 			 rst,
           //Tx Fifo
           input [31:0] 		 data_in,
           output reg 			 rd,
           //Rx Fifo
           output reg [31:0] 		 data_out,
           output reg 			 we,
           //tristate data
           output reg 			 DAT_oe_o,
           output reg [3:0] 		 DAT_dat_o,
           input [3:0] 			 DAT_dat_i,
           //Control signals
           input [`BLKSIZE_W-1:0] 	 blksize,
           input 			 bus_4bit,
           input [`BLKCNT_W-1:0] 	 blkcnt,
           input [1:0] 			 start,
           input [1:0] 			 byte_alignment,
	   input [31:0] 		 timeout_i,
           output 			 sd_data_busy,
           output 			 busy,
           output reg 			 crc_ok,
           output reg 			 finish_o,
	   output reg [31:0] 		 wait_reg_o,
	   output reg [`BLKSIZE_W-1+4:0] transf_cnt_o
       );

reg [3:0] DAT_dat_reg;
reg [`BLKSIZE_W-1+4:0] data_cycles;
reg bus_4bit_reg;
//CRC16
reg [3:0] crc_in;
reg crc_en;
reg crc_rst;
wire [15:0] crc_out [3:0];
parameter SIZE = 7;
reg [SIZE-1:0] state;
reg [SIZE-1:0] next_state;
parameter IDLE       = 7'b0000001;
parameter WRITE_DAT  = 7'b0000010;
parameter WRITE_CRC  = 7'b0000100;
parameter WRITE_BUSY = 7'b0001000;
parameter READ_WAIT  = 7'b0010000;
parameter READ_DAT   = 7'b0100000;
parameter FINISH     = 7'b1000000;
reg [2:0] crc_status;
reg busy_int;
reg [`BLKCNT_W-1:0] blkcnt_reg;
reg [1:0] byte_alignment_reg;
reg [`BLKSIZE_W-1:0] blksize_reg;
reg next_block;
wire start_bit;
reg [4:0] crc_c;
reg [3:0] last_din;
reg [2:0] crc_s ;
reg [4:0] data_index;

//sd data input pad register
always @(posedge sd_clk)
    DAT_dat_reg <= DAT_dat_i;

genvar i;
generate
    for(i=0; i<4; i=i+1) begin: CRC_16_gen
        sd_crc_16 CRC_16_i (crc_in[i],crc_en, sd_clk, crc_rst, crc_out[i]);
    end
endgenerate

assign busy = (state != IDLE) && (state != FINISH);
assign start_bit = !DAT_dat_reg[0];
assign sd_data_busy = !DAT_dat_reg[0];

always @(state or start or start_bit or  transf_cnt_o or data_cycles or crc_status or crc_ok or busy_int or next_block or wait_reg_o or timeout_i)
begin: FSM_COMBO
    case(state)
        IDLE: begin
            if (start == 2'b01)
                next_state = WRITE_DAT;
            else if  (start == 2'b10)
                next_state = READ_WAIT;
            else
                next_state = IDLE;
        end
        WRITE_DAT: begin
            if (transf_cnt_o >= data_cycles+21 && start_bit)
                next_state = WRITE_CRC;
            else
                next_state = WRITE_DAT;
        end
        WRITE_CRC: begin
            if (crc_status == 3)
                next_state = WRITE_BUSY;
            else
                next_state = WRITE_CRC;
        end
        WRITE_BUSY: begin
            if (!busy_int && next_block && crc_ok)
                next_state = WRITE_DAT;
            else if (!busy_int)
                next_state = FINISH;
            else
                next_state = WRITE_BUSY;
        end
        READ_WAIT: begin
            if ((wait_reg_o >= 3) && start_bit) begin // allow time for bus to change direction
                next_state = READ_DAT;
            end
            else if (wait_reg_o >= timeout_i) begin // prevent hang if card did not respond
                next_state = FINISH;
            end
            else begin
                next_state = READ_WAIT;
            end
        end
        READ_DAT: begin
            if (transf_cnt_o == data_cycles+17 && next_block && crc_ok)
                next_state = READ_WAIT;
            else if (transf_cnt_o == data_cycles+17)
                next_state = FINISH;
            else
                next_state = READ_DAT;
        end
        FINISH:
	    if (start != 2'b00)
              next_state = FINISH;
            else
              next_state = IDLE;
        default: next_state = IDLE;
    endcase
    //abort
    if (start == 2'b11)
        next_state = IDLE;
end

always @(posedge sd_clk or posedge rst)
begin: FSM_OUT
    if (rst) begin
        state <= IDLE;
        DAT_oe_o <= 0;
        crc_en <= 0;
        crc_rst <= 1;
        transf_cnt_o <= 0;
        crc_c <= 15;
        rd <= 0;
        last_din <= 0;
        crc_c <= 0;
        crc_in <= 0;
        DAT_dat_o <= 0;
        crc_status <= 0;
        crc_s <= 0;
        we <= 0;
        data_out <= 0;
        crc_ok <= 0;
        busy_int <= 0;
        data_index <= 0;
        next_block <= 0;
        blkcnt_reg <= 0;
        byte_alignment_reg <= 0;
        data_cycles <= 0;
        bus_4bit_reg <= 0;     
        wait_reg_o <= 0;
        finish_o <= 0;
    end
    else begin
        state <= next_state;
        case(state)
            IDLE: begin
                DAT_oe_o <= 0;
                DAT_dat_o <= 4'b1111;
                crc_en <= 0;
                crc_rst <= 1;
                transf_cnt_o <= 0;
                crc_c <= 16;
                crc_status <= 0;
                crc_s <= 0;
                we <= 0;
                rd <= 0;
                data_index <= 0;
                next_block <= 0;
                blkcnt_reg <= blkcnt;
                byte_alignment_reg <= byte_alignment;
                blksize_reg <= blksize;
                data_cycles <= (bus_4bit ? {2'b0,blksize,1'b0} + 'd2 : {blksize,3'b0} + 'd8);
                bus_4bit_reg <= bus_4bit;
	        wait_reg_o <= 0;
	        finish_o <= 0;
            end
            WRITE_DAT: begin
                crc_ok <= 0;
                transf_cnt_o <= transf_cnt_o + 16'h1;
                next_block <= 0;
                rd <= 0;
                //special case
                if (transf_cnt_o == 0 && byte_alignment_reg == 2'b11 && bus_4bit_reg) begin
                    rd <= 1;
                end
                else if (transf_cnt_o == 1) begin
                    crc_rst <= 0;
                    crc_en <= 1;
                    if (bus_4bit_reg) begin
                        last_din <= {
                            data_in[31-({byte_alignment_reg,3'b000})], 
                            data_in[30-({byte_alignment_reg,3'b000})], 
                            data_in[29-({byte_alignment_reg,3'b000})], 
                            data_in[28-({byte_alignment_reg,3'b000})]
                            };
                        crc_in <= {
                            data_in[31-({byte_alignment_reg,3'b000})], 
                            data_in[30-({byte_alignment_reg,3'b000})], 
                            data_in[29-({byte_alignment_reg,3'b000})], 
                            data_in[28-({byte_alignment_reg,3'b000})]
                            };
                    end
                    else begin
                        last_din <= {3'h7, data_in[31-({byte_alignment_reg,3'b000})]};
                        crc_in <= {3'h7, data_in[31-({byte_alignment_reg,3'b000})]};
                    end
                    DAT_oe_o <= 1;
                    DAT_dat_o <= bus_4bit_reg ? 4'h0 : 4'he;
                    data_index <= bus_4bit_reg ? {2'b00, byte_alignment_reg, 1'b1} : {byte_alignment_reg, 3'b001};
                end
                else if ((transf_cnt_o >= 2) && (transf_cnt_o <= data_cycles+1)) begin
                    DAT_oe_o<=1;
                    if (bus_4bit_reg) begin
                        last_din <= {
                            data_in[31-({data_index[2:0],2'b00})], 
                            data_in[30-({data_index[2:0],2'b00})], 
                            data_in[29-({data_index[2:0],2'b00})], 
                            data_in[28-({data_index[2:0],2'b00})]
                            };
                        crc_in <= {
                            data_in[31-({data_index[2:0],2'b00})], 
                            data_in[30-({data_index[2:0],2'b00})], 
                            data_in[29-({data_index[2:0],2'b00})], 
                            data_in[28-({data_index[2:0],2'b00})]
                            };
                        if (data_index[2:0] == 3'h5/*not 7 - read delay !!!*/ && transf_cnt_o <= data_cycles-1) begin
                            rd <= 1;
                        end
                    end
                    else begin
                        last_din <= {3'h7, data_in[31-data_index]};
                        crc_in <= {3'h7, data_in[31-data_index]};
                        if (data_index == 29/*not 31 - read delay !!!*/) begin
                            rd <= 1;
                        end
                    end
                    data_index <= data_index + 5'h1;
                    DAT_dat_o <= last_din;
                    if (transf_cnt_o == data_cycles+1)
                        crc_en<=0;
                end
                else if (transf_cnt_o > data_cycles+1 & crc_c!=0) begin
                    crc_en <= 0;
                    crc_c <= crc_c - 5'h1;
                    DAT_oe_o <= 1;
                    DAT_dat_o[0] <= crc_out[0][crc_c-1];
                    if (bus_4bit_reg)
                        DAT_dat_o[3:1] <= {crc_out[3][crc_c-1], crc_out[2][crc_c-1], crc_out[1][crc_c-1]};
                    else
                        DAT_dat_o[3:1] <= {3'h7};
                end
                else if (transf_cnt_o == data_cycles+18) begin
                    DAT_oe_o <= 1;
                    DAT_dat_o <= 4'hf;
                end
                else if (transf_cnt_o >= data_cycles+19) begin
                    DAT_oe_o <= 0;
                end
            end
            WRITE_CRC: begin
                DAT_oe_o <= 0;
                if (crc_status < 3)
                    crc_s[crc_status[1:0]] <= DAT_dat_reg[0];
                crc_status <= crc_status + 3'h1;
                busy_int <= 1;
            end
            WRITE_BUSY: begin
                if (crc_s == 3'b010)
                    crc_ok <= 1;
                else
                    crc_ok <= 0;
                busy_int <= !DAT_dat_reg[0];
                next_block <= (blkcnt_reg != 0);
                if (next_state != WRITE_BUSY) begin
                    blkcnt_reg <= blkcnt_reg - `BLKCNT_W'h1;
                    byte_alignment_reg <= byte_alignment_reg + blksize_reg[1:0] + 2'b1;
                    crc_rst <= 1;
                    crc_c <= 16;
                    crc_status <= 0;
                end
                transf_cnt_o <= 0;
            end
            READ_WAIT: begin
                DAT_oe_o <= 0;
                crc_rst <= 0;
                crc_en <= 1;
                crc_in <= 0;
                crc_c <= 15;// end
                next_block <= 0;
                transf_cnt_o <= 0;
                data_index <= bus_4bit_reg ? {2'b00,byte_alignment_reg,1'b0} : ({byte_alignment_reg,3'b000});
	        wait_reg_o <= wait_reg_o + 1;
            end
            READ_DAT: begin
                if (transf_cnt_o < data_cycles) begin
                    if (bus_4bit_reg) begin
                        we <= (data_index[2:0] == 7 || (transf_cnt_o == data_cycles-1 && blkcnt_reg == 0));
                        data_out[31-({data_index[2:0],2'b00})] <= DAT_dat_reg[3];
                        data_out[30-({data_index[2:0],2'b00})] <= DAT_dat_reg[2];
                        data_out[29-({data_index[2:0],2'b00})] <= DAT_dat_reg[1];
                        data_out[28-({data_index[2:0],2'b00})] <= DAT_dat_reg[0];
                    end
                    else begin
                        we <= (data_index == 31 || (transf_cnt_o == data_cycles-1 && blkcnt_reg == 0));
                        data_out[31-data_index] <= DAT_dat_reg[0];
                    end
                    data_index <= data_index + 5'h1;
                    crc_in <= DAT_dat_reg;
                    crc_ok <= 1;
                    transf_cnt_o <= transf_cnt_o + 16'h1;
                end
                else if (transf_cnt_o <= data_cycles+16) begin
                    transf_cnt_o <= transf_cnt_o + 16'h1;
                    crc_en <= 0;
                    last_din <= DAT_dat_reg;
                    we<=0;
                    if (transf_cnt_o > data_cycles) begin
                        crc_c <= crc_c - 5'h1;
                        if  (crc_out[0][crc_c[3:0]] != last_din[0])
                            crc_ok <= 0;
                        if  (crc_out[1][crc_c[3:0]] != last_din[1] && bus_4bit_reg)
                            crc_ok<=0;
                        if  (crc_out[2][crc_c[3:0]] != last_din[2] && bus_4bit_reg)
                            crc_ok <= 0;
                        if  (crc_out[3][crc_c[3:0]] != last_din[3] && bus_4bit_reg)
                            crc_ok <= 0;
                        if (crc_c == 0) begin
                            next_block <= (blkcnt_reg != 0);
                            blkcnt_reg <= blkcnt_reg - `BLKCNT_W'h1;
                            byte_alignment_reg <= byte_alignment_reg + blksize_reg[1:0] + 2'b1;
                            crc_rst <= 1;
                        end
                    end
                end
            end // case: READ_DAT
	  FINISH:
	    finish_o <= 1;
	  default:;
	  
        endcase
    end
end

endmodule





