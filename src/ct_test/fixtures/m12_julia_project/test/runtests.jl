using Test

add(a, b) = a + b

@testset "calculator" begin
    @test add(2, 3) == 5
end

println("julia fixture passed")
