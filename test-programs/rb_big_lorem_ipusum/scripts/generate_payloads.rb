#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../config/environment'
require 'rb_big_lorem_ipusum'

engine = RbBigLoremIpusum::Core::Engine.new
payload = engine.bootstrap_fleet
puts "Generated manifest with #{payload[:manifest][:ships].length} ships"
