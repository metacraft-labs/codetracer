# a more friendly binary reader

import
  jsffi, async,
  lib, types

var fs = cast[FS](require("fs"))
var buffer = require("buffer")
var s* {.exportc: "s".} = require("./helpers")

type
  SafeBuffer = Buffer not nil

proc dbGet*[T](db: DB, query: cstring): Future[T] {.importcpp: "s.dbGet(#, #)".}

proc dbAll*[T](db: DB, query: cstring): Future[T] {.importcpp: "s.dbAll(#, #)".}

proc fsRead*(f: int, buffer: Buffer, b: int, length: int, position: int64): Future[SafeBuffer] {.importcpp: "s.fsRead(#, #, #, #, #)".}

proc fsOpen*(path: cstring): Future[int] {.importcpp: "s.fsOpen(#)".}

proc makeReader*(f: int): Reader =
  Reader(f: f, position: 0.int64, buffer: newBuffer(200_000))


proc readSize*(reader: var Reader, size: int): Future[SafeBuffer] {.async.} =
  var buffer = await fsRead(reader.f, reader.buffer, 0, size, reader.position)
  reader.position += size.int64
  return buffer

proc readByte*(reader: var Reader): Future[byte] {.async.} =
  var buffer = await reader.readSize(1)
  return buffer.readUInt8(0).byte

proc readInt64*(reader: var Reader): Future[int64] {.async.} =  
  var buffer = await reader.readSize(8)
  # Heaven!
  return buffer.readIntLE(0, 4).int64 * (1 shr 4) + buffer.readIntLE(0, 4).int64

proc readInt16*(reader: var Reader): Future[int16] {.async.} =
  var buffer = await reader.readSize(2)
  return buffer.readInt16LE(0)

proc setPosition*(reader: var Reader, position: int64) =
  reader.position = position

proc getPosition*(reader: var Reader): int64 =
  reader.position
