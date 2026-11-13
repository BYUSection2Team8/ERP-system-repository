import { useState } from 'react';
import { ErrorNotice, Loading, PageHeader } from '../../app/ui';
import { db, errorMessage, unwrap } from '../../lib/db';
import { dateTime } from '../../lib/format';
import { useLiveQuery } from '../../lib/useLiveQuery';

interface SettingRow {
  key: string;
  value: string;
  type: 'number' | 'text' | 'boolean' | 'json';
  category: string;
  label: string | null;
  description: string | null;
  updated_at: string;
}

const categoryNames: Record<string, string> = {
  company: 'Company',
  labor: 'Labor',
  machine: 'Machine time',
  filament: 'Filament',
  sales: 'Sales, tax and discounts',
  fulfillment: 'Shipping and packaging',
  ordering: 'Ordering and holding cost (ROP / EOQ)',
  inventory: 'Inventory',
  history: 'Generated history (read only)',
};
const order = ['ordering', 'sales', 'fulfillment', 'labor', 'machine', 'filament', 'inventory', 'company', 'history'];

async function load() {
  return db().from('settings').select('*').order('key').then(unwrap<SettingRow[]>);
}

export function SettingsPage() {
  const { data, error, loading } = useLiveQuery(load, ['settings']);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  if (loading) return <Loading what="settings" />;
  if (error) return <ErrorNotice message={error} />;
  if (!data) return null;

  async function save(s: SettingRow) {
    const v = (edits[s.key] ?? s.value).trim();
    setSaving(s.key);
    setMsg(null);
    try {
      if (s.type === 'number' && (v === '' || !Number.isFinite(Number(v)))) throw new Error(`${s.label ?? s.key} must be a number.`);
      if (s.type === 'boolean' && v !== 'true' && v !== 'false') throw new Error(`${s.label ?? s.key} must be true or false.`);
      await db().from('settings').update({ value: v, updated_at: new Date().toISOString() }).eq('key', s.key).then((r) => unwrap(r));
      setMsg({ ok: true, text: `${s.label ?? s.key} saved. Every screen that uses it recalculates.` });
      const next = { ...edits };
      delete next[s.key];
      setEdits(next);
    } catch (e) {
      setMsg({ ok: false, text: errorMessage(e) });
    } finally {
      setSaving(null);
    }
  }

  const cats = [...new Set(data.map((s) => s.category))].sort((a, b) => (order.indexOf(a) + 99) % 99 - (order.indexOf(b) + 99) % 99);

  return (
    <div>
      <PageHeader
        title="Settings"
        subtitle="Every rate and rule the system uses is a stored setting. Change one and the reorder points, EOQ, costs, prices and reports that depend on it update everywhere."
      />
      {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'} spaced`}>{msg.text}</div>}
      {cats.map((cat) => (
        <section key={cat}>
          <h2>{categoryNames[cat] ?? cat}</h2>
          <div className="table-wrap">
            <table className="table settings-grid">
              <tbody>
                {data.filter((s) => s.category === cat).map((s) => {
                  const value = edits[s.key] ?? s.value;
                  const dirty = edits[s.key] !== undefined && edits[s.key] !== s.value;
                  const readOnly = cat === 'history';
                  return (
                    <tr key={s.key}>
                      <td>
                        <strong>{s.label ?? s.key}</strong>
                        {s.description && <div className="muted small">{s.description}</div>}
                      </td>
                      <td>
                        {readOnly ? (
                          <span>{s.value}</span>
                        ) : s.type === 'boolean' ? (
                          <select value={value} onChange={(e) => setEdits({ ...edits, [s.key]: e.target.value })}>
                            <option value="true">true</option>
                            <option value="false">false</option>
                          </select>
                        ) : (
                          <input value={value} inputMode={s.type === 'number' ? 'decimal' : undefined} onChange={(e) => setEdits({ ...edits, [s.key]: e.target.value })} />
                        )}
                      </td>
                      <td className="muted small">{dateTime(s.updated_at)}</td>
                      <td>
                        {!readOnly && (
                          <button className={`btn ${dirty ? 'primary' : ''}`} disabled={!dirty || saving !== null} onClick={() => save(s)}>
                            {saving === s.key ? 'Saving…' : 'Save'}
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      ))}
    </div>
  );
}
