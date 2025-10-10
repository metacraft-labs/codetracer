# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  module Spec
    class WorkflowSpec < Minitest::Test
      def test_main_run_executes_without_error
        main = Main.new
        assert_silent { main.run }
      end
    end
  end
end
