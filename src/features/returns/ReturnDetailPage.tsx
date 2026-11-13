import { Link, useParams } from 'react-router-dom';
import { JournalTables } from '../../app/JournalTables';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, unwrap } from '../../lib/db';
import { dateTime, money, qty, unitCost } from '../../lib/format';
import type { Account, Item, LedgerRow, Location, ReturnLine, SaleReturn } from '../../lib/types';
import { useLiveQuery } from '../../lib/useLiveQuery';

interface LineView extends ReturnLine {
  item: Pick<Item, 'id' | 'name' | 'sku' | 'uom'>;
}

async function load(id: string) {
  const c = db();
  const ret = await c.from('returns').select('*').eq('id', id).maybeSingle().then(unwrap<SaleReturn | null>);
  if (!ret) throw new Error('That return does not exist.');
  const [lines, so, customer, reasons, locations, ledger, accounts, exch] = await Promise.all([
    c.from('return_lines').select('*, item:items(id, name, sku, uom)').eq('return_id', id).then((r) => unwrap(r) as unknown as LineView[]),
    c.from('sales_orders').select('id, order_no, payment_method, status').eq('id', ret.so_id).single().then(unwrap<{ id: string; order_no: string; payment_method: string | null; status: string }>),
    ret.customer_id ? c.from('customers').select('name').eq('id', ret.customer_id).maybeSingle().then(unwrap<{ name: string } | null>) : Promise.resolve(null),
    c.from('reason_codes').select('code, description, is_quality').eq('category', 'return').then(unwrap<{ code: string; description: string; is_quality: boolean }[]>),
    c.from('locations').select('*').then(unwrap<Location[]>),
    c.from('ledger').select('id, journal_id, posted_at, account_code, debit, credit, source_type, memo').eq('source_id', id).order('id').then(unwrap<LedgerRow[]>),
    c.from('accounts').select('code, name, type').then(unwrap<Account[]>),
    ret.exchange_so_id ? c.from('sales_orders').select('id, order_no, status').eq('id', ret.exchange_so_id).maybeSingle().then(unwrap<{ id: string; order_no: string; status: string } | null>) : Promise.resolve(null),
  ]);
  return { ret, lines, so, customer, reasons, locations, ledger, accounts: new Map(accounts.map((a) => [a.code, a])), exch };
}

export function ReturnDetailPage() {
  const { id = '' } = useParams();
  const { data, error, loading } = useLiveQuery(() => load(id), ['returns', 'return_lines', 'ledger', 'sales_orders'], [id]);
  if (loading) return <Loading what="return" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;
  const { ret, lines, so } = data;
  const qa = lines.some((l) => l.disposition === 'qa_hold');

  return (
    <div>
      <PageHeader
        title={`${ret.return_type === 'exchange' ? 'Exchange' : 'Return'} ${ret.return_no}`}
        subtitle={<>{data.customer?.name ?? 'Walk-in customer'} · order <Link to={`/sales/${so.id}`}>{so.order_no}</Link> · {dateTime(ret.returned_at)}</>}
        actions={
          <>
            <Link className="btn primary" to="/returns/new">New return</Link>
            <Link className="btn" to="/returns">All returns</Link>
          </>
        }
      />
      {qa && (
        <div className="notice warn spaced">
          Quality-failure items are in <strong>QA Hold</strong> (not sellable). After inspection, <Link to="/inventory/transfer">transfer them back</Link> to stock or{' '}
          <Link to="/inventory/adjust">scrap them</Link> with "Scrapped after QA inspection".
        </div>
      )}
      <div className="detail-grid">
        <div>
          <h2>Items returned</h2>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Qty</th>
                  <th>Reason</th>
                  <th>Went to</th>
                  <th className="num">Net price</th>
                  <th className="num">Cost back to stock</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => {
                  const rc = data.reasons.find((x) => x.code === l.reason_code);
                  return (
                    <tr key={l.id}>
                      <td><Link to={`/inventory/item/${l.item_id}`}>{l.item.name}</Link></td>
                      <td className="num">{qty(l.qty, l.item.uom)}</td>
                      <td>{rc?.description ?? l.reason_code}{rc?.is_quality && <span className="badge bad">quality</span>}</td>
                      <td>{l.disposition === 'qa_hold' ? <span className="badge warn status">QA Hold</span> : data.locations.find((x) => x.id === l.location_id)?.name}</td>
                      <td className="num">{unitCost(l.net_unit_price)}</td>
                      <td className="num">{money(Number(l.qty) * Number(l.unit_cost))}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {data.exch && (
            <p>
              Replacement order <Link to={`/sales/${data.exch.id}`}>{data.exch.order_no}</Link> ({data.exch.status === 'placed' ? 'backordered — ships when available' : data.exch.status}).
            </p>
          )}
          {ret.notes && <p className="muted">{ret.notes}</p>}
        </div>
        <div>
          <h2>Settlement</h2>
          <div className="card">
            <table className="totals">
              <tbody>
                <tr><td>Merchandise credit</td><td className="num">{money(ret.merchandise_credit)}</td></tr>
                <tr><td>Sales tax refunded</td><td className="num">{money(ret.tax_credit)}</td></tr>
                {Number(ret.restocking_fee) > 0 && <tr><td>Restocking fee</td><td className="num bad">−{money(ret.restocking_fee)}</td></tr>}
                {Number(ret.exchange_total) > 0 && <tr><td>Replacement order</td><td className="num">−{money(ret.exchange_total)}</td></tr>}
                <tr className="grand">
                  <td>{Number(ret.refund_amount) >= 0 ? 'Refunded to customer' : 'Collected from customer'}</td>
                  <td className="num">{money(Math.abs(Number(ret.refund_amount)))}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      <JournalTables ledger={data.ledger} accounts={data.accounts} names={{ sale_return: 'Return' }} />
    </div>
  );
}
