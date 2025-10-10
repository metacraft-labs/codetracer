# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  module Spec
    class EngineSpec < Minitest::Test
      def setup
        @engine = Core::Engine.new
      end

      def test_bootstrap_fleet_generates_manifest
        payload = @engine.bootstrap_fleet
        assert_equal 12, payload[:manifest][:ships].length
        refute_empty payload[:diff_targets][:file_diff_summary]
        refute_empty payload[:fleet_metrics]
      end
    end
  end
end
