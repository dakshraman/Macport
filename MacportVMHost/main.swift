import Foundation
import MacportKit

// A file named `main.swift` is top-level code, which is why the entry point is a
// free call rather than `@main`. The host keeps its own run loop alive inside
// `run`, so this line returns only after a clean shutdown.
exit(await MacportVMHostMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
