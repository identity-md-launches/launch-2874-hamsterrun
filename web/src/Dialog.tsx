import { useEffect, useId, useRef, type ReactNode } from 'react';
import { Icon } from './Art';

export function Dialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  const id = useId();
  useEffect(() => {
    const el = ref.current!;
    const trigger = document.activeElement as HTMLElement | null;
    el.showModal();
    return () => {
      el.close();
      if (trigger?.isConnected && !trigger.matches(':disabled')) trigger.focus({ preventScroll: true });
      else document.querySelector<HTMLElement>('main')?.focus({ preventScroll: true });
    };
  }, []);
  return <dialog ref={ref} className="dialog" aria-labelledby={id} onCancel={e => { e.preventDefault(); onClose(); }}
    onClick={e => { const r = e.currentTarget.getBoundingClientRect(); if (e.target === e.currentTarget && (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom)) onClose(); }}>
    <div className="dialog-head"><h2 id={id}>{title}</h2><button className="icon-button" aria-label="Close dialog" onClick={onClose}><Icon name="close" size={16} /></button></div>
    {children}
  </dialog>;
}
