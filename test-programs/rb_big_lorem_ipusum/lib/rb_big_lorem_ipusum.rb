# frozen_string_literal: true

require_relative 'rb_big_lorem_ipusum/version'
require_relative 'rb_big_lorem_ipusum/support/loader'
require_relative 'rb_big_lorem_ipusum/features/diff_diagnostics/analyzer'

# Core components
require_relative 'rb_big_lorem_ipusum/core/engine'
require_relative 'rb_big_lorem_ipusum/core/pipelines/diff_harvester'
require_relative 'rb_big_lorem_ipusum/core/simulations/fleet_simulator'
require_relative 'rb_big_lorem_ipusum/core/simulations/call_storm'
require_relative 'rb_big_lorem_ipusum/core/analysis/analyzer'
require_relative 'rb_big_lorem_ipusum/core/mega_payload'

# Infrastructure
require_relative 'rb_big_lorem_ipusum/infrastructure/telemetry/aggregator_support'
require_relative 'rb_big_lorem_ipusum/infrastructure/telemetry/aggregator'
require_relative 'rb_big_lorem_ipusum/infrastructure/telemetry/processors/stream_serializer'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/archive_service'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/file_system_adapter'
require_relative 'rb_big_lorem_ipusum/infrastructure/storage/memory_buffer'
require_relative 'rb_big_lorem_ipusum/infrastructure/scheduling/orchestrator'

# UI
require_relative 'rb_big_lorem_ipusum/ui/dashboard_toolkit'

# Algorithms
require_relative 'rb_big_lorem_ipusum/algorithms/graph/dijkstra'
require_relative 'rb_big_lorem_ipusum/algorithms/dynamic/longest_common_subsequence'
require_relative 'rb_big_lorem_ipusum/algorithms/dp/knapsack'

# Application layer wiring
require_relative '../app/controllers/navigation_controller'
require_relative '../app/controllers/diff_controller'
require_relative '../app/domain/entities/ship'
require_relative '../app/domain/entities/crew_member'
require_relative '../app/domain/logging/log_entry'
require_relative '../app/service_layer/reporting_service'
require_relative 'rb_big_lorem_ipusum/algorithms/algorithm_registry'
require_relative '../app/views/templates/dashboard_view'
