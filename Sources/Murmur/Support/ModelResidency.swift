import Darwin
import Foundation
import Observation

/// Keeps the speech and cleanup models in memory only while they're being used.
///
/// Bark and S1-mini together hold about 600 MB (S1-mini's weights on the GPU, Bark on the
/// Neural Engine). Nothing loads at launch; a press wakes the models it needs, in parallel
/// with recording, and after `Settings.idleUnload` without a dictation both are released.
/// Reloading from disk costs about half a second for Bark and a couple of seconds for
/// S1-mini, overlapping with the speech that triggered it.
@MainActor
@Observable
final class ModelResidency {
    static let shared = ModelResidency()

    /// True while a hold is recording or finishing; set by the controller.
    var isBusy: () -> Bool = { false }

    private var timer: Task<Void, Never>?

    private init() {}

    /// At a press: cancel any pending release and start loading what this hold needs.
    func wake(engine: SpeechEngineChoice, cleanup: CleanupEngine?) {
        timer?.cancel()
        timer = nil
        StreamingModelPreparation.shared.wake(engine)
        if cleanup == .s1Mini { S1MiniPreparation.shared.wake() }
    }

    /// A model finished loading, or a hold finished: start the idle countdown.
    func loaded() { scheduleRelease() }
    func idle() { scheduleRelease() }

    /// Restarts the countdown, e.g. after the setting changes.
    func scheduleRelease() {
        timer?.cancel()
        guard let delay = Settings.shared.idleUnload.delay else {
            timer = nil
            return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if self.isBusy() {
                return    // the hold's end calls idle() again
            }
            await self.releaseAll()
        }
    }

    func releaseAll() async {
        let before = Self.footprintMB()
        await StreamingModelPreparation.shared.release()
        await S1MiniPreparation.shared.release()
        // The models' CPU-side buffers are freed shortly after (FluidAudio clears its
        // buffer cache on a detached task), but the allocator keeps the pages for reuse and
        // the footprint doesn't fall. Give the frees a moment, then hand pages back.
        try? await Task.sleep(for: .seconds(2))
        let returned = malloc_zone_pressure_relief(nil, 0)
        Log.app.info("idle: allocator returned \(returned / 1_048_576) MB")
        Log.app.info(
            "idle: models released, footprint \(before, format: .fixed(precision: 0)) MB → \(Self.footprintMB(), format: .fixed(precision: 0)) MB"
        )
    }

    /// This process's physical footprint, the number Activity Monitor shows as Memory.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
