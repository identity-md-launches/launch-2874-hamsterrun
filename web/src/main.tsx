import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { App } from './App';
import { loadRuntime, type Runtime } from './runtime';
import './styles.css';

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: true } } });
function Bootstrap() {
  const [runtime, setRuntime] = useState<Runtime>();
  const [error, setError] = useState('');
  async function start() { setError(''); try { setRuntime(await loadRuntime()); } catch (e) { setError(e instanceof Error ? e.message : 'Could not load the v3 game files.'); } }
  useEffect(() => { void start(); }, []);
  if (!runtime) return <main className="loading"><div><img src="./hamster.svg" alt="A little pixel hamster" width={100} height={88} /><h1>HamsterRun</h1><p role={error ? 'alert' : 'status'}>{error || 'Opening your pocket adventure…'}</p>{error && <button className="button" onClick={() => void start()}>Retry loading</button>}</div></main>;
  return <WagmiProvider config={runtime.wagmi}><QueryClientProvider client={queryClient}><App runtime={runtime} /></QueryClientProvider></WagmiProvider>;
}
createRoot(document.getElementById('root')!).render(<Bootstrap />);
