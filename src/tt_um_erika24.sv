`timescale 1ns/1ps

module tt_um_erika24 (
    input  logic [7:0] ui_in,    // dedicated inputs
    output logic [7:0] uo_out,   // dedicated outputs
    input  logic [7:0] uio_in,   // bidirectional input path
    output logic [7:0] uio_out,  // bidirectional output path
    output logic [7:0] uio_oe,   // bidirectional output enable
    input  logic       ena,      // always high when design is powered
    input  logic       clk,      // clock
    input  logic       rst_n     // active-low reset
);

    // TinyFarm input mapping:
    // ui_in[1:0] = mode select
    //   00 = view
    //   01 = plant
    //   10 = water
    //   11 = harvest
    //
    // ui_in[3:2] = field select
    // ui_in[5:4] = crop select
    //   00 = wheat
    //   01 = corn
    //   10 = carrot
    //   11 = tomato
    //
    // ui_in[6] = action button
    // ui_in[7] = fulfill button

    logic [1:0] mode_sel;
    logic [1:0] field_sel;
    logic [1:0] crop_sel;
    logic       action_btn;
    logic       fulfill_btn;

    assign mode_sel    = ui_in[1:0];
    assign field_sel   = ui_in[3:2];
    assign crop_sel    = ui_in[5:4];
    assign action_btn  = ui_in[6];
    assign fulfill_btn = ui_in[7];

    // Tiny VGA PMOD signal order:
    // uo_out[0] = R1
    // uo_out[1] = G1
    // uo_out[2] = B1
    // uo_out[3] = VSYNC
    // uo_out[4] = R0
    // uo_out[5] = G0
    // uo_out[6] = B0
    // uo_out[7] = HSYNC

    logic       hsync;
    logic       vsync;
    logic [1:0] vga_r;
    logic [1:0] vga_g;
    logic [1:0] vga_b;

    logic [7:0]  score_unused;
    logic [11:0] inventory_unused;
    logic [1:0]  order_crop_unused;
    logic [1:0]  order_qty_unused;
    logic [3:0]  order_timer_unused;

    tinyfarm_top #(
        .CLK_HZ(25_000_000),
        .GAME_TICK_HZ(20)
    ) tinyfarm_inst (
        .clk(clk),
        .rst_n(rst_n),

        .mode_sel(mode_sel),
        .field_sel(field_sel),
        .crop_sel(crop_sel),

        .action_btn(action_btn),
        .fulfill_btn(fulfill_btn),

        .hsync(hsync),
        .vsync(vsync),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),

        .score_o(score_unused),
        .inventory_o(inventory_unused),
        .order_crop_o(order_crop_unused),
        .order_qty_o(order_qty_unused),
        .order_timer_o(order_timer_unused)
    );

    assign uo_out[0] = vga_r[1];
    assign uo_out[1] = vga_g[1];
    assign uo_out[2] = vga_b[1];
    assign uo_out[3] = vsync;
    assign uo_out[4] = vga_r[0];
    assign uo_out[5] = vga_g[0];
    assign uo_out[6] = vga_b[0];
    assign uo_out[7] = hsync;

    // No bidirectional pins used
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // Avoid unused signal warnings
    logic _unused = &{ena, uio_in, 1'b0};

endmodule

module tinyfarm_top #(
    parameter int CLK_HZ       = 25_000_000,
    parameter int GAME_TICK_HZ = 4
)(
    input  logic clk,
    input  logic rst_n,

    // User controls
    input  logic [1:0] mode_sel,    // 00=view, 01=plant, 10=water, 11=harvest
    input  logic [1:0] field_sel,   // 0..3 selected field
    input  logic [1:0] crop_sel,    // 0=wheat,1=corn,2=carrot,3=tomato
    input  logic action_btn,
    input  logic fulfill_btn,

    // Tiny VGA Pmod (2 bits per color)
    output logic hsync,
    output logic vsync,
    output logic [1:0] vga_r,
    output logic [1:0] vga_g,
    output logic [1:0] vga_b,

    // Debug outputs for simulation / bring-up
    output logic [7:0] score_o,
    output logic [11:0] inventory_o,
    output logic [1:0] order_crop_o,
    output logic [1:0] order_qty_o,
    output logic [3:0] order_timer_o
);

    localparam logic [1:0] MODE_VIEW    = 2'b00;
    localparam logic [1:0] MODE_PLANT   = 2'b01;
    localparam logic [1:0] MODE_WATER   = 2'b10;
    localparam logic [1:0] MODE_HARVEST = 2'b11;

    localparam logic [1:0] CROP_WHEAT  = 2'd0;
    localparam logic [1:0] CROP_CORN   = 2'd1;
    localparam logic [1:0] CROP_CARROT = 2'd2;
    localparam logic [1:0] CROP_TOMATO = 2'd3;

    localparam logic [3:0] ORDER_TIME_DEFAULT = 4'd12;
    localparam logic [2:0] INV_MAX            = 3'd7;

    // typedef struct packed {
    //     logic       valid;
    //     logic       ready;
    //     logic [1:0] crop;
    //     logic [3:0] timer;
    // } field_t;

    logic field_valid [0:3];
    logic field_ready [0:3];
    logic [1:0] field_crop [0:3];
    logic [3:0] field_timer [0:3];

    typedef enum logic [1:0] {
        ST_IDLE    = 2'd0,
        ST_ACTION  = 2'd1,
        ST_FULFILL = 2'd2,
        ST_TICK    = 2'd3
    } state_t;

    // field_t fields [0:3];
    logic [2:0] inventory [0:3];

    logic [1:0] order_crop;
    logic [1:0] order_qty;   // 1..3
    logic [3:0] order_timer;
    logic [7:0] score;
    logic [7:0] lfsr;

    logic action_pulse, fulfill_pulse;
    logic game_tick;
    logic [31:0] tick_div_ctr;

    state_t state, next_state;

    logic [9:0] hcount, vcount;
    logic visible;

    integer i;

    // Helper functions
    function automatic logic [3:0] crop_growth_time(input logic [1:0] crop);
        case (crop)
            CROP_WHEAT:  crop_growth_time = 4'd3;
            CROP_CORN:   crop_growth_time = 4'd4;
            CROP_CARROT: crop_growth_time = 4'd5;
            default:     crop_growth_time = 4'd6;
        endcase
    endfunction

    function automatic logic [7:0] lfsr_advance(input logic [7:0] cur);
        logic feedback;
        begin
            feedback     = cur[7] ^ cur[5] ^ cur[4] ^ cur[3];
            lfsr_advance = {cur[6:0], feedback};
            if (lfsr_advance == 8'h00)
                lfsr_advance = 8'hA5;
        end
    endfunction

    function automatic logic [1:0] order_crop_from_lfsr(input logic [7:0] cur);
        order_crop_from_lfsr = cur[1:0];
    endfunction

    function automatic logic [1:0] order_qty_from_lfsr(input logic [7:0] cur);
        logic [1:0] q;
        begin
            q = cur[3:2];
            case (q)
                2'd0:    order_qty_from_lfsr = 2'd1;
                2'd1:    order_qty_from_lfsr = 2'd2;
                default: order_qty_from_lfsr = 2'd3;
            endcase
        end
    endfunction

    function automatic logic [2:0] sat_inc3(input logic [2:0] val);
        if (val < INV_MAX) sat_inc3 = val + 3'd1;
        else               sat_inc3 = val;
    endfunction

    function automatic logic in_rect (
        input logic [9:0] x,
        input logic [9:0] y,
        input logic [9:0] x0,
        input logic [9:0] y0,
        input logic [9:0] w,
        input logic [9:0] h
    );
        in_rect = (x >= x0) && (x < x0 + w) && (y >= y0) && (y < y0 + h);
    endfunction

    function automatic logic on_border (
        input logic [9:0] x,
        input logic [9:0] y,
        input logic [9:0] x0,
        input logic [9:0] y0,
        input logic [9:0] w,
        input logic [9:0] h,
        input logic [9:0] t
    );
        on_border =
            in_rect(x, y, x0, y0, w, h) &&
            ((x < x0 + t) || (x >= x0 + w - t) ||
             (y < y0 + t) || (y >= y0 + h - t));
    endfunction

    function automatic logic [5:0] field_color(input logic valid,
            input logic ready, input logic [1:0] crop);
        begin
            if (!valid) begin
                field_color = 6'b01_00_00; // brown-ish empty soil
            end else if (ready) begin
                field_color = 6'b00_11_00; // bright green ready
            end else begin
                case (crop)
                    CROP_WHEAT:  field_color = 6'b11_11_00; // yellow
                    CROP_CORN:   field_color = 6'b11_11_00; // yellow
                    CROP_CARROT: field_color = 6'b11_01_00; // orange
                    default:     field_color = 6'b11_00_00; // red tomato
                endcase
            end
        end
    endfunction

    // Input conditioning
    tinyfarm_button_pulse u_action_pulse (
        .clk(clk),
        .rst_n(rst_n),
        .btn_in(action_btn),
        .pulse_out(action_pulse)
    );

    tinyfarm_button_pulse u_fulfill_pulse (
        .clk(clk),
        .rst_n(rst_n),
        .btn_in(fulfill_btn),
        .pulse_out(fulfill_pulse)
    );

    // -----------------------------
    // Game tick divider
    `ifdef SIM
        localparam int TICK_DIV_MAX = 9;  // one game tick every 10 clk cycles in simulation
    `else
        localparam int TICK_DIV_MAX = (CLK_HZ / GAME_TICK_HZ) - 1;
    `endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_div_ctr <= 32'd0;
            game_tick    <= 1'b0;
        end else begin
            if (tick_div_ctr == TICK_DIV_MAX) begin
                tick_div_ctr <= 32'd0;
                game_tick    <= 1'b1;
            end else begin
                tick_div_ctr <= tick_div_ctr + 32'd1;
                game_tick    <= 1'b0;
            end
        end
    end

    // Main control FSM
    always_comb begin
        next_state = state;

        unique case (state)
            ST_IDLE: begin
                if (game_tick) begin
                    next_state = ST_TICK;
                end else if (fulfill_pulse) begin
                    next_state = ST_FULFILL;
                end else if (action_pulse) begin
                    if (mode_sel == MODE_VIEW)
                        next_state = ST_IDLE;
                    else
                        next_state = ST_ACTION;
                end else begin
                    next_state = ST_IDLE;
                end
            end

            ST_ACTION:  next_state = ST_IDLE;
            ST_FULFILL: next_state = ST_IDLE;
            ST_TICK:    next_state = ST_IDLE;
            default:    next_state = ST_IDLE;
        endcase
    end

    // Main game state update
    always_ff @(posedge clk or negedge rst_n) begin : game_state_update
        logic [7:0] new_lfsr;
        logic [1:0] fcrop;

        if (!rst_n) begin
            state <= ST_IDLE;

            for (i = 0; i < 4; i = i + 1) begin
                field_valid[i] <= 1'b0;
                field_ready[i] <= 1'b0;
                field_crop[i]  <= 2'd0;
                field_timer[i] <= 4'd0;
                inventory[i]    <= 3'd0;
            end

            score       <= 8'd0;
            lfsr        <= 8'hA5;
            order_crop  <= 2'd0;
            order_qty   <= 2'd1;
            order_timer <= ORDER_TIME_DEFAULT;
        end else begin
            state <= next_state;

            unique case (state)
                ST_IDLE: begin
                    // Hold state.
                end

                ST_ACTION: begin
                    unique case (mode_sel)
                        MODE_PLANT: begin
                            if (!field_valid[field_sel]) begin
                                field_valid[field_sel] <= 1'b1;
                                field_ready[field_sel] <= 1'b0;
                                field_crop[field_sel]  <= crop_sel;
                                field_timer[field_sel] <= crop_growth_time(crop_sel);
                            end
                        end

                        MODE_WATER: begin
                            if (field_valid[field_sel] && !field_ready[field_sel]) begin
                                if (field_timer[field_sel] > 4'd1) begin
                                    field_timer[field_sel] <= field_timer[field_sel] - 4'd1;
                                end else begin
                                    field_timer[field_sel] <= 4'd0;
                                    field_ready[field_sel] <= 1'b1;
                                end
                            end
                        end

                        MODE_HARVEST: begin
                            if (field_valid[field_sel] && field_ready[field_sel]) begin
                                fcrop = field_crop[field_sel];
                                inventory[fcrop] <= sat_inc3(inventory[fcrop]);

                                field_valid[field_sel] <= 1'b0;
                                field_ready[field_sel] <= 1'b0;
                                field_crop[field_sel]  <= 2'd0;
                                field_timer[field_sel] <= 4'd0;
                            end
                        end

                        default: begin
                            // VIEW mode does not modify state.
                        end
                    endcase
                end

                ST_FULFILL: begin
                    if (inventory[order_crop] >= {1'b0, order_qty}) begin
                        inventory[order_crop] <= inventory[order_crop] - {1'b0, order_qty};
                        score                 <= score + 8'd1;

                        new_lfsr    = lfsr_advance(lfsr);
                        lfsr        <= new_lfsr;
                        order_crop  <= order_crop_from_lfsr(new_lfsr);
                        order_qty   <= order_qty_from_lfsr(new_lfsr);
                        order_timer <= ORDER_TIME_DEFAULT;
                    end
                end

                ST_TICK: begin
                    for (i = 0; i < 4; i = i + 1) begin
                        if (field_valid[i] && !field_ready[i]) begin
                            if (field_timer[i] > 4'd1) begin
                                field_timer[i] <= field_timer[i] - 4'd1;
                            end else begin
                                field_timer[i] <= 4'd0;
                                field_ready[i] <= 1'b1;
                            end
                        end
                    end

                    if (order_timer > 4'd1) begin
                        order_timer <= order_timer - 4'd1;
                    end else begin
                        // Optional small penalty on expiration.
                        if (score != 8'd0)
                            score <= score - 8'd1;

                        new_lfsr    = lfsr_advance(lfsr);
                        lfsr        <= new_lfsr;
                        order_crop  <= order_crop_from_lfsr(new_lfsr);
                        order_qty   <= order_qty_from_lfsr(new_lfsr);
                        order_timer <= ORDER_TIME_DEFAULT;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // Debug outputs
    assign score_o       = score;
    assign inventory_o   = {inventory[3], inventory[2], inventory[1], inventory[0]};
    assign order_crop_o  = order_crop;
    assign order_qty_o   = order_qty;
    assign order_timer_o = order_timer;

    // VGA timing
    tinyfarm_vga_timing u_vga_timing (
        .clk(clk),
        .rst_n(rst_n),
        .hcount(hcount),
        .vcount(vcount),
        .hsync(hsync),
        .vsync(vsync),
        .visible(visible)
    );

    // VGA renderer
    always_comb begin : vga_render
        logic [5:0] rgb;
        rgb = 6'b00_00_00;

        if (!visible) begin
            rgb = 6'b00_00_00;
        end else begin
            // Background.
            rgb = 6'b00_10_01;

            // Four field boxes.
            if (in_rect(hcount, vcount,  10'd40,  10'd40, 10'd180, 10'd140))
                rgb = field_color(field_valid[0], field_ready[0], field_crop[0]);
            if (on_border(hcount, vcount, 10'd40, 10'd40, 10'd180, 10'd140, 10'd4) && (field_sel == 2'd0))
                rgb = 6'b11_11_11;

            if (in_rect(hcount, vcount, 10'd240,  10'd40, 10'd180, 10'd140))
                rgb = field_color(field_valid[1], field_ready[1], field_crop[1]);
            if (on_border(hcount, vcount, 10'd240, 10'd40, 10'd180, 10'd140, 10'd4) && (field_sel == 2'd1))
                rgb = 6'b11_11_11;

            if (in_rect(hcount, vcount, 10'd40, 10'd220, 10'd180, 10'd140))
                rgb = field_color(field_valid[2], field_ready[2], field_crop[2]);
            if (on_border(hcount, vcount, 10'd40, 10'd220, 10'd180, 10'd140, 10'd4) && (field_sel == 2'd2))
                rgb = 6'b11_11_11;

            if (in_rect(hcount, vcount, 10'd240, 10'd220, 10'd180, 10'd140))
                rgb = field_color(field_valid[3], field_ready[3], field_crop[3]);
            if (on_border(hcount, vcount, 10'd240, 10'd220, 10'd180, 10'd140, 10'd4) && (field_sel == 2'd3))
                rgb = 6'b11_11_11;

            // Order panel box
            if (in_rect(hcount, vcount, 10'd460, 10'd40, 10'd140, 10'd120))
                rgb = 6'b00_00_01;

            // Order crop swatch
            if (in_rect(hcount, vcount, 10'd485, 10'd70, 10'd50, 10'd50)) begin
                case (order_crop)
                    CROP_WHEAT:  rgb = 6'b11_11_00;
                    CROP_CORN:   rgb = 6'b11_11_00;
                    CROP_CARROT: rgb = 6'b11_01_00;
                    default:     rgb = 6'b11_00_00;
                endcase
            end

            // Order quantity bars
            if ((order_qty >= 2'd1) && in_rect(hcount, vcount, 10'd550, 10'd70, 10'd15, 10'd50))
                rgb = 6'b11_11_11;
            if ((order_qty >= 2'd2) && in_rect(hcount, vcount, 10'd570, 10'd70, 10'd15, 10'd50))
                rgb = 6'b11_11_11;
            if ((order_qty >= 2'd3) && in_rect(hcount, vcount, 10'd590, 10'd70, 10'd15, 10'd50))
                rgb = 6'b11_11_11;

            // Inventory bars
            if (in_rect(hcount, vcount, 10'd40, 10'd400 - inventory[0] * 8, 10'd20, inventory[0] * 8))
                rgb = 6'b11_11_00;
            if (in_rect(hcount, vcount, 10'd80, 10'd400 - inventory[1] * 8, 10'd20, inventory[1] * 8))
                rgb = 6'b11_11_00;
            if (in_rect(hcount, vcount, 10'd120, 10'd400 - inventory[2] * 8, 10'd20, inventory[2] * 8))
                rgb = 6'b11_01_00;
            if (in_rect(hcount, vcount, 10'd160, 10'd400 - inventory[3] * 8, 10'd20, inventory[3] * 8))
                rgb = 6'b11_00_00;

            // Score bar
            if (in_rect(hcount, vcount, 10'd460, 10'd220, score[4:0] * 5, 10'd20))
                rgb = 6'b00_11_11;

            // Order timer bar
            if (in_rect(hcount, vcount, 10'd460, 10'd260, order_timer * 10, 10'd16))
                rgb = 6'b11_00_11;
        end

        vga_r = rgb[5:4];
        vga_g = rgb[3:2];
        vga_b = rgb[1:0];
    end

endmodule
