#!/usr/bin/env ruby

# hashpipe_redis_gateway.rb - A gateway daemon between Hashpipe status buffers
# and Redis.
#
# The contents of Hashpipe status buffer are periodically sent to Redis.  A
# redis hash is used to hold the Ruby hash returned by Status#to_hash.  The key
# used to refer to the redis hash is gateway/instance specific so status buffer
# hashes for multiple gateways and instances can all be stored in one Redis
# instance.  The updated key is also published on the "update channel".  The
# gateway name is typically the name of the gateway's host, but it need not be.
#
# Key format:
#
#   "hashpipe://#{gwname}/#{instance_id}/status"
#
#   Example: hashpipe://px1/0/status
#
# Update channel format:
#
#   "hashpipe://#{gwname}/#{instance_id}/update"
#
#   Example: hashpipe://px1/0/update
#
# Additionally, a thread is started that subscribes to "command channels" so
# that key/value pairs can be published via Redis.  Recevied key/value pairs
# are stored in the status buffers as appropriate for the channel on which they
# arrive.  Each gateway instance subscribes to multiple command channels:
# status buffer specific "set" channels, the broadcast "set" channel, and a
# gateway specific "command" channel.
#
# Status buffer "set" channels are used to set fields in a specific status
# buffer instance.  The format of the status buffer specific "set" channel is:
#
#   "hashpipe://#{gwname}/#{instance_id}/set"
#
#   Example: hashpipe://px1/0/set
#
# The broadcast "set" channel is used to set fields in all status buffer
# instances.  The broadcast "set" channel is:
#
#   "hashpipe:///set"
#
# Messages sent to "set" channels are expected to be in "key=value" format with
# multiple key/value pairs separated by newlines ("\n").
#
# The gateway command channel is used to send commands to the gateway itself.
# The format of the gateway command channel is:
#
#   "hashpipe://#{gwname}/command"
#
#   Example: hashpipe://px1/command
#
# Messages sent to "set" channels are expected to be in "command=args" format with
# multiple command/args pairs separated by newlines ("\n").  The format of args
# is command specific.  Currently, only one command is supported:
#
#   delay=SECONDS - Sets the delay between updates to SECONDS seconds.  Note
#                   that SECONDS is interpreted as a floating point number
#                   (e.g. "0.25").

require 'rubygems'
require 'optparse'
require 'socket'
require 'redis'
require 'hashpipe'

OPTS = {
  :delay     => 0.25,
  :instances => (0..3),
  :name      => Socket.gethostname,
  :server    => 'redishost',
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS]"
  op.separator('')
  op.separator('Gateway between Hashpipe status buffers and Redis server.')
  op.separator('')
  op.separator('Options:')
  op.on('-d', '--delay=SECONDS', Float, "Delay between updates (0.25-60) [#{OPTS[:delay]}]") do |o|
    o = 0.25 if o < 0.25
    o = 60.0 if o > 60.0
    OPTS[:delay] = o
  end
  op.on('-i', '--instances=NX,...', Array, "Instances to gateway [#{OPTS[:instances]}]") do |o|
    OPTS[:instances] = o.map {|s| Integer(s) rescue 0}
    OPTS[:instances].uniq!
  end
  op.on('-n', '--name=NAME', "Alternate name to use in keys [#{OPTS[:name]}]") do |o|
    OPTS[:name] = o
  end
  op.on('-s', '--server=NAME', "Name of host running redis-server [#{OPTS[:server]}]") do |o|
    OPTS[:server] = o
  end
  #op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!

# Updates redis with contents of status_bufs and publishes each statusbuf's key
# on its "update" channel (if +publish+ is true).
#
def update_redis(redis, status_bufs, publish=false)
  # Pipeline all status buffer updates
  redis.pipelined do
    status_bufs.each do |sb|
      # Each status buffer update happens in a transaction
      redis.multi do
        key = "hashpipe://#{OPTS[:name]}/#{sb.instance_id}/status"
        redis.del(key)
        redis.mapped_hmset(key, sb.to_hash)
        if publish
          # Publish "updated" method to notify subscribers
          channel = "hashpipe://#{OPTS[:name]}/#{sb.instance_id}/update"
          redis.publish channel, key
        end
      end # redis.multi
    end # status_bufs,each
  end # redis.pipelined
end # def update_redis

# Create Redis object
redis = Redis.new(:host => OPTS[:server])

# Create Hashpipe::Status objects
status_bufs = OPTS[:instances].map {|i| Hashpipe::Status.new(i, false) rescue nil}
status_bufs.compact!
#p status_bufs

# Loop "forever"
while
  update_redis(redis, status_bufs)
  # Delay before doing it again
  sleep OPTS[:delay]
end
