import { useMemo, useState, type KeyboardEvent } from 'react';
import type { Item } from '../../lib/types';
import { CameraScanner } from './CameraScanner';

/** Find the item whose barcode or SKU matches exactly (case-insensitive). */
export function findByCode(items: Item[], code: string): Item | undefined {
  const c = code.trim().toUpperCase();
  return items.find((i) => i.barcode.toUpperCase() === c || i.sku.toUpperCase() === c);
}

/**
 * One box for every way of choosing an item:
 *  - USB barcode scanner (types the code + Enter),
 *  - phone/laptop camera (camera button),
 *  - typing part of a name or SKU and picking from the list.
 */
export function ScanItemInput({
  items,
  onPick,
  placeholder = 'Scan or type a barcode, SKU or name',
  autoFocus = false,
}: {
  items: Item[];
  onPick: (item: Item) => void;
  placeholder?: string;
  autoFocus?: boolean;
}) {
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [scanning, setScanning] = useState(false);

  const matches = useMemo(() => {
    const t = text.trim().toLowerCase();
    if (t.length < 2) return [];
    return items
      .filter(
        (i) =>
          i.name.toLowerCase().includes(t) ||
          i.sku.toLowerCase().includes(t) ||
          i.barcode.toLowerCase().includes(t),
      )
      .slice(0, 8);
  }, [items, text]);

  function pick(item: Item) {
    onPick(item);
    setText('');
    setError(null);
  }

  function resolve(code: string) {
    const exact = findByCode(items, code);
    if (exact) return pick(exact);
    setError(`No item has barcode or SKU "${code.trim()}".`);
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    if (!text.trim()) return;
    const exact = findByCode(items, text);
    if (exact) return pick(exact);
    if (matches.length === 1) return pick(matches[0]);
    setError(matches.length ? 'Several items match: pick one from the list.' : `No item matches "${text.trim()}".`);
  }

  return (
    <div className="scan-input">
      <div className="scan-row">
        <input
          value={text}
          onChange={(e) => {
            setText(e.target.value);
            setError(null);
          }}
          onKeyDown={onKeyDown}
          placeholder={placeholder}
          autoFocus={autoFocus}
          autoComplete="off"
          aria-label="Scan or search for an item"
        />
        <button type="button" className="btn" onClick={() => setScanning(true)} title="Scan with camera">
          📷 Scan
        </button>
      </div>
      {matches.length > 0 && (
        <ul className="suggestions">
          {matches.map((i) => (
            <li key={i.id}>
              <button type="button" onClick={() => pick(i)}>
                <span>{i.name}</span>
                <span className="muted small">{i.sku}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {error && <div className="field-error">{error}</div>}
      {scanning && (
        <CameraScanner
          onClose={() => setScanning(false)}
          onScan={(code) => {
            setScanning(false);
            resolve(code);
          }}
        />
      )}
    </div>
  );
}
