//###############################################################################
//# WbXbc - Wishbone Crossbar Components - Error Generator                      #
//###############################################################################
//#    Copyright 2018 Dirk Heisswolf                                            #
//#    This file is part of the WbXbc project.                                  #
//#                                                                             #
//#    WbXbc is free software: you can redistribute it and/or modify            #
//#    it under the terms of the GNU General Public License as published by     #
//#    the Free Software Foundation, either version 3 of the License, or        #
//#    (at your option) any later version.                                      #
//#                                                                             #
//#    WbXbc is distributed in the hope that it will be useful,                 #
//#    but WITHOUT ANY WARRANTY; without even the implied warranty of           #
//#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            #
//#    GNU General Public License for more details.                             #
//#                                                                             #
//#    You should have received a copy of the GNU General Public License        #
//#    along with WbXbc.  If not, see <http://www.gnu.org/licenses/>.           #
//###############################################################################
//# Description:                                                                #
//#    This module implements an error generator or dummy target for the        #
//#    pipelined Wishbone protocol. It propagates accesses from the initiator   #
//#    to the target bus, but intercepts accesses without a target, signaling   #
//#    an error condition to the initiator. The target association is           #
//#    determined by a set of address tags, generated by the address decoder.   #
//#                                                                             #
//#                          +-------------------+                              #
//#                          |                   |                              #
//#                          |                   |                              #
//#            initiator     |       WbXbc       |       target                 #
//#               bus    --->|       error       |--->    bus                   #
//#              with        |     generator     |        with                  #
//#             selects      |                   |       selects                #
//#                          |                   |                              #
//#                          +-------------------+                              #
//#                                                                             #
//###############################################################################
//# Version History:                                                            #
//#   July 18, 2018                                                             #
//#      - Initial release                                                      #
//#   October 8, 2018                                                           #
//#      - Updated parameter and signal naming                                  #
//#   October 15, 2018                                                          #
//#      - redesigned FSM                                                       #
//###############################################################################
`default_nettype none

module WbXbc_error_generator
  #(parameter TGT_CNT     = 4,   //number of target addresses
    parameter ADR_WIDTH   = 16,  //width of the address bus
    parameter DAT_WIDTH   = 16,  //width of each data bus
    parameter SEL_WIDTH   = 2,   //number of data select lines
    parameter TGA_WIDTH   = 1,   //number of propagated address tags
    parameter TGC_WIDTH   = 1,   //number of propagated cycle tags
    parameter TGRD_WIDTH  = 1,   //number of propagated read data tags
    parameter TGWD_WIDTH  = 1)   //number of propagated write data tags

   (//Clock and reset
    //---------------
    input wire                   clk_i,            //module clock
    input wire                   async_rst_i,      //asynchronous reset
    input wire                   sync_rst_i,       //synchronous reset

    //Initiator interface
    //-------------------
    input  wire                  itr_cyc_i,        //bus cycle indicator       +-
    input  wire                  itr_stb_i,        //access request            |
    input  wire                  itr_we_i,         //write enable              |
    input  wire                  itr_lock_i,       //uninterruptable bus cycle | initiator
    input  wire [SEL_WIDTH-1:0]  itr_sel_i,        //write data selects        | initiator
    input  wire [ADR_WIDTH-1:0]  itr_adr_i,        //address bus               | to
    input  wire [DAT_WIDTH-1:0]  itr_dat_i,        //write data bus            | target
    input  wire [TGA_WIDTH-1:0]  itr_tga_i,        //address tags              |
    input  wire [TGT_CNT-1:0]    itr_tga_tgtsel_i, //target select tags        |
    input  wire [TGC_WIDTH-1:0]  itr_tgc_i,        //bus cycle tags            |
    input  wire [TGWD_WIDTH-1:0] itr_tgd_i,        //write data tags           +-
    output reg                   itr_ack_o,        //bus cycle acknowledge     +-
    output reg                   itr_err_o,        //error indicator           | target
    output reg                   itr_rty_o,        //retry request             | to
    output wire                  itr_stall_o,      //access delay              | initiator
    output wire [DAT_WIDTH-1:0]  itr_dat_o,        //read data bus             |
    output wire [TGRD_WIDTH-1:0] itr_tgd_o,        //read data tags            +-

    //Target interface
    //----------------
    output reg                   tgt_cyc_o,        //bus cycle indicator       +-
    output wire                  tgt_stb_o,        //access request            |
    output wire                  tgt_we_o,         //write enable              |
    output wire                  tgt_lock_o,       //uninterruptable bus cycle |
    output wire [SEL_WIDTH-1:0]  tgt_sel_o,        //write data selects        | initiator
    output wire [ADR_WIDTH-1:0]  tgt_adr_o,        //write data selects        | to
    output wire [DAT_WIDTH-1:0]  tgt_dat_o,        //write data bus            | target
    output wire [TGA_WIDTH-1:0]  tgt_tga_o,        //address tags              |
    output wire [TGT_CNT-1:0]    tgt_tga_tgtsel_o, //target select tags        |
    output wire [TGC_WIDTH-1:0]  tgt_tgc_o,        //bus cycle tags            |
    output wire [TGWD_WIDTH-1:0] tgt_tgd_o,        //write data tags           +-
    input  wire                  tgt_ack_i,        //bus cycle acknowledge     +-
    input  wire                  tgt_err_i,        //error indicator           | target
    input  wire                  tgt_rty_i,        //retry request             | to
    input  wire                  tgt_stall_i,      //access delay              | initiator
    input  wire [DAT_WIDTH-1:0]  tgt_dat_i,        //read data bus             |
    input  wire [TGRD_WIDTH-1:0] tgt_tgd_i);       //read data tags            +-

   //Internal signals
   wire                          any_tgtsel = |itr_tga_tgtsel_i;                   //any target select asserted
   wire                          req        = &{itr_cyc_i, itr_stb_i};             //request from initiator
   wire                          no_req     = |{&{any_tgtsel, tgt_stall_i}, ~req}; //no bus request
   wire                          val_req    = &{ any_tgtsel, ~tgt_stall_i,   req}; //valid request
   wire                          inval_req  = &{~any_tgtsel,                 req}; //invalid request
   wire                          ack        = |{tgt_ack_i, tgt_err_i, tgt_rty_i};  //acknowledge from target
   reg          [1:0]            state_next;                                       //next state

   //Internal registers
   reg          [1:0]            state_reg;                                        //state variable

   //Finite state machine
   //====================
   //                 inval_req     _______
   //         +------------------->/       \
   //         |                    | ERROR |
   //         |  +-----------------\_______/
   //         |  |      no_req       ^  |
   //        _|__v_                  |  |
   // rst   /      \        inval_req|  |
   //  O--->| IDLE |               & |  |val_req
   //       \______/              ack|  |
   //         ^  |                   |  |
   //         |  |     val_req      _|__v_
   //         |  +---------------->/      \
   //         |                    | BUSY |
   //         +--------------------\______/
   //               no_req & ack
   //State encoding
   parameter STATE_IDLE       = 2'b00;                     //awaiting bus request (reset state)
   parameter STATE_BUSY       = 2'b01;                     //awaiting bus acknowledge
   parameter STATE_ERROR      = 2'b10;                     //generate error response
   parameter STATE_UNREACH    = 2'b11;                     //unreachable state
   always @*
     begin
        //Default outputs
        itr_ack_o             = tgt_ack_i;                 //propagate bus cycle acknowledge
        itr_err_o             = tgt_err_i;                 //propagate error indicator
        itr_rty_o             = tgt_rty_i;                 //propagate retry request        `
        tgt_cyc_o             = itr_cyc_i & any_tgtsel;    //propagate cycle indicator on valid request
        //Default transition
        state_next            = state_reg;                 //remain in current state
        case (state_reg)
          STATE_IDLE:
            begin
               if (val_req)
                 state_next = STATE_BUSY;
               if (inval_req)
                 state_next = STATE_ERROR;
            end
          STATE_BUSY:
            begin
               if (no_req & ack)
                 state_next = STATE_IDLE;
               if (inval_req & ack)
                 state_next = STATE_ERROR;
               //Outputs
	       tgt_cyc_o             = 1'b1;              //indicate ongoung bus cycle
            end
          STATE_ERROR,
          STATE_UNREACH:
            begin
               if (no_req)
                 state_next = STATE_IDLE;
               if (val_req)
                 state_next = STATE_BUSY;
               //Outputs
               itr_ack_o             = 1'b0;               //terminate bus cycle with error
               itr_err_o             = 1'b1;               //
               itr_rty_o             = 1'b0;               //        `
            end
        endcase // case (state_reg)
     end // always @ *

   //State variable
   always @(posedge async_rst_i or posedge clk_i)
     if (async_rst_i)                                      //asynchronous reset
       state_reg <= STATE_IDLE;
     else if (sync_rst_i)                                  //synchronous reset
       state_reg <= STATE_IDLE;
     else
       state_reg <= state_next;                            //state transition

   //Plain signal propagation to the target bus
   assign tgt_lock_o       = itr_lock_i;                   //uninterruptible bus cycle indicators
   assign tgt_we_o         = itr_we_i;                     //write enable
   assign tgt_sel_o        = itr_sel_i;                    //write data selects
   assign tgt_adr_o        = itr_adr_i;                    //address busses
   assign tgt_dat_o        = itr_dat_i;                    //write data busses
   assign tgt_tga_o        = itr_tga_i;                    //address tags
   assign tgt_tga_tgtsel_o = itr_tga_tgtsel_i;             //address tags
   assign tgt_tgc_o        = itr_tgc_i;                    //bus cycle tags
   assign tgt_tgd_o        = itr_tgd_i;                    //write data tags

   //Interceptable signal propagation to the target bus
   assign tgt_stb_o        = itr_stb_i & any_tgtsel;       //access request

   //Plain signal propagation to the initiator bus
   assign itr_dat_o        = tgt_dat_i;                    //read data bus
   assign itr_tgd_o        = tgt_tgd_i;                    //read data tags

   //Interceptable signal propagation to the initiator bus
   assign itr_stall_o      = tgt_stall_i & any_tgtsel;     //access delay

endmodule // WbXbc_error_generator
