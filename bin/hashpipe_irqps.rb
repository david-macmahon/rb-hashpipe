#!/usr/bin/env ruby

# hashpipe_irqps.rb - Measure IRQs Per Second for specified interrupts.
#
# Reads /proc/interrupts two times, SECONDS seconds apart, then calculates
# and displays various IRQs/second statistics.
#
# Usage: hashpipe_irqps.rb [-v] PATTERN [SECONDS]
#
# Examples:
#
#     $ ./irqps.rb eth2
#     CPU  4   2529.0 IRQ/s   55.9 %
#     CPU  5   1997.0 IRQ/s   44.1 %
#
#     $ ./irqps.rb -v eth2
#     IRQ 110 CPU  5    673.0 IRQ/s   IR-PCI-MSI-edge eth2-0
#     IRQ 111 CPU  4    626.0 IRQ/s   IR-PCI-MSI-edge eth2-1
#     IRQ 112 CPU  5    674.0 IRQ/s   IR-PCI-MSI-edge eth2-2
#     IRQ 113 CPU  4    623.0 IRQ/s   IR-PCI-MSI-edge eth2-3
#     IRQ 114 CPU  5    676.0 IRQ/s   IR-PCI-MSI-edge eth2-4
#     IRQ 115 CPU  4    624.0 IRQ/s   IR-PCI-MSI-edge eth2-5
#     IRQ 117 CPU  4      3.0 IRQ/s   IR-PCI-MSI-edge eth2-13
#     IRQ 119 CPU  4    623.0 IRQ/s   IR-PCI-MSI-edge eth2-15
#     
#     CPU  4   2499.0 IRQ/s   55.3 %
#     CPU  5   2023.0 IRQ/s   44.7 %

if ARGV[0] == '-v'
  VERBOSE = true
  ARGV.shift
else
  VERBOSE = false
end

PATTERN = ARGV[0]
SECONDS = Integer(ARGV[1]||1) rescue 1

def get_irq_stats(pattern=nil)
  header, *irqlines = File.readlines('/proc/interrupts')
  cpus = header.split

  irqlines = irqlines.grep(Regexp.new(pattern||'.'))
  irqdata = {}
  irqlines.each do |line|
    stats = line.chomp.split(nil, cpus.length+2)
    irq = stats.shift.to_i
    info = stats.pop
    stats.map! {|s| s.to_i}
    irqdata[irq] = [stats, info]
  end
  irqdata
end

tic=get_irq_stats(PATTERN)
sleep SECONDS
toc=get_irq_stats(PATTERN)

cpu_stats={}
ips_sum = 0
tic.keys.sort.each do |irq|
  n0 = tic[irq][0]
  n1 = toc[irq][0]
  n0.each_with_index do |n, cpu|
    ips = (n1[cpu] - n).to_f / SECONDS
    if ips > 0
      # Accumulate per-cpu stats
      cpu_stats[cpu] ||= 0
      cpu_stats[cpu]  += ips
      ips_sum += ips
      if VERBOSE
        printf "IRQ %3d CPU %2d %8.1f IRQ/s   %s\n",
          irq, cpu, ips, tic[irq][1].squeeze(' ')
      end
    end
  end
end
puts if VERBOSE

cpu_stats.keys.sort.each do |cpu|
  printf "CPU %2d %8.1f IRQ/s  %5.1f %%\n", cpu, cpu_stats[cpu], 100.0*cpu_stats[cpu]/ips_sum
end
