import { useEffect, useRef } from 'react';
import JsBarcode from 'jsbarcode';

/** Code 128 barcode rendered as SVG (crisp when printed). */
export function Barcode({
  value,
  height = 40,
  moduleWidth = 1.5,
  showText = true,
}: {
  value: string;
  height?: number;
  moduleWidth?: number;
  showText?: boolean;
}) {
  const ref = useRef<SVGSVGElement>(null);
  useEffect(() => {
    if (!ref.current) return;
    try {
      JsBarcode(ref.current, value, {
        format: 'CODE128',
        height,
        width: moduleWidth,
        margin: 0,
        displayValue: showText,
        fontSize: 11,
        textMargin: 1,
        background: 'transparent',
      });
    } catch {
      // Invalid characters for Code 128: leave the SVG empty.
    }
  }, [value, height, moduleWidth, showText]);
  return <svg ref={ref} className="barcode" aria-label={`Barcode ${value}`} />;
}
