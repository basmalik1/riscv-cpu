# Timing constraints for the pipelined build.
#
# Note what is NOT here: the single-cycle build declares a generated clock,
# because it divides the board clock by four with a counter. This core runs
# directly on the 50 MHz board clock, so there is one clock and no derived
# clock to constrain.

create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

derive_clock_uncertainty

# Buttons, switches, LEDs and displays are asynchronous to everything.
set_false_path -from [get_ports {KEY[*]}] -to *
set_false_path -from [get_ports {SW[*]}]  -to *
set_false_path -from * -to [get_ports {LEDR[*]}]
set_false_path -from * -to [get_ports {HEX0[*]}]
set_false_path -from * -to [get_ports {HEX1[*]}]
set_false_path -from * -to [get_ports {HEX2[*]}]
set_false_path -from * -to [get_ports {HEX3[*]}]
set_false_path -from * -to [get_ports {HEX4[*]}]
set_false_path -from * -to [get_ports {HEX5[*]}]
