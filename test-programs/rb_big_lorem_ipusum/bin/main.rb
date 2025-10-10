#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../config/environment'
require 'rb_big_lorem_ipusum'

module RbBigLoremIpusum
  # Entrypoint used by QA teams to trigger representative execution paths.
  class Main
    def initialize
      @engine = Core::Engine.new
      @diff_harvester = Core::Pipelines::DiffHarvester.new
      @dashboard = UI::ConsoleDashboard.new
      @reporting_service = App::Services::ReportingService.new
      @algorithm_registry = App::Services::AlgorithmRegistry.new
      @call_storm = Core::Simulations::CallStorm.new(output: $stdout)
    end

    def run
      payload = @engine.bootstrap_fleet
      diffs = @diff_harvester.harvest(payload[:manifest], payload[:diff_targets])
      telemetry = Infrastructure::Telemetry::Aggregator.new.capture(payload[:fleet_metrics])
      announce_payload(payload[:mega_payload])
      render_dashboard(diffs, telemetry)
      render_algorithm_demos
      trigger_call_storm
      @reporting_service.persist(payload[:manifest], diffs, telemetry)
    rescue StandardError => e
      warn "[rb_big_lorem_ipusum] execution aborted: #{e.class}: #{e.message}\n#{e.backtrace.take(5).join("\n")}"
      exit 1
    end

    private

    def render_dashboard(diffs, telemetry)
      @dashboard.render(crew: diffs[:crew_map], diffs: diffs[:file_diff_summary], telemetry: telemetry)
    end

    def announce_payload(payloads)
      return if payloads.nil? || payloads.empty?

      sample = payloads.first
      puts "Mega payload sample signature: #{sample[:summary][:signature]} (catalog index #{sample[:index]})"
    end

    # Exercise multiple algorithms so diff tooling encounters varied call sites.
    def render_algorithm_demos
      demos = {
        shortest_paths: @algorithm_registry.run(:dijkstra, sample_graph, 0),
        lcs: @algorithm_registry.run(:lcs, 'galactic diff viewer', 'galactic view differ'),
        knapsack: @algorithm_registry.run(:knapsack, knapsack_items, 150)
      }
      puts "\n== Algorithm demo results =="
      demos.each do |name, result|
        puts "- #{name}: #{result.inspect}"
      end
    end

    def trigger_call_storm
      puts "\n== Call storm execution =="
      results = @call_storm.execute(seed_sequence: [6, 5, 7])
      results[:branches].each do |branch|
        puts "- seed #{branch[:seed]} => depth #{branch[:top][:depth]} score #{branch[:top][:score]}"
      end
    end

    def sample_graph
      {
        0 => { 1 => 4, 2 => 1 },
        1 => { 3 => 1 },
        2 => { 1 => 2, 3 => 5 },
        3 => {}
      }
    end

    def knapsack_items
      [
        { name: 'diff-cache', weight: 35, value: 120 },
        { name: 'render-cache', weight: 45, value: 180 },
        { name: 'ui-snapshot', weight: 25, value: 90 },
        { name: 'undo-stack', weight: 40, value: 110 }
      ]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  RbBigLoremIpusum::Main.new.run
end
