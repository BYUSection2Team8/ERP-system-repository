import { useEffect, useState } from 'react';
import QRCode from 'qrcode';

/** QR code image for a URL (drawn in the browser, nothing is sent anywhere). */
export function QrCode({ value, size = 140, label }: { value: string; size?: number; label?: string }) {
  const [src, setSrc] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    QRCode.toDataURL(value, { margin: 1, width: size * 2, errorCorrectionLevel: 'M', color: { dark: '#14284b', light: '#ffffff' } })
      .then((url) => live && setSrc(url))
      .catch(() => live && setSrc(null));
    return () => {
      live = false;
    };
  }, [value, size]);
  if (!src) return <div style={{ width: size, height: size }} />;
  return <img src={src} width={size} height={size} alt={label ?? 'QR code'} className="qr" />;
}
