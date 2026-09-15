import Foundation

public enum MeetingChatFileValidation {
    public static func validate(_ url: URL, policy: MeetingChatPolicy) throws {
        guard url.isFileURL else { throw MeetingError.unavailable("Choose a file on this Mac.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MeetingError.unavailable("Choose a single file to send.") }
        if policy.maxFileBytes > 0, UInt64(max(0, values.fileSize ?? 0)) > policy.maxFileBytes {
            throw MeetingError.unavailable("This file exceeds the meeting’s file size limit (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: policy.maxFileBytes), countStyle: .file))).")
        }
        let allowed = policy.allowedFileTypes.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
        }.filter { !$0.isEmpty }
        if !allowed.isEmpty, !allowed.contains(url.pathExtension.lowercased()) {
            throw MeetingError.unavailable("This meeting allows these file types: \(policy.allowedFileTypes).")
        }
    }
}
