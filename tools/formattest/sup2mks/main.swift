import Foundation
// CI: runs the app's own PGSContainer on the subtitle Jellyfin served.
let args = CommandLine.arguments
guard args.count == 3, let sup = FileManager.default.contents(atPath: args[1]),
      let mks = PGSContainer.matroska(fromSUP: sup) else { print("sup2mks: conversion failed"); exit(1) }
FileManager.default.createFile(atPath: args[2], contents: mks)
print("sup2mks: \(sup.count) bytes of PGS -> \(mks.count) bytes of Matroska")
