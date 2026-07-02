# Regras da Casa — Arquitetura Lava Rápido Pro

**Última atualização:** 02 de julho de 2026

Este arquivo lista as **decisões técnicas irreversíveis** do projeto. Cada regra existe porque uma violação já causou um bug real em produção. Antes de alterar qualquer área abaixo, leia a regra correspondente.

Para o histórico técnico completo e os trechos de código de referência, ver [`docs/arquitetura.md`](./arquitetura.md).

---

## 1. Nunca usar `window.focus` ou `disconnect()` manual no Realtime

O evento `window.focus` dispara dezenas de vezes por sessão no mobile (teclado abrindo, toques, foco entre elementos), causando resyncs em cascata. Chamar `sb.realtime.disconnect()`/`connect()` manualmente interrompe o backoff exponencial interno da lib do Supabase e pode deixar o cliente em estado inconsistente — inclusive afetando a renovação de token.

**Único padrão permitido para resync em wake-up mobile:** `visibilitychange` + `pageshow(persisted)`, com guard mínimo de 5 segundos entre execuções. O Supabase reconecta o WebSocket sozinho.

## 2. Sempre validar `user.id` via `profileRef` antes de resetar estados de auth

O Supabase pode reemitir `SIGNED_IN` (não apenas `TOKEN_REFRESHED`) ao revalidar uma sessão existente — por exemplo, quando o celular acorda de um freeze. Tratar todo `SIGNED_IN` como login novo destrói `profile`/`empresa`/`assInfo` desnecessariamente, causando tela preta.

**Regra:** antes de resetar qualquer estado no handler de `SIGNED_IN`, comparar `profileRef.current?.id` com `s.user.id`. Se forem iguais, é revalidação — apenas atualizar a sessão, sem tocar em profile/empresa/assinatura.

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
