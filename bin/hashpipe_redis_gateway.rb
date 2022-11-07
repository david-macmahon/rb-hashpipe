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
# The command channels can be used to send commands to the gateway itself.
# Command channels exist at the instance, gateway, and broadcast levels.
#
# The format of the instance specific command channel is:
#
#   "hashpipe://#{gwname}/#{instance_id}/gateway"
#
#   Example: hashpipe://px1/0/gateway
#
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
# ("\n").  The format of args is command specific.  Currently, four commands
# are supported:
#
#   delay=SECONDS - Sets the delay between updates to SECONDS seconds.  Note
#                   that SECONDS is interpreted as a floating point number
#                   (e.g. "0.25").
#
#   join=GROUP - Joins the group "GROUP" for the gateway instances associated
#                with the command channel.  Unicast (i.e. instance specific)
#                command channels will join the group for that instance only.
#                Gateway or broadcast command channels will join the group for
#                all instances of this gateway.  If no instances of this
#                gateway had previously joined the group, then the gateway will
#                subscribe to the group "set" channel "hashpipe:GROUP///set".
#
#   leave=GROUP - Leaves the group "GROUP" for the gateway instances associated
#                 with the command channel.  Unicast (i.e. instance specific)
#                 command channels will leave the group for that instance only.
#                 Gateway or broadcast command channels will leave the group
#                 for all instances of this gateway.  If no instances of this
#                 gateway remain joined the group, then the gateway will
#                 unsubscribe from the group "set" channel
#                 "hashpipe:GROUP///set".
#
#   quit - Causes the gateway process to exit.
#
# # PROMETHEUS EXPORTER
#
# The gateway can also start a Prometheus exporter to expose user-specified
# status buffer fields as Prometheus metrics.  A YAML file is used to specify
# the metric name (default: 'hashpipe_status_buffer'), the port on which to
# listen (default: 9661), and an array of field specifiers detailing which
# fields to export and how to export them.  A field specifier consists of the
# name of the field and an optional boolean flag indicating whether the field
# is a string.  The field will be assumed to be numeric if the "string" flag is
# not provided (or if it's false).  All metrics have an "hpinstance" label
# whose value is the Hashpipe host/instance and "name" label whose value is the
# field's name.  The metric value for numeric fields be the status buffer
# values converted to floating point.  String fields will have their value
# stored as the value of the "value" label and will have a value of 1.
#
# Here is the required structure of the YAML file:
#
#     port: 9661
#     name: hashpipe_status_buffer
#     help: Hashpipe status buffer field
#     fields:
#       - name: RA
#       - name: DEC
#       - name: SRC_NAME
#         string: true
#
# This will result in the following metrics (assuming gateway domain "bluse",
# and Hashpipe instance "blpn48/0"):
#
#     # HELP hashpipe_status_buffer Status buffer fields for hpguppi_daq
#     # TYPE hashpipe_status_buffer gauge
#     hashpipe_status_buffer{domain="bluse", hpinstance="blpn48/0", name="RA"} 156.3626
#     hashpipe_status_buffer{domain="bluse", hpinstance="blpn48/0", name="DEC"} 46.6493
#     hashpipe_status_buffer{domain="bluse", hpinstance="blpn48/0", name="SRC_NAME", value="3C295"} 1

require 'rubygems'
require 'optparse'
require 'socket'
require 'set'
require 'redis'
require 'hashpipe'

DEFAULT_EXPORTER_PORT = 9661

OPTS = {
  :create       => false,
  :delay        => 1.0,
  :domain       => 'hashpipe',
  :instance_ids => (0..3),
  :foreground   => false,
  :gwname       => Socket.gethostname,
  :notify       => false,
  :server       => 'redishost',
  :expire       => true,
  :prometheus   => nil
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
  op.on('-D', '--domain=DOMAIN',
        "Domain for Redis channels/keys [#{OPTS[:domain]}]") do |o|
    OPTS[:domain] = o
  end
  op.on('-f', '--[no-]foreground',
        "Run in foreground [#{OPTS[:foreground]}]") do |o|
    OPTS[:foreground] = o
  end
  op.on('-g', '--gwname=GWNAME',
        "Name of this gateway [#{OPTS[:gwname]}]") do |o|
    OPTS[:gwname] = o
  end
  op.on('-i', '--instances=I[,I[...]]', Array,
        "Instances to gateway [#{OPTS[:instance_ids]}]") do |o|
    OPTS[:instance_ids] = o.map {|s| Integer(s) rescue 0}
    OPTS[:instance_ids].uniq!
  end
  op.on('-n', '--[no-]notify',
        "Publish update notifications [#{OPTS[:notify]}]") do |o|
    OPTS[:notify] = o
  end
  op.on('-p', '--prometheus=CONFFILE',
        "Export metrics as specified in CONFFILE [no export]") do |o|
    require 'yaml'
    OPTS[:prometheus] = YAML.load_file(o)
  end
  op.on('-s', '--server=NAME',
        "Host running redis-server [#{OPTS[:server]}]") do |o|
    OPTS[:server] = o
  end
  op.on('-x', '--no-expire',
        "Disable expiration of redis keys") do |o|
    OPTS[:expire] = o
  end
  op.separator('')
  op.on_tail('-h','--help','Show this message') do
    puts op.help
    exit
  end
end
OP.parse!
#p OPTS; exit

# Use un-buffered stdout
STDOUT.sync = true

# Become a daemon process unless running in foreground was requested
Process.daemon unless OPTS[:foreground]

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

gwinst_list = instance_ids.map {|i| "#{OPTS[:gwname]}/#{i}"}
puts "Gateway Hashpipe instances: #{gwinst_list.join(' ')}"

# Set OPTS[:instance_ids] to those that we have
OPTS[:instance_ids] = instance_ids

# Create subscribe channel names
SBSET_CHANNELS = OPTS[:instance_ids].map do |i|
  "#{OPTS[:domain]}://#{OPTS[:gwname]}/#{i}/set"
end
SBREQ_CHANNELS = OPTS[:instance_ids].map do |i|
  "#{OPTS[:domain]}://#{OPTS[:gwname]}/#{i}/req"
end
BCASTSET_CHANNEL = "#{OPTS[:domain]}:///set"
BCASTREQ_CHANNEL = "#{OPTS[:domain]}:///req"

SBCMD_CHANNELS = OPTS[:instance_ids].map do |i|
  "#{OPTS[:domain]}://#{OPTS[:gwname]}/#{i}/gateway"
end
GWCMD_CHANNEL = "#{OPTS[:domain]}://#{OPTS[:gwname]}/gateway"
BCASTCMD_CHANNEL = "#{OPTS[:domain]}:///gateway"

# Hash mappping the "set" channels we have joined to the Set of instance IDs
# associated with that group "set" channel.  It is possible for different
# instances handled by a gateway to join different groups.  So we track that
# part of that instance specific aspect of group membership here.
grset_chan_to_insts = {}

# Create subscribe thread
subscribe_thread = Thread.new do
  # Create Redis objects for publishing/subscribing
  publisher  = Redis.new(:host => OPTS[:server])
  subscriber = Redis.new(:host => OPTS[:server])
  subscriber.subscribe(BCASTSET_CHANNEL, *SBSET_CHANNELS,
                       BCASTREQ_CHANNEL, *SBREQ_CHANNELS,
                       BCASTCMD_CHANNEL, GWCMD_CHANNEL, *SBCMD_CHANNELS) do |on|
    on.message do |chan, msg|
      case chan
      # Set channels
      when BCASTSET_CHANNEL, *SBSET_CHANNELS, *grset_chan_to_insts.keys
        insts = case chan
                when BCASTSET_CHANNEL; OPTS[:instance_ids] # "broadcast"
                when %r{://[^/]+/([^/]+)/set}; [$1]        # "unicast"
                else grset_chan_to_insts[chan]||[]         # "multicast/group"
                end

        pairs = msg.split("\n").map {|s| s.split('=')}
        insts.each do |i|
          sb = STATUS_BUFS[i]
          pairs.each do |k,v|
            if k.nil? or k.empty?
              STDERR.puts "invalid key #{k.inspect} (value #{v.inspect})"
              next
            end

            if v.nil? or v.empty?
              STDERR.puts "invalid value #{v.inspect} (key #{k.inspect})"
              next
            end

            # If v is all digits, convert to Integer
            # otherwise try to convert to Float
            if /^\d+$/ =~ v
              v = v.to_i
            else
              v = Float(v) rescue v
            end

            sb.lock do
              case v
              when Integer; sb.hputi8(k, v)
              when Float;   sb.hputr8(k, v)
              else sb.hputs(k, v)
              end
            end
          end
        end

      when BCASTREQ_CHANNEL, *SBREQ_CHANNELS
        insts = case chan
                when BCASTREQ_CHANNEL; OPTS[:instance_ids]
                when %r{/(\w+)/req}; [$1]
                end

        keys = msg.split("\n")
        insts.each do |inst|
          sb = STATUS_BUFS[inst]
          resp = []
          sb.lock do
            resp = keys.map do |k|
              v = sb.hgets(k)
              if OPTS[:foreground]
                puts "#{OPTS[:gwname]}/#{inst} #{k}=#{v} (#{v.class})"
              end
              "#{k}=#{v}"
            end
          end
          publisher.publish("#{OPTS[:domain]}://#{OPTS[:gwname]}/#{inst}/rep", resp.join("\n"))
        end

      # Gateway channels
      when BCASTCMD_CHANNEL, GWCMD_CHANNEL, *SBCMD_CHANNELS
        pairs = msg.split("\n").map {|s| s.split('=')}
        pairs.each do |k,v|
          case k
          when /quit/i
            puts "got quit command"
            return
          when 'delay', 'DELAY'
            delay = Float(v) rescue 1.0
            delay = 0.25 if delay < 0.25
            delay = 60.0 if delay > 60.0
            OPTS[:delay] = delay
            # Wake up main thread
            Thread.main.wakeup

          when 'join', 'JOIN'
            insts = case chan
                    when %r{//[^/]+/([^/]+)/gateway}; [$1] # "unicast"
                    else OPTS[:instance_ids] # "broadcast" or "gateway"
                    end
            group = v
            grset_channel = "#{OPTS[:domain]}:#{group}///set"
            puts "joining group #{group} for instances #{insts.inspect}"
            # If we have no mapping for this group
            if !grset_chan_to_insts[grset_channel]
              # Create empty mapping
              grset_chan_to_insts[grset_channel] = Set.new()
              # Subscribe to group set channel
              puts "subscribing to channel #{grset_channel}"
              subscriber.subscribe(grset_channel)
            end
            # Add instances to mapping
            grset_chan_to_insts[grset_channel] += insts

          when 'leave', 'LEAVE'
            insts = case chan
                    when %r{//[^/]+/([^/]+)/gateway}; [$1] # "unicast"
                    else OPTS[:instance_ids] # "broadcast" or "gateway"
                    end
            group = v
            grset_channel = "#{OPTS[:domain]}:#{group}///set"
            puts "leaving group #{group} for instances #{insts.inspect}"
            # If we have a mapping for this group
            if grset_chan_to_insts[grset_channel]
              grset_chan_to_insts[grset_channel] -= insts
              # If no more instances are associated with this group
              if grset_chan_to_insts[grset_channel].empty?
                # Remove empty mapping
                grset_chan_to_insts.delete(grset_channel)
                # Unsubscribe from group set channel
                puts "unsubscribing from #{grset_channel}"
                subscriber.unsubscribe(grset_channel)
              end
            end
          end
        end

      end # case chan
    end # on.message
  end # subcribe
end # subscribe thread

def export_metrics(req, res)
  start = Time.now
  body = StringIO.new

  metric = OPTS[:prometheus]['name']

  if OPTS[:prometheus]['fields']
    help   = OPTS[:prometheus]['help']
    body.puts "# HELP #{metric} #{help}"
    body.puts "# TYPE #{metric} gauge"

    OPTS[:instance_ids].each do |iid|
      sb = STATUS_BUFS[iid].to_hash
      OPTS[:prometheus]['fields'].each do |field|
        name = field['name']
        value = sb[name]
        next unless value

        body.print "#{metric}{domain=\"#{OPTS[:domain]}\", " +
                   "hpinstance=\"#{OPTS[:gwname]}/#{iid}\", " +
                   "name=\"#{name}\""

        if field['string']
          body.print ", value=\"#{value}\""
          value = 1
        else
          value = value.to_r.to_f
        end

        body.puts "} #{value}"
      end
    end
  end

  body.puts "# HELP #{metric}_scrape_duration_seconds " +
            "Number of seconds to scrape the #{metric} exporter"
  body.puts "# TYPE #{metric}_scrape_duration_seconds gauge"
  body.puts "#{metric}_scrape_duration_seconds{domain=\"#{OPTS[:domain]}\", " +
            "gateway=\"#{OPTS[:gwname]}\"} #{(Time.now-start).to_f}"

  if req.accept_encoding.index('gzip')
    res['Content-Encoding'] = 'gzip'
    res.body = Zlib.gzip(body.string)
  else
    res.body = body.string
  end
  res.status = 200
end

exporter_thread = nil

if OPTS[:prometheus]
  # Require additional packages
  require 'stringio'
  require 'webrick'
  require 'zlib'
  # Set defaults as needed
  OPTS[:prometheus]['bind'] ||= '0.0.0.0'
  OPTS[:prometheus]['port'] ||= DEFAULT_EXPORTER_PORT
  OPTS[:prometheus]['name'] ||= 'hashpipe_status_buffer'
  OPTS[:prometheus]['help'] ||= 'Hashpipe status buffer field'

  # Create webrick server (with no logging)
  OPTS[:exporter] = WEBrick::HTTPServer.new(
    BindAddress: OPTS[:prometheus]['bind'],
    Port: OPTS[:prometheus]['port'],
    AccessLog: [],
    Logger: WEBrick::Log.new(File::NULL)
  )

  OPTS[:exporter].mount_proc '/' do |req, res|
    res.body = '<html><head><title>' +
               "Hashpipe #{OPTS[:domain]}://#{OPTS[:gwname]} Exporter" +
               '</title></head><body><h1>' +
               "Hashpipe #{OPTS[:domain]}://#{OPTS[:gwname]} Exporter" +
               '</h1><p><a href="/metrics">Metrics</a></p></body></html>'
    res.status = 200
  end

  OPTS[:exporter].mount_proc '/metrics' do |req, res|
    export_metrics(req, res)
  end

  exporter_thread = Thread.new {OPTS[:exporter].start}
end

['INT', 'TERM'].each do |sig|
  trap sig do
    OPTS[:exporter].shutdown if OPTS[:exporter]
    exporter_thread.join if exporter_thread
    subscribe_thread.kill
  end
end

# Updates redis with contents of status_bufs and publishes each statusbuf's key
# on its "update" channel (if +notify+ is true).
#
def update_redis(redis, instance_ids, notify=false)
  # Pipeline all status buffer updates
  redis.pipelined do |pipeline|
    instance_ids.each do |iid|
      sb = STATUS_BUFS[iid]
      # Each status buffer update happens in a transaction
      pipeline.multi do |transaction|
        key = "#{OPTS[:domain]}://#{OPTS[:gwname]}/#{iid}/status"
        transaction.del(key)
        sb_hash = sb.to_hash
        transaction.mapped_hmset(key, sb_hash)
        # Expire time must be integer, we always round up
        transaction.expire(key, (3*OPTS[:delay]).ceil) if OPTS[:expire]
        if notify
          # Publish "updated" method to notify subscribers
          channel = "#{OPTS[:domain]}://#{OPTS[:gwname]}/#{iid}/update"
          transaction.publish channel, key
        end
      end # pipeline.multi
    end # status_bufs,each
  end # redis.pipelined
end # def update_redis

# Create Redis object
redis = Redis.new(:host => OPTS[:server])

# Loop until subscribe_thread stops
while subscribe_thread.alive?
  update_redis(redis, OPTS[:instance_ids], OPTS[:notify])
  # Delay before doing it again
  sleep OPTS[:delay]
end

# Ensure the web server gets shutdown
OPTS[:exporter].shutdown if OPTS[:exporter]
exporter_thread.join if exporter_thread
