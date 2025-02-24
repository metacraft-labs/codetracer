## codetracer `<path>`
  e.g. for `ls`
  if trace is nil =>
    
    default build/(eventually auto-detected cfg/makefile etc) => record `<defaultpath>` => record ls.nim
    
    otherwise =>
    
      editing a path, record it => record `<currentpath>` => record ls.nim 
    
      not editing => error "cant build, please update config, or edit a file"

    eventually: change with a menu/dialog
  