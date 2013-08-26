require 'rubygems'

# Require the hashpipe shared library
hashpipe_shared_lib = 'hashpipe.' + RbConfig::CONFIG['DLEXT']
require hashpipe_shared_lib
require 'hashpipe_gem' if false # Fake out RDoc

require 'hashpipe/version'

module Hashpipe
  class Status

    alias :[]  :hgets
    alias :[]= :hputs

    # Return current buffer contents as a Hash
    def to_hash
      # Get buffer contents as a String
      s = lock {buf} rescue ''
      # Split into RECORD_SIZE character lines
      lines = s.scan(/.{#{RECORD_SIZE}}/o)
      # Skip END record
      lines.pop if lines[-1].start_with?('END ')

      # Parse lines into key and value
      h = {}
      lines.each do |l|
        key, value = l.split('=', 2)
        value ||= '' # In case no '='
        key.strip!
        value.strip!
        # If value is enclosed in single quotes, remove them and strip spaces
        value = value[1..-2].strip if /^'.*'$/ =~ value
        h[key] = value
      end
      h
    end # to_hash

    # Return a more user-friendly string than the default.
    def inspect
      "#<#{self.class} instance_id=#{instance_id}>"
    end

  end # class Status
end # module Hashpipe
