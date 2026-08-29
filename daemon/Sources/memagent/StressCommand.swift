import Foundation

/// Debug helper: allocate and touch real pages so growth detection and
/// prediction can be exercised without sudo or memory_pressure(1).
enum StressCommand {
    static func run(mb: Int, ratePerSec: Int, holdSeconds: Int) {
        let chunkMB = 64
        var chunks: [UnsafeMutableRawPointer] = []
        var allocated = 0
        let sleepPerChunk = Double(chunkMB) / Double(max(1, ratePerSec))

        print("stress: allocating \(mb) MB at ~\(ratePerSec) MB/s (pid \(getpid()))")
        while allocated < mb {
            let size = min(chunkMB, mb - allocated) * 1_048_576
            guard let ptr = malloc(size) else {
                print("stress: malloc failed at \(allocated) MB")
                break
            }
            memset(ptr, 0xAB, size)  // touch every page so it counts as footprint
            chunks.append(ptr)
            allocated += chunkMB
            if allocated % 512 == 0 || allocated >= mb {
                print("stress: \(min(allocated, mb)) / \(mb) MB")
            }
            Thread.sleep(forTimeInterval: sleepPerChunk)
        }
        print("stress: holding for \(holdSeconds)s — watch `memagent predict` / anomalies")
        Thread.sleep(forTimeInterval: Double(holdSeconds))
        for ptr in chunks { free(ptr) }
        print("stress: released")
    }
}
