# SKMS - SK Market Structure

SKMS is a TradingView Pine Script v6 indicator for market structure analysis. It tracks swing structure, retracements, BOS, and CHOCH on the chart, and can optionally plot an internal structure layer for finer trend analysis.

## Latest Version

The latest indicator build in this repository is `SKMS/custom-v4-internal-structure.pine`.

## What It Does

- Detects bullish and bearish market structure.
- Marks BOS and CHOCH events with colored lines and labels.
- Tracks retracement behavior using independent bar logic.
- Updates previous highs and lows when wicks sweep them.
- Supports optional internal structure visualization.
- Lets you choose how internal structure starts after a breakout:
	- `Breakout Candle`
	- `Last IB`

## Indicator Inputs

- `Show Internal Structure`: enables internal structure plotting.
- `Internal Structure Start Point`: selects the internal start reference.
- `High/Low Line Width`: controls the thickness of structure lines.

## How To Use

1. Open the Pine Script editor in TradingView.
2. Paste the contents of `SKMS/custom-v4-internal-structure.pine`.
3. Add the script to your chart.
4. Use the inputs to switch internal structure on or off.

## Repository Files

- `SKMS/custom-v4-internal-structure.pine` - latest indicator version with internal structure support.
- `SKMS/custom-v3-internal-structure.pine` - previous internal-structure version.
- `SKMS/custom-v2.pine` - earlier indicator version.
- `SKMS/custom.pine` - base indicator version.
- `SKMS/SKMS_Strategy.pine` - strategy variant built on the same structure logic.
- `SKMS/my_structure_rules.txt` - notes and rules used while developing the logic.
- `SKMS/ref/smc_by_luxalgo_indicator_tradingview.pine` - reference script.

## Notes

- The script is written for TradingView Pine Script v6.
- It uses line and label objects heavily, so chart object limits matter.
- Internal structure is optional and hidden by default.

## License

No license has been added yet.
