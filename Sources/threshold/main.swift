import Foundation
import ThresholdCore

let thresholdVersion = "1.2.0"

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: threshold daemon | check | version\n".utf8))
    exit(64)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let command = arguments.first else { usage() }

switch command {
case "daemon":
    exit(Lifecycle(platform: SystemPlatform()).run())

case "check":
    let platform = SystemPlatform()
    let (json, code) = CheckReport.make(source: platform.configSource(), state: platform.stateStore.load(),
                                        versions: platform.versions, packages: platform.packages)
    do {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        FileHandle.standardError.write(Data("could not encode check output: \(error)\n".utf8))
        exit(1)
    }
    exit(code)

case "version":
    print(thresholdVersion)

default:
    usage()
}
