
```bash
projects clone curl # 
  # clones with git into `projects/curl` from the address we have, if not already there
  # the address might not be upstream, if we have a branch or want a certain commit
projects build # 
  # builds the project where we are , based on the name of the folder(maybe the projects path as well)
  # if not in codetracer shell, probably runs projects build_in_shell in codetracer shell
  # otherwise directly runs projects build_in_shell
  # which is an internal command
projects setup curl [--build / --no-build] # 
  # clones a project if needed, if no specific build flag passes
  # asks if we want to build 
  # otherwise builds if `--build` passed and doesn't build if
  # `--no-build` passed
  # and runs `codetracer shell` leaving the user inside with 
  # some examples printed 
```

```bash
$ projects setup curl 
> * cloning curl into projects/curl
> * moving there
> do you want to build it? Y/n ?
Y
> answered Y: building
> * starting codetracer shell
> * building curl: running commands
> ..
> * build finished: built bin/curl with codetracer build info
> 
> now you can work with the project:
> example run commands:
> `bin/curl` # just running curl
> `bin/curl -L -X GET https://bible.com` # downloading a page, following redirects
```
