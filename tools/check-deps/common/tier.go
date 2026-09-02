package common

// Tier ranks the review priority of a dependency.
type Tier int

const (
	TierT1 Tier = 1 // security-critical; treat every change with care
	TierT2 Tier = 2 // review: build graph, toolchain, supply chain, breaking bumps
	TierT3 Tier = 3 // minor: patch-level or build-time tooling updates
)

// String renders the review-tier label. It routes through Normalized(), the
// one canonical "unrecognized tier -> T3" rule, so a future or unrecognized
// tier value renders as T3 rather than panicking or inventing a label.
func (t Tier) String() string {
	switch t.Normalized() {
	case TierT1:
		return "T1"
	case TierT2:
		return "T2"
	case TierT3:
		return "T3"
	}
	panic("Tier.String: Normalized() returned an unrecognized tier")
}

// Normalized maps any tier value to the three report tiers, resting
// unrecognized or future values at TierT3. TierT3 is the explicit catch-all
// resting tier (baseTier defaults every unclaimed dependency to it), so an
// unrecognized value intentionally renders, counts, and buckets as T3 rather
// than panicking. It is the one canonical "unrecognized tier -> T3" rule:
// String(), the count accumulator, and the console renderer all route through
// it so the fallback never diverges.
func (t Tier) Normalized() Tier {
	switch t {
	case TierT1:
		return TierT1
	case TierT2:
		return TierT2
	default:
		return TierT3
	}
}
