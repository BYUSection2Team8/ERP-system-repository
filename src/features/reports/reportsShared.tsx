import { addDays } from '../production/productionShared';

export const rangePresets: { label: string; days: number }[] = [
  { label: 'Last 7 days', days: 7 },
  { label: 'Last 30 days', days: 30 },
  { label: 'Last 90 days', days: 90 },
  { label: 'Last 6 months', days: 183 },
];

/** From / To date inputs plus quick presets ending today. */
export function DateRange({
  from,
  to,
  today,
  onChange,
}: {
  from: string;
  to: string;
  today: string;
  onChange: (from: string, to: string) => void;
}) {
  return (
    <div className="toolbar">
      <label>
        From
        <input type="date" value={from} max={to} onChange={(e) => e.target.value && onChange(e.target.value, to)} />
      </label>
      <label>
        To
        <input type="date" value={to} min={from} onChange={(e) => e.target.value && onChange(from, e.target.value)} />
      </label>
      <div className="choice-row" style={{ alignSelf: 'flex-end' }}>
        {rangePresets.map((p) => (
          <button key={p.label} type="button" className="btn" onClick={() => onChange(addDays(today, -(p.days - 1)), today)}>
            {p.label}
          </button>
        ))}
      </div>
    </div>
  );
}

export interface Bar {
  key: string;
  label: string;
  value: number;
  tooltip: string;
}

/**
 * One-series bar chart (SVG). Bars grow from a zero baseline (negative values,
 * e.g. a day with only returns, hang below it). Each bar has a hover tooltip;
 * the table under the chart is the accessible view of the same numbers.
 */
export function BarChart({ bars, format, title }: { bars: Bar[]; format: (v: number) => string; title: string }) {
  const W = 760;
  const H = 220;
  const padL = 64;
  const padR = 8;
  const padT = 10;
  const padB = 26;
  const max = Math.max(0, ...bars.map((b) => b.value));
  const min = Math.min(0, ...bars.map((b) => b.value));
  const span = max - min || 1;
  const y = (v: number) => padT + ((max - v) / span) * (H - padT - padB);
  const slot = (W - padL - padR) / Math.max(bars.length, 1);
  const barW = Math.max(2, Math.min(28, slot - 2));
  const ticks = [max, max / 2, 0, ...(min < 0 ? [min] : [])].filter((v, i, a) => a.indexOf(v) === i);
  const labelEvery = Math.ceil(bars.length / 10);

  return (
    <div className="chart card">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={W - padR} y1={y(t)} y2={y(t)} className={t === 0 ? 'chart-base' : 'chart-grid'} />
            <text x={padL - 6} y={y(t) + 4} textAnchor="end" className="chart-axis">{format(t)}</text>
          </g>
        ))}
        {bars.map((b, i) => {
          const x = padL + i * slot + (slot - barW) / 2;
          const top = Math.min(y(b.value), y(0));
          const h = Math.max(Math.abs(y(b.value) - y(0)), b.value === 0 ? 0 : 1);
          const r = Math.min(4, barW / 2, h);
          return (
            <g key={b.key} className="chart-bar">
              <rect x={padL + i * slot} y={padT} width={slot} height={H - padT - padB} fill="transparent">
                <title>{b.tooltip}</title>
              </rect>
              {h > 0 && (
                <path
                  d={
                    b.value >= 0
                      ? `M${x},${top + h} V${top + r} Q${x},${top} ${x + r},${top} H${x + barW - r} Q${x + barW},${top} ${x + barW},${top + r} V${top + h} Z`
                      : `M${x},${top} V${top + h - r} Q${x},${top + h} ${x + r},${top + h} H${x + barW - r} Q${x + barW},${top + h} ${x + barW},${top + h - r} V${top} Z`
                  }
                  className={b.value >= 0 ? 'chart-fill' : 'chart-fill negative'}
                >
                  <title>{b.tooltip}</title>
                </path>
              )}
              {i % labelEvery === 0 && (
                <text x={padL + i * slot + slot / 2} y={H - 8} textAnchor="middle" className="chart-axis">{b.label}</text>
              )}
            </g>
          );
        })}
      </svg>
    </div>
  );
}

export function shortDate(iso: string): string {
  return new Date(`${iso}T12:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}
