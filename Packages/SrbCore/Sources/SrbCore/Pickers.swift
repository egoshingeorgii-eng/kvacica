import Foundation

public enum SessionPicker {
    /// The first item that isn't from the same cluster or note as the card just shown, else the
    /// first look-alike, else the first item (the same note again; nil unless `allowSameNote`).
    public static func next<T>(
        _ items: [T],
        lastCluster: String?,
        lastNote: String?,
        cluster: (T) -> String?,
        note: (T) -> String,
        allowSameNote: Bool = true
    ) -> T? {
        items.first { item in
            note(item) != lastNote && (lastCluster == nil || cluster(item) != lastCluster)
        } ?? items.first { note($0) != lastNote } ?? (allowSameNote ? items.first : nil)
    }
}
