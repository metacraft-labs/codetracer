
* Concurrent calltrace

Interface ideas:

Based on (especially the last one)  top/htop/ [tokio-console](https://github.com/tokio-rs/console) / https://perfetto.dev/ / [goroutine gdb](https://go.dev/doc/gdb)

How:
  Normal calltrace

  async/thread/goroutine:

    start():
      let node = await parse(code)
      let typed_node = await typecheck(node, env)
      let asm = await gen_asm(typed_node)
      await assemble(asm)
      await print("ready")

    start:
      parse(code) node:
        parse_section(code1)
        parse_section(code2)
      typecheck(node, env) typed_node
      gen_asm(typed_node) asm
      assemble(asm)
      print("ready")


    start():
      var node_futures = []
      for code in code_list:
        node_futures.push(go_without_wait parse(code))
      let nodes = await join(node_futures)

    start #0:
      .. other
      parse #2 %2 (code):
        parse_section(code1)
      parse #3 %3 (code):
        parse_section(code1)
      parse #4 %4 (code):
        parse_section(code1)
      parse #5 %2 (code) node:
        parse_section(code2)
      push_in_join #6  (node)
      parse #7 %3 (code) node:
        parse_section(code2)
      push_in_join #8 (node)
      parse #9 %4 (code) node:
        parse_section(code2)
      push_in_join #10 (node)

    start:
      % concurrent group
      parse #2,#5 %2 (code) node:
        #2                            #5
        parse_section(code1) ..->%3.. parse_section(code2)
      parse #3,#7 %3 (code) node:
        #3                            #7
        parse_section(code1) ..->%4.. parse_section(code2)
      parse #4,#9 %4 (code) node:
        #4                            #9
        parse_section(code1) ..->%2.. parse_section(code2)
      push_in_join #6 (node) <- %2
      push_in_join #8 (node) <- %3
      push_in_join #10 (node) <- %4
      % end concurrent group

    start:
      % concurrent group
      parse #2,#5 %2 (code) node:
        #2
        parse_section(code1)
        ..->%3..
        #5
        parse_section(code2)
      parse #3,#7 %3 (code) node:
        #3
        parse_section(code1)
        ..->%4..
        #7
        parse_section(code2)
      parse #4,#9 %4 (code) node:
        #4
        parse_section(code1)
        ..->%2..
        #9
        parse_section(code2)
      push_in_join #6 (node) <- %2
      push_in_join #8 (node) <- %3
      push_in_join #10 (node) <- %4
      % end concurrent group

    start:
      % concurrent group
      parse #2,#5 %2 (code) node:
        #2
        parse_section(code1)
          ..->%3..
            ..%4->..
              #5
              parse_section(code2)
                ..->%3
      parse #3,#7 %3 (code) node:
          #3
          parse_section(code1)
            ..->%4..
              ..%2->..
                #7
                parse_section(code2)
                  ..->%4
      parse #4,#9 %4 (code) node:
            #4
            parse_section(code1)
              ..->%2..
                ..%3->..
                  #9
                  parse_section(code2)
      push_in_join #6 (node) <- %2
      push_in_join #8 (node) <- %3
      push_in_join #10 (node) <- %4
      % end concurrent group



    start:
      % concurrent group
      parse #2,#5 %2 (code) node:
        #2
        ->parse_section %5(code1)
                                  ..->parse %3..
                                                                                      ..parse_section %5->..
                                                                                              #5
                                                                                              parse_section %8(code2)
                                                                                                              ..->%3
      parse #3,#7 %3 (code) node:
                                  #3
                                  ->parse_section %6(code1)
                                                            ..->parse %4..
                                                                                               ..
      parse #4,#9 %4 (code) node:
                                                            #4
                                                            ->parse_section %7(code1)
                                                                                      ..->parse_section %5..
                                                                                                 ..
      push_in_join #6 (node) <- %2
      push_in_join #8 (node) <- %3
      push_in_join #10 (node) <- %4
      % end concurrent group
