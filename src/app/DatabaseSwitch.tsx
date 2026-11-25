import { databaseOptions, dbChoice, dbShortLabel, hasDatabaseChoice, switchDatabase, type DbChoice } from '../lib/supabase';

/**
 * Practice (database 1) / Demo (database 2). Shown only when both databases are
 * configured. Switching reloads the site on the other database; each database has
 * its own logins, so you may need to sign in again.
 */
export function DatabaseSwitch({ compact = false }: { compact?: boolean }) {
  if (!hasDatabaseChoice) return null;

  if (compact) {
    return (
      <label className={`db-switch compact ${dbChoice}`} title="Which database this browser uses. Switching reloads the page.">
        <span className="sr-only">Database</span>
        <select
          value={dbChoice}
          onChange={(e) => {
            const next = e.target.value as DbChoice;
            if (next !== dbChoice && window.confirm(`Switch this browser to ${databaseOptions.find((o) => o.value === next)?.label}? The page reloads; you may need to sign in again.`)) {
              switchDatabase(next);
            } else {
              e.target.value = dbChoice;
            }
          }}
        >
          {databaseOptions.map((o) => (
            <option key={o.value} value={o.value}>{o.value === 'practice' ? 'Practice DB' : 'Demo DB'}</option>
          ))}
        </select>
      </label>
    );
  }

  return (
    <fieldset className="db-switch">
      <legend>Database</legend>
      <div className="choice-row">
        {databaseOptions.map((o) => (
          <label key={o.value} className={`choice ${dbChoice === o.value ? 'selected' : ''}`}>
            <input type="radio" name="database" checked={dbChoice === o.value} onChange={() => switchDatabase(o.value)} />
            {o.label}
          </label>
        ))}
      </div>
      <p className="muted small" style={{ margin: 0 }}>
        Now using: <strong>{dbShortLabel}</strong>. This browser remembers the choice.
      </p>
    </fieldset>
  );
}
