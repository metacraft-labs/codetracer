# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require_relative '../../../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  module Spec
    class CallStormSpec < Minitest::Test
      def test_execute_returns_branch_details
        storm = Core::Simulations::CallStorm.new(output: StringIO.new)
        result = storm.execute(seed_sequence: [3])

        assert_equal [3], result[:seeds]
        branch = result[:branches].first
        refute_nil branch[:top][:score]
        refute_nil branch[:top][:signature]
        refute_empty branch[:envelope]
      end
    end
  end
end
