# Timing constraints. Without these the fitter has nothing to close against and
# the timing report is meaningless.

create_clock -name {MAX10_CLK1_50} -period 20.000 [get_ports {MAX10_CLK1_50}]

# cpu_clk is a counter bit used as a clock, so it is a generated clock derived
# from the board clock by four. Declaring it is what lets the analyser check the
# core's paths at 12.5 MHz rather than treating them as unconstrained.
create_generated_clock -name {cpu_clk} -source [get_ports {MAX10_CLK1_50}] \
    -divide_by 4 [get_registers {phase[1]}]

derive_clock_uncertainty

# Buttons, switches, LEDs and the displays are asynchronous to everything.
set_false_path -from [get_ports {KEY[*]}] -to *
set_false_path -from [get_ports {SW[*]}]  -to *
set_false_path -from * -to [get_ports {LEDR[*]}]
set_false_path -from * -to [get_ports {HEX0[*]}]
set_false_path -from * -to [get_ports {HEX1[*]}]
set_false_path -from * -to [get_ports {HEX2[*]}]
set_false_path -from * -to [get_ports {HEX3[*]}]
set_false_path -from * -to [get_ports {HEX4[*]}]
set_false_path -from * -to [get_ports {HEX5[*]}]
