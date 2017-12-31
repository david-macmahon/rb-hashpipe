#!/usr/bin/env ruby

# A curses-based Hashpipe Redis monitor.
# Transcribed from hashpipe_status_monitor.py.

require 'optparse'
require 'curses'
require 'redis'
require 'hashpipe/keys'
include Hashpipe::RedisKeys

include Curses

DEFCOL = 0
KEYCOL = 1
VALCOL = 2
ERRCOL = 3

OPTS = {
  :domain => 'hashpipe',
  :loose  => false,
  :server => 'redishost'
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS] [REDISHOST] GW/INST [...]"
  op.separator('')
  op.on('-D', '--domain=DOMAIN',
        "Domain for Redis channels/keys [#{OPTS[:domain]}]") do |o|
    OPTS[:domain] = o
  end
  op.on('-l', '--[no-]loose',
        "Use loose display format [#{OPTS[:loose]}]") do |o|
    OPTS[:loose] = o
  end
  op.on('-s', '--server=NAME',
        "Host running redis-server [#{OPTS[:server]}]") do |o|
    OPTS[:server] = o
  end
  #op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!
#p OPTS; exit

# Connect to Redis server, first try ARGV[0], then use OPTS[:server]
begin
  # Try ARGV[0] (for backwards compatibility)
  redis = Redis.new(:host => ARGV[0])
  redis.ping # Test connection
  # Connect succeeded, drop ARGV[0]
  ARGV.shift
rescue
  begin
    # Use OPTS[:server]
    redis = Redis.new(:host => OPTS[:server])
    redis.ping # Test connection
  rescue
    print "Error connecting to redis server '#{OPTS[:server]}'"
    print " and '#{ARGV[0]}'" if ARGV[0] != OPTS[:server]
    puts
    exit 1
  end
end

if ARGV.empty?
  puts OP
  exit 1
end

# Old versions of Curses don't have Window#erase
if !Curses::Window.instance_methods.index(:erase)
  class Curses::Window
    def erase
      color_set(DEFCOL)
      blanks = ' ' * maxx
      maxy.times do |y|
        setpos(y, 0)
        addstr(blanks)
      end
      setpos(0, 0)
    end
  end
end

def addstr(win, row, col, string, color=DEFCOL)
  win.setpos(row, col) if row && col
  win.color_set(color) if color
  win.addstr(string) if string
  win.color_set(DEFCOL) if color && color != DEFCOL
end

def display_status(redis, key_fragments, fragidx=0)

  noecho
  start_color
  stdscr.keypad true
  stdscr.nodelay = true

  run = true

  # Hide the cursor
  Curses.curs_set(0)

  # Look like gbtstatus (why not?)
  init_pair(KEYCOL, COLOR_CYAN,  COLOR_BLACK)
  init_pair(VALCOL, COLOR_GREEN, COLOR_BLACK)
  init_pair(ERRCOL, COLOR_WHITE, COLOR_RED)

  # Loop
  while run
    # Get current key fragment
    keyfrag = key_fragments[fragidx]

    # Refresh status data from redis
    data = redis.hgetall(status_key(keyfrag, nil, OPTS[:domain]))
    # Remeber whether we got nil data
    nil_data = data.nil? || data.empty?
    # Make sure data is not nil
    data ||= {}

    # Erase screen (no flicker!)
    stdscr.erase

    # Draw border
    stdscr.box(0,0)

    # Display main status info
    onecol = false # Set to true for one-column format
    col = 2
    curline = 0

    addstr(stdscr, curline, col, " Current Status: %s " % keyfrag, KEYCOL)

    curline += 2
    flip = 0
    keys = data.keys.sort
    keys.delete 'INSTANCE'

    prefix = keys.empty? ? '' : keys[0][0,3]

    keys.each do |k|
      if OPTS[:loose] && k[0,3] != prefix
        prefix = k[0,3]
        curline += flip
        col = 2
        flip = 0
        #stdscr.addch(curline, 0, ACS_LTEE)
        #stdscr.hline(curline, 1, ACS_HLINE, xmax-2)
        #stdscr.addch(curline, xmax-1, ACS_RTEE)
        curline += 1
      end

      v = data[k]
      if (curline < stdscr.maxy-3)
        addstr(stdscr, curline, col, '%8s : ' % k, KEYCOL)
        addstr(stdscr, nil, nil, v, VALCOL)
      else
        addstr(stdscr, stdscr.maxy-3, col,
               '-- Increase window size --', ERRCOL)
      end

      if flip == 1 || onecol
        curline += 1
        col = 2
        flip = 0
      else
        col = 40
        flip = 1
      end
    end # keys.each

    col = 2
    if flip == 1 && !onecol
      curline += 1
    end

    if nil_data
      addstr(stdscr, curline, col,
             "No data found for #{key_fragments[fragidx]}!",
             ERRCOL)
      stdscr.clrtoeol
    end

    # Bottom info line
    addstr(stdscr, stdscr.maxy-2, col,
           "Last update: #{Time.now.strftime('%c')}  -  " \
           "Press 'q' to quit, 0-9 to select")

    # Redraw screen
    stdscr.refresh

    # Sleep a bit
    sleep 0.25

    # Look for input
    while c = stdscr.getch
      case c
      when 'q'
        run = false
      #when '0'..'9'
      #  c = c.ord - '0'.ord
      #  if c != instance_id
      #    begin
      #      stat = Hshpipe::Status.new(c, false)
      #      instance_id = c
      #    rescue
      #      addstr(stdscr, stdscr.maxy-2, col,
      #             "Error connecting to status buffer for instance #{c}",
      #             ERRCOL)
      #      stdscr.clrtoeol
      #      stdscr.refresh
      #      # Give time to read message, but could make UI feel
      #      # non-responsive
      #      sleep(1)
      #    end
      #  end
      when '=', Key::RIGHT
        fragidx += 1 if fragidx < key_fragments.length-1
      when '-', Key::LEFT
        fragidx -= 1 if fragidx > 0
      when '+', Key::DOWN
        fragidx += 4 if fragidx < key_fragments.length-4
      when '_', Key::UP
        fragidx -= 4 if fragidx > 3
      # Space or ctrl-L or ctrl-R uses the harsher #clear
      when ' ', 'L'.ord-'A'.ord+1, 'R'.ord-'A'.ord+1
        stdscr.clear
      ## Key code diagnostics
      #else
      #  addstr(stdscr, 4, 2, ' ' * (stdscr.maxx-2))
      #  addstr(stdscr, 4, 2, "got '#{c.inspect}'")
      #  stdscr.refresh
      #  sleep 1
      end # case

      c = stdscr.getch
    end # while c != ERR
  end # while run
end # display_status

# Initialize screen and call the main func
init_screen
begin
  begin
    display_status(redis, ARGV, 0)
  ensure
    close_screen
  end
#rescue KeyboardInterrupt
#    puts "Exiting..."
rescue => e
  p e
  puts e.backtrace
end
