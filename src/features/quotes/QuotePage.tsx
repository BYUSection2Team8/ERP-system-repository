import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { errorMessage, rpc } from '../../lib/db';
import { useSalesRefData } from '../sales/salesShared';
import { QuoteFields, QuoteResult, emptyQuoteForm, quotePayload, useCustomQuote, type QuoteForm } from './quoteShared';

/** /sales/quote — price a custom print and turn it into an order in one click. */
export function QuotePage() {
  const ref = useSalesRefData();
  const navigate = useNavigate();
  const [f, setF] = useState<QuoteForm>(emptyQuoteForm);
  const [customerId, setCustomerId] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const payload = quotePayload(f);
  const { quote, error, pricing } = useCustomQuote(payload);

  async function create() {
    if (!payload) return;
    setBusy(true);
    setErr(null);
    try {
      const id = await rpc<string>('create_custom_print_order', { p: { ...payload, customer_id: customerId } });
      navigate(`/sales/${id}`);
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (ref.loading) return <Loading what="customers" />;
  if (ref.error) return <ErrorNotice message={ref.error} />;
  return (
    <div>
      <PageHeader
        title="Custom print quote"
        subtitle="Enter what the slicer says (print time and grams). The database prices it from current filament cost, machine and labor rates, packaging and our real recent failure rate, and estimates the ready date from the print queue."
      />
      <div className="pos-grid">
        <div className="card form">
          <QuoteFields f={f} set={setF} allowShip />
          <label>
            Note for the order (optional)
            <input value={f.notes} maxLength={500} onChange={(e) => setF({ ...f, notes: e.target.value })} />
          </label>
        </div>
        <div className="card form pos-pay">
          {!payload && <p className="muted">Enter a name, print time and grams to see the price.</p>}
          {error && <div className="notice error">{error}</div>}
          {pricing && !quote && <p className="muted">Pricing…</p>}
          {quote && <QuoteResult q={quote} pricing={pricing} />}
          <label>
            Customer
            <select value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
              <option value="">Choose a customer…</option>
              {(ref.data?.customers ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          {err && <div className="notice error">{err}</div>}
          <button className="btn primary big" disabled={!quote || pricing || !!error || !customerId || busy} onClick={create}>
            {busy ? 'Creating…' : 'Accept quote → create order'}
          </button>
          <p className="muted small">Creates a made-to-order item with its own bill of material, a sales order at this price, and a planned production order for MRP and the printers.</p>
        </div>
      </div>
    </div>
  );
}
