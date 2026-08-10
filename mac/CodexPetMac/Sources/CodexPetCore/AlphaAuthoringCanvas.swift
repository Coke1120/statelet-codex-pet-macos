/// Stable pixel geometry for newly converted Statelet animation media.
///
/// The pet window is measured in resizable AppKit points and must not determine
/// codec geometry. Existing libraries may contain other resolutions; playback
/// continues to scale those clips without rewriting them.
public enum AlphaAuthoringCanvas {
    public static let width = 320
    public static let height = 480
}
