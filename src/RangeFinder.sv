`default_nettype none

module tt_um_erika (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    output logic [7:0]  uo_out,

    input  logic [7:0]  uio_in,
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe
);

    // Tie-offs by default (prevents Yosys "undriven" weirdness)
    always_comb begin
        uio_out = 8'b0;
        uio_oe  = 8'b0;
    end

    // Internal signals
    logic [7:0] range;
    logic error;

    // Map range to dedicated outputs
    assign uo_out = range;

    // Drive error on uio[0]
    always_comb begin
        uio_out[0] = error;
        uio_oe[0]  = 1'b1;   // drive uio[0] as output
    end

    // Instantiate your design
    RangeFinder #(.WIDTH(8)) dut (
        .data_in (ui_in),
        .clock   (clk),
        .reset   (~rst_n),     // your module reset is active-high
        .go      (uio_in[0]),  // or ui_in[0] if you prefer
        .finish  (uio_in[1]),
        .range   (range),
        .error   (error)
    );

endmodule



module RangeFinder
   #(parameter WIDTH=8)
    (input  logic [WIDTH-1:0] data_in,
     input  logic             clock, reset,
     input  logic             go, finish,
     output logic [WIDTH-1:0] range,
     output logic             error);

// Put your code here
  enum logic [2:0] {
    INIT = 3'b000,
    ACTIVE = 3'b001,
    CALC = 3'b010,
    GO_ERROR = 3'b011,
    FINISH_ERROR = 3'b100
} state, next_state;

  logic [WIDTH-1:0] max, min, next_min, next_max;

always_comb begin
    next_state = state;
  	error = 1'b0;
    
    next_min = min;
    next_max = max;

    range = next_max - next_min;
  
  case (state)

    INIT: begin
      if (go & !finish)
            next_state = ACTIVE;
      else if (finish) begin
            next_state = FINISH_ERROR;
      		error = 1'b1;
      end
        else
            next_state = INIT;
    end

    ACTIVE: begin
      	if (data_in > max)
            next_max = data_in;
               
        if (data_in < min)
            next_min = data_in;
      
        range = next_max - next_min;
      
        if (finish)
            next_state = CALC;

        else
            next_state = ACTIVE;
    end

    CALC: begin
        next_state = INIT;
    end

    GO_ERROR: begin
      if (finish)
            next_state = INIT;
        else begin
            next_state = GO_ERROR;
      		error = 1'b1;
        end
    end
    
    FINISH_ERROR: begin
      if (go & !finish) begin
        next_state = ACTIVE;
      	error = 1'b0;
      end
      else begin
        next_state = FINISH_ERROR;
       // next_state = INIT;
        error = 1'b1;
      end
    end
    
  endcase
  
end

  always_ff @(posedge clock, posedge reset) begin
    if (reset) begin
        state <= INIT;
        max <= 0;
        min <= {WIDTH{1'b0}};;
    end
    else begin
        state <= next_state;

        // Set outputs here
      //if (finish & go)
      //  error <= 1'b1;
      
      case (state)

            ACTIVE: begin
                min <= next_min;
              	max <= next_max;
            end

        endcase
    end
end

endmodule: RangeFinder