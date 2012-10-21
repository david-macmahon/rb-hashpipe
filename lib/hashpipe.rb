require 'rubygems'

# Require the hashpipe shared library
hashpipe_shared_lib = 'hashpipe.' + RbConfig::CONFIG['DLEXT']
require hashpipe_shared_lib
require 'hashpipe_gem' if false # Fake out RDoc

require 'hashpipe/version'
