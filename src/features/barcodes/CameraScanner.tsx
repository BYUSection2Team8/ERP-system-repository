import { useEffect, useRef, useState } from 'react';
import { BrowserMultiFormatReader } from '@zxing/browser';

type Controls = Awaited<ReturnType<BrowserMultiFormatReader['decodeFromConstraints']>>;

/**
 * Full-screen camera scanner (phone or laptop camera). Reads Code 128 and
 * most other barcode types. Needs HTTPS, which GitHub Pages provides.
 * USB scanners don't need this: they type into the scan box like a keyboard.
 */
export function CameraScanner({ onScan, onClose }: { onScan: (text: string) => void; onClose: () => void }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const onScanRef = useRef(onScan);
  onScanRef.current = onScan;
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const reader = new BrowserMultiFormatReader();
    let controls: Controls | undefined;
    let finished = false;

    reader
      .decodeFromConstraints(
        { video: { facingMode: { ideal: 'environment' } }, audio: false },
        video,
        (result, _err, c) => {
          if (!result || finished) return;
          finished = true;
          c.stop();
          if (navigator.vibrate) navigator.vibrate(60);
          onScanRef.current(result.getText());
        },
      )
      .then((c) => {
        controls = c;
        if (finished) c.stop();
      })
      .catch((e: unknown) => {
        const name = e instanceof DOMException ? e.name : '';
        setError(
          name === 'NotAllowedError'
            ? 'Camera permission was denied. Allow camera access for this site, or type the barcode instead.'
            : name === 'NotFoundError'
              ? 'No camera found on this device. Type the barcode or use a USB scanner.'
              : 'Could not start the camera. Type the barcode instead.',
        );
      });

    return () => {
      finished = true;
      controls?.stop();
    };
  }, []);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal scanner" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <strong>Scan a barcode</strong>
          <button className="btn" onClick={onClose}>
            Close
          </button>
        </div>
        {error ? (
          <div className="notice error">{error}</div>
        ) : (
          <>
            <div className="scanner-view">
              <video ref={videoRef} muted playsInline />
              <div className="scanner-guide" />
            </div>
            <p className="muted small">Hold the label inside the box, in good light.</p>
          </>
        )}
      </div>
    </div>
  );
}
