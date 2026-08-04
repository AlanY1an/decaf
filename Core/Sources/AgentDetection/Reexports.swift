// Re-exports so AgentDetection presents the full interface described in plan 02 §0
// without duplicating definitions:
// - AgentKind lives in HookWire (shared with caff-bridge, review decision R14).
// - DetectionPrecision lives in CaffeinateCore (AppStateSnapshot carries it, R12),
//   which AgentDetection depends on.
// Both aliases resolve to the exact same underlying types.

import CaffeinateCore
import HookWire

public typealias AgentKind = HookWire.AgentKind
public typealias DetectionPrecision = CaffeinateCore.DetectionPrecision
