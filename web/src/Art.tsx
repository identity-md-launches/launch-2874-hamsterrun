export type IconName = 'pet' | 'flag' | 'gift' | 'book' | 'arrow' | 'refresh' | 'heart' | 'bolt' | 'food' | 'wheel' | 'check' | 'clock' | 'link' | 'close' | 'wallet';
const paths: Record<IconName, string> = {
  pet: 'M4 3h3v3h6V3h3v7h2v6h-2v2H4v-2H2v-6h2V3zm2 6v3h2V9H6zm6 0v3h2V9h-2zm-3 4v2h2v-2H9z',
  flag: 'M4 2h2v2h12v8H6v6H4V2zm2 4v4h3V6H6zm6 0v4h3V6h-3z',
  gift: 'M8 2h4v2h4v3h3v5h-2v6H3v-6H1V7h3V4h4V2zm0 3H6v2h3V5H8zm4 0v2h2V5h-2zM3 9v1h6V9H3zm8 0v7h4v-4h-4v-2h6V9h-6zm-6 3v4h4v-4H5z',
  book: 'M2 3h7v1h2V3h7v14h-7v1H9v-1H2V3zm2 2v10h5V5H4zm7 0v10h5V5h-5z',
  arrow: 'M10 3h3v3h3v3h3v2h-3v3h-3v3h-3v-5H1V8h9V3z',
  refresh: 'M5 2h9v2h3v3h2v4h-6V9h2V7h-2V5H6v2H4v7h2v2h7v-2h3v3h-3v2H5v-2H2v-3H0V7h2V4h3V2z',
  heart: 'M2 3h5v2h6V3h5v2h2v6h-2v3h-3v3h-3v2H8v-2H5v-3H2v-3H0V5h2V3z',
  bolt: 'M11 0h4l-4 7h6L7 20H4l4-9H3L11 0z',
  food: 'M2 10h16v3h-2v4H4v-4H2v-3zm4-8h2v5H6V2zm6 0h2v5h-2V2z',
  wheel: 'M6 1h8v2h3v3h2v8h-2v3h-3v2H6v-2H3v-3H1V6h2V3h3V1zm1 3v2H5v2H4v4h1v2h2v2h2v-5H4V9h5V4H7zm4 0v5h5V8h-1V6h-2V4h-2zm0 7v5h2v-2h2v-2h1v-1h-5z',
  check: 'M16 3h3v3h-3v3h-3v3h-3v3H7v-3H4V9H1V6h3v3h3v3h3V9h3V6h3V3z',
  clock: 'M5 1h10v2h3v3h2v8h-2v3h-3v2H5v-2H2v-3H0V6h2V3h3V1zm1 3v2H4v8h2v2h8v-2h2V6h-2V4H6zm3 2h2v5h3v2H9V6z',
  link: 'M9 2h7v2h2v7h-2v2h-4v-3h3V5h-5v3H7V4h2V2zM4 7h4v3H5v5h5v-3h3v4h-2v2H4v-2H2V9h2V7z',
  close: 'M3 1h3v3h3v3h2V4h3V1h3v3h-3v3h-3v4h3v3h3v3h-3v-3h-3v-3H9v3H6v3H3v-3h3v-3h3V7H6V4H3V1z',
  wallet: 'M3 3h14v3h2v12H1V5h2V3zm0 5v8h14v-3h-5V9h5V8H3zm11 3v1h3v-1h-3z',
};
export function Icon({ name, size = 20 }: { name: IconName; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 20 20" fill="currentColor" shapeRendering="crispEdges" aria-hidden="true"><path fillRule="evenodd" d={paths[name]} /></svg>;
}
export function Dpad() {
  return <svg viewBox="0 0 76 76" className="dpad" aria-hidden="true" shapeRendering="crispEdges"><path d="M26 0h24v26h26v24H50v26H26V50H0V26h26z" fill="#CADC9F"/><path d="M29 5h18v24h24v18H47v24H29V47H5V29h24z" fill="#306230"/><path d="m38 12-5 7h10zM12 38l7 5V33zm52 0-7-5v10zM38 64l5-7H33z" fill="#CADC9F"/><path d="M33 33h10v10H33z" fill="#0F380F"/></svg>;
}
