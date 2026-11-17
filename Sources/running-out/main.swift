import Foundation
import RunningOutCore

FileHandle.standardError.write(Data("usage: running-out <index|stats|watch> [options]\n".utf8))
exit(2)
