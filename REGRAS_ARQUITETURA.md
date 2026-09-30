# Regras da Casa — Arquitetura Lava Rápido Pro

**Última atualização:** 28 de setembro de 2026

Este arquivo lista as **decisões técnicas irreversíveis** do projeto. Cada regra existe porque uma violação já causou um bug real em produção. Antes de alterar qualquer área abaixo, leia a regra correspondente.

Para o histórico técnico completo e os trechos de código de referência, ver [`docs/arquitetura.md`](./arquitetura.md).

---

## 1. Nunca usar `window.focus` ou `disconnect()` manual no Realtime

O evento `window.focus` dispara dezenas de vezes por sessão no mobile (teclado abrindo, toques, foco entre elementos), causando resyncs em cascata. Chamar `sb.realtime.disconnect()`/`connect()` manualmente interrompe o backoff exponencial interno da lib do Supabase e pode deixar o cliente em estado inconsistente — inclusive afetando a renovação de token.

**Único padrão permitido para resync em wake-up mobile:** `visibilitychange` + `pageshow(persisted)`, com guard mínimo de 5 segundos entre execuções. O Supabase reconecta o WebSocket sozinho.

## 2. Sempre validar `user.id` via `profileRef` antes de resetar estados de auth

O Supabase pode reemitir `SIGNED_IN` (não apenas `TOKEN_REFRESHED`) ao revalidar uma sessão existente — por exemplo, quando o celular acorda de um freeze. Tratar todo `SIGNED_IN` como login novo destrói `profile`/`empresa`/`assInfo` desnecessariamente, causando tela preta.

**Regra:** antes de resetar qualquer estado no handler de `SIGNED_IN`, comparar `profileRef.current?.id` com `s.user.id`. Se forem iguais, é revalidação — apenas atualizar a sessão, sem tocar em profile/empresa/assinatura.

**Armadilha irmã (28/09/2026):** `isLoggingIn.current=true` já é suficiente para bloquear o `SIGNED_OUT` temporário durante o login (o branch correspondente no `onAuthStateChange` retorna cedo, independente de `initializing`). **Nunca** forçar `setInitializing(true)` em `onLoginStart` — isso troca `<LoginScreen>` pelo spinner de tela cheia do `App`, desmontando o formulário; se o login falhar, o `LoginScreen` remonta do zero e apaga e-mail, senha e a mensagem de erro antes do usuário ver. O `useEffect([session])` já liga `initializing` sozinho quando a sessão realmente chega — não precisa disso no clique do botão.

## 2b. Toda saída do efeito de carregamento do profile deve deixar `profile` não-nulo (ou a trava final cobre)

`initializing=false` com `session` verdadeira e `profile` ainda `null` é o gatilho de `Cannot read properties of null (reading 'role')` — a única linha entre `if(!session)` e o resto do `App` é `if(profile.role===...)`, sem guard.

**Regra:** qualquer `catch`/early-return dentro do efeito `useEffect([session])` que chama `setInitializing(false)` deve também garantir um `profile` válido (usar o mesmo fallback `{_fetchError:true, role:'owner', ...}` já usado no caminho `fetchFailed`, com `setProfile(prev=>prev||fallback)` para não sobrescrever um profile real obtido antes do erro). Além disso, `if(!profile)return TelaCarregando;` logo após `if(!session)` no `App()` é a rede de segurança final — **nunca remover**, mesmo que pareça redundante com os fallbacks acima.

## 3. Transições financeiras são SÍNCRONAS por padrão

Qualquer operação que envolva dinheiro (ex: marcar uma ordem como "Pago", mover para o histórico de faturamento) **nunca** usa UI otimista nem fila offline. O operador aguarda a confirmação real do servidor antes de ver a tela mudar. Uma duplicação ou perda de registro financeiro é sempre pior do que meio segundo de espera percebida.

UI otimista e fila offline (IndexedDB) são permitidos **apenas** para transições operacionais reversíveis e sem impacto financeiro direto (ex: Aguardando → Lavando → Concluído).

## 4. Todo novo componente isola seus próprios fetches — nunca importa funções de telas irmãs

O app usa lazy-mount: telas montam uma vez e alternam visibilidade via `display:none`/`flex`, permanecendo todas vivas na memória simultaneamente. Isso cria um risco real de confundir escopos — uma função de uma tela **parece** disponível em outra, mas não está.

**Incidente registrado:** um `useEffect` que chamava `carregar()` (função exclusiva do `CRMScreen`) foi inserido por engano dentro do `FolhaScreen`, que usa `fetchTudo()`. Resultado: crash de runtime toda vez que a aba Folha era aberta.

**Regra prática:** antes de adicionar qualquer referência a função em um componente de tela, rodar `grep -n "nomeDaFuncao"` no arquivo inteiro e confirmar que ela está declarada **dentro do mesmo componente** ou é **verdadeiramente global** (fora de qualquer função de componente). O mesmo vale para props — só existem se declaradas na assinatura da função **e** passadas explicitamente no local de renderização.

## 5. Edge Functions com autenticação própria: sempre confira o toggle "Verify JWT" após qualquer redeploy

A Edge Function `backup-tenant-data` (e qualquer outra que valide seu próprio secret via header `Authorization`, em vez de depender de um JWT de usuário do Supabase) precisa do toggle **"Verify JWT with legacy secret" desligado** no painel. Se esse toggle estiver ligado, o gateway do Supabase rejeita a chamada com `401` **antes mesmo do código da função rodar** — o erro não aparece nos logs da função porque ela nunca chega a ser invocada.

**Armadilha conhecida:** esse toggle pode voltar a ligar sozinho a cada novo deploy/atualização da função (bug documentado publicamente na comunidade Supabase, não é erro de configuração nossa). **Sempre confira manualmente esse toggle depois de qualquer redeploy** de uma função com autenticação própria — um cron job de backup pode passar dias falhando silenciosamente com `401` sem nenhum alerta visível até alguém checar `cron.job_run_details`.

## 6. Faturamento conta pela data efetiva de pagamento, nunca só pela data da lavagem

Receita de mensalista deve ser contabilizada na data em que o pagamento foi recebido (baixa manual), não na data em que os carros foram lavados. Somar faturamento por `completed_at` puro faz o passado ser alterado retroativamente quando uma fatura antiga é paga.

**Regra:** em qualquer cálculo de faturamento por data (nos **Relatórios** e no **Histórico**), usar sempre `dataEfetiva(h) = h.data_pagamento || h.completed_at`. Nunca reintroduzir `completed_at` puro para somar ou agrupar receita em nenhuma das telas — se uma usar e a outra não, elas divergem (foi o bug do "Hoje R$ 590 vs R$ 640"). A query de período deve trazer registros por `completed_at` OU `data_pagamento` (`.or()`), senão lavagens antigas pagas hoje somem do período atual.

Faturamento (Relatórios, via `historico`) e extrato de caixa (Caixa Manual, via `caixa_movimentos`) são visões complementares — o pagamento do mensalista aparece nos dois de propósito, sem dupla contagem num mesmo total.

---

## 7. Recuperação de senha: `recoveryMode` tem prioridade sobre TODOS os guards de render

O link de e-mail abre uma **sessão real**. Se o `App` tratasse isso como login comum, o usuário cairia no Dashboard sem definir a nova senha.

**Regras:**
- O guard `if(recoveryMode) return <ResetPasswordScreen/>` deve ficar **depois de todos os hooks** e **antes** de `initializing`/`!session`. Nunca mover para depois deles.
- O evento `PASSWORD_RECOVERY` é emitido durante a inicialização do cliente, **antes do React montar**. Por isso existe o ouvinte precoce no script simples (`window.__recoveryDetected` + `sessionStorage('lr_recovery')`). Não remover nem mover para dentro do React.
- No `onAuthStateChange`, o ramo `PASSWORD_RECOVERY` retorna **antes** de qualquer lógica de `SIGNED_IN`, sem tocar em `TOKEN_REFRESHED` nem no guard do `profileRef`.
- `flowType:'pkce'` no `createClient` é parte do fluxo. O `redirectTo` (`origin + pathname`) precisa estar em **Redirect URLs** no Supabase, senão o link não funciona.
- Limitação conhecida: o link só funciona no mesmo navegador/dispositivo do pedido (verificador PKCE no `localStorage`).

---

## Checklist rápido antes de qualquer PR que toque em Auth, Realtime, Lazy-Mount ou fluxo financeiro

- [ ] Testei login normal (email+senha)?
- [ ] Testei minimizar o app no celular e voltar?
- [ ] Testei trocar de aba no navegador mobile e voltar?
- [ ] `profile`, `empresa` e `assInfo` permanecem populados após o wake-up?
- [ ] Testei desligar o Wi-Fi, mudar um status, religar o Wi-Fi — a ação sincronizou?
- [ ] Confirmei que nenhuma transição financeira foi tratada como otimista/offline?
- [ ] Se adicionei função nova a uma tela, confirmei com `grep` que está no escopo correto?
- [ ] Se redeployei uma Edge Function com secret próprio, confirmei que "Verify JWT" continua desligado?
- [ ] Se toquei em cálculo de faturamento, usei `dataEfetiva` (data_pagamento || completed_at) em vez de `completed_at` puro?
- [ ] Se toquei no `App`/auth, o link de recuperação de senha ainda abre a tela "Nova senha" (e não o Dashboard)?
