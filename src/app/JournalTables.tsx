import { dateTime, money } from '../lib/format';
import type { Account, LedgerRow } from '../lib/types';

/**
 * The journal entries a document posted (production order, PO, receipt...).
 * Shows how each business action hits the books; debits always equal credits.
 */
export function JournalTables({
  ledger,
  accounts,
  names = {},
  title = 'Accounting (journal entries)',
  empty,
}: {
  ledger: LedgerRow[];
  accounts: Map<string, Account>;
  names?: Record<string, string>;
  title?: string;
  empty?: string;
}) {
  if (ledger.length === 0) {
    return (
      <>
        <h2>{title}</h2>
        <p className="muted">{empty ?? 'Nothing has been posted yet.'}</p>
      </>
    );
  }
  const journals = new Map<string, LedgerRow[]>();
  for (const r of ledger) journals.set(r.journal_id, [...(journals.get(r.journal_id) ?? []), r]);
  return (
    <>
      <h2>{title}</h2>
      <p className="muted small">Posted by the database in the same transaction as the stock movement. Debits always equal credits.</p>
      {[...journals.values()].map((rows) => {
        const dr = rows.reduce((s, r) => s + Number(r.debit), 0);
        const cr = rows.reduce((s, r) => s + Number(r.credit), 0);
        return (
          <div className="table-wrap journal" key={rows[0].journal_id}>
            <table className="table">
              <thead>
                <tr>
                  <th>{names[rows[0].source_type] ?? rows[0].source_type} · {dateTime(rows[0].posted_at)}</th>
                  <th className="num">Debit</th>
                  <th className="num">Credit</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id}>
                    <td className={Number(r.credit) > 0 ? 'indent' : ''}>
                      {r.account_code} {accounts.get(r.account_code)?.name ?? ''}
                      {r.memo && <span className="muted small"> · {r.memo}</span>}
                    </td>
                    <td className="num">{Number(r.debit) > 0 ? money(r.debit) : ''}</td>
                    <td className="num">{Number(r.credit) > 0 ? money(r.credit) : ''}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td>Total</td>
                  <td className="num">{money(dr)}</td>
                  <td className="num">{money(cr)}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        );
      })}
    </>
  );
}
