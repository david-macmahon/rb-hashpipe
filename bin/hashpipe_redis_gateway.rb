#!/usr/bin/env ruby

# hashpipe_redis_gateway.rb - A gateway daemon between Hashpipe status buffers
# and Redis.
#
# The contents of Hashpipe status buffer are periodically sent to Redis.  A
# redis hash is used to hold the Ruby hash returned by Status#to_hash.  The key
# used to refer to the redis hash is gateway/instance specific so status buffer
# hashes for multiple gateways and instances can all be stored in one Redis
# instance.  This key is known as the "status key".  When updated, the status
# key is also published on the "update channel".  The status key is set to
# expire after three times the delay interval.  The gateway name is typically
# the name of the gateway's host, but it need not be.
#
# Status key format:
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
# status buffer specific "set" channels, the broadcast "set" channel, a
# gateway specific "command" channel, and the broadcast "command" channel.
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
#   "hashpipe://#{gwname}/gateway"
#
#   Example: hashpipe://px1/gateway
#
# The broadcast command channel is used to send commands to all gateways.  The
# broadcast command channel is:
#
#   "hashpipe:///gateway"
#
# Messages sent to gateway command channels are expected to be in
# "command=args" format with multiple command/args pairs separated by newlines
# ("\n").  The format of args is command specific.  Currently, only one command
# is supported:
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
  :create       => false,
  :delay        => 1.0,
  :instance_ids => (0..3),
  :gwname       => Socket.gethostname,
  :server       => 'redishost',
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS]"
  op.separator('')
  op.separator('Gateway between Hashpipe status buffers and Redis server.')
  op.separator('')
  op.separator('Options:')
  op.on('-c', '--[no-]create',
        "Create missing status buffers [#{OPTS[:create]}]") do |o|
    OPTS[:create] = o
  end
  op.on('-d', '--delay=SECONDS', Float,
        "Delay between updates (0.25-60) [#{OPTS[:delay]}]") do |o|
    o = 0.25 if o < 0.25
    o = 60.0 if o > 60.0
    OPTS[:delay] = o
  end
  op.on('-g', '--gwname=GWNAME',
        "Gateway name [#{OPTS[:gwname]}]") do |o|
    OPTS[:gwname] = o
  end
  op.on('-i', '--instances=I[,...]', Array,
        "Instances to gateway [#{OPTS[:instance_ids]}]") do |o|
    OPTS[:instance_ids] = o.map {|s| Integer(s) rescue 0}
    OPTS[:instance_ids].uniq!
  end
  op.on('-s', '--server=NAME',
        "Host running redis-server [#{OPTS[:server]}]") do |o|
    OPTS[:server] = o
  end
  op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!
#p OPTS; exit

# STATUS_BUFS maps instance id (String or Integer) to Hashpipe::Status object.
STATUS_BUFS = {}
# Create Hashpipe::Status objects
instance_ids = []
OPTS[:instance_ids].each do |i|
  hps = Hashpipe::Status.new(i, OPTS[:create]) rescue nil
  if hps
    instance_ids << i
    STATUS_BUFS[i] = hps
    STATUS_BUFS["#{i}"] = hps
  end
end
#p STATUS_BUFS; exit

# If we got nothing, exit
if instance_ids.empty?
  puts "No status buffers to gateway"
  exit 1
end

puts "Gateway Hashpipe instances #{instance_ids.join(',')}"

# Set OPTS[:instance_ids] to those that we have
OPTS[:instance_ids] = instance_ids

# Create subscribe channel names
SBSET_CHANNELS = OPTS[:instance_ids].map do |i|
  "hashpipe://#{OPTS[:gwname]}/#{i}/set"
end
BCASTSET_CHANNEL = 'hashpipe:///set'
GWCMD_CHANNEL = "hashpipe://#{OPTS[:gwname]}/gateway"
BCASTCMD_CHANNEL = 'hashpipe:///gateway'

# Create subscribe thread
Thread.new do
  # Create Redis object for subscribing
  subscriber = Redis.new(:host => OPTS[:server])
  subscriber.subscribe(BCASTSET_CHANNEL, BCASTCMD_CHANNEL,
                       GWCMD_CHANNEL, *SBSET_CHANNELS) do |on|
    on.message do |chan, msg|
      case chan
      # Set channels
      when BCASTSET_CHANNEL, *SBSET_CHANNELS
        insts = case chan
                when BCASTSET_CHANNEL; OPTS[:instance_ids]
                when %r{/(\w+)/set}; [$1]
                end

        pairs = msg.split("\n").map {|s| s.split('=')}
        insts.each do |i|
          sb = STATUS_BUFS[i]
          pairs.each {|k,v| sb[k] = v}
        end

      # Gateway channels
      when BCASTCMD_CHANNEL, GWCMD_CHANNEL
        pairs = msg.split("\n").map {|s| s.split('=')}
        pairs.each do |k,v|
          case k
          when 'delay', 'DELAY'
            delay = Float(v) rescue 1.0
            delay = 0.25 if delay < 0.25
            delay = 60.0 if delay > 60.0
            OPTS[:delay] = delay
            # Wake up main thread
            Thread.main.wakeup
          end
        end

      end # case chan
    end # on.message
  end # subcribe
end # subscribe thread

# Updates redis with contents of status_bufs and publishes each statusbuf's key
# on its "update" channel (if +notify+ is true).
#
def update_redis(redis, instance_ids, notify=false)
  # Pipeline all status buffer updates
  redis.pipelined do
    instance_ids.each do |iid|
      sb = STATUS_BUFS[iid]
      # Each status buffer update happens in a transaction
      redis.multi do
        key = "hashpipe://#{OPTS[:gwname]}/#{iid}/status"
        redis.del(key)
        redis.mapped_hmset(key, sb.to_hash)
        redis.expire(key, 3*OPTS[:delay])
        if notify
          # Publish "updated" method to notify subscribers
          channel = "hashpipe://#{OPTS[:gwname]}/#{iid}/update"
          redis.publish channel, key
        end
      end # redis.multi
    end # status_bufs,each
  end # redis.pipelined
end # def update_redis

# Create Redis object
redis = Redis.new(:host => OPTS[:server])

# Loop "forever"
while
  update_redis(redis, OPTS[:instance_ids])
  # Delay before doing it again
  sleep OPTS[:delay]
end
