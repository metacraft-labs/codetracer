// based on https://nodejs.org/api/fs.html#fspromisescopyfilesrc-dest-mode
// should we directly use node:fs/promises? async versions?
var fs = require("fs")
var child_process = require("child_process")

process.on('unhandledRejection', r => console.log(r)); // why is this not the fucking default, Node?

async function dbGet(db: any, query: string): Promise<any> {
    var promise = new Promise(resolve => {
        db.get(query, function(err, res) {
            resolve(res)
        })
    })
    return promise
}

async function dbAll(db: any, query: string): Promise<any> {
    var promise = new Promise(resolve => {
        db.all(query, function(err, res) {
            resolve(res)
        })
    })
    return promise
}

async function fsRead(fd: number, buffer: any, b: number, length: number, position: number): Promise<any> {
    var promise = new Promise(resolve => {
        fs.read(fd, buffer, b, length, position, (err, bytesRead, newBuffer) => {
            // console.log("fsRead", length, position, bytesRead, buffer)
            resolve(buffer)
        })
    })
    return promise
}

async function fsOpen(path: string): Promise<number> {
    var promise = new Promise<number>(resolve => {
        fs.open(path, 'r', (err: any, f: number) => {
            if (err) {
                console.log(err)
            }
            resolve(f)
        })
    })
    return promise
}

async function fsReadFile(path: string): Promise<string> {
	var promise = new Promise<string>(resolve => {
        fs.readFile(path, 'utf8', (err: any, f: string) => {
            if (err) {
                console.log(err)
            }
            resolve(f)
        })
    })
    return promise
}

async function fsWriteFile(path: string, s: string): Promise<void> {
    var promise = new Promise<void>(resolve => {
        fs.writeFile(path, s, (err: any) => {
            if (err) {
                console.log(err)
            }
            resolve()
        })
    })
    return promise
}

async function fsReadFileWithErr(path: string): Promise<{Field0: string, Field1: any}> {
    var promise = new Promise<{Field0: string, Field1: any}>(resolve => {
        fs.readFile(path, 'utf8', (err: any, f: string) => {
            //console.log(f, err)
            resolve({Field0: f, Field1: err})
        })
    })
    return promise
}

async function fsWriteFileWithErr(path: string, s: string): Promise<any> {
    var promise = new Promise<any>(resolve => {
        fs.writeFile(path, s, resolve)
	})
	return promise
}

async function fsReaddir(path: string, options: any): Promise<string[]> {
	var promise = new Promise<string[]>(resolve => {
		fs.readdir(path, options, (err: any, files: string[]) => {
			resolve(files)
		})
	})
	return promise
}

async function fsCopyFileWithErr(src: string, dest: string): Promise<any> {
    var promise = new Promise<any>(resolve => {
        fs.copyFile(src, dest, (err: any) => {
            // if (err) {
            //     console.log(err)
            // }
            resolve(err)
        })
    })
    return promise
}

async function fsMkdirWithErr(directory: string, options: any): Promise<any> {
  var promise = new Promise<any>(resolve => {
    fs.mkdir(directory, options, (err: any) => {
        // if (err) {
        //     console.log(err);
        // }
        resolve(err)
    })
  })
  return promise
}

async function childProcessExec(cmd: string, options: any = {}): Promise<{Field0: string, Field1: string, Field2: any}> {
    var promise = new Promise<{Field0: string, Field1: string, Field2: any}>(resolve => {
        options.maxBuffer = 5_000_000;
        // console.log('index: running child process: (helpers.ts):', cmd, options)

        try {
            child_process.exec(cmd, options, (err: any, stdout: string, stderr: string) => {
                resolve({Field0: stdout, Field1: stderr, Field2: err})
            })
        } catch {
            resolve({Field0: '', Field1: '', Field2: 'error'})
        }
    })
    return promise
}

async function wait(ms: number): Promise<number> {
    var promise = new Promise<number>(resolve => {
        setTimeout(() => resolve(ms), ms)
    })
    return promise
}


var path = require('path')

export {dbGet, dbAll, fsRead, fsOpen, fsReadFile, fsWriteFile, fsReadFileWithErr, fsWriteFileWithErr, fsReaddir, fsCopyFileWithErr, fsMkdirWithErr, childProcessExec, fs, wait}
