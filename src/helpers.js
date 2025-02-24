"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
    return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.wait = exports.fs = exports.childProcessExec = exports.fsMkdirWithErr = exports.fsCopyFileWithErr = exports.fsReaddir = exports.fsWriteFileWithErr = exports.fsReadFileWithErr = exports.fsWriteFile = exports.fsReadFile = exports.fsOpen = exports.fsRead = exports.dbAll = exports.dbGet = void 0;
// based on https://nodejs.org/api/fs.html#fspromisescopyfilesrc-dest-mode
// should we directly use node:fs/promises? async versions?
var fs = require("fs");
exports.fs = fs;
var child_process = require("child_process");
process.on('unhandledRejection', function (r) { return console.log(r); }); // why is this not the fucking default, Node?
function dbGet(db, query) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                db.get(query, function (err, res) {
                    resolve(res);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.dbGet = dbGet;
function dbAll(db, query) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                db.all(query, function (err, res) {
                    resolve(res);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.dbAll = dbAll;
function fsRead(fd, buffer, b, length, position) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.read(fd, buffer, b, length, position, function (err, bytesRead, newBuffer) {
                    // console.log("fsRead", length, position, bytesRead, buffer)
                    resolve(buffer);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsRead = fsRead;
function fsOpen(path) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.open(path, 'r', function (err, f) {
                    if (err) {
                        console.log(err);
                    }
                    resolve(f);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsOpen = fsOpen;
function fsReadFile(path) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.readFile(path, 'utf8', function (err, f) {
                    if (err) {
                        console.log(err);
                    }
                    resolve(f);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsReadFile = fsReadFile;
function fsWriteFile(path, s) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.writeFile(path, s, function (err) {
                    if (err) {
                        console.log(err);
                    }
                    resolve();
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsWriteFile = fsWriteFile;
function fsReadFileWithErr(path) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.readFile(path, 'utf8', function (err, f) {
                    //console.log(f, err)
                    resolve({ Field0: f, Field1: err });
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsReadFileWithErr = fsReadFileWithErr;
function fsWriteFileWithErr(path, s) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.writeFile(path, s, resolve);
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsWriteFileWithErr = fsWriteFileWithErr;
function fsReaddir(path, options) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.readdir(path, options, function (err, files) {
                    resolve(files);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsReaddir = fsReaddir;
function fsCopyFileWithErr(src, dest) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.copyFile(src, dest, function (err) {
                    // if (err) {
                    //     console.log(err)
                    // }
                    resolve(err);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsCopyFileWithErr = fsCopyFileWithErr;
function fsMkdirWithErr(directory, options) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                fs.mkdir(directory, options, function (err) {
                    // if (err) {
                    //     console.log(err);
                    // }
                    resolve(err);
                });
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.fsMkdirWithErr = fsMkdirWithErr;
function childProcessExec(cmd_1) {
    return __awaiter(this, arguments, void 0, function (cmd, options) {
        var promise;
        if (options === void 0) { options = {}; }
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                options.maxBuffer = 5000000;
                // console.log('index: running child process: (helpers.ts):', cmd, options)
                try {
                    child_process.exec(cmd, options, function (err, stdout, stderr) {
                        resolve({ Field0: stdout, Field1: stderr, Field2: err });
                    });
                }
                catch (_a) {
                    resolve({ Field0: '', Field1: '', Field2: 'error' });
                }
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.childProcessExec = childProcessExec;
function wait(ms) {
    return __awaiter(this, void 0, void 0, function () {
        var promise;
        return __generator(this, function (_a) {
            promise = new Promise(function (resolve) {
                setTimeout(function () { return resolve(ms); }, ms);
            });
            return [2 /*return*/, promise];
        });
    });
}
exports.wait = wait;
var path = require('path');
