module Shield
    module_function

    def iterate_asteroids(initial_shield, shield_regen_percentage, masses)
      remaining_shield = initial_shield
      iteration = 0

      while iteration < masses.length
        mass = masses[iteration]
        damage = calculate_damage(initial_shield, remaining_shield, mass)
        remaining_shield -= damage

        regeneration = 0
        if remaining_shield > 0
          regeneration = calculate_shield_regeneration(initial_shield, remaining_shield, shield_regen_percentage)
          remaining_shield += regeneration
        end

        status_report(iteration, initial_shield, remaining_shield, damage, regeneration)
        iteration += 1
      end

      # Must have at least 1 unit of shield to survive
      remaining_shield > 0
    end

    def calculate_damage(initial_shield, remaining_shield, mass)
      shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield)
      damage = if shield_pct == 100
                 mass
               else
                 mass * (100 - shield_pct)
               end
      [damage, remaining_shield].min
    end

    def calculate_shield_regeneration(initial_shield, remaining_shield, shield_regen_percentage)
      regen = (initial_shield * shield_regen_percentage / 100.0).floor
      [(initial_shield - remaining_shield), regen].min
    end

    def calculate_remaining_shield_pct(initial_shield, remaining_shield)
      ((remaining_shield * 100) / initial_shield).floor
    end

    def status_report(iteration, initial_shield, remaining_shield, damage, regenerated_shield)
      puts "----- Iteration #{iteration + 1} -----"
      puts "Damage: #{damage}"
      puts "Regenerated #{regenerated_shield} energy"
      shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield)
      puts "Shield status: #{shield_pct}% (#{remaining_shield} units)"
    end
  end
