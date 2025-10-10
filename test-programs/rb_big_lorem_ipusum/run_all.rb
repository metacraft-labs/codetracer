#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'config/environment'
require 'rb_big_lorem_ipusum'

puts '== rb_big_lorem_ipusum full execution =='

engine = RbBigLoremIpusum::Core::Engine.new
payload = engine.bootstrap_fleet
puts "Bootstrapped #{payload[:manifest][:ships].length} ships"

diff_harvester = RbBigLoremIpusum::Core::Pipelines::DiffHarvester.new
diffs = diff_harvester.harvest(payload[:manifest], payload[:diff_targets])
puts "Harvested #{diffs[:file_diff_summary].keys.length} diff targets"

diagnostics = RbBigLoremIpusum::Features::DiffDiagnostics::Analyzer.new
diagnostics.emit_summary(diffs[:file_diff_summary].to_a)

aggregator = RbBigLoremIpusum::Infrastructure::Telemetry::Aggregator.new
telemetry = aggregator.capture(payload[:fleet_metrics])
puts "Captured telemetry streams: #{telemetry.keys.join(', ')}"

dashboard = RbBigLoremIpusum::UI::ConsoleDashboard.new
dashboard.render(crew: diffs[:crew_map], diffs: diffs[:file_diff_summary], telemetry: telemetry)

mega_payload = RbBigLoremIpusum::Core::MegaPayload.generate_payloads(2)
puts "\n== Mega payload excerpts =="
mega_payload.each do |entry|
  puts "Payload #{entry[:index]} signature=#{entry[:summary][:signature]} depth=#{entry[:trace].length}"
end

algo_registry = RbBigLoremIpusum::Algorithms::AlgorithmRegistry.new
puts "\n== Algorithm runs =="
graph = { 0 => { 1 => 2, 2 => 5 }, 1 => { 2 => 1 }, 2 => { 3 => 2 }, 3 => {} }
puts "Dijkstra: #{algo_registry.run(:dijkstra, graph, 0)}"
puts "LCS: #{algo_registry.run(:lcs, 'diff viewer', 'viewer diff')}"
knapsack_items = [
  { name: 'alpha', weight: 20, value: 60 },
  { name: 'beta', weight: 35, value: 90 },
  { name: 'gamma', weight: 15, value: 45 }
]
puts "Knapsack: #{algo_registry.run(:knapsack, knapsack_items, 50)}"

nav_controller = RbBigLoremIpusum::App::Controllers::NavigationController.new(algorithm_registry: algo_registry)
sample_ship = payload[:manifest][:ships].first
routes = nav_controller.routes_for(sample_ship)
puts "\nNavigation routes for #{sample_ship.identifier}:"
puts routes.inspect

diff_controller = RbBigLoremIpusum::App::Controllers::DiffController.new
sample_path, _ = diffs[:file_diff_summary].first
diff_body = "// headline change\nline one\nline two\nline three\nline four"
drill_down = diff_controller.drill_down(sample_path, diff_body)
puts "\nDrill down for #{sample_path}:"
puts drill_down.inspect

reporting = RbBigLoremIpusum::App::ServiceLayer::ReportingService.new
reports = reporting.persist(payload[:manifest], diffs, telemetry)
puts "\nPersisted #{reports.length} report entries"

call_storm = RbBigLoremIpusum::Core::Simulations::CallStorm.new
puts "\n== Call storm run =="
storm_results = call_storm.execute(seed_sequence: [3, 2])
storm_results[:branches].each do |branch|
  puts "Seed #{branch[:seed]} depth #{branch[:top][:depth]} score #{branch[:top][:score]}"
end

puts "\n== Completed full execution =="
