// M2.T13 step 4 (NFR-R5 override, R-206 AC6). With "Allow loads above the memory budget" (`set.cap.allowOver`, off by
// default, Advanced only) the NFR-R5 refusal becomes a load attempt guarded by the memory-pressure responder (T14):
// the over-budget model is the first one released at CRITICAL pressure, and no attempt starts while the system is
// already at CRITICAL. Without the override nothing ever loads past B.
import AntiChatFoundation
import Foundation

public enum BudgetOverride {
    /// May a load that does not fit B be attempted?
    public static func mayAttempt(allowOverBudget: Bool, pressure: PressureLevel) -> Bool {
        allowOverBudget && pressure < .critical
    }

    /// Release order at CRITICAL: over-budget loads first (newest first), then the normal pressure order.
    public static func criticalVictims(overBudget: [String]) -> [String] { overBudget.reversed() }
}
