# frozen_string_literal: true

require 'json'
require 'fileutils'

module RbBigLoremIpusum
  module Infrastructure
    module Storage
      class FileSystemAdapter
        ROOT = File.expand_path('../../../../tmp/rb_big_lorem_ipusum', __dir__)

        def initialize(root: ROOT)
          @root = root
        end

        def persist(relative_path, payload)
          absolute = File.join(@root, relative_path)
          FileUtils.mkdir_p(File.dirname(absolute))
          File.write(absolute, JSON.pretty_generate(payload))
        rescue Errno::EACCES => e
          warn "Unable to persist #{relative_path}: #{e.message}"
        end
      end
    end
  end
end
