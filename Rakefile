require 'rubygems'
require 'rubygems/package_task'

# Get Hashpipe::VERSION
require './lib/hashpipe/version.rb'

spec = Gem::Specification.new do |s|
  # Basics
  s.name = 'hashpipe'
  s.version = Hashpipe::VERSION
  s.summary = 'Ruby interface to Hashpipe library'
  s.description = <<-EOD
    This is the Ruby interface to the Hashpipe library.  Hashpipe is the High
    Availability PIPeline Engine.  Currently, Hashpipe only provides library
    access to the Hashpipe status buffers.
    EOD
  #s.platform = Gem::Platform::Ruby
  s.required_ruby_version = '>= 1.8.1'

  # About
  s.authors = 'David MacMahon'
  s.email = 'davidm@astro.berkeley.edu'
  s.homepage = 'http://rb-hashpipe.rubyforge.org/'
  s.rubyforge_project = 'rb-hashpipe' 

  # Files, Libraries, and Extensions
  s.files = %w[
    lib/hashpipe.rb
    lib/hashpipe/version.rb
    ext/extconf.rb
    ext/rb_hashpipe.c
    ext/rb_run_threads.c
  ]
  s.require_paths = ['lib']
  #s.autorequire = nil
  #s.bindir = 'bin'
  #s.executables = []
  #s.default_executable = nil

  # C compilation
  s.extensions = %w[ ext/extconf.rb ]

  # Documentation
  s.rdoc_options = ['--title', "Ruby/Hashpipe #{s.version} Documentation"]
  s.has_rdoc = true
  s.extra_rdoc_files = []

  # Testing TODO
  #s.test_files = [test/test.rb]
end

Gem::PackageTask.new(spec) do |pkg|
  pkg.need_zip = true
  pkg.need_tar = true
end
