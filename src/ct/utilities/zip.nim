import streams, std/[ sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]

import zip/zipfiles
import zip/gzipfiles
import streams

proc zipFolder*(folderPath: string) =

proc unzipIntoFolder(zipfile, targetPath: string) =
    
    
#var z: ZipArchive
#discard z.open("/codetracer/src/ct/online_sharing/result.zip", fmWrite)
#var r: seq[Stream] = @[]
#for file in walkDirRec("/codetracer/src/ct/online_sharing/tozip"):
  
#  let relPath = file.relativePath("/codetracer/src/ct/online_sharing/tozip")
#  echo relPath

#  let fileStream = newFileStream(file, fmRead)
#  r.add(fileStream)
#  z.addFile(relPath, fileStream)

#echo 13
#z.close()
#for r1 in r:
#  r1.close()
#sleep (100000)
