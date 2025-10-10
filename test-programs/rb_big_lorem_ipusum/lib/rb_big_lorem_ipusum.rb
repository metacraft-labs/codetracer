# frozen_string_literal: true

require_relative 'rb_big_lorem_ipusum/version'
require_relative 'rb_big_lorem_ipusum/support/loader'

# Core components
require_relative 'rb_big_lorem_ipusum/core/engine'
require_relative 'rb_big_lorem_ipusum/core/pipelines/diff_harvester'
require_relative 'rb_big_lorem_ipusum/core/simulations/fleet_simulator'
require_relative 'rb_big_lorem_ipusum/core/simulations/call_storm'
require_relative 'rb_big_lorem_ipusum/core/analysis/analyzer'
require_relative 'rb_big_lorem_ipusum/core/mega_payload'

# Infrastructure
require_relative 'rb_big_lorem_ipusum/infrastructure/telemetry/aggregator'
require_relative 'rb_big_lorem_ipusum/infrastructure/telemetry/stream_serializer'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/archive_service'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/file_system_adapter'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/memory_adapter'
require_relative 'rb_big_lorem_ipusum/infrastructure/scheduling/orchestrator'

# UI
require_relative 'rb_big_lorem_ipusum/ui/console_dashboard'
require_relative 'rb_big_lorem_ipusum/ui/diff_summary_renderer'

# Algorithms
require_relative 'rb_big_lorem_ipusum/algorithms/graph/dijkstra'
require_relative 'rb_big_lorem_ipusum/algorithms/dynamic/longest_common_subsequence'
require_relative 'rb_big_lorem_ipusum/algorithms/dp/knapsack'

# Application layer wiring
require_relative '../app/controllers/navigation_controller'
require_relative '../app/controllers/diff_controller'
require_relative '../app/models/ship'
require_relative '../app/models/crew_member'
require_relative '../app/models/log_entry'
require_relative '../app/services/reporting_service'
require_relative '../app/services/algorithm_registry'
require_relative '../app/views/templates/dashboard_view'
