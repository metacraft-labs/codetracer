# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  module Spec
    class StorageSpec < Minitest::Test
      def setup
        @archive = Infrastructure::Storage::ArchiveService.new
      end

      def test_snapshot_persists_manifest
        manifest = { ships: [], crew_map: {} }
        result = @archive.snapshot(manifest)
        assert result[:serialized_at]
      end
    end
  end
end
