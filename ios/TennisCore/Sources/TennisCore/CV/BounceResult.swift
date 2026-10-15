import Foundation

public struct CVPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct CVVideoMetadata: Codable, Equatable, Sendable {
    public let durationMs: Int64
    public let width: Int
    public let height: Int
    public let fps: Double
    enum CodingKeys: String, CodingKey { case durationMs = "duration_ms", width, height, fps }
    public init(durationMs: Int64, width: Int, height: Int, fps: Double) { self.durationMs=durationMs; self.width=width; self.height=height; self.fps=fps }
}
public struct CVModelMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let runtime: String
    public let sha256: String?
    public init(name: String, version: String, runtime: String, sha256: String? = nil) { self.name=name; self.version=version; self.runtime=runtime; self.sha256=sha256 }
}
public struct CVBounceEvent: Codable, Equatable, Sendable {
    public let eventId: String
    public let eventType: String
    public let timestampMs: Int64
    public let imagePoint: CVPoint?
    public let courtPoint: CVPoint?
    public let zone: String?
    public let confidence: Double?
    public let reviewStatus: String
    enum CodingKeys: String, CodingKey { case eventId="event_id", eventType="event_type", timestampMs="timestamp_ms", imagePoint="image_point", courtPoint="court_point", zone, confidence, reviewStatus="review_status" }
    public init(eventId: String, eventType: String="bounce", timestampMs: Int64, imagePoint: CVPoint?, courtPoint: CVPoint?, zone: String?, confidence: Double?, reviewStatus: String) { self.eventId=eventId; self.eventType=eventType; self.timestampMs=timestampMs; self.imagePoint=imagePoint; self.courtPoint=courtPoint; self.zone=zone; self.confidence=confidence; self.reviewStatus=reviewStatus }
}
public struct CVBounceResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let matchId: String
    public let video: CVVideoMetadata
    public let calibrationId: String
    public let model: CVModelMetadata
    public let events: [CVBounceEvent]
    enum CodingKeys: String, CodingKey { case schemaVersion="schema_version", matchId="match_id", video, calibrationId="calibration_id", model, events }
    public init(schemaVersion: String="1.0", matchId: String, video: CVVideoMetadata, calibrationId: String, model: CVModelMetadata, events: [CVBounceEvent]) { self.schemaVersion=schemaVersion; self.matchId=matchId; self.video=video; self.calibrationId=calibrationId; self.model=model; self.events=events }
    public func validate() throws {
        guard schemaVersion == "1.0", !matchId.isEmpty, !calibrationId.isEmpty, video.durationMs > 0, video.width > 0, video.height > 0, video.fps.isFinite, video.fps > 0, !model.name.isEmpty, !model.version.isEmpty, !model.runtime.isEmpty else { throw CVBounceResultError.invalidMetadata }
        var seen = Set<String>()
        let zones = Set(["front_court_left", "front_court_right", "baseline_left", "baseline_right", "out_left", "out_right", "out_behind"])
        let statuses = Set(["needs_review", "accepted", "corrected", "rejected", "unresolved"])
        for event in events {
            guard !event.eventId.isEmpty, seen.insert(event.eventId).inserted, event.eventType == "bounce", event.timestampMs >= 0, event.timestampMs <= video.durationMs, statuses.contains(event.reviewStatus) else { throw CVBounceResultError.invalidEvent }
            if let p=event.imagePoint, !(p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)) { throw CVBounceResultError.invalidPoint }
            if let p=event.courtPoint, !(p.x.isFinite && p.y.isFinite) { throw CVBounceResultError.invalidPoint }
            if let c=event.confidence, !(c.isFinite && (0...1).contains(c)) { throw CVBounceResultError.invalidConfidence }
            if let z=event.zone, !zones.contains(z) { throw CVBounceResultError.invalidZone }
        }
    }
    public var acceptedEvents: [CVBounceEvent] { events.filter { ($0.reviewStatus == "accepted" || $0.reviewStatus == "corrected") && $0.zone != nil } }
}
public enum CVBounceResultError: Error { case invalidMetadata, invalidEvent, invalidPoint, invalidConfidence, invalidZone }
