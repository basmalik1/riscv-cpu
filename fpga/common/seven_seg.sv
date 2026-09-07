// Active-low seven segment decoder. DE10-Lite drives a segment on with a 0.
module seven_seg (
    input  logic [3:0] value,
    output logic [7:0] seg
);
    always_comb begin
        unique case (value)
            4'h0: seg = 8'b1100_0000;
            4'h1: seg = 8'b1111_1001;
            4'h2: seg = 8'b1010_0100;
            4'h3: seg = 8'b1011_0000;
            4'h4: seg = 8'b1001_1001;
            4'h5: seg = 8'b1001_0010;
            4'h6: seg = 8'b1000_0010;
            4'h7: seg = 8'b1111_1000;
            4'h8: seg = 8'b1000_0000;
            4'h9: seg = 8'b1001_0000;
            4'ha: seg = 8'b1000_1000;
            4'hb: seg = 8'b1000_0011;
            4'hc: seg = 8'b1100_0110;
            4'hd: seg = 8'b1010_0001;
            4'he: seg = 8'b1000_0110;
            4'hf: seg = 8'b1000_1110;
        endcase
    end
endmodule
