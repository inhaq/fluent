import os

/// Lightweight `os_signpost` instrumentation for the dictation pipeline.
///
/// Until now the only timing data was scattered `os_log` timestamps, which
/// makes "is it fast?" a matter of reading logs and doing mental subtraction.
/// These signposts emit a single Instruments-visible interval per dictation
/// plus discrete events for each milestone in the hot path:
///
///   shortcut trigger -> recorder ready -> stop -> audio finalized
///     -> transcript received -> paste
///
/// Open Instruments with the "os_signpost" / "Points of Interest" instrument
/// (subsystem `com.inhaq.fluent`) to see the end-to-end latency and the
/// gaps between stages, rather than inferring them from log lines.
enum PipelineSignpost {
    /// Category `PointsOfInterest` makes the intervals/events land on the
    /// dedicated Points of Interest track in Instruments.
    static let signposter = OSSignposter(
        subsystem: "com.inhaq.fluent",
        category: "PointsOfInterest"
    )

    /// Stable interval name so begin/end pair up in Instruments.
    static let dictationInterval: StaticString = "Dictation"
}
