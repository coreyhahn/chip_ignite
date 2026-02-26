# SDC constraints for ldpc_decoder_top
# Adapted from Caravel user_proj_example SDC
# Target: 50 MHz (20 ns period)

### Note:
# - input clock transition and latency are set for clk port.
# - IO ports are assumed to be asynchronous (IO_SYNC=0).

#------------------------------------------#
# Pre-defined Constraints
#------------------------------------------#

set ::env(IO_SYNC) 0

# Clock network
if {[info exists ::env(CLOCK_PORT)] && $::env(CLOCK_PORT) != ""} {
	set clk_input $::env(CLOCK_PORT)
	create_clock [get_ports $clk_input] -name clk -period $::env(CLOCK_PERIOD)
	puts "\[INFO\]: Creating clock {clk} for port $clk_input with period: $::env(CLOCK_PERIOD)"
} else {
	set clk_input __VIRTUAL_CLK__
	create_clock -name clk -period $::env(CLOCK_PERIOD)
	puts "\[INFO\]: Creating virtual clock with period: $::env(CLOCK_PERIOD)"
}
if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
	set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}
if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL_PIN)] } {
	set ::env(SYNTH_CLK_DRIVING_CELL_PIN) $::env(SYNTH_DRIVING_CELL_PIN)
}

# Clock non-idealities
set_propagated_clock [all_clocks]
set_clock_uncertainty $::env(SYNTH_CLOCK_UNCERTAINTY) [get_clocks {clk}]
puts "\[INFO\]: Setting clock uncertainity to: $::env(SYNTH_CLOCK_UNCERTAINTY)"
set_clock_transition $::env(SYNTH_CLOCK_TRANSITION) [get_clocks {clk}]
puts "\[INFO\]: Setting clock transition to: $::env(SYNTH_CLOCK_TRANSITION)"

# Maximum transition time for the design nets
set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
puts "\[INFO\]: Setting maximum transition to: $::env(MAX_TRANSITION_CONSTRAINT)"

# Maximum fanout
set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
puts "\[INFO\]: Setting maximum fanout to: $::env(MAX_FANOUT_CONSTRAINT)"

# Timing paths delays derate
set_timing_derate -early [expr {1-$::env(SYNTH_TIMING_DERATE)}]
set_timing_derate -late [expr {1+$::env(SYNTH_TIMING_DERATE)}]
puts "\[INFO\]: Setting timing derate to: [expr {$::env(SYNTH_TIMING_DERATE) * 100}] %"

# Reset input delay
set_input_delay [expr $::env(CLOCK_PERIOD) * 0.5] -clock [get_clocks {clk}] [get_ports {rst_n}]

# Multicycle paths for Wishbone handshake
set_multicycle_path -setup 2 -through [get_ports {wb_ack_o}]
set_multicycle_path -hold 1  -through [get_ports {wb_ack_o}]
set_multicycle_path -setup 2 -through [get_ports {wb_cyc_i}]
set_multicycle_path -hold 1  -through [get_ports {wb_cyc_i}]
set_multicycle_path -setup 2 -through [get_ports {wb_stb_i}]
set_multicycle_path -hold 1  -through [get_ports {wb_stb_i}]

#------------------------------------------#
# Retrieved Constraints (from Caravel)
#------------------------------------------#

# Clock source latency
set clk_max_latency 5.57
set clk_min_latency 4.65
set_clock_latency -source -max $clk_max_latency [get_clocks {clk}]
set_clock_latency -source -min $clk_min_latency [get_clocks {clk}]
puts "\[INFO\]: Setting clock latency range: $clk_min_latency : $clk_max_latency"

# Clock input Transition
set clk_tran 0.61
set_input_transition $clk_tran [get_ports $clk_input]
puts "\[INFO\]: Setting clock transition: $clk_tran"

# Input delays (scaled from Caravel characterization)
set_input_delay -max 3.17 -clock [get_clocks {clk}] [get_ports {wb_sel_i[*]}]
set_input_delay -max 3.74 -clock [get_clocks {clk}] [get_ports {wb_we_i}]
set_input_delay -max 3.89 -clock [get_clocks {clk}] [get_ports {wb_adr_i[*]}]
set_input_delay -max 4.13 -clock [get_clocks {clk}] [get_ports {wb_stb_i}]
set_input_delay -max 4.61 -clock [get_clocks {clk}] [get_ports {wb_dat_i[*]}]
set_input_delay -max 4.74 -clock [get_clocks {clk}] [get_ports {wb_cyc_i}]
set_input_delay -min 0.79 -clock [get_clocks {clk}] [get_ports {wb_adr_i[*]}]
set_input_delay -min 1.04 -clock [get_clocks {clk}] [get_ports {wb_dat_i[*]}]
set_input_delay -min 1.19 -clock [get_clocks {clk}] [get_ports {wb_sel_i[*]}]
set_input_delay -min 1.65 -clock [get_clocks {clk}] [get_ports {wb_we_i}]
set_input_delay -min 1.69 -clock [get_clocks {clk}] [get_ports {wb_cyc_i}]
set_input_delay -min 1.86 -clock [get_clocks {clk}] [get_ports {wb_stb_i}]

# Input Transition
set_input_transition -max 0.14  [get_ports {wb_we_i}]
set_input_transition -max 0.15  [get_ports {wb_stb_i}]
set_input_transition -max 0.17  [get_ports {wb_cyc_i}]
set_input_transition -max 0.18  [get_ports {wb_sel_i[*]}]
set_input_transition -max 0.84  [get_ports {wb_dat_i[*]}]
set_input_transition -max 0.92  [get_ports {wb_adr_i[*]}]
set_input_transition -min 0.07  [get_ports {wb_adr_i[*]}]
set_input_transition -min 0.07  [get_ports {wb_dat_i[*]}]
set_input_transition -min 0.09  [get_ports {wb_cyc_i}]
set_input_transition -min 0.09  [get_ports {wb_sel_i[*]}]
set_input_transition -min 0.09  [get_ports {wb_we_i}]
set_input_transition -min 0.15  [get_ports {wb_stb_i}]

# Output delays
set_output_delay -max 0.7  -clock [get_clocks {clk}] [get_ports {irq_o}]
set_output_delay -max 3.62 -clock [get_clocks {clk}] [get_ports {wb_dat_o[*]}]
set_output_delay -max 8.41 -clock [get_clocks {clk}] [get_ports {wb_ack_o}]
set_output_delay -min 0    -clock [get_clocks {clk}] [get_ports {irq_o}]
set_output_delay -min 1.13 -clock [get_clocks {clk}] [get_ports {wb_dat_o[*]}]
set_output_delay -min 1.37 -clock [get_clocks {clk}] [get_ports {wb_ack_o}]

# Output loads
set_load 0.19 [all_outputs]
