# Changelog — Lava Rápido Pro

## [02/07/2026] — Observabilidade (Sentry), Cadastro por OCR e Backup Automatizado por Tenant

### 🟢 Adicionado — Observabilidade em Produção (Sentry)

- **SDK do Sentry integrado** via CDN (`js.sentry-cdn.com`), inicializado com `Sentry.onLoad` no bloco de script principal do `index.html`.
- **`ErrorBoundary` aprimorado:** `componentDidCatch` agora envia automaticamente qualquer erro de runtime não tratado para o Sentry via `Sentry.captureException`, além de logar no console. Fallback visual atualizado para uma mensagem que informa ao operador que o suporte já foi notificado.
- Guards defensivos (`typeof Sentry!=="undefined"`) garantem que o app continue funcionando normalmente mesmo se o CDN do Sentry falhar ao carregar (rede bloqueada, adblocker).

### 🟢 Adicionado — Cadastro de Placa por OCR (`PlateScanner`)

- Novo componente `PlateScanner`, modal fullscreen que acessa a câmera traseira do dispositivo (`facingMode:"environment"`) e usa **Tesseract.js** (via CDN) para ler a placa do veículo em tempo real.
- Captura throttled a cada 1,2s (em vez de `requestAnimationFrame` puro) com guard contra execuções concorrentes — evita empilhar reconhecimentos e travar o celular do operador, já que cada OCR leva 1–3s.
- Recorte da imagem limitado à região da máscara visual (borda amarela, 85%×28% central) e whitelist de caracteres, para acelerar e melhorar a precisão da leitura.
- Regex cobre os dois padrões de placa brasileira (antigo `ABC-1234` e Mercosul `ABC1D23`); ao detectar uma correspondência válida, preenche o campo `plate`, dispara a verificação de cliente recuperado e encerra a câmera automaticamente.
- Gatilho: ícone de câmera dentro do input de Placa na tela de Nova Lavagem, no estilo glassmorphism âmbar do restante do app.
- Limpeza de hardware garantida em todos os caminhos de saída (detecção, cancelamento manual, unmount do componente) — sem vazamento de acesso à câmera.
- 100% client-side: nenhuma imagem trafega para o Supabase. RLS e demais políticas de segurança permanecem inalterados.

### 🟢 Adicionado — Backup Automatizado, Isolado por Tenant

- **Edge Function `backup-tenant-data`:** percorre todas as empresas cadastradas e gera, para cada uma, um dump JSON isolado contendo `ordens_servico`, `caixa_movimentos` e `historico`, salvo no Storage em `backups/{empresa_id}/backup_{timestamp}.json`.
- **Processamento atômico por tenant:** falha no backup de uma empresa é registrada e reportada (Sentry), mas **não interrompe** o processamento das demais. Resposta HTTP `207` sinaliza sucesso parcial quando aplicável.
- **Paginação em lotes de 1000 registros** por tabela, evitando estouro de memória à medida que o volume de dados cresce.
- **Autenticação do endpoint:** requer header `Authorization: Bearer <BACKUP_CRON_SECRET>` — protegido contra chamadas não autorizadas.
- **Agendamento via `pg_cron` + `pg_net`:** job diário às 03:00 (horário de Brasília / 06:00 UTC), definido na migration `031_backup_automatizado.sql`, que também cria o bucket privado `backups` no Storage (sem acesso público — apenas `service_role`).
- **Validado em produção em 02/07/2026:** primeira execução manual retornou `200`, com as 11 empresas ativas da plataforma processadas com sucesso e zero falhas.

### 📝 Nota de operação — bug conhecido do painel Supabase

O toggle **"Verify JWT with legacy secret"** de uma Edge Function pode ligar-se sozinho a cada novo deploy/atualização da função (bug documentado publicamente pela comunidade Supabase). Como o `backup-tenant-data` faz sua própria validação via `BACKUP_CRON_SECRET`, esse toggle **precisa permanecer desligado** — confira manualmente sempre que a função for redeployada, ou o cron passará a falhar silenciosamente com `401`.

---

## [01/07/2026] — Resiliência Offline, UI Otimista e Blindagem Final do Mobile

### 🟢 Adicionado — Arquitetura Offline-First

- **Fila offline via IndexedDB (`filaOffline`):** wrapper global com `init/add/getAll/remove/count`, todos com `try/catch` que degrada graciosamente se o IndexedDB estiver indisponível. Enfileira localmente qualquer transição de status que falhe por perda de rede, sem depender de bibliotecas externas.
- **UI Otimista para transições operacionais:** ao avançar o status de uma lavagem (Aguardando → Lavando → Concluído), a tela atualiza **imediatamente**, antes da resposta do Supabase. Padrão aplicado:
  1. Snapshot do card para rollback
  2. Atualização otimista do estado local
  3. Tentativa de persistência no banco
  4. Sucesso → nada a fazer; Conflito (outro operador já mudou) → recarrega a fila; Erro de rede → enfileira offline e mantém a tela otimista (sem rollback)
- **Sincronização em background:** `useEffect` global no `App()` com listener `online` + retry a cada 30s + tentativa no mount. Percorre a fila do IndexedDB e reenvia cada ação pendente ao Supabase, removendo da fila local após confirmação.
- **Feedback visual de sincronização:** banner amarelo discreto no topo da Fila ("N alterações aguardando sincronização") com mini-spinner, visível apenas quando há pendências reais.

### 🔒 Decisão arquitetural — Consistência financeira preservada

A transição para **"Pago"** foi deliberadamente **excluída** do padrão otimista/offline. Continua 100% síncrona: o operador aguarda a confirmação do servidor antes de ver a UI mudar, e o fluxo `UPDATE` → `INSERT` em `historico` → `DELETE` da fila permanece sequencial e sem enfileiramento local. Motivo: dinheiro exige garantia de consistência acima de velocidade percebida — uma duplicação ou perda de registro de faturamento é um problema mais grave do que meio segundo de espera.

### 🔴 Corrigido — Herdado da sessão anterior (30/06), confirmado estável hoje

- **Tela preta ao voltar do background no mobile:** o Supabase reemite `SIGNED_IN` (não apenas `TOKEN_REFRESHED`) ao revalidar sessão após o navegador congelar a aba. Sem proteção, isso destruía `profile`/`empresa`/`assInfo` como se fosse um login novo. Corrigido com `profileRef` — uma ref que espelha o profile atual e permite ao listener de auth distinguir revalidação (mesmo `user.id`) de login genuíno, preservando o estado no primeiro caso.
- **`ErrorBoundary` global:** qualquer erro de runtime não capturado nas camadas anteriores agora resulta em tela de erro com botão "Recarregar", nunca mais em tela preta silenciosa.

---

## [30/06/2026] — Estabilização crítica: Auth Mobile, UX Defensiva e Correções de Regressão

### 🔴 Corrigido — Crítico (Produção)

- **Login exigindo múltiplos cliques / loop de "Cadastrar Empresa":** causa raiz era dupla — (1) disparo duplo de `SIGNED_OUT`/`SIGNED_IN` pelo Supabase durante login criava condição de corrida no estado `session`; (2) dado corrompido no banco (`profiles.empresa_id = NULL`) para a conta do owner Zanata, desde 12/06. Corrigido com estado único `initializing`, ref `isLoggingIn` para filtrar eventos temporários, e `UPDATE` SQL direto vinculando o profile à empresa correta.
- **Tela preta/travada ao voltar de background no mobile:** o Supabase reemite `SIGNED_IN` (não apenas `TOKEN_REFRESHED`) ao revalidar sessão após o navegador congelar a aba. O handler tratava isso como login novo, destruindo `profile`/`empresa`/`assInfo`. Corrigido com `profileRef` que distingue revalidação (mesmo usuário) de login genuíno.
- **Crash de runtime ao abrir aba "Nova Lavagem":** funções `maskPlate`/`maskPhone` referenciadas em `onChange` mas nunca declaradas no escopo do componente. Corrigido declarando-as dentro do `NewWashScreen`.
- **Crash de runtime ao abrir aba "Folha":** `useEffect` residual de uma correção anterior chamava `carregar()` (função exclusiva do `CRMScreen`) dentro do `FolhaScreen`, que usa `fetchTudo()`. Removido.
- **Folha de pagamento zerada:** três tabelas (`funcionario_diaria`, `folha_pagamentos`, `folha_dias_trabalhados`) tinham `select()` com coluna `funcionario_id`, mas o schema real usa `profile_id`. Corrigido em todas as três queries.
- **Aba Serviços exibindo lista vazia:** `.order('created_at')` referenciava uma coluna que não existe (o campo real tem outro nome). Query rejeitada silenciosamente pelo Postgres. Removido o `.order()`, ordenação movida para o cliente.
- **Aba Equipe sem listar funcionários:** `select()` misturava colunas de `profiles` com colunas de `funcionario_diaria` (`tipo_pagamento`, `valor_diaria`), que não existem na tabela `profiles`. Corrigido para `select('*')`.
- **Horários da empresa não persistindo:** função de salvamento não tratava o retorno de `error` do Supabase — falhas de RLS ou rede eram silenciosas, dando falso feedback de sucesso. Adicionado `try/catch`/`alert()` explícito.
- **Card "Cliente Recuperado" não aparecendo / regressão do CRM:** a lógica original considerava apenas o registro mais recente por telefone. Um retorno posterior sem a flag do banco sobrescrevia a detecção do retorno anterior, fazendo clientes já recuperados voltarem à lista de sumidos. Corrigido com dois `Set` permanentes (placa + telefone) construídos a partir de todo o histórico disponível — imunidade vitalícia após a primeira recuperação confirmada.
- **Card "Receita de Hoje" com valores de ontem:** cálculo de datas usava `.toISOString()` (UTC) em vez do fuso local, vazando lavagens da noite anterior para o dia seguinte. Corrigido com `setHours(0,0,0,0)` no fuso local em todos os pontos (KPIs e gráfico).
- **Gráfico de Relatórios dessincronizado dos cards:** gráfico usava `caixa_movimentos` como fonte, cards usavam `historico` — números diferentes para o mesmo período. Unificado para usar `historico` em ambos.
- **Registro "Pago" desaparecendo da fila sem entrar no Histórico:** a transição dependia de um trigger de banco não confirmável. Substituído por lógica explícita no frontend: `UPDATE` do status → `INSERT` em `historico` → só então `DELETE` da fila, com `try/catch` e alerta visível em caso de falha em qualquer etapa.

### 🟡 Corrigido — Performance (sem regressão de UX)

- **G1 — Lazy-Mount de abas:** telas passaram de desmontar/remontar a cada troca para permanecerem montadas com `display:none`/`flex`, preservando estado e canais Realtime. Elimina ~160 queries redundantes por dia de operação.
- **G2 — Double-fetch no INSERT do Realtime da Fila:** removido `fetchQueue()` redundante após atualização otimista do estado local.
- **G3 — Histórico com janela de 6 meses** para badge do CRM e cálculo de sumidos (antes: sem filtro de data, processando o histórico completo).
- **G4 — Canal Realtime unificado na Folha:** de 3 WebSockets separados para 1 canal com 3 listeners.
- **G5 — KPIs financeiros em `useMemo`** com defesas de null-safety contra dados históricos incompletos.

### 🟢 Adicionado — Trilha 3: UX/UI Defensiva

- **Máscara de placa:** formatação automática em tempo real (uppercase, hífen no padrão antigo `ABC-1234`, sem hífen no Mercosul `ABC1D23`), com validação por regex que impede o envio de placas fora do padrão — sem bloquear a digitação.
- **Máscara de telefone:** formatação progressiva `(49) 99999-9999` conforme o usuário digita.
- **Empty states premium:** telas de Fila, CRM e Histórico exibem mensagens centralizadas com ícone e texto orientativo (ex: "Fila vazia — adicione um veículo na aba Nova Lavagem") em vez de tela em branco.
- **Banners de erro amigáveis:** falhas de rede em operações críticas (avançar status, salvar histórico) exibem banner vermelho no topo da tela com mensagem clara, em vez de falhar silenciosamente.
- **`ErrorBoundary` global:** qualquer erro de runtime não capturado nas camadas anteriores agora mostra uma tela de erro com botão "Recarregar", eliminando o cenário de tela preta silenciosa.

### 📄 Documentação

- Criado `docs/arquitetura.md` com as regras anti-regressão do motor de autenticação, isolamento de escopo do lazy-mount, e mapeamento de nomes de coluna reais do banco.
