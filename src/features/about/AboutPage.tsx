// Rubric requirement: document the AI coding tools and database used.
const tools = [
  { name: 'Claude Code (Anthropic)', use: 'AI coding tool that wrote the application code; the team reviewed and tested it.' },
  { name: 'Supabase (PostgreSQL)', use: 'Database, user logins, and real-time updates shared by all users.' },
  { name: 'GitHub', use: 'Stores every version of the code.' },
  { name: 'GitHub Actions + GitHub Pages', use: 'Builds the app automatically on every change and hosts the website.' },
  { name: 'React + TypeScript (Vite)', use: 'Framework used to build the user interface.' },
  { name: 'JsBarcode', use: 'Draws the Code 128 barcodes on item labels.' },
  { name: 'ZXing (@zxing/browser)', use: 'Reads barcodes through a phone or laptop camera. USB scanners work as a keyboard.' },
];

const dbFacts = [
  'Inventory is never typed in: on-hand quantities are the sum of posted stock movements (receipts, sales, returns, transfers, adjustments, production).',
  'Every business action (sale, return, receipt, transfer, adjustment, production issue/complete) is one database function that succeeds or fails as a whole.',
  'Every action also posts balanced debits and credits to a general ledger; financial reports read from that ledger.',
  'Costs use the weighted-average method. Made items roll up their cost from the bill of material plus machine time and labor from Settings.',
  'Row-level security in the database decides what staff and customers can see, so the public web address exposes nothing.',
];

export function AboutPage() {
  return (
    <div>
      <h1>About this system</h1>
      <p className="muted">
        Poulson Prints ERP is a GSCM 401 team project: a mini-ERP for a fictional Utah 3D-printing
        business.
      </p>
      <h2>Tools and database used</h2>
      <table className="table">
        <thead>
          <tr>
            <th>Tool</th>
            <th>What it does here</th>
          </tr>
        </thead>
        <tbody>
          {tools.map((t) => (
            <tr key={t.name}>
              <td>{t.name}</td>
              <td>{t.use}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <h2>How the database keeps the numbers honest</h2>
      <ul>
        {dbFacts.map((f) => (
          <li key={f}>{f}</li>
        ))}
      </ul>
    </div>
  );
}
