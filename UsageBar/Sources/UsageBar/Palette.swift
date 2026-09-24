import SwiftUI

/// One color family per provider, used for its rings, bars, and cost share. The primary tone marks the main
/// allowance or measurement; softer and deeper tones mark nested windows or parts within the same provider.
/// System orange stays reserved for warnings.
enum Palette {
    /// Codex: cobalt, a cool blue that reads as OpenAI's tooling without borrowing a brand mark.
    static let codex = Color(red: 0.30, green: 0.52, blue: 1.00)
    /// Claude: Anthropic's terracotta, with a sand tone for the 5-hour session.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let claudeSoft = Color(red: 0.93, green: 0.72, blue: 0.60)
    /// Local inference: mint for compute, a lighter mint for memory, and a deep green for generated output.
    static let local = Color(red: 0.24, green: 0.78, blue: 0.63)
    static let localSoft = Color(red: 0.56, green: 0.88, blue: 0.78)
    static let localDeep = Color(red: 0.11, green: 0.55, blue: 0.44)
}
