swifty-xcodebuild
=================

- Swift re-write of oclint-xcodebuild focusing on performance
- swifty-xcodebuild takes the output of an xcodebuild command and translates compiler commands into a JSON Compilation Database (compile_commands.json) format.

## Usage 

- Capture output of xcodebuild

    `xcodebuild <options> | tee xcodebuild.log`
    
- Run swifty-xcodebuild

    `./swifty-xcodebuild xcodebuild.log compile_commands.json`
