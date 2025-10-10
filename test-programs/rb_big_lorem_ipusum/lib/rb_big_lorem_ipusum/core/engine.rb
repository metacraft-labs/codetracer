# frozen_string_literal: true

module RbBigLoremIpusum
  module Core
    # Coordinates the synthetic fleet simulation and ensures each component exposes
    # consistent data for diff tooling.
    class Engine
      CREW_ROLES = %w[analyst botanist captain mechanic pilot scientist].freeze

      def initialize(simulator: Simulations::FleetSimulator.new,
                     analyzer: Analysis::Analyzer.new,
                     scheduler: Infrastructure::Scheduling::Orchestrator.new,
                     archive: Infrastructure::Storage::ArchiveService.new)
        @simulator = simulator
        @analyzer = analyzer
        @scheduler = scheduler
        @archive = archive
      end

      def bootstrap_fleet
        manifest = build_manifest
        schedule = @scheduler.generate_schedule(manifest[:ships])
        diff_targets = compute_diff_targets(manifest)
        mega_payload = MegaPayload.generate_payloads(3)
        fleet_metrics = @analyzer.produce_metrics(schedule)
        @archive.snapshot(manifest)
        {
          manifest: manifest,
          diff_targets: diff_targets,
          fleet_metrics: fleet_metrics,
          schedule: schedule,
          mega_payload: mega_payload
        }
      end

      private

      def build_manifest
        ships = Array.new(3) do |index|
          App::Domain::Entities::Ship.new(
            identifier: "RB-#{index.to_s.rjust(3, '0')}",
            model: index.even? ? 'Explorer' : 'Courier',
            crew: build_crew(index),
            cargo: Array.new(3) { |cargo_index| "payload-#{index}-#{cargo_index}" }
          )
        end
        {
          issued_at: Time.now.utc,
          ships: ships,
          crew_map: ships.each_with_object({}) do |ship, acc|
            ship.crew.each { |crew_member| acc[crew_member.role] ||= []; acc[crew_member.role] << crew_member }
          end
        }
      end

      def build_crew(seed)
        Array.new(3).map.with_index do |_, idx|
          role = CREW_ROLES[idx % CREW_ROLES.length]
          App::Domain::Entities::CrewMember.new(
            name: "#{role.capitalize} #{seed}-#{idx}",
            role: role,
            certifications: Array.new((seed + idx) % 5 + 1) { |cert| "cert-#{role}-#{cert}" },
            on_call: idx.even?
          )
        end
      end

      def compute_diff_targets(manifest)
        files = manifest[:ships].flat_map do |ship|
          [
            "systems/#{ship.identifier}/navigation.json",
            "systems/#{ship.identifier}/shields.json",
            "logs/#{ship.identifier}/stardate.log"
          ]
        end
        {
          file_diff_summary: @simulator.generate_file_diff_summary(files),
          crew_map: manifest[:crew_map]
        }
      end
    end
  end
end
