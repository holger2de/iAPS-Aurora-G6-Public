import Foundation

func saveDebugDataToTempFile(description: String, fileName: String, data: Data) {
    #if DEBUG
        do {
            let documentsDirectory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            let debugDirectory = documentsDirectory
                .appendingPathComponent("ai-debug", isDirectory: true)

            try FileManager.default.createDirectory(
                at: debugDirectory,
                withIntermediateDirectories: true
            )

            let debugFile = debugDirectory.appendingPathComponent(fileName)
            try data.write(to: debugFile, options: .atomic)

            print("💾 DEBUG: \(description) saved to: \(debugFile.path)")
        } catch {
            print("💾 DEBUG: \(description) failed to save: \(error)")
        }
    #endif
}
