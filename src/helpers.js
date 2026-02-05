"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.fs = void 0;
exports.dbGet = dbGet;
exports.dbAll = dbAll;
exports.fsRead = fsRead;
exports.fsOpen = fsOpen;
exports.fsReadFile = fsReadFile;
exports.fsWriteFile = fsWriteFile;
exports.fsReadFileWithErr = fsReadFileWithErr;
exports.fsWriteFileWithErr = fsWriteFileWithErr;
exports.fsReaddir = fsReaddir;
exports.fsCopyFileWithErr = fsCopyFileWithErr;
exports.fsMkdirWithErr = fsMkdirWithErr;
exports.fsUnlinkWithErr = fsUnlinkWithErr;
exports.childProcessExec = childProcessExec;
exports.wait = wait;
// based on https://nodejs.org/api/fs.html#fspromisescopyfilesrc-dest-mode
// should we directly use node:fs/promises? async versions?
var fs = require("fs");
exports.fs = fs;
var child_process = require("child_process");
process.on('unhandledRejection', r => console.log(r)); // why is this not the fucking default, Node?
async function dbGet(db, query) {
    var promise = new Promise(resolve => {
        db.get(query, function (err, res) {
            resolve(res);
        });
    });
    return promise;
}
async function dbAll(db, query) {
    var promise = new Promise(resolve => {
        db.all(query, function (err, res) {
            resolve(res);
        });
    });
    return promise;
}
async function fsRead(fd, buffer, b, length, position) {
    var promise = new Promise(resolve => {
        fs.read(fd, buffer, b, length, position, (err, bytesRead, newBuffer) => {
            // console.log("fsRead", length, position, bytesRead, buffer)
            resolve(buffer);
        });
    });
    return promise;
}
async function fsOpen(path) {
    var promise = new Promise(resolve => {
        fs.open(path, 'r', (err, f) => {
            if (err) {
                console.log(err);
            }
            resolve(f);
        });
    });
    return promise;
}
async function fsReadFile(path) {
    var promise = new Promise(resolve => {
        fs.readFile(path, 'utf8', (err, f) => {
            if (err) {
                console.log(err);
            }
            resolve(f);
        });
    });
    return promise;
}
async function fsWriteFile(path, s) {
    var promise = new Promise(resolve => {
        fs.writeFile(path, s, (err) => {
            if (err) {
                console.log(err);
            }
            resolve();
        });
    });
    return promise;
}
async function fsReadFileWithErr(path) {
    var promise = new Promise(resolve => {
        fs.readFile(path, 'utf8', (err, f) => {
            //console.log(f, err)
            resolve({ Field0: f, Field1: err });
        });
    });
    return promise;
}
async function fsWriteFileWithErr(path, s) {
    var promise = new Promise(resolve => {
        fs.writeFile(path, s, resolve);
    });
    return promise;
}
async function fsReaddir(path, options) {
    var promise = new Promise(resolve => {
        fs.readdir(path, options, (err, files) => {
            resolve(files);
        });
    });
    return promise;
}
async function fsCopyFileWithErr(src, dest) {
    var promise = new Promise(resolve => {
        fs.copyFile(src, dest, (err) => {
            // if (err) {
            //     console.log(err)
            // }
            resolve(err);
        });
    });
    return promise;
}
async function fsMkdirWithErr(directory, options) {
    var promise = new Promise(resolve => {
        fs.mkdir(directory, options, (err) => {
            // if (err) {
            //     console.log(err);
            // }
            resolve(err);
        });
    });
    return promise;
}
async function fsUnlinkWithErr(path) {
    var promise = new Promise(resolve => {
        fs.unlink(path, (err) => {
            resolve(err);
        });
    });
    return promise;
}
async function childProcessExec(cmd, options = {}) {
    var promise = new Promise(resolve => {
        options.maxBuffer = 5000000;
        // console.log('index: running child process: (helpers.ts):', cmd, options)
        try {
            child_process.exec(cmd, options, (err, stdout, stderr) => {
                resolve({ Field0: stdout, Field1: stderr, Field2: err });
            });
        }
        catch (_a) {
            resolve({ Field0: '', Field1: '', Field2: 'error' });
        }
    });
    return promise;
}
async function wait(ms) {
    var promise = new Promise(resolve => {
        setTimeout(() => resolve(ms), ms);
    });
    return promise;
}
var path = require('path');
