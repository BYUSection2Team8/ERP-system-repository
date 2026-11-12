// Rubric requirement: document the AI coding tools and database used.
const tools = [
  { name: 'Claude Code (Anthropic)', use: 'AI coding tool that wrote the application code; the team reviewed and tested it.' },
  { name: 'Supabase (PostgreSQL)', use: 'Database, user logins, and real-time updates shared by all users.' },
  { name: 'GitHub', use: 'Stores every version of the code.' },
  { name: 'GitHub Actions + GitHub Pages', use: 'Builds the app automatically on every change and hosts the website.' },
  { name: 'React + TypeScript (Vite)', use: 'Framework used to build the user interface.' },
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
    </div>
  );
}
