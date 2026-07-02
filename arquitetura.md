# Arquitetura — Lava Rápido Pro

**Última atualização:** 02 de julho de 2026
**Escopo:** `index.html` (painel administrativo) + Edge Functions (Supabase)

Este documento registra decisões arquiteturais críticas que **não podem ser revertidas ou contornadas** sem análise cuidadosa. Cada regra abaixo existe porque uma violação anterior já causou um bug real em produção. O objetivo é que qualquer pessoa (humana ou IA) trabalhando neste código consulte este arquivo antes de mexer nas áreas listadas.

---

## 🔒 Regras Intocáveis do Motor de Autenticação

### 1. Distinção obrigatória entre `TOKEN_REFRESHED` e `SIGNED_IN`

O `onAuthStateChange` do Supabase dispara múltiplos tipos de evento com uma sessão não-nula. Tratá-los todos da mesma forma quebra o app.

```js
sb.auth.onAuthStateChange((event, s) => {
  // TOKEN_REFRESHED: renovação de JWT — NUNCA limpa profile/empresa/assInfo
  if(event === "TOKEN_REFRESHED" && s){
    setSession(s);
    return;
  }
  if(s){
    // Aqui pode ser SIGNED_IN genuíno OU revalidação de wake-up mobile.
    // Ver regra #2 antes de resetar qualquer estado.
  }
});
```

**Por que importa:** o Supabase renova o JWT a cada ~1h automaticamente. Se o handler de `TOKEN_REFRESHED` limpar `profile`/`empresa`, a tela do operador esvazia sozinha em produção, sem nenhuma ação do usuário.

### 2. `profileRef` blinda contra falso SIGNED_IN no wake-up mobile

Quando o navegador mobile congela a aba (background) e o usuário retorna, o Supabase frequentemente reemite `SIGNED_IN` — não `TOKEN_REFRESHED` — mesmo sendo a mesma sessão. Sem proteção, isso é indistinguível de um login genuíno de outro usuário.

```js
const profileRef = useRef(null);
useEffect(() => { profileRef.current = profile; }, [profile]);

// No listener de auth:
if(s){
  if(profileRef.current && profileRef.current.id === s.user.id){
    // Wake-up/revalidação — MESMO usuário já carregado. Não destrói nada.
    setSession(s);
    return;
  }
  // Só chega aqui se for de fato um usuário novo/diferente — reseta normalmente
  setProfile(null); setEmpresa(null); setAssInfo(null);
  setSession(s);
}
```

O mesmo guard deve existir no `useEffect([session])` que busca o profile, para não disparar `setInitializing(true)` desnecessariamente:

```js
useEffect(() => {
  if(!session) return;
  if(profileRef.current?.id === session.user.id && profileRef.current?.empresa_id){
    return; // já temos tudo válido — não reinicializa
  }
  setInitializing(true);
  // ...fetch normal
}, [session]);
```

**Nunca remova este guard** para "simplificar o código". Ele é a diferença entre o app funcionar normalmente ao trocar de aba no celular e a tela ficar preta.

### 3. Proibição absoluta de `window.focus` e `disconnect()` manual no Realtime

Testado e descartado nesta sessão — **não reintroduzir**:

- ❌ `window.addEventListener("focus", ...)` — dispara dezenas de vezes por sessão no mobile (teclado abrindo, toques, foco entre elementos), causando resyncs em cascata.
- ❌ `sb.realtime.disconnect()` seguido de `connect()` manual — interrompe o backoff exponencial interno da lib e pode deixar o cliente em estado inconsistente, inclusive afetando a renovação de token.

O único padrão permitido para resync em wake-up mobile:

```js
useEffect(() => {
  let lastRefresh = 0;
  const forcarResync = () => {
    const agora = Date.now();
    if(agora - lastRefresh < 5000) return; // guard mínimo de 5s
    lastRefresh = agora;
    setTimeout(() => setRefreshToken(t => t+1), 500);
  };
  const onVisible = () => { if(document.visibilityState === "visible") forcarResync(); };
  const onPageShow = e => { if(e.persisted) forcarResync(); }; // iOS Safari BFCache
  document.addEventListener("visibilitychange", onVisible);
  window.addEventListener("pageshow", onPageShow);
  return () => {
    document.removeEventListener("visibilitychange", onVisible);
    window.removeEventListener("pageshow", onPageShow);
  };
}, []);
```

Apenas `visibilitychange` + `pageshow`. O Supabase reconecta o WebSocket sozinho.

### 4. `ErrorBoundary` como rede de segurança final

```js
class ErrorBoundary extends React.Component{
  static getDerivedStateFromError(erro){return{erro};}
  componentDidCatch(erro,info){console.error("ErrorBoundary capturou:",erro,info);}
  render(){
    if(this.state.erro) return <TelaDeErroComBotaoRecarregar/>;
    return this.props.children;
  }
}
ReactDOM.createRoot(document.getElementById("root")).render(<ErrorBoundary><App/></ErrorBoundary>);
```

Qualquer erro de runtime não previsto (referência a função inexistente, propriedade de objeto undefined, etc.) agora mostra uma tela de erro com botão "Recarregar" em vez de deixar a tela preta silenciosa.

---

## 🔒 Isolamento Estrito de Escopo no Lazy-Mount

O app usa lazy-mount (telas montam uma vez, alternam visibilidade via `display:none`/`flex`) para performance. Isso introduz um risco específico: **funções e variáveis de uma tela não existem no escopo de outra**, mesmo que pareçam relacionadas.

**Incidente registrado nesta sessão:** um `useEffect` que chamava `carregar()` (função exclusiva do `CRMScreen`) foi inserido por engano dentro do `FolhaScreen`, que usa `fetchTudo()` — nome diferente. Como `carregar` não existe no escopo do `FolhaScreen`, o React lançava um erro de runtime ao montar o componente, resultando em tela azul/travada sempre que a aba Folha era aberta.

**Regra:** antes de adicionar qualquer `useEffect`, `useCallback` ou referência de função em um componente de tela (`HomeScreen`, `HistoryScreen`, `CRMScreen`, `FolhaScreen`, `NewWashScreen`, `ConfigScreen`), confirme:

1. A função referenciada está declarada **dentro desse mesmo componente**, ou é **global** (fora de qualquer função de componente)?
2. Rode `grep -n "nomeDaFuncao"` no arquivo inteiro e confirme onde ela é declarada antes de assumir que existe no escopo atual.

O mesmo se aplica a props como `refreshToken`: só existe no componente se foi explicitamente declarado na assinatura da função (`function Tela({empresaId, refreshToken=0})`) **e** passado no local de renderização (`<Tela refreshToken={refreshToken}/>`).

---

## 🔒 Outras Regras Consolidadas de Sessões Anteriores

### Nomes de coluna reais (não confiar em nomes "plausíveis")

| Tabela | Coluna real | Nunca usar |
|---|---|---|
| `funcionario_diaria` | `profile_id` | `funcionario_id` |
| `folha_pagamentos` | `profile_id`, `valor` | `funcionario_id`, `valor_pago` |
| `folha_dias_trabalhados` | `profile_id` | `funcionario_id` |
| `historico` | `cliente_recuperado`, `completed_at` | — |

Antes de restringir qualquer `select('*')` para colunas explícitas, rode `grep -n "objeto\.campo"` cruzado no arquivo para confirmar o nome real usado downstream.

### Datas — sempre fuso local, nunca UTC

- **Nunca** usar `.toISOString().split("T")[0]` para comparação de datas no frontend.
- **Sempre** usar `toLocalDateStr(date)` (função global, ~linha 421).
- Para "início do dia": `date.setHours(0,0,0,0)` no fuso local, não aritmética de milissegundos (`Date.now() - dias*86400000`).

### Regras dos Hooks do React

- **Nunca** declarar `useState`/`useEffect`/`useMemo`/`useCallback` depois de um `return` condicional dentro de `App()`.
- Todos os hooks devem estar no topo do componente, antes de qualquer guard de renderização (`if(initializing) return ...`).

---

## 🔒 Infraestrutura de Backup (Edge Function + pg_cron)

Implementado e validado em produção em 02/07/2026.

### Componentes

| Peça | Localização | Função |
|---|---|---|
| Edge Function | `functions/backup-tenant-data/index.ts` | Gera dump JSON por empresa e faz upload ao Storage |
| Migration | `031_backup_automatizado.sql` | Cria bucket `backups` + agenda o cron job |
| Secret | `BACKUP_CRON_SECRET` (Edge Functions → Secrets) | Autentica a chamada do cron à função |
| Bucket | `backups` (Storage, privado) | Armazena `backups/{empresa_id}/backup_{timestamp}.json` |
| Cron job | `backup-diario-tenants` (pg_cron) | Dispara a função todo dia às 06:00 UTC (03:00 Brasília) |

### Tabelas incluídas no dump

`ordens_servico`, `caixa_movimentos`, `historico` — configurável no array `TABELAS_BACKUP` no topo da função. `historico` foi incluída deliberadamente além do pedido original, por concentrar todo o faturamento consolidado do negócio.

### Regras específicas desta infraestrutura

1. **Processamento atômico por tenant:** o loop de empresas tem `try/catch` individual. Uma falha isolada **nunca** deve interromper o processamento das demais. Não remover esse isolamento ao editar a função.
2. **Paginação obrigatória:** toda leitura de tabela usa `.range()` em lotes de 1000 registros (`LOTE` no código). Nunca substituir por um `select('*')` sem paginação — o volume de dados só cresce.
3. **"Verify JWT with legacy secret" deve permanecer desligado** para esta função (ver Regra #5 em `REGRAS_ARQUITETURA.md`). Confirme após qualquer redeploy — o toggle pode voltar a ligar sozinho (bug conhecido do painel Supabase).
4. **Nenhuma política de RLS foi alterada.** A função usa `SUPABASE_SERVICE_ROLE_KEY`, que não está sujeita a RLS por definição — o RLS do client (usuários normais do app) continua intacto e é o mecanismo de segurança real para o resto do sistema.
5. **Fuso horário do cron:** `pg_cron` no Supabase roda em UTC. O job está agendado para `0 6 * * *` (06:00 UTC = 03:00 Brasília). Se o horário de disparo precisar mudar, ajustar considerando essa conversão.

### Diagnóstico rápido se o backup parar de funcionar

```sql
-- Ver últimas execuções do cron e se falharam
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Testar a função manualmente (fora do horário agendado)
SELECT net.http_post(
  url     := 'https://ikahodmuchwitxfvlaop.supabase.co/functions/v1/backup-tenant-data',
  headers := jsonb_build_object(
    'Content-Type',  'application/json',
    'Authorization', 'Bearer <BACKUP_CRON_SECRET>'
  ),
  body    := '{}'::jsonb
);
-- Ver a resposta do teste acima:
SELECT status_code, content::text FROM net._http_response ORDER BY id DESC LIMIT 1;
```

`401` → verificar o toggle "Verify JWT" e se o secret bate exatamente. `404` → nome da função errado ou não deployada. `200` com `falhas: []` → tudo certo.

---

## Checklist antes de mexer em Auth, Realtime ou Lazy-Mount

- [ ] Testei o fluxo de login normal (email+senha)?
- [ ] Testei minimizar o app no celular e voltar (wake-up)?
- [ ] Testei trocar de aba no navegador mobile e voltar?
- [ ] Confirmei que `profile`, `empresa` e `assInfo` permanecem populados após o wake-up?
- [ ] Se adicionei uma função nova a uma tela, confirmei com `grep` que ela está declarada no escopo correto?
- [ ] Se toquei em qualquer `select()` do Supabase, confirmei os nomes reais de coluna com `grep` cruzado?
- [ ] Se redeployei a Edge Function de backup, confirmei que "Verify JWT" continua desligado?
