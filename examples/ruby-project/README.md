# ruby

this is a simple interpreter written in ruby

it can execute ast defined as a ruby object:

```ruby
run(n(:module, [n(:binary_add, [n(:int, [0]), n(:int, [7])])]))
# rint(7)
```

it is a simple project useful to research ruby support for codetracer 
and inferring types

it's also defined for python and c++

