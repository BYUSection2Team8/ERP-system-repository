// Brand mark: a "P" built from stacked print layers.
export function Logo({ size = 32 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-label="Poulson Prints logo" role="img">
      <rect width="32" height="32" rx="6" fill="var(--navy)" />
      <g fill="var(--teal)">
        <rect x="9" y="6" width="12" height="3" rx="1" />
        <rect x="9" y="10" width="14" height="3" rx="1" />
        <rect x="9" y="14" width="14" height="3" rx="1" />
        <rect x="9" y="18" width="5" height="3" rx="1" />
        <rect x="9" y="22" width="5" height="3" rx="1" />
      </g>
    </svg>
  );
}
