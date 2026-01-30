def fibonacci(n)
    if n > 1
        fibonacci(n - 1) + fibonacci(n - 2)
    else
        1
    end
end

fibonacci(10)
