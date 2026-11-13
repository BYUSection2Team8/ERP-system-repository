import type { ReactNode } from 'react';

export interface MathRow {
  label: ReactNode;
  value: ReactNode;
  /** where the input comes from (setting, ledger, history…) */
  source?: ReactNode;
  strong?: boolean;
}

/**
 * "Show the math" (wow factor #3): a fold-out panel under a calculated number
 * listing the formula and every input with where it comes from, so a manager
 * (or Dr. Wright) can check the number by hand and see what changes it.
 */
export function ShowMath({ formula, rows, children, open = false }: { formula?: ReactNode; rows: MathRow[]; children?: ReactNode; open?: boolean }) {
  return (
    <details className="show-math" open={open}>
      <summary>Show the math</summary>
      {formula && <div className="math formula">{formula}</div>}
      <table className="math-table">
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className={r.strong ? 'strong' : ''}>
              <td>{r.label}</td>
              <td className="num">{r.value}</td>
              <td className="muted small">{r.source}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {children}
    </details>
  );
}
