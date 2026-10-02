import React, { createContext, useContext, useEffect, useId, useRef, useState } from 'react';
import tokens from '../../lumina_tokens/lumina.v1.json';
import './styles.css';
import { useGlassWater } from './water';

export { tokens };
export type ThemeMode = 'system' | 'light' | 'dark';
const ThemeContext = createContext<{ mode: ThemeMode; setMode: (value: ThemeMode) => void }>({ mode: 'system', setMode: () => {} });
const storedTheme = (): ThemeMode => {
  if (typeof window === 'undefined') return 'system';
  const value = window.localStorage.getItem('lumina-theme');
  return value === 'light' || value === 'dark' ? value : 'system';
};
export function LuminaProvider({ children, initialMode }: { children: React.ReactNode; initialMode?: ThemeMode }) {
  const root = useRef<HTMLDivElement>(null);
  useGlassWater(root);
  const [mode, setMode] = useState<ThemeMode>(initialMode ?? storedTheme);
  const [prefersDark, setPrefersDark] = useState(() => typeof window !== 'undefined' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  useEffect(() => {
    const query = window.matchMedia('(prefers-color-scheme: dark)');
    const update = () => setPrefersDark(query.matches);
    query.addEventListener('change', update);
    return () => query.removeEventListener('change', update);
  }, []);
  useEffect(() => { window.localStorage.setItem('lumina-theme', mode); }, [mode]);
  const theme = mode === 'system' ? (prefersDark ? 'dark' : 'light') : mode;
  const variables = Object.fromEntries(Object.entries(tokens.color[theme]).map(([key, value]) => [`--${key.replace(/[A-Z]/g, char => `-${char.toLowerCase()}`)}`, value])) as React.CSSProperties;
  Object.assign(variables, { '--radius-control': `${tokens.radius.control}px`, '--radius-card': `${tokens.radius.card}px`, '--minimum-control': `${tokens.size.minimumControl}px`, '--glass-blur': '7px' });
  return <ThemeContext.Provider value={{ mode, setMode }}><div ref={root} style={variables} className="lumina-root" data-theme={theme}>{children}</div></ThemeContext.Provider>;
}
export const useLuminaTheme = () => useContext(ThemeContext);

type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'secondary' | 'quiet' | 'danger'; loading?: boolean; water?: boolean };
export function LuminaButton({ variant = 'secondary', loading = false, water = true, children, className = '', disabled, ...props }: ButtonProps) {
  return <button {...props} data-lumina-water={water && variant !== 'quiet'} className={`lumina-button lumina-button--${variant} ${className}`} disabled={disabled || loading} aria-busy={loading || undefined}>{loading ? <span className="lumina-spinner" aria-hidden="true"/> : null}{children}</button>;
}
export function LuminaIconButton({ label, children, className = '', ...props }: Omit<ButtonProps, 'children'> & { label: string; children: React.ReactNode }) {
  return <LuminaButton {...props} aria-label={label} title={label} className={`lumina-icon-button ${className}`}>{children}</LuminaButton>;
}
export function LuminaTextField({ label, hint, error, id: givenId, className = '', ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string; error?: string }) {
  const autoId = useId(); const id = givenId ?? autoId;
  return <div className={`lumina-field ${className}`}><label htmlFor={id}>{label}</label><input {...props} id={id} aria-invalid={!!error} aria-describedby={error ? `${id}-error` : hint ? `${id}-hint` : undefined}/>{error ? <span id={`${id}-error`} className="lumina-error" role="alert">{error}</span> : hint ? <span id={`${id}-hint`} className="lumina-hint">{hint}</span> : null}</div>;
}
export function LuminaCheckbox({ label, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  return <label className="lumina-choice" data-lumina-water="true"><input {...props} type="checkbox"/><span data-water-surface className="lumina-checkbox-mark" aria-hidden="true"/><span>{label}</span></label>;
}
export function LuminaSwitch({ label, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  return <label className="lumina-choice" data-lumina-water="true"><input {...props} type="checkbox" role="switch" className="lumina-switch-input"/><span data-water-surface className="lumina-switch-track" aria-hidden="true"><span/></span><span>{label}</span></label>;
}
export function LuminaSlider({ label, min = 0, max = 100, value, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  const id = useId();
  return <div className="lumina-slider"><label htmlFor={id}>{label}<output htmlFor={id}>{value ?? 0}</output></label><div className="lumina-slider-surface" data-lumina-water="true" style={{ '--slider-progress': `${Math.max(0, Math.min(100, (Number(value ?? min) - Number(min)) / Math.max(1, Number(max) - Number(min)) * 100))}%` } as React.CSSProperties}><input {...props} id={id} type="range" min={min} max={max} value={value}/></div></div>;
}
export function LuminaSegmented<T extends string>({ label, options, value, onChange }: { label: string; options: readonly { value: T; label: string }[]; value: T; onChange: (value: T) => void }) {
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  function move(event: React.KeyboardEvent, index: number) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + options.length) % options.length;
    onChange(options[next].value); refs.current[next]?.focus();
  }
  return <div className="lumina-segmented" role="radiogroup" aria-label={label}>{options.map((item, index) => <button data-lumina-water="true" key={item.value} ref={node => { refs.current[index] = node; }} type="button" role="radio" aria-checked={value === item.value} tabIndex={value === item.value ? 0 : -1} className={value === item.value ? 'selected' : ''} onClick={() => onChange(item.value)} onKeyDown={event => move(event, index)}>{item.label}</button>)}</div>;
}
export function LuminaCard({ title, children, className = '', water = false }: { title?: string; children: React.ReactNode; className?: string; water?: boolean }) {
  return <section data-lumina-water={water} className={`lumina-card ${className}`}>{title ? <h2 className="lumina-etched">{title}</h2> : null}{children}</section>;
}
export function LuminaTopBar({ title, leading, trailing, water = false }: { title: string; leading?: React.ReactNode; trailing?: React.ReactNode; water?: boolean }) {
  return <header data-lumina-water={water} className="lumina-topbar"><div className="lumina-topbar__side">{leading}</div><h1 className="lumina-etched">{title}</h1><div className="lumina-topbar__side lumina-topbar__side--end">{trailing}</div></header>;
}
export type MenuItem = { label: string; onSelect: () => void; disabled?: boolean };
export function LuminaMenu({ label, items }: { label: string; items: MenuItem[] }) {
  const [open, setOpen] = useState(false); const root = useRef<HTMLDivElement>(null);
  useEffect(() => { if (!open) return; function outside(event: PointerEvent) { if (!root.current?.contains(event.target as Node)) setOpen(false); } document.addEventListener('pointerdown', outside); return () => document.removeEventListener('pointerdown', outside); }, [open]);
  useEffect(() => { if (open) root.current?.querySelector<HTMLButtonElement>('[role=menuitem]:not(:disabled)')?.focus(); }, [open]);
  return <div ref={root} className="lumina-menu" onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false); }}><LuminaButton aria-expanded={open} aria-haspopup="menu" onClick={() => setOpen(!open)}>{label}</LuminaButton>{open ? <div role="menu" className="lumina-menu__panel" onKeyDown={event => { if (event.key === 'Escape') { setOpen(false); (root.current?.querySelector('button') as HTMLElement)?.focus(); } }}>{items.map((item, index) => <button key={index} role="menuitem" disabled={item.disabled} onClick={() => { item.onSelect(); setOpen(false); }} onKeyDown={event => { if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); const enabled = Array.from(root.current?.querySelectorAll<HTMLButtonElement>('[role=menuitem]:not(:disabled)') ?? []); const at = enabled.indexOf(event.currentTarget); enabled[(at + (event.key === 'ArrowDown' ? 1 : -1) + enabled.length) % enabled.length]?.focus(); } }}>{item.label}</button>)}</div> : null}</div>;
}
export function LuminaDialog({ open, title, children, onClose, actions }: { open: boolean; title: string; children: React.ReactNode; onClose: () => void; actions?: React.ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current; if (!dialog) return; if (open && !dialog.open) dialog.showModal(); if (!open && dialog.open) dialog.close(); }, [open]);
  return <dialog ref={ref} className="lumina-dialog" aria-label={title} onClose={onClose} onCancel={onClose}><h2 className="lumina-etched">{title}</h2><div>{children}</div><footer>{actions ?? <LuminaButton onClick={onClose}>关闭</LuminaButton>}</footer></dialog>;
}
export function LuminaToast({ message, action, onDismiss }: { message: string; action?: { label: string; onClick: () => void }; onDismiss: () => void }) {
  useEffect(() => { const timer = window.setTimeout(onDismiss, 5000); return () => window.clearTimeout(timer); }, [message, onDismiss]);
  return <div className="lumina-toast" role="status"><span>{message}</span>{action ? <button onClick={action.onClick}>{action.label}</button> : null}<button aria-label="关闭提示" onClick={onDismiss}>×</button></div>;
}
