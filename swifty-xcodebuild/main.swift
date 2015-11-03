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
        
        var jsonArray = [JSON]()
        
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
                            let outputRecord = processClangCommand(clangCommandLine, directory: directory)
                            jsonArray.append(outputRecord)
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
        
        // Write to output file
        let json = JSON(jsonArray).rawString()!.replace("\\/", "/")
        try! Path(outputFile).write(json)
        print("Wrote output file successfully")
    }
    
}


let swifty = SwiftyXcodebuild()
//let directory = swifty.clangQuote("/Users/lqi/Projects/LQRDG/oclint-sample-projects/SVProject/Pods")
//let json: JSON = ["directory": "http://test.com/other"]
//let string = NSString(data: try! json.rawData(), encoding: NSUTF8StringEncoding)
//print(string)
//print(json.rawString()!.replace("\\/", "/"))
let inputFile = "/Users/dbeard/xcodebuild.log"
let outputFile = "/Users/dbeard/compile_commands.json"
swifty.convert(inputFile, outputFile: outputFile)

//When operating in POSIX mode, shlex will try to obey to the following parsing rules.
//
//Quotes are stripped out, and do not separate words ("Do"Not"Separate" is parsed as the single word DoNotSeparate);
//Non-quoted escape characters (e.g. '\') preserve the literal value of the next character that follows;
//Enclosing characters in quotes which are not part of escapedquotes (e.g. "'") preserve the literal value of all characters within the quotes;
//Enclosing characters in quotes which are part of escapedquotes (e.g. '"') preserves the literal value of all characters within the quotes, with the exception of the characters mentioned in escape. The escape characters retain its special meaning only when followed by the quote in use, or the escape character itself. Otherwise the escape character will be considered a normal character.
//EOF is signaled with a None value;
//Quoted empty strings ('') are allowed;


