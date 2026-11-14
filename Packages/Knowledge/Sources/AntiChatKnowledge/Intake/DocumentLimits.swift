// M6.T01 (R-020 AC3): the attachment limits. Named `AttachmentLimits` because the vendored Osaurus module already has a
// `DocumentLimits` (per-adapter parse caps); intake passes `maxFileBytes` as every adapter's size limit.
import Foundation

public enum AttachmentLimits {
    /// 512 MB per file (`upload.tooLarge` `{limit}` = "512 MB").
    public static let maxFileBytes: Int64 = 512 * 1024 * 1024
    /// 20 files per message (`upload.tooMany`).
    public static let maxFiles = 20
    /// The `{limit}` text of `upload.tooLarge`.
    public static let maxFileLabel = "512 MB"
}
