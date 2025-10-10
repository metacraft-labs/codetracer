# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require_relative '../../../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  module Spec
    class ConsoleDashboardSpec < Minitest::Test
      def test_render_outputs_roles
        dashboard = UI::ConsoleDashboard.new
        output = StringIO.new
        $stdout = output
        dashboard.render(
          crew: { pilot: [App::Domain::Entities::CrewMember.new(name: 'Pilot 1', role: 'pilot', certifications: [], on_call: false)] },
          diffs: { 'file.rb' => { added: [{ payload: 'line', path: 'file.rb', first_line: false }], removed: [] } },
          telemetry: { diff_rendering: [{ ship: 'RB-000', metrics: [] }] }
        )
        $stdout = STDOUT
        assert_includes output.string, 'Role: pilot'
      ensure
        $stdout = STDOUT
      end
    end
  end
end
