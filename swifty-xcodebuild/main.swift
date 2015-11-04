//
//  main.swift
//  swifty-xcodebuild
//
//  Created by Daniel Beard on 10/30/15.
//  Copyright © 2015 DanielBeard. All rights reserved.
//

// Playground - noun: a place where people can play

import Foundation
import CoreLocation

extension String {
    func replace(input: String, _ substitute: String) -> String {
        return self.stringByReplacingOccurrencesOfString(input, withString: substitute)
    }
    
    func strip() -> String {
        return self.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet())
    }
    
    func split(separator: String) -> [String] {
        return self.componentsSeparatedByString(separator)
    }
    
    func match(regex: String) -> Bool {
        if let _ = self.rangeOfString(regex, options: .RegularExpressionSearch) {
            return true
        }
        return false
    }
}

final class OutputStreamer {
    
    private let outputStreamer: NSOutputStream
    
    init(outputFile: String) {
        outputStreamer = NSOutputStream(toFileAtPath: outputFile, append: true)!
        outputStreamer.open()
    }
    
    func write(string: String) {
        let data: NSData = string.dataUsingEncoding(NSUTF8StringEncoding)!
        outputStreamer.write(UnsafePointer<UInt8>(data.bytes), maxLength: data.length)
    }
    
    func close() {
        outputStreamer.close()
    }
}


final class SwiftyXcodebuild {
    
    //MARK: Constants
    let kDefaultInputFile = "xcodebuild.log"
    let kJSONCompilationDB = "compile_commands.json"
    let kSupportedCompilers = [
        "clang",
        "clang\\+\\+",
        "llvm-cpp-4.2",
        "llvm-g\\+\\+",
        "llvm-g\\+\\+-4.2",
        "llvm-gcc",
        "llvm-gcc-4.2",
        "arm-apple-darwin10-llvm-g\\+\\+-4.2",
        "arm-apple-darwin10-llvm-gcc-4.2",
        "i686-apple-darwin10-llvm-g\\+\\+-4.2",
        "i686-apple-darwin10-llvm-gcc-4.2",
        "gcc",
        "g\\+\\+",
        "c\\+\\+",
        "cc"
    ]
    let kEscapedSpace = "🌎"
    
    //MARK: Regex's
    let findUnsafeRegex = "[ \"\\\\]"
    let findQuotingRegex = "[\'\"\\\\]"
    
    //MARK: Properties
    var pchDictionary = [String: String]()
    let fileManager = NSFileManager.defaultManager()
    
    func clangQuote(input: String) -> String {
        guard input.characters.count > 0 else {
            return "\"\""
        }
        if input.match(findUnsafeRegex) {
            return "\"" + input.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        } else {
            return input
        }
    }
    
    func tokenizeCommand(input: String) -> [String] {
        if input.match(findQuotingRegex) {
            //TODO: This is a really dumb, should fix, might also have to handle other cases like single quote and double quote.
            // Escaped space = 🌎
            let escapedInput = input.replace("\\ ", kEscapedSpace)
            let output = escapedInput.split(" ")
            var result = [String]()
            for string in output {
                if string.characters.count > 0 {
                    result.append(string.replace(kEscapedSpace, " ").strip())
                }
            }
            return result
        } else {
            return input.strip().split(" ").map { $0.strip() }
        }
    }
    
    func registerSourceForPTHFile(clangCommand: String, directory: String) {
        let tokens = tokenizeCommand(clangCommand)
        var srcFile = ""
        var pthFile = ""
        for (index, token) in tokens.enumerate() {
            if token == "-c" && index + 1 < tokens.count {
                srcFile = tokens[index+1]
            } else if token == "-o" && index + 1 < tokens.count {
                let file = tokens[index+1]
                if file.hasSuffix(".pch.pth") || file.hasSuffix(".pch.pch") || file.hasSuffix(".h.pch") {
                    pthFile = file
                }
            }
        }
        if srcFile.characters.count > 0 && pthFile.characters.count > 0 {
            pchDictionary[pthFile] = srcFile
        }
    }
    
    func sourceFileForPTHFile(pthFile: String) -> String? {
        if let srcFile = pchDictionary[pthFile + ".pth"] {
            return srcFile
        }
        return pchDictionary[pthFile + ".pch"]
    }
    
    func readDirectory(line: String) -> String {
        let tokens = tokenizeCommand(line)
        if tokens.count >= 2 && tokens[0] == "cd" {
            return tokens[1]
        }
        return ""
    }
    
    func processClangCommand(clangCommand: String, directory: String) -> JSON {
        let tokens = tokenizeCommand(clangCommand)
        var command = [String]()
        var sourceFile = ""
        
        var tokenGenerator = tokens.generate()
        repeat {
            guard let token = tokenGenerator.next() else { break }
            if token == "-include" {
                guard let includeFile = tokenGenerator.next() else { break }
                var resultIncludeFile = ""
                if fileManager.fileExistsAtPath(includeFile) {
                    resultIncludeFile = clangQuote(includeFile)
                } else {
                    if let srcFile = sourceFileForPTHFile(includeFile) {
                        resultIncludeFile = clangQuote(srcFile)
                    } else {
                        print("Can not find original pch source file for \(includeFile)")
                        exit(3)
                    }
                }
                command.append(token)
                command.append(resultIncludeFile)
            } else if token == "-c" {
                guard let srcFile = tokenGenerator.next() else { break }
                sourceFile = srcFile
                command.append(token)
                command.append(clangQuote(srcFile))
            } else {
                command.append(clangQuote(token))
            }
        } while true
       
        let json: JSON = ["directory": directory, "file": Path(sourceFile).normalize().asString(), "command": command.joinWithSeparator(" ")]
        return json
    }
    
    func convert(inputFile: String, outputFile: String) {
        
        let compileCRegex = "CompileC"
        let processPCHRegex = "ProcessPCH"
        let supportedCompilersString = kSupportedCompilers.joinWithSeparator("|")
        let clangCommandRegex = "(\(supportedCompilersString)) .* -c .* -o "
        var isFirstCommand = true
        
        let outputPath = Path(outputFile)
        let outputStreamer = OutputStreamer(outputFile: outputFile)
        outputStreamer.write("[")
        
        // Open input file for reading
        if let lines = StreamReader(path: inputFile) {
            defer { lines.close() }
            
            loop: repeat {
                guard let logLine = lines.nextLine() else { break }
                
                // CompileC
                if logLine.match(compileCRegex) {
                    guard let directoryLine = lines.nextLine() else { break loop }
                    let directory = readDirectory(directoryLine)
                    
                    // Loop through clang commands
                    repeat {
                        guard let clangCommandLine = lines.nextLine() else { break loop }
                        if clangCommandLine.match(clangCommandRegex) {
                            autoreleasepool {
                                if !isFirstCommand { outputStreamer.write(",\n") }
                                let clangOutput = processClangCommand(clangCommandLine, directory: directory)
                                let jsonString = "\(clangOutput.rawString()!.replace("\\/", "/"))\n"
                                outputStreamer.write(jsonString)
                                isFirstCommand = false
                            }
                        } else {
                            continue
                        }
                        break
                    } while true
                    continue
                }
                
                // ProcessPCH
                if logLine.match(processPCHRegex) {
                    guard let directoryLine = lines.nextLine() else { break loop }
                    let directory = readDirectory(directoryLine)
                    
                    // Loop through clang commands
                    repeat {
                        guard let clangCommandLine = lines.nextLine() else { break loop }
                        if clangCommandLine.match(clangCommandRegex) {
                            registerSourceForPTHFile(clangCommandLine, directory: directory)
                        } else {
                            continue
                        }
                        break
                    } while true
                    continue
                }
            } while true
        }
        outputStreamer.write("]")
        outputStreamer.close()

        print("Wrote output file successfully")
    }
    
}

autoreleasepool {
    
    // Check input arguments
    let args = Process.arguments
    if args.count != 3 {
        print("Usage swifty-xcodebuild [input-file] [output-file]")
        exit(2)
    }
    
    let swifty = SwiftyXcodebuild()
    let inputFile = args[1]
    let outputFile = args[2]
    
    // Remove output file if it already exists
    let outputPath = Path(outputFile)
    if outputPath.exists {
        do {
            try outputPath.delete()
        } catch {
            print("File already exists at output path, but could not be removed.")
            exit(2)
        }
    }
    
    // Check that input file exists
    let inputPath = Path(inputFile)
    if !inputPath.exists {
        print("Input file does not exist!")
        exit(3)
    }
    
    swifty.convert(inputFile, outputFile: outputFile)
}
