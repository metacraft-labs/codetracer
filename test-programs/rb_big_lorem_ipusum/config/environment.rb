# frozen_string_literal: true

root = File.expand_path('..', __dir__)
lib_path = File.join(root, 'lib')
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

require_relative 'settings/telemetry'