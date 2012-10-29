#!/usr/bin/env ruby

# A curses-based Hashpipe Redis monitor.
# Transcribed from hashpipe_status_monitor.py.

require 'rubygems'
require 'curses'
require 'redis'
require 'hashpipe/keys'
include Hashpipe::RedisKeys

include Curses

DEFCOL = 0
KEYCOL = 1
VALCOL = 2
ERRCOL = 3

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
    data = redis.hgetall(status_key(keyfrag,nil))
    # Remeber whether we got nil data
    nil_data = data.nil?
    # Make sure data is not nil
    data ||= {}

    # Clear screen
    stdscr.clear

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
      if k[0,3] != prefix
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
      addstr(stdscr, 1, 2, #curline, col,
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
      when '+', '=', Key::RIGHT, Key::DOWN
        fragidx += 1 if fragidx < key_fragments.length-1
      when '-', Key::LEFT, Key::UP
        fragidx -= 1 if fragidx > 0
      end # case

      c = stdscr.getch
    end # while c != ERR
  end # while run
end # display_status

# Need at least two arguments.  First is name of host running Redis server.
# Remaining are key "fragments" from command line (ARGV).  Format of each key
# fragment is "#{gwname}/#{instance_id}" (e.g. "px1/0").  One way to create
# these on a bash command line is:
#
#   px{1..8}/{0..1}
#
# Gives help if fewer than 2 arguments are given.
if ARGV.length < 2
  puts "Usage: #{File.basename($0)} REDISHOST GW/INST [...]"
  puts
  puts "Example: #{File.basename($0)} redishost px{1..8}/{0..1}"
  exit
end

# First command line arg is redis host
redishost = ARGV.shift

# Connect to Redis server
begin
    redis = Redis.new(:host => redishost)
rescue
    puts "Error connecting to redis server '#{instance_id}'"
    exit 1 
end

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
