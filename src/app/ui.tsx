import type { ReactNode } from 'react';
import type { Location } from '../lib/types';

// Small shared building blocks so every screen looks the same.

export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="page-header">
      <div>
        <h1>{title}</h1>
        {subtitle && <p className="muted">{subtitle}</p>}
      </div>
      {actions && <div className="page-actions no-print">{actions}</div>}
    </div>
  );
}

export function Loading({ what = 'data' }: { what?: string }) {
  return <p className="muted">Loading {what}…</p>;
}

export function ErrorNotice({ message }: { message: string }) {
  return <div className="notice error">{message}</div>;
}

export function Stat({ label, value, hint, tone }: { label: string; value: ReactNode; hint?: ReactNode; tone?: 'warn' | 'bad' }) {
  return (
    <div className={`stat ${tone ?? ''}`}>
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
      {hint && <div className="stat-hint">{hint}</div>}
    </div>
  );
}

const shortNames: Record<string, string> = {
  PRINT_FARM: 'Print Farm',
  FULFILLMENT: 'Fulfillment',
  CAMPUS: 'Campus',
  QA_HOLD: 'QA Hold',
};

export function shortLocation(loc: Location): string {
  return shortNames[loc.code] ?? loc.name;
}
