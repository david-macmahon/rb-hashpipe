#!/usr/bin/env ruby

# hashpipe_redis_gateway.rb - A gateway daemon between Hashpipe status buffers
# and Redis.
#
# The contents of Hashpipe status buffer are periodically sent to Redis.  A
# redis hash is used to hold the Ruby hash returned by Status#to_hash.  The key
# used to refer to the redis hash is host/instance specific so status buffer
# hashes for multiple hosts and instances can all be stored in one Redis
# instance.
#
# Additionally, a thread is started that subscribes to "command channels" so
# that key/value pairs can be published via Redis.  Recevied key/value pairs
# are stored in the status buffers as appropriate for the channel on which they
# arrive.

require 'rubygems'
require 'optparse'
require 'socket'
require 'redis'
require 'hashpipe'

OPTS = {
  :instances => (0..3),
  :name    => Socket.gethostname,
  :server  => 'redishost',
}

OP = OptionParser.new do |op|
  op.program_name = File.basename($0)

  op.banner = "Usage: #{op.program_name} [OPTIONS]"
  op.separator('')
  op.separator('Gateway between Hashpipe status buffers and Redis server.')
  op.separator('')
  op.separator('Options:')
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
# Key format:
#
#   "hashpipe://#{name}/#{instance_id}/status"
#
#   Example: hashpipe://px1/0/status
#
# Update channel format:
#
#   "hashpipe://#{name}/#{instance_id}/update"
#
#   Example: : hashpipe://px1/0/update
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
  # Do it again in 0.25 seconds
  sleep 0.25
end
