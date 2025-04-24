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
      
      remaining_shield > 0
    end
  
    def calculate_damage(initial_shield, remaining_shield, mass)
      shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield)

      damage = mass * (100 - shield_pct)
    end
  
    def calculate_shield_regeneration(initial_shield, remaining_shield, shield_regen_percentage)
      regen = (initial_shield * shield_regen_percentage) / 100
    end
  
    def calculate_remaining_shield_pct(initial_shield, remaining_shield)
      (remaining_shield * 100) / initial_shield
    end
  
    def status_report(iteration, initial_shield, remaining_shield, damage, regenerated_shield)
      puts "----- iteration #{iteration} -----"
      puts "Damage: #{damage}"
      puts "Regenerated #{regenerated_shield} energy"
      remaining_shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield)
      puts "Shield status #{remaining_shield_pct}% #{remaining_shield}"
    end
  end