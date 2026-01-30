

### Try to step/next several times using caption bar

* State panel: see values
* Preload info: by default in parallel
* Editor: based on monaco(javascript editor library used in visual studio code)

### Jump to output

* Now you should see a similar output in a new place in code

### Jump to calltrace

* Again: similar, you can try and jump around in several places in the output/calltrace

### Trace: right-click on a line number in the editor, e.g. 17

### Now enter an expression like `log p` and click `update traces`

* Scroll through the results and filter them

### Trace: now you can instead type `plot p` and `update traces`

* You should see a graph of the values of `p`

### Trace: now you can type `bar p` and `update traces`

* You should see a bar: we might add different visualisations
* Also, this text box should become expandable(TODO for me: alexander), maybe the button being elsewhere so it looks like a part of the source, but still different

### Preload: enter `alt+m`

* You should see the multiline mode of preload info

### Preload: enter `alt+i`

* You should see the inline mode: it seems that we have to shorten some of the values

### Preload: you can enter `alt+p` to get to the parallel view again

* We might have a button in top right of the editor that lets us switch

### Enter `alt+1`: low level view

* In Nim mode, you'll see the C code for your current path

### Enter `alt+2`: low level view 2

* In Nim mode, you'll see the assembly code of your current function

### You can go back with `alt+0`: normal view





### Yeah

## Upgrade

* Upgrade `nim` and `nimgraph`: `git pull` from upstream `devel` or a stable version, rebasing and squashing (I use `reset --soft HEAD~` several times for that) to collect most of our changes in single or two patches and push forward
* Upgrade Electron: change Electron in `package.json`, nvm use 12, `npm install`, `npm install node-abi`, `node_modules/bin/electron-rebuild`
