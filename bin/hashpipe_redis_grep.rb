#!/usr/bin/env ruby

# hashpipe_redis_grep.rb - A script for grepping Hashpipe status buffers stored
#                          in Redis by, for example, hashpipe_redis_gateway.rb.
#
# Status key format:
#
#   "hashpipe://#{gwname}/#{instance_id}/status"
#
#   Example: hashpipe://px1/0/status

require 'rubygems'
require 'optparse'
require 'redis'

OPTS = {
  :key_glob => '*',
  :server   => 'redishost'
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS] STATUS_KEY_REGEXP"
  op.separator('')
  op.separator('Grep for Hashpipe status buffer keys in a Redis server.')
  op.separator('All hashpipe status buffers cached in the server will be')
  op.separator('grepped for status buffer keys matching STATUS_KEY_REGEXP.')
  op.separator('Matches are printed as three fields: hashpipe instance name,')
  op.separator('status buffer key, and corresponding status buffer value.')
  op.separator('Matches against STATUS_KEY_REGEXP are case insensitive.')
  op.separator('')
  op.separator('Options:')
  op.on('-k', '--key-glob=GLOB',
        "Redis key glob pattern [#{OPTS[:key_glob]}]") do |o|
    OPTS[:key_glob] = o
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

if ARGV.empty?
  puts OP.help
  exit 1
end

# Create case-INsensitive Regexp object for given pattern
pattern = Regexp.new(ARGV[0], true)

# Create Redis object
redis = Redis.new(:host => OPTS[:server])

# Get redis keys for hashpipe status buffers
key_glob = "hashpipe://*#{OPTS[:key_glob]}*/status"
rkeys = redis.keys(key_glob).sort

# For each redis key
rkeys.each do |rkey|
  # Get list of status buffer keys that match pattern
  sbkeys = redis.hkeys(rkey).grep(pattern).sort
  # Skip to next if no keys match
  next if sbkeys.empty?
  # Get values for status buffer keys that match pattern
  sbvals = redis.hmget(rkey, *sbkeys)
  # Make cleaned up redis key name
  clean_key = rkey.sub(%r{^hashpipe://}, '')
  clean_key.sub!(%r{/status$}, '')
  # Print each matching sbkey with value
  sbkeys.each_with_index do |sbkey, i|
    sbval = sbvals[i]
    printf "%s %s %s\n", clean_key, sbkey, sbval
  end
end
