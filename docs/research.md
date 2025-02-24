

I spent some time with the Nim compiler today, as I want to improve the rr logic for bigger apps like it this week.

Various observations:

* I often want to trace just a certain period of the program, e.g. 
I know that it behaves ok in the first 90% of invocations, and it breaks just in a certain moment.
Here is probably where some kind of condition-based tracing/searching might help.
A progress bar on which you can jump to %-event of the program also seems like a possible solution, but it's more of a gimmick, and I am not totally sure how useful would it be in general
* Another thing that would be interesting is some kind of info on how hot some method/path is. That can give you another view into which are the important parts of the file (or dead code) but I think it's still soon for profiling features (talking about another view of the file, I also had some ideas how with dynamic call info, you can visualize/animate right of a method the methods it called and the args it passed them, but that's again more of a questionary? visualization experiment)
* Probably I can get the enum variants using the future nim syntax plugin, but no obvious way now
* Overall and most importantly, still some work on more robust handling of instances/variants to be able to use most Nim compiler values, still probably most of the complicated ones are broken , but shouldn't be too much fixing



While trying example simpler (not compilers) programs these days, I another possible operation. Following the construction of a value seems like something that could be an useful extension of the history search (and something I haven't seen before)

An example is:

```nim
proc x(z: string): G =
  var filename = z & ";"
  filename[2] = ' '
  var g = G(filename: filename)
  return g

proc a =
  var filename = "w"
  for w in 0..<4:
    echo x(filename & $w)
    filename = filename & $w
    echo x2(filename)
```

and that would be the result

```nim
							! filename: "z4;" =>
  var filename = z & ";"  	! z = "z4"
  proc x(z: string): G      ! z is arg coming from
  x(filename & $w)          ! filename = "z" w = 4
  var filename = "z"        ! filename = "z"
```

The point is that we follow not only to the allocation of a variable, but also detect how it's constructed and we also follow the history of those values recursively to get a full picture of how 
was our value constructed(because that might map to something a human would do manually).
I toyed with recognizing common patterns (e.g. arg passing), I admit analyzing this seem harder and 
full of edge cases, but a not-always-perfect version of it seems simple: not tough to recognize calls/variables on right of assignment or in a call and to re-apply recursively the same actions on them
As a whole that's a dubious and indefinite future idea of course, but I'll document here just in case.



