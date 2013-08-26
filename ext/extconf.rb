# extconf.rb : Configure script for rb-hashpipe
#
#   Copyright (c) 2009 David MacMahon <davidm@astro.berkeley.edu>
#
#   This program is free software.
#   You can distribute/modify this program
#   under the same terms as Ruby itself.
#   NO WARRANTY.
#
# usage: ruby extconf.rb [configure options]

require 'mkmf'

# configure options:
#  --with-hashpipe-dir=path
#  --with-hashpipe-include=path
#  --with-hashpipe-lib=path
dir_config('hashpipe')

# Check for hashpipe_status.h header
exit unless have_header('hashpipe_status.h')

# Check for libhashpipestatus library.  Need to include rb_run_threads.c so
# test program will define global run_threads variable needed by
# libhashpipestatus.
exit unless have_library('hashpipestatus',
                         'hashpipe_status_attach')

# Generate Makefile
create_makefile("hashpipe")
